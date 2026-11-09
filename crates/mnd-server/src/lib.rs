//! Meander backend, Rust edition — drop-in replacement for the Node/Express
//! server in `backend/`.
//!
//! Wire compatibility is the hard requirement: the Flutter apps and web players
//! are already shipped, so paths, status codes, JSON field names and error texts
//! follow the Node routes exactly. Anything that cannot be reproduced is called
//! out in the module that deviates.

pub mod auth;
pub mod config;
pub mod cron;
pub mod cron_jobs;
pub mod error;
pub mod extractors;
pub mod json;
pub mod middleware;
pub mod ratelimit;
pub mod routes;
pub mod services;
pub mod sockets;
pub mod state;

use std::sync::Arc;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::http::{Request, StatusCode, Uri};
use axum::middleware as mw;
use axum::routing::get;
use socketioxide::SocketIo;
use tower_http::compression::CompressionLayer;
use tower_http::compression::predicate::SizeAbove;
use tower_http::services::ServeDir;

use crate::config::Config;
use crate::state::AppState;

/// Builds the full application. The returned `SocketIo` is already stored in
/// the state; it is returned for tests that need to inspect namespaces.
pub async fn build_app(state: Arc<AppState>) -> anyhow::Result<(Router, SocketIo)> {
    for dir in [
        "uploads",
        "quests_files",
        "music_files",
        "assets_files",
        ".well-known",
    ] {
        std::fs::create_dir_all(state.cfg.public_dir.join(dir))?;
    }

    let uploads = Router::new()
        .fallback_service(
            ServeDir::new(state.cfg.public_dir.join("uploads")).not_found_service(
                tower::service_fn(|req| async move {
                    Ok::<_, std::convert::Infallible>(express_fallback(req).await)
                }),
            ),
        )
        .layer(mw::from_fn(middleware::uploads_guard));

    let auth_routes = routes::auth::router().layer(mw::from_fn_with_state(
        state.clone(),
        middleware::auth_rate_limit,
    ));

    let quests = routes::quests::router(state.clone());

    let admin_routes =
        routes::admin::router()
            .fallback(express_fallback)
            .layer(mw::from_fn_with_state(
                state.clone(),
                middleware::admin_gate,
            ));
    let cloud_sync_routes = routes::cloud_sync::router()
        .fallback(express_fallback)
        .layer(mw::from_fn_with_state(state.clone(), middleware::auth_gate));

    let mut app = Router::new()
        .route("/", get(|| async { StatusCode::NO_CONTENT }))
        .route("/robots.txt", get(routes::static_files::robots))
        .route(
            "/.well-known/security.txt",
            get(routes::static_files::security_txt),
        )
        .route(
            "/static/downloads/{file_name}",
            get(routes::static_files::downloads),
        )
        .nest_service("/uploads", uploads)
        .nest_service(
            "/static/quests",
            ServeDir::new(state.cfg.public_dir.join("quests")).not_found_service(
                tower::service_fn(|req| async move {
                    Ok::<_, std::convert::Infallible>(express_fallback(req).await)
                }),
            ),
        )
        .nest_service(
            "/.well-known",
            ServeDir::new(state.cfg.public_dir.join(".well-known")).not_found_service(
                tower::service_fn(|req| async move {
                    Ok::<_, std::convert::Infallible>(express_fallback(req).await)
                }),
            ),
        )
        .nest("/auth", auth_routes)
        .nest("/quests", quests)
        .nest("/profiles", routes::profiles::router())
        .nest("/admin", admin_routes)
        .nest("/share", routes::share::router())
        .nest("/reports", routes::reports::router())
        .nest("/notifications", routes::notifications::router())
        .nest("/api/author-walls", routes::author_wall::router())
        .nest("/api/community", routes::community::router())
        .nest("/api/messages", routes::messages::router())
        .nest("/api/forums", routes::forums::router())
        .nest("/music", routes::music::router())
        .nest("/assets", routes::assets::router())
        .nest("/cloud-sync", cloud_sync_routes)
        .merge(routes::router())
        // Runs only for routes that matched; Express decodes route params
        // before the handler, so malformed escapes answer 400.
        .route_layer(mw::from_fn(middleware::validate_path_params))
        // One megabyte for ordinary JSON, matching `express.json({limit:'1mb'})`.
        // Upload and cloud-sync routers raise it on their own routes.
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .fallback(not_found)
        .with_state(state.clone());

    if state.cfg.is_production || !state.cfg.enable_debug_routes {
        // `/test-ip` is mounted by `routes::router` unconditionally; the Node
        // server only exposed it in this configuration, so keep the gate here.
        app = app.layer(mw::from_fn(debug_routes_gate));
    }

    let app = app
        .layer(CompressionLayer::new().compress_when(SizeAbove::new(1024)))
        .layer(mw::from_fn_with_state(
            state.clone(),
            middleware::body_parser,
        ))
        .layer(mw::from_fn_with_state(
            state.clone(),
            middleware::general_rate_limit,
        ))
        .layer(mw::from_fn_with_state(state.clone(), middleware::cors))
        .layer(mw::from_fn(middleware::security_headers))
        .layer(mw::from_fn(middleware::method_fallthrough))
        .layer(axum::middleware::map_response(middleware::json_charset))
        // Outermost HTTP layer: logs the final status (including errors added
        // by inner middleware) and echoes the request id for nginx.
        .layer(mw::from_fn_with_state(
            state.clone(),
            middleware::access_log,
        ));

    // Express is non-strict about a *single* trailing slash (`/music/` ===
    // `/music`) but rejects `/music//`. Normalise before routing; Socket.IO
    // requests are handled by the socket service first, so `/socket.io/`
    // keeps its slash.
    let normalized = TrimExpressSlash(app);
    let (socket_service, io) = sockets::setup_with_inner(&state, normalized);
    let _ = state.io.set(io.clone());
    let app = Router::new().fallback_service(socket_service);

    Ok((app, io))
}

/// Express path normalisation: collapse one duplicated slash right after a
/// mount and remove a single trailing slash. Leading and inner duplicates are
/// left alone (Express rejects them). Returns `None` when nothing changes.
fn normalize_express_path(original: &str) -> Option<String> {
    // Express routers match an inner path that starts with one extra slash
    // (`/quests//genres` === `/quests/genres`), but two extra slashes lose.
    let collapsed = EXPRESS_MOUNTS.iter().find_map(|mount| {
        let rest = original.strip_prefix(mount)?;
        if rest.starts_with("//") && !rest.starts_with("///") {
            Some(format!("{mount}{}", &rest[1..]))
        } else {
            None
        }
    });
    let mut path: Option<String> = collapsed;
    let current = path.as_deref().unwrap_or(original);
    if current.len() > 1 && current.ends_with('/') && !current.trim_matches('/').is_empty() {
        path = Some(current[..current.len() - 1].to_string());
    }
    path
}

/// Routers where Express tolerates one extra slash between the mount path
/// and the inner route. Routers with a path-less middleware in the mount
/// chain (`/auth`) or literal multi-segment mounts (`/api/app`) do not.
const EXPRESS_MOUNTS: [&str; 9] = [
    "/api/author-walls",
    "/api/forums",
    "/api/messages",
    "/notifications",
    "/profiles",
    "/quests",
    "/assets",
    "/music",
    "/share",
];

/// Removes one trailing slash (Express `strict: false`). Unlike
/// `tower_http::normalize_path` it never touches leading or inner slashes,
/// which Express does not collapse either.
#[derive(Clone)]
struct TrimExpressSlash<S>(S);

impl<S, B> tower::Service<Request<B>> for TrimExpressSlash<S>
where
    S: tower::Service<Request<B>>,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = S::Future;

    fn poll_ready(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        self.0.poll_ready(cx)
    }

    fn call(&mut self, mut req: Request<B>) -> Self::Future {
        if let Some(new_path) = normalize_express_path(req.uri().path()) {
            let mut parts = req.uri().clone().into_parts();
            let path_and_query = match parts.path_and_query.as_ref().and_then(|pq| pq.query()) {
                Some(query) => format!("{new_path}?{query}"),
                None => new_path,
            };
            if let Ok(pq) = path_and_query.parse() {
                parts.path_and_query = Some(pq);
                if let Ok(uri) = Uri::from_parts(parts) {
                    *req.uri_mut() = uri;
                }
            }
        }
        self.0.call(req)
    }
}

/// Body limits from `app.ts`: 1 MB for JSON, 5 MB for cloud-sync payloads.
/// Media type from a `Content-Type` header value (parameters stripped,
/// compared case-insensitively like `type-is`).
pub(crate) fn media_type(value: &str) -> &str {
    value.split(';').next().unwrap_or("").trim()
}

pub(crate) fn is_json_content_type(value: &str) -> bool {
    media_type(value).eq_ignore_ascii_case("application/json")
}

pub(crate) fn is_urlencoded_content_type(value: &str) -> bool {
    media_type(value).eq_ignore_ascii_case("application/x-www-form-urlencoded")
}

pub(crate) fn is_multipart_content_type(value: &str) -> bool {
    media_type(value).eq_ignore_ascii_case("multipart/form-data")
}

/// `charset` parameter of a `Content-Type` value, if present.
pub(crate) fn charset_param(value: &str) -> Option<String> {
    value.split(';').skip(1).find_map(|param| {
        let (name, value) = param.split_once('=')?;
        name.trim()
            .eq_ignore_ascii_case("charset")
            .then(|| value.trim().trim_matches('"').to_string())
    })
}

/// Body encodings `body-parser` accepts (`iconv-lite` names).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BodyEncoding {
    Utf8,
    Utf16Le,
    Utf16Be,
    /// `utf-16`: BOM decides, little-endian otherwise.
    Utf16,
}

/// `Ok(None)` when the charset parameter is absent (UTF-8 default), `Err`
/// with the upper-cased name when body-parser would answer 415.
pub(crate) fn body_encoding(value: &str) -> Result<Option<BodyEncoding>, String> {
    let Some(name) = charset_param(value) else {
        return Ok(None);
    };
    let encoding = if name.eq_ignore_ascii_case("utf-8") {
        BodyEncoding::Utf8
    } else if name.eq_ignore_ascii_case("utf-16") {
        BodyEncoding::Utf16
    } else if name.eq_ignore_ascii_case("utf-16le") {
        BodyEncoding::Utf16Le
    } else if name.eq_ignore_ascii_case("utf-16be") {
        BodyEncoding::Utf16Be
    } else {
        return Err(name.to_ascii_uppercase());
    };
    Ok(Some(encoding))
}

pub(crate) fn decode_body(bytes: &[u8], encoding: Option<BodyEncoding>) -> String {
    let decode_utf16 = |little: bool, strip_bom: bool| -> String {
        let units: Vec<u16> = bytes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| {
                if little {
                    u16::from_le_bytes([pair[0], pair[1]])
                } else {
                    u16::from_be_bytes([pair[0], pair[1]])
                }
            })
            .collect();
        let units = if strip_bom && units.first() == Some(&0xFEFF) {
            &units[1..]
        } else {
            &units[..]
        };
        String::from_utf16_lossy(units)
    };
    match encoding {
        None | Some(BodyEncoding::Utf8) => String::from_utf8_lossy(bytes).into_owned(),
        Some(BodyEncoding::Utf16Le) => decode_utf16(true, true),
        Some(BodyEncoding::Utf16Be) => decode_utf16(false, true),
        Some(BodyEncoding::Utf16) => {
            if bytes.starts_with(&[0xFF, 0xFE]) {
                // BOM included in the first code unit and stripped above.
                decode_utf16(true, true)
            } else if bytes.starts_with(&[0xFE, 0xFF]) {
                decode_utf16(false, true)
            } else {
                decode_utf16(true, false)
            }
        }
    }
}

pub(crate) fn json_body_limit(req: &axum::extract::Request) -> usize {
    body_limit(req.uri().path(), "application/json")
}

/// Limits from `app.ts`: JSON 1 MB (5 MB for cloud-sync), urlencoded 100 KB
/// (5 MB for cloud-sync).
pub(crate) fn body_limit(path: &str, content_type: &str) -> usize {
    let cloud_sync = path == "/cloud-sync" || path.starts_with("/cloud-sync/");
    if is_json_content_type(content_type) {
        if cloud_sync {
            5 * 1024 * 1024
        } else {
            1024 * 1024
        }
    } else if cloud_sync {
        5 * 1024 * 1024
    } else {
        100 * 1024
    }
}

/// Express's default 404 page (finalhandler), reproduced byte for byte so
/// unmatched routes do not change content type or body shape.
/// Marks a response produced by Express's `finalhandler` (HTML 404), whose
/// CSP is `default-src 'none'` instead of helmet's app policy.
#[derive(Clone, Copy)]
pub struct ExpressFinalHandler;

pub(crate) fn express_not_found(
    method: &axum::http::Method,
    path: &str,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let body = format!(
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Error</title>\n</head>\n<body>\n<pre>Cannot {method} {path}</pre>\n</body>\n</html>\n"
    );
    let mut response = (
        StatusCode::NOT_FOUND,
        [(axum::http::header::CONTENT_TYPE, "text/html; charset=utf-8")],
        body,
    )
        .into_response();
    response.extensions_mut().insert(ExpressFinalHandler);
    response
}

async fn not_found(req: axum::extract::Request) -> axum::response::Response {
    express_fallback(req).await
}

pub(crate) async fn express_fallback(req: axum::extract::Request) -> axum::response::Response {
    // Nested routers see the path with their prefix stripped; Express's
    // finalhandler prints the path the client requested.
    let path = req
        .extensions()
        .get::<axum::extract::OriginalUri>()
        .map(|original| original.0.path())
        .unwrap_or_else(|| req.uri().path());
    express_not_found(req.method(), path)
}

/// `MethodRouter::fallback` for paths where Node would fall through to a later
/// route and end in Express's 404 instead of axum's 405.
pub(crate) async fn method_not_found(req: axum::extract::Request) -> axum::response::Response {
    express_fallback(req).await
}

async fn debug_routes_gate(
    req: axum::extract::Request,
    next: mw::Next,
) -> axum::response::Response {
    if req.uri().path() == "/test-ip" {
        let path = req
            .extensions()
            .get::<axum::extract::OriginalUri>()
            .map(|original| original.0.path())
            .unwrap_or_else(|| req.uri().path());
        return express_not_found(req.method(), path);
    }
    next.run(req).await
}

/// Convenience for binaries and integration tests.
pub async fn from_env() -> anyhow::Result<(Router, SocketIo, Arc<AppState>)> {
    let cfg: Arc<Config> = Config::load();
    let state = AppState::new(cfg).await?;
    let (app, io) = build_app(state.clone()).await?;
    Ok((app, io, state))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::header;

    #[test]
    fn express_not_found_matches_finalhandler_headers() {
        let response = express_not_found(&axum::http::Method::PUT, "/profiles/me");
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert_eq!(
            response
                .headers()
                .get(header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok()),
            Some("text/html; charset=utf-8")
        );
        assert!(response.extensions().get::<ExpressFinalHandler>().is_some());
    }

    #[test]
    fn express_path_normalisation_matches_node() {
        let cases: &[(&str, Option<&str>)] = &[
            ("/quests/genres/", Some("/quests/genres")),
            ("/quests/genres", None),
            ("/quests/genres//", Some("/quests/genres/")),
            ("/quests//genres", Some("/quests/genres")),
            ("/quests///genres", None),
            ("/api/forums//audit-forum", Some("/api/forums/audit-forum")),
            ("/api/messages//threads", Some("/api/messages/threads")),
            ("/notifications//", Some("/notifications")),
            ("/assets//", Some("/assets")),
            ("/auth//google/token", None),
            ("/api/app//version", None),
            ("//quests/genres", None),
            ("//", None),
            ("/", None),
        ];
        for (input, expected) in cases {
            assert_eq!(
                normalize_express_path(input).as_deref(),
                *expected,
                "input {input}"
            );
        }
    }

    #[test]
    fn media_types_are_matched_exactly() {
        assert!(is_json_content_type("application/json"));
        assert!(is_json_content_type("Application/JSON; charset=utf-8"));
        assert!(is_json_content_type("application/json ; charset=UTF-8"));
        assert!(!is_json_content_type("application/json-patch+json"));
        assert!(!is_json_content_type("application/vnd.api+json"));
        assert!(is_urlencoded_content_type(
            "application/x-www-form-urlencoded; charset=utf-8"
        ));
        assert!(is_multipart_content_type("multipart/form-data; boundary=x"));
        assert!(!is_multipart_content_type("multipart/form-datax"));
        assert_eq!(
            charset_param("application/json; charset=UTF-8"),
            Some("UTF-8".into())
        );
        assert_eq!(
            charset_param("application/json; charset=\"utf-8\""),
            Some("utf-8".into())
        );
        assert_eq!(charset_param("application/json"), None);
    }

    #[test]
    fn charsets_mirror_body_parser() {
        assert!(matches!(
            body_encoding("application/json; charset=utf-8"),
            Ok(Some(BodyEncoding::Utf8))
        ));
        assert!(matches!(body_encoding("application/json"), Ok(None)));
        assert!(matches!(
            body_encoding("application/json; charset=utf-16"),
            Ok(Some(BodyEncoding::Utf16))
        ));
        assert!(matches!(
            body_encoding("application/json; charset=utf-16le"),
            Ok(Some(BodyEncoding::Utf16Le))
        ));
        assert!(matches!(
            body_encoding("application/json; charset=utf-16be"),
            Ok(Some(BodyEncoding::Utf16Be))
        ));
        assert_eq!(
            body_encoding("application/json; charset=utf8"),
            Err("UTF8".into())
        );
        assert_eq!(
            body_encoding("application/json; charset=latin1"),
            Err("LATIN1".into())
        );
    }

    #[test]
    fn utf16_bodies_decode_like_iconv() {
        let json = "{\"token\":\"x\"}";
        let le: Vec<u8> = json.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        let be: Vec<u8> = json.encode_utf16().flat_map(|u| u.to_be_bytes()).collect();
        assert_eq!(decode_body(&le, Some(BodyEncoding::Utf16Le)), json);
        assert_eq!(decode_body(&be, Some(BodyEncoding::Utf16Be)), json);
        let mut bom_le = vec![0xFF, 0xFE];
        bom_le.extend_from_slice(&le);
        assert_eq!(decode_body(&bom_le, Some(BodyEncoding::Utf16)), json);
        let mut bom_be = vec![0xFE, 0xFF];
        bom_be.extend_from_slice(&be);
        assert_eq!(decode_body(&bom_be, Some(BodyEncoding::Utf16)), json);
    }
}
