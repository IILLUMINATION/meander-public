//! HTTP error type mirroring `humanErrorMiddleware`.
//!
//! Every handler returns `Result<Response, ApiError>`; the error body keeps the
//! Node shape (`{error, code?, original_error?}`) and the human translations of
//! the enumerable database failures. `original_error` is only exposed outside
//! production, exactly like the Node middleware.

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::{Map, Value, json};

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub error: String,
    pub code: Option<&'static str>,
    pub original: Option<String>,
    pub extra: Option<Map<String, Value>>,
}

impl ApiError {
    pub fn new(status: StatusCode, error: impl Into<String>) -> Self {
        Self {
            status,
            error: error.into(),
            code: None,
            original: None,
            extra: None,
        }
    }

    pub fn bad_request(error: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, error)
    }

    pub fn unauthorized(error: impl Into<String>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, error)
    }

    pub fn forbidden(error: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, error)
    }

    pub fn not_found(error: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, error)
    }

    pub fn internal(error: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, error)
    }

    pub fn conflict(error: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, error)
    }

    pub fn with_code(mut self, code: &'static str) -> Self {
        self.code = Some(code);
        self
    }

    pub fn with_original(mut self, original: impl Into<String>) -> Self {
        self.original = Some(original.into());
        self
    }

    pub fn with_extra(mut self, key: &str, value: Value) -> Self {
        self.extra
            .get_or_insert_with(Map::new)
            .insert(key.to_string(), value);
        self
    }

    pub fn status(mut self, status: StatusCode) -> Self {
        self.status = status;
        self
    }

    pub fn is_production(&self) -> bool {
        std::env::var("NODE_ENV").as_deref() == Ok("production")
    }
}

/// The translations from `middleware/error_messages.ts`, keyed by SQLSTATE and
/// constraint name (the Node version matched the message text).
fn human_db_message(err: &sqlx::Error) -> Option<&'static str> {
    let db = match err {
        sqlx::Error::Database(db) => db,
        _ => return None,
    };

    if let Some(constraint) = db.constraint() {
        let human = match constraint {
            "quest_votes_pkey" => "Вы уже голосовали за этот квест.",
            "ratings_pkey" => "Вы уже оценили этот квест.",
            "quest_downloads_pkey" => "Вы уже скачали этот квест.",
            "user_followers_pkey" => "Вы уже подписаны на этого автора.",
            _ => "",
        };
        if !human.is_empty() {
            return Some(human);
        }
    }

    match db.code().as_deref() {
        Some("42P01") => Some("Квест временно недоступен. Попробуйте позже."),
        Some("23505") => Some("Такой элемент уже существует."),
        Some("23503") => Some("Связанный элемент не найден."),
        Some("42501") => Some("У вас нет прав для этого действия."),
        Some("22P02") | Some("22007") => {
            Some("Неверный формат данных. Проверьте запрос и попробуйте снова.")
        }
        _ => None,
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(err: sqlx::Error) -> Self {
        // The detail stays in the log; the client sees either the enumerable
        // translation or the generic 500 text that humanErrorMiddleware used.
        let original = err.to_string();
        tracing::error!(error = %err, "database error");
        match human_db_message(&err) {
            Some(msg) => ApiError::internal(msg).with_original(original),
            None => ApiError::internal(if is_production() {
                "Произошла ошибка. Попробуйте позже.".to_string()
            } else {
                original.clone()
            })
            .with_original(original),
        }
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.error)
    }
}

impl std::error::Error for ApiError {}

impl From<anyhow::Error> for ApiError {
    fn from(err: anyhow::Error) -> Self {
        tracing::error!(error = %err, "internal error");
        ApiError::internal(if is_production() {
            "Произошла ошибка. Попробуйте позже.".to_string()
        } else {
            err.to_string()
        })
    }
}

impl From<std::io::Error> for ApiError {
    fn from(err: std::io::Error) -> Self {
        tracing::error!(error = %err, "io error");
        ApiError::internal(if is_production() {
            "Произошла ошибка. Попробуйте позже.".to_string()
        } else {
            err.to_string()
        })
    }
}

fn is_production() -> bool {
    std::env::var("NODE_ENV").as_deref() == Ok("production")
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut body = Map::new();
        body.insert("error".into(), Value::String(self.error));
        if let Some(code) = self.code {
            body.insert("code".into(), Value::String(code.into()));
        }
        if let Some(extra) = self.extra {
            for (k, v) in extra {
                body.entry(k).or_insert(v);
            }
        }
        if !is_production() {
            if let Some(original) = self.original {
                body.insert("original_error".into(), Value::String(original));
            }
        }
        (self.status, Json(Value::Object(body))).into_response()
    }
}

/// Shorthand for handler return types: JSON body with 200 and an empty 204.
pub type ApiResult = Result<Response, ApiError>;

pub fn ok_json(value: impl Into<Value>) -> ApiResult {
    Ok(Json(value.into()).into_response())
}

pub fn ok_created(value: impl Into<Value>) -> ApiResult {
    Ok((StatusCode::CREATED, Json(value.into())).into_response())
}

pub fn no_content() -> ApiResult {
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// `res.status(413).send({error: ...})` used by the body-size guard.
/// `app.ts` maps three multer messages to 400 before the human error
/// middleware; everything else becomes a 500 with `original_error`.
pub fn upload_error(message: &str) -> ApiError {
    match message {
        "Invalid image file type" | "Invalid quest file type" | "Unexpected upload field" => {
            ApiError::bad_request(message)
        }
        _ => multer_error(message),
    }
}

/// multer errors reach `humanErrorMiddleware` in Node (500 plus
/// `original_error` in development), unlike the route-level JSON rejections.
pub fn multer_error(message: impl Into<String>) -> ApiError {
    let message = message.into();
    ApiError::internal(message.clone()).with_original(message)
}

pub fn payload_too_large() -> ApiError {
    ApiError::new(
        StatusCode::PAYLOAD_TOO_LARGE,
        "File too large. Limits: regular users 100 MB, verified users 500 MB.",
    )
}

/// Convenience for the very common "missing required field" answers.
pub fn missing_field(name: &str) -> ApiError {
    ApiError::bad_request(format!("{name} is required"))
}

pub fn json_array(v: Vec<Value>) -> Value {
    Value::Array(v)
}

pub fn json_obj(pairs: Vec<(&str, Value)>) -> Value {
    let mut map = Map::new();
    for (k, v) in pairs {
        map.insert(k.to_string(), v);
    }
    Value::Object(map)
}

#[allow(dead_code)]
pub fn debug_body(value: &Value) -> String {
    json!(value).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_error_matches_app_ts_message_classes() {
        let plain = upload_error("Invalid image file type");
        assert_eq!(plain.status, StatusCode::BAD_REQUEST);
        assert!(plain.original.is_none());

        let quest = upload_error("Invalid quest file type");
        assert_eq!(quest.status, StatusCode::BAD_REQUEST);

        let audio = upload_error("Invalid music file type");
        assert_eq!(audio.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(audio.original.as_deref(), Some("Invalid music file type"));
    }

    #[test]
    fn multer_error_keeps_original_for_development_output() {
        let err = multer_error("Unexpected file field");
        assert_eq!(err.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(err.original.as_deref(), Some("Unexpected file field"));
    }
}
