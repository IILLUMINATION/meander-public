//! Request body extraction shared by the ported routes.
//!
//! Express had `express.json` **and** `express.urlencoded` mounted globally and
//! `multer` per upload route. Axum needs explicit extractors, so:
//!
//! * [`Body`] parses JSON or `application/x-www-form-urlencoded` into a
//!   `serde_json::Value`, including the 400 `Bad JSON format` answer;
//! * [`multipart`] streams parts to temporary files (uploads reach 500 MB, so
//!   buffering in memory is not an option) and exposes fields plus files.

use std::collections::HashMap;
use std::path::PathBuf;

use axum::extract::{FromRequest, Multipart, Request};
use axum::http::{StatusCode, header};
use serde_json::{Map, Value, json};

use crate::error::{ApiError, payload_too_large};

/// Why [`upload_form`] could not produce multipart form data.
pub enum UploadFormError {
    /// The multipart/file limit was exceeded (multer `LIMIT_FILE_SIZE`).
    TooLarge,
    /// The multipart envelope itself is malformed (multer's own errors).
    Multipart(String),
    /// Global `express.json` rejected the body before the route.
    BadJson,
}

/// Parses an upload route's body the way Node does: multipart goes through
/// multer-like streaming, while JSON/urlencoded bodies are parsed globally and
/// then reach the handler with no files (which is a normal 400 there).
pub async fn upload_form(
    request: Request,
    state: &std::sync::Arc<super::state::AppState>,
    max_file_bytes: usize,
) -> Result<FormData, UploadFormError> {
    let raw_content_type = request
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let content_type = raw_content_type.to_ascii_lowercase();
    let media = crate::media_type(&content_type);

    if !crate::is_multipart_content_type(&content_type) {
        // `multer` engages busboy for any `multipart/*` media type, and busboy
        // then refuses everything but `multipart/form-data`.
        if let Some(subtype) = media.strip_prefix("multipart/") {
            if !subtype.is_empty() {
                return Err(UploadFormError::Multipart(format!(
                    "Unsupported content type: {raw_content_type}"
                )));
            }
        }
        let bytes = axum::body::to_bytes(request.into_body(), 1024 * 1024)
            .await
            .map_err(|_| UploadFormError::TooLarge)?;
        if crate::is_json_content_type(&content_type) && !bytes.is_empty() {
            match serde_json::from_slice::<Value>(&bytes) {
                Ok(value) if value.is_object() || value.is_array() => {}
                _ => return Err(UploadFormError::BadJson),
            }
        }
        return Ok(FormData::default());
    }

    let boundary = content_type.split(';').skip(1).find_map(|param| {
        let (name, value) = param.split_once('=')?;
        name.trim()
            .eq_ignore_ascii_case("boundary")
            .then(|| value.trim().to_string())
    });
    match boundary.as_deref() {
        None => {
            return Err(UploadFormError::Multipart(
                "Multipart: Boundary not found".to_string(),
            ));
        }
        // Multer silently skips parsing when the boundary is empty.
        Some("") => return Ok(FormData::default()),
        Some(_) => {}
    }

    let multipart = Multipart::from_request(request, state)
        .await
        .map_err(|_| UploadFormError::Multipart("Unexpected end of form".to_string()))?;
    collect_multipart(multipart, max_file_bytes)
        .await
        .map_err(|err| {
            if err.status == StatusCode::PAYLOAD_TOO_LARGE {
                UploadFormError::TooLarge
            } else {
                UploadFormError::Multipart(err.error)
            }
        })
}

/// Result of the global `express.json`/`express.urlencoded` equivalent, cached
/// in request extensions before auth and routing run (Node parses first).
#[derive(Clone)]
pub struct ParsedBody(pub Value);

/// Parsed body, JSON-shaped. Missing/empty bodies become `{}` like Express.
pub struct Body(pub Value);

impl Body {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.get(key)
    }

    pub fn str(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(Value::as_str)
    }

    pub fn i64(&self, key: &str) -> Option<i64> {
        match self.0.get(key) {
            Some(Value::Number(n)) => n.as_i64(),
            Some(Value::String(s)) => s.trim().parse().ok(),
            _ => None,
        }
    }

    pub fn bool(&self, key: &str) -> Option<bool> {
        match self.0.get(key) {
            Some(Value::Bool(b)) => Some(*b),
            Some(Value::String(s)) => Some(s == "true" || s == "1"),
            _ => None,
        }
    }

    pub fn array(&self, key: &str) -> Vec<Value> {
        match self.0.get(key) {
            Some(Value::Array(items)) => items.clone(),
            Some(other) => vec![other.clone()],
            None => Vec::new(),
        }
    }
}

pub(crate) fn urlencoded_to_value(raw: &str) -> Value {
    let mut map: Map<String, Value> = Map::new();
    for pair in raw.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        let key = percent_decode(key);
        let value = percent_decode(value);
        match map.get_mut(&key) {
            // Express turns repeated keys into an array.
            Some(Value::Array(items)) => items.push(Value::String(value)),
            Some(existing) => {
                let first = existing.take();
                map.insert(key, Value::Array(vec![first, Value::String(value)]));
            }
            None => {
                map.insert(key, Value::String(value));
            }
        }
    }
    Value::Object(map)
}

fn percent_decode(raw: &str) -> String {
    let plus = raw.replace('+', " ");
    let bytes = plus.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&plus[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl FromRequest<std::sync::Arc<super::state::AppState>> for Body {
    type Rejection = ApiError;

    async fn from_request(
        req: Request,
        _state: &std::sync::Arc<super::state::AppState>,
    ) -> Result<Self, Self::Rejection> {
        if let Some(body) = req.extensions().get::<ParsedBody>() {
            return Ok(Body(body.0.clone()));
        }

        let content_type = req
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        // Express only fills `req.body` for the two parser content types;
        // anything else reaches the handler as an empty object.
        if !crate::is_json_content_type(&content_type)
            && !crate::is_urlencoded_content_type(&content_type)
        {
            return Ok(Body(json!({})));
        }

        let limit = super::json_body_limit(&req);
        let bytes = axum::body::to_bytes(req.into_body(), limit)
            .await
            .map_err(|_| payload_too_large())?;

        if bytes.is_empty() {
            return Ok(Body(json!({})));
        }

        if crate::is_urlencoded_content_type(&content_type) {
            let raw = String::from_utf8_lossy(&bytes);
            return Ok(Body(urlencoded_to_value(&raw)));
        }

        // Express's `strict: true` parser only accepts objects and arrays;
        // `null`, strings and numbers are answered with the 400 below.
        match serde_json::from_slice::<Value>(&bytes) {
            Ok(value) if value.is_object() || value.is_array() => Ok(Body(value)),
            _ => Err(ApiError::bad_request("Bad JSON format")),
        }
    }
}

impl axum::extract::OptionalFromRequest<std::sync::Arc<super::state::AppState>> for Body {
    type Rejection = ApiError;

    async fn from_request(
        req: Request,
        state: &std::sync::Arc<super::state::AppState>,
    ) -> Result<Option<Self>, Self::Rejection> {
        <Self as FromRequest<std::sync::Arc<super::state::AppState>>>::from_request(req, state)
            .await
            .map(Some)
    }
}

/// One multipart file, streamed to a temporary path.
pub struct UploadedFile {
    pub field: String,
    pub file_name: String,
    pub content_type: Option<String>,
    pub path: PathBuf,
    pub size: usize,
}

impl Drop for UploadedFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

impl std::fmt::Debug for UploadedFile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UploadedFile")
            .field("field", &self.field)
            .field("file_name", &self.file_name)
            .field("content_type", &self.content_type)
            .field("size", &self.size)
            .finish()
    }
}

#[derive(Debug, Default)]
pub struct FormData {
    pub fields: HashMap<String, Vec<String>>,
    pub files: Vec<UploadedFile>,
}

impl FormData {
    pub fn str(&self, key: &str) -> Option<&str> {
        self.fields.get(key)?.first().map(String::as_str)
    }

    pub fn strings(&self, key: &str) -> Vec<String> {
        self.fields.get(key).cloned().unwrap_or_default()
    }

    pub fn file(&self, field: &str) -> Option<&UploadedFile> {
        self.files.iter().find(|f| f.field == field)
    }

    /// The value as a `serde_json::Value`: JSON arrays/objects are decoded,
    /// everything else stays a string — matching `JSON.parse` use in the Node
    /// handlers.
    pub fn value(&self, key: &str) -> Value {
        match self.str(key) {
            Some(raw) => serde_json::from_str::<Value>(raw).unwrap_or_else(|_| json!(raw)),
            None => Value::Null,
        }
    }

    pub fn bool(&self, key: &str) -> bool {
        matches!(self.str(key), Some("true") | Some("1") | Some("on"))
    }
}

/// `multer` field-by-field limits: request handlers pass the file cap.
pub async fn collect_multipart(
    mut multipart: Multipart,
    max_file_bytes: usize,
) -> Result<FormData, ApiError> {
    let mut form = FormData::default();

    while let Some(field) = multipart.next_field().await.map_err(|err| {
        tracing::warn!(error = %err, "multipart parse failed");
        ApiError::bad_request("Unexpected end of form")
    })? {
        let name = field.name().unwrap_or_default().to_string();
        let file_name = field.file_name().map(str::to_string);
        let content_type = field.content_type().map(str::to_string);

        match file_name {
            None => {
                let value = field.text().await.map_err(|err| {
                    tracing::warn!(error = %err, "multipart text field failed");
                    ApiError::bad_request("Unexpected end of form")
                })?;
                form.fields.entry(name).or_default().push(value);
            }
            Some(file_name) => {
                let path =
                    std::env::temp_dir().join(format!("mnd-upload-{}", uuid::Uuid::new_v4()));
                let mut file = tokio::fs::File::create(&path).await.map_err(|err| {
                    tracing::error!(error = %err, "cannot create upload temp file");
                    ApiError::internal("Failed to save uploaded file")
                })?;
                let mut size = 0usize;
                let mut stream = field;
                use tokio::io::AsyncWriteExt;
                while let Some(chunk) = stream.chunk().await.map_err(|err| {
                    tracing::warn!(error = %err, "multipart file chunk failed");
                    ApiError::bad_request("Unexpected end of form")
                })? {
                    size += chunk.len();
                    if size > max_file_bytes {
                        let _ = tokio::fs::remove_file(&path).await;
                        return Err(payload_too_large());
                    }
                    file.write_all(&chunk).await.map_err(|err| {
                        tracing::error!(error = %err, "cannot write upload temp file");
                        ApiError::internal("Failed to save uploaded file")
                    })?;
                }
                file.flush().await.map_err(|err| {
                    tracing::error!(error = %err, "cannot flush upload temp file");
                    ApiError::internal("Failed to save uploaded file")
                })?;
                form.files.push(UploadedFile {
                    field: name,
                    file_name,
                    content_type,
                    path,
                    size,
                });
            }
        }
    }

    Ok(form)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urlencoded_parses_arrays_and_escapes() {
        let value =
            urlencoded_to_value("a=1&a=2&b=hello+world&c=%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82");
        assert_eq!(value["a"], json!(["1", "2"]));
        assert_eq!(value["b"], json!("hello world"));
        assert_eq!(value["c"], json!("привет"));
    }

    #[test]
    fn body_accessors_mirror_express_shapes() {
        let body = Body(json!({"flag": "true", "count": "12", "list": "solo"}));
        assert_eq!(body.bool("flag"), Some(true));
        assert_eq!(body.i64("count"), Some(12));
        assert_eq!(body.array("list"), vec![json!("solo")]);
        assert!(body.str("missing").is_none());
    }
}
