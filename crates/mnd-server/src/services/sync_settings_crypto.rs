//! Port of `sync_settings_crypto.ts`.
//!
//! AES-256-GCM encryption for the GitHub sync token stored in
//! `profile_sync_settings`. The format matches the Node implementation exactly:
//! `ciphertext`, `iv`, and `tag` are separate base64 strings, and an empty
//! plaintext becomes three empty strings.

use std::sync::LazyLock;

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::{AeadCore, AeadInPlace, Key, KeyInit, Nonce, Tag};
use base64::Engine;
use base64::prelude::BASE64_STANDARD;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::ApiError;

/// The shape stored in `profile_sync_settings` and returned to callers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedToken {
    pub ciphertext: String,
    pub iv: String,
    pub tag: String,
}

impl Default for EncryptedToken {
    fn default() -> Self {
        Self {
            ciphertext: String::new(),
            iv: String::new(),
            tag: String::new(),
        }
    }
}

fn build_cipher() -> Result<Aes256Gcm, String> {
    let secret = std::env::var("SYNC_SETTINGS_SECRET")
        .map_err(|_| "SYNC_SETTINGS_SECRET is not configured".to_string())?;
    if secret.trim().len() < 16 {
        return Err("SYNC_SETTINGS_SECRET is not configured".to_string());
    }

    let mut hasher = Sha256::new();
    hasher.update(secret.trim().as_bytes());
    let key_bytes = hasher.finalize();
    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    Ok(Aes256Gcm::new(key))
}

static CIPHER: LazyLock<Result<Aes256Gcm, String>> = LazyLock::new(build_cipher);

fn cipher() -> Result<&'static Aes256Gcm, ApiError> {
    CIPHER.as_ref().map_err(|e| ApiError::internal(e.clone()))
}

fn b64_decode(input: &str) -> Result<Vec<u8>, ApiError> {
    BASE64_STANDARD
        .decode(input)
        .map_err(|e| ApiError::internal(format!("invalid base64: {e}")))
}

/// Encrypt a plaintext token. Returns empty strings for blank input.
///
/// Errors only if `SYNC_SETTINGS_SECRET` is missing or too short.
pub fn encrypt_token(plain: &str) -> Result<EncryptedToken, ApiError> {
    if plain.trim().is_empty() {
        return Ok(EncryptedToken::default());
    }

    let cipher = cipher()?;
    let nonce = Aes256Gcm::generate_nonce(&mut rand::rngs::OsRng);
    let mut buffer = plain.as_bytes().to_vec();
    let tag = cipher
        .encrypt_in_place_detached(&nonce, b"", &mut buffer)
        .map_err(|e| ApiError::internal(format!("encryption failed: {e}")))?;

    Ok(EncryptedToken {
        ciphertext: BASE64_STANDARD.encode(&buffer),
        iv: BASE64_STANDARD.encode(nonce.as_slice()),
        tag: BASE64_STANDARD.encode(tag.as_slice()),
    })
}

/// Decrypt a token. Missing inputs return an empty string.
///
/// Any failure to decode or authenticate yields `ApiError::internal`.
pub fn decrypt_token(
    ciphertext: Option<&str>,
    iv: Option<&str>,
    tag: Option<&str>,
) -> Result<String, ApiError> {
    let (Some(ct), Some(iv), Some(tag)) = (ciphertext, iv, tag) else {
        return Ok(String::new());
    };
    if ct.is_empty() || iv.is_empty() || tag.is_empty() {
        return Ok(String::new());
    }

    let cipher = cipher()?;
    let iv_bytes = b64_decode(iv)?;
    let tag_bytes = b64_decode(tag)?;
    let mut buffer = b64_decode(ct)?;
    let nonce = Nonce::<Aes256Gcm>::from_slice(&iv_bytes);
    let auth_tag = Tag::<Aes256Gcm>::from_slice(&tag_bytes);

    cipher
        .decrypt_in_place_detached(nonce, b"", &mut buffer, auth_tag)
        .map_err(|e| ApiError::internal(format!("decryption failed: {e}")))?;

    String::from_utf8(buffer)
        .map_err(|e| ApiError::internal(format!("decrypted token is not valid utf-8: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ensure_secret() {
        // Safety: tests run single-threaded for the crypto module.
        unsafe {
            std::env::set_var(
                "SYNC_SETTINGS_SECRET",
                "test-secret-longer-than-16-characters",
            );
        }
    }

    #[test]
    fn empty_plaintext_rounds_to_empty() {
        ensure_secret();
        let encrypted = encrypt_token("").unwrap();
        assert!(encrypted.ciphertext.is_empty());
        assert!(encrypted.iv.is_empty());
        assert!(encrypted.tag.is_empty());

        let decrypted = decrypt_token(
            Some(&encrypted.ciphertext),
            Some(&encrypted.iv),
            Some(&encrypted.tag),
        )
        .unwrap();
        assert_eq!(decrypted, "");
    }

    #[test]
    fn aes_256_gcm_round_trip() {
        ensure_secret();
        let plain = "github_pat_12345_abcXYZ";
        let encrypted = encrypt_token(plain).unwrap();

        assert!(!encrypted.ciphertext.is_empty());
        assert!(!encrypted.iv.is_empty());
        assert!(!encrypted.tag.is_empty());

        let decrypted = decrypt_token(
            Some(&encrypted.ciphertext),
            Some(&encrypted.iv),
            Some(&encrypted.tag),
        )
        .unwrap();
        assert_eq!(decrypted, plain);
    }

    #[test]
    fn missing_parts_return_empty() {
        ensure_secret();
        assert_eq!(decrypt_token(None, None, None).unwrap(), "");
        assert_eq!(decrypt_token(Some("x"), None, None).unwrap(), "");
        assert_eq!(decrypt_token(Some("x"), Some("y"), None).unwrap(), "");
    }

    #[test]
    fn tampered_ciphertext_fails() {
        ensure_secret();
        let encrypted = encrypt_token("sensitive").unwrap();
        let tampered = format!("{}=", encrypted.ciphertext);
        assert!(decrypt_token(Some(&tampered), Some(&encrypted.iv), Some(&encrypted.tag)).is_err());
    }
}
