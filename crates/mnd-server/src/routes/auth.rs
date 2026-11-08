//! `/auth` routes.  Drop-in порт четырёх Node-роутеров:
//! `routes/auth.ts`, `routes/auth_yandex.ts`, `routes/auth_telegram.ts`,
//! `routes/auth_apple.ts`.

use std::sync::Arc;

use axum::{
    Router,
    extract::State,
    http::StatusCode,
    routing::{get, post},
};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Utc};
use jsonwebtoken::{Algorithm, EncodingKey, Header, Validation};
use serde::Serialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::Row;
use uuid::Uuid;

use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult, ok_json};
use crate::extractors::Body;
use crate::json::{pg_row_to_json, ts};
use crate::services::achievements::award_achievement;
use crate::services::google_exchange::{
    GoogleExchangeConfig, exchange_google_code, is_loopback_redirect, is_pkce_verifier,
};
use crate::services::telegram_jwt::{verify_telegram_id_token, verify_telegram_widget_hash};
use crate::state::AppState;

const DELETION_GRACE_DAYS: i32 = 3;
const MAX_DELETION_REASON_LENGTH: usize = 500;

#[derive(Serialize)]
struct AppClaims {
    id: Uuid,
    role: String,
    tv: i64,
    exp: i64,
}

fn app_token(
    row: &sqlx::postgres::PgRow,
    secret: &str,
) -> Result<String, jsonwebtoken::errors::Error> {
    let id = row.try_get::<Uuid, _>("id").unwrap_or_default();
    let role = row.try_get::<String, _>("role").unwrap_or_default();
    let tv = row.try_get::<i32, _>("token_version").unwrap_or(0) as i64;
    // expiresIn: '7d'
    let exp = Utc::now().timestamp() + 7 * 24 * 60 * 60;
    let claims = AppClaims { id, role, tv, exp };
    let header = Header::new(Algorithm::HS256);
    let key = EncodingKey::from_secret(secret.as_bytes());
    jsonwebtoken::encode(&header, &claims, &key)
}

fn token_with_user(row: &sqlx::postgres::PgRow, secret: &str, error_text: &str) -> ApiResult {
    let token = app_token(row, secret).map_err(|e| {
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, error_text).with_original(e.to_string())
    })?;
    ok_json(json!({ "token": token, "user": pg_row_to_json(row) }))
}

// ============================================================================
//  Google Sign-In
// ============================================================================

async fn google_token(State(state): State<Arc<AppState>>, body: Body) -> ApiResult {
    let Some(id_token) = body.str("idToken") else {
        return Err(ApiError::bad_request("idToken is required"));
    };

    let Some(secret) = state.cfg.jwt_secret.as_deref() else {
        return Err(ApiError::internal("Server auth is not configured"));
    };

    if state.cfg.google_client_ids.is_empty() {
        return Err(ApiError::internal("Google auth is not configured"));
    }

    let audiences: Vec<&str> = state
        .cfg
        .google_client_ids
        .iter()
        .map(|s| s.as_str())
        .collect();

    let Some(payload) = crate::services::jwks::verify_identity_token(
        &state.google_jwks,
        &state.http,
        id_token,
        &["https://accounts.google.com", "accounts.google.com"],
        &audiences,
    )
    .await
    else {
        return Err(ApiError::unauthorized("Invalid Google token"));
    };

    let google_id = payload.get("sub").and_then(Value::as_str).unwrap_or("");
    if google_id.is_empty() {
        return Err(ApiError::unauthorized("Invalid Google token"));
    }

    let email = payload
        .get("email")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    let full_name = payload
        .get("name")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    let avatar_url = payload
        .get("picture")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());

    let user = match sqlx::query("SELECT * FROM profiles WHERE google_id = $1")
        .bind(google_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Server error during token verification",
            )
            .with_original(e.to_string())
        })? {
        Some(row) => row,
        None => {
            let row = sqlx::query(
                "INSERT INTO profiles (id, google_id, full_name, email, avatar_url)
                 VALUES ($1, $2, $3, $4, $5)
                 RETURNING *",
            )
            .bind(Uuid::new_v4())
            .bind(google_id)
            .bind(full_name)
            .bind(email)
            .bind(avatar_url)
            .fetch_one(&state.db)
            .await
            .map_err(|e| {
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Server error during token verification",
                )
                .with_original(e.to_string())
            })?;

            let user_id = row.try_get::<Uuid, _>("id").unwrap_or_default();
            award_achievement(&state, user_id, "hello_world").await;
            tracing::info!(
                full_name = ?full_name,
                "New user created via Google Sign-In"
            );
            row
        }
    };

    tracing::info!(user_id = ?user.try_get::<Uuid, _>("id").unwrap_or_default(), "User signed in via Google Sign-In");

    token_with_user(&user, secret, "Server error during token verification")
}

async fn google_exchange(State(state): State<Arc<AppState>>, body: Body) -> ApiResult {
    let Some(desktop_client_id) = std::env::var("GOOGLE_DESKTOP_CLIENT_ID")
        .ok()
        .filter(|s| !s.is_empty())
    else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "Google desktop exchange is not configured",
        ));
    };
    let Some(desktop_client_secret) = std::env::var("GOOGLE_DESKTOP_CLIENT_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
    else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "Google desktop exchange is not configured",
        ));
    };

    let Some(code) = body.str("code") else {
        return Err(ApiError::bad_request("code is required"));
    };
    if code.is_empty() || code.len() > 4096 {
        return Err(ApiError::bad_request("code is required"));
    }

    let Some(code_verifier) = body.str("codeVerifier") else {
        return Err(ApiError::bad_request("codeVerifier is invalid"));
    };
    if !is_pkce_verifier(code_verifier) {
        return Err(ApiError::bad_request("codeVerifier is invalid"));
    }

    let Some(redirect_uri) = body.str("redirectUri") else {
        return Err(ApiError::bad_request("redirectUri must point to loopback"));
    };
    if !is_loopback_redirect(redirect_uri) {
        return Err(ApiError::bad_request("redirectUri must point to loopback"));
    }

    if let Some(client_id) = body.str("clientId") {
        if client_id != desktop_client_id {
            return Err(ApiError::bad_request("clientId does not match this server"));
        }
    }

    let input = crate::services::google_exchange::GoogleExchangeInput {
        code: code.to_string(),
        code_verifier: code_verifier.to_string(),
        redirect_uri: redirect_uri.to_string(),
    };
    let config = GoogleExchangeConfig {
        client_id: desktop_client_id,
        client_secret: desktop_client_secret,
    };

    let id_token = exchange_google_code(&state.http, &input, &config)
        .await
        .map_err(|e| {
            tracing::error!(error = %e.0, "Google desktop exchange failed");
            ApiError::unauthorized("Google token exchange failed").with_original(e.0)
        })?;

    ok_json(json!({ "idToken": id_token }))
}

// ============================================================================
//  Yandex
// ============================================================================

#[derive(Debug)]
struct YandexInfo {
    id: String,
    login: String,
    default_email: Option<String>,
    emails: Option<Vec<String>>,
    display_name: Option<String>,
    real_name: Option<String>,
    first_name: Option<String>,
    last_name: Option<String>,
    default_avatar_id: Option<String>,
}

async fn fetch_yandex_info(
    http: &reqwest::Client,
    oauth_token: &str,
) -> Result<YandexInfo, ApiError> {
    let response = http
        .get("https://login.yandex.ru/info?format=json")
        .header("Authorization", format!("OAuth {oauth_token}"))
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Server error during Yandex verification",
            )
            .with_original(e.to_string())
        })?;

    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Err(ApiError::unauthorized("Invalid Yandex token"));
    }

    let status = response.status();
    if !status.is_success() {
        let text = response.text().await.unwrap_or_default();
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server error during Yandex verification",
        )
        .with_original(format!("Yandex info failed: {} {}", status, text)));
    }

    let data: Value = response.json().await.map_err(|e| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server error during Yandex verification",
        )
        .with_original(e.to_string())
    })?;

    let Some(id) = data.get("id").and_then(Value::as_str) else {
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server error during Yandex verification",
        )
        .with_original("Yandex response missing id/login"));
    };
    let Some(login) = data.get("login").and_then(Value::as_str) else {
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server error during Yandex verification",
        )
        .with_original("Yandex response missing id/login"));
    };

    Ok(YandexInfo {
        id: id.to_string(),
        login: login.to_string(),
        default_email: data
            .get("default_email")
            .and_then(Value::as_str)
            .map(String::from),
        emails: data.get("emails").and_then(|v| v.as_array()).map(|arr| {
            arr.iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect()
        }),
        display_name: data
            .get("display_name")
            .and_then(Value::as_str)
            .map(String::from),
        real_name: data
            .get("real_name")
            .and_then(Value::as_str)
            .map(String::from),
        first_name: data
            .get("first_name")
            .and_then(Value::as_str)
            .map(String::from),
        last_name: data
            .get("last_name")
            .and_then(Value::as_str)
            .map(String::from),
        default_avatar_id: data
            .get("default_avatar_id")
            .and_then(Value::as_str)
            .map(String::from),
    })
}

async fn yandex_token(State(state): State<Arc<AppState>>, body: Body) -> ApiResult {
    let oauth_token = body.str("yandexToken").or_else(|| body.str("token"));
    let Some(oauth_token) = oauth_token else {
        return Err(ApiError::bad_request("yandexToken is required"));
    };

    let Some(secret) = state.cfg.jwt_secret.as_deref() else {
        return Err(ApiError::internal("Server auth is not configured"));
    };

    let info = fetch_yandex_info(&state.http, oauth_token).await?;

    let yandex_id = info.id.clone();
    let yandex_login = info.login.clone();
    let email: Option<String> = info
        .default_email
        .or_else(|| info.emails.as_ref().and_then(|v| v.first().cloned()));
    let full_name: Option<String> = info
        .display_name
        .or(info.real_name)
        .or_else(|| {
            let parts = [info.first_name.as_deref(), info.last_name.as_deref()]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>();
            if parts.is_empty() {
                None
            } else {
                Some(parts.join(" "))
            }
        })
        .or(Some(yandex_login.clone()));
    let avatar_url: Option<String> = info
        .default_avatar_id
        .clone()
        .map(|id| format!("https://avatars.yandex.net/get-yapic/{id}/islands-200"));

    let user = match sqlx::query("SELECT * FROM profiles WHERE yandex_id = $1")
        .bind(&yandex_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Server error during Yandex verification",
            )
            .with_original(e.to_string())
        })? {
        Some(row) => row,
        None => {
            let email_to_insert = if let Some(ref email) = email {
                let exists = sqlx::query("SELECT id FROM profiles WHERE email = $1")
                    .bind(email)
                    .fetch_optional(&state.db)
                    .await
                    .map_err(|e| {
                        ApiError::new(
                            StatusCode::INTERNAL_SERVER_ERROR,
                            "Server error during Yandex verification",
                        )
                        .with_original(e.to_string())
                    })?;
                if exists.is_some() {
                    None
                } else {
                    Some(email.clone())
                }
            } else {
                None
            };

            let row = sqlx::query(
                "INSERT INTO profiles (id, yandex_id, yandex_login, full_name, email, avatar_url)
                 VALUES ($1, $2, $3, $4, $5, $6)
                 RETURNING *",
            )
            .bind(Uuid::new_v4())
            .bind(&yandex_id)
            .bind(&yandex_login)
            .bind(&full_name)
            .bind(&email_to_insert)
            .bind(&avatar_url)
            .fetch_one(&state.db)
            .await
            .map_err(|e| {
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Server error during Yandex verification",
                )
                .with_original(e.to_string())
            })?;

            let user_id = row.try_get::<Uuid, _>("id").unwrap_or_default();
            award_achievement(&state, user_id, "hello_world").await;
            tracing::info!(full_name = ?full_name, login = %yandex_login, "New user created via Yandex");
            row
        }
    };

    // Обновляем профиль свежими данными при каждом входе, не перетирая свой аватар.
    let user = sqlx::query(
        "UPDATE profiles
         SET full_name = COALESCE($2, full_name),
             avatar_url = CASE WHEN avatar_custom THEN avatar_url ELSE COALESCE($3, avatar_url) END,
             yandex_login = $4
         WHERE id = $1
         RETURNING *",
    )
    .bind(user.try_get::<Uuid, _>("id").unwrap_or_default())
    .bind(&full_name)
    .bind(&avatar_url)
    .bind(&yandex_login)
    .fetch_one(&state.db)
    .await
    .map_err(|e| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server error during Yandex verification",
        )
        .with_original(e.to_string())
    })?;

    tracing::info!(user_id = ?user.try_get::<Uuid, _>("id").unwrap_or_default(), login = %yandex_login, "User signed in via Yandex");

    token_with_user(&user, secret, "Server error during Yandex verification")
}

// ============================================================================
//  Telegram
// ============================================================================

fn json_value_as_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

fn telegram_full_name(
    first: Option<&str>,
    last: Option<&str>,
    username: Option<&str>,
    telegram_id: &str,
) -> Option<String> {
    let parts = [first, last].into_iter().flatten().collect::<Vec<_>>();
    if !parts.is_empty() {
        Some(parts.join(" "))
    } else if let Some(u) = username {
        Some(u.to_string())
    } else {
        Some(format!("tg_{telegram_id}"))
    }
}

async fn telegram_widget_auth(state: &AppState, data: &Map<String, Value>) -> ApiResult {
    let telegram_id = data.get("id").and_then(json_value_as_string);
    let hash = data.get("hash").and_then(Value::as_str);
    if telegram_id.is_none() || hash.is_none() {
        return Err(ApiError::bad_request("telegramData invalid"));
    }
    let telegram_id = telegram_id.unwrap();

    let Some(bot_token) = state
        .cfg
        .telegram_bot_token
        .as_deref()
        .filter(|s| !s.is_empty())
    else {
        return Err(ApiError::internal("TELEGRAM_BOT_TOKEN not configured"));
    };

    if !verify_telegram_widget_hash(data, bot_token) {
        return Err(ApiError::unauthorized("Invalid Telegram hash"));
    }

    let auth_date = data.get("auth_date").and_then(Value::as_i64);
    if let Some(auth_date) = auth_date {
        let now = Utc::now().timestamp();
        if (now - auth_date).abs() > 86400 {
            return Err(ApiError::unauthorized("Telegram auth expired"));
        }
    } else {
        return Err(ApiError::unauthorized("Telegram auth expired"));
    }

    let username = data.get("username").and_then(Value::as_str);
    let first_name = data.get("first_name").and_then(Value::as_str);
    let last_name = data.get("last_name").and_then(Value::as_str);
    let photo_url = data.get("photo_url").and_then(Value::as_str);

    let full_name = telegram_full_name(first_name, last_name, username, &telegram_id);

    let user = match sqlx::query("SELECT * FROM profiles WHERE telegram_id = $1")
        .bind(&telegram_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Server error during Telegram verification",
            )
            .with_original(e.to_string())
        })? {
        Some(row) => row,
        None => {
            let row = sqlx::query(
                "INSERT INTO profiles (id, telegram_id, telegram_username, full_name, avatar_url)
                 VALUES ($1, $2, $3, $4, $5)
                 RETURNING *",
            )
            .bind(Uuid::new_v4())
            .bind(&telegram_id)
            .bind(&username)
            .bind(&full_name)
            .bind(&photo_url)
            .fetch_one(&state.db)
            .await
            .map_err(|e| {
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Server error during Telegram verification",
                )
                .with_original(e.to_string())
            })?;

            let user_id = row.try_get::<Uuid, _>("id").unwrap_or_default();
            award_achievement(&state, user_id, "hello_world").await;
            row
        }
    };

    let secret = state
        .cfg
        .jwt_secret
        .as_deref()
        .ok_or_else(|| ApiError::internal("Server auth is not configured"))?;

    token_with_user(&user, secret, "Server error during Telegram verification")
}

async fn telegram_token(State(state): State<Arc<AppState>>, body: Body) -> ApiResult {
    let raw_token = body
        .str("telegramIdToken")
        .or_else(|| body.str("idToken"))
        .or_else(|| body.str("token"));

    if raw_token.map(|s| s.is_empty()).unwrap_or(true) {
        if let Some(Value::Object(map)) = body.0.get("telegramData") {
            return telegram_widget_auth(&state, map).await;
        }
        return Err(ApiError::bad_request("telegramIdToken is required"));
    }
    let raw_token = raw_token.unwrap();

    let Some(secret) = state.cfg.jwt_secret.as_deref() else {
        return Err(ApiError::internal("Server auth is not configured"));
    };

    let Some(bot_token) = state
        .cfg
        .telegram_bot_token
        .as_deref()
        .filter(|s| !s.is_empty())
    else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "Telegram sign-in is not configured",
        ));
    };

    let payload = verify_telegram_id_token(raw_token, bot_token)
        .map_err(|e| ApiError::unauthorized(e.message.clone()))?;

    let telegram_id = payload
        .get("sub")
        .or_else(|| payload.get("id"))
        .or_else(|| payload.get("user_id"))
        .or_else(|| payload.get("telegram_id"))
        .and_then(json_value_as_string)
        .filter(|s| !s.is_empty());
    let username = payload
        .get("preferred_username")
        .or_else(|| payload.get("username"))
        .or_else(|| payload.get("login"))
        .and_then(Value::as_str);
    let full_name = payload
        .get("name")
        .and_then(Value::as_str)
        .map(|s| s.to_string())
        .or_else(|| {
            let parts = [
                payload.get("given_name").and_then(Value::as_str),
                payload.get("family_name").and_then(Value::as_str),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
            if !parts.is_empty() {
                Some(parts.join(" "))
            } else {
                None
            }
        })
        .or_else(|| username.map(|s| s.to_string()))
        .or_else(|| telegram_id.as_ref().map(|id| format!("tg_{id}")));
    let avatar_url = payload
        .get("picture")
        .or_else(|| payload.get("photo_url"))
        .and_then(Value::as_str);

    let Some(telegram_id) = telegram_id else {
        return Err(ApiError::unauthorized("Invalid Telegram token payload"));
    };

    let user = match sqlx::query("SELECT * FROM profiles WHERE telegram_id = $1")
        .bind(&telegram_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Server error during Telegram verification",
            )
            .with_original(e.to_string())
        })? {
        Some(row) => row,
        None => {
            let row = sqlx::query(
                "INSERT INTO profiles (id, telegram_id, telegram_username, full_name, avatar_url)
                 VALUES ($1, $2, $3, $4, $5)
                 RETURNING *",
            )
            .bind(Uuid::new_v4())
            .bind(&telegram_id)
            .bind(&username)
            .bind(&full_name)
            .bind(&avatar_url)
            .fetch_one(&state.db)
            .await
            .map_err(|e| {
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Server error during Telegram verification",
                )
                .with_original(e.to_string())
            })?;

            let user_id = row.try_get::<Uuid, _>("id").unwrap_or_default();
            award_achievement(&state, user_id, "hello_world").await;
            tracing::info!(telegram_id = %telegram_id, username = ?username, "New user via Telegram");
            row
        }
    };

    let user = sqlx::query(
        "UPDATE profiles
         SET telegram_username = COALESCE($2, telegram_username),
             full_name = COALESCE($3, full_name),
             avatar_url = CASE WHEN avatar_custom THEN avatar_url ELSE COALESCE($4, avatar_url) END
         WHERE id = $1
         RETURNING *",
    )
    .bind(user.try_get::<Uuid, _>("id").unwrap_or_default())
    .bind(&username)
    .bind(&full_name)
    .bind(&avatar_url)
    .fetch_one(&state.db)
    .await
    .map_err(|e| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server error during Telegram verification",
        )
        .with_original(e.to_string())
    })?;

    tracing::info!(telegram_id = %telegram_id, username = ?username, "User sign-in via Telegram");

    token_with_user(&user, secret, "Server error during Telegram verification")
}

// ============================================================================
//  Apple
// ============================================================================

fn normalize_name(body: &Body) -> Option<String> {
    let first = body.str("firstName").map(|s| s.trim());
    let last = body.str("lastName").map(|s| s.trim());
    let full = body.str("fullName").map(|s| s.trim());

    let from_parts: Vec<&str> = [first, last].into_iter().flatten().collect();

    let raw = if !from_parts.is_empty() {
        from_parts.join(" ")
    } else if let Some(f) = full {
        f.to_string()
    } else {
        String::new()
    };

    if raw.is_empty() {
        None
    } else {
        Some(raw.chars().take(120).collect())
    }
}

fn is_truthy_flag(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(true)) => true,
        Some(Value::String(s)) if s == "true" || s == "1" => true,
        _ => false,
    }
}

fn constant_time_eq(expected: &str, actual: &str) -> bool {
    let a = expected.as_bytes();
    let b = actual.as_bytes();
    if a.len() != b.len() {
        return false;
    }
    a.iter()
        .zip(b.iter())
        .fold(0u8, |diff, (x, y)| diff | (x ^ y))
        == 0
}

async fn verify_apple_identity_token(
    state: &AppState,
    token: &str,
    raw_nonce: Option<&str>,
) -> Result<Value, ApiError> {
    let header = jsonwebtoken::decode_header(token)
        .map_err(|_| ApiError::unauthorized("Invalid Apple token"))?;
    let kid = header
        .kid
        .as_deref()
        .ok_or_else(|| ApiError::unauthorized("Unexpected Apple token header"))?;

    let Some(key) = state.apple_jwks.decoding_key(&state.http, kid).await else {
        // Если ключа нет — выясняем, недоступен ли Apple, чтобы сохранить 502-ответ Node.
        let reachable: bool = state
            .http
            .get("https://appleid.apple.com/auth/keys")
            .header("accept", "application/json")
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false);
        if !reachable {
            return Err(ApiError::new(
                StatusCode::BAD_GATEWAY,
                "Apple is unreachable, try again",
            ));
        }
        return Err(ApiError::unauthorized("Apple signing key not found"));
    };

    if header.alg != Algorithm::RS256 {
        return Err(ApiError::unauthorized("Unexpected Apple token header"));
    }

    let mut validation = Validation::new(Algorithm::RS256);
    validation.validate_exp = true;
    validation.required_spec_claims.clear();
    validation.validate_aud = false;
    validation.set_issuer(&["https://appleid.apple.com"]);
    let audiences: Vec<&str> = state
        .cfg
        .apple_service_id
        .as_ref()
        .map(|svc| vec![svc.as_str(), state.cfg.apple_bundle_id.as_str()])
        .unwrap_or_else(|| vec![state.cfg.apple_bundle_id.as_str()]);
    validation.set_audience(&audiences);

    let data = jsonwebtoken::decode::<Value>(token, &key, &validation)
        .map_err(|_| ApiError::unauthorized("Invalid Apple token"))?;
    let payload = data.claims;

    if raw_nonce.is_none() || payload.get("nonce").is_none() {
        return Err(ApiError::unauthorized("Missing nonce"));
    }
    let raw_nonce = raw_nonce.unwrap();

    let digest = {
        let mut h = Sha256::new();
        h.update(raw_nonce.as_bytes());
        h.finalize()
    };
    let expected_b64url = URL_SAFE_NO_PAD.encode(&digest);
    let expected_hex = hex::encode(&digest);
    let provided = payload.get("nonce").and_then(Value::as_str).unwrap_or("");

    if !constant_time_eq(&expected_b64url, provided) && !constant_time_eq(&expected_hex, provided) {
        return Err(ApiError::unauthorized("Nonce mismatch"));
    }

    if payload.get("sub").is_none() {
        return Err(ApiError::unauthorized("Apple token has no subject"));
    }

    Ok(payload)
}

async fn apple_token(State(state): State<Arc<AppState>>, body: Body) -> ApiResult {
    let Some(id_token) = body.str("idToken") else {
        return Err(ApiError::bad_request("idToken is required"));
    };

    let Some(secret) = state.cfg.jwt_secret.as_deref() else {
        return Err(ApiError::internal("Server auth is not configured"));
    };

    let payload = match verify_apple_identity_token(&state, id_token, body.str("nonce")).await {
        Ok(v) => v,
        Err(e) => {
            return Err(match e.status {
                StatusCode::UNAUTHORIZED => ApiError::unauthorized("Invalid Apple token"),
                StatusCode::BAD_GATEWAY => {
                    ApiError::new(StatusCode::BAD_GATEWAY, "Apple is unreachable, try again")
                }
                _ => ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Server error during Apple token verification",
                )
                .with_original(e.error),
            });
        }
    };

    let apple_id = payload.get("sub").and_then(Value::as_str).unwrap_or("");
    let email = payload
        .get("email")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from);
    let email_relayed = is_truthy_flag(payload.get("is_private_email"));
    let full_name = normalize_name(&body);

    let user = match sqlx::query("SELECT * FROM profiles WHERE apple_id = $1")
        .bind(apple_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Server error during Apple token verification",
            )
            .with_original(e.to_string())
        })? {
        Some(row) => row,
        None => {
            let email_to_insert: Option<String> = if let Some(ref email) = email {
                let exists = sqlx::query("SELECT id FROM profiles WHERE email = $1")
                    .bind(email)
                    .fetch_optional(&state.db)
                    .await
                    .map_err(|e| {
                        ApiError::new(
                            StatusCode::INTERNAL_SERVER_ERROR,
                            "Server error during Apple token verification",
                        )
                        .with_original(e.to_string())
                    })?;
                if exists.is_some() {
                    None
                } else {
                    Some(email.clone())
                }
            } else {
                None
            };

            let row = sqlx::query(
                "INSERT INTO profiles (id, apple_id, full_name, email, apple_email_relayed)
                 VALUES ($1, $2, $3, $4, $5)
                 RETURNING *",
            )
            .bind(Uuid::new_v4())
            .bind(apple_id)
            .bind(&full_name)
            .bind(&email_to_insert)
            .bind(email_relayed)
            .fetch_one(&state.db)
            .await
            .map_err(|e| {
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Server error during Apple token verification",
                )
                .with_original(e.to_string())
            })?;

            let user_id = row.try_get::<Uuid, _>("id").unwrap_or_default();
            award_achievement(&state, user_id, "hello_world").await;
            tracing::info!(full_name = ?full_name, "New user created via Sign in with Apple");
            row
        }
    };

    let user = sqlx::query(
        "UPDATE profiles
         SET full_name = COALESCE($2, full_name),
             apple_email_relayed = COALESCE($3, apple_email_relayed)
         WHERE id = $1
         RETURNING *",
    )
    .bind(user.try_get::<Uuid, _>("id").unwrap_or_default())
    .bind(&full_name)
    .bind(email_relayed)
    .fetch_one(&state.db)
    .await
    .map_err(|e| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server error during Apple token verification",
        )
        .with_original(e.to_string())
    })?;

    tracing::info!(user_id = ?user.try_get::<Uuid, _>("id").unwrap_or_default(), "User signed in via Sign in with Apple");

    token_with_user(
        &user,
        secret,
        "Server error during Apple token verification",
    )
}

// ============================================================================
//  Удаление аккаунта
// ============================================================================

fn remaining_days(purge_at: DateTime<Utc>) -> i64 {
    let now = Utc::now();
    if purge_at <= now {
        return 0;
    }
    let ms = purge_at.signed_duration_since(now).num_milliseconds() as f64;
    let days = ms / 86_400_000.0;
    days.ceil().max(0.0) as i64
}

async fn get_account(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let user_id = auth.id;

    let result = async {
        let row =
            sqlx::query("SELECT deletion_purge_at, deletion_reason FROM profiles WHERE id = $1")
                .bind(user_id)
                .fetch_optional(&state.db)
                .await
                .map_err(|e| {
                    ApiError::new(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "Сервер занят, попробуйте чуть позже",
                    )
                    .with_original(e.to_string())
                })?
                .ok_or_else(|| ApiError::not_found("Профиль не найден"))?;

        let purge_at: Option<DateTime<Utc>> = row.try_get("deletion_purge_at").ok();
        let reason: Option<String> = row.try_get("deletion_reason").ok();

        ok_json(json!({
            "deletion_scheduled_at": purge_at.map(ts),
            "days_left": purge_at.map(remaining_days),
            "reason": reason,
        }))
    }
    .await;

    result
}

async fn delete_account(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    body: Body,
) -> ApiResult {
    let user_id = auth.id;

    let result = async {
        if body.bool("acknowledged") != Some(true) {
            return Err(ApiError::bad_request(
                "Нужно подтверждение удаления (acknowledged = true)",
            ));
        }

        if let Some(value) = body.0.get("reason") {
            let reason_str = value.as_str();
            if reason_str.is_none() || reason_str.unwrap().len() > MAX_DELETION_REASON_LENGTH {
                return Err(ApiError::bad_request("Причина слишком длинная"));
            }
        }
        let reason: Option<&str> = body.str("reason");

        let mut tx = state.db.begin().await.map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        let role_row = sqlx::query("SELECT role FROM profiles WHERE id = $1")
            .bind(user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| {
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Сервер занят, попробуйте чуть позже",
                )
                .with_original(e.to_string())
            })?;

        let Some(role_row) = role_row else {
            return Err(ApiError::not_found("Профиль не найден"));
        };
        let role: String = role_row.try_get("role").unwrap_or_default();
        if role == "admin" {
            return Err(ApiError::forbidden(
                "Учётную запись администратора удаляет владелец сервиса",
            ));
        }

        let scheduled = sqlx::query(
            "UPDATE profiles
             SET deletion_purge_at = now() + ($2::int * interval '1 day'),
                 deletion_reason   = $3
           WHERE id = $1
             AND deletion_purge_at IS NULL
           RETURNING deletion_purge_at",
        )
        .bind(user_id)
        .bind(DELETION_GRACE_DAYS)
        .bind(reason)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        let Some(scheduled) = scheduled else {
            tx.rollback().await.map_err(|e| {
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Сервер занят, попробуйте чуть позже",
                )
                .with_original(e.to_string())
            })?;
            let open = sqlx::query("SELECT deletion_purge_at FROM profiles WHERE id = $1")
                .bind(user_id)
                .fetch_optional(&state.db)
                .await
                .map_err(|e| {
                    ApiError::new(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "Сервер занят, попробуйте чуть позже",
                    )
                    .with_original(e.to_string())
                })?
                .ok_or_else(|| ApiError::not_found("Профиль не найден"))?;
            let purge_at: Option<DateTime<Utc>> = open.try_get("deletion_purge_at").ok();
            return Err(ApiError::conflict("Удаление уже запланировано")
                .with_extra("deletion_scheduled_at", json!(purge_at.map(ts))));
        };

        let purge_at: DateTime<Utc> = scheduled.try_get("deletion_purge_at").map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        sqlx::query(
            "INSERT INTO account_deletion_audit
                (user_id, purge_at, acknowledged, reason)
             VALUES ($1, $2::timestamptz, true, $3)",
        )
        .bind(user_id)
        .bind(purge_at)
        .bind(reason)
        .execute(&mut *tx)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        tx.commit().await.map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        tracing::info!(%user_id, days = DELETION_GRACE_DAYS, "Account deletion scheduled");

        ok_json(json!({
            "deletion_scheduled_at": ts(purge_at),
            "days_left": DELETION_GRACE_DAYS,
        }))
    }
    .await;

    result
}

async fn restore_account(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let user_id = auth.id;

    let result = async {
        let mut tx = state.db.begin().await.map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        let cancelled = sqlx::query(
            "UPDATE profiles
             SET deletion_purge_at = NULL,
                 deletion_reason   = NULL
           WHERE id = $1
             AND deletion_purge_at IS NOT NULL
           RETURNING id",
        )
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        if cancelled.is_none() {
            tx.rollback().await.map_err(|e| {
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Сервер занят, попробуйте чуть позже",
                )
                .with_original(e.to_string())
            })?;
            return Err(ApiError::not_found("Удаление не запланировано"));
        }

        sqlx::query(
            "UPDATE account_deletion_audit
             SET resolved_at = now(),
                 outcome     = 'cancelled'
           WHERE user_id = $1
             AND resolved_at IS NULL",
        )
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        tx.commit().await.map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Сервер занят, попробуйте чуть позже",
            )
            .with_original(e.to_string())
        })?;

        ok_json(json!({ "restored": true }))
    }
    .await;

    result
}

// ============================================================================
//  Router
// ============================================================================

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/google/token", post(google_token))
        .route("/google/exchange", post(google_exchange))
        .route("/yandex/token", post(yandex_token))
        .route("/telegram/token", post(telegram_token))
        .route("/apple/token", post(apple_token))
        .route("/account", get(get_account).delete(delete_account))
        .route("/account/restore", post(restore_account))
}
