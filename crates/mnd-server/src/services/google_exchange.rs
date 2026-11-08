//! Порт `backend/src/services/google_exchange.ts`.
//!
//! Обмен authorization code → id_token для desktop-входа Google.  Секрет
//! desktop-клиента и правила проверки redirect URI/PKCE остаются в точности
//! как в Node-реализации.

use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;
use reqwest::Client;
use url::Url;

const GOOGLE_TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";

static LOOPBACK_HOSTS: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    ["localhost", "127.0.0.1", "[::1]"]
        .iter()
        .copied()
        .collect()
});

static PKCE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[A-Za-z0-9._~-]{43,128}$").expect("PKCE verifier regex is valid")
});

/// Входные данные от клиента.
pub struct GoogleExchangeInput {
    pub code: String,
    pub code_verifier: String,
    pub redirect_uri: String,
}

/// Учётные данные сервер-сервер обмена.
pub struct GoogleExchangeConfig {
    pub client_id: String,
    pub client_secret: String,
}

#[derive(Debug)]
pub struct GoogleExchangeError(pub String);

impl std::fmt::Display for GoogleExchangeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for GoogleExchangeError {}

/** Только http(s) на loopback: auth-сервер приложения слушает 127.0.0.1. */
pub fn is_loopback_redirect(raw: &str) -> bool {
    if raw.is_empty() || raw.len() > 2048 {
        return false;
    }
    let url = match Url::parse(raw) {
        Ok(u) => u,
        Err(_) => return false,
    };
    if !matches!(url.scheme(), "http" | "https") {
        return false;
    }
    if !url.username().is_empty() || url.password().is_some() {
        return false;
    }
    LOOPBACK_HOSTS.contains(url.host_str().unwrap_or(""))
}

/** PKCE: 43–128 символов из unreserved-набора (RFC 7636). */
pub fn is_pkce_verifier(raw: &str) -> bool {
    PKCE_RE.is_match(raw)
}

pub async fn exchange_google_code(
    http: &Client,
    input: &GoogleExchangeInput,
    config: &GoogleExchangeConfig,
) -> Result<String, GoogleExchangeError> {
    let params = [
        ("grant_type", "authorization_code"),
        ("code", &input.code),
        ("client_id", &config.client_id),
        ("client_secret", &config.client_secret),
        ("code_verifier", &input.code_verifier),
        ("redirect_uri", &input.redirect_uri),
    ];

    let response = http
        .post(GOOGLE_TOKEN_ENDPOINT)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .form(&params)
        .send()
        .await
        .map_err(|e| GoogleExchangeError(format!("Google token request failed: {e}")))?;

    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|e| GoogleExchangeError(format!("failed to read Google response: {e}")))?;

    if !status.is_success() {
        return Err(GoogleExchangeError(format!(
            "Google token endpoint answered {status}: {}",
            text.chars().take(500).collect::<String>()
        )));
    }

    let data: serde_json::Value = serde_json::from_str(&text)
        .map_err(|_| GoogleExchangeError("Google token endpoint returned invalid JSON".into()))?;

    let id_token = data
        .get("id_token")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty());

    id_token
        .map(|s| s.to_string())
        .ok_or_else(|| GoogleExchangeError("Google token endpoint returned no id_token".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_verifier_validates_known_ok() {
        // 43–128 unreserved chars: RFC 7636 example.
        assert!(is_pkce_verifier(
            "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjX1"
        ));
    }

    #[test]
    fn pkce_rejects_too_short_and_special_chars() {
        // Too short.
        assert!(!is_pkce_verifier("abcABC123"));
        // Special chars not allowed.
        assert!(!is_pkce_verifier(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!"
        ));
    }

    #[test]
    fn loopback_accepts_ipv4_localhost_and_ipv6() {
        assert!(is_loopback_redirect("http://127.0.0.1:8080/callback"));
        assert!(is_loopback_redirect("https://localhost:8080/callback"));
        assert!(is_loopback_redirect("http://[::1]:8080/callback"));
    }

    #[test]
    fn loopback_rejects_non_loopback_and_crap() {
        assert!(!is_loopback_redirect("https://example.com/callback"));
        assert!(!is_loopback_redirect("not-a-url"));
        assert!(!is_loopback_redirect(""));
        assert!(!is_loopback_redirect("ftp://127.0.0.1/callback"));
    }
}
