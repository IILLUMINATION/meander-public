//! Market catalogue SQL — port of `market_query.ts`.
//!
//! The query lives here, not in the route, because it carries three promises:
//! only published quests, only what the viewer's adult setting permits, and a
//! genre placeholder that does not shift when search already took `$1`.

pub const QUEST_VIEWS_COUNT_SQL: &str =
    "(SELECT COALESCE(SUM(v.views), 0)::int FROM quest_views v WHERE v.quest_id = mq.id)";

const SELECT: &str = "SELECT mq.*, mq.average_rating::text AS average_rating, (SELECT COALESCE(SUM(v.views), 0)::int FROM quest_views v WHERE v.quest_id = mq.id) AS views_count, p.cosmetics ->> 'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM market_quests mq LEFT JOIN profiles p ON p.id = mq.author_id WHERE mq.status = 'published'";

#[derive(Debug, Default)]
pub struct MarketListOptions {
    pub search: Option<String>,
    pub category: Option<String>,
    pub show_nsfw: bool,
    pub viewer_id: Option<uuid::Uuid>,
    /// Catalogue tier 1..3; `None` — all tiers.
    pub tier: Option<i16>,
    /// Row cap; `None` — no LIMIT (older clients).
    pub limit: Option<i64>,
    pub offset: i64,
}

/// Builds the SQL plus its positional binds. The binds are returned as typed
/// values so the caller can bind them in order.
pub enum Param {
    Text(String),
    Tier(i16),
    Uuid(uuid::Uuid),
    Int(i64),
}

impl MarketListOptions {
    pub fn build(&self) -> (String, Vec<Param>) {
        let mut text = String::from(SELECT);
        let mut params: Vec<Param> = Vec::new();

        if !self.show_nsfw {
            text.push_str(" AND mq.is_nsfw = FALSE");
        }

        if let Some(tier) = self.tier {
            params.push(Param::Tier(tier));
            text.push_str(&format!(" AND mq.market_tier = ${}", params.len()));
        }

        if let Some(search) = self.search.as_ref().filter(|s| !s.is_empty()) {
            params.push(Param::Text(format!("%{search}%")));
            text.push_str(&format!(
                " AND (mq.title ILIKE ${n} OR mq.author_name ILIKE ${n})",
                n = params.len()
            ));
        }

        if let Some(category) = self.category.as_ref().filter(|c| *c != "All") {
            params.push(Param::Text(category.clone()));
            text.push_str(&format!(" AND ${} = ANY(mq.genres)", params.len()));
        }

        // Guideline 1.2: a blocked author disappears from the catalogue of the
        // person who blocked them. Kept last so search/genre numbering does not
        // depend on being signed in.
        if let Some(viewer) = self.viewer_id {
            params.push(Param::Uuid(viewer));
            text.push_str(&format!(
                " AND NOT EXISTS (SELECT 1 FROM user_blocks ub WHERE ub.user_id = ${} AND ub.blocked_id = mq.author_id)",
                params.len()
            ));
        }

        text.push_str(" ORDER BY mq.market_tier ASC, mq.created_at DESC");

        if let Some(limit) = self.limit {
            params.push(Param::Int(limit));
            text.push_str(&format!(" LIMIT ${}", params.len()));
        }
        if self.offset > 0 {
            params.push(Param::Int(self.offset));
            text.push_str(&format!(" OFFSET ${}", params.len()));
        }

        (text, params)
    }
}

/// Binds the built parameters in order.
pub fn bind_params(
    mut query: sqlx::query::Query<'_, sqlx::Postgres, sqlx::postgres::PgArguments>,
    params: Vec<Param>,
) -> sqlx::query::Query<'_, sqlx::Postgres, sqlx::postgres::PgArguments> {
    for param in params {
        query = match param {
            Param::Text(v) => query.bind(v),
            Param::Tier(v) => query.bind(v),
            Param::Uuid(v) => query.bind(v),
            Param::Int(v) => query.bind(v),
        };
    }
    query
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hides_nsfw_and_orders_by_tier_then_freshness() {
        let (text, params) = MarketListOptions::default().build();
        assert!(text.contains("AND mq.is_nsfw = FALSE"));
        assert!(text.ends_with("ORDER BY mq.market_tier ASC, mq.created_at DESC"));
        assert!(params.is_empty());
    }

    #[test]
    fn search_takes_one_placeholder_for_both_columns() {
        let (text, params) = MarketListOptions {
            search: Some("NN".into()),
            category: Some("fantasy".into()),
            viewer_id: Some(uuid::Uuid::nil()),
            tier: Some(2),
            limit: Some(20),
            offset: 40,
            ..Default::default()
        }
        .build();
        assert!(text.contains("mq.market_tier = $1"));
        assert!(text.contains("(mq.title ILIKE $2 OR mq.author_name ILIKE $2)"));
        assert!(text.contains("$3 = ANY(mq.genres)"));
        assert!(text.contains("ub.user_id = $4"));
        assert!(text.contains("LIMIT $5"));
        assert!(text.contains("OFFSET $6"));
        assert_eq!(params.len(), 6);
    }

    #[test]
    fn all_and_empty_filters_are_ignored() {
        let (text, _) = MarketListOptions {
            category: Some("All".into()),
            ..Default::default()
        }
        .build();
        assert!(!text.contains("ANY(mq.genres)"));
        let (text, _) = MarketListOptions {
            search: Some(String::new()),
            ..Default::default()
        }
        .build();
        assert!(!text.contains("ILIKE"));
    }
}
