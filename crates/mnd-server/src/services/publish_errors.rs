//! Enumerable publication errors — port of `publish_errors.ts`.
//!
//! Every failure has a code, a status and a human sentence. Unexpected errors
//! become 500 `publish_failed`; the original goes to the log only.

use axum::http::StatusCode;
use serde_json::{Map, Value, json};

use crate::error::ApiError;

pub const REGULAR_USER_MAX_FILE_SIZE_BYTES: u64 = 100 * 1024 * 1024;
pub const VERIFIED_USER_MAX_FILE_SIZE_BYTES: u64 = 500 * 1024 * 1024;
pub const MB: u64 = 1024 * 1024;

#[derive(Debug)]
pub struct PublishError {
    pub code: &'static str,
    pub status: StatusCode,
    pub message: String,
    pub details: Map<String, Value>,
}

impl PublishError {
    pub fn new(
        code: &'static str,
        status: StatusCode,
        message: impl Into<String>,
        details: Map<String, Value>,
    ) -> Self {
        Self {
            code,
            status,
            message: message.into(),
            details,
        }
    }

    /// Shape used by `res.status(out.status).json(out.body)`: exactly
    /// `{error, code, ...details}`, with no `original_error` even outside
    /// production, because the Node catch never produced one.
    pub fn to_api_error(&self) -> ApiError {
        let mut error = ApiError::new(self.status, self.message.clone()).with_code(self.code);
        for (key, value) in &self.details {
            error = error.with_extra(key, value.clone());
        }
        error
    }
}

pub fn size_limit_for(is_verified: bool) -> u64 {
    if is_verified {
        VERIFIED_USER_MAX_FILE_SIZE_BYTES
    } else {
        REGULAR_USER_MAX_FILE_SIZE_BYTES
    }
}

/// Rejects by declared `Content-Length` before the multipart body is parsed.
/// Five megabytes of slack cover the other multipart fields.
pub fn declared_size_rejection(
    content_length: Option<u64>,
    limit_bytes: u64,
) -> Option<PublishError> {
    let declared = content_length?;
    if declared == 0 {
        return None;
    }
    let multipart_overhead = 5 * MB;
    if declared <= limit_bytes + multipart_overhead {
        return None;
    }
    Some(file_too_large(declared, limit_bytes))
}

pub fn file_too_large(size_bytes: u64, limit_bytes: u64) -> PublishError {
    let size_mb = format!("{:.2}", size_bytes as f64 / MB as f64);
    let limit_mb = (limit_bytes + MB / 2) / MB;
    let mut details = Map::new();
    details.insert("size_bytes".into(), json!(size_bytes));
    let size_mb_value = size_mb.parse::<f64>().unwrap_or(0.0);
    details.insert(
        "size_mb".into(),
        if size_mb_value.fract() == 0.0 {
            json!(size_mb_value as i64)
        } else {
            json!(size_mb_value)
        },
    );
    details.insert("limit_bytes".into(), json!(limit_bytes));
    details.insert("limit_mb".into(), json!(limit_mb));
    PublishError::new(
        "file_too_large",
        StatusCode::PAYLOAD_TOO_LARGE,
        format!(
            "Пакет квеста слишком большой: {size_mb} МБ при лимите {limit_mb} МБ. \
             Убери лишнее из ресурсов квеста (лишние картинки, звук, видео) \
             или попроси верификацию автора — с ней лимит 500 МБ."
        ),
        details,
    )
}

pub fn missing_quest_file() -> PublishError {
    PublishError::new(
        "quest_file_required",
        StatusCode::BAD_REQUEST,
        "Файл квеста не дошёл до сервера. Попробуй опубликовать заново — \
         обычно это обрыв связи во время загрузки.",
        Map::new(),
    )
}

pub fn ownership_conflict() -> PublishError {
    PublishError::new(
        "quest_owned_by_other_author",
        StatusCode::CONFLICT,
        "Квест с таким идентификатором уже опубликован другим автором. \
         Так бывает, когда редактируют копию, скачанную из маркета: она \
         сохраняет id исходной публикации. Сохрани работу под новым \
         именем и опубликуй как новый квест.",
        Map::new(),
    )
}

pub fn duplicate_file() -> PublishError {
    PublishError::new(
        "duplicate_file",
        StatusCode::CONFLICT,
        "Такой файл уже есть в магазине у другого автора.",
        Map::new(),
    )
}

pub fn archive_unreadable(reason: &str) -> PublishError {
    let mut details = Map::new();
    details.insert("reason".into(), json!(reason));
    PublishError::new(
        "archive_unreadable",
        StatusCode::UNPROCESSABLE_ENTITY,
        "Сервер не смог разобрать пакет квеста. Проверь, что квест собирается \
         без ошибок, и попробуй опубликовать заново.",
        details,
    )
}

pub fn content_rejected(reason: &str) -> PublishError {
    let mut details = Map::new();
    details.insert("reason".into(), json!(reason));
    PublishError::new(
        "content_policy_violation",
        StatusCode::UNPROCESSABLE_ENTITY,
        format!("Публикация отклонена по правилам магазина: {reason}"),
        details,
    )
}

/// Anything that is not a `PublishError` is a server fault.
pub fn unexpected(err: &dyn std::fmt::Display) -> ApiError {
    tracing::error!(error = %err, "publish failed");
    ApiError::internal(
        "Сервер не смог обработать публикацию. Попробуй позже — если ошибка повторяется, напиши в поддержку.",
    )
    .with_code("publish_failed")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn declared_size_gate_allows_overhead_and_rejects_oversize() {
        let limit = REGULAR_USER_MAX_FILE_SIZE_BYTES;
        assert!(declared_size_rejection(None, limit).is_none());
        assert!(declared_size_rejection(Some(0), limit).is_none());
        assert!(declared_size_rejection(Some(limit), limit).is_none());
        assert!(declared_size_rejection(Some(limit + 5 * MB), limit).is_none());
        assert!(declared_size_rejection(Some(limit + 5 * MB + 1), limit).is_some());
    }

    #[test]
    fn oversized_file_reports_megabytes() {
        let err = file_too_large(200 * MB, 100 * MB);
        assert_eq!(err.status, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(err.code, "file_too_large");
        assert!(err.message.contains("200.00 МБ"));
        assert!(err.message.contains("100 МБ"));
        assert_eq!(err.details["size_mb"], json!(200));
    }

    #[test]
    fn api_error_carries_code_and_details() {
        let api = content_rejected("мат в названии").to_api_error();
        assert_eq!(api.status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(api.code, Some("content_policy_violation"));
        assert_eq!(
            api.extra.as_ref().unwrap()["reason"],
            json!("мат в названии")
        );
    }

    #[test]
    fn size_limit_depends_on_verification() {
        assert_eq!(size_limit_for(false), 100 * MB);
        assert_eq!(size_limit_for(true), 500 * MB);
    }
}
