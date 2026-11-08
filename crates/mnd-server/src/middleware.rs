//! HTTP middleware: client IP resolution, CORS, helmet headers, compression and
//! the four rate-limit policies from `app.ts`.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use axum::Json;
use axum::extract::{ConnectInfo, Request, State};
use axum::http::{HeaderName, HeaderValue, Method, StatusCode, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use serde_json::json;

use crate::ratelimit::{Decision, normalize_ip, policy};
use crate::state::AppState;

/// `clientIp`: the peer address, except that loopback peers (the local nginx)
/// may supply `X-Real-IP`. A direct connection cannot spoof it.
pub fn client_ip(req: &Request) -> String {
    let peer = req
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|info| info.0.ip());
    let loopback = peer.map(|ip| ip.is_loopback()).unwrap_or(false);

    if loopback {
        if let Some(real) = req
            .headers()
            .get("x-real-ip")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<IpAddr>().ok())
        {
            return real.to_string();
        }
        // Express `trust proxy: 'loopback'` walks the X-Forwarded-For chain
        // from the socket: with one trusted (loopback) hop the effective
        // client is the right-most entry, not the left-most one.
        if let Some(last) = req
            .headers()
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
            .and_then(|v| v.trim().parse::<IpAddr>().ok())
        {
            return last.to_string();
        }
    }

    peer.map(|ip| ip.to_string())
        .unwrap_or_else(|| "unknown".into())
}

fn rate_headers(response: &mut Response, decision: Decision) {
    let headers = response.headers_mut();
    let mut set = |name: &'static str, value: String| {
        // A route-level limiter (`/quests`, `/auth`, downloads) runs inside
        // the global one and Express lets it overwrite the general headers.
        if headers.contains_key(name) {
            return;
        }
        if let Ok(value) = HeaderValue::from_str(&value) {
            headers.insert(HeaderName::from_static(name), value);
        }
    };
    set("ratelimit-limit", decision.limit.to_string());
    set("ratelimit-remaining", decision.remaining.to_string());
    set("ratelimit-reset", decision.reset_secs.to_string());
    set(
        "ratelimit-policy",
        format!("{};w={}", decision.limit, decision.window_secs),
    );
}

pub(crate) fn too_many(message: &str, decision: Decision) -> Response {
    let mut response = (
        StatusCode::TOO_MANY_REQUESTS,
        Json(json!({ "error": message })),
    )
        .into_response();
    rate_headers(&mut response, decision);
    if let Ok(value) = HeaderValue::from_str(&decision.reset_secs.to_string()) {
        response
            .headers_mut()
            .insert(HeaderName::from_static("retry-after"), value);
    }
    response
}

/// Express rejects malformed percent-escapes in route parameters before the
/// handler runs (`decodeURIComponent` → URIError). Axum leaves the raw segment
/// intact, so reproduce the router-level 400 here, after routing decided that
/// the path is a parameterised route.
pub async fn validate_path_params(req: Request, next: Next) -> Response {
    if let Some(matched) = req.extensions().get::<axum::extract::MatchedPath>() {
        if matched.as_str().contains('{') {
            for segment in req.uri().path().split('/') {
                if !segment.is_empty() && !percent_decodes(segment) {
                    let message = format!("Failed to decode param '{segment}'");
                    let err = if crate::error::is_production() {
                        crate::error::ApiError::bad_request("Произошла ошибка. Попробуйте позже.")
                    } else {
                        crate::error::ApiError::bad_request(message.clone()).with_original(message)
                    };
                    return err.into_response();
                }
            }
        }
    }
    next.run(req).await
}

/// True when percent escapes form valid UTF-8 (what `decodeURIComponent`
/// accepts). Literal characters pass through untouched.
fn percent_decodes(raw: &str) -> bool {
    let bytes = raw.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return false;
            }
            let hex = |b: u8| (b as char).to_digit(16);
            let Some(hi) = hex(bytes[i + 1]) else {
                return false;
            };
            let Some(lo) = hex(bytes[i + 2]) else {
                return false;
            };
            decoded.push((hi * 16 + lo) as u8);
            i += 3;
        } else {
            decoded.push(bytes[i]);
            i += 1;
        }
    }
    std::str::from_utf8(&decoded).is_ok()
}

/// 1000 requests / 15 min / IP for everything.
pub async fn general_rate_limit(
    State(state): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Response {
    let key = format!("gen:{}", normalize_ip(&client_ip(&req)));
    let decision = state
        .limiter
        .hit(key, policy::GENERAL_MAX, policy::GENERAL_WINDOW);
    if !decision.allowed {
        return too_many(policy::GENERAL_MESSAGE, decision);
    }
    let mut response = next.run(req).await;
    rate_headers(&mut response, decision);
    response
}

/// 100 attempts / hour / IP for `/auth/*`.
pub async fn auth_rate_limit(
    State(state): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Response {
    let key = format!("auth:{}", normalize_ip(&client_ip(&req)));
    let decision = state
        .limiter
        .hit(key, policy::AUTH_MAX, policy::AUTH_WINDOW);
    if !decision.allowed {
        return too_many(policy::AUTH_MESSAGE, decision);
    }
    let mut response = next.run(req).await;
    rate_headers(&mut response, decision);
    response
}

/// `/quests`: 600 / 15 min with any Authorization header, 60 without.
pub async fn quest_rate_limit(
    State(state): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Response {
    let authorized = req.headers().contains_key(header::AUTHORIZATION);
    let max = if authorized {
        policy::QUEST_MAX_AUTH
    } else {
        policy::QUEST_MAX_ANON
    };
    let key = format!("quests:{}", normalize_ip(&client_ip(&req)));
    let decision = state.limiter.hit(key, max, policy::QUEST_WINDOW);
    if !decision.allowed {
        return too_many(policy::QUEST_MESSAGE, decision);
    }
    let mut response = next.run(req).await;
    rate_headers(&mut response, decision);
    response
}

/// Publication throttle: five per hour per author (or per IP when anonymous).
pub fn upload_allowed(state: &AppState, user_id: Option<&str>, ip: &str) -> (bool, Decision) {
    let key = match user_id {
        Some(id) => format!("pub_{id}"),
        None => format!("pub_ip_{}", normalize_ip(ip)),
    };
    let decision = state
        .limiter
        .hit(key, policy::UPLOAD_MAX, policy::UPLOAD_WINDOW);
    (decision.allowed, decision)
}

pub fn download_allowed(state: &AppState, user_id: Option<&str>, ip: &str) -> (bool, Decision) {
    let (key, max) = match user_id {
        Some(id) => (format!("dl_{id}"), policy::DOWNLOAD_MAX_AUTH),
        None => (
            format!("dl_{}", normalize_ip(ip)),
            policy::DOWNLOAD_MAX_ANON,
        ),
    };
    let decision = state.limiter.hit(key, max, policy::DOWNLOAD_WINDOW);
    (decision.allowed, decision)
}

pub fn download_rejection(decision: Decision) -> Response {
    too_many(policy::DOWNLOAD_MESSAGE, decision)
}

/// CORS: native clients send no Origin and are always allowed; browsers must
/// match `CORS_ORIGINS`. A refusal is the JSON the Node error handler produced.
pub async fn cors(State(state): State<Arc<AppState>>, req: Request, next: Next) -> Response {
    let origin = req
        .headers()
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);

    if !state.cfg.origin_allowed(origin.as_deref()) {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "CORS blocked" })),
        )
            .into_response();
    }

    let is_preflight = req.method() == Method::OPTIONS;

    let mut response = if is_preflight {
        StatusCode::NO_CONTENT.into_response()
    } else {
        next.run(req).await
    };

    // The `cors` package always varies on Origin, even without a request
    // Origin, and merges it into the existing Vary list.
    let headers = response.headers_mut();
    let has_origin = headers
        .get_all(header::VARY)
        .iter()
        .any(|v| v.to_str().map(|s| s.contains("Origin")).unwrap_or(false));
    if !has_origin {
        let existing = headers
            .get(header::VARY)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let value = match existing {
            Some(existing) => format!("Origin, {existing}"),
            None => "Origin".to_string(),
        };
        headers.remove(header::VARY);
        if let Ok(value) = HeaderValue::from_str(&value) {
            headers.insert(header::VARY, value);
        }
    }

    if let Some(origin) = origin {
        if let Ok(value) = HeaderValue::from_str(&origin) {
            headers.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, value);
        }
        if is_preflight {
            headers.insert(
                header::ACCESS_CONTROL_ALLOW_METHODS,
                HeaderValue::from_static("GET,POST,PUT,PATCH,DELETE"),
            );
            headers.insert(
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                HeaderValue::from_static("Content-Type,Authorization"),
            );
        }
    }
    response
}

/// The helmet header set the Node app enabled.
/// Express never answers 405: a path that exists for other methods falls
/// through to the next route and, if nothing matches, to the 404 page. axum
/// stops at the matched path, so translate its 405 into the same 404 page.
/// Express `router.use(authMiddleware)` mounted before any route: unknown
/// paths and wrong methods under the prefix answer 401/403 before Express's
/// 404 page. Handlers still extract the user themselves; the duplicate check
/// keeps this layer independent of handler signatures.
pub async fn auth_gate(
    State(state): State<Arc<AppState>>,
    request: Request,
    next: Next,
) -> Response {
    use axum::extract::FromRequestParts;

    let (mut parts, body) = request.into_parts();
    match crate::auth::AuthUser::from_request_parts(&mut parts, &state).await {
        Ok(_) => next.run(Request::from_parts(parts, body)).await,
        Err(err) => err.into_response(),
    }
}

/// `router.use(authMiddleware); router.use(adminAuth)` — same as
/// [`auth_gate`] plus the role check, for the whole `/admin` prefix.
pub async fn admin_gate(
    State(state): State<Arc<AppState>>,
    request: Request,
    next: Next,
) -> Response {
    use axum::extract::FromRequestParts;

    let (mut parts, body) = request.into_parts();
    match crate::auth::AdminUser::from_request_parts(&mut parts, &state).await {
        Ok(_) => next.run(Request::from_parts(parts, body)).await,
        Err(err) => err.into_response(),
    }
}

/// Express mounts `express.json` and `express.urlencoded` before every route,
/// so malformed or oversized bodies are rejected before auth and before the
/// route decides what to do. Parsing here (and caching the value for `Body`)
/// keeps that precedence.
pub async fn body_parser(
    State(_state): State<Arc<AppState>>,
    request: Request,
    next: Next,
) -> Response {
    let content_type = request
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    let is_json = crate::is_json_content_type(&content_type);
    let is_form = crate::is_urlencoded_content_type(&content_type);
    // CORS answers preflights before the parsers run, so OPTIONS never gets
    // here; GET and HEAD bodies are parsed exactly like POST (body-parser
    // has no method check).
    if !(is_json || is_form) {
        return next.run(request).await;
    }
    // `type-is.hasBody`: body-parser skips requests without Content-Length
    // or Transfer-Encoding entirely, including their charset check.
    if !request.headers().contains_key(header::CONTENT_LENGTH)
        && !request.headers().contains_key(header::TRANSFER_ENCODING)
    {
        return next.run(request).await;
    }

    let encoding = match crate::body_encoding(&content_type) {
        Ok(encoding) => encoding,
        Err(name) => {
            let message = format!("unsupported charset \"{name}\"");
            let err = if crate::error::is_production() {
                crate::error::ApiError::new(
                    StatusCode::UNSUPPORTED_MEDIA_TYPE,
                    "Произошла ошибка. Попробуйте позже.",
                )
            } else {
                crate::error::ApiError::new(StatusCode::UNSUPPORTED_MEDIA_TYPE, message.clone())
                    .with_original(message)
            };
            return err.into_response();
        }
    };

    let limit = crate::body_limit(request.uri().path(), &content_type);
    let (mut parts, body) = request.into_parts();
    let bytes = match axum::body::to_bytes(body, limit).await {
        Ok(bytes) => bytes,
        Err(_) => return crate::error::payload_too_large().into_response(),
    };

    let parsed = if bytes.is_empty() {
        json!({})
    } else if is_json {
        let text = crate::decode_body(&bytes, encoding);
        match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(value) if value.is_object() || value.is_array() => value,
            _ => return crate::error::ApiError::bad_request("Bad JSON format").into_response(),
        }
    } else {
        let raw = crate::decode_body(&bytes, encoding);
        crate::extractors::urlencoded_to_value(&raw)
    };

    parts
        .extensions
        .insert(crate::extractors::ParsedBody(parsed));
    next.run(Request::from_parts(parts, axum::body::Body::from(bytes)))
        .await
}

pub async fn method_fallthrough(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = request.method().clone();
    // Trailing slashes were trimmed before routing; Express prints the path
    // exactly as requested.
    let path = request
        .extensions()
        .get::<axum::extract::OriginalUri>()
        .map(|original| original.0.path().to_owned())
        .unwrap_or_else(|| request.uri().path().to_owned());
    let response = next.run(request).await;
    if response.status() == axum::http::StatusCode::METHOD_NOT_ALLOWED {
        return crate::express_not_found(&method, &path);
    }
    response
}

/// Express's `res.json` labels payloads `application/json; charset=utf-8`.
/// axum's `Json` omits the parameter; keep the header byte-compatible.
pub async fn json_charset(mut response: axum::response::Response) -> axum::response::Response {
    use axum::http::header;
    let is_bare_json = response
        .headers()
        .get(header::CONTENT_TYPE)
        .map(|v| v.as_bytes() == b"application/json")
        .unwrap_or(false);
    if is_bare_json {
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            header::HeaderValue::from_static("application/json; charset=utf-8"),
        );
    }
    response
}

pub async fn security_headers(req: Request, next: Next) -> Response {
    let mut response = next.run(req).await;
    let final_handler = response
        .extensions()
        .get::<crate::ExpressFinalHandler>()
        .is_some();
    let headers = response.headers_mut();
    let mut set = |name: &'static str, value: &'static str| {
        headers.insert(
            HeaderName::from_static(name),
            HeaderValue::from_static(value),
        );
    };
    set("x-content-type-options", "nosniff");
    set("x-frame-options", "SAMEORIGIN");
    set("x-dns-prefetch-control", "off");
    set("x-download-options", "noopen");
    set("x-permitted-cross-domain-policies", "none");
    set("x-xss-protection", "0");
    set("referrer-policy", "no-referrer");
    set("origin-agent-cluster", "?1");
    set("cross-origin-opener-policy", "same-origin");
    set(
        "strict-transport-security",
        "max-age=31536000; includeSubDomains",
    );
    set(
        "content-security-policy",
        if final_handler {
            "default-src 'none'"
        } else {
            "default-src 'self';script-src 'self';style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;font-src 'self' https://fonts.gstatic.com;img-src 'self' data: https:;connect-src 'self' https:;base-uri 'self';form-action 'self';frame-ancestors 'self';object-src 'none';script-src-attr 'none';upgrade-insecure-requests"
        },
    );
    response
}

/// `/uploads` refuses markup extensions even when the file exists on disk.
pub async fn uploads_guard(req: Request, next: Next) -> Response {
    let path = req.uri().path().to_ascii_lowercase();
    if [".html", ".htm", ".js", ".mjs", ".svg", ".xml"]
        .iter()
        .any(|ext| path.ends_with(ext))
    {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "Forbidden file type" })),
        )
            .into_response();
    }
    next.run(req).await
}
/// Request-part extractor wrapper so handlers can key rate limits by client IP
/// without taking the whole `Request`.
pub struct ClientIp(pub String);

impl axum::extract::FromRequestParts<Arc<AppState>> for ClientIp {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(
        parts: &mut axum::http::request::Parts,
        _state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let peer = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|info| info.0.ip());
        let loopback = peer.map(|ip| ip.is_loopback()).unwrap_or(false);
        let ip = if loopback {
            parts
                .headers
                .get("x-real-ip")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<IpAddr>().ok())
                .map(|ip| ip.to_string())
                .or_else(|| {
                    parts
                        .headers
                        .get("x-forwarded-for")
                        .and_then(|v| v.to_str().ok())
                        .and_then(|v| v.split(',').next())
                        .and_then(|v| v.trim().parse::<IpAddr>().ok())
                        .map(|ip| ip.to_string())
                })
                .unwrap_or_else(|| {
                    peer.map(|ip| ip.to_string())
                        .unwrap_or_else(|| "unknown".into())
                })
        } else {
            peer.map(|ip| ip.to_string())
                .unwrap_or_else(|| "unknown".into())
        };
        Ok(ClientIp(ip))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_decoding_rejects_invalid_escapes_and_utf8() {
        assert!(percent_decodes("audit-forum"));
        assert!(percent_decodes("%D0%BA%D0%B2%D0%B5%D1%81%D1%82"));
        assert!(!percent_decodes("audit%ZZ"));
        assert!(!percent_decodes("%E0%A4%A"));
        assert!(!percent_decodes("a%"));
        assert!(!percent_decodes("%2"));
    }

    #[test]
    fn route_limiter_headers_win_over_general() {
        let mut response = Response::new(axum::body::Body::empty());
        response.headers_mut().insert(
            HeaderName::from_static("ratelimit-limit"),
            HeaderValue::from_static("60"),
        );
        rate_headers(
            &mut response,
            Decision {
                allowed: true,
                limit: 1000,
                remaining: 999,
                reset_secs: 10,
                window_secs: 900,
            },
        );
        assert_eq!(
            response
                .headers()
                .get("ratelimit-limit")
                .and_then(|v| v.to_str().ok()),
            Some("60")
        );
        assert_eq!(
            response
                .headers()
                .get("ratelimit-policy")
                .and_then(|v| v.to_str().ok()),
            Some("1000;w=900")
        );
    }
}
