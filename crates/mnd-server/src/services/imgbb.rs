//! ImgBB upload — port of `backend/src/services/imgbb.ts`.
//!
//! Encodes the image as base64 and posts it to `https://api.imgbb.com/1/upload`,
//! exactly like the Node service. A missing API key is reported with the same
//! message and becomes a 500 error at the route boundary.

use std::path::Path;

use reqwest::header::USER_AGENT;
use serde::Deserialize;

#[derive(Debug)]
pub enum ImgbbError {
    MissingKey(String),
    Upload(String),
}

impl std::fmt::Display for ImgbbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImgbbError::MissingKey(msg) | ImgbbError::Upload(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for ImgbbError {}

impl From<ImgbbError> for crate::error::ApiError {
    fn from(err: ImgbbError) -> Self {
        crate::error::ApiError::internal(err.to_string()).with_original(err.to_string())
    }
}

#[derive(Debug, Deserialize)]
struct ImgbbResponse {
    data: Option<ImgbbData>,
}

#[derive(Debug, Deserialize)]
struct ImgbbData {
    url: Option<String>,
}

pub async fn upload_to_imgbb(
    http: &reqwest::Client,
    key: Option<&str>,
    file_path: impl AsRef<Path>,
) -> Result<String, ImgbbError> {
    if key.is_none() || key.unwrap_or("").is_empty() {
        return Err(ImgbbError::MissingKey(
            "IMGBB_KEY is missing in .env".into(),
        ));
    }
    let key = key.unwrap();

    let image = tokio::fs::read(file_path.as_ref())
        .await
        .map_err(|err| ImgbbError::Upload(err.to_string()))?;
    let base64_image = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &image);

    let form = reqwest::multipart::Form::new().text("image", base64_image);

    let response = http
        .post("https://api.imgbb.com/1/upload")
        .query(&[("key", key)])
        .header(
            USER_AGENT,
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
        )
        .multipart(form)
        .send()
        .await
        .map_err(|err| ImgbbError::Upload(err.to_string()))?;

    let text = response
        .text()
        .await
        .map_err(|err| ImgbbError::Upload(err.to_string()))?;

    let parsed: ImgbbResponse =
        serde_json::from_str(&text).map_err(|err| ImgbbError::Upload(err.to_string()))?;

    match parsed.data.and_then(|d| d.url) {
        Some(url) => Ok(url),
        None => {
            tracing::error!(response = %text, "[imgbb] response missing URL");
            Err(ImgbbError::Upload("Failed to upload image to ImgBB".into()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_key_error_message_matches_node() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let err = rt
            .block_on(async {
                let client = reqwest::Client::new();
                upload_to_imgbb(&client, None, "/nonexistent/path.png").await
            })
            .unwrap_err();
        assert_eq!(err.to_string(), "IMGBB_KEY is missing in .env");
    }
}
