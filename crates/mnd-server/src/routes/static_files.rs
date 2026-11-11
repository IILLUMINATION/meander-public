//! Static files and the guarded quest download. Port of the static block in
//! `app.ts` plus the `/.well-known/security.txt` and `/robots.txt` routes.

use std::path::Path as FsPath;
use std::sync::LazyLock;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, Utc};
use regex::Regex;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;
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
Canonical: https://meander.illuminat.dev/.well-known/security.txt\n";

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

enum RangeSpec {
    Full,
    Partial(u64, u64),
    Unsatisfiable,
}

fn parse_range(raw: Option<&str>, len: u64) -> RangeSpec {
    let Some(raw) = raw else {
        return RangeSpec::Full;
    };
    let Some(spec) = raw.trim().strip_prefix("bytes=") else {
        return RangeSpec::Full;
    };
    // sendFile answers a single byte range; multi-range requests fall back to
    // the whole file.
    if spec.contains(',') {
        return RangeSpec::Full;
    }
    let spec = spec.trim();
    let Some((start, end)) = spec.split_once('-') else {
        return RangeSpec::Full;
    };
    if start.is_empty() {
        let Ok(suffix) = end.trim().parse::<u64>() else {
            return RangeSpec::Full;
        };
        if suffix == 0 || len == 0 {
            return RangeSpec::Unsatisfiable;
        }
        let start = len.saturating_sub(suffix);
        return RangeSpec::Partial(start, len - 1);
    }
    let Ok(start) = start.trim().parse::<u64>() else {
        return RangeSpec::Full;
    };
    if start >= len {
        return RangeSpec::Unsatisfiable;
    }
    let end = if end.trim().is_empty() {
        len - 1
    } else {
        let Ok(end) = end.trim().parse::<u64>() else {
            return RangeSpec::Full;
        };
        if end < start {
            return RangeSpec::Unsatisfiable;
        }
        end.min(len - 1)
    };
    RangeSpec::Partial(start, end)
}

fn http_date(time: SystemTime) -> String {
    let dt: DateTime<Utc> = time.into();
    dt.format("%a, %d %b %Y %H:%M:%S GMT").to_string()
}

/// Node's `fs.Stats.mtime` is a `Date`, whose millisecond field rounds the
/// filesystem nanoseconds to the nearest millisecond. `etag` hashes that
/// `Date`, so truncating here would produce a different ETag roughly half the
/// time.
fn mtime_millis(time: SystemTime) -> u128 {
    time.duration_since(UNIX_EPOCH)
        .map(|d| (d.as_nanos() + 500_000) / 1_000_000)
        .unwrap_or(0)
}

fn weak_eq(a: &str, b: &str) -> bool {
    a.trim().trim_start_matches("W/") == b.trim().trim_start_matches("W/")
}

fn if_none_match_matches(headers: &HeaderMap, etag: &str) -> bool {
    let Some(raw) = headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
    else {
        return false;
    };
    raw.split(',').any(|part| {
        let part = part.trim();
        part == "*" || weak_eq(part, etag)
    })
}

fn not_modified_since(headers: &HeaderMap, modified: SystemTime) -> bool {
    let Some(raw) = headers
        .get(header::IF_MODIFIED_SINCE)
        .and_then(|v| v.to_str().ok())
    else {
        return false;
    };
    let Ok(since) = DateTime::parse_from_rfc2822(raw) else {
        return false;
    };
    let modified: DateTime<Utc> = modified.into();
    modified.timestamp() <= since.timestamp()
}

fn if_range_matches(headers: &HeaderMap, etag: &str, last_modified: &str) -> bool {
    let Some(raw) = headers.get(header::IF_RANGE).and_then(|v| v.to_str().ok()) else {
        return true;
    };
    let raw = raw.trim();
    raw == last_modified || weak_eq(raw, etag)
}

/// Streams a file with the headers and byte-range/conditional semantics of
/// Express `res.sendFile` (which backs both quest download routes in Node).
pub async fn file_response(
    path: &FsPath,
    headers: &HeaderMap,
    cache_control: &str,
    not_found_message: &str,
    content_type: &'static str,
) -> ApiResult {
    let meta = tokio::fs::metadata(path).await.map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            crate::error::ApiError::not_found(not_found_message)
        } else {
            crate::error::ApiError::internal("Failed to serve quest file")
        }
    })?;
    let len = meta.len();
    let modified = meta.modified().unwrap_or(UNIX_EPOCH);
    let millis = mtime_millis(modified);
    let etag = format!("W/\"{len:x}-{millis:x}\"");
    let last_modified = http_date(modified);

    if if_none_match_matches(headers, &etag) || not_modified_since(headers, modified) {
        let mut response = Response::new(Body::empty());
        *response.status_mut() = StatusCode::NOT_MODIFIED;
        let out = response.headers_mut();
        out.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
        if let Ok(value) = HeaderValue::from_str(cache_control) {
            out.insert(header::CACHE_CONTROL, value);
        }
        if let Ok(value) = HeaderValue::from_str(&last_modified) {
            out.insert(header::LAST_MODIFIED, value);
        }
        if let Ok(value) = HeaderValue::from_str(&etag) {
            out.insert(header::ETAG, value);
        }
        return Ok(response);
    }

    let range = if if_range_matches(headers, &etag, &last_modified) {
        parse_range(
            headers.get(header::RANGE).and_then(|v| v.to_str().ok()),
            len,
        )
    } else {
        RangeSpec::Full
    };

    if matches!(range, RangeSpec::Unsatisfiable) {
        let mut response =
            crate::error::ApiError::new(StatusCode::RANGE_NOT_SATISFIABLE, "Range Not Satisfiable")
                .with_original("Range Not Satisfiable")
                .into_response();
        if let Ok(value) = HeaderValue::from_str(&format!("bytes */{len}")) {
            response.headers_mut().insert(header::CONTENT_RANGE, value);
        }
        let out = response.headers_mut();
        // `send` keeps the file's content type on the error response.
        if let Ok(value) = HeaderValue::from_str(&format!("{content_type}; charset=utf-8")) {
            out.insert(header::CONTENT_TYPE, value);
        }
        if let Ok(value) = HeaderValue::from_str(cache_control) {
            out.insert(header::CACHE_CONTROL, value);
        }
        if let Ok(value) = HeaderValue::from_str(&last_modified) {
            out.insert(header::LAST_MODIFIED, value);
        }
        out.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
        if let Ok(value) = HeaderValue::from_str(&etag) {
            out.insert(header::ETAG, value);
        }
        return Ok(response);
    }

    let (status, start, length) = match range {
        RangeSpec::Partial(start, end) => (StatusCode::PARTIAL_CONTENT, start, end - start + 1),
        RangeSpec::Full | RangeSpec::Unsatisfiable => (StatusCode::OK, 0, len),
    };

    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|_| crate::error::ApiError::internal("Failed to serve quest file"))?;
    if start > 0 {
        file.seek(std::io::SeekFrom::Start(start))
            .await
            .map_err(|_| crate::error::ApiError::internal("Failed to serve quest file"))?;
    }
    let stream = ReaderStream::new(file.take(length));
    let mut response = Response::new(Body::from_stream(stream));
    *response.status_mut() = status;
    let out = response.headers_mut();
    out.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    out.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    out.insert(header::CONTENT_LENGTH, HeaderValue::from(length));
    if let Ok(value) = HeaderValue::from_str(cache_control) {
        out.insert(header::CACHE_CONTROL, value);
    }
    if let Ok(value) = HeaderValue::from_str(&last_modified) {
        out.insert(header::LAST_MODIFIED, value);
    }
    if let Ok(value) = HeaderValue::from_str(&etag) {
        out.insert(header::ETAG, value);
    }
    if let RangeSpec::Partial(start, end) = range
        && let Ok(value) = HeaderValue::from_str(&format!("bytes {start}-{end}/{len}"))
    {
        out.insert(header::CONTENT_RANGE, value);
    }
    Ok(response)
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
    request: axum::extract::Request,
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

    let cache_control = if published {
        "public, max-age=86400"
    } else {
        "no-store"
    };
    let mut response = file_response(
        &path,
        request.headers(),
        cache_control,
        "Not found",
        "application/octet-stream",
    )
    .await?;
    response.headers_mut().insert(
        header::HeaderName::from_static("cross-origin-resource-policy"),
        HeaderValue::from_static("same-origin"),
    );
    Ok(response)
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

    #[test]
    fn etag_millis_round_like_node_date() {
        let at = |ns: u64| UNIX_EPOCH + std::time::Duration::from_nanos(ns);
        assert_eq!(mtime_millis(at(863_891_680)), 864);
        assert_eq!(mtime_millis(at(864_077_961)), 864);
        assert_eq!(mtime_millis(at(864_500_000)), 865);
        assert_eq!(mtime_millis(at(864_499_999)), 864);
    }
}
