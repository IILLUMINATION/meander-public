//! Quest language tag (#331) — port of `quest_language.ts`.

use std::sync::LazyLock;

use regex::RegexBuilder;

static LANGUAGE_TAG: LazyLock<regex::Regex> = LazyLock::new(|| {
    RegexBuilder::new(r"^[a-z]{2,3}(-[a-z0-9]{2,4})?$")
        .case_insensitive(true)
        .build()
        .expect("language tag")
});

const MAX_LENGTH: usize = 35;

/// A valid BCP-47-ish tag or `null`. `null` is not an error: historical quests
/// have no language at all.
pub fn normalize_quest_language(raw: Option<&str>) -> Option<String> {
    let value = raw?.trim();
    if value.is_empty() || value.chars().count() > MAX_LENGTH {
        return None;
    }
    LANGUAGE_TAG.is_match(value).then(|| value.to_string())
}

/// Upper bound on declared languages — mirrors `MAX_QUEST_LANGUAGES`.
pub const MAX_QUEST_LANGUAGES: usize = 8;

/// Quest language list (#331) — port of `normalizeQuestLanguages`.
///
/// The client sends `languages` as a JSON array string inside FormData (the
/// same shape as `genres`), so JSON parsing comes first; a comma-separated
/// string is accepted for manual requests. Invalid tags are dropped silently,
/// duplicates collapse case-insensitively, and the author's order survives:
/// the first tag is the primary one stored in `quests.language`.
pub fn normalize_quest_languages(raw: Option<&str>) -> Vec<String> {
    let Some(value) = raw.map(str::trim).filter(|v| !v.is_empty()) else {
        return Vec::new();
    };
    let items: Vec<String> = if value.starts_with('[') {
        match serde_json::from_str::<serde_json::Value>(value) {
            Ok(serde_json::Value::Array(items)) => items
                .into_iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect(),
            _ => Vec::new(),
        }
    } else {
        value.split(',').map(str::to_string).collect()
    };
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();
    for item in items {
        if let Some(tag) = normalize_quest_language(Some(item.as_str())) {
            if seen.insert(tag.to_lowercase()) {
                result.push(tag);
            }
            if result.len() >= MAX_QUEST_LANGUAGES {
                break;
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_primary_subtags_and_regions() {
        for tag in ["ru", "en", "zh-CN", "pt-BR"] {
            assert_eq!(normalize_quest_language(Some(tag)).as_deref(), Some(tag));
        }
    }

    #[test]
    fn rejects_non_tags() {
        for raw in [
            "",
            "   ",
            "r",
            "russian language",
            "ru_RU",
            "ыы",
            &"a".repeat(36),
        ] {
            assert_eq!(normalize_quest_language(Some(raw)), None, "{raw}");
        }
        assert_eq!(normalize_quest_language(None), None);
    }

    #[test]
    fn accepts_a_json_list_from_formdata() {
        assert_eq!(
            normalize_quest_languages(Some(r#"["ru","en"]"#)),
            vec!["ru".to_string(), "en".to_string()]
        );
    }

    #[test]
    fn accepts_a_comma_separated_list() {
        assert_eq!(
            normalize_quest_languages(Some("ru, en ,ja")),
            vec!["ru".to_string(), "en".to_string(), "ja".to_string()]
        );
    }

    #[test]
    fn keeps_author_order_and_drops_duplicates() {
        assert_eq!(
            normalize_quest_languages(Some(r#"["ja","RU","ru","en"]"#)),
            vec!["ja".to_string(), "RU".to_string(), "en".to_string()]
        );
    }

    #[test]
    fn empty_and_broken_values_give_an_empty_list() {
        for raw in [None, Some(""), Some("   "), Some("[]"), Some(r#"["ru","#)] {
            assert_eq!(normalize_quest_languages(raw), Vec::<String>::new(), "{raw:?}");
        }
    }

    #[test]
    fn caps_the_number_of_languages() {
        let many = format!(
            "[{}]",
            (0..20)
                .map(|i| format!("\"l{}\"", (b'a' + i as u8) as char))
                .collect::<Vec<_>>()
                .join(",")
        );
        assert_eq!(
            normalize_quest_languages(Some(&many)).len(),
            MAX_QUEST_LANGUAGES
        );
    }
}
