//! Deterministic moderation wrapping `content_rules` — port of `moderation.ts`.

use crate::services::content_rules::{
    ScanOptions, Scope, Severity, Verdict, interest_score, quality_score, scan_text, verdict,
};

pub use crate::services::content_rules::Severity as RuleSeverity;

#[derive(Debug, Clone)]
pub struct ModerationResult {
    pub approved: bool,
    pub reason: String,
    pub is_hard_reject: bool,
    pub quality_score: i64,
    /// Disputed text the rules may not reject on their own: manual queue.
    pub needs_review: bool,
    pub severity: Severity,
}

pub fn moderate_quest_content(
    title: &str,
    description: &str,
    content_sample: &str,
) -> ModerationResult {
    let total_len =
        title.chars().count() + description.chars().count() + content_sample.chars().count();
    if total_len < 50 {
        return ModerationResult {
            approved: false,
            is_hard_reject: true,
            reason: "Слишком мало контента. Квест должен содержать сюжет.".into(),
            quality_score: 0,
            needs_review: false,
            severity: Severity::Medium,
        };
    }

    // Title, description and game text are scanned with their own rules: the
    // storefront forbids profanity, the game body allows it. Game text is
    // capped so publishing never depends on archive size.
    let body: String = content_sample.chars().take(200_000).collect();
    let mut hits = scan_text(title, Scope::Title, ScanOptions::default());
    hits.extend(scan_text(
        description,
        Scope::Description,
        ScanOptions::default(),
    ));
    hits.extend(scan_text(&body, Scope::Body, ScanOptions::default()));
    let v: Verdict = verdict(&hits);

    ModerationResult {
        approved: v.approved,
        is_hard_reject: v.is_hard_reject,
        reason: v.reason,
        quality_score: quality_score(title, description, content_sample),
        needs_review: v.needs_review,
        severity: v.severity,
    }
}

pub fn moderate_game_script(script_content: &str) -> ModerationResult {
    const FORBIDDEN: [&str; 5] = ["window.", "document.", "eval(", "XMLHttpRequest", "fetch("];
    for word in FORBIDDEN {
        if script_content.contains(word) {
            return ModerationResult {
                approved: false,
                is_hard_reject: true,
                reason: format!("Запрещенный код: {word}"),
                quality_score: 0,
                needs_review: false,
                severity: Severity::High,
            };
        }
    }
    ModerationResult {
        approved: true,
        is_hard_reject: false,
        reason: "Код безопасен".into(),
        quality_score: 100,
        needs_review: false,
        severity: Severity::Low,
    }
}

#[derive(Debug, Clone)]
pub struct ReviewVerdict {
    pub approved: bool,
    pub reason: String,
    pub severity: Severity,
    pub needs_review: bool,
}

pub fn moderate_review(text: &str, allow_ads: bool) -> ReviewVerdict {
    if text.trim().chars().count() < 2 {
        return ReviewVerdict {
            approved: false,
            reason: "Отзыв слишком короткий".into(),
            severity: Severity::Low,
            needs_review: false,
        };
    }
    let v = verdict(&scan_text(text, Scope::Review, ScanOptions { allow_ads }));
    ReviewVerdict {
        approved: !v.is_hard_reject,
        reason: v.reason,
        severity: v.severity,
        needs_review: v.needs_review,
    }
}

#[derive(Debug, Clone)]
pub struct WallPostVerdict {
    pub approved: bool,
    pub reason: String,
    pub severity: Severity,
    pub interest_score: i64,
    pub needs_review: bool,
}

pub fn moderate_wall_post(text: &str, media_urls: &[String]) -> WallPostVerdict {
    if text.trim().chars().count() < 2 && media_urls.is_empty() {
        return WallPostVerdict {
            approved: false,
            reason: "Пост слишком короткий".into(),
            severity: Severity::Low,
            interest_score: 0,
            needs_review: false,
        };
    }
    let v = verdict(&scan_text(text, Scope::Post, ScanOptions::default()));
    WallPostVerdict {
        approved: !v.is_hard_reject,
        reason: v.reason,
        severity: v.severity,
        interest_score: interest_score(text, media_urls.len()),
        needs_review: v.needs_review,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_quest_is_hard_rejected() {
        let r = moderate_quest_content("Тест", "", "");
        assert!(r.is_hard_reject);
        assert!(r.reason.to_lowercase().contains("мало контента"));
    }

    #[test]
    fn quest_with_porn_in_body_goes_to_review() {
        let r = moderate_quest_content(
            "Ночная смена в баре",
            "Квест про бариста, который не спал три ночи подряд.",
            "В баре кто-то оставил журнал «порно» на стойке, и все делают вид, что не замечают.",
        );
        assert!(!r.is_hard_reject, "жёсткий отказ: {}", r.reason);
        assert!(!r.approved);
        assert!(r.needs_review);
    }

    #[test]
    fn unsafe_script_is_rejected() {
        for snippet in ["window.alert(1)", "eval('x')", "fetch('/x')"] {
            assert!(moderate_game_script(snippet).is_hard_reject, "{snippet}");
        }
        assert!(moderate_game_script("print('hi')").approved);
    }

    #[test]
    fn short_review_is_rejected() {
        assert!(!moderate_review(" ", false).approved);
        assert!(moderate_review("Отличный квест, прошёл за вечер", false).approved);
    }

    #[test]
    fn empty_wall_post_is_rejected() {
        assert!(!moderate_wall_post("", &[]).approved);
        assert!(moderate_wall_post("Привет всем", &[]).approved);
    }
}
