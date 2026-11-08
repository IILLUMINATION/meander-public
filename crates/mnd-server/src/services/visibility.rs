//! Role checks and unpublished-content visibility — port of `visibility.ts`.
//!
//! Roles are always read from the database: a seven-day token keeps the old
//! role after a demotion, so it cannot authorise anything.

use std::sync::Arc;

use uuid::Uuid;

use crate::state::AppState;

pub async fn current_role(state: &Arc<AppState>, user_id: Uuid) -> Option<String> {
    sqlx::query_scalar("SELECT role FROM profiles WHERE id = $1")
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
        .ok()
        .flatten()
}

pub async fn is_admin(state: &Arc<AppState>, user_id: Uuid) -> bool {
    current_role(state, user_id).await.as_deref() == Some("admin")
}

/// Administrator or moderator — the people who edit other people's content.
pub async fn is_staff(state: &Arc<AppState>, user_id: Option<Uuid>) -> bool {
    let Some(user_id) = user_id else {
        return false;
    };
    matches!(
        current_role(state, user_id).await.as_deref(),
        Some("admin") | Some("moderator")
    )
}

/// Unpublished work is visible to its author and to admins only.
pub async fn can_see_unpublished(
    state: &Arc<AppState>,
    viewer: Option<Uuid>,
    author_id: Option<Uuid>,
) -> bool {
    let Some(viewer) = viewer else {
        return false;
    };
    if author_id == Some(viewer) {
        return true;
    }
    is_admin(state, viewer).await
}
