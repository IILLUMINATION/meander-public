//! Порт `backend/src/services/telegram_jwt.ts`.
//!
//! Проверяет id_token от Telegram Login Widget HMAC-SHA256 ключом SHA256(bot_token)
//! (и запасным вариантом — сырым bot_token).  Дополнительно позволяет
//! проверить подпись старого виджета (`telegramData` + `hash`) тем же ключом.

use base64::Engine;
use hmac::{Hmac, Mac};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

#[derive(Debug)]
pub struct TelegramTokenError {
    pub message: String,
}

impl TelegramTokenError {
    pub fn unauthorized(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl std::fmt::Display for TelegramTokenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for TelegramTokenError {}

fn base64_url_decode(input: &str) -> Result<String, TelegramTokenError> {
    let mut s = input.replace('-', "+").replace('_', "/");
    while s.len() % 4 != 0 {
        s.push('=');
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&s)
        .map_err(|_| TelegramTokenError::unauthorized("Invalid JWT encoding"))?;
    String::from_utf8(bytes).map_err(|_| TelegramTokenError::unauthorized("Invalid JWT encoding"))
}

fn signatures_match(expected: &str, actual: &str) -> bool {
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

fn hmac_sha256_base64url(key: &[u8], data: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC key length is valid");
    mac.update(data.as_bytes());
    let result = mac.finalize();
    let bytes = result.into_bytes();
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&bytes)
}

/// Проверка JWT id_token, выписанного Telegram.
pub fn verify_telegram_id_token(
    id_token: &str,
    bot_token: &str,
) -> Result<Value, TelegramTokenError> {
    if bot_token.is_empty() {
        return Err(TelegramTokenError::unauthorized(
            "Telegram sign-in is not configured",
        ));
    }

    let parts: Vec<&str> = id_token.split('.').collect();
    if parts.len() != 3 {
        return Err(TelegramTokenError::unauthorized("Invalid JWT format"));
    }

    let header: Value = serde_json::from_str(&base64_url_decode(parts[0])?)
        .map_err(|_| TelegramTokenError::unauthorized("Invalid JWT encoding"))?;
    let payload: Value = serde_json::from_str(&base64_url_decode(parts[1])?)
        .map_err(|_| TelegramTokenError::unauthorized("Invalid JWT encoding"))?;

    if header.get("alg").and_then(Value::as_str) != Some("HS256") {
        return Err(TelegramTokenError::unauthorized(
            "Unsupported Telegram token algorithm",
        ));
    }

    let data = format!("{}.{}", parts[0], parts[1]);

    // Telegram подписывает id_token ключом SHA256(bot_token); для старых сборок
    // допускаем и сырой bot_token.
    let derived_key = {
        let mut h = Sha256::new();
        h.update(bot_token.as_bytes());
        h.finalize()
    };

    let expected = hmac_sha256_base64url(&derived_key, &data);
    let expected_raw = hmac_sha256_base64url(bot_token.as_bytes(), &data);

    let signature = parts[2];
    if !signatures_match(&expected, signature) && !signatures_match(&expected_raw, signature) {
        return Err(TelegramTokenError::unauthorized(
            "Invalid Telegram token signature",
        ));
    }

    if let Some(exp) = payload.get("exp").and_then(Value::as_i64) {
        let now = chrono::Utc::now().timestamp();
        if now > exp {
            return Err(TelegramTokenError::unauthorized("Telegram token expired"));
        }
    }

    Ok(payload)
}

fn widget_value_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => v.to_string(),
    }
}

/// Проверяет `hash` в данных виджета Telegram Login Widget.
pub fn verify_telegram_widget_hash(data: &Map<String, Value>, bot_token: &str) -> bool {
    if bot_token.is_empty() {
        return false;
    }
    if data.get("hash").is_none() {
        return false;
    }
    let mut pairs: Vec<String> = data
        .iter()
        .filter(|(k, _)| *k != "hash")
        .map(|(k, v)| format!("{}={}", k, widget_value_string(v)))
        .collect();
    pairs.sort();
    let check_string = pairs.join("\n");

    let secret = {
        let mut h = Sha256::new();
        h.update(bot_token.as_bytes());
        h.finalize()
    };

    let mut mac = Hmac::<Sha256>::new_from_slice(&secret).expect("HMAC key length is valid");
    mac.update(check_string.as_bytes());
    let result = mac.finalize();
    let expected = hex::encode(result.into_bytes());
    let actual = data.get("hash").and_then(Value::as_str).unwrap_or("");
    signatures_match(&expected, actual)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use chrono::Utc;
    use serde_json::json;

    fn base64url(value: Value) -> String {
        let json = value.to_string();
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json.as_bytes())
    }

    #[test]
    fn verify_valid_id_token_with_derived_key() {
        let bot_token = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11";
        let header = base64url(json!({"alg":"HS256","typ":"JWT"}));
        let exp = Utc::now().timestamp() + 300;
        let payload = base64url(json!({"sub":"42","username":"me","exp":exp}));
        let data = format!("{}.{}", header, payload);

        let derived = {
            let mut h = Sha256::new();
            h.update(bot_token.as_bytes());
            h.finalize()
        };
        let signature = hmac_sha256_base64url(&derived, &data);
        let token = format!("{}.{}", data, signature);

        let result = verify_telegram_id_token(&token, bot_token).unwrap();
        assert_eq!(result.get("sub").and_then(Value::as_str), Some("42"));
    }

    #[test]
    fn reject_expired_token() {
        let bot_token = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11";
        let header = base64url(json!({"alg":"HS256","typ":"JWT"}));
        let payload = base64url(json!({"sub":"42","exp":1}));
        let data = format!("{}.{}", header, payload);
        let derived = {
            let mut h = Sha256::new();
            h.update(bot_token.as_bytes());
            h.finalize()
        };
        let signature = hmac_sha256_base64url(&derived, &data);
        let token = format!("{}.{}", data, signature);

        assert!(verify_telegram_id_token(&token, bot_token).is_err());
    }

    #[test]
    fn reject_bad_signature() {
        let bot_token = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11";
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMifQ.wrong";
        assert!(verify_telegram_id_token(token, bot_token).is_err());
    }

    #[test]
    fn widget_hash_accepts_valid_signature() {
        let bot_token = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11";
        let mut data = Map::new();
        data.insert("auth_date".into(), json!(1_700_000_000i64));
        data.insert("id".into(), json!(42));
        data.insert("username".into(), json!("me"));

        let mut pairs: Vec<String> = data
            .iter()
            .map(|(k, v)| format!("{}={}", k, widget_value_string(v)))
            .collect();
        pairs.sort();
        let check_string = pairs.join("\n");
        let secret = {
            let mut h = Sha256::new();
            h.update(bot_token.as_bytes());
            h.finalize()
        };
        let mut mac = Hmac::<Sha256>::new_from_slice(&secret).unwrap();
        mac.update(check_string.as_bytes());
        let hash = hex::encode(mac.finalize().into_bytes());
        data.insert("hash".into(), json!(hash));

        assert!(verify_telegram_widget_hash(&data, bot_token));
    }
}
