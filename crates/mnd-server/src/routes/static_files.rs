//! Static files and the guarded quest download. Port of the static block in
//! `app.ts` plus the `/.well-known/security.txt` and `/robots.txt` routes.

use std::sync::LazyLock;

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use regex::Regex;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::OptionalAuth;
use crate::error::ApiResult;
use crate::services::visibility::can_see_unpublished;
use crate::state::AppState;

static QUEST_FILE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.mnd$").unwrap()
});

pub const SECURITY_TXT: &str = "Contact: https://github.com/IILLUMINATION/meander-public/security/advisories/new\n\
Expires: 2027-11-07T00:00:00.000Z\n\
Preferred-Languages: ru, en\n\
Canonical: https://backend.meander.sbs/.well-known/security.txt\n";

pub const ROBOTS_TXT: &str = "User-agent: *\nDisallow: /\nAllow: /share/\n";

pub async fn robots() -> Response {
    text_response(ROBOTS_TXT)
}

pub async fn security_txt() -> Response {
    text_response(SECURITY_TXT)
}

fn text_response(body: &'static str) -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
        body,
    )
        .into_response()
}

fn not_found() -> Response {
    (
        StatusCode::NOT_FOUND,
        axum::Json(serde_json::json!({"error": "Not found"})),
    )
        .into_response()
}

/// `/static/downloads/:fileName`
///
/// The file name is `<questId>.mnd`, so one id was enough to download someone
/// else's rejected quest. Publication is checked here, the author and admin by
/// role from the database. On production nginx serves the bytes through
/// `X-Accel-Redirect`; without the prefix the file is sent directly.
pub async fn downloads(
    State(state): State<Arc<AppState>>,
    Path(file_name): Path<String>,
    auth: OptionalAuth,
    ip: crate::middleware::ClientIp,
) -> ApiResult {
    if !QUEST_FILE.is_match(&file_name) {
        return Ok(not_found());
    }

    let (allowed, decision) = crate::middleware::download_allowed(
        &state,
        auth.id().map(|id| id.to_string()).as_deref(),
        &ip.0,
    );
    if !allowed {
        return Ok(crate::middleware::download_rejection(decision));
    }

    let quest_id = Uuid::parse_str(&file_name[..36]).ok();
    let Some(quest_id) = quest_id else {
        return Ok(not_found());
    };

    use sqlx::Row;
    let row = sqlx::query("SELECT status, author_id FROM quests WHERE id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await?;
    let Some(row) = row else {
        return Ok(not_found());
    };

    let status = crate::json::text_col(&row, "status");
    let author_id: Option<Uuid> = row.try_get("author_id").ok().flatten();
    let published = status.as_deref() == Some("published");
    if !published && !can_see_unpublished(&state, auth.id(), author_id).await {
        return Ok(not_found());
    }

    let path = state.cfg.public_dir.join("quests_files").join(&file_name);
    if !path.exists() {
        return Ok(not_found());
    }

    let prefix = if published {
        state.cfg.quest_xaccel_prefix.as_str()
    } else {
        state.cfg.quest_xaccel_private_prefix.as_str()
    };
    if !prefix.is_empty() {
        // nginx sets cache headers on the internal location; a second
        // Cache-Control here would be a second source of truth.
        let mut response = Response::new(Body::empty());
        *response.status_mut() = StatusCode::OK;
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            header::HeaderValue::from_static("application/octet-stream"),
        );
        if let Ok(value) = header::HeaderValue::from_str(&format!("{prefix}/{file_name}")) {
            response
                .headers_mut()
                .insert(header::HeaderName::from_static("x-accel-redirect"), value);
        }
        return Ok(response);
    }

    let bytes = tokio::fs::read(&path).await.map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            crate::error::ApiError::not_found("Not found")
        } else {
            crate::error::ApiError::internal("Failed to serve quest file")
        }
    })?;

    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/octet-stream".to_string()),
            (
                header::CACHE_CONTROL,
                if published {
                    "public, max-age=86400".to_string()
                } else {
                    "no-store".to_string()
                },
            ),
            (
                header::HeaderName::from_static("cross-origin-resource-policy"),
                "same-origin".to_string(),
            ),
        ],
        Body::from(bytes),
    )
        .into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_uuid_mnd_names_are_served() {
        assert!(QUEST_FILE.is_match("6f1d2a4e-0b4d-4f2a-9d5f-0b1b2c3d4e5f.mnd"));
        assert!(!QUEST_FILE.is_match("../etc/passwd"));
        assert!(!QUEST_FILE.is_match("6f1d2a4e-0b4d-4f2a-9d5f-0b1b2c3d4e5f.exe"));
        assert!(!QUEST_FILE.is_match("6f1d2a4e-0b4d-4f2a-9d5f-0b1b2c3d4e5"));
    }
}
