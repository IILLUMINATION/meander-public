//! Environment configuration for the Meander backend.
//!
//! Reads the same variables the Node backend read (`dotenv` semantics: an
//! existing process environment wins over the `.env` file), so both servers can
//! run from `backend/` with one `.env`.

use std::path::PathBuf;
use std::sync::Arc;

#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,
    pub base_url: String,
    pub is_production: bool,
    pub cors_origins: Vec<String>,
    pub database_url: String,

    pub jwt_secret: Option<String>,
    pub session_secret: Option<String>,

    pub google_client_ids: Vec<String>,
    pub google_client_secret: Option<String>,
    pub google_web_client_id: Option<String>,
    pub yandex_client_id: Option<String>,
    pub yandex_client_secret: Option<String>,
    pub telegram_bot_token: Option<String>,
    pub telegram_client_id: Option<String>,
    pub apple_bundle_id: String,
    pub apple_service_id: Option<String>,

    pub github_owner: Option<String>,
    pub github_repo: Option<String>,
    pub github_token: Option<String>,
    pub imgbb_key: Option<String>,
    pub onlysq_base_url: Option<String>,
    pub onlysq_api_key: Option<String>,
    pub onlysq_model: Option<String>,
    pub pollinations_token: Option<String>,

    pub cloud_sync_root: PathBuf,
    pub sync_settings_secret: Option<String>,
    pub public_dir: PathBuf,
    pub quest_xaccel_prefix: String,
    pub quest_xaccel_private_prefix: String,

    pub enable_debug_routes: bool,
    pub firebase_credentials: Option<PathBuf>,

    pub ai_default_tokens: i64,
    pub ai_veteran_tokens: i64,
    pub ai_ad_reward_tokens: i64,
    pub ai_token_refill_hours: i64,
}

fn env(key: &str) -> Option<String> {
    match std::env::var(key) {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => None,
    }
}

fn env_or(key: &str, default: &str) -> String {
    env(key).unwrap_or_else(|| default.to_string())
}

fn env_parse<T: std::str::FromStr>(key: &str, default: T) -> T {
    env(key)
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

impl Config {
    /// Loads `.env` (without overriding the process environment) and reads the
    /// configuration. `dotenv` catches a missing file, so this never fails.
    pub fn load() -> Arc<Self> {
        // `backend/.env` is where the Node backend kept it; the crate may be
        // run from the repo root or from the crate directory.
        for candidate in [".env", "../.env", "backend/.env"] {
            let _ = dotenvy::from_filename(candidate);
        }

        let is_production = env("NODE_ENV").as_deref() == Some("production");
        let cors_origins = env("CORS_ORIGINS")
            .map(|raw| {
                raw.split(',')
                    .map(|o| o.trim().to_string())
                    .filter(|o| !o.is_empty())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        let google_client_ids = [
            "GOOGLE_CLIENT_ID",
            "GOOGLE_IOS_CLIENT_ID",
            "GOOGLE_WINDOWS_CLIENT_ID",
            "GOOGLE_DESKTOP_CLIENT_ID",
        ]
        .iter()
        .filter_map(|k| env(k))
        .collect();

        // Node resolves `path.join(__dirname, '../public')`, i.e. always
        // `backend/public` (ts-node) or `backend/public` (compiled `dist`).
        // Do not fall back based on cwd: nginx serves that directory by name.
        let public_dir = env("PUBLIC_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("backend/public"));

        let xaccel = env("QUEST_XACCEL_PREFIX").unwrap_or_default();

        Arc::new(Self {
            port: env_parse("PORT", 3000),
            base_url: env_or("BASE_URL", "http://localhost:3000"),
            is_production,
            cors_origins,
            database_url: env_or(
                "DATABASE_URL",
                "postgres://postgres@127.0.0.1:5432/meander_dev",
            ),

            jwt_secret: env("JWT_SECRET"),
            session_secret: env("SESSION_SECRET"),

            google_web_client_id: env("GOOGLE_CLIENT_ID"),
            google_client_secret: env("GOOGLE_CLIENT_SECRET"),
            google_client_ids,
            yandex_client_id: env("YANDEX_CLIENT_ID"),
            yandex_client_secret: env("YANDEX_CLIENT_SECRET"),
            // `auth_telegram.ts`: TELEGRAM_BOT_TOKEN || TELOXIDE_TOKEN.
            telegram_bot_token: env("TELEGRAM_BOT_TOKEN").or_else(|| env("TELOXIDE_TOKEN")),
            telegram_client_id: env("TELEGRAM_CLIENT_ID"),
            apple_bundle_id: env_or("APPLE_BUNDLE_ID", "com.IILLUMINAT.meadner"),
            apple_service_id: env("APPLE_SERVICE_ID"),

            github_owner: env("GITHUB_OWNER"),
            github_repo: env("GITHUB_REPO"),
            github_token: env("GITHUB_TOKEN"),
            imgbb_key: env("IMGBB_KEY"),
            onlysq_base_url: env("ONLYSQ_BASE_URL"),
            onlysq_api_key: env("ONLYSQ_API_KEY"),
            onlysq_model: env("ONLYSQ_MODEL"),
            pollinations_token: env("POLLINATIONS_TOKEN"),

            // Node: `CLOUD_SYNC_ROOT` or `path.resolve(cwd, 'storage', 'cloud_sync')`
            // (see `services/cloud_sync_storage.ts`), not a subdirectory of `public`.
            cloud_sync_root: env("CLOUD_SYNC_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("storage").join("cloud_sync")),
            sync_settings_secret: env("SYNC_SETTINGS_SECRET"),
            public_dir,
            quest_xaccel_private_prefix: env("QUEST_XACCEL_PRIVATE_PREFIX")
                .unwrap_or_else(|| xaccel.clone()),
            quest_xaccel_prefix: xaccel,

            enable_debug_routes: env("ENABLE_DEBUG_ROUTES").as_deref() == Some("true"),
            firebase_credentials: env("FIREBASE_CREDENTIALS")
                .or_else(|| env("GOOGLE_APPLICATION_CREDENTIALS"))
                .map(PathBuf::from),

            ai_default_tokens: env_parse("AI_DEFAULT_TOKENS", 30),
            ai_veteran_tokens: env_parse("AI_VETERAN_TOKENS", 100),
            ai_ad_reward_tokens: env_parse("AI_AD_REWARD_TOKENS", 10),
            ai_token_refill_hours: env_parse("AI_TOKEN_REFILL_HOURS", 24),
        })
    }

    /// The Node app allowed every origin when it was not production and the
    /// allowlist was empty (native clients send no Origin at all).
    pub fn origin_allowed(&self, origin: Option<&str>) -> bool {
        match origin {
            None | Some("") => true,
            Some(o) => {
                (!self.is_production && self.cors_origins.is_empty())
                    || self.cors_origins.iter().any(|allowed| allowed == o)
            }
        }
    }
}
