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
use axum::http::StatusCode;
use axum::middleware as mw;
use axum::routing::get;
use socketioxide::SocketIo;
use tower_http::compression::CompressionLayer;
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

    let (socket_layer, io) = sockets::setup(&state);
    let _ = state.io.set(io.clone());

    let uploads = Router::new()
        .fallback_service(ServeDir::new(state.cfg.public_dir.join("uploads")))
        .layer(mw::from_fn(middleware::uploads_guard));

    let auth_routes = routes::auth::router().layer(mw::from_fn_with_state(
        state.clone(),
        middleware::auth_rate_limit,
    ));

    let quests = routes::quests::router().layer(mw::from_fn_with_state(
        state.clone(),
        middleware::quest_rate_limit,
    ));

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
            ServeDir::new(state.cfg.public_dir.join("quests")),
        )
        .nest_service(
            "/.well-known",
            ServeDir::new(state.cfg.public_dir.join(".well-known")),
        )
        .nest("/auth", auth_routes)
        .nest("/quests", quests)
        .nest("/profiles", routes::profiles::router())
        .nest("/admin", routes::admin::router())
        .nest("/share", routes::share::router())
        .nest("/reports", routes::reports::router())
        .nest("/notifications", routes::notifications::router())
        .nest("/api/author-walls", routes::author_wall::router())
        .nest("/api/community", routes::community::router())
        .nest("/api/messages", routes::messages::router())
        .nest("/api/forums", routes::forums::router())
        .nest("/music", routes::music::router())
        .nest("/assets", routes::assets::router())
        .nest("/cloud-sync", routes::cloud_sync::router())
        .merge(routes::router())
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
        .layer(mw::from_fn_with_state(
            state.clone(),
            middleware::general_rate_limit,
        ))
        .layer(axum::middleware::map_response(middleware::json_charset))
        .layer(CompressionLayer::new())
        .layer(mw::from_fn_with_state(state.clone(), middleware::cors))
        .layer(mw::from_fn(middleware::security_headers))
        .layer(mw::from_fn(middleware::method_fallthrough))
        .layer(socket_layer);

    Ok((app, io))
}

/// Body limits from `app.ts`: 1 MB for JSON, 5 MB for cloud-sync payloads.
pub(crate) fn json_body_limit(req: &axum::extract::Request) -> usize {
    let path = req.uri().path();
    if path == "/cloud-sync" || path.starts_with("/cloud-sync/") {
        5 * 1024 * 1024
    } else {
        1024 * 1024
    }
}

/// Express's default 404 page (finalhandler), reproduced byte for byte so
/// unmatched routes do not change content type or body shape.
pub(crate) fn express_not_found(
    method: &axum::http::Method,
    path: &str,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let body = format!(
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Error</title>\n</head>\n<body>\n<pre>Cannot {method} {path}</pre>\n</body>\n</html>\n"
    );
    (
        StatusCode::NOT_FOUND,
        [(axum::http::header::CONTENT_TYPE, "text/html; charset=utf-8")],
        body,
    )
        .into_response()
}

async fn not_found(req: axum::extract::Request) -> axum::response::Response {
    express_not_found(req.method(), req.uri().path())
}

/// `MethodRouter::fallback` for paths where Node would fall through to a later
/// route and end in Express's 404 instead of axum's 405.
pub(crate) async fn method_not_found(
    method: axum::http::Method,
    uri: axum::http::Uri,
) -> axum::response::Response {
    express_not_found(&method, uri.path())
}

async fn debug_routes_gate(
    req: axum::extract::Request,
    next: mw::Next,
) -> axum::response::Response {
    if req.uri().path() == "/test-ip" {
        use axum::response::IntoResponse;
        return (StatusCode::NOT_FOUND, "Not Found").into_response();
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
    }
}
