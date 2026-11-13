//! Content moderation rules — a deterministic port of `content_rules.ts`.
//!
//! The Node version replaced an LLM call: every decision here is enumerable,
//! offline and repeatable. The scope table is the core promise of the file:
//! profanity inside game text may only ask for a human review, while the same
//! word in a title is a hard rejection.
//!
//! JavaScript regex backreferences (`(.)\1{6,}`, `([а-я]{7,})\s*\1`) have no
//! Rust equivalent, so those two spam shapes are detected by scanning runs
//! explicitly.

use std::sync::LazyLock;

use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Low,
    Medium,
    High,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Low => "low",
            Severity::Medium => "medium",
            Severity::High => "high",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Title,
    Description,
    Body,
    Review,
    Post,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleAction {
    Hard,
    Review,
    Off,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuleHit {
    pub code: &'static str,
    pub reason: String,
    pub severity: Severity,
    /// True means reject immediately; false means send to manual review.
    pub hard: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verdict {
    pub approved: bool,
    pub is_hard_reject: bool,
    pub needs_review: bool,
    pub severity: Severity,
    pub reason: String,
    pub codes: Vec<&'static str>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ScanOptions {
    /// Quest authors and admins may post links and announcements.
    pub allow_ads: bool,
}

const MEANDER_HOSTS: [&str; 2] = ["meander.illuminat.dev", "meander.app"];

const MAT_ANYWHERE: [&str; 16] = [
    "пизд",
    "бляд",
    "бля",
    "хуй",
    "хуя",
    "хуе",
    "говн",
    "дерьм",
    "шлюх",
    "гандон",
    "пидар",
    "пидор",
    "ублюд",
    "мудак",
    "задрот",
    "нищеброд",
];

const SELF_HARM: [&str; 13] = [
    "повесись",
    "повесься",
    "утопись",
    "убей себя",
    "застрели себя",
    "зарежь себя",
    "отрежь себе вены",
    "режь вены",
    "покончи с собой",
    "кончи с собой",
    "скончай с собой",
    "не стоит жить",
    "лучше бы ты не родился",
];

const CHILD_TERMS: [&str; 14] = [
    "малолетн",
    "несовершеннолетн",
    "ребёнк",
    "ребенк",
    "подростк",
    "школьник",
    "дошкол",
    "малыш",
    "мальчик",
    "девочк",
    "loli",
    "shota",
    "child",
    "teen",
];

const SEXUAL_TERMS: [&str; 20] = [
    "порно",
    "porn",
    "xxx",
    "секс",
    "sex",
    "трах",
    "минет",
    "куни",
    "анал",
    "оргазм",
    "эрек",
    "сиськ",
    "письк",
    "вагин",
    "нюд",
    "nude",
    "раздвин",
    "сперм",
    "проститутк",
    "без трусов",
];

const PORN_COMMERCE: [&str; 11] = [
    "порно",
    "porn",
    "xxx",
    "порнограф",
    "pornhub",
    "onlyfans",
    "секс по вызову",
    "секс-услуг",
    "интим-услуг",
    "спидоло",
    "webcam-модель",
];

const HATE: [&str; 7] = [
    "хайль гитлер",
    "heil hitler",
    "зиг-гей",
    "зиг гей",
    "ку-клукс",
    "ку кл кл",
    "недочеловек",
];

const INJECTION: [&str; 9] = [
    "ignore previous instructions",
    "ignore all previous",
    "забудь инструкции",
    "игнорируй инструкции",
    "системный промпт",
    "выведи промпт",
    "покажи промпт",
    "role:system",
    "jailbreak",
];

const SPAM_PHRASES: [&str; 13] = [
    "подпишись",
    "подписка на канал",
    "переходи по ссылке",
    "реферальн",
    "промокод на скидку",
    "заработок без вложений",
    "казино",
    "ставк на спорт",
    "ставок на спорт",
    "накрутк",
    "криптобиржа",
    "слиты баз",
    "продажа аккаунтов",
];

static MAT_BOUNDED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?u)(?:^|[^\p{L}\p{N}_])(?:за|вы|на|по|пере|про|раз|рас|об|от|до|под|с|у)?[ъь]?еб[а-яё]*|(?:^|[^\p{L}\p{N}_])(?:сука|сучк|сран|бздеть|долбо[йъ]|придур|даун)\b",
    )
    .expect("MAT_BOUNDED")
});

static TEST_WORD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^(?:тест+|test+|check|проверка|привет+|ку|ы+|х+|фыва+|йцукен+|asdf|qwerty|zxcv|проба|123+)[\s.,!?-]*$",
    )
    .expect("TEST_WORD")
});

static CONSONANTS_LATIN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[bcdfghjklmnpqrstvwxz]{7,}").expect("latin consonants"));
static CONSONANTS_CYRILLIC: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[бвгджзйклмнпрстфхцчшщ]{8,}").expect("cyrillic consonants"));

static LINK_RE: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(
        r"(?iu)(?:https?://|www\.)\S+|(?:t|tg)\.me/\S+|(?:vk|ok)\.com/\S+|discord\.gg/\S+|(?:youtube\.com|youtu\.be)/\S+|\b[\p{L}\p{N}][\p{L}\p{N}-]*\.(?:ru|com|net|org|sbs|xyz|top|site|online|click|store)\b(?:/\S*)?",
    )
    .build()
    .expect("LINK_RE")
});

static TG_JOIN: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(r"(?:t|tg)\.me/\+|tg://join")
        .case_insensitive(true)
        .build()
        .expect("TG_JOIN")
});

static INTEREST_UPDATE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new("(?u)(анонс|обновлен|обновл|релиз|патч|гайд|урок|туториал|разбор|секрет|фишк)")
        .expect("interest update")
});

static INTEREST_MEDIA: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new("(?u)(скриншот|арт|иллюстрац|обложк|впечатления|после игры|прохождение)")
        .expect("interest media")
});

static CYRILLIC_WORD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?u)^[а-яё]{7,}$").expect("cyrillic word"));

fn normalize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            // Zero-width characters used to bypass filters.
            '\u{200b}'..='\u{200d}' | '\u{feff}' | '\u{00ad}' => continue,
            '*' | '_' | '~' | '`' | '|' | '\\' => continue,
            'ё' | 'Ё' => out.push('е'),
            c => out.extend(c.to_lowercase()),
        }
    }
    out
}

fn squash(text: &str) -> String {
    normalize(text)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

fn indexes_of(hay: &str, terms: &[&str]) -> Vec<usize> {
    let mut found = Vec::new();
    for term in terms {
        let mut from = 0;
        while let Some(rel) = hay[from..].find(term) {
            let at = from + rel;
            found.push(at);
            from = at + term.len();
            if from >= hay.len() {
                break;
            }
        }
    }
    found
}

fn closest_gap(a: &[usize], b: &[usize]) -> usize {
    let mut gap = usize::MAX / 2;
    for x in a {
        for y in b {
            gap = gap.min(x.abs_diff(*y));
        }
    }
    gap
}

fn count_profanity(text: &str, squashed: &str) -> usize {
    let mut total = MAT_BOUNDED.find_iter(text).count();
    for root in MAT_ANYWHERE {
        total += text.matches(root).count();
        if squashed.contains(root) {
            total += 1;
        }
    }
    total
}

/// `([а-яё]{7,})\s*\1`: the same long word twice in a row.
fn has_repeated_word(text: &str) -> bool {
    let words: Vec<&str> = text.split_whitespace().collect();
    for pair in words.windows(2) {
        if pair[0] == pair[1] && CYRILLIC_WORD.is_match(pair[0]) {
            return true;
        }
    }
    false
}

fn looks_like_spam_shape(text: &str) -> Option<&'static str> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Some("текст пустой");
    }
    if TEST_WORD.is_match(trimmed) {
        return Some("текст — служебная пометка («тест», «проверка»)");
    }
    // Повтор одного символа спамом не считаем: «███████», «───────», «!!!!»
    // — обычные разделители и цензура в текстах квестов. Правило ложно
    // снимало публикации, поэтому удалено (паритет с Node-бэкендом).
    if has_repeated_word(trimmed) {
        return Some("одно слово повторяется подряд");
    }
    if CONSONANTS_LATIN.is_match(trimmed) {
        return Some("набор согласных");
    }
    if CONSONANTS_CYRILLIC.is_match(trimmed) {
        return Some("набор согласных");
    }

    let words: Vec<&str> = trimmed
        .split_whitespace()
        .filter(|w| w.chars().all(|c| c.is_alphabetic()) && w.chars().count() > 1)
        .collect();
    if words.len() >= 6 {
        let unique = words.iter().collect::<std::collections::HashSet<_>>().len();
        if (unique as f64) / (words.len() as f64) < 0.25 {
            return Some("одни и те же слова по кругу");
        }
    }
    None
}

fn foreign_links(text: &str) -> Vec<String> {
    LINK_RE
        .find_iter(text)
        .map(|m| m.as_str().to_string())
        .filter(|url| !MEANDER_HOSTS.iter().any(|host| url.contains(host)))
        .collect()
}

fn rule_action(scope: Scope, kind: &str) -> RuleAction {
    use RuleAction::{Hard, Off, Review};
    match (scope, kind) {
        (Scope::Title | Scope::Description, "profanity") | (Scope::Review, "profanity") => Hard,
        (Scope::Body | Scope::Post, "profanity") => Review,

        (Scope::Title | Scope::Description | Scope::Review, "ads") => Hard,
        (Scope::Body | Scope::Post, "ads") => Off,

        (Scope::Title | Scope::Description | Scope::Post, "scam") => Review,
        (Scope::Review, "scam") => Hard,
        (Scope::Body, "scam") => Off,
        _ => Off,
    }
}

pub fn scan_text(raw: &str, scope: Scope, options: ScanOptions) -> Vec<RuleHit> {
    let mut hits = Vec::new();
    let text = normalize(raw);
    if text.trim().is_empty() {
        return hits;
    }
    let squashed = squash(raw);

    let self_harm = indexes_of(&text, &SELF_HARM);
    if !self_harm.is_empty() {
        hits.push(RuleHit {
            code: "SELF_HARM",
            reason: "Призыв навредить себе или угроза жизни".into(),
            severity: Severity::High,
            hard: true,
        });
    }

    let child_at = indexes_of(&text, &CHILD_TERMS);
    let sex_at = indexes_of(&text, &SEXUAL_TERMS);
    if !child_at.is_empty() && !sex_at.is_empty() && closest_gap(&child_at, &sex_at) < 120 {
        hits.push(RuleHit {
            code: "CSAM",
            reason: "Сексуальный подтекст вместе с упоминанием несовершеннолетних".into(),
            severity: Severity::High,
            hard: true,
        });
    } else if !indexes_of(&text, &PORN_COMMERCE).is_empty() {
        // Inside game text "порно" is a character's line, not published porn;
        // it goes to humans instead of a silent rejection.
        hits.push(RuleHit {
            code: "PORN",
            reason: "Порнография или интим-услуги".into(),
            severity: Severity::High,
            hard: scope != Scope::Body,
        });
    }

    if !indexes_of(&text, &HATE).is_empty() {
        hits.push(RuleHit {
            code: "HATE",
            reason: "Запрещённая символика или лозунг".into(),
            severity: Severity::High,
            hard: true,
        });
    }

    let mat_total = count_profanity(&text, &squashed);
    if rule_action(scope, "profanity") != RuleAction::Off && mat_total > 0 {
        if rule_action(scope, "profanity") == RuleAction::Hard {
            hits.push(RuleHit {
                code: "PROFANITY",
                reason: format!("Нецензурная брань ({mat_total} сл.)"),
                severity: Severity::High,
                hard: true,
            });
        } else if mat_total >= 3 {
            hits.push(RuleHit {
                code: "PROFANITY_DENSE",
                reason: format!("В тексте много нецензурной брани ({mat_total} сл.) — на проверку"),
                severity: Severity::Medium,
                hard: false,
            });
        }
    }

    if let Some(shape) = looks_like_spam_shape(&text) {
        hits.push(RuleHit {
            code: "SPAM_SHAPE",
            reason: format!("Похоже на спам: {shape}"),
            severity: Severity::Medium,
            hard: matches!(scope, Scope::Title | Scope::Description),
        });
    }

    if !indexes_of(&text, &INJECTION).is_empty() {
        hits.push(RuleHit {
            code: "INJECTION",
            reason: "Попытка служебной инструкции вместо контента".into(),
            severity: Severity::Medium,
            hard: false,
        });
    }

    let links = foreign_links(&text);
    let tme_join = TG_JOIN.is_match(&text);
    let ads_action = rule_action(scope, "ads");
    if !options.allow_ads && ads_action != RuleAction::Off && (tme_join || !links.is_empty()) {
        hits.push(RuleHit {
            code: "ADS",
            reason: if tme_join {
                "Ссылка-приглашение в мессенджер".into()
            } else {
                "Реклама или внешняя ссылка".into()
            },
            severity: Severity::Medium,
            hard: ads_action == RuleAction::Hard,
        });
    }

    if rule_action(scope, "scam") != RuleAction::Off {
        let scam_hits = indexes_of(&text, &SPAM_PHRASES);
        if !scam_hits.is_empty() {
            hits.push(RuleHit {
                code: "SCAM",
                reason: format!(
                    "Спам или сомнительный заработок ({} совпад.)",
                    scam_hits.len()
                ),
                severity: Severity::High,
                hard: rule_action(scope, "scam") == RuleAction::Hard,
            });
        }
    }

    hits
}

pub fn verdict(hits: &[RuleHit]) -> Verdict {
    let hard: Vec<&RuleHit> = hits.iter().filter(|h| h.hard).collect();
    let review: Vec<&RuleHit> = hits.iter().filter(|h| !h.hard).collect();
    let severity = if hits.iter().any(|h| h.severity == Severity::High) {
        Severity::High
    } else if hits.iter().any(|h| h.severity == Severity::Medium) {
        Severity::Medium
    } else {
        Severity::Low
    };
    let first = hard.first().or_else(|| review.first());
    Verdict {
        approved: hits.is_empty(),
        is_hard_reject: !hard.is_empty(),
        needs_review: hard.is_empty() && !review.is_empty(),
        severity,
        reason: first
            .map(|h| h.reason.clone())
            .unwrap_or_else(|| "Нарушений не найдено".into()),
        codes: hits.iter().map(|h| h.code).collect(),
    }
}

/// Feed ranking: length, media and author-update signals.
pub fn interest_score(text: &str, media_count: usize) -> i64 {
    let t = normalize(text);
    let len = t.trim().chars().count() as i64;
    let mut score: i64 = 20;
    if len >= 60 {
        score += 10;
    }
    if len >= 200 {
        score += 18;
    }
    if len >= 600 {
        score += 25;
    }
    if media_count >= 2 {
        score += 14;
    } else if media_count == 1 {
        score += 8;
    }
    if INTEREST_UPDATE.is_match(&t) {
        score += 25;
    } else if INTEREST_MEDIA.is_match(&t) {
        score += 12;
    }
    if t.contains('?') || t.contains('#') {
        score += 4;
    }
    if len < 40 && media_count == 0 {
        score = score.min(30);
    }
    score.clamp(0, 100)
}

/// Quest completeness: volume and vocabulary variety.
pub fn quality_score(title: &str, description: &str, content_sample: &str) -> i64 {
    let all = normalize(&format!("{title} {description} {content_sample}"));
    let words: Vec<&str> = all.split_whitespace().filter(|w| !w.is_empty()).collect();
    if words.len() < 20 {
        return 10;
    }
    let volume = ((words.len() as f64 / 5.0).round() as i64).min(55);
    let unique = words.iter().collect::<std::collections::HashSet<_>>().len();
    let variety = ((unique as f64 / words.len() as f64) * 45.0).round() as i64;
    (volume + variety).clamp(0, 100)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn find<'a>(hits: &'a [RuleHit], code: &str) -> Option<&'a RuleHit> {
        hits.iter().find(|h| h.code == code)
    }

    #[test]
    fn porn_in_body_is_review_not_hard_reject() {
        let v = verdict(&scan_text(
            "Герой шутит про порно в баре",
            Scope::Body,
            ScanOptions::default(),
        ));
        assert!(!v.is_hard_reject);
        assert!(v.needs_review);
    }

    #[test]
    fn porn_in_storefront_is_hard_reject() {
        for scope in [Scope::Title, Scope::Description] {
            let hits = scan_text("порно", scope, ScanOptions::default());
            let hit = find(&hits, "PORN").expect("PORN hit");
            assert!(hit.hard);
        }
    }

    #[test]
    fn spam_shape_in_body_is_soft() {
        // Форма текста, которая остаётся спам-признаком: набор согласных и
        // повтор слова. Повтор одного символа спамом больше не считается.
        for text in ["бвгджзйклмн", "повторение повторение"] {
            let v = verdict(&scan_text(text, Scope::Body, ScanOptions::default()));
            assert!(!v.is_hard_reject, "{text}: body rejected automatically");
            assert!(v.needs_review, "{text}: body not sent to review");
        }
    }

    #[test]
    fn repeated_character_is_not_spam() {
        // «Разделители» и цензура — обычная вёрстка квеста, а не спам:
        // правило «один символ повторяется много раз» снимало честные работы.
        for text in ["███████", "───────", "!!!!!!!!!!!", "аааааааа"] {
            for scope in [Scope::Title, Scope::Description, Scope::Body] {
                let hits = scan_text(text, scope, ScanOptions::default());
                assert!(
                    find(&hits, "SPAM_SHAPE").is_none(),
                    "{text} in {scope:?}: SPAM_SHAPE still fires"
                );
            }
        }
    }

    #[test]
    fn spam_shape_in_storefront_is_hard() {
        for scope in [Scope::Title, Scope::Description] {
            let hits = scan_text("бвгджзйклмн", scope, ScanOptions::default());
            let hit = find(&hits, "SPAM_SHAPE").expect("SPAM_SHAPE hit");
            assert!(hit.hard);
        }
    }

    #[test]
    fn forbidden_content_never_softens() {
        let cases = [
            ("CSAM", "как соблазнить ребенка и секс с ним"),
            ("HATE", "хайль гитлер"),
            ("SELF_HARM", "повесись"),
        ];
        for (code, text) in cases {
            for scope in [Scope::Title, Scope::Description, Scope::Body] {
                let hits = scan_text(text, scope, ScanOptions::default());
                let hit =
                    find(&hits, code).unwrap_or_else(|| panic!("{code} not hit in {scope:?}"));
                assert!(hit.hard, "{code} softened in {scope:?}");
            }
        }
    }

    #[test]
    fn profanity_is_not_triggered_by_innocent_words() {
        // "хлеб", "небо", "Глеб" must survive the bounded "еб" root.
        for text in ["хлеб на столе", "небо синее", "Глеб пришёл"] {
            assert!(
                scan_text(text, Scope::Title, ScanOptions::default()).is_empty(),
                "{text} false positive"
            );
        }
    }

    #[test]
    fn links_are_rejected_in_description_but_allowed_with_ads() {
        let text = "смотри https://example.com/page";
        assert!(
            find(
                &scan_text(text, Scope::Description, ScanOptions::default()),
                "ADS"
            )
            .is_some()
        );
        assert!(
            find(
                &scan_text(text, Scope::Description, ScanOptions { allow_ads: true }),
                "ADS"
            )
            .is_none()
        );
        // A deep link to the project itself is not foreign.
        assert!(
            find(
                &scan_text(
                    "meander.illuminat.dev/share/abc",
                    Scope::Description,
                    ScanOptions::default()
                ),
                "ADS"
            )
            .is_none()
        );
    }

    #[test]
    fn interest_score_is_bounded_and_rewards_updates() {
        assert_eq!(interest_score("привет", 0), 20);
        assert_eq!(interest_score("", 0), 20);
        let update = "Привет! Обновление 2.0: новый патч и гайд по прохождению.";
        assert!(interest_score(update, 0) > 30);
        // 20 base + 10 + 18 + 25 for volume and 14 for media; no phrase bonus.
        assert_eq!(interest_score(&"a".repeat(1000), 5), 87);
    }

    #[test]
    fn quality_score_matches_js_scale() {
        assert_eq!(quality_score("Тест", "", ""), 10);
        let body = (0..30)
            .map(|i| format!("слово{i}"))
            .collect::<Vec<_>>()
            .join(" ");
        let q = quality_score("Заголовок", "Описание", &body);
        assert!((0..=100).contains(&q));
        assert!(q > 10);
    }
}
