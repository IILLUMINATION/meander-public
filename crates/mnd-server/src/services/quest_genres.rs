//! Canonical quest genres — port of `data/quest_genres.ts`. Only stable Latin
//! ids are stored; legacy labels (`Fantasy`, `Sci-Fi`) are translated here.

use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

pub const QUEST_GENRE_IDS: [&str; 52] = [
    "fantasy",
    "dark_fantasy",
    "fairytale",
    "mythology",
    "sci_fi",
    "cyberpunk",
    "steampunk",
    "post_apocalypse",
    "space_opera",
    "horror",
    "supernatural",
    "vampire",
    "werewolf",
    "zombie",
    "mystery",
    "detective",
    "noir",
    "crime",
    "mafia",
    "heist",
    "spy",
    "thriller",
    "psychological",
    "adventure",
    "survival",
    "disaster",
    "war",
    "western",
    "pirates",
    "time_travel",
    "alternate_history",
    "historical",
    "romance",
    "drama",
    "tragedy",
    "comedy",
    "satire",
    "parody",
    "slice_of_life",
    "school",
    "family",
    "sports",
    "music",
    "travel",
    "philosophy",
    "puzzle",
    "escape_room",
    "martial_arts",
    "medical",
    "political",
    "business",
    "farming",
];

pub const MAX_QUEST_GENRES: usize = 3;

static SEPARATORS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\s_]+").unwrap());

fn known(id: &str) -> bool {
    QUEST_GENRE_IDS.contains(&id)
}

fn legacy_alias(key: &str) -> Option<&'static str> {
    Some(match key {
        "fantasy" => "fantasy",
        "sci-fi" => "sci_fi",
        "scifi" => "sci_fi",
        "science-fiction" => "sci_fi",
        "horror" => "horror",
        "adventure" => "adventure",
        "mystery" => "mystery",
        "romance" => "romance",
        "comedy" => "comedy",
        "thriller" => "thriller",
        "historical" => "historical",
        "history" => "historical",
        "drama" => "drama",
        _ => return None,
    })
}

/// Normalises one raw value (string, JSON array item, number) to a genre id.
/// Non-strings are rejected exactly like `String(raw)` on an object would be
/// useless in the original: `42` has no alias and no canonical id.
pub fn normalize_genre_id(raw: &Value) -> Option<String> {
    let value = match raw {
        Value::String(s) => s.trim().to_string(),
        _ => return None,
    };
    if value.is_empty() {
        return None;
    }
    let key = SEPARATORS
        .replace_all(&value.to_lowercase(), "-")
        .to_string();
    if let Some(alias) = legacy_alias(&key) {
        return Some(alias.to_string());
    }
    let snake = key.replace('-', "_");
    known(&snake).then_some(snake)
}

/// Accepts a JSON array or a single value, dedupes, preserves order, caps at
/// `max`. An empty result means "the author selected nothing".
pub fn normalize_quest_genres(raw: &Value, max: usize) -> Vec<String> {
    let items: Vec<&Value> = match raw {
        Value::Array(items) => items.iter().collect(),
        other => vec![other],
    };
    let mut result: Vec<String> = Vec::new();
    for item in items {
        let Some(id) = normalize_genre_id(item) else {
            continue;
        };
        if result.contains(&id) {
            continue;
        }
        result.push(id);
        if result.len() >= max {
            break;
        }
    }
    result
}

/// The multipart/FormData field arrives as a JSON string, a plain string or an
/// array; old clients sent one genre per field.
pub fn genres_from_form_value(raw: Option<&str>) -> Vec<String> {
    let Some(raw) = raw else {
        return Vec::new();
    };
    let parsed =
        serde_json::from_str::<Value>(raw).unwrap_or_else(|_| Value::String(raw.to_string()));
    normalize_quest_genres(&parsed, MAX_QUEST_GENRES)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn catalogue_is_unique_and_stable() {
        assert!(QUEST_GENRE_IDS.len() >= 40);
        let unique: std::collections::HashSet<_> = QUEST_GENRE_IDS.iter().collect();
        assert_eq!(unique.len(), QUEST_GENRE_IDS.len());
        for id in QUEST_GENRE_IDS {
            assert!(
                id.chars().next().is_some_and(|c| c.is_ascii_lowercase())
                    && id
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
                "{id} is not a stable id"
            );
        }
    }

    #[test]
    fn canonical_ids_pass_through() {
        for id in ["fantasy", "sci_fi", "escape_room", "slice_of_life"] {
            assert_eq!(normalize_genre_id(&json!(id)), Some(id.to_string()));
        }
    }

    #[test]
    fn legacy_labels_translate() {
        let map = [
            ("Fantasy", "fantasy"),
            ("Sci-Fi", "sci_fi"),
            ("SciFi", "sci_fi"),
            ("Horror", "horror"),
            ("Adventure", "adventure"),
            ("Mystery", "mystery"),
            ("Romance", "romance"),
            ("Comedy", "comedy"),
            ("Thriller", "thriller"),
            ("Historical", "historical"),
            ("Drama", "drama"),
        ];
        for (legacy, expected) in map {
            assert_eq!(
                normalize_genre_id(&json!(legacy)),
                Some(expected.to_string()),
                "{legacy}"
            );
        }
    }

    #[test]
    fn case_spaces_and_dashes_are_ignored() {
        assert_eq!(
            normalize_genre_id(&json!("  DARK FANTASY ")),
            Some("dark_fantasy".into())
        );
        assert_eq!(
            normalize_genre_id(&json!("post-apocalypse")),
            Some("post_apocalypse".into())
        );
        assert_eq!(normalize_genre_id(&json!("SCI_FI")), Some("sci_fi".into()));
    }

    #[test]
    fn unknown_genres_are_dropped() {
        assert_eq!(normalize_genre_id(&json!("фэнтези")), None);
        assert_eq!(normalize_genre_id(&json!("")), None);
        assert_eq!(normalize_genre_id(&json!(null)), None);
        assert_eq!(normalize_genre_id(&json!(42)), None);
        assert_eq!(
            normalize_quest_genres(&json!(["fantasy", "nonsense", "horror"]), MAX_QUEST_GENRES),
            vec!["fantasy", "horror"]
        );
    }

    #[test]
    fn duplicates_are_removed_and_limit_kept() {
        assert_eq!(
            normalize_quest_genres(
                &json!(["Horror", "horror", "Fantasy", "Drama", "Comedy"]),
                MAX_QUEST_GENRES
            ),
            vec!["horror", "fantasy", "drama"]
        );
        assert_eq!(
            normalize_quest_genres(&json!(["Fantasy", "Drama", "Comedy"]), MAX_QUEST_GENRES).len(),
            MAX_QUEST_GENRES
        );
    }

    #[test]
    fn all_is_a_filter_not_a_genre() {
        assert_eq!(normalize_genre_id(&json!("All")), None);
        assert_eq!(normalize_genre_id(&json!("all")), None);
    }

    #[test]
    fn form_values_parse_both_shapes() {
        assert_eq!(genres_from_form_value(Some("Sci-Fi")), vec!["sci_fi"]);
        assert_eq!(
            genres_from_form_value(Some(r#"["Sci-Fi"]"#)),
            vec!["sci_fi"]
        );
    }
}
