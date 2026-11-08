//! `/api/app` — partner banners and forced-update check. Port of `routes/app.ts`.

use std::sync::Arc;

use axum::Json;
use axum::extract::{Query, State};
use axum::http::header;
use axum::response::Response;
use axum::routing::get;
use axum::{Router, response::IntoResponse};
use serde_json::{Value, json};
use sqlx::Row;

use crate::error::{ApiError, ApiResult};
use crate::json::{parse_int, pg_row_to_json};
use crate::state::AppState;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/partner-banners", get(partner_banners))
        .route("/version/check", get(version_check))
}

/// Public list of active partner banners for the market. Cached 5 minutes on
/// the CDN, 1 minute in the browser. A database failure still answers 200 with
/// an empty list: the client has its own fallback.
async fn partner_banners(State(state): State<Arc<AppState>>) -> Response {
    let rows = sqlx::query(
        "SELECT id, title, subtitle, cta_text, url, image_url,
                icon, tint_color, slots, pinned, sort_order
           FROM partner_banners
          WHERE is_active = TRUE
          ORDER BY sort_order ASC, created_at ASC",
    )
    .fetch_all(&state.db)
    .await;

    let body = match rows {
        Ok(rows) => {
            let banners = rows
                .iter()
                .map(|row| {
                    let slots: Value = row
                        .try_get::<Option<Vec<String>>, _>("slots")
                        .ok()
                        .flatten()
                        .map(|v| json!(v))
                        .unwrap_or_else(|| json!([]));
                    json!({
                        "id": row.try_get::<Option<String>, _>("id").ok().flatten(),
                        "title": row.try_get::<Option<String>, _>("title").ok().flatten(),
                        "subtitle": row.try_get::<Option<String>, _>("subtitle").ok().flatten(),
                        "ctaText": row.try_get::<Option<String>, _>("cta_text").ok().flatten(),
                        "url": row.try_get::<Option<String>, _>("url").ok().flatten(),
                        "imageUrl": row.try_get::<Option<String>, _>("image_url").ok().flatten(),
                        "icon": row.try_get::<Option<String>, _>("icon").ok().flatten().unwrap_or_else(|| "campaign".into()),
                        "tintColor": row.try_get::<Option<String>, _>("tint_color").ok().flatten().unwrap_or_else(|| "#6750A4".into()),
                        "slots": if slots.is_array() { slots } else { json!([]) },
                        "pinned": row.try_get::<Option<bool>, _>("pinned").ok().flatten().unwrap_or(false),
                    })
                })
                .collect::<Vec<_>>();
            Json(Value::Array(banners)).into_response()
        }
        Err(err) => {
            tracing::error!(error = %err, "partner banners fetch error");
            Json(json!([])).into_response()
        }
    };

    let mut response = body;
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        header::HeaderValue::from_static("public, max-age=60, s-maxage=300"),
    );
    response
}

async fn version_check(
    State(state): State<Arc<AppState>>,
    Query(query): Query<std::collections::HashMap<String, String>>,
) -> ApiResult {
    let build_number = parse_int(query.get("build_number").map(String::as_str));
    let platform = query
        .get("platform")
        .filter(|p| !p.is_empty())
        .cloned()
        .unwrap_or_else(|| "all".into());

    let Some(build_number) = build_number else {
        return Err(ApiError::bad_request("build_number is required"));
    };

    let row = sqlx::query(
        "SELECT version, build_number, is_critical, download_url, changelog
           FROM app_versions
          WHERE platform IN ($1, 'all')
            AND is_active = true
            AND build_number > $2
          ORDER BY build_number DESC
          LIMIT 1",
    )
    .bind(&platform)
    .bind(build_number)
    .fetch_optional(&state.db)
    .await;

    match row {
        Ok(None) => Ok(Json(json!({"hasUpdate": false})).into_response()),
        Ok(Some(row)) => {
            let value = pg_row_to_json(&row);
            Ok(Json(json!({
                "hasUpdate": true,
                "isCritical": value.get("is_critical").cloned().unwrap_or(Value::Bool(false)),
                "latestVersion": value.get("version").cloned().unwrap_or(Value::Null),
                "latestBuild": value.get("build_number").cloned().unwrap_or(Value::Null),
                "downloadUrl": value.get("download_url").and_then(Value::as_str).unwrap_or(""),
                "changelog": value.get("changelog").and_then(Value::as_str).unwrap_or(""),
            }))
            .into_response())
        }
        Err(err) => {
            tracing::error!(error = %err, "version check error");
            Ok(Json(json!({"hasUpdate": false})).into_response())
        }
    }
}
