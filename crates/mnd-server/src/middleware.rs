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
        if let Some(first) = req
            .headers()
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(',').next())
            .and_then(|v| v.trim().parse::<IpAddr>().ok())
        {
            return first.to_string();
        }
    }

    peer.map(|ip| ip.to_string())
        .unwrap_or_else(|| "unknown".into())
}

fn rate_headers(response: &mut Response, decision: Decision) {
    let set = |response: &mut Response, name: &'static str, value: String| {
        if let Ok(value) = HeaderValue::from_str(&value) {
            response
                .headers_mut()
                .insert(HeaderName::from_static(name), value);
        }
    };
    set(response, "ratelimit-limit", decision.limit.to_string());
    set(
        response,
        "ratelimit-remaining",
        decision.remaining.to_string(),
    );
    set(response, "ratelimit-reset", decision.reset_secs.to_string());
}

pub(crate) fn too_many(message: &str, decision: Decision) -> Response {
    let mut response = (
        StatusCode::TOO_MANY_REQUESTS,
        Json(json!({ "error": message })),
    )
        .into_response();
    rate_headers(&mut response, decision);
    response
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
    let requested_headers = req
        .headers()
        .get(header::ACCESS_CONTROL_REQUEST_HEADERS)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);

    let mut response = if is_preflight {
        StatusCode::NO_CONTENT.into_response()
    } else {
        next.run(req).await
    };

    let headers = response.headers_mut();
    if let Some(origin) = origin {
        if let Ok(value) = HeaderValue::from_str(&origin) {
            headers.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, value);
        }
        headers.append(header::VARY, HeaderValue::from_static("Origin"));
        headers.insert(
            header::ACCESS_CONTROL_ALLOW_METHODS,
            HeaderValue::from_static("GET,HEAD,PUT,PATCH,POST,DELETE"),
        );
        if let Some(requested) = requested_headers {
            if let Ok(value) = HeaderValue::from_str(&requested) {
                headers.insert(header::ACCESS_CONTROL_ALLOW_HEADERS, value);
            }
        } else {
            headers.insert(
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                HeaderValue::from_static("Content-Type, Authorization"),
            );
        }
    }
    response
}

/// The helmet header set the Node app enabled.
/// Express never answers 405: a path that exists for other methods falls
/// through to the next route and, if nothing matches, to the 404 page. axum
/// stops at the matched path, so translate its 405 into the same 404 page.
pub async fn method_fallthrough(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
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
    set("origin-agent-cluster", "?=0");
    set("cross-origin-opener-policy", "same-origin");
    set(
        "strict-transport-security",
        "max-age=15552000; includeSubDomains",
    );
    set(
        "content-security-policy",
        "default-src 'self';script-src 'self';style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;font-src 'self' https://fonts.gstatic.com;img-src 'self' data: https:;connect-src 'self' https:",
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
