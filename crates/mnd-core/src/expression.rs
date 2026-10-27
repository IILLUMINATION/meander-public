//! Вычисление выражений квеста.
//!
//! Порт `ExpressionEvaluatorService` из
//! `mnd_player/lib/services/expression_evaluator.dart`: рекурсивный спуск
//! с лексером, подстановка `{переменных}`, функции и чистка чисел.
//!
//! Высокоуровневый каскадный lookup реализован в
//! [`crate::executor::ScriptExecutor::evaluate_expression`].

use serde_json::{Map, Value};

use crate::models::quest_table::{TABLE_VIEW_KEYS, strip_table_view};

/// Результат вычисления выражения; алиас для совместимости с прежним API.
pub type EvalValue = Value;

/// Приведение к числу (как Dart `_toNum`).
pub fn to_num(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}

/// Приведение к bool (как Dart `_toBool`).
pub fn to_bool(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::Null => false,
        Value::String(s) => {
            let text = s.trim().to_lowercase();
            !(text.is_empty() || text == "null" || text == "false")
        }
        _ => true,
    }
}

/// Число из JSON в f64, с целочисленным отображением при .0.
pub fn json_of_f64(f: f64) -> Value {
    if f.is_finite() && f.fract() == 0.0 && f >= (i64::MIN as f64) && f <= (i64::MAX as f64) {
        Value::from(f as i64)
    } else {
        Value::from(f)
    }
}

// ---------------------------------------------------------------------------
// Лексер и парсер (рекурсивный спуск)
// ---------------------------------------------------------------------------

fn is_ident_start(c: char) -> bool {
    c.is_alphabetic() || c == '_'
}

fn is_ident_part(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

#[derive(Debug, Clone, PartialEq)]
enum Token {
    Num(f64),
    Str(String),
    Ident(String),
    Bool(bool),
    Null,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Eq,
    Neq,
    Gt,
    Gte,
    Lt,
    Lte,
    And,
    Or,
    Not,
    LParen,
    RParen,
    LBracket,
    RBracket,
    Dot,
    Comma,
    Eof,
}

struct Lexer {
    chars: Vec<char>,
    pos: usize,
}

impl Lexer {
    fn new(src: &str) -> Self {
        Lexer {
            chars: src.chars().collect(),
            pos: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn peek2(&self) -> Option<char> {
        self.chars.get(self.pos + 1).copied()
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek();
        if c.is_some() {
            self.pos += 1;
        }
        c
    }

    fn skip_ws(&mut self) {
        while self.peek().is_some_and(|c| c.is_whitespace()) {
            self.pos += 1;
        }
    }

    fn tokenize(&mut self) -> Result<Vec<Token>, String> {
        let mut tokens = Vec::new();
        loop {
            self.skip_ws();
            let Some(c) = self.peek() else {
                tokens.push(Token::Eof);
                return Ok(tokens);
            };
            match c {
                '+' => {
                    self.bump();
                    tokens.push(Token::Plus);
                }
                '-' => {
                    self.bump();
                    tokens.push(Token::Minus);
                }
                '*' => {
                    self.bump();
                    tokens.push(Token::Star);
                }
                '/' => {
                    self.bump();
                    tokens.push(Token::Slash);
                }
                '%' => {
                    self.bump();
                    tokens.push(Token::Percent);
                }
                '(' => {
                    self.bump();
                    tokens.push(Token::LParen);
                }
                ')' => {
                    self.bump();
                    tokens.push(Token::RParen);
                }
                '[' => {
                    self.bump();
                    tokens.push(Token::LBracket);
                }
                ']' => {
                    self.bump();
                    tokens.push(Token::RBracket);
                }
                ',' => {
                    self.bump();
                    tokens.push(Token::Comma);
                }
                '.' => {
                    self.bump();
                    tokens.push(Token::Dot);
                }
                '=' => {
                    if self.peek2() == Some('=') {
                        self.bump();
                        self.bump();
                        tokens.push(Token::Eq);
                    } else {
                        return Err("ожидался '=='".into());
                    }
                }
                '!' => {
                    if self.peek2() == Some('=') {
                        self.bump();
                        self.bump();
                        tokens.push(Token::Neq);
                    } else {
                        self.bump();
                        tokens.push(Token::Not);
                    }
                }
                '>' => {
                    if self.peek2() == Some('=') {
                        self.bump();
                        self.bump();
                        tokens.push(Token::Gte);
                    } else {
                        self.bump();
                        tokens.push(Token::Gt);
                    }
                }
                '<' => {
                    if self.peek2() == Some('=') {
                        self.bump();
                        self.bump();
                        tokens.push(Token::Lte);
                    } else {
                        self.bump();
                        tokens.push(Token::Lt);
                    }
                }
                '&' => {
                    if self.peek2() == Some('&') {
                        self.bump();
                        self.bump();
                        tokens.push(Token::And);
                    } else {
                        return Err("ожидался '&&'".into());
                    }
                }
                '|' => {
                    if self.peek2() == Some('|') {
                        self.bump();
                        self.bump();
                        tokens.push(Token::Or);
                    } else {
                        return Err("ожидался '||'".into());
                    }
                }
                '\'' | '"' => {
                    let quote = c;
                    self.bump();
                    let mut s = String::new();
                    loop {
                        let Some(nc) = self.bump() else {
                            return Err("незакрытая строка".into());
                        };
                        if nc == quote {
                            break;
                        }
                        if nc == '\\' {
                            if let Some(escaped) = self.bump() {
                                s.push(match escaped {
                                    'n' => '\n',
                                    't' => '\t',
                                    'r' => '\r',
                                    '\\' => '\\',
                                    '\'' => '\'',
                                    '"' => '"',
                                    other => other,
                                });
                            }
                        } else {
                            s.push(nc);
                        }
                    }
                    tokens.push(Token::Str(s));
                }
                c if c.is_ascii_digit()
                    || (c == '.' && self.peek2().is_some_and(|d| d.is_ascii_digit())) =>
                {
                    let mut num = String::new();
                    while let Some(d) = self.peek() {
                        if d.is_ascii_digit() || (d == '.' && !num.contains('.')) {
                            num.push(d);
                            self.bump();
                        } else if d == 'e' || d == 'E' {
                            if num.contains('e') || num.contains('E') {
                                break;
                            }
                            num.push(d);
                            self.bump();
                            if self.peek() == Some('-') || self.peek() == Some('+') {
                                num.push(self.bump().unwrap());
                            }
                            while self.peek().is_some_and(|x| x.is_ascii_digit()) {
                                num.push(self.bump().unwrap());
                            }
                        } else {
                            break;
                        }
                    }
                    let v: f64 = num
                        .parse()
                        .map_err(|_| format!("невалидное число: {num}"))?;
                    // Паритет с Dart: «500ms» — это не число. Если сразу после
                    // цифрового токена идёт буква/подчёркивание, токен целиком
                    // становится идентификатором («500ms»), а не числом 500.
                    if self.peek().is_some_and(is_ident_start) {
                        while let Some(d) = self.peek() {
                            if is_ident_part(d) {
                                num.push(d);
                                self.bump();
                            } else {
                                break;
                            }
                        }
                        tokens.push(Token::Ident(num));
                    } else {
                        tokens.push(Token::Num(v));
                    }
                }
                c if is_ident_start(c) => {
                    let mut ident = String::new();
                    while let Some(d) = self.peek() {
                        if is_ident_part(d) {
                            ident.push(d);
                            self.bump();
                        } else {
                            break;
                        }
                    }
                    match ident.as_str() {
                        "true" => tokens.push(Token::Bool(true)),
                        "false" => tokens.push(Token::Bool(false)),
                        "null" => tokens.push(Token::Null),
                        _ => tokens.push(Token::Ident(ident)),
                    }
                }
                other => {
                    return Err(format!(
                        "неожиданный символ '{other}' (позиция {})",
                        self.pos
                    ));
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    Neq,
    Gt,
    Gte,
    Lt,
    Lte,
    And,
    Or,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum UnOp {
    Neg,
    Not,
}

#[derive(Debug, Clone, PartialEq)]
enum Expr {
    Num(f64),
    Str(String),
    Bool(bool),
    Null,
    Var(String),
    Group(Box<Expr>),
    Unary(UnOp, Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    Index(Box<Expr>, Box<Expr>),
    Field(Box<Expr>, String),
    Call(Box<Expr>, Vec<Expr>),
}

/// Потолок вложенности `(` и аргументов функций. Каждый уровень стоит ~8
/// стековых кадров в парсере и столько же в `eval_expr`; без потолка
/// формула из тысячи скобок не возвращает ошибку парсера, а роняет процесс
/// переполнением стека — это ловится только abort'ом, а не `Err`.
const MAX_EXPR_DEPTH: usize = 64;

struct Parser<'a> {
    tokens: &'a [Token],
    pos: usize,
    /// Текущая глубина рекурсии по скобкам и аргументам функций.
    depth: usize,
}

impl<'a> Parser<'a> {
    fn new(tokens: &'a [Token]) -> Self {
        Parser {
            tokens,
            pos: 0,
            depth: 0,
        }
    }

    fn peek(&self) -> &Token {
        self.tokens.get(self.pos).unwrap_or(&Token::Eof)
    }

    fn next(&mut self) -> Token {
        let t = self.peek().clone();
        if !matches!(t, Token::Eof) {
            self.pos += 1;
        }
        t
    }

    fn expect_rparen(&mut self) -> Result<(), String> {
        match self.next() {
            Token::RParen => Ok(()),
            other => Err(format!("ожидался ')', получен {other:?}")),
        }
    }

    fn expect_rbracket(&mut self) -> Result<(), String> {
        match self.next() {
            Token::RBracket => Ok(()),
            other => Err(format!("ожидался ']', получен {other:?}")),
        }
    }

    fn parse_expr(&mut self) -> Result<Expr, String> {
        self.depth += 1;
        let result = if self.depth > MAX_EXPR_DEPTH {
            Err(format!(
                "слишком глубокая вложенность скобок (>{MAX_EXPR_DEPTH})"
            ))
        } else {
            self.parse_or()
        };
        self.depth -= 1;
        result
    }

    fn parse_or(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_and()?;
        while matches!(self.peek(), Token::Or) {
            self.next();
            let right = self.parse_and()?;
            left = Expr::Binary(BinOp::Or, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_and(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_comparison()?;
        while matches!(self.peek(), Token::And) {
            self.next();
            let right = self.parse_comparison()?;
            left = Expr::Binary(BinOp::And, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_comparison(&mut self) -> Result<Expr, String> {
        let left = self.parse_additive()?;
        let op = match self.peek() {
            Token::Eq => BinOp::Eq,
            Token::Neq => BinOp::Neq,
            Token::Gt => BinOp::Gt,
            Token::Gte => BinOp::Gte,
            Token::Lt => BinOp::Lt,
            Token::Lte => BinOp::Lte,
            _ => return Ok(left),
        };
        self.next();
        let right = self.parse_additive()?;
        Ok(Expr::Binary(op, Box::new(left), Box::new(right)))
    }

    fn parse_additive(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_multiplicative()?;
        loop {
            let op = match self.peek() {
                Token::Plus => BinOp::Add,
                Token::Minus => BinOp::Sub,
                _ => return Ok(left),
            };
            self.next();
            let right = self.parse_multiplicative()?;
            left = Expr::Binary(op, Box::new(left), Box::new(right));
        }
    }

    fn parse_multiplicative(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_unary()?;
        loop {
            let op = match self.peek() {
                Token::Star => BinOp::Mul,
                Token::Slash => BinOp::Div,
                Token::Percent => BinOp::Mod,
                _ => return Ok(left),
            };
            self.next();
            let right = self.parse_unary()?;
            left = Expr::Binary(op, Box::new(left), Box::new(right));
        }
    }

    fn parse_unary(&mut self) -> Result<Expr, String> {
        match self.peek() {
            Token::Minus => {
                self.next();
                Ok(Expr::Unary(UnOp::Neg, Box::new(self.parse_unary()?)))
            }
            Token::Plus => {
                self.next();
                self.parse_unary()
            }
            Token::Not => {
                self.next();
                Ok(Expr::Unary(UnOp::Not, Box::new(self.parse_unary()?)))
            }
            _ => self.parse_postfix(),
        }
    }

    fn parse_postfix(&mut self) -> Result<Expr, String> {
        let mut expr = self.parse_primary()?;
        loop {
            match self.peek() {
                Token::LBracket => {
                    self.next();
                    let index = self.parse_expr()?;
                    self.expect_rbracket()?;
                    expr = Expr::Index(Box::new(expr), Box::new(index));
                }
                Token::Dot => {
                    self.next();
                    let key = match self.next() {
                        Token::Ident(name) => name,
                        other => return Err(format!("ожидался ключ, получен {other:?}")),
                    };
                    expr = Expr::Field(Box::new(expr), key);
                }
                Token::LParen => {
                    self.next();
                    let mut args = Vec::new();
                    if !matches!(self.peek(), Token::RParen) {
                        loop {
                            args.push(self.parse_expr()?);
                            if matches!(self.peek(), Token::Comma) {
                                self.next();
                            } else {
                                break;
                            }
                        }
                    }
                    self.expect_rparen()?;
                    expr = Expr::Call(Box::new(expr), args);
                }
                _ => return Ok(expr),
            }
        }
    }

    fn parse_primary(&mut self) -> Result<Expr, String> {
        match self.next() {
            Token::Num(n) => Ok(Expr::Num(n)),
            Token::Str(s) => Ok(Expr::Str(s)),
            Token::Bool(b) => Ok(Expr::Bool(b)),
            Token::Null => Ok(Expr::Null),
            Token::Ident(name) => Ok(Expr::Var(name)),
            Token::LParen => {
                let inner = self.parse_expr()?;
                self.expect_rparen()?;
                Ok(Expr::Group(Box::new(inner)))
            }
            other => Err(format!("неожиданный токен {other:?}")),
        }
    }
}

// ---------------------------------------------------------------------------
// Вычисление
// ---------------------------------------------------------------------------

/// Контекст выполнения выражения.
pub struct EvalContext<'a> {
    pub variables: &'a Map<String, Value>,
}

fn eval_expr(e: &Expr, c: &EvalContext) -> Value {
    match e {
        Expr::Num(n) => json_of_f64(*n),
        Expr::Str(s) => Value::String(s.clone()),
        Expr::Bool(b) => Value::Bool(*b),
        Expr::Null => Value::Null,
        Expr::Var(name) => c.variables.get(name).cloned().unwrap_or(Value::Null),
        Expr::Group(inner) => eval_expr(inner, c),
        Expr::Unary(op, inner) => {
            let v = eval_expr(inner, c);
            match op {
                UnOp::Neg => to_num(&v).map(|n| json_of_f64(-n)).unwrap_or(Value::Null),
                UnOp::Not => Value::Bool(!to_bool(&v)),
            }
        }
        Expr::Binary(op, left, right) => {
            let l = eval_expr(left, c);
            let r = eval_expr(right, c);
            eval_binary(*op, &l, &r)
        }
        Expr::Index(base, index) => {
            let b = eval_expr(base, c);
            let i = eval_expr(index, c);
            index_value(&b, &i)
        }
        Expr::Field(base, key) => match eval_expr(base, c) {
            Value::Object(map) => map.get(key).cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        },
        Expr::Call(base, args) => {
            let fn_name = match base.as_ref() {
                Expr::Var(n) => n.clone(),
                _ => return Value::Null,
            };
            let args: Vec<Value> = args.iter().map(|a| eval_expr(a, c)).collect();
            call_function(&fn_name, &args, c)
        }
    }
}

fn index_value(base: &Value, idx: &Value) -> Value {
    match (base, idx) {
        (Value::Object(map), Value::String(key)) => {
            map.get(key).cloned().unwrap_or_else(|| {
                // Переменная как ключ: в Dart currentObj[varKey] ?? currentObj[varKey.toString()]
                let vk = key;
                map.get(vk).cloned().unwrap_or(Value::Null)
            })
        }
        (Value::Array(arr), Value::Number(n)) => n
            .as_i64()
            .and_then(|i| arr.get(i as usize))
            .cloned()
            .unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

fn eval_binary(op: BinOp, l: &Value, r: &Value) -> Value {
    match op {
        BinOp::Add => {
            if let (Some(a), Some(b)) = (to_num(l), to_num(r)) {
                return json_of_f64(a + b);
            }
            // Строковая конкатенация (как Dart: num+num иначе "abc"+"def").
            Value::String(format!("{}{}", string_repr(l), string_repr(r)))
        }
        BinOp::Sub => num2(l, r, |a, b| a - b),
        BinOp::Mul => num2(l, r, |a, b| a * b),
        BinOp::Div => match (to_num(l), to_num(r)) {
            (Some(a), Some(b)) if b != 0.0 => json_of_f64(a / b),
            _ => Value::Null,
        },
        BinOp::Mod => match (to_num(l), to_num(r)) {
            (Some(a), Some(b)) if b != 0.0 => json_of_f64(a % b),
            _ => Value::Null,
        },
        BinOp::Eq => Value::Bool(values_equal(l, r)),
        BinOp::Neq => Value::Bool(!values_equal(l, r)),
        BinOp::Gt => Value::Bool(compare_values(l, r, &|a, b| a > b)),
        BinOp::Gte => Value::Bool(compare_values(l, r, &|a, b| a >= b)),
        BinOp::Lt => Value::Bool(compare_values(l, r, &|a, b| a < b)),
        BinOp::Lte => Value::Bool(compare_values(l, r, &|a, b| a <= b)),
        BinOp::And => Value::Bool(to_bool(l) && to_bool(r)),
        BinOp::Or => Value::Bool(to_bool(l) || to_bool(r)),
    }
}

fn num2(l: &Value, r: &Value, op: impl Fn(f64, f64) -> f64) -> Value {
    match (to_num(l), to_num(r)) {
        (Some(a), Some(b)) => json_of_f64(op(a, b)),
        _ => Value::Null,
    }
}

fn string_repr(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn compare_values(l: &Value, r: &Value, cmp: &dyn Fn(f64, f64) -> bool) -> bool {
    if let (Some(a), Some(b)) = (to_num(l), to_num(r)) {
        return cmp(a, b);
    }
    let ls = string_repr(l);
    let rs = string_repr(r);
    match ls.cmp(&rs) {
        std::cmp::Ordering::Greater => cmp(2.0, 1.0),
        std::cmp::Ordering::Less => cmp(1.0, 2.0),
        std::cmp::Ordering::Equal => cmp(1.0, 1.0),
    }
}

/// Значение функции. `c` нужен `get_var`/`has_var` и табличным функциям: имя
/// переменной или таблицы приходит из строки, так что без контекста их не
/// реализовать.
fn call_function(name: &str, args: &[Value], c: &EvalContext) -> Value {
    match name {
        // ── Числа ─────────────────────────────────────────────────────────
        "abs" => unary_num(args, f64::abs),
        "ceil" => unary_num(args, f64::ceil),
        "floor" => unary_num(args, f64::floor),
        "trunc" => unary_num(args, f64::trunc),
        "int" => unary_num(args, f64::trunc),
        "sign" => unary_num(args, f64::signum),
        "sqrt" => unary_num(args, f64::sqrt),
        "sin" => unary_num(args, f64::sin),
        "cos" => unary_num(args, f64::cos),
        "tan" => unary_num(args, f64::tan),
        "asin" => unary_num(args, f64::asin),
        "acos" => unary_num(args, f64::acos),
        "atan" => unary_num(args, f64::atan),
        "ln" => unary_num(args, f64::ln),
        "log10" => unary_num(args, f64::log10),
        "log2" => unary_num(args, f64::log2),
        "exp" => unary_num(args, f64::exp),
        "deg" => unary_num(args, f64::to_degrees),
        "rad" => unary_num(args, f64::to_radians),
        "round" => {
            let Some(first) = args.first().and_then(to_num_some) else {
                return Value::Null;
            };
            let digits = args.get(1).and_then(to_num_some).unwrap_or(0.0);
            if digits == 0.0 {
                json_of_f64(first.round())
            } else {
                let mul = 10f64.powi(digits as i32);
                json_of_f64((first * mul).round() / mul)
            }
        }
        "pow" => two_num_op(args, |x, e| x.powf(e)),
        "hypot" => two_num_op(args, f64::hypot),
        "atan2" => two_num_op(args, f64::atan2),
        // Остаток всегда неотрицателен при положительном делителе: `mod(-1, 3)`
        // даёт 2, а не -1 — иначе `mod(i, 3)` для чередования строк ломается на
        // отрицательных индексах.
        "mod" => {
            let (Some(a), Some(b)) = (
                args.first().and_then(to_num_some),
                args.get(1).and_then(to_num_some),
            ) else {
                return Value::Null;
            };
            if b == 0.0 {
                return Value::Null;
            }
            json_of_f64(a - (a / b).floor() * b)
        }
        "log" => {
            let Some(x) = args.first().and_then(to_num_some) else {
                return Value::Null;
            };
            if x <= 0.0 {
                return Value::Null;
            }
            match args.get(1).and_then(to_num_some) {
                Some(base) if base > 0.0 && base != 1.0 => json_of_f64(x.log(base)),
                None => json_of_f64(x.log10()),
                _ => Value::Null,
            }
        }
        // min/max/sum/avg считают и числа, и массивы чисел: `sum(1, 2, scores)`.
        "min" => fold_nums(args, f64::min),
        "max" => fold_nums(args, f64::max),
        "sum" => {
            let nums = flatten_nums(args);
            if nums.is_empty() {
                return Value::Null;
            }
            json_of_f64(nums.iter().sum())
        }
        "avg" => {
            let nums = flatten_nums(args);
            if nums.is_empty() {
                return Value::Null;
            }
            json_of_f64(nums.iter().sum::<f64>() / nums.len() as f64)
        }
        "clamp" => {
            let (Some(v), Some(lo), Some(hi)) = (
                args.first().and_then(to_num_some),
                args.get(1).and_then(to_num_some),
                args.get(2).and_then(to_num_some),
            ) else {
                return Value::Null;
            };
            json_of_f64(v.max(lo).min(hi))
        }
        "between" => {
            let (Some(v), Some(lo), Some(hi)) = (
                args.first().and_then(to_num_some),
                args.get(1).and_then(to_num_some),
                args.get(2).and_then(to_num_some),
            ) else {
                return Value::Null;
            };
            Value::Bool((lo.min(hi)..=lo.max(hi)).contains(&v))
        }
        "pi" => Value::from(std::f64::consts::PI),
        "e" => Value::from(std::f64::consts::E),
        "random" => {
            let min_v = args.first().and_then(to_num_some).unwrap_or(0.0);
            let max_v = args.get(1).and_then(to_num_some).unwrap_or(1.0);
            if min_v <= max_v {
                random_range(min_v, max_v)
            } else {
                random_range(max_v, min_v)
            }
        }
        // ── Текст ──────────────────────────────────────────────────────────
        "length" => match args.first() {
            Some(Value::Array(arr)) => Value::from(arr.len() as i64),
            Some(Value::Object(map)) => Value::from(map.len() as i64),
            Some(v) => Value::from(string_repr(v).chars().count() as i64),
            None => Value::Null,
        },
        "contains" => {
            let Some(s) = args.first().and_then(Value::as_str) else {
                return Value::Null;
            };
            let Some(p) = args.get(1).and_then(Value::as_str) else {
                return Value::Null;
            };
            Value::Bool(s.contains(p))
        }
        "upper" => map_text(args, |t| t.to_uppercase()),
        "lower" => map_text(args, |t| t.to_lowercase()),
        "trim" => map_text(args, |t| t.trim().to_string()),
        "capitalize" => map_text(args, |t| {
            let mut ch = t.chars();
            match ch.next() {
                Some(first) => first.to_uppercase().collect::<String>() + ch.as_str(),
                None => t,
            }
        }),
        "to_str" => match args.first() {
            Some(v) => Value::String(string_repr(v)),
            None => Value::Null,
        },
        // Символьные индексы, как в Dart: substr("меander", 1, 3) == "ean".
        "substr" => {
            let Some(t) = text_arg(args, 0) else {
                return Value::Null;
            };
            let chars: Vec<char> = t.chars().collect();
            let from = args.get(1).and_then(to_num_some).unwrap_or(0.0);
            let start = from.max(0.0) as usize;
            let take = match args.get(2).and_then(to_num_some) {
                Some(n) if n >= 0.0 => n as usize,
                Some(_) => return Value::Null,
                None => chars.len().saturating_sub(start),
            };
            let end = start.saturating_add(take).min(chars.len());
            if start > chars.len() {
                return Value::String(String::new());
            }
            Value::String(chars[start..end].iter().collect())
        }
        "index_of" => {
            let (Some(t), Some(p)) = (text_arg(args, 0), text_arg(args, 1)) else {
                return Value::Null;
            };
            Value::from(match t.find(p.as_str()) {
                Some(byte_i) => t[..byte_i].chars().count() as i64,
                None => -1i64,
            })
        }
        "replace" => {
            let (Some(t), Some(from)) = (text_arg(args, 0), text_arg(args, 1)) else {
                return Value::Null;
            };
            if from.is_empty() {
                return Value::String(t);
            }
            let to = text_arg(args, 2).unwrap_or_default();
            Value::String(t.replace(from.as_str(), to.as_str()))
        }
        "starts_with" | "ends_with" => {
            let (Some(t), Some(p)) = (text_arg(args, 0), text_arg(args, 1)) else {
                return Value::Null;
            };
            Value::Bool(if name == "starts_with" {
                t.starts_with(p.as_str())
            } else {
                t.ends_with(p.as_str())
            })
        }
        "repeat" => {
            let Some(t) = text_arg(args, 0) else {
                return Value::Null;
            };
            let n = args.get(1).and_then(to_num_some).unwrap_or(0.0);
            if n < 0.0 {
                return Value::Null;
            }
            // Потолок на 1000 повторов: формула не должна вешать плеер.
            Value::String(t.repeat((n as usize).min(1000)))
        }
        "pad_left" | "pad_right" => {
            let Some(t) = text_arg(args, 0) else {
                return Value::Null;
            };
            let width = args.get(1).and_then(to_num_some).unwrap_or(0.0).max(0.0) as usize;
            let fill = text_arg(args, 2).unwrap_or_else(|| " ".to_string());
            let fill_ch = fill.chars().next().unwrap_or(' ');
            let pad = width.saturating_sub(t.chars().count());
            if name == "pad_left" {
                Value::String(format!("{}{t}", fill_ch.to_string().repeat(pad)))
            } else {
                Value::String(format!("{t}{}", fill_ch.to_string().repeat(pad)))
            }
        }
        "split" => {
            let (Some(t), Some(sep)) = (text_arg(args, 0), text_arg(args, 1)) else {
                return Value::Null;
            };
            if sep.is_empty() {
                return Value::Null;
            }
            Value::Array(
                t.split(sep.as_str())
                    .map(|p| Value::String(p.to_string()))
                    .collect(),
            )
        }
        "join" => {
            let Some(first) = args.first() else {
                return Value::Null;
            };
            let sep = text_arg(args, 1).unwrap_or_else(|| ", ".to_string());
            match first {
                Value::Array(arr) => Value::String(
                    arr.iter()
                        .map(string_repr)
                        .collect::<Vec<_>>()
                        .join(sep.as_str()),
                ),
                Value::Object(map) => Value::String(
                    map.values()
                        .map(string_repr)
                        .collect::<Vec<_>>()
                        .join(sep.as_str()),
                ),
                other => Value::String(string_repr(other)),
            }
        }
        // Русские формы: plural(2, "строка", "строки", "строк").
        "plural" => {
            let Some(n) = args.first().and_then(to_num_some) else {
                return Value::Null;
            };
            let one = text_arg(args, 1).unwrap_or_default();
            let few = text_arg(args, 2).unwrap_or_else(|| one.clone());
            let many = text_arg(args, 3).unwrap_or_else(|| few.clone());
            let abs = n.abs() as i64;
            let hundred = abs % 100;
            let pick = if (11..=14).contains(&hundred) {
                many
            } else {
                match abs % 10 {
                    1 => one,
                    2..=4 => few,
                    _ => many,
                }
            };
            Value::String(pick)
        }
        // ── Логика ─────────────────────────────────────────────────────────
        // Ветки вычисляются обе: парсер не умеет ленивость. В выражении это
        // безопасно (бокковых эффектов нет), но делить на ноль внутри ветки
        // всё равно нельзя — там просто выйдет null.
        "if" => {
            let cond = args.first().map(to_bool).unwrap_or(false);
            match (cond, args.get(1), args.get(2)) {
                (true, Some(v), _) => v.clone(),
                (false, _, Some(v)) => v.clone(),
                (true, None, _) => Value::Bool(true),
                _ => Value::Null,
            }
        }
        // Первое значение, которое не null и не пустая строка: `coalesce(hero,
        // hero2, "безымянный")`. Слово «нет» считается значением, а не пустотой.
        "coalesce" => args
            .iter()
            .find(|v| match v {
                Value::Null => false,
                Value::String(s) => !s.trim().is_empty(),
                _ => true,
            })
            .cloned()
            .unwrap_or(Value::Null),
        "is_empty" => Value::Bool(match args.first() {
            None => true,
            Some(v) => match v {
                Value::Null => true,
                Value::String(s) => s.trim().is_empty(),
                Value::Array(arr) => arr.is_empty(),
                Value::Object(map) => map.is_empty(),
                _ => false,
            },
        }),
        "is_num" => Value::Bool(args.first().and_then(to_num).is_some()),
        "not" => Value::Bool(!args.first().map(to_bool).unwrap_or(false)),
        "bool" => Value::Bool(args.first().map(to_bool).unwrap_or(false)),
        "num" => match args.first().and_then(to_num) {
            Some(n) => json_of_f64(n),
            None => Value::Null,
        },
        // ── Переменные по имени ────────────────────────────────────────────
        "get_var" => match text_arg(args, 0) {
            Some(key) => strip_table_view(&c.variables.get(&key).cloned().unwrap_or(Value::Null)),
            None => Value::Null,
        },
        "has_var" => match text_arg(args, 0) {
            Some(key) => Value::Bool(c.variables.contains_key(&key)),
            None => Value::Null,
        },
        // ── Таблицы ────────────────────────────────────────────────────────
        // Номера строк везде с 1 — как в deep-lookup `{shop["цена"][1]}` и как
        // в сетке редактора. Обычные массивы остаются с 0.
        "table_rows" => with_table(args, c, |t| Value::from(table_row_list(t).len() as i64)),
        "table_columns" => with_table(args, c, |t| {
            Value::Array(table_column_list(t).into_iter().map(Value::from).collect())
        }),
        "table_column" => with_table(args, c, |t| match column_arg(t, args) {
            Some(values) => Value::Array(values),
            None => Value::Null,
        }),
        "table_cell" => with_table(args, c, |t| {
            let Some(col) = text_arg(args, 1) else {
                return Value::Null;
            };
            match row_index(args.get(2)).and_then(|i| table_row_list(t).get(i).cloned()) {
                Some(row) => row.get(&col).cloned().unwrap_or(Value::Null),
                None => Value::Null,
            }
        }),
        "table_row" => with_table(args, c, |t| {
            row_index(args.get(1))
                .and_then(|i| table_row_list(t).get(i).cloned())
                .unwrap_or(Value::Null)
        }),
        "table_sum" => table_fold(args, c, |nums| json_of_f64(nums.iter().sum())),
        "table_avg" => table_fold(args, c, |nums| {
            json_of_f64(nums.iter().sum::<f64>() / nums.len() as f64)
        }),
        "table_min" => table_fold(args, c, |nums| {
            json_of_f64(nums.iter().copied().fold(f64::INFINITY, f64::min))
        }),
        "table_max" => table_fold(args, c, |nums| {
            json_of_f64(nums.iter().copied().fold(f64::NEG_INFINITY, f64::max))
        }),
        // Номера подходящих строк ищутся по колонке: `table_where(shop, 'тип',
        // 'еда')` → [1, 3], а `length(...)` от него — сколько всего.
        "table_where" => with_table(args, c, |t| {
            match column_arg(t, args).map(|values| {
                let needle = args.get(2).cloned().unwrap_or(Value::Null);
                values
                    .iter()
                    .enumerate()
                    .filter(|(_, v)| values_equal(v, &needle))
                    .map(|(i, _)| Value::from(i as i64 + 1))
                    .collect()
            }) {
                Some(rows) => Value::Array(rows),
                None => Value::Null,
            }
        }),
        "table_find" => with_table(args, c, |t| match column_arg(t, args) {
            Some(values) => {
                let needle = args.get(2).cloned().unwrap_or(Value::Null);
                Value::from(
                    values
                        .iter()
                        .position(|v| values_equal(v, &needle))
                        .map_or(0, |i| i as i64 + 1),
                )
            }
            None => Value::Null,
        }),
        "table_has" => with_table(args, c, |t| match column_arg(t, args) {
            Some(values) => {
                let needle = args.get(2).cloned().unwrap_or(Value::Null);
                Value::Bool(values.iter().any(|v| values_equal(v, &needle)))
            }
            None => Value::Null,
        }),
        // Вывод таблицы в текст: `{table_text(лавка)}` в реплике NPC.
        "table_text" => with_table(args, c, |t| {
            Value::String(render_table(
                t,
                &text_arg(args, 1).unwrap_or_else(|| " ".into()),
            ))
        }),
        _ => Value::Null,
    }
}

/// Общий разбор: первый аргумент — таблица (значение или имя), иначе null.
fn with_table(args: &[Value], c: &EvalContext, ok: impl Fn(&Value) -> Value) -> Value {
    match table_value(args.first(), c) {
        Some(table) => ok(&table),
        None => Value::Null,
    }
}

fn table_value(arg: Option<&Value>, c: &EvalContext) -> Option<Value> {
    match arg? {
        Value::String(name) => match c.variables.get(name) {
            Some(table @ Value::Object(_)) => Some(table.clone()),
            _ => None,
        },
        table @ Value::Object(_) => Some(table.clone()),
        _ => None,
    }
}

/// Числа колонки, пропуская нечисловые ячейки («нет в наличии» ≠ 0).
fn table_fold(args: &[Value], c: &EvalContext, ok: impl Fn(Vec<f64>) -> Value) -> Value {
    with_table(args, c, |t| {
        let Some(values) = column_arg(t, args) else {
            return Value::Null;
        };
        let nums: Vec<f64> = values.iter().filter_map(to_num).collect();
        if nums.is_empty() {
            Value::Null
        } else {
            ok(nums)
        }
    })
}

/// Колонка из второго аргумента — её значения по строкам.
fn column_arg(table: &Value, args: &[Value]) -> Option<Vec<Value>> {
    text_arg(args, 1).and_then(|col| table_column_values(table, &col))
}

/// Номер строки из формулы → индекс массива (нумерация с 1, как в `{t[стлб][1]}`).
fn row_index(value: Option<&Value>) -> Option<usize> {
    let n = value.and_then(to_num)?;
    if n < 1.0 {
        return None;
    }
    Some(n as usize - 1)
}

fn table_row_list(table: &Value) -> Vec<Value> {
    table
        .get("__rows")
        .or_else(|| table.get("rows"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn table_column_list(table: &Value) -> Vec<String> {
    table
        .get("__columns")
        .or_else(|| table.get("columns"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn table_column_values(table: &Value, column: &str) -> Option<Vec<Value>> {
    if let Some(values) = table
        .get("__column_values")
        .and_then(|m| m.get(column))
        .and_then(Value::as_array)
    {
        return Some(values.clone());
    }
    let rows = table_row_list(table);
    if !rows.is_empty() {
        let columns = table_column_list(table);
        let known =
            columns.iter().any(|c| c == column) || rows.iter().any(|row| row.get(column).is_some());
        // Колонки с таким именем в сетке нет: лучше null, чем массив пустот,
        // на котором поиск по опечатке дал бы «нашлось».
        return known.then(|| {
            rows.iter()
                .map(|row| row.get(column).cloned().unwrap_or(Value::Null))
                .collect()
        });
    }
    // Сетки нет — но в `data` под этим ключом может лежать массив.
    table.get(column).and_then(Value::as_array).cloned()
}

/// Таблица как человек: строки через перевод строки, колонки через `sep`.
/// У key-value таблицы строк нет — тогда печатаем `ключ: значение`.
fn render_table(table: &Value, sep: &str) -> String {
    let rows = table_row_list(table);
    if !rows.is_empty() {
        let mut columns = table_column_list(table);
        if columns.is_empty() {
            columns = rows
                .iter()
                .flat_map(|r| r.as_object().into_iter().flatten().map(|(k, _)| k.clone()))
                .collect();
            columns.dedup();
        }
        return rows
            .iter()
            .map(|row| {
                columns
                    .iter()
                    // Пустая ячейка — пустое место, а не слово «null».
                    .map(|col| match row.get(col) {
                        Some(v) if v != &Value::Null => string_repr(v),
                        _ => String::new(),
                    })
                    .collect::<Vec<_>>()
                    .join(sep)
            })
            .collect::<Vec<_>>()
            .join("\n");
    }
    table
        .as_object()
        .map(|map| {
            map.iter()
                .filter(|(key, _)| !TABLE_VIEW_KEYS.contains(&key.as_str()))
                .map(|(key, value)| format!("{key}: {}", string_repr(value)))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Аргумент как текст: строки как есть, числа и булевы — через `string_repr`.
fn text_arg(args: &[Value], i: usize) -> Option<String> {
    args.get(i).map(string_repr)
}

fn map_text(args: &[Value], op: impl Fn(String) -> String) -> Value {
    match text_arg(args, 0) {
        Some(t) => Value::String(op(t)),
        None => Value::Null,
    }
}

/// Числа из аргументов, разворачивая вложенные массивы: `sum(1, scores)`.
fn flatten_nums(args: &[Value]) -> Vec<f64> {
    let mut out = Vec::new();
    for a in args {
        match a {
            Value::Array(arr) => out.extend(flatten_nums(arr)),
            Value::Object(map) => out.extend(map.values().filter_map(to_num)),
            other => out.extend(to_num(other)),
        }
    }
    out
}

fn fold_nums(args: &[Value], op: impl Fn(f64, f64) -> f64) -> Value {
    let nums = flatten_nums(args);
    if nums.is_empty() {
        return Value::Null;
    }
    json_of_f64(nums.into_iter().reduce(op).unwrap_or(0.0))
}

fn to_num_some(v: &Value) -> Option<f64> {
    to_num(v)
}

fn unary_num(args: &[Value], op: impl Fn(f64) -> f64) -> Value {
    match args.first().and_then(to_num_some) {
        Some(v) => json_of_f64(op(v)),
        None => Value::Null,
    }
}

fn two_num_op(args: &[Value], op: impl Fn(f64, f64) -> f64) -> Value {
    match (
        args.first().and_then(to_num_some),
        args.get(1).and_then(to_num_some),
    ) {
        (Some(a), Some(b)) => json_of_f64(op(a, b)),
        _ => Value::Null,
    }
}

/// Случайное число: целые границы → int в [min, max], иначе double.
fn random_range(min: f64, max: f64) -> Value {
    if min == max {
        return json_of_f64(min);
    }
    // Детерминированный LCG поверх системного времени — как Dart Random()
    // (без seed). Значения не тестируются на паритет.
    // Счётчик в seed нужен потому, что у браузерных часов точность миллисекунда:
    // без него два вызова в один мс давали бы одно и то же «случайное» число.
    static SEED_TICK: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let seed = (crate::time::unix_now_nanos() as u64
        + SEED_TICK.fetch_add(1, std::sync::atomic::Ordering::Relaxed))
        ^ 0x9E3779B97F4A7C15;
    let mut state = seed;
    let mut next = || {
        state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        state >> 33
    };
    let is_int_bounds = min.fract() == 0.0 && max.fract() == 0.0;
    if is_int_bounds {
        let lo = min as i64;
        let hi = max as i64;
        if hi <= lo {
            return Value::from(lo);
        }
        let range = (hi - lo + 1) as u64;
        Value::from(lo + (next() % range) as i64)
    } else {
        let frac = (next() % 1_000_000_000) as f64 / 1e9;
        json_of_f64(min + frac * (max - min))
    }
}

// ---------------------------------------------------------------------------
// Публичный API
// ---------------------------------------------------------------------------

/// Вычислитель выражений, порт `ExpressionEvaluatorService`.
#[derive(Debug, Clone, Default)]
pub struct ExpressionEvaluator;

impl ExpressionEvaluator {
    /// `_cleanNumericResult`: дробные значения, близкие к целым, → int.
    pub fn clean_numeric_result(value: Value) -> Value {
        if let Some(f) = value.as_f64() {
            if !f.is_finite() {
                return Value::from(f);
            }
            if f == 0.0 {
                return Value::from(0i64);
            }
            let mut cleaned = f;
            let rounded = (f * 1e10).round() / 1e10;
            if (f - rounded).abs() < 1e-11 {
                cleaned = rounded;
            }
            return json_of_f64(cleaned);
        }
        value
    }

    /// Полный вычислитель с подстановкой `{var}` и функциями.
    ///
    /// Паритет: `ExpressionEvaluatorService.evaluate(...)` из Dart.
    pub fn evaluate(&self, input_value: &Value, variables: &Map<String, Value>) -> Value {
        // Не-строки возвращаются очищенными.
        let Value::String(expression_string) = input_value else {
            let cleaned = Self::clean_numeric_result(input_value.clone());
            return cleaned;
        };

        let expression = expression_string.trim();
        if expression.is_empty() {
            return Value::Null;
        }
        let lower = expression.to_lowercase();
        if lower == "null" {
            return Value::Null;
        }
        if lower == "true" {
            return Value::Bool(true);
        }
        if lower == "false" {
            return Value::Bool(false);
        }
        if let Some(val) = variables.get(expression) {
            return Self::clean_numeric_result(val.clone());
        }

        let processed = substitute_placeholders(expression, variables);

        match evaluate_parsed(&processed, variables) {
            Some(v) => Self::clean_numeric_result(v),
            None => fallback_literal(&processed),
        }
    }
}

/// Парс+вычисление без подстановок (после замены `{var}`).
pub(crate) fn evaluate_parsed(expr: &str, variables: &Map<String, Value>) -> Option<Value> {
    let mut lexer = Lexer::new(expr);
    let tokens = lexer.tokenize().ok()?;
    let mut parser = Parser::new(&tokens);
    let ast = parser.parse_expr().ok()?;
    let ctx = EvalContext { variables };
    Some(eval_expr(&ast, &ctx))
}

fn fallback_literal(processed: &str) -> Value {
    if !contains_operators(processed) {
        let starts_quote = processed.starts_with('\'') || processed.starts_with('"');
        let starts_digit = processed.chars().next().is_some_and(|c| c.is_ascii_digit());
        if !starts_quote && !starts_digit {
            return Value::Null;
        }
        if (processed.starts_with('\'') && processed.ends_with('\''))
            || (processed.starts_with('"') && processed.ends_with('"'))
        {
            return Value::String(processed[1..processed.len() - 1].to_string());
        }
    }
    Value::Null
}

fn contains_operators(s: &str) -> bool {
    s.chars().any(|c| {
        matches!(
            c,
            '+' | '-' | '*' | '/' | '%' | '(' | ')' | '=' | '<' | '>' | '!' | '&' | '|'
        )
    })
}

/// Подстановка `{var}` из контекста (как Dart `replaceAllMapped`).
pub fn substitute_placeholders(expr: &str, variables: &Map<String, Value>) -> String {
    let mut out = String::with_capacity(expr.len());
    let chars: Vec<char> = expr.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '{' {
            let mut j = i + 1;
            let mut depth = 1;
            while j < chars.len() {
                if chars[j] == '{' {
                    depth += 1;
                } else if chars[j] == '}' {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                j += 1;
            }
            if j < chars.len() {
                let var_name: String = chars[i + 1..j].iter().collect();
                let var_name = var_name.trim();
                let replacement = match variables.get(var_name) {
                    None => "null".to_string(),
                    Some(Value::Number(n)) => {
                        if let Some(i) = n.as_i64() {
                            i.to_string()
                        } else if let Some(f) = n.as_f64() {
                            if f.is_finite()
                                && f.fract() == 0.0
                                && f >= (i64::MIN as f64)
                                && f <= (i64::MAX as f64)
                            {
                                (f as i64).to_string()
                            } else {
                                f.to_string()
                            }
                        } else {
                            n.to_string()
                        }
                    }
                    Some(Value::Bool(b)) => b.to_string(),
                    Some(Value::String(s)) => {
                        let escaped = s.replace('\'', "\\'");
                        format!("'{escaped}'")
                    }
                    // Объекты/массивы — null (паритет: Dart toString() давал бы
                    // строку '{...}', но парсер не умеет; безопаснее null).
                    Some(_) => "null".to_string(),
                };
                out.push_str(&replacement);
                i = j + 1;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

// ---------------------------------------------------------------------------
// Сравнение значений (паритет с `_valuesEqual` / `_compareValues`)
// ---------------------------------------------------------------------------

/// `_valuesEqual`: null-семантика, числовое сравнение, строковые варианты,
/// mojibake-репаир.
pub fn values_equal(left: &Value, right: &Value) -> bool {
    if left == &Value::Null && right == &Value::Null {
        return true;
    }
    if left == &Value::Null || right == &Value::Null {
        let non_null = if left != &Value::Null { left } else { right };
        if let Value::String(s) = non_null {
            let normalized = s.trim();
            if normalized.is_empty() || is_nothing_like(normalized) {
                return true;
            }
        }
        return false;
    }
    if let (Some(a), Some(b)) = (to_num(left), to_num(right)) {
        return a == b;
    }
    // Паритет с эталоном: мягкая коэрция bool↔string. Конфиг-переменные
    // приходят строками ("false"/"true"), а в скриптах сравниваются с
    // логическими литералами: `{первый вход}==false` должно срабатывать.
    if matches!(left, Value::Bool(_)) || matches!(right, Value::Bool(_)) {
        return to_bool(left) == to_bool(right);
    }
    let ls = left.to_string();
    let rs = right.to_string();
    let left_variants = string_variants(&ls);
    let right_variants = string_variants(&rs);
    right_variants.iter().any(|v| left_variants.contains(v))
}

pub fn is_nothing_like(s: &str) -> bool {
    let normalized = s.trim().to_lowercase();
    matches!(
        normalized.as_str(),
        ""
            | "ничего"
            | "nothing"
            | "none"
            | "null"
            | "пусто"
            | "нет"
            // mojibake-варианты из легаси-сейвов
            | "рќрёс‡рµрірѕ"
            | "сђсњсђс‘сђвђўсђвµсђс–сђс•"
            | "рѕрёс‡рµрірѕ"
    )
}

fn string_variants(source: &str) -> Vec<String> {
    let trimmed = source.trim();
    if trimmed.is_empty() {
        return vec![String::new()];
    }
    let mut variants = vec![trimmed.to_string(), trimmed.to_lowercase()];
    if let Some(repaired) = try_repair_mojibake(trimmed)
        && !repaired.is_empty()
    {
        variants.push(repaired.clone());
        variants.push(repaired.to_lowercase());
    }
    variants
}

/// Попытка починить mojibake: UTF-8 текст, декодированный как latin1.
pub fn try_repair_mojibake(input: &str) -> Option<String> {
    if !input.contains('Р') && !input.contains('С') {
        return None;
    }
    let bytes: Vec<u8> = input.chars().map(|c| c as u32 as u8).collect();
    let repaired = String::from_utf8_lossy(&bytes).to_string();
    let trimmed = repaired.trim().to_string();
    if trimmed.is_empty() || trimmed == input {
        None
    } else {
        Some(trimmed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn math_parses_and_evaluates() {
        let vars = Map::new();
        let ev = ExpressionEvaluator;
        assert_eq!(
            ev.evaluate(&Value::String("2 + 3 * 4".into()), &vars),
            json_of_f64(14.0)
        );
        assert_eq!(
            ev.evaluate(&Value::String("(2 + 3) * 4".into()), &vars),
            json_of_f64(20.0)
        );
        assert_eq!(
            ev.evaluate(&Value::String("10 / 4".into()), &vars),
            Value::from(2.5)
        );
        assert_eq!(
            ev.evaluate(&Value::String("2 > 1".into()), &vars),
            Value::Bool(true)
        );
    }

    /// Прогон без подстановки `{var}`: так в контекст попадают массивы и
    /// объекты, которые плейсхолдер всегда превращает в null.
    fn eval(expr: &str) -> Value {
        let vars = vars_with();
        evaluate_parsed(expr, &vars).unwrap_or(Value::Null)
    }

    #[test]
    fn deep_paren_nesting_does_not_overflow_stack() {
        // Без потолка парсер и eval_expr идут друг в друга тысячами кадров:
        // тест не падает на ассерте, а кладёт процесс переполнением стека.
        let ok = "(".repeat(50) + "7" + &")".repeat(50);
        assert_eq!(eval(&ok), serde_json::json!(7));

        let too_deep = "(".repeat(5000) + "7" + &")".repeat(5000);
        assert_eq!(
            eval(&too_deep),
            Value::Null,
            "слишком глубокая формула должна остаться ошибкой парсера"
        );

        // Аргументы функций идут через тот же parse_expr — проверка и на них.
        let nested_calls = "max(1,".repeat(2000) + "1" + &")".repeat(2000);
        assert_eq!(eval(&nested_calls), Value::Null);
    }

    fn vars_with() -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("name".into(), serde_json::json!("Аня"));
        m.insert("scores".into(), serde_json::json!([3, 7, 10]));
        m.insert("empty".into(), serde_json::json!(""));
        m.insert("shop".into(), shop_table_view());
        m.insert("записки".into(), kv_table_view());
        m
    }

    /// Таблица без сетки — только key-value, как её завели бы скрипты.
    fn kv_table_view() -> Value {
        use crate::models::quest_table::QuestTable;
        QuestTable::new(
            "записки".into(),
            vec![],
            vec![],
            serde_json::json!({"заметка": "нет"})
                .as_object()
                .cloned()
                .unwrap(),
        )
        .formula_view()
    }

    /// Настоящая таблица квеста, каких её видит исполнитель: сетка + `data`.
    fn shop_table_view() -> Value {
        use crate::models::quest_table::QuestTable;
        let table = QuestTable::new(
            "shop".into(),
            ["товар", "цена", "тип"]
                .iter()
                .map(|c| c.to_string())
                .collect(),
            vec![
                serde_json::json!({"товар": "хлеб", "цена": 30, "тип": "еда"}),
                serde_json::json!({"товар": "ключ", "цена": 5, "тип": "ключ"}),
                serde_json::json!({"товар": "молоко", "цена": 40, "тип": "еда"}),
            ]
            .into_iter()
            .map(|r| r.as_object().cloned().unwrap())
            .collect(),
            serde_json::json!({"открыто": true})
                .as_object()
                .cloned()
                .unwrap(),
        );
        table.formula_view()
    }

    #[test]
    fn math_functions_new() {
        assert_eq!(eval("mod(7, 3)"), json_of_f64(1.0));
        // Отрицательное число: остаток всегда в сторону делителя.
        assert_eq!(eval("mod(-1, 3)"), json_of_f64(2.0));
        assert_eq!(eval("mod(7, 0)"), Value::Null);
        assert_eq!(eval("trunc(-2.7)"), json_of_f64(-2.0));
        assert_eq!(eval("sign(-4)"), json_of_f64(-1.0));
        assert_eq!(eval("clamp(11, 0, 10)"), json_of_f64(10.0));
        assert_eq!(eval("between(5, 10, 1)"), Value::Bool(true));
        assert_eq!(eval("log(100)"), json_of_f64(2.0));
        assert_eq!(eval("log(8, 2)"), json_of_f64(3.0));
        assert_eq!(eval("log(0)"), Value::Null);
        // min/max/sum теперь вариативны и раскрывают массивы.
        assert_eq!(eval("min(4, 2, 9)"), json_of_f64(2.0));
        assert_eq!(eval("sum(scores)"), json_of_f64(20.0));
        assert_eq!(eval("sum(scores, 1)"), json_of_f64(21.0));
        assert_eq!(eval("avg(scores)"), json_of_f64(20.0 / 3.0));
        assert_eq!(eval("max(empty, 3)"), json_of_f64(3.0));
    }

    #[test]
    fn text_functions_new() {
        assert_eq!(eval("upper(name)"), serde_json::json!("АНЯ"));
        assert_eq!(eval("lower('ПРИВЕТ')"), serde_json::json!("привет"));
        assert_eq!(eval("trim('  а  ')"), serde_json::json!("а"));
        assert_eq!(eval("capitalize('алекс')"), serde_json::json!("Алекс"));
        assert_eq!(eval("length(scores)"), json_of_f64(3.0));
        assert_eq!(eval("length(name)"), json_of_f64(3.0));
        // Индексы символьные, не байтовые: кириллица считается по буквам.
        assert_eq!(eval("substr('посылка', 1, 3)"), serde_json::json!("осы"));
        assert_eq!(eval("substr('посылка', 5)"), serde_json::json!("ка"));
        assert_eq!(eval("substr('посылка', 99)"), serde_json::json!(""));
        assert_eq!(eval("index_of('посылка', 'сыл')"), json_of_f64(2.0));
        assert_eq!(eval("index_of('посылка', 'нет')"), json_of_f64(-1.0));
        assert_eq!(
            eval("replace('a-b-c', '-', '+')"),
            serde_json::json!("a+b+c")
        );
        assert_eq!(eval("starts_with(name, 'А')"), Value::Bool(true));
        assert_eq!(eval("ends_with(name, 'А')"), Value::Bool(false));
        assert_eq!(eval("repeat('а', 3)"), serde_json::json!("ааа"));
        assert_eq!(eval("pad_left('7', 3, '0')"), serde_json::json!("007"));
        assert_eq!(eval("pad_right('7', 3)"), serde_json::json!("7  "));
        assert_eq!(eval("join(scores, ' / ')"), serde_json::json!("3 / 7 / 10"));
        assert_eq!(eval("split('а,б', ',')[1]"), serde_json::json!("б"));
        assert_eq!(eval("to_str(12)"), serde_json::json!("12"));
    }

    #[test]
    fn plural_ru_forms() {
        let pl = |n: i64| eval(&format!("plural({n}, 'строка', 'строки', 'строк')"));
        assert_eq!(pl(1), serde_json::json!("строка"));
        assert_eq!(pl(2), serde_json::json!("строки"));
        assert_eq!(pl(5), serde_json::json!("строк"));
        assert_eq!(pl(11), serde_json::json!("строк"));
        assert_eq!(pl(21), serde_json::json!("строка"));
        assert_eq!(pl(104), serde_json::json!("строки"));
    }

    #[test]
    fn logic_and_variable_functions() {
        assert_eq!(eval("if(1 > 2, 'да', 'нет')"), serde_json::json!("нет"));
        assert_eq!(eval("if(name, 'есть', 'пусто')"), serde_json::json!("есть"));
        assert_eq!(eval("if(empty, 'есть', 'нет')"), serde_json::json!("нет"));
        assert_eq!(eval("coalesce(empty, name)"), serde_json::json!("Аня"));
        assert_eq!(eval("is_empty(empty)"), Value::Bool(true));
        assert_eq!(eval("is_empty(scores)"), Value::Bool(false));
        assert_eq!(eval("is_num('12,5')"), Value::Bool(false));
        assert_eq!(eval("is_num('12.5')"), Value::Bool(true));
        assert_eq!(eval("not(0)"), Value::Bool(true));
        assert_eq!(eval("bool('нет')"), Value::Bool(true));
        assert_eq!(eval("num('42')"), json_of_f64(42.0));
        // Динамическое имя переменной — то, для чего нужны get_var/has_var.
        assert_eq!(eval("get_var('name')"), serde_json::json!("Аня"));
        assert_eq!(eval("get_var('нет такой')"), Value::Null);
        assert_eq!(eval("has_var('scores')"), Value::Bool(true));
        assert_eq!(eval("length(get_var('scores'))"), json_of_f64(3.0));
        assert_eq!(eval("get_var('scores')[2]"), json_of_f64(10.0));
    }

    #[test]
    fn unknown_and_broken_calls_are_null_not_panic() {
        assert_eq!(eval("нет_такой_функции(1)"), Value::Null);
        assert_eq!(eval("upper()"), Value::Null);
        assert_eq!(eval("substr('abc', 1, -2)"), Value::Null);
        assert_eq!(eval("round(1.5"), Value::Null);
    }

    /// Ключы `data` читаются из формул напрямую — это единственный способ
    /// достать из формулы то, что пишет блок «Данные». Фиксируем синтаксис
    /// тестом, чтобы подсказки в редакторе не разошлись с движком.
    #[test]
    fn data_keys_are_readable_in_formulas() {
        assert_eq!(eval("shop['открыто']"), serde_json::json!(true));
        assert_eq!(eval("shop[\"открыто\"]"), serde_json::json!(true));
        // Ключа нет — null, а не выдаённая строка «null».
        assert_eq!(eval("shop['нет_такого_ключа']"), Value::Null);
        // Сетка лежит под служебными ключами той же projection.
        assert_eq!(eval("length(shop['__columns'])"), Value::from(3));
        assert_eq!(
            eval("shop['__rows'][0]['товар']"),
            serde_json::json!("хлеб")
        );
    }

    /// Движок формул знает у таблицы только ключи хранилища: `shop["цена"]` —
    /// это запрос ключа `цена` в `data`, а не колонка сетки. Колонки видит
    /// только подстановка `{…}` (см. executor::tests). Отсюда и тихий облом:
    /// `shop["цена"][1] + 5` → строка «5» вместо ячейки.
    #[test]
    fn engine_reads_data_keys_not_grid_columns() {
        assert_eq!(eval("shop[\"цена\"][1]"), Value::Null);
        assert_eq!(
            eval("shop[\"цена\"][1] + 5"),
            Value::String("5".into()),
            "ссылка внутри формулы не должна молча терять ячейку"
        );
        assert_eq!(
            eval("table_cell(shop, 'цена', 1) + 5"),
            json_of_f64(35.0),
            "формульный вариант той же ячейки"
        );
    }

    #[test]
    fn table_functions_read_the_grid() {
        assert_eq!(eval("table_rows(shop)"), Value::from(3));
        assert_eq!(
            eval("table_columns(shop)"),
            serde_json::json!(["товар", "цена", "тип"])
        );
        assert_eq!(
            eval("table_column(shop, 'цена')"),
            serde_json::json!([30, 5, 40])
        );
        // Строки с 1 — как в `{shop["цена"][1]}` и как в сетке редактора.
        assert_eq!(
            eval("table_cell(shop, 'товар', 1)"),
            serde_json::json!("хлеб")
        );
        assert_eq!(eval("table_cell(shop, 'товар', 0)"), Value::Null);
        assert_eq!(
            eval("table_row(shop, 2)['товар']"),
            serde_json::json!("ключ")
        );
        // Имя таблицы строкой работает без резолва переменной.
        assert_eq!(eval("table_sum('shop', 'цена')"), Value::from(75));
        // Таблица внутри арифметики — ради этого всё и затевалось.
        assert_eq!(
            eval("table_max(shop, 'цена') - table_min(shop, 'цена')"),
            Value::from(35)
        );
        assert_eq!(eval("table_avg(shop, 'цена')"), Value::from(25));
    }

    #[test]
    fn table_functions_search_and_tolerate_garbage() {
        assert_eq!(eval("table_find(shop, 'тип', 'ключ')"), Value::from(2));
        assert_eq!(eval("table_find(shop, 'тип', 'нет')"), Value::from(0));
        // `values_equal`: строка из ячейки равна числу из формулы.
        assert_eq!(eval("table_find(shop, 'цена', '30')"), Value::from(1));
        assert_eq!(
            eval("table_where(shop, 'тип', 'еда')"),
            serde_json::json!([1, 3])
        );
        assert_eq!(
            eval("length(table_where(shop, 'тип', 'еда'))"),
            Value::from(2)
        );
        assert_eq!(
            eval("table_has(shop, 'товар', 'молоко')"),
            Value::from(true)
        );
        assert_eq!(
            eval("table_has(shop, 'товар', 'кефир')"),
            Value::from(false)
        );
        // Мусор на входе — null на выходе, без паники.
        assert_eq!(eval("table_rows(5)"), Value::Null);
        assert_eq!(eval("table_sum(shop, 'нет_такой_колонки')"), Value::Null);
        assert_eq!(
            eval("table_column('нет_такой_таблицы', 'цена')"),
            Value::Null
        );
        // Опечатка в имени колонки не должна превращаться в «нашлось»: пустые
        // ячейки равны друг другу, поэтому неизвестная колонка даёт null,
        // а не ноль/false — их формула различит.
        assert_eq!(eval("table_find(shop, 'ценна', '30')"), Value::Null);
        assert_eq!(eval("table_has(shop, 'товарр', 'хлеб')"), Value::Null);
        assert_eq!(eval("table_where(shop, 'ценна', '30')"), Value::Null);
        assert_eq!(eval("table_column(shop, 'ценна')"), Value::Null);
        // А вот известная колонка без совпадения — пустой поиск, не null.
        assert_eq!(
            eval("table_where(shop, 'тип', 'нет')"),
            serde_json::json!([])
        );
    }

    #[test]
    fn table_renders_as_text() {
        assert_eq!(
            eval("table_text(shop)"),
            serde_json::json!("хлеб 30 еда\nключ 5 ключ\nмолоко 40 еда")
        );
        assert_eq!(
            eval("table_text(shop, ' · ')"),
            serde_json::json!("хлеб · 30 · еда\nключ · 5 · ключ\nмолоко · 40 · еда")
        );
        // У key-value таблицы строк нет — печатаем её как список заметок.
        assert_eq!(string_repr(&eval("table_text(записки)")), "заметка: нет");
    }

    #[test]
    fn whole_table_leaves_the_formula_as_plain_data() {
        // Служебные ключи projection не должны утезать в переменную игрока:
        // `data` тут ровно один ключ.
        assert_eq!(eval("length(get_var('shop'))"), Value::from(1));
        assert_eq!(eval("get_var('shop')['открыто']"), Value::from(true));
    }
}
