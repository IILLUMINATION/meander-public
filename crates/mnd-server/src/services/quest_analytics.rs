//! Per-quest and per-author analytics — port of `quest_analytics.ts`.
//!
//! Days are UTC: `playtime_daily` and `quest_views` store the UTC date computed
//! by the Node server, so comparing it with session-timezone days would produce
//! two different charts over the same data. Every date bucket therefore carries
//! `AT TIME ZONE 'UTC'`, and window bounds use `...T00:00:00Z`.

use std::collections::HashMap;

use chrono::{DateTime, Duration, NaiveDate, NaiveDateTime, Utc};
use futures::TryFutureExt;
use serde_json::{Value, json};
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::error::ApiError;
use crate::json::opt_ts;

pub const MIN_DAYS: i64 = 7;
pub const MAX_DAYS: i64 = 180;

/// Same value as `rewards.ts`; a day below ten minutes is an abandoned tab,
/// not a played day.
const GAME_DAY_MIN_SECONDS: i64 = 600;

const BY_QUEST: &str = "quest_id = $1";
const BY_AUTHOR: &str = "quest_id IN (SELECT id FROM quests WHERE author_id = $1)";

/// UTC date `back` days ago, `YYYY-MM-DD`.
pub fn iso_day(back: i64) -> String {
    (Utc::now() - Duration::days(back))
        .format("%Y-%m-%d")
        .to_string()
}

/// `days` from the query string: only a sane range — one person must not be
/// able to ask the server for the entire output.
pub fn clamp_days(raw: Option<&str>, fallback: i64) -> i64 {
    let parsed = match raw {
        Some(raw) => {
            let raw = raw.trim();
            if raw.is_empty() {
                fallback as f64
            } else {
                raw.parse::<f64>().unwrap_or(f64::NAN)
            }
        }
        None => fallback as f64,
    };
    if !parsed.is_finite() {
        return fallback;
    }
    (parsed.round() as i64).clamp(MIN_DAYS, MAX_DAYS)
}

/// Current and previous windows of equal length, materialised as strings.
pub fn windows_of(days: i64) -> RawWindows {
    RawWindows {
        to: iso_day(0),
        from: iso_day(days - 1),
        prev_to: iso_day(days),
        prev_from: iso_day(days * 2 - 1),
    }
}

#[derive(Debug, Clone)]
pub struct RawWindows {
    pub to: String,
    pub from: String,
    pub prev_to: String,
    pub prev_from: String,
}

#[derive(Debug, Clone, Default)]
pub struct WindowTotals {
    pub views: i64,
    pub viewers: i64,
    pub downloads: i64,
    pub downloaders: i64,
    pub likes: i64,
    pub dislikes: i64,
    pub ratings: i64,
    pub rating_avg: f64,
    pub reviews: i64,
    pub players: i64,
    pub playtime_seconds: i64,
}

/// JS numbers have no `4.0`: whole averages serialise as `4`, fractions keep
/// their digits. serde_json would otherwise print `4.0`.
fn js_number_json(value: f64) -> Value {
    crate::json::js_number(value)
}

impl WindowTotals {
    fn to_json(&self) -> Value {
        json!({
            "views": self.views,
            "viewers": self.viewers,
            "downloads": self.downloads,
            "downloaders": self.downloaders,
            "likes": self.likes,
            "dislikes": self.dislikes,
            "ratings": self.ratings,
            "rating_avg": js_number_json(self.rating_avg),
            "reviews": self.reviews,
            "players": self.players,
            "playtime_seconds": self.playtime_seconds,
        })
    }
}

#[derive(Debug, Clone, Default)]
pub struct DayRow {
    pub day: String,
    pub views: i64,
    pub viewers: i64,
    pub downloads: i64,
    pub likes: i64,
    pub dislikes: i64,
    pub ratings: i64,
    pub rating_avg: Option<f64>,
    pub reviews: i64,
    pub players: i64,
    pub playtime_seconds: i64,
}

impl DayRow {
    fn new(day: String) -> Self {
        Self {
            day,
            ..Default::default()
        }
    }

    fn to_json(&self) -> Value {
        json!({
            "day": self.day,
            "views": self.views,
            "viewers": self.viewers,
            "downloads": self.downloads,
            "likes": self.likes,
            "dislikes": self.dislikes,
            "ratings": self.ratings,
            "rating_avg": self.rating_avg.map(js_number_json),
            "reviews": self.reviews,
            "players": self.players,
            "playtime_seconds": self.playtime_seconds,
        })
    }
}

fn day_key_date(raw: NaiveDate) -> String {
    raw.format("%Y-%m-%d").to_string()
}

/// Totals for both windows in one pass per signal. `FILTER (WHERE ... >= $4)`
/// against `FILTER (WHERE ... < $4)` keeps distinct counters exact: subtracting
/// the current window from a wide range would drop people active in both.
async fn window_totals(
    db: &PgPool,
    subject: Uuid,
    w: &RawWindows,
    scope: &str,
) -> Result<(WindowTotals, WindowTotals), ApiError> {
    let from_ts = format!("{}T00:00:00Z", w.prev_from);
    let to_ts = format!("{}T23:59:59.999Z", w.to);
    let cur_from_ts = format!("{}T00:00:00Z", w.from);

    let views_sql = format!(
        "SELECT COALESCE(sum(views) FILTER (WHERE day >= $4::date),0)::bigint AS n,
                COUNT(DISTINCT user_id) FILTER (WHERE day >= $4::date)::bigint AS u,
                COALESCE(sum(views) FILTER (WHERE day < $4::date),0)::bigint AS pn,
                COUNT(DISTINCT user_id) FILTER (WHERE day < $4::date)::bigint AS pu
           FROM quest_views
          WHERE {scope} AND day BETWEEN $2::date AND $3::date"
    );
    let views = sqlx::query(&views_sql)
        .bind(subject)
        .bind(&w.prev_from)
        .bind(&w.to)
        .bind(&w.from)
        .fetch_one(db);

    let downloads_sql = format!(
        "SELECT COUNT(*) FILTER (WHERE downloaded_at >= $4::timestamptz)::bigint AS n,
                COUNT(DISTINCT user_id) FILTER (WHERE downloaded_at >= $4::timestamptz)::bigint AS u,
                COUNT(*) FILTER (WHERE downloaded_at < $4::timestamptz)::bigint AS pn,
                COUNT(DISTINCT user_id) FILTER (WHERE downloaded_at < $4::timestamptz)::bigint AS pu
           FROM quest_downloads
          WHERE {scope} AND downloaded_at >= $2::timestamptz AND downloaded_at <= $3::timestamptz"
    );
    let downloads = sqlx::query(&downloads_sql)
        .bind(subject)
        .bind(&from_ts)
        .bind(&to_ts)
        .bind(&cur_from_ts)
        .fetch_one(db);

    let votes_sql = format!(
        "SELECT COUNT(*) FILTER (WHERE is_like AND created_at >= $4::timestamptz)::bigint AS l,
                COUNT(*) FILTER (WHERE NOT is_like AND created_at >= $4::timestamptz)::bigint AS d,
                COUNT(*) FILTER (WHERE is_like AND created_at < $4::timestamptz)::bigint AS pl,
                COUNT(*) FILTER (WHERE NOT is_like AND created_at < $4::timestamptz)::bigint AS pd
           FROM quest_votes
          WHERE {scope} AND created_at >= $2::timestamptz AND created_at <= $3::timestamptz"
    );
    let votes = sqlx::query(&votes_sql)
        .bind(subject)
        .bind(&from_ts)
        .bind(&to_ts)
        .bind(&cur_from_ts)
        .fetch_one(db);

    let ratings_sql = format!(
        "SELECT COUNT(*) FILTER (WHERE created_at >= $4::timestamptz)::bigint AS n,
                COALESCE(avg(rating) FILTER (WHERE created_at >= $4::timestamptz),0)::float8 AS a,
                COUNT(*) FILTER (WHERE created_at < $4::timestamptz)::bigint AS pn,
                COALESCE(avg(rating) FILTER (WHERE created_at < $4::timestamptz),0)::float8 AS pa
           FROM ratings
          WHERE {scope} AND created_at >= $2::timestamptz AND created_at <= $3::timestamptz"
    );
    let ratings = sqlx::query(&ratings_sql)
        .bind(subject)
        .bind(&from_ts)
        .bind(&to_ts)
        .bind(&cur_from_ts)
        .fetch_one(db);

    let reviews_sql = format!(
        "SELECT COUNT(*) FILTER (WHERE status = 'approved' AND created_at >= $4::timestamptz)::bigint AS n,
                COUNT(*) FILTER (WHERE status = 'approved' AND created_at < $4::timestamptz)::bigint AS pn
           FROM reviews
          WHERE {scope} AND created_at >= $2::timestamptz AND created_at <= $3::timestamptz"
    );
    let reviews = sqlx::query(&reviews_sql)
        .bind(subject)
        .bind(&from_ts)
        .bind(&to_ts)
        .bind(&cur_from_ts)
        .fetch_one(db);

    let play_sql = format!(
        "SELECT COALESCE(sum(seconds) FILTER (WHERE day >= $4::date),0)::bigint AS n,
                COUNT(DISTINCT user_id) FILTER (WHERE day >= $4::date AND seconds >= $5)::bigint AS u,
                COALESCE(sum(seconds) FILTER (WHERE day < $4::date),0)::bigint AS pn,
                COUNT(DISTINCT user_id) FILTER (WHERE day < $4::date AND seconds >= $5)::bigint AS pu
           FROM playtime_daily
          WHERE {scope} AND day BETWEEN $2::date AND $3::date"
    );
    let play = sqlx::query(&play_sql)
        .bind(subject)
        .bind(&w.prev_from)
        .bind(&w.to)
        .bind(&w.from)
        .bind(GAME_DAY_MIN_SECONDS)
        .fetch_one(db);

    let (views, downloads, votes, ratings, reviews, play) =
        tokio::try_join!(views, downloads, votes, ratings, reviews, play)?;

    let cur = WindowTotals {
        views: views.get::<i64, _>("n"),
        viewers: views.get::<i64, _>("u"),
        downloads: downloads.get::<i64, _>("n"),
        downloaders: downloads.get::<i64, _>("u"),
        likes: votes.get::<i64, _>("l"),
        dislikes: votes.get::<i64, _>("d"),
        ratings: ratings.get::<i64, _>("n"),
        rating_avg: ratings.get::<f64, _>("a"),
        reviews: reviews.get::<i64, _>("n"),
        players: play.get::<i64, _>("u"),
        playtime_seconds: play.get::<i64, _>("n"),
    };
    let prev = WindowTotals {
        views: views.get::<i64, _>("pn"),
        viewers: views.get::<i64, _>("pu"),
        downloads: downloads.get::<i64, _>("pn"),
        downloaders: downloads.get::<i64, _>("pu"),
        likes: votes.get::<i64, _>("pl"),
        dislikes: votes.get::<i64, _>("pd"),
        ratings: ratings.get::<i64, _>("pn"),
        rating_avg: ratings.get::<f64, _>("pa"),
        reviews: reviews.get::<i64, _>("pn"),
        players: play.get::<i64, _>("pu"),
        playtime_seconds: play.get::<i64, _>("pn"),
    };
    Ok((cur, prev))
}

/// Daily series for the current window, keyed by date.
async fn day_series(
    db: &PgPool,
    subject: Uuid,
    from: &str,
    to: &str,
    scope: &str,
) -> Result<HashMap<String, DayRow>, ApiError> {
    let from_ts = format!("{from}T00:00:00Z");
    let to_ts = format!("{to}T23:59:59.999Z");

    let views_sql = format!(
        "SELECT day, SUM(views)::int AS n, COUNT(DISTINCT user_id)::int AS u
           FROM quest_views
          WHERE {scope} AND day BETWEEN $2::date AND $3::date
          GROUP BY day"
    );
    let views = sqlx::query(&views_sql)
        .bind(subject)
        .bind(from)
        .bind(to)
        .fetch_all(db);

    let downloads_sql = format!(
        "SELECT (downloaded_at AT TIME ZONE 'UTC')::date AS day, COUNT(*)::int AS n
           FROM quest_downloads
          WHERE {scope} AND downloaded_at >= $2::timestamptz
            AND downloaded_at <= $3::timestamptz
          GROUP BY day"
    );
    let downloads = sqlx::query(&downloads_sql)
        .bind(subject)
        .bind(&from_ts)
        .bind(&to_ts)
        .fetch_all(db);

    let votes_sql = format!(
        "SELECT (created_at AT TIME ZONE 'UTC')::date AS day,
                COUNT(*) FILTER (WHERE is_like)::int AS l,
                COUNT(*) FILTER (WHERE NOT is_like)::int AS d
           FROM quest_votes
          WHERE {scope} AND created_at >= $2::timestamptz
            AND created_at <= $3::timestamptz
          GROUP BY day"
    );
    let votes = sqlx::query(&votes_sql)
        .bind(subject)
        .bind(&from_ts)
        .bind(&to_ts)
        .fetch_all(db);

    let ratings_sql = format!(
        "SELECT (created_at AT TIME ZONE 'UTC')::date AS day,
                COUNT(*)::int AS n, AVG(rating)::float8 AS a
           FROM ratings
          WHERE {scope} AND created_at >= $2::timestamptz
            AND created_at <= $3::timestamptz
          GROUP BY day"
    );
    let ratings = sqlx::query(&ratings_sql)
        .bind(subject)
        .bind(&from_ts)
        .bind(&to_ts)
        .fetch_all(db);

    let reviews_sql = format!(
        "SELECT (created_at AT TIME ZONE 'UTC')::date AS day,
                COUNT(*) FILTER (WHERE status = 'approved')::int AS n
           FROM reviews
          WHERE {scope} AND created_at >= $2::timestamptz
            AND created_at <= $3::timestamptz
          GROUP BY day"
    );
    let reviews = sqlx::query(&reviews_sql)
        .bind(subject)
        .bind(&from_ts)
        .bind(&to_ts)
        .fetch_all(db);

    let play_sql = format!(
        "SELECT day, SUM(seconds)::bigint AS n,
                COUNT(DISTINCT user_id) FILTER (WHERE seconds >= $4)::int AS u
           FROM playtime_daily
          WHERE {scope} AND day BETWEEN $2::date AND $3::date
          GROUP BY day"
    );
    let play = sqlx::query(&play_sql)
        .bind(subject)
        .bind(from)
        .bind(to)
        .bind(GAME_DAY_MIN_SECONDS)
        .fetch_all(db);

    let (views, downloads, votes, ratings, reviews, play) =
        tokio::try_join!(views, downloads, votes, ratings, reviews, play)?;

    // `AT TIME ZONE 'UTC'` yields `timestamp`; plain `day` is `date`.
    fn day_of(row: &sqlx::postgres::PgRow) -> String {
        if let Ok(date) = row.try_get::<NaiveDate, _>("day") {
            return day_key_date(date);
        }
        row.get::<NaiveDateTime, _>("day")
            .format("%Y-%m-%d")
            .to_string()
    }

    let mut by_day: HashMap<String, DayRow> = HashMap::new();

    for r in &views {
        let day = day_of(r);
        let row = by_day
            .entry(day.clone())
            .or_insert_with(|| DayRow::new(day));
        row.views = r.get::<i32, _>("n") as i64;
        row.viewers = r.get::<i32, _>("u") as i64;
    }
    for r in &downloads {
        let day = day_of(r);
        let row = by_day
            .entry(day.clone())
            .or_insert_with(|| DayRow::new(day));
        row.downloads = r.get::<i32, _>("n") as i64;
    }
    for r in &votes {
        let day = day_of(r);
        let row = by_day
            .entry(day.clone())
            .or_insert_with(|| DayRow::new(day));
        row.likes = r.get::<i32, _>("l") as i64;
        row.dislikes = r.get::<i32, _>("d") as i64;
    }
    for r in &ratings {
        let day = day_of(r);
        let row = by_day
            .entry(day.clone())
            .or_insert_with(|| DayRow::new(day));
        row.ratings = r.get::<i32, _>("n") as i64;
        row.rating_avg = r.try_get::<Option<f64>, _>("a").ok().flatten();
    }
    for r in &reviews {
        let day = day_of(r);
        let row = by_day
            .entry(day.clone())
            .or_insert_with(|| DayRow::new(day));
        row.reviews = r.get::<i32, _>("n") as i64;
    }
    for r in &play {
        let day = day_of(r);
        let row = by_day
            .entry(day.clone())
            .or_insert_with(|| DayRow::new(day));
        row.playtime_seconds = r.get::<i64, _>("n");
        row.players = r.get::<i32, _>("u") as i64;
    }

    Ok(by_day)
}

fn series_json(by_day: &HashMap<String, DayRow>, days: i64) -> Vec<Value> {
    // The series must be continuous: a gap reads as "analytics broke", a zero
    // reads as "nobody came back" — different situations for the author.
    let mut series = Vec::with_capacity(days as usize);
    for i in (0..days).rev() {
        let day = iso_day(i);
        let row = by_day
            .get(&day)
            .cloned()
            .unwrap_or_else(|| DayRow::new(day));
        series.push(row.to_json());
    }
    series
}

/// Detailed stats for one quest in a single answer.
pub async fn get_quest_analytics(
    db: &PgPool,
    quest_id: Uuid,
    days: i64,
) -> Result<Option<Value>, ApiError> {
    let w = windows_of(days);

    let quest = sqlx::query(
        "SELECT id, title, status, created_at,
                COALESCE(downloads_count,0)::int AS downloads_count,
                COALESCE(like_count,0)::int AS like_count,
                COALESCE(dislike_count,0)::int AS dislike_count
           FROM quests WHERE id = $1",
    )
    .bind(quest_id)
    .fetch_optional(db)
    .await?;
    let Some(quest) = quest else { return Ok(None) };

    let (totals, by_day, lifetime, hist) = tokio::try_join!(
        window_totals(db, quest_id, &w, BY_QUEST),
        day_series(db, quest_id, &w.from, &w.to, BY_QUEST),
        sqlx::query(
            "SELECT
               (SELECT COALESCE(sum(views),0) FROM quest_views WHERE quest_id = $1)::bigint AS views,
               (SELECT COUNT(DISTINCT user_id) FROM quest_views WHERE quest_id = $1)::bigint AS viewers,
               (SELECT COALESCE(sum(playtime_seconds),0) FROM user_quest_playtime WHERE quest_id = $1)::bigint AS play_seconds,
               (SELECT COUNT(DISTINCT user_id) FROM playtime_daily WHERE quest_id = $1 AND seconds >= $2)::bigint AS players,
               (SELECT COUNT(*) FROM reviews WHERE quest_id = $1)::bigint AS reviews,
               (SELECT COUNT(*) FROM reviews WHERE quest_id = $1 AND status = 'approved')::bigint AS reviews_approved,
               (SELECT COUNT(*) FROM reviews WHERE quest_id = $1 AND author_reply IS NOT NULL)::bigint AS reviews_answered,
               (SELECT max(day) FROM quest_views WHERE quest_id = $1) AS last_viewed_day,
               (SELECT max(downloaded_at) FROM quest_downloads WHERE quest_id = $1) AS last_downloaded_at,
               (SELECT max(last_played_at) FROM user_quest_playtime WHERE quest_id = $1) AS last_played_at",
        )
        .bind(quest_id)
        .bind(GAME_DAY_MIN_SECONDS)
        .fetch_one(db)
        .map_err(ApiError::from),
        sqlx::query("SELECT rating, COUNT(*)::int AS n FROM ratings WHERE quest_id = $1 GROUP BY rating")
            .bind(quest_id)
            .fetch_all(db)
            .map_err(ApiError::from),
    )?;

    let (cur, prev) = totals;

    let mut hist_by_rating: HashMap<i32, i64> = HashMap::new();
    for r in &hist {
        hist_by_rating.insert(
            r.try_get::<i16, _>("rating").map(i32::from).unwrap_or(0),
            r.try_get::<i32, _>("n").unwrap_or(0) as i64,
        );
    }

    let last_viewed_day: Option<NaiveDate> = lifetime.try_get("last_viewed_day").ok().flatten();
    let last_downloaded_at: Option<DateTime<Utc>> =
        lifetime.try_get("last_downloaded_at").ok().flatten();
    let last_played_at: Option<DateTime<Utc>> = lifetime.try_get("last_played_at").ok().flatten();

    let lifetime_json = json!({
        "views": lifetime.get::<i64, _>("views"),
        "viewers": lifetime.get::<i64, _>("viewers"),
        "plays_total_seconds": lifetime.get::<i64, _>("play_seconds"),
        "players": lifetime.get::<i64, _>("players"),
        "reviews": lifetime.get::<i64, _>("reviews"),
        "reviews_approved": lifetime.get::<i64, _>("reviews_approved"),
        "reviews_answered": lifetime.get::<i64, _>("reviews_answered"),
        "last_viewed_day": last_viewed_day.map(|d| d.format("%Y-%m-%d").to_string()),
        "last_downloaded_at": opt_ts(last_downloaded_at),
        "last_played_at": opt_ts(last_played_at),
    });

    let created_at: Option<DateTime<Utc>> = quest.try_get("created_at").ok().flatten();

    let histogram: Vec<Value> = [5, 4, 3, 2, 1]
        .iter()
        .map(|rating| {
            json!({
                "rating": rating,
                "count": hist_by_rating.get(rating).copied().unwrap_or(0),
            })
        })
        .collect();

    Ok(Some(json!({
        "quest": {
            "id": quest.get::<Uuid, _>("id"),
            "title": quest.get::<String, _>("title"),
            "status": crate::json::text_col(&quest, "status").unwrap_or_default(),
            "created_at": opt_ts(created_at),
            "downloads_count": quest.get::<i32, _>("downloads_count"),
            "like_count": quest.get::<i32, _>("like_count"),
            "dislike_count": quest.get::<i32, _>("dislike_count"),
        },
        "days": days,
        "from": w.from,
        "to": w.to,
        "series": series_json(&by_day, days),
        "window": cur.to_json(),
        "previous": prev.to_json(),
        "lifetime": lifetime_json,
        "rating_histogram": histogram,
    })))
}

/// How many quests are listed row by row: more is an export, not a summary.
const MAX_QUEST_ROWS: i64 = 60;

/// Summary across every quest of one author, computed by the same helpers.
pub async fn get_author_analytics(
    db: &PgPool,
    author_id: Uuid,
    days: i64,
) -> Result<Value, ApiError> {
    let w = windows_of(days);
    let from_ts = format!("{}T00:00:00Z", w.from);
    let to_ts = format!("{}T23:59:59.999Z", w.to);

    let (totals, by_day, counts, rows) = tokio::try_join!(
        window_totals(db, author_id, &w, BY_AUTHOR),
        day_series(db, author_id, &w.from, &w.to, BY_AUTHOR),
        sqlx::query(
            "SELECT COUNT(*)::int AS total,
                    COUNT(*) FILTER (WHERE status = 'published')::int AS published
               FROM quests WHERE author_id = $1",
        )
        .bind(author_id)
        .fetch_one(db)
        .map_err(ApiError::from),
        sqlx::query(
            "SELECT q.id, q.title, q.status,
                    (SELECT COALESCE(sum(v.views),0) FROM quest_views v
                      WHERE v.quest_id = q.id AND v.day BETWEEN $2::date AND $3::date)::bigint AS views,
                    (SELECT COUNT(DISTINCT v2.user_id) FROM quest_views v2
                      WHERE v2.quest_id = q.id AND v2.day BETWEEN $2::date AND $3::date)::bigint AS viewers,
                    (SELECT COUNT(*) FROM quest_downloads d
                      WHERE d.quest_id = q.id AND d.downloaded_at >= $4::timestamptz
                        AND d.downloaded_at <= $5::timestamptz)::bigint AS downloads,
                    (SELECT COUNT(DISTINCT p.user_id) FROM playtime_daily p
                      WHERE p.quest_id = q.id AND p.day BETWEEN $2::date AND $3::date
                        AND p.seconds >= $6)::bigint AS players,
                    (SELECT COALESCE(sum(p2.seconds),0) FROM playtime_daily p2
                      WHERE p2.quest_id = q.id AND p2.day BETWEEN $2::date AND $3::date)::bigint AS play_seconds,
                    (SELECT COUNT(*) FILTER (WHERE vt.is_like) FROM quest_votes vt
                      WHERE vt.quest_id = q.id AND vt.created_at >= $4::timestamptz
                        AND vt.created_at <= $5::timestamptz)::bigint AS likes,
                    (SELECT AVG(r.rating) FROM ratings r WHERE r.quest_id = q.id)::float8 AS rating_avg
               FROM quests q
              WHERE q.author_id = $1
              ORDER BY views DESC, q.created_at DESC
              LIMIT $7",
        )
        .bind(author_id)
        .bind(&w.from)
        .bind(&w.to)
        .bind(&from_ts)
        .bind(&to_ts)
        .bind(GAME_DAY_MIN_SECONDS)
        .bind(MAX_QUEST_ROWS)
        .fetch_all(db)
        .map_err(ApiError::from),
    )?;

    let (cur, prev) = totals;

    let quests: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "id": r.get::<Uuid, _>("id").to_string(),
                "title": r.try_get::<String, _>("title").unwrap_or_default(),
                "status": crate::json::text_col(r, "status").unwrap_or_default(),
                "views": r.get::<i64, _>("views"),
                "viewers": r.get::<i64, _>("viewers"),
                "downloads": r.get::<i64, _>("downloads"),
                "players": r.get::<i64, _>("players"),
                "playtime_seconds": r.get::<i64, _>("play_seconds"),
                "likes": r.get::<i64, _>("likes"),
                "rating_avg": r.try_get::<Option<f64>, _>("rating_avg").ok().flatten().map(js_number_json),
            })
        })
        .collect();

    Ok(json!({
        "days": days,
        "from": w.from,
        "to": w.to,
        "quests_total": counts.get::<i32, _>("total"),
        "quests_published": counts.get::<i32, _>("published"),
        "window": cur.to_json(),
        "previous": prev.to_json(),
        "series": series_json(&by_day, days),
        "quests": quests,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamp_days_keeps_sane_range() {
        assert_eq!(clamp_days(None, 30), 30);
        assert_eq!(clamp_days(Some("abc"), 30), 30);
        assert_eq!(clamp_days(Some(""), 30), 30);
        assert_eq!(clamp_days(Some("1"), 30), MIN_DAYS);
        assert_eq!(clamp_days(Some("9999"), 30), MAX_DAYS);
        assert_eq!(clamp_days(Some("45"), 30), 45);
        assert_eq!(clamp_days(Some("29.6"), 30), 30);
    }

    #[test]
    fn windows_tile_without_overlap() {
        let w = windows_of(30);
        assert_eq!(w.to, iso_day(0));
        assert_eq!(w.from, iso_day(29));
        assert_eq!(w.prev_to, iso_day(30));
        assert_eq!(w.prev_from, iso_day(59));
    }

    #[test]
    fn series_is_continuous_and_oldest_first() {
        let by_day = HashMap::new();
        let series = series_json(&by_day, 3);
        assert_eq!(series.len(), 3);
        assert_eq!(series[0]["day"], json!(iso_day(2)));
        assert_eq!(series[2]["day"], json!(iso_day(0)));
        assert_eq!(series[0]["views"], json!(0));
        assert_eq!(series[0]["rating_avg"], Value::Null);
    }
}
