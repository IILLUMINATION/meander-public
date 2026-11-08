//! Process-wide state: database pool, HTTP client, caches and the socket.io
//! handle. Mirrors the module-level singletons of the Node backend.

use std::sync::{Arc, OnceLock};
use std::time::Instant;

use dashmap::DashMap;
use socketioxide::SocketIo;
use sqlx::PgPool;
use uuid::Uuid;

use crate::config::Config;
use crate::ratelimit::RateLimiter;
use crate::services::jwks::JwksCache;

#[derive(Debug, Clone, Copy)]
pub struct AccountState {
    pub blocked: bool,
    pub token_version: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct CachedAccount {
    pub state: AccountState,
    pub fetched_at: Instant,
}

pub struct AppState {
    pub cfg: Arc<Config>,
    pub db: PgPool,
    pub http: reqwest::Client,
    /// 30-second account state cache (block flag + token version).
    pub accounts: DashMap<Uuid, CachedAccount>,
    /// `last_seen_at` write throttle, 2 minutes.
    pub last_seen: DashMap<Uuid, Instant>,
    /// Daily activity throttle, 30 minutes.
    pub visits: DashMap<Uuid, Instant>,
    pub limiter: RateLimiter,
    pub io: OnceLock<SocketIo>,
    pub google_jwks: JwksCache,
    pub apple_jwks: JwksCache,
    /// Firebase OAuth token cache for FCM pushes.
    pub fcm: crate::services::fcm::FcmCache,
}

impl AppState {
    pub async fn new(cfg: Arc<Config>) -> anyhow::Result<Arc<Self>> {
        let db = sqlx::postgres::PgPoolOptions::new()
            .max_connections(10)
            .idle_timeout(std::time::Duration::from_secs(30))
            .acquire_timeout(std::time::Duration::from_secs(2))
            .connect(&cfg.database_url)
            .await?;

        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .user_agent("meander-backend/0.3")
            .build()?;

        Ok(Arc::new(Self {
            cfg,
            db,
            http,
            accounts: DashMap::new(),
            last_seen: DashMap::new(),
            visits: DashMap::new(),
            limiter: RateLimiter::new(),
            io: OnceLock::new(),
            google_jwks: JwksCache::new("https://www.googleapis.com/oauth2/v3/certs"),
            apple_jwks: JwksCache::new("https://appleid.apple.com/auth/keys"),
            fcm: crate::services::fcm::FcmCache::default(),
        }))
    }

    /// Emits an event to every socket of one user (`user_<id>` room), the same
    /// room `initSocket` joined on connect.
    pub fn emit_to_user(
        &self,
        user_id: &str,
        event: &str,
        payload: impl serde::Serialize + Send + 'static,
    ) {
        self.emit_to_room(&format!("user_{user_id}"), event, payload);
    }

    pub fn emit_to_room(
        &self,
        room: &str,
        event: &str,
        payload: impl serde::Serialize + Send + 'static,
    ) {
        let Some(io) = self.io.get() else {
            return;
        };
        // socketioxide's broadcast `emit` is async; dropping the future would
        // silently skip delivery (the old code did exactly that).
        let operator = io.to(room.to_string());
        let event = event.to_string();
        tokio::spawn(async move {
            if let Err(err) = operator.emit(event, &payload).await {
                tracing::warn!(error = %err, "socket emit failed");
            }
        });
    }

    /// Linear probe used by admin health output and tests.
    pub fn account_cache_len(&self) -> usize {
        self.accounts.len()
    }
}
