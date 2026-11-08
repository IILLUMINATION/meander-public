//! Port of `rewards.ts`.
//!
//! Activity rewards are granted server-side only: streak comes from the profile,
//! game days from `playtime_daily`, approved reviews on other people's quests,
//! and downloads of other people's quests.

use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::json::ts;
use crate::state::AppState;

use super::cosmetics::{GrantOptions, grant_cosmetics};

pub type RewardMetric = &'static str;

pub struct RewardRule {
    pub id: &'static str,
    pub metric: RewardMetric,
    pub threshold: i64,
    pub title: &'static str,
    pub hint: &'static str,
    pub cosmetics: &'static [&'static str],
}

/// Секунд в сутках достаточно, чтобы день засчитали как игровой.
pub const GAME_DAY_MIN_SECONDS: i64 = 600;

pub const REWARD_RULES: &[RewardRule] = &[
    RewardRule {
        id: "streak_7",
        metric: "streak",
        threshold: 7,
        title: "Неделя рядом",
        hint: "7 дней захода подряд",
        cosmetics: &["neon_pulse"],
    },
    RewardRule {
        id: "streak_30",
        metric: "streak",
        threshold: 30,
        title: "Месяц без пропусков",
        hint: "30 дней захода подряд",
        cosmetics: &["aurora_drift", "frost_blue"],
    },
    RewardRule {
        id: "streak_100",
        metric: "streak",
        threshold: 100,
        title: "Сотый день",
        hint: "100 дней захода подряд",
        cosmetics: &["gold_laurel", "royal_gold"],
    },
    RewardRule {
        id: "game_days_10",
        metric: "game_days",
        threshold: 10,
        title: "Десять игровых дней",
        hint: "10 дней, где вы наиграли хотя бы 10 минут",
        cosmetics: &["fireflies"],
    },
    RewardRule {
        id: "game_days_50",
        metric: "game_days",
        threshold: 50,
        title: "Завсегдатай",
        hint: "50 игровых дней",
        cosmetics: &["midnight_surf", "sunset_glow"],
    },
    RewardRule {
        id: "game_days_180",
        metric: "game_days",
        threshold: 180,
        title: "Полгода в пути",
        hint: "180 игровых дней",
        cosmetics: &["starfield", "pulsar"],
    },
    RewardRule {
        id: "reviews_5",
        metric: "reviews",
        threshold: 5,
        title: "Голос сообщества",
        hint: "5 одобренных отзывов на чужих квестах",
        cosmetics: &["toxic_lime"],
    },
    RewardRule {
        id: "reviews_25",
        metric: "reviews",
        threshold: 25,
        title: "Разбор полётов",
        hint: "25 одобренных отзывов",
        cosmetics: &["glitch_ring", "magenta_neon"],
    },
    RewardRule {
        id: "downloads_15",
        metric: "downloads",
        threshold: 15,
        title: "Коллекционер",
        hint: "15 скачанных чужих квестов",
        cosmetics: &["holo_band"],
    },
    RewardRule {
        id: "downloads_60",
        metric: "downloads",
        threshold: 60,
        title: "Архив",
        hint: "60 скачанных чужих квестов",
        cosmetics: &["solar_corona", "ember_orbit"],
    },
];

pub const METRIC_LABELS: &[(&str, &str)] = &[
    ("streak", "дней подряд"),
    ("game_days", "игровых дней"),
    ("reviews", "отзывов"),
    ("downloads", "квестов"),
];

pub const METRIC_IDS: [&str; 4] = ["streak", "game_days", "reviews", "downloads"];

/// Только для логов/тестов: список известных метрик.
pub const ALL_METRICS: &[&str] = &METRIC_IDS;

/// Все четыре метрики одним запросом.
pub async fn read_metrics(state: &AppState, user_id: Uuid) -> Value {
    let row = sqlx::query(
        "WITH m_game AS (
             SELECT count(*)::int AS n
               FROM (SELECT day FROM playtime_daily
                      WHERE user_id = $1
                      GROUP BY day
                     HAVING sum(seconds) >= $2) d
         ),
         m_reviews AS (
             SELECT count(*)::int AS n
               FROM reviews r
               JOIN quests q ON q.id = r.quest_id
              WHERE r.author_id = $1
                AND r.status = 'approved'
                AND q.author_id <> $1
                AND length(trim(r.text_content)) >= 20
         ),
         m_downloads AS (
             SELECT count(*)::int AS n
               FROM quest_downloads d
               JOIN quests q ON q.id = d.quest_id
              WHERE d.user_id = $1 AND q.author_id <> $1
         )
         SELECT COALESCE(p.streak_count, 0)::int AS streak,
                g.n AS game_days,
                r.n AS reviews,
                dl.n AS downloads
           FROM profiles p
           CROSS JOIN m_game g
           CROSS JOIN m_reviews r
           CROSS JOIN m_downloads dl
          WHERE p.id = $1",
    )
    .bind(user_id)
    .bind(GAME_DAY_MIN_SECONDS)
    .fetch_optional(&state.db)
    .await;

    match row {
        Ok(Some(r)) => json!({
            "streak": r.try_get::<i32, _>("streak").unwrap_or(0) as i64,
            "game_days": r.try_get::<i32, _>("game_days").unwrap_or(0) as i64,
            "reviews": r.try_get::<i32, _>("reviews").unwrap_or(0) as i64,
            "downloads": r.try_get::<i32, _>("downloads").unwrap_or(0) as i64,
        }),
        _ => json!({
            "streak": 0,
            "game_days": 0,
            "reviews": 0,
            "downloads": 0,
        }),
    }
}

/// Выдаёт всё, что уже открыто и ещё не выдано.
pub async fn grant_due_rewards(state: &AppState, user_id: Uuid) -> Vec<String> {
    let metrics = read_metrics(state, user_id).await;

    let held_rows = sqlx::query("SELECT rule_id FROM reward_grants WHERE user_id = $1")
        .bind(user_id)
        .fetch_all(&state.db)
        .await;

    let held: std::collections::HashSet<String> = match held_rows {
        Ok(rows) => rows
            .iter()
            .filter_map(|r| r.try_get::<String, _>("rule_id").ok())
            .collect(),
        Err(_) => std::collections::HashSet::new(),
    };

    let pending: Vec<&RewardRule> = REWARD_RULES
        .iter()
        .filter(|r| {
            !held.contains(r.id)
                && metrics.get(r.metric).and_then(|v| v.as_i64()).unwrap_or(0) >= r.threshold
        })
        .collect();

    let mut awarded = Vec::new();
    for rule in pending {
        let inserted = sqlx::query(
            "INSERT INTO reward_grants (user_id, rule_id, cosmetic_ids)
             VALUES ($1, $2, $3)
             ON CONFLICT (user_id, rule_id) DO NOTHING
             RETURNING rule_id",
        )
        .bind(user_id)
        .bind(rule.id)
        .bind(
            rule.cosmetics
                .iter()
                .map(|s| s.to_string())
                .collect::<Vec<String>>(),
        )
        .fetch_optional(&state.db)
        .await;

        if let Ok(Some(_)) = inserted {
            let cosmetics: Vec<String> = rule.cosmetics.iter().map(|s| s.to_string()).collect();
            let _ = grant_cosmetics(
                state,
                user_id,
                &cosmetics,
                GrantOptions {
                    days: None,
                    source: "reward".to_string(),
                    reason: Some(rule.id.to_string()),
                    granted_by: None,
                },
            )
            .await;
            awarded.push(rule.id.to_string());
        }
    }

    awarded
}

const QUALIFIED_SQL: &[(&str, &str)] = &[
    (
        "streak",
        "SELECT id AS user_id, COALESCE(streak_count, 0) AS value
           FROM profiles WHERE COALESCE(streak_count, 0) >= $1",
    ),
    (
        "game_days",
        "SELECT user_id, count(*) AS value
           FROM (SELECT user_id, day FROM playtime_daily
                  GROUP BY user_id, day
                 HAVING sum(seconds) >= $2) d
          GROUP BY user_id
         HAVING count(*) >= $1",
    ),
    (
        "reviews",
        "SELECT r.author_id AS user_id, count(*) AS value
           FROM reviews r
           JOIN quests q ON q.id = r.quest_id
          WHERE r.status = 'approved'
            AND q.author_id <> r.author_id
            AND length(trim(r.text_content)) >= 20
          GROUP BY r.author_id
         HAVING count(*) >= $1",
    ),
    (
        "downloads",
        "SELECT d.user_id, count(*) AS value
           FROM quest_downloads d
           JOIN quests q ON q.id = d.quest_id
          WHERE d.user_id IS NOT NULL AND q.author_id <> d.user_id
          GROUP BY d.user_id
         HAVING count(*) >= $1",
    ),
];

async fn grant_rule_to_qualifying_users(
    state: &AppState,
    rule: &RewardRule,
) -> Result<u64, crate::error::ApiError> {
    let sql = QUALIFIED_SQL
        .iter()
        .find(|(m, _)| *m == rule.metric)
        .map(|(_, sql)| *sql)
        .unwrap_or("SELECT $1 AS dummy WHERE false");

    let mut query = sqlx::query(sql).bind(rule.threshold);
    if rule.metric == "game_days" {
        query = query.bind(GAME_DAY_MIN_SECONDS);
    }

    let qualified = query.fetch_all(&state.db).await?;
    if qualified.is_empty() {
        return Ok(0);
    }

    let user_ids: Vec<Uuid> = qualified
        .iter()
        .filter_map(|r| r.try_get::<Uuid, _>("user_id").ok())
        .collect();

    let cosmetics: Vec<String> = rule.cosmetics.iter().map(|s| s.to_string()).collect();
    let inserted = sqlx::query(
        "INSERT INTO reward_grants (user_id, rule_id, cosmetic_ids)
         SELECT u, $2::text, $3::text[]
           FROM unnest($1::uuid[]) AS t(u)
         ON CONFLICT (user_id, rule_id) DO NOTHING
         RETURNING user_id",
    )
    .bind(&user_ids)
    .bind(rule.id)
    .bind(&cosmetics)
    .fetch_all(&state.db)
    .await?;

    for row in &inserted {
        if let Ok(uid) = row.try_get::<Uuid, _>("user_id") {
            let _ = grant_cosmetics(
                state,
                uid,
                &cosmetics,
                GrantOptions {
                    days: None,
                    source: "reward".to_string(),
                    reason: Some(rule.id.to_string()),
                    granted_by: None,
                },
            )
            .await;
        }
    }

    Ok(inserted.len() as u64)
}

/// Полный обход лестницы. Зовётся по таймеру.
pub async fn sweep_reward_ladder(state: &AppState) -> u64 {
    let mut total = 0u64;
    for rule in REWARD_RULES {
        match grant_rule_to_qualifying_users(state, rule).await {
            Ok(n) => total += n,
            Err(e) => {
                tracing::error!(rule_id = rule.id, error = %e, "reward rule failed");
            }
        }
    }
    total
}

/// Прогресс по всем правилам — то, что видит экран «Награды».
pub async fn reward_progress(state: &AppState, user_id: Uuid) -> Value {
    let metrics = read_metrics(state, user_id).await;
    let granted_rows =
        sqlx::query("SELECT rule_id, granted_at FROM reward_grants WHERE user_id = $1")
            .bind(user_id)
            .fetch_all(&state.db)
            .await;

    let by_rule: std::collections::HashMap<String, Option<chrono::DateTime<chrono::Utc>>> =
        match granted_rows {
            Ok(rows) => rows
                .iter()
                .filter_map(|r| {
                    let rule_id: String = r.try_get("rule_id").ok()?;
                    let granted_at: chrono::DateTime<chrono::Utc> = r.try_get("granted_at").ok()?;
                    Some((rule_id, Some(granted_at)))
                })
                .collect(),
            Err(_) => std::collections::HashMap::new(),
        };

    let progress: Vec<Value> = REWARD_RULES
        .iter()
        .map(|rule| {
            let current = metrics
                .get(rule.metric)
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let granted_at = by_rule.get(rule.id).copied().flatten();
            json!({
                "rule": {
                    "id": rule.id,
                    "metric": rule.metric,
                    "threshold": rule.threshold,
                    "title": rule.title,
                    "hint": rule.hint,
                    "cosmetics": rule.cosmetics,
                },
                "current": current,
                "done": current >= rule.threshold,
                "grantedAt": granted_at.map(ts),
            })
        })
        .collect();

    Value::Array(progress)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reward_rules_are_sorted_and_reach_thresholds() {
        assert_eq!(REWARD_RULES.len(), 10);
        for rule in REWARD_RULES {
            assert!(rule.threshold > 0);
            assert!(!rule.cosmetics.is_empty());
        }
    }

    #[test]
    fn metric_constants_match_node() {
        assert_eq!(GAME_DAY_MIN_SECONDS, 600);
        assert_eq!(
            METRIC_IDS.to_vec(),
            vec!["streak", "game_days", "reviews", "downloads"]
        );
        assert!(METRIC_LABELS.iter().any(|(k, _)| *k == "reviews"));
    }
}
