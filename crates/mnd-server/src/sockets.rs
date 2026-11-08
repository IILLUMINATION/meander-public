//! Socket.io server: same rooms, events and handshake auth as `socket.ts`.
//!
//! Rooms: every socket joins `user_<id>`; author-wall posts add `post_<id>`
//! after the same authorisation check the Node server performed (post exists,
//! active, author not blocked by the viewer). Events consumed by the clients:
//! `join_post`, `leave_post`; events emitted by services: `new_notification`,
//! `dm_message`, `new_comment`, `post_stats_updated`, `new_wall_post`.

use std::sync::Arc;

use serde_json::Value;
use socketioxide::SocketIo;
use socketioxide::extract::{SocketRef, State, TryData};
use socketioxide::handler::ConnectHandler;
use socketioxide::service::SocketIoService;
use uuid::Uuid;

use crate::auth::account_state;
use crate::state::AppState;

#[derive(Debug, Clone)]
pub struct SocketUser(pub Uuid);

/// Builds the Socket.IO service around an already assembled HTTP router.
///
/// Socket.IO requests are answered by the engine before the inner service is
/// called; every other request falls through to `inner`.
pub fn setup_with_inner<S>(state: &Arc<AppState>, inner: S) -> (SocketIoService<S>, SocketIo)
where
    S: tower::Service<
            axum::extract::Request,
            Error = std::convert::Infallible,
            Response = axum::response::Response,
        > + Clone
        + Send
        + Sync
        + 'static,
    S::Future: Send + 'static,
{
    let (service, io) = SocketIo::builder()
        .with_state(state.clone())
        .build_with_inner_svc(inner);
    // The middleware rejects the handshake before the connection handler runs,
    // so `on_connect` can assume an authenticated user.
    io.ns("/", on_connect.with(authenticate));
    (service, io)
}

/// `socket.handshake.auth.token` first, then `?token=` (older web players).
fn handshake_token(auth: Option<&Value>, query: Option<&str>) -> Option<String> {
    if let Some(token) = auth.and_then(|a| a.get("token")).and_then(Value::as_str) {
        if !token.is_empty() {
            return Some(token.to_string());
        }
    }
    query.and_then(|q| {
        q.split('&')
            .filter_map(|pair| pair.split_once('='))
            .find(|(k, _)| *k == "token")
            .map(|(_, v)| v.to_string())
    })
}

async fn authenticate(
    socket: SocketRef,
    TryData(auth): TryData<Value>,
    State(state): State<Arc<AppState>>,
) -> Result<(), String> {
    let auth = auth.ok();
    let query = socket.req_parts().uri.query();
    let token = handshake_token(auth.as_ref(), query)
        .ok_or_else(|| "Authentication error: No token provided".to_string())?;

    let Some(secret) = state.cfg.jwt_secret.as_deref() else {
        tracing::error!("[socket] JWT_SECRET is not set — realtime is disabled");
        return Err("Authentication error: Server is not configured".into());
    };

    let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::HS256);
    validation.required_spec_claims.clear();
    validation.validate_exp = true;
    let payload = jsonwebtoken::decode::<Value>(
        &token,
        &jsonwebtoken::DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )
    .map_err(|_| "Authentication error: Invalid token".to_string())?
    .claims;

    let user_id = payload
        .get("id")
        .and_then(Value::as_str)
        .and_then(|id| Uuid::parse_str(id).ok())
        .ok_or_else(|| "Authentication error: Invalid token".to_string())?;

    // Blocked accounts must not receive realtime data either.
    let account = account_state(&state, user_id).await;
    if account.blocked {
        return Err("Authentication error: Account is blocked".into());
    }

    socket.extensions.insert(SocketUser(user_id));
    Ok(())
}

async fn on_connect(socket: SocketRef) {
    let Some(SocketUser(user_id)) = socket.extensions.get::<SocketUser>().map(|u| u.clone()) else {
        return;
    };
    socket.join(format!("user_{user_id}"));
    tracing::info!(%user_id, "[socket] connected");

    socket.on("join_post", join_post);
    socket.on("leave_post", leave_post);
}

async fn join_post(
    socket: SocketRef,
    TryData(post_id): TryData<Value>,
    State(state): State<Arc<AppState>>,
) {
    let Some(post_id) = post_id
        .ok()
        .as_ref()
        .and_then(Value::as_str)
        .and_then(|id| Uuid::parse_str(id).ok())
    else {
        return;
    };
    let Some(SocketUser(user_id)) = socket.extensions.get::<SocketUser>().map(|u| u.clone()) else {
        return;
    };

    use sqlx::Row;
    let post = match sqlx::query("SELECT author_id, is_active FROM author_posts WHERE id = $1")
        .bind(post_id)
        .fetch_optional(&state.db)
        .await
    {
        Ok(Some(row)) => row,
        _ => return,
    };
    if !post
        .try_get::<Option<bool>, _>("is_active")
        .ok()
        .flatten()
        .unwrap_or(false)
    {
        return;
    }
    let author_id: Option<Uuid> = post.try_get::<Option<Uuid>, _>("author_id").ok().flatten();
    let Some(author_id) = author_id else { return };

    let blocked: Option<i32> =
        sqlx::query_scalar("SELECT 1 FROM user_blocks WHERE user_id = $1 AND blocked_id = $2")
            .bind(user_id)
            .bind(author_id)
            .fetch_optional(&state.db)
            .await
            .unwrap_or(None);
    if blocked.is_some() {
        return;
    }

    socket.join(format!("post_{post_id}"));
    tracing::debug!(%user_id, %post_id, "[socket] joined post room");
}

async fn leave_post(socket: SocketRef, TryData(post_id): TryData<Value>) {
    if let Some(post_id) = post_id.ok().as_ref().and_then(Value::as_str) {
        socket.leave(format!("post_{post_id}"));
    }
}
