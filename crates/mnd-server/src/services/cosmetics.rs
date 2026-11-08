//! Port of `cosmetics.ts`.
//!
//! The catalogue is kept identical to the Node source: ids, slots and tiers are
//! mirrored in the Flutter client, so any rename here breaks validation and
//! rendering on shipped apps.

use std::collections::HashMap;
use std::sync::LazyLock;

use serde_json::{Map, Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::error::ApiError;
use crate::json::opt_ts;
use crate::state::AppState;

pub const COSMETIC_SLOTS: [&str; 5] = [
    "banner",
    "background",
    "avatar_frame",
    "name_style",
    "effect",
];

pub struct CosmeticDef {
    pub id: &'static str,
    pub slot: &'static str,
    pub tier: &'static str,
}

const COSMETICS_ROWS: &[(&str, &str, &str)] = &[
    ("beige", "banner", "common"),
    ("forest", "banner", "common"),
    ("royal_purple", "banner", "common"),
    ("sunset", "banner", "common"),
    ("ocean", "banner", "common"),
    ("rose", "banner", "common"),
    ("cyber", "banner", "common"),
    ("mono", "banner", "common"),
    ("aurora", "banner", "common"),
    ("aurora_drift", "banner", "rare"),
    ("lava_flow", "banner", "rare"),
    ("neon_grid", "banner", "epic"),
    ("starfield", "banner", "epic"),
    ("oil_slick", "banner", "epic"),
    ("gold_leaf", "banner", "legendary"),
    ("frost_panel", "banner", "rare"),
    ("midnight_surf", "banner", "rare"),
    ("vapor_silk", "banner", "epic"),
    ("solar_prominence", "banner", "epic"),
    ("green_horizon", "banner", "legendary"),
    ("rose_quartz", "banner", "common"),
    ("art_night_meadow", "banner", "common"),
    ("art_golden_field", "banner", "common"),
    ("art_lone_tree", "banner", "common"),
    ("art_forest_bridge", "banner", "common"),
    ("art_pond_robot", "banner", "common"),
    ("art_open_road", "banner", "common"),
    ("bg_night_meadow", "background", "common"),
    ("bg_golden_field", "background", "common"),
    ("bg_lone_tree", "background", "common"),
    ("bg_forest_bridge", "background", "common"),
    ("bg_pond_robot", "background", "common"),
    ("bg_open_road", "background", "common"),
    ("prism_ring", "avatar_frame", "rare"),
    ("neon_pulse", "avatar_frame", "rare"),
    ("gold_laurel", "avatar_frame", "legendary"),
    ("ember_orbit", "avatar_frame", "epic"),
    ("glitch_ring", "avatar_frame", "epic"),
    ("frost_circle", "avatar_frame", "rare"),
    ("soft_line", "avatar_frame", "common"),
    ("solar_corona", "avatar_frame", "legendary"),
    ("holo_band", "avatar_frame", "epic"),
    ("frost_crown", "avatar_frame", "rare"),
    ("mint_halo", "avatar_frame", "common"),
    ("sunset_glow", "name_style", "rare"),
    ("frost_blue", "name_style", "rare"),
    ("toxic_lime", "name_style", "rare"),
    ("royal_gold", "name_style", "legendary"),
    ("magenta_neon", "name_style", "epic"),
    ("pride_wave", "name_style", "epic"),
    ("ink_violet", "name_style", "common"),
    ("polar_shimmer", "name_style", "epic"),
    ("copper_name", "name_style", "rare"),
    ("pulsar", "name_style", "legendary"),
    ("rose_neon", "name_style", "rare"),
    ("graphite", "name_style", "common"),
    ("snowfall", "effect", "rare"),
    ("campfire_embers", "effect", "rare"),
    ("stardust", "effect", "epic"),
    ("fireflies", "effect", "rare"),
    ("coin_rain", "effect", "legendary"),
    ("cherry_blossom", "effect", "rare"),
    ("hearts", "effect", "rare"),
    ("confetti", "effect", "common"),
    ("cold_rain", "effect", "common"),
    ("blizzard", "effect", "epic"),
    ("fireworks", "effect", "legendary"),
    ("rose_down", "effect", "epic"),
    ("monsoon", "effect", "rare"),
    ("witchfire", "effect", "rare"),
    ("glitter", "effect", "common"),
];

static COSMETICS: LazyLock<HashMap<&'static str, CosmeticDef>> = LazyLock::new(|| {
    let mut map = HashMap::with_capacity(COSMETICS_ROWS.len());
    for (id, slot, tier) in COSMETICS_ROWS {
        map.insert(*id, CosmeticDef { id, slot, tier });
    }
    map
});

pub const LEGACY_BANNER_IDS: [&str; 9] = [
    "beige",
    "forest",
    "royal_purple",
    "sunset",
    "ocean",
    "rose",
    "cyber",
    "mono",
    "aurora",
];

fn get_cosmetic(id: &str) -> Option<&'static CosmeticDef> {
    COSMETICS.get(id)
}

/// Бесплатные предметы не требуют записи в `user_cosmetics`.
pub fn is_free_cosmetic(id: &str) -> bool {
    get_cosmetic(id).is_some_and(|d| d.tier == "common")
}

pub fn cosmetic_slot(id: &str) -> Option<&'static str> {
    get_cosmetic(id).map(|d| d.slot)
}

pub fn cosmetic_tier(id: &str) -> Option<&'static str> {
    get_cosmetic(id).map(|d| d.tier)
}

/// Нормализует `cosmetics` из запроса: { slot: id | null }.
/// Бросает `ApiError::bad_request` с русским сообщением.
pub fn validate_equipped(value: &Value) -> Result<Map<String, Value>, String> {
    if value.is_null() {
        return Ok(Map::new());
    }

    let Value::Object(obj) = value else {
        return Err("cosmetics must be an object".to_string());
    };

    let mut result = Map::new();
    for slot in COSMETIC_SLOTS {
        let Some(raw) = obj.get(slot) else {
            continue;
        };
        if raw.is_null() || raw == "" {
            result.insert(slot.to_string(), Value::Null);
            continue;
        }
        let Some(id) = raw.as_str() else {
            return Err(format!("cosmetics.{slot} must be a string"));
        };
        let Some(def) = get_cosmetic(id) else {
            return Err(format!("Неизвестное оформление: {id}"));
        };
        if def.slot != slot {
            return Err(format!("«{id}» не подходит в слот «{slot}»"));
        }
        result.insert(slot.to_string(), Value::String(id.to_string()));
    }
    Ok(result)
}

/// Читает сохранённый снап: выбрасывает id, которых больше нет в каталоге,
/// и предметы не своего слота.
pub fn sanitize_stored(raw: &Value) -> Map<String, Value> {
    let mut result = Map::new();
    let Some(obj) = raw.as_object() else {
        return result;
    };
    for slot in COSMETIC_SLOTS {
        let Some(id) = obj.get(slot).and_then(|v| v.as_str()) else {
            continue;
        };
        if id.is_empty() {
            continue;
        }
        if let Some(def) = get_cosmetic(id)
            && def.slot == slot
        {
            result.insert(slot.to_string(), Value::String(id.to_string()));
        }
    }
    result
}

/// Предметы, на которые у пользователя нет права (бесплатные не проверяются).
pub async fn find_missing_grants(state: &AppState, user_id: Uuid, ids: &[String]) -> Vec<String> {
    let need: Vec<String> = ids
        .iter()
        .filter(|id| !is_free_cosmetic(id))
        .cloned()
        .collect();
    if need.is_empty() {
        return Vec::new();
    }

    let rows = sqlx::query(
        "SELECT cosmetic_id FROM user_cosmetics
          WHERE user_id = $1
            AND cosmetic_id = ANY($2::text[])
            AND (expires_at IS NULL OR expires_at > NOW())",
    )
    .bind(user_id)
    .bind(&need)
    .fetch_all(&state.db)
    .await;

    let held: std::collections::HashSet<String> = match rows {
        Ok(rows) => rows
            .iter()
            .map(|r| r.try_get::<String, _>("cosmetic_id").unwrap_or_default())
            .filter(|s| !s.is_empty())
            .collect(),
        Err(_) => std::collections::HashSet::new(),
    };

    need.into_iter().filter(|id| !held.contains(id)).collect()
}

/// Надетые предметы пользователя с действующими правами.
pub async fn equipped_for(state: &AppState, user_id: Uuid) -> Map<String, Value> {
    let raw: Result<Option<Value>, sqlx::Error> =
        sqlx::query_scalar("SELECT cosmetics FROM profiles WHERE id = $1")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await;
    match raw {
        Ok(Some(value)) => sanitize_stored(&value),
        _ => Map::new(),
    }
}

/// Права пользователя: id + срок (null = бессрочно).
pub async fn list_grants(state: &AppState, user_id: Uuid) -> Vec<Value> {
    let rows = sqlx::query(
        "SELECT cosmetic_id, expires_at FROM user_cosmetics
          WHERE user_id = $1
            AND (expires_at IS NULL OR expires_at > NOW())",
    )
    .bind(user_id)
    .fetch_all(&state.db)
    .await;

    match rows {
        Ok(rows) => rows
            .iter()
            .filter_map(|r| {
                let id: String = r.try_get("cosmetic_id").ok()?;
                let def = get_cosmetic(&id)?;
                let expires_at: Option<chrono::DateTime<chrono::Utc>> =
                    r.try_get("expires_at").ok()?;
                Some(json!({
                    "id": id,
                    "expires_at": opt_ts(expires_at),
                    "tier": def.tier,
                }))
            })
            .collect(),
        Err(_) => Vec::new(),
    }
}

pub struct GrantOptions {
    pub days: Option<i32>,
    pub source: String,
    pub reason: Option<String>,
    pub granted_by: Option<Uuid>,
}

/// Выдаёт предметы. Возвращает (granted, skipped).
#[allow(clippy::too_many_arguments)]
pub async fn grant_cosmetics(
    state: &AppState,
    user_id: Uuid,
    ids: &[String],
    opts: GrantOptions,
) -> Result<(Vec<String>, Vec<String>), ApiError> {
    let mut granted = Vec::new();
    let mut skipped = Vec::new();

    for id in ids {
        let Some(def) = get_cosmetic(id) else {
            skipped.push(id.clone());
            continue;
        };
        if is_free_cosmetic(id) {
            skipped.push(id.clone());
            continue;
        }

        sqlx::query(
            "INSERT INTO user_cosmetics (user_id, cosmetic_id, slot, tier, source, reason, granted_by, expires_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7,
                     CASE WHEN $8::int IS NULL THEN NULL ELSE GREATEST(NOW(), COALESCE(
                         (SELECT expires_at FROM user_cosmetics WHERE user_id = $1 AND cosmetic_id = $2),
                         NOW()
                     )) + ($8 || ' days')::INTERVAL END)
             ON CONFLICT (user_id, cosmetic_id) DO UPDATE
               SET source = EXCLUDED.source,
                   reason = COALESCE(EXCLUDED.reason, user_cosmetics.reason),
                   granted_by = EXCLUDED.granted_by,
                   expires_at = CASE
                       WHEN $8::int IS NULL THEN NULL
                       ELSE GREATEST(NOW(), COALESCE(user_cosmetics.expires_at, NOW())) + ($8 || ' days')::INTERVAL
                   END",
        )
        .bind(user_id)
        .bind(id)
        .bind(def.slot)
        .bind(def.tier)
        .bind(&opts.source)
        .bind(opts.reason.as_deref())
        .bind(opts.granted_by)
        .bind(opts.days)
        .execute(&state.db)
        .await?;

        granted.push(id.clone());
    }

    Ok((granted, skipped))
}

/// legacy-синхронизация: `banner_style` читают старые версии приложения.
pub fn legacy_banner_style(equipped: &Map<String, Value>) -> Option<Value> {
    let id = equipped.get("banner").and_then(|v| v.as_str())?;
    if LEGACY_BANNER_IDS.contains(&id) {
        Some(json!({"type": "preset", "id": id}))
    } else {
        None
    }
}

/// Снимает оформление, срок права на которое истёк.
pub async fn sweep_expired_cosmetics(state: &AppState) -> u64 {
    let free: Vec<String> = COSMETICS_ROWS
        .iter()
        .filter(|(_, _, tier)| *tier == "common")
        .map(|(id, _, _)| id.to_string())
        .collect();

    let res = sqlx::query(
        "WITH worn AS (
             SELECT p.id AS user_id, p.cosmetics
               FROM profiles p
              WHERE p.cosmetics IS NOT NULL
         ),
         kept AS (
             SELECT w.user_id,
                    jsonb_object_agg(e.key, e.value) AS cosmetics
               FROM worn w
               JOIN jsonb_each_text(w.cosmetics) AS e ON TRUE
              WHERE e.value IS NULL
                 OR e.value = ANY($1::text[])
                 OR EXISTS (SELECT 1 FROM user_cosmetics uc
                             WHERE uc.user_id = w.user_id
                               AND uc.cosmetic_id = e.value
                               AND (uc.expires_at IS NULL OR uc.expires_at > NOW()))
           GROUP BY w.user_id
         )
         UPDATE profiles p
            SET cosmetics = k.cosmetics
           FROM kept k
          WHERE p.id = k.user_id
            AND p.cosmetics IS DISTINCT FROM k.cosmetics
         RETURNING p.id",
    )
    .bind(&free)
    .execute(&state.db)
    .await;

    match res {
        Ok(r) => r.rows_affected(),
        Err(_) => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalogue_verifies_free_and_slot() {
        assert!(is_free_cosmetic("beige"));
        assert!(!is_free_cosmetic("gold_leaf"));
        assert_eq!(cosmetic_slot("bg_night_meadow"), Some("background"));
        assert_eq!(cosmetic_slot("unknown"), None);
    }

    #[test]
    fn validate_equipped_accepts_valid_and_null() {
        let value = json!({
            "banner": "gold_leaf",
            "avatar_frame": null,
            "name_style": "royal_gold",
            "effect": ""
        });
        let out = validate_equipped(&value).unwrap();
        assert_eq!(out.get("banner"), Some(&Value::String("gold_leaf".into())));
        assert_eq!(out.get("avatar_frame"), Some(&Value::Null));
        assert_eq!(
            out.get("name_style"),
            Some(&Value::String("royal_gold".into()))
        );
        assert_eq!(out.get("effect"), Some(&Value::Null));
    }

    #[test]
    fn validate_equipped_rejects_wrong_slot_and_unknown() {
        let wrong = json!({"banner": "gold_laurel"}); // frame in banner
        assert!(validate_equipped(&wrong).is_err());

        let unknown = json!({"banner": "not_real"});
        assert!(validate_equipped(&unknown).is_err());
    }

    #[test]
    fn sanitize_stored_drops_bad_entries() {
        let raw = json!({
            "banner": "gold_leaf",
            "avatar_frame": "unknown_thing",
            "name_style": "",
            "effect": null,
            "background": "bg_night_meadow"
        });
        let out = sanitize_stored(&raw);
        assert_eq!(out.len(), 2);
        assert_eq!(out.get("banner"), Some(&Value::String("gold_leaf".into())));
        assert_eq!(
            out.get("background"),
            Some(&Value::String("bg_night_meadow".into()))
        );
    }

    #[test]
    fn legacy_banner_style_for_preset() {
        let mut equipped = Map::new();
        assert!(legacy_banner_style(&equipped).is_none());
        equipped.insert("banner".to_string(), Value::String("aurora".into()));
        let style = legacy_banner_style(&equipped).unwrap();
        assert_eq!(style, json!({"type": "preset", "id": "aurora"}));
    }

    #[test]
    fn legacy_banner_style_ignores_non_preset() {
        let mut equipped = Map::new();
        equipped.insert("banner".to_string(), Value::String("gold_leaf".into()));
        assert!(legacy_banner_style(&equipped).is_none());
    }
}
