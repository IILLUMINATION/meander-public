//! JWKS-backed RS256 verification for Google and Apple identity tokens.
//!
//! The Node backend delegated this to `google-auth-library` and Apple's key
//! endpoint; both boil down to: fetch a JWKS, pick the key by `kid`, verify the
//! signature, then check `iss`/`aud`/`exp`.

use std::time::{Duration, Instant};

use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::RwLock;

const JWKS_TTL: Duration = Duration::from_secs(60 * 60);

#[derive(Debug, Clone, Deserialize)]
struct Jwk {
    kid: String,
    n: String,
    e: String,
}

#[derive(Debug, Deserialize)]
struct Jwks {
    keys: Vec<Jwk>,
}

pub struct JwksCache {
    url: String,
    keys: RwLock<Option<(Instant, Vec<Jwk>)>>,
}

impl JwksCache {
    pub fn new(url: &str) -> Self {
        Self {
            url: url.to_string(),
            keys: RwLock::new(None),
        }
    }

    async fn keys(&self, http: &reqwest::Client) -> Option<Vec<Jwk>> {
        if let Some((fetched, keys)) = self.keys.read().await.as_ref()
            && fetched.elapsed() < JWKS_TTL
        {
            return Some(keys.clone());
        }
        let response = http
            .get(&self.url)
            .send()
            .await
            .ok()?
            .error_for_status()
            .ok()?;
        let jwks: Jwks = response.json().await.ok()?;
        *self.keys.write().await = Some((Instant::now(), jwks.keys.clone()));
        Some(jwks.keys)
    }

    pub async fn decoding_key(&self, http: &reqwest::Client, kid: &str) -> Option<DecodingKey> {
        let keys = self.keys(http).await?;
        let jwk = keys.iter().find(|k| k.kid == kid)?;
        DecodingKey::from_rsa_components(&jwk.n, &jwk.e).ok()
    }
}

/// Verifies an RS256 JWT against a JWKS. Returns the payload only when the
/// signature, issuer and audience all match.
pub async fn verify_identity_token(
    cache: &JwksCache,
    http: &reqwest::Client,
    token: &str,
    issuers: &[&str],
    audiences: &[&str],
) -> Option<Value> {
    let header = jsonwebtoken::decode_header(token).ok()?;
    if header.alg != Algorithm::RS256 {
        return None;
    }
    let key = cache.decoding_key(http, header.kid.as_deref()?).await?;

    let mut validation = Validation::new(Algorithm::RS256);
    validation.required_spec_claims.clear();
    validation.validate_exp = true;
    validation.validate_aud = false;
    let data = jsonwebtoken::decode::<Value>(token, &key, &validation).ok()?;
    let claims = data.claims;

    let iss = claims.get("iss")?.as_str()?;
    if !issuers.contains(&iss) {
        return None;
    }
    let aud_ok = match claims.get("aud")? {
        Value::String(aud) => audiences.iter().any(|a| *a == aud),
        Value::Array(items) => items
            .iter()
            .filter_map(Value::as_str)
            .any(|aud| audiences.contains(&aud)),
        _ => false,
    };
    aud_ok.then_some(claims)
}
