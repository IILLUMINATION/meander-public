//! HTTP routes, one module per Node router file.

pub mod admin;
pub mod app;
pub mod assets;
pub mod auth;
pub mod author_wall;
pub mod cloud_sync;
pub mod community;
pub mod forums;
pub mod messages;
pub mod music;
pub mod notifications;
pub mod profiles;
pub mod quests;
pub mod reports;
pub mod share;
pub mod static_files;

use std::sync::Arc;

use axum::Router;
use axum::routing::get;

use crate::middleware;
use crate::state::AppState;

/// Mounts that mirror `app.ts` one-for-one (paths and prefixes).
pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        // `app.use('/api/app', appRoutes)` and `app.use('/quests', ...)`.
        .nest("/api/app", app::router())
        // Public quests are throttled before reaching the router in app.ts;
        // the limiter is applied by the top-level assembly so it also covers
        // POST /quests.
        .route("/test-ip", get(test_ip))
}

async fn test_ip(req: axum::extract::Request) -> axum::Json<serde_json::Value> {
    let ip = middleware::client_ip(&req);
    let mut body = serde_json::json!({
        "ip": ip,
        "ips": [ip],
    });
    // `res.json` drops keys whose value is undefined, so the header key is
    // absent when the request had no X-Forwarded-For.
    if let Some(forwarded) = req
        .headers()
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
    {
        if let Some(object) = body.as_object_mut() {
            object.insert("headers".into(), serde_json::json!(forwarded));
        }
    }
    axum::Json(body)
}
