//! Market catalogue tiers — port of `market_tiers.ts`.
//!
//! 1 — hand-picked best; 2 — moderated, not demo; 3 — demo. The invariant is
//! enforced by a database constraint; both backend write points live here.

pub const MARKET_TIER_BEST: i16 = 1;
pub const MARKET_TIER_MODERATED: i16 = 2;
pub const MARKET_TIER_DEMO: i16 = 3;

/// Tier of a new publication: demos fall to the bottom, everything else is 2.
pub fn tier_for_new_quest(is_demo: bool) -> i16 {
    if is_demo {
        MARKET_TIER_DEMO
    } else {
        MARKET_TIER_MODERATED
    }
}

/// Tier on republish: a manual first tier survives an ordinary republish, a
/// demo losing its flag rises to 2, and flagging demo always drops to 3.
pub const MARKET_TIER_ON_REPUBLISH_SQL: &str = "CASE WHEN EXCLUDED.is_demo THEN 3 WHEN quests.market_tier = 3 THEN 2 ELSE quests.market_tier END";

/// Parses a tier from an admin request: integers 1..3 only.
pub fn parse_market_tier(raw: Option<&str>) -> Option<i16> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    let value: i16 = raw.parse().ok()?;
    (MARKET_TIER_BEST..=MARKET_TIER_DEMO)
        .contains(&value)
        .then_some(value)
}

/// Admin JSON bodies may carry a number instead of a string.
pub fn parse_market_tier_json(raw: &serde_json::Value) -> Option<i16> {
    match raw {
        serde_json::Value::Number(n) => {
            let v = n.as_i64()?;
            i16::try_from(v).ok().filter(|v| (1..=3).contains(v))
        }
        serde_json::Value::String(s) => parse_market_tier(Some(s)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_quest_tier_follows_demo_flag() {
        assert_eq!(tier_for_new_quest(false), 2);
        assert_eq!(tier_for_new_quest(true), 3);
    }

    #[test]
    fn tier_parser_rejects_non_integers_and_range() {
        for good in ["1", "2", "3", " 2 "] {
            assert!(parse_market_tier(Some(good)).is_some(), "{good}");
        }
        for bad in ["", "0", "4", "1.5", "two", "-1"] {
            assert!(parse_market_tier(Some(bad)).is_none(), "{bad}");
        }
        assert_eq!(parse_market_tier_json(&serde_json::json!(2)), Some(2));
        assert_eq!(parse_market_tier_json(&serde_json::json!(9)), None);
    }
}
