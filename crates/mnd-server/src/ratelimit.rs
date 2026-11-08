//! Fixed-window rate limiter with the same policies and messages as the
//! express-rate-limit configuration in `app.ts`.

use std::time::{Duration, Instant};

use dashmap::DashMap;

#[derive(Debug, Clone, Copy)]
pub struct Decision {
    pub allowed: bool,
    pub limit: u64,
    pub remaining: u64,
    /// Seconds until the current window resets (`RateLimit-Reset`).
    pub reset_secs: u64,
}

#[derive(Debug, Clone, Copy)]
struct Window {
    started: Instant,
    count: u64,
}

#[derive(Debug, Default)]
pub struct RateLimiter {
    windows: DashMap<String, Window>,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn hit(&self, key: impl Into<String>, max: u64, window: Duration) -> Decision {
        let key = key.into();
        let now = Instant::now();
        let mut entry = self.windows.entry(key).or_insert(Window {
            started: now,
            count: 0,
        });

        if now.duration_since(entry.started) >= window {
            entry.started = now;
            entry.count = 0;
        }

        entry.count += 1;
        let remaining_window = window.saturating_sub(now.duration_since(entry.started));
        let allowed = entry.count <= max;

        Decision {
            allowed,
            limit: max,
            remaining: max.saturating_sub(entry.count),
            reset_secs: remaining_window.as_secs().max(1),
        }
    }

    /// Drops expired windows; called from the cron tick so a long-lived server
    /// does not accumulate one entry per IP forever.
    pub fn prune(&self, window: Duration) {
        let now = Instant::now();
        self.windows
            .retain(|_, w| now.duration_since(w.started) < window);
    }

    pub fn len(&self) -> usize {
        self.windows.len()
    }
}

/// The `ipKeyGenerator`-normalised key: express-rate-limit collapses IPv6
/// clients to their /56 subnet so one host cannot rotate addresses cheaply.
pub fn normalize_ip(ip: &str) -> String {
    match ip.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V6(v6)) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return v4.to_string();
            }
            let segments = v6.segments();
            format!(
                "{:x}:{:x}:{:x}:{:x}::/56",
                segments[0], segments[1], segments[2], segments[3]
            )
        }
        Ok(other) => other.to_string(),
        Err(_) => ip.to_string(),
    }
}

pub mod policy {
    use std::time::Duration;

    pub const GENERAL_WINDOW: Duration = Duration::from_secs(15 * 60);
    pub const GENERAL_MAX: u64 = 1000;
    pub const GENERAL_MESSAGE: &str = "Too many requests";

    pub const AUTH_WINDOW: Duration = Duration::from_secs(60 * 60);
    pub const AUTH_MAX: u64 = 100;
    pub const AUTH_MESSAGE: &str = "Too many login attempts.";

    pub const UPLOAD_WINDOW: Duration = Duration::from_secs(60 * 60);
    pub const UPLOAD_MAX: u64 = 5;
    pub const UPLOAD_MESSAGE: &str = "Публиковать можно не чаще 5 раз в час. Попробуй позже.";

    pub const QUEST_WINDOW: Duration = Duration::from_secs(15 * 60);
    pub const QUEST_MAX_AUTH: u64 = 600;
    pub const QUEST_MAX_ANON: u64 = 60;
    pub const QUEST_MESSAGE: &str = "Too many requests. Please slow down.";

    pub const DOWNLOAD_WINDOW: Duration = Duration::from_secs(60 * 60);
    pub const DOWNLOAD_MAX_AUTH: u64 = 600;
    pub const DOWNLOAD_MAX_ANON: u64 = 300;
    pub const DOWNLOAD_MESSAGE: &str = "Слишком много загрузок. Подожди немного и попробуй снова.";
}
