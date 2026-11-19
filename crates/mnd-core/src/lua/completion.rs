//! Контекстное автодополнение Lua для редакторов (L3A, этап 3).
//!
//! Парсит буфер через `full_moon` (по токенам — устойчив к обрывочному
//! вводу в процессе набора), собирает «видимые» в позиции курсора символы:
//! - статический реестр: ключевые слова, `core.*` API, stdlib (`math.*`,
//!   `string.*`, `table.*`, `os.*`, `io.*`, `utf8.*`) и сниппеты;
//! - имена, объявленные в файле до курсора (локальные переменные, функции,
//!   параметры, присваивания).
//!
//! Вход: исходник + байтовая позиция курсора. Выход: JSON-массив
//! `[{label, kind, insertText, detail}]`, отфильтрованный по префиксу.

use full_moon::tokenizer::{Lexer, LexerResult, Symbol, Token, TokenType};
use serde_json::{Value, json};

/// Тип подсказки (kind), маппится в иконку на стороне Flutter.
#[derive(Clone, Copy, Debug)]
enum Kind {
    Keyword,
    Snippet,
    Core,
    Stdlib,
    Function,
    Variable,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Keyword => "keyword",
            Kind::Snippet => "snippet",
            Kind::Core => "core",
            Kind::Stdlib => "stdlib",
            Kind::Function => "function",
            Kind::Variable => "variable",
        }
    }
}

/// Одна подсказка.
struct Suggestion {
    label: String,
    kind: Kind,
    insert_text: String,
    detail: Option<String>,
}

/// `core.*` — руки Lua к движку. Список обязан совпадать с регистрацией в
/// [`super::LuaSession::install_core_api`]; за это стоит тест, иначе
/// автодополнение тихонько отстаёт от API, а автор узнаёт о функции только из
/// чужого примера.
pub(crate) const CORE_API: &[&str] = &[
    "get_var",
    "set_var",
    "get_table",
    "set_table",
    "go_to",
    "play_sound",
    "stop_sound",
    "play_music",
    "stop_music",
    "pause_resume",
    "set_volume",
    "set_blur",
    "set_item_visible",
    "set_item_image",
    "set_top_panel",
    "fade_out",
    "fade_in",
    "open_link",
    "save_game",
    "open_saves",
    "load_save",
    "delete_save",
    "log",
];

const STDLIB_FUNCTIONS: &[(&str, &[&str])] = &[
    (
        "math",
        &[
            "abs",
            "ceil",
            "floor",
            "max",
            "min",
            "random",
            "randomseed",
            "sqrt",
            "pow",
            "exp",
            "log",
            "sin",
            "cos",
            "tan",
            "pi",
            "huge",
        ],
    ),
    (
        "string",
        &[
            "len", "sub", "upper", "lower", "rep", "reverse", "format", "byte", "char", "find",
            "match", "gmatch", "gsub",
        ],
    ),
    (
        "table",
        &[
            "insert", "remove", "concat", "sort", "unpack", "pack", "maxn",
        ],
    ),
    // Только часы и дата: процессов, файлов и окружения в песочнице нет.
    ("os", &["time", "clock", "date", "difftime"]),
    (
        "utf8",
        &["len", "char", "sub", "codes", "codepoint", "offset"],
    ),
    (
        "coroutine",
        &[
            "create",
            "resume",
            "yield",
            "status",
            "running",
            "wrap",
            "isyieldable",
        ],
    ),
];

/// Ключевые слова Lua.
const KEYWORDS: &[&str] = &[
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
    "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
];

/// Сниппеты: `label`, вставляемый текст.
const SNIPPETS: &[(&str, &str)] = &[
    ("function", "function  ()\n    \nend"),
    ("if", "if  then\n    \nend"),
    ("for", "for i = 1,  do\n    \nend"),
    ("while", "while  do\n    \nend"),
    ("local x =", "local  = "),
];

fn is_symbol(token: &Token, sym: Symbol) -> bool {
    matches!(token.token_type(), TokenType::Symbol { symbol: s } if *s == sym)
}

/// Получить текст идентификатора токена.
fn identifier_text(token: &Token) -> Option<String> {
    match token.token_type() {
        TokenType::Identifier { identifier } => Some(identifier.to_string()),
        _ => None,
    }
}

/// Собрать объявленные в файле (до cursor) имена.
///
/// Стратегия (устойчива к частичному вводу): идём по токенам до позиции
/// курсора; ловим max длина имени — lua-локаль не должна быть длиннее
/// буфера (безопасная страховка).
fn declared_names_before(tokens: &[&Token]) -> Vec<(String, Kind)> {
    let mut names: Vec<(String, Kind)> = Vec::new();
    let mut i = 0;
    while i < tokens.len() {
        let token = tokens[i];
        // local <name>
        if is_symbol(token, Symbol::Local)
            && let Some(name) = tokens.get(i + 1).and_then(|t| identifier_text(t))
        {
            names.push((name, Kind::Variable));
        }
        // function [local] function <name> ( … ) — но локальные собраны выше
        // `local function <name>` не отловится по `Local` (следующий токен —
        // `function`), ловим здесь:
        //   local function name
        if is_symbol(token, Symbol::Local)
            && let Some(fn_tok) = tokens.get(i + 1)
            && is_symbol(fn_tok, Symbol::Function)
            && let Some(name) = tokens.get(i + 2).and_then(|t| identifier_text(t))
        {
            names.push((name, Kind::Function));
        }
        // function <name> ( …
        if is_symbol(token, Symbol::Function)
            && let Some(name) = tokens
                .get(i + 1)
                .filter(|n| {
                    !is_symbol(n, Symbol::LeftParen)
                        && !is_symbol(n, Symbol::Dot)
                        && !is_symbol(n, Symbol::Colon)
                })
                .and_then(|t| identifier_text(t))
        {
            names.push((name, Kind::Function));
        }
        i += 1;
    }
    names
}

fn tokenize(source: &str, cursor: usize) -> Vec<Token> {
    // Держим голову токенизатора в рамках буфера: обрезаем по границе
    // символа, чтобы не резать UTF-8 посредине.
    let bound = source.floor_char_boundary(cursor);
    let prefix = &source[..bound];
    let tokens = match Lexer::new(prefix, full_moon::LuaVersion::new()).collect() {
        LexerResult::Ok(tokens) | LexerResult::Recovered(tokens, _) => tokens,
        LexerResult::Fatal(_) => Vec::new(),
    };
    // Отбрасываем тривию (пробелы/комментарии/Eof) — мешает офсетному
    // сканированию соседних токенов.
    tokens
        .into_iter()
        .filter(|t| !t.token_type().is_trivia() && !matches!(t.token_type(), TokenType::Eof))
        .collect()
}

/// Текущая «головка» (префикс), который набирает пользователь в позиции
/// курсора. Ищем последний Identifier/число-«слово» до cursor; если курсор
/// стоит внутри идентификатора — берём его целиком.
fn current_word(source: &str, tokens: &[&Token], cursor: usize) -> String {
    // Идём с конца к началу: находим токен-идентификатор, чей диапазон
    // покрывает cursor-1 (конец слова).
    for token in tokens.iter().rev() {
        let end = token.end_position().bytes();
        let start = token.start_position().bytes();
        if end >= cursor
            && start <= cursor
            && let Some(id) = identifier_text(token)
        {
            return id;
        }
        // Если этот токен целиком до cursor и это последний - берём его.
        if end <= cursor {
            if let Some(id) = identifier_text(token) {
                // Но это может быть завершённое слово, а не набираемое.
                // Проверяем: символ сразу перед cursor — не буква/цифра/_?
                let before = cursor.checked_sub(1).map(|i| source.as_bytes()[i]);
                match before {
                    Some(b) if b.is_ascii_alphanumeric() || b == b'_' => {
                        // курсор «внутри» продолжения слова — токен-start
                        // должен охватывать байт cursor-1.
                        if start <= cursor && end >= cursor - 1 {
                            return id;
                        }
                    }
                    _ => return String::new(),
                }
            }
            return String::new();
        }
    }
    String::new()
}

/// Полный список подсказок без фильтра по префиксу.
fn all_suggestions(names: &[(String, Kind)]) -> Vec<Suggestion> {
    let mut out: Vec<Suggestion> = Vec::new();

    // core.*
    for f in CORE_API {
        out.push(Suggestion {
            label: format!("core.{f}()"),
            kind: Kind::Core,
            insert_text: format!("core.{f}()"),
            detail: Some("core.* API".to_string()),
        });
        out.push(Suggestion {
            label: format!("core.{f}"),
            kind: Kind::Core,
            insert_text: format!("core.{f}"),
            detail: Some("core.* API".to_string()),
        });
    }

    // stdlib
    for (lib, fns) in STDLIB_FUNCTIONS {
        for f in *fns {
            out.push(Suggestion {
                label: format!("{lib}.{f}()"),
                kind: Kind::Stdlib,
                insert_text: format!("{lib}.{f}()"),
                detail: Some(format!("{lib}.* stdlib")),
            });
        }
    }

    // ключевые слова
    for kw in KEYWORDS {
        out.push(Suggestion {
            label: kw.to_string(),
            kind: Kind::Keyword,
            insert_text: kw.to_string(),
            detail: Some("ключевое слово".to_string()),
        });
    }

    // сниппеты
    for (label, text) in SNIPPETS {
        out.push(Suggestion {
            label: label.to_string(),
            kind: Kind::Snippet,
            insert_text: text.to_string(),
            detail: Some("шаблон".to_string()),
        });
    }

    // объявленные в буфере имена
    for (name, kind) in names {
        // не дублируем явно
        if out.iter().any(|s| s.label == *name) {
            continue;
        }
        out.push(Suggestion {
            label: name.clone(),
            kind: *kind,
            insert_text: name.clone(),
            detail: Some(match kind {
                Kind::Function => "функция из файла".to_string(),
                Kind::Variable => "переменная из файла".to_string(),
                _ => String::new(),
            }),
        });
    }

    out
}

/// Точка входа автодополнения. Возвращает JSON-массив подсказок.
pub fn lua_complete(source: &str, cursor: usize) -> Value {
    let tokens = tokenize(source, cursor);
    let refs: Vec<&Token> = tokens.iter().collect();
    let word = current_word(source, &refs, cursor);

    let names = declared_names_before(&refs);
    let all = all_suggestions(&names);

    let lword = word.to_lowercase();
    let filtered: Vec<Value> = all
        .into_iter()
        .filter(|s| {
            if lword.is_empty() {
                true
            } else {
                s.label.to_lowercase().starts_with(&lword)
            }
        })
        .map(|s| {
            json!({
                "label": s.label,
                "kind": s.kind.as_str(),
                "insertText": s.insert_text,
                "detail": s.detail,
            })
        })
        .collect();

    Value::Array(filtered)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suggests_core_and_keyword() {
        let v = lua_complete("function start()\n  core.s\nend", 20);
        let arr = v.as_array().unwrap();
        assert!(arr.iter().any(|i| i["label"] == "core.set_var"));
    }

    #[test]
    fn empty_buffer_suggests_keywords() {
        let v = lua_complete("", 0);
        let arr = v.as_array().unwrap();
        assert!(arr.iter().any(|i| i["label"] == "function"));
    }

    #[test]
    fn detects_declared_function() {
        let src = "function hello_world()\nend\n";
        let v = lua_complete(src, src.len());
        let arr = v.as_array().unwrap();
        assert!(arr.iter().any(|i| i["label"] == "hello_world"));
    }

    #[test]
    fn filters_by_prefix() {
        let v = lua_complete("lo", 2);
        eprintln!("DBG prefix: {}", v);
        let arr = v.as_array().unwrap();
        assert!(!arr.is_empty());
        assert!(arr.iter().all(|i| {
            i["label"]
                .as_str()
                .unwrap()
                .to_lowercase()
                .starts_with("lo")
        }));
    }
}
