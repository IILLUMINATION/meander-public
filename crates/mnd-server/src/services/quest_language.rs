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
}
