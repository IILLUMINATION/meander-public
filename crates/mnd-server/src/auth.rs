//! Authentication: JWT verification, the account-state cache and the three
//! axum extractors that replace `authMiddleware` / `optionalAuthMiddleware` /
//! `adminAuth`.
//!
//! Behavioural notes that are easy to lose in a port:
//! * a missing `JWT_SECRET` on a protected route is a 500, not a 401;
//! * expired/invalid tokens answer 401 with `code: TOKEN_INVALID` — never 403,
//!   because the client resets the session on 401 only;
//! * blocked accounts answer 403 `ACCOUNT_BLOCKED`, revoked tokens 401
//!   `TOKEN_REVOKED`;
//! * `last_seen_at` writes are throttled to one per two minutes per user and
//!   never block the response.

use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde_json::Value;
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::error::ApiError;
use crate::state::{AccountState, AppState, CachedAccount};

const ACCOUNT_CACHE_TTL: Duration = Duration::from_secs(30);
const LAST_SEEN_THROTTLE: Duration = Duration::from_secs(2 * 60);
const VISIT_THROTTLE: Duration = Duration::from_secs(30 * 60);

#[derive(Debug, Clone)]
pub struct AuthUser {
    pub id: Uuid,
    pub role: Option<String>,
    /// `token_version` claim (`tv`); absent means 0.
    pub tv: i64,
    pub payload: Value,
}

#[derive(Debug, Clone)]
pub struct OptionalAuth(pub Option<AuthUser>);

impl OptionalAuth {
    pub fn user(&self) -> Option<&AuthUser> {
        self.0.as_ref()
    }

    pub fn id(&self) -> Option<Uuid> {
        self.0.as_ref().map(|u| u.id)
    }
}

/// `getBearerToken` from the Node middleware: exactly two space-separated
/// parts, scheme must be `Bearer`, token must be non-empty.
fn bearer_token(header: Option<&str>) -> Option<&str> {
    let header = header?;
    let mut parts = header.split(' ');
    let scheme = parts.next()?;
    let token = parts.next()?;
    if scheme != "Bearer" || token.is_empty() {
        return None;
    }
    Some(token)
}

fn verify(secret: &str, token: &str) -> Option<Value> {
    let mut validation = Validation::new(Algorithm::HS256);
    // node-jsonwebtoken does not require an `exp` claim, it only honours one.
    validation.required_spec_claims.clear();
    validation.validate_exp = true;
    validation.validate_aud = false;
    let data = jsonwebtoken::decode::<Value>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )
    .ok()?;
    // Signed *strings* are not tokens this service ever issued.
    if data.claims.is_object() {
        Some(data.claims)
    } else {
        None
    }
}

fn claims_user(payload: Value) -> Option<AuthUser> {
    let id = payload.get("id")?.as_str()?;
    let id = Uuid::parse_str(id).ok()?;
    let role = payload
        .get("role")
        .and_then(Value::as_str)
        .map(str::to_string);
    let tv = match payload.get("tv") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    };
    Some(AuthUser {
        id,
        role,
        tv,
        payload,
    })
}

/// Reads account state with the 30-second cache. Database failures degrade to
/// "not blocked" exactly like the Node implementation: a broken read must not
/// lock every user out.
pub async fn account_state(state: &Arc<AppState>, user_id: Uuid) -> AccountState {
    if let Some(cached) = state.accounts.get(&user_id)
        && cached.fetched_at.elapsed() < ACCOUNT_CACHE_TTL
    {
        return cached.state;
    }

    let fresh = match sqlx::query("SELECT is_blocked, token_version FROM profiles WHERE id = $1")
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
    {
        Ok(row) => {
            use sqlx::Row;
            match row {
                Some(row) => AccountState {
                    blocked: row
                        .try_get::<Option<bool>, _>("is_blocked")
                        .ok()
                        .flatten()
                        .unwrap_or(false),
                    token_version: row
                        .try_get::<Option<i32>, _>("token_version")
                        .ok()
                        .flatten()
                        .map(i64::from),
                },
                None => AccountState {
                    blocked: false,
                    token_version: Some(0),
                },
            }
        }
        Err(err) => {
            // Pre-migration databases have no token_version column.
            if matches!(&err, sqlx::Error::Database(db) if db.code().as_deref() == Some("42703")) {
                match sqlx::query("SELECT is_blocked FROM profiles WHERE id = $1")
                    .bind(user_id)
                    .fetch_optional(&state.db)
                    .await
                {
                    Ok(row) => {
                        use sqlx::Row;
                        AccountState {
                            blocked: row
                                .and_then(|r| {
                                    r.try_get::<Option<bool>, _>("is_blocked").ok().flatten()
                                })
                                .unwrap_or(false),
                            token_version: None,
                        }
                    }
                    Err(err) => {
                        tracing::error!(error = %err, "[auth] block status check failed");
                        AccountState {
                            blocked: false,
                            token_version: None,
                        }
                    }
                }
            } else {
                tracing::error!(error = %err, "[auth] account state check failed");
                AccountState {
                    blocked: false,
                    token_version: None,
                }
            }
        }
    };

    state.accounts.insert(
        user_id,
        CachedAccount {
            state: fresh,
            fetched_at: Instant::now(),
        },
    );
    fresh
}

fn token_current(user: &AuthUser, account: AccountState) -> bool {
    account
        .token_version
        .is_none_or(|version| user.tv == version)
}

/// Fire-and-forget side effects of an authenticated request.
pub fn touch_last_seen(state: &Arc<AppState>, user_id: Uuid) {
    let should_touch = !matches!(
        state.last_seen.get(&user_id),
        Some(at) if at.elapsed() < LAST_SEEN_THROTTLE
    );
    if !should_touch {
        return;
    }
    state.last_seen.insert(user_id, Instant::now());

    let state = state.clone();
    spawn_detached(async move {
        if let Err(err) = sqlx::query("UPDATE profiles SET last_seen_at = now() WHERE id = $1")
            .bind(user_id)
            .execute(&state.db)
            .await
        {
            tracing::debug!(error = %err, "[auth] last_seen update failed");
        }
        crate::services::cloud_sync_cleanup::reset_cleanup_stage_on_activity(&state, user_id).await;
        crate::services::activity::touch_daily_activity(&state, user_id).await;
    });
}

/// Removes the throttle entry, used by tests and by the cron prune.
pub fn forget_user_activity(state: &AppState, user_id: Uuid) {
    state.last_seen.remove(&user_id);
    state.visits.remove(&user_id);
}

pub fn visit_throttle_elapsed(state: &AppState, user_id: Uuid) -> bool {
    match state.visits.get(&user_id) {
        Some(at) => at.elapsed() >= VISIT_THROTTLE,
        None => true,
    }
}

fn spawn_detached<F>(future: F) -> JoinHandle<()>
where
    F: Future<Output = ()> + Send + 'static,
{
    tokio::spawn(future)
}

/// The router state is passed straight to the extractor; reading it from the
/// request extensions only works for layers that insert it there, and the
/// nested `State` extractor does not.
fn state_from_parts(state: &Arc<AppState>) -> Arc<AppState> {
    state.clone()
}

impl FromRequestParts<Arc<AppState>> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let state = state_from_parts(state);
        let secret = state
            .cfg
            .jwt_secret
            .as_deref()
            .ok_or_else(|| ApiError::internal("Server auth is not configured"))?;

        let token = bearer_token(
            parts
                .headers
                .get(axum::http::header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok()),
        )
        .ok_or_else(|| ApiError::unauthorized("No token provided"))?;

        let payload = verify(secret, token).ok_or_else(|| {
            ApiError::unauthorized("Token is not valid").with_code("TOKEN_INVALID")
        })?;
        let user = claims_user(payload).ok_or_else(|| {
            ApiError::unauthorized("Token is not valid").with_code("TOKEN_INVALID")
        })?;

        let account = account_state(&state, user.id).await;
        if account.blocked {
            return Err(ApiError::forbidden("Your account is blocked").with_code("ACCOUNT_BLOCKED"));
        }
        if !token_current(&user, account) {
            return Err(ApiError::unauthorized("Token is not valid").with_code("TOKEN_REVOKED"));
        }

        touch_last_seen(&state, user.id);
        Ok(user)
    }
}

impl FromRequestParts<Arc<AppState>> for OptionalAuth {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let state = state_from_parts(state);
        let Some(secret) = state.cfg.jwt_secret.as_deref() else {
            return Ok(OptionalAuth(None));
        };
        let Some(token) = bearer_token(
            parts
                .headers
                .get(axum::http::header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok()),
        ) else {
            return Ok(OptionalAuth(None));
        };
        let Some(user) = verify(secret, token).and_then(claims_user) else {
            return Ok(OptionalAuth(None));
        };

        let account = account_state(&state, user.id).await;
        if account.blocked || !token_current(&user, account) {
            return Ok(OptionalAuth(None));
        }
        touch_last_seen(&state, user.id);
        Ok(OptionalAuth(Some(user)))
    }
}

/// `adminAuth`: the role is read from the database, never trusted from the
/// seven-day token.
#[derive(Debug, Clone)]
pub struct AdminUser(pub AuthUser);

impl FromRequestParts<Arc<AppState>> for AdminUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let user = AuthUser::from_request_parts(parts, state).await?;
        let state = state_from_parts(state);
        let role: Option<String> = sqlx::query_scalar("SELECT role FROM profiles WHERE id = $1")
            .bind(user.id)
            .fetch_optional(&state.db)
            .await
            .map_err(|err| {
                tracing::error!(error = %err, "Admin Check Error");
                ApiError::internal("Server error checking admin rights")
            })?;
        match role {
            None => Err(ApiError::unauthorized("User not found in DB")),
            Some(role) if role == "admin" => Ok(AdminUser(user)),
            Some(_) => Err(ApiError::forbidden("Access denied. Admins only.")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bearer_parsing_matches_node_split() {
        assert_eq!(bearer_token(Some("Bearer abc")), Some("abc"));
        assert_eq!(bearer_token(Some("bearer abc")), None);
        assert_eq!(bearer_token(Some("Bearer  abc")), None);
        assert_eq!(bearer_token(Some("Bearer")), None);
        assert_eq!(bearer_token(None), None);
    }

    #[test]
    fn claims_without_id_are_rejected() {
        assert!(claims_user(serde_json::json!({"role": "user"})).is_none());
        assert!(claims_user(serde_json::json!({"id": "not-a-uuid"})).is_none());
        let user = claims_user(serde_json::json!({
            "id": "6f1d2a4e-0b4d-4f2a-9d5f-0b1b2c3d4e5f",
            "role": "user",
            "tv": 3
        }))
        .unwrap();
        assert_eq!(user.tv, 3);
        assert_eq!(user.role.as_deref(), Some("user"));
    }

    #[test]
    fn token_version_absent_is_current() {
        let user = claims_user(serde_json::json!({
            "id": "6f1d2a4e-0b4d-4f2a-9d5f-0b1b2c3d4e5f"
        }))
        .unwrap();
        assert!(token_current(
            &user,
            AccountState {
                blocked: false,
                token_version: None
            }
        ));
        assert!(token_current(
            &user,
            AccountState {
                blocked: false,
                token_version: Some(0)
            }
        ));
        assert!(!token_current(
            &user,
            AccountState {
                blocked: false,
                token_version: Some(1)
            }
        ));
    }
}
