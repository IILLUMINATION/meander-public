//! Admin routes: `/admin/*`. Port of `backend/src/routes/admin.ts`.
//!
//! Wire contract matches Node exactly: every route is protected by
//! [`AdminUser`], and the JSON shapes/statuses are preserved byte-for-byte.

use std::collections::HashMap;
use std::sync::Arc;

use axum::{
    Router,
    extract::{Path, Query, State},
    routing::{get, post},
};
use serde_json::{Map, Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::auth::AdminUser;
use crate::error::{ApiError, ApiResult, ok_json};
use crate::extractors::Body;
use crate::json::{parse_num, pg_row_to_json, rows_to_json};
use crate::services::{
    activity, cloud_sync_tier, cosmetics,
    notifications::{self, NewNotification},
};
use crate::state::AppState;

// ============================================================================
//  Catalog mirrors the source of truth in backend/src/services/cosmetics.ts.
//  It is kept here (not exported from services/cosmetics.rs) per the contract.
// ============================================================================

const MAX_GRANT_USERS: usize = 500;
const MAX_GRANT_ITEMS: usize = 100;

#[derive(Clone, Copy)]
struct CatalogItem {
    id: &'static str,
    slot: &'static str,
    tier: &'static str,
}

const CATALOG: &[CatalogItem] = &[
    CatalogItem {
        id: "beige",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "forest",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "royal_purple",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "sunset",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "ocean",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "rose",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "cyber",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "mono",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "aurora",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "aurora_drift",
        slot: "banner",
        tier: "rare",
    },
    CatalogItem {
        id: "lava_flow",
        slot: "banner",
        tier: "rare",
    },
    CatalogItem {
        id: "neon_grid",
        slot: "banner",
        tier: "epic",
    },
    CatalogItem {
        id: "starfield",
        slot: "banner",
        tier: "epic",
    },
    CatalogItem {
        id: "oil_slick",
        slot: "banner",
        tier: "epic",
    },
    CatalogItem {
        id: "gold_leaf",
        slot: "banner",
        tier: "legendary",
    },
    CatalogItem {
        id: "frost_panel",
        slot: "banner",
        tier: "rare",
    },
    CatalogItem {
        id: "midnight_surf",
        slot: "banner",
        tier: "rare",
    },
    CatalogItem {
        id: "vapor_silk",
        slot: "banner",
        tier: "epic",
    },
    CatalogItem {
        id: "solar_prominence",
        slot: "banner",
        tier: "epic",
    },
    CatalogItem {
        id: "green_horizon",
        slot: "banner",
        tier: "legendary",
    },
    CatalogItem {
        id: "rose_quartz",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "art_night_meadow",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "art_golden_field",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "art_lone_tree",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "art_forest_bridge",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "art_pond_robot",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "art_open_road",
        slot: "banner",
        tier: "common",
    },
    CatalogItem {
        id: "bg_night_meadow",
        slot: "background",
        tier: "common",
    },
    CatalogItem {
        id: "bg_golden_field",
        slot: "background",
        tier: "common",
    },
    CatalogItem {
        id: "bg_lone_tree",
        slot: "background",
        tier: "common",
    },
    CatalogItem {
        id: "bg_forest_bridge",
        slot: "background",
        tier: "common",
    },
    CatalogItem {
        id: "bg_pond_robot",
        slot: "background",
        tier: "common",
    },
    CatalogItem {
        id: "bg_open_road",
        slot: "background",
        tier: "common",
    },
    CatalogItem {
        id: "prism_ring",
        slot: "avatar_frame",
        tier: "rare",
    },
    CatalogItem {
        id: "neon_pulse",
        slot: "avatar_frame",
        tier: "rare",
    },
    CatalogItem {
        id: "gold_laurel",
        slot: "avatar_frame",
        tier: "legendary",
    },
    CatalogItem {
        id: "ember_orbit",
        slot: "avatar_frame",
        tier: "epic",
    },
    CatalogItem {
        id: "glitch_ring",
        slot: "avatar_frame",
        tier: "epic",
    },
    CatalogItem {
        id: "frost_circle",
        slot: "avatar_frame",
        tier: "rare",
    },
    CatalogItem {
        id: "soft_line",
        slot: "avatar_frame",
        tier: "common",
    },
    CatalogItem {
        id: "solar_corona",
        slot: "avatar_frame",
        tier: "legendary",
    },
    CatalogItem {
        id: "holo_band",
        slot: "avatar_frame",
        tier: "epic",
    },
    CatalogItem {
        id: "frost_crown",
        slot: "avatar_frame",
        tier: "rare",
    },
    CatalogItem {
        id: "mint_halo",
        slot: "avatar_frame",
        tier: "common",
    },
    CatalogItem {
        id: "sunset_glow",
        slot: "name_style",
        tier: "rare",
    },
    CatalogItem {
        id: "frost_blue",
        slot: "name_style",
        tier: "rare",
    },
    CatalogItem {
        id: "toxic_lime",
        slot: "name_style",
        tier: "rare",
    },
    CatalogItem {
        id: "royal_gold",
        slot: "name_style",
        tier: "legendary",
    },
    CatalogItem {
        id: "magenta_neon",
        slot: "name_style",
        tier: "epic",
    },
    CatalogItem {
        id: "pride_wave",
        slot: "name_style",
        tier: "epic",
    },
    CatalogItem {
        id: "ink_violet",
        slot: "name_style",
        tier: "common",
    },
    CatalogItem {
        id: "polar_shimmer",
        slot: "name_style",
        tier: "epic",
    },
    CatalogItem {
        id: "copper_name",
        slot: "name_style",
        tier: "rare",
    },
    CatalogItem {
        id: "pulsar",
        slot: "name_style",
        tier: "legendary",
    },
    CatalogItem {
        id: "rose_neon",
        slot: "name_style",
        tier: "rare",
    },
    CatalogItem {
        id: "graphite",
        slot: "name_style",
        tier: "common",
    },
    CatalogItem {
        id: "snowfall",
        slot: "effect",
        tier: "rare",
    },
    CatalogItem {
        id: "campfire_embers",
        slot: "effect",
        tier: "rare",
    },
    CatalogItem {
        id: "stardust",
        slot: "effect",
        tier: "epic",
    },
    CatalogItem {
        id: "fireflies",
        slot: "effect",
        tier: "rare",
    },
    CatalogItem {
        id: "coin_rain",
        slot: "effect",
        tier: "legendary",
    },
    CatalogItem {
        id: "cherry_blossom",
        slot: "effect",
        tier: "rare",
    },
    CatalogItem {
        id: "hearts",
        slot: "effect",
        tier: "rare",
    },
    CatalogItem {
        id: "confetti",
        slot: "effect",
        tier: "common",
    },
    CatalogItem {
        id: "cold_rain",
        slot: "effect",
        tier: "common",
    },
    CatalogItem {
        id: "blizzard",
        slot: "effect",
        tier: "epic",
    },
    CatalogItem {
        id: "fireworks",
        slot: "effect",
        tier: "legendary",
    },
    CatalogItem {
        id: "rose_down",
        slot: "effect",
        tier: "epic",
    },
    CatalogItem {
        id: "monsoon",
        slot: "effect",
        tier: "rare",
    },
    CatalogItem {
        id: "witchfire",
        slot: "effect",
        tier: "rare",
    },
    CatalogItem {
        id: "glitter",
        slot: "effect",
        tier: "common",
    },
];

fn catalog_item(id: &str) -> Option<&'static CatalogItem> {
    CATALOG.iter().find(|item| item.id == id)
}

fn catalog_values() -> Vec<Value> {
    CATALOG
        .iter()
        .map(|item| {
            json!({
                "id": item.id,
                "slot": item.slot,
                "tier": item.tier,
            })
        })
        .collect()
}

fn as_strings(values: &[Value]) -> Vec<String> {
    values
        .iter()
        .map(|v| match v {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        })
        .collect()
}

fn trim_reason(reason: Option<&str>) -> Option<String> {
    reason.map(|s| s.chars().take(300).collect())
}

// ============================================================================
//  Handlers
// ============================================================================

async fn stats(State(state): State<Arc<AppState>>, _admin: AdminUser) -> ApiResult {
    let users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM profiles")
        .fetch_one(&state.db)
        .await?;
    let quests: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM quests")
        .fetch_one(&state.db)
        .await?;
    let pending_quests: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM quests WHERE status = 'in_review'")
            .fetch_one(&state.db)
            .await?;
    let pending_music: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM music_tracks WHERE status = 'in_review'")
            .fetch_one(&state.db)
            .await?;
    let pending_assets: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM market_assets WHERE status = 'in_review'")
            .fetch_one(&state.db)
            .await?;

    ok_json(json!({
        "users": users,
        "quests": quests,
        "pending_quests": pending_quests,
        "pending_music": pending_music,
        "pending_assets": pending_assets,
    }))
}

async fn activity_overview(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let days = parse_num(q.get("days").map(|s| s.as_str())).map(|f| f as i64);
    let overview = activity::get_activity_overview(&state, days).await;
    ok_json(overview)
}

async fn moderation_queue(State(state): State<Arc<AppState>>, _admin: AdminUser) -> ApiResult {
    let rows = sqlx::query(
        "SELECT q.*, p.full_name as author_name
           FROM quests q
           JOIN profiles p ON q.author_id = p.id
          WHERE q.status = 'in_review'
          ORDER BY q.updated_at ASC",
    )
    .fetch_all(&state.db)
    .await?;
    ok_json(rows_to_json(&rows))
}

async fn music_moderation_queue(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
) -> ApiResult {
    let rows = sqlx::query(
        "SELECT m.*, p.full_name as author_name, p.is_verified as author_is_verified
           FROM music_tracks m
           LEFT JOIN profiles p ON m.author_id = p.id
          WHERE m.status = 'in_review'
          ORDER BY m.created_at ASC",
    )
    .fetch_all(&state.db)
    .await?;
    ok_json(rows_to_json(&rows))
}

async fn review_music(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Path(id_str): Path<String>,
    body: Body,
) -> ApiResult {
    let id = Uuid::parse_str(&id_str).map_err(|_| ApiError::bad_request("Invalid ID format"))?;
    let status = body.str("status").unwrap_or_default();
    if !matches!(status, "published" | "rejected") {
        return Err(ApiError::bad_request("Invalid status"));
    }

    if status == "rejected" {
        let row = sqlx::query("SELECT id FROM music_tracks WHERE id = $1")
            .bind(id)
            .fetch_optional(&state.db)
            .await?;
        if row.is_none() {
            return Err(ApiError::not_found("Track not found"));
        }
        sqlx::query("DELETE FROM music_tracks WHERE id = $1")
            .bind(id)
            .execute(&state.db)
            .await?;
        remove_public_file(&state.cfg.public_dir.join("music_files"), &id).await;
    } else {
        let result = sqlx::query(
            "UPDATE music_tracks SET status = $1::music_status, updated_at = NOW() WHERE id = $2",
        )
        .bind(status)
        .bind(id)
        .execute(&state.db)
        .await?;
        if result.rows_affected() == 0 {
            return Err(ApiError::not_found("Track not found"));
        }
    }

    ok_json(json!({ "success": true }))
}

async fn assets_moderation_queue(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
) -> ApiResult {
    let rows = sqlx::query(
        "SELECT m.*, p.full_name as author_name, p.is_verified as author_is_verified
           FROM market_assets m
           LEFT JOIN profiles p ON m.author_id = p.id
          WHERE m.status = 'in_review'
          ORDER BY m.created_at ASC",
    )
    .fetch_all(&state.db)
    .await?;
    ok_json(rows_to_json(&rows))
}

async fn review_asset(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Path(id_str): Path<String>,
    body: Body,
) -> ApiResult {
    let id = Uuid::parse_str(&id_str).map_err(|_| ApiError::bad_request("Invalid ID format"))?;
    let status = body.str("status").unwrap_or_default();
    if !matches!(status, "published" | "rejected") {
        return Err(ApiError::bad_request("Invalid status"));
    }

    if status == "rejected" {
        let row = sqlx::query("SELECT id FROM market_assets WHERE id = $1")
            .bind(id)
            .fetch_optional(&state.db)
            .await?;
        if row.is_none() {
            return Err(ApiError::not_found("Asset not found"));
        }
        sqlx::query("DELETE FROM market_assets WHERE id = $1")
            .bind(id)
            .execute(&state.db)
            .await?;
        remove_public_file(&state.cfg.public_dir.join("assets_files"), &id).await;
    } else {
        let result = sqlx::query(
            "UPDATE market_assets SET status = $1::asset_status, updated_at = NOW() WHERE id = $2",
        )
        .bind(status)
        .bind(id)
        .execute(&state.db)
        .await?;
        if result.rows_affected() == 0 {
            return Err(ApiError::not_found("Asset not found"));
        }
    }

    ok_json(json!({ "success": true }))
}

async fn review_quest(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Path(id_str): Path<String>,
    body: Body,
) -> ApiResult {
    let id = Uuid::parse_str(&id_str).map_err(|_| ApiError::bad_request("Invalid ID format"))?;
    let status = body.str("status").unwrap_or_default();
    if !matches!(status, "published" | "rejected") {
        return Err(ApiError::bad_request("Invalid status"));
    }

    let title: String;
    let author_id: Option<Uuid>;

    let row = sqlx::query(
        "UPDATE quests SET status = $1::quest_status, moderator_comment = $2, updated_at = NOW()
          WHERE id = $3
         RETURNING author_id, title",
    )
    .bind(status)
    .bind(body.str("comment"))
    .bind(id)
    .fetch_optional(&state.db)
    .await?;

    match row {
        Some(row) => {
            author_id = row.try_get("author_id").ok();
            title = row.try_get("title").unwrap_or_default();
        }
        None => return Err(ApiError::not_found("Quest not found")),
    }

    if let Some(author_id) = author_id {
        let kind = if status == "published" {
            "quest_approved"
        } else {
            "quest_rejected"
        };
        let notify_state = state.clone();
        let quest_id = id;
        let title_for_notif = title.clone();
        tokio::spawn(async move {
            notifications::create_notification(
                &notify_state,
                NewNotification {
                    user_id: author_id,
                    actor_id: None,
                    kind,
                    quest_id: Some(quest_id),
                    review_id: None,
                    payload: Some(json!({ "title": title_for_notif })),
                },
            )
            .await;
        });

        let tier_state = state.clone();
        tokio::spawn(async move {
            let _ = cloud_sync_tier::recompute_tier(&tier_state, author_id).await;
        });
    }

    ok_json(json!({ "success": true }))
}

async fn blocked_users(State(state): State<Arc<AppState>>, _admin: AdminUser) -> ApiResult {
    let rows = sqlx::query(
        "SELECT id, full_name, email, created_at, is_blocked
           FROM profiles
          WHERE is_blocked = TRUE
          ORDER BY created_at DESC",
    )
    .fetch_all(&state.db)
    .await?;
    ok_json(rows_to_json(&rows))
}

async fn unblock_user(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Path(id_str): Path<String>,
) -> ApiResult {
    let id = Uuid::parse_str(&id_str).map_err(|_| ApiError::bad_request("Invalid ID format"))?;

    let row = sqlx::query(
        "UPDATE profiles
            SET is_blocked = FALSE, token_version = token_version + 1
          WHERE id = $1
         RETURNING *",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await?;

    match row {
        Some(row) => ok_json(json!({
            "success": true,
            "user": pg_row_to_json(&row),
        })),
        None => Err(ApiError::not_found("User not found")),
    }
}

async fn cosmetics_catalog(_admin: AdminUser) -> ApiResult {
    ok_json(json!({ "items": catalog_values() }))
}

async fn cosmetics_grants(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let user_id = match q.get("user_id") {
        Some(s) if !s.is_empty() => {
            Some(Uuid::parse_str(s).map_err(|_| ApiError::bad_request("Invalid user_id"))?)
        }
        _ => None,
    };

    let rows = sqlx::query(
        "SELECT uc.user_id, p.full_name, uc.cosmetic_id, uc.slot, uc.tier,
                uc.source, uc.reason, uc.granted_at, uc.expires_at
           FROM user_cosmetics uc
           JOIN profiles p ON p.id = uc.user_id
          WHERE ($1::uuid IS NULL OR uc.user_id = $1)
          ORDER BY uc.granted_at DESC
          LIMIT 500",
    )
    .bind(user_id)
    .fetch_all(&state.db)
    .await?;
    ok_json(json!({ "grants": rows_to_json(&rows) }))
}

async fn cosmetics_grant(
    State(state): State<Arc<AppState>>,
    admin: AdminUser,
    body: Body,
) -> ApiResult {
    let user_ids: Vec<String> = if let Some(Value::Array(arr)) = body.get("user_ids") {
        as_strings(arr)
    } else if let Some(v) = body.get("user_id").and_then(Value::as_str) {
        vec![v.to_string()]
    } else {
        Vec::new()
    };

    let cosmetic_ids: Vec<String> = match body.get("cosmetic_ids") {
        Some(Value::Array(arr)) => as_strings(arr),
        _ => Vec::new(),
    };

    if user_ids.is_empty() || user_ids.len() > MAX_GRANT_USERS {
        return Err(ApiError::bad_request(format!(
            "Нужен список user_ids (1..{MAX_GRANT_USERS})"
        )));
    }
    if cosmetic_ids.is_empty() || cosmetic_ids.len() > MAX_GRANT_ITEMS {
        return Err(ApiError::bad_request(format!(
            "Нужен список cosmetic_ids (1..{MAX_GRANT_ITEMS})"
        )));
    }

    let unknown: Vec<&str> = cosmetic_ids
        .iter()
        .filter(|id| catalog_item(id).is_none())
        .map(|id| id.as_str())
        .collect();
    if !unknown.is_empty() {
        return Err(ApiError::bad_request(format!(
            "Неизвестные id оформления: {}",
            unknown.join(", ")
        )));
    }

    let days = body.i64("days").map(|d| d as i32);
    if let Some(d) = days
        && (d <= 0 || d > 3650)
    {
        return Err(ApiError::bad_request(
            "days должен быть числом 1..3650 или null",
        ));
    }

    let reason = trim_reason(body.str("reason"));
    let source = "admin_grant".to_string();
    let granted_by = Some(admin.0.id);

    let mut granted_map = Map::new();
    for id_str in &user_ids {
        let user_id = Uuid::parse_str(id_str)
            .map_err(|_| ApiError::bad_request(format!("Неверный id пользователя: {id_str}")))?;
        let (granted, _skipped) = cosmetics::grant_cosmetics(
            &state,
            user_id,
            &cosmetic_ids,
            cosmetics::GrantOptions {
                days,
                source: source.clone(),
                reason: reason.clone(),
                granted_by,
            },
        )
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "admin cosmetics grant");
            ApiError::internal("Server error granting cosmetics")
        })?;
        granted_map.insert(
            id_str.clone(),
            Value::Array(granted.into_iter().map(Value::String).collect()),
        );
    }

    ok_json(json!({ "success": true, "granted": Value::Object(granted_map) }))
}

async fn cosmetics_users(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let query = q.get("q").map(|s| s.trim()).unwrap_or_default();
    if query.len() < 2 {
        return Err(ApiError::bad_request("Нужно не меньше 2 символов"));
    }

    let rows = sqlx::query(
        "SELECT id, full_name, avatar_url
           FROM profiles
          WHERE full_name ILIKE $1
             OR id::text = $2
          ORDER BY full_name
          LIMIT 25",
    )
    .bind(format!("%{query}%"))
    .bind(query)
    .fetch_all(&state.db)
    .await?;
    ok_json(json!({ "users": rows_to_json(&rows) }))
}

async fn cosmetics_revoke(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    body: Body,
) -> ApiResult {
    let user_id = body
        .str("user_id")
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or_else(|| ApiError::bad_request("Нужны user_id и cosmetic_ids"))?;
    let cosmetic_ids: Vec<String> = match body.get("cosmetic_ids") {
        Some(Value::Array(arr)) if !arr.is_empty() => as_strings(arr),
        _ => return Err(ApiError::bad_request("Нужны user_id и cosmetic_ids")),
    };

    let revoked: Vec<String> = sqlx::query_scalar(
        "DELETE FROM user_cosmetics
          WHERE user_id = $1
            AND cosmetic_id = ANY($2::text[])
         RETURNING cosmetic_id",
    )
    .bind(user_id)
    .bind(&cosmetic_ids)
    .fetch_all(&state.db)
    .await?;

    sqlx::query(
        "UPDATE profiles
            SET cosmetics = (
                SELECT jsonb_object_agg(key, value)
                  FROM jsonb_each_text(cosmetics) AS e
                 WHERE NOT (e.value = ANY($2::text[]))
            )
          WHERE id = $1",
    )
    .bind(user_id)
    .bind(&cosmetic_ids)
    .execute(&state.db)
    .await?;

    ok_json(json!({
        "success": true,
        "revoked": revoked,
    }))
}

async fn cosmetics_codes_list(State(state): State<Arc<AppState>>, _admin: AdminUser) -> ApiResult {
    let rows = sqlx::query(
        "SELECT code, cosmetic_ids, days_duration, max_uses, current_uses, is_active, created_at
           FROM promo_codes
          WHERE cardinality(cosmetic_ids) > 0
          ORDER BY created_at DESC
          LIMIT 200",
    )
    .fetch_all(&state.db)
    .await
    .map_err(|err| {
        tracing::error!(error = %err, "admin cosmetics codes");
        ApiError::internal("Server error")
    })?;
    ok_json(json!({ "codes": rows_to_json(&rows) }))
}

async fn cosmetics_codes_create(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    body: Body,
) -> ApiResult {
    let cosmetic_ids: Vec<String> = match body.get("cosmetic_ids") {
        Some(Value::Array(arr)) => as_strings(arr),
        _ => Vec::new(),
    };

    if cosmetic_ids.is_empty() || cosmetic_ids.len() > MAX_GRANT_ITEMS {
        return Err(ApiError::bad_request(format!(
            "Нужен список cosmetic_ids (1..{MAX_GRANT_ITEMS})"
        )));
    }

    let unknown: Vec<&str> = cosmetic_ids
        .iter()
        .filter(|id| catalog_item(id).is_none())
        .map(|id| id.as_str())
        .collect();
    if !unknown.is_empty() {
        return Err(ApiError::bad_request(format!(
            "Неизвестные id оформления: {}",
            unknown.join(", ")
        )));
    }

    let code = match body.str("code") {
        Some(raw) => {
            let raw = raw.trim().to_uppercase();
            if !raw.is_empty() && raw.len() <= 40 {
                raw
            } else {
                auto_promo_code()
            }
        }
        None => auto_promo_code(),
    };

    let max_uses = body
        .i64("max_uses")
        .map(|v| if v < 1 { 1 } else { v })
        .unwrap_or(100);
    let days_duration = body
        .i64("days")
        .map(|v| if v < 0 { 0 } else { v })
        .unwrap_or(0);

    sqlx::query(
        "INSERT INTO promo_codes (code, days_duration, max_uses, cosmetic_ids)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (code) DO UPDATE
           SET cosmetic_ids = EXCLUDED.cosmetic_ids,
               days_duration = EXCLUDED.days_duration,
               max_uses = EXCLUDED.max_uses,
               is_active = TRUE",
    )
    .bind(&code)
    .bind(days_duration)
    .bind(max_uses)
    .bind(&cosmetic_ids)
    .execute(&state.db)
    .await
    .map_err(|err| {
        tracing::error!(error = %err, "admin cosmetics code create");
        ApiError::internal("Server error creating code")
    })?;

    ok_json(json!({
        "success": true,
        "code": code,
        "cosmetic_ids": cosmetic_ids,
        "max_uses": max_uses,
        "days_duration": days_duration,
    }))
}

// ============================================================================
//  Helpers
// ============================================================================

fn auto_promo_code() -> String {
    let uuid = Uuid::new_v4().to_string();
    format!("MND-{}", uuid[..8].to_uppercase())
}

async fn remove_public_file(dir: &std::path::Path, id: &Uuid) {
    let prefix = format!("{id}.");
    let mut entries = match tokio::fs::read_dir(dir).await {
        Ok(entries) => entries,
        Err(_) => return,
    };
    while let Ok(Some(entry)) = entries.next_entry().await {
        if let Ok(true) = entry
            .file_name()
            .to_str()
            .map(|s| s.starts_with(&prefix))
            .ok_or(false)
        {
            let _ = tokio::fs::remove_file(entry.path()).await;
        }
    }
}

// ============================================================================
//  Router
// ============================================================================

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/stats", get(stats))
        .route("/activity", get(activity_overview))
        .route("/moderation-queue", get(moderation_queue))
        .route("/music-moderation-queue", get(music_moderation_queue))
        .route("/music/{id}/review", post(review_music))
        .route("/assets-moderation-queue", get(assets_moderation_queue))
        .route("/assets/{id}/review", post(review_asset))
        .route("/quest/{id}/review", post(review_quest))
        .route("/blocked-users", get(blocked_users))
        .route("/users/{id}/unblock", post(unblock_user))
        .route("/cosmetics/catalog", get(cosmetics_catalog))
        .route("/cosmetics/grants", get(cosmetics_grants))
        .route("/cosmetics/grant", post(cosmetics_grant))
        .route("/cosmetics/users", get(cosmetics_users))
        .route("/cosmetics/revoke", post(cosmetics_revoke))
        .route(
            "/cosmetics/codes",
            get(cosmetics_codes_list).post(cosmetics_codes_create),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_contains_known_items() {
        assert!(catalog_item("gold_leaf").is_some());
        assert_eq!(catalog_item("gold_leaf").unwrap().tier, "legendary");
        assert!(catalog_item("missing").is_none());
    }

    #[test]
    fn auto_promo_code_format() {
        let code = auto_promo_code();
        assert!(code.starts_with("MND-"));
        assert_eq!(code.len(), 12);
    }
}
