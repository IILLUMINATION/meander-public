//! Server entrypoint.

use std::net::SocketAddr;
use std::sync::Arc;

use mnd_server::{build_app, config::Config, cron, state::AppState};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,sqlx=warn".into()),
        )
        .init();

    let cfg: Arc<Config> = Config::load();
    let state = AppState::new(cfg.clone()).await?;
    let (app, _io) = build_app(state.clone()).await?;

    let addr = SocketAddr::from(([0, 0, 0, 0], cfg.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(port = cfg.port, "server is running");

    // Push notifications are optional: without credentials every send is a
    // logged no-op, exactly like the Node server.
    if mnd_server::services::fcm::ensure_initialized(&state) {
        tracing::info!("[FCM] Firebase credentials loaded");
    }

    if cfg.disable_cron {
        tracing::warn!("background cron disabled (DISABLE_CRON)");
    } else {
        cron::spawn_all(state);
    }

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}
