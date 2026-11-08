//! JS-compatible JSON conversion for PostgreSQL rows.
//!
//! The Flutter clients were written against `node-postgres` + `res.json()`, so
//! the wire format has three quirks that a plain `sqlx` mapping would break:
//!
//! * `BIGINT`/`NUMERIC` arrive as **strings** (`pg` does not lose precision);
//! * `TIMESTAMPTZ` becomes `Date.toISOString()` — always UTC, always exactly
//!   three fractional digits and a `Z` suffix;
//! * `NaN`/`Infinity` cannot appear in JSON and become `null`.
//!
//! `pg_row_to_json` reproduces that mapping, which lets routes that returned
//! `res.json(rows)` stay byte-compatible.

use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, SecondsFormat, TimeZone, Utc};
use serde_json::{Map, Value, json};
use sqlx::postgres::PgRow;
use sqlx::{Column, Row, TypeInfo, ValueRef};
use uuid::Uuid;

/// `Date.prototype.toISOString()` for a UTC instant.
pub fn ts(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339_opts(SecondsFormat::Millis, true)
}

pub fn opt_ts(dt: Option<DateTime<Utc>>) -> Option<String> {
    dt.map(ts)
}

/// JS `Date` for a `timestamp without time zone` (pg treats it as local time;
/// the production server runs in UTC).
pub fn naive_ts(dt: NaiveDateTime) -> String {
    ts(DateTime::<Utc>::from_naive_utc_and_offset(dt, Utc))
}

/// `node-postgres` parses `DATE` with `new Date(y, m - 1, d)`, i.e. local
/// midnight, and `Date#toISOString` then shifts it to UTC. A `DATE` column is
/// therefore not midnight UTC unless the process runs in UTC.
pub fn date_ts(d: NaiveDate) -> String {
    let Some(naive) = d.and_hms_opt(0, 0, 0) else {
        return ts(Utc::now());
    };
    match Local.from_local_datetime(&naive).single() {
        Some(local) => ts(local.with_timezone(&Utc)),
        // Ambiguous or nonexistent local midnight (DST): fall back to UTC.
        None => ts(DateTime::<Utc>::from_naive_utc_and_offset(naive, Utc)),
    }
}

/// JS numbers have no `4.0`: whole averages serialise as `4`.
pub fn js_number(value: f64) -> Value {
    if value.is_finite() && value.fract() == 0.0 {
        json!(value as i64)
    } else {
        json!(value)
    }
}

fn finite(v: f64) -> Value {
    if v.is_finite() { json!(v) } else { Value::Null }
}

/// Converts one column of a row. Unknown types fall back to text rather than
/// failing the whole response, mirroring `pg`'s "something is better than 500".
pub fn column_json(row: &PgRow, idx: usize) -> Value {
    let col = &row.columns()[idx];
    // sqlx reports array types as `TEXT[]` while the match arms use the
    // PostgreSQL internal spelling (`_TEXT`); normalise to the latter.
    let mut type_name = col.type_info().name().to_ascii_uppercase();
    if let Some(base) = type_name.strip_suffix("[]") {
        type_name = format!("_{base}");
    }

    macro_rules! opt_get {
        ($t:ty) => {
            row.try_get::<Option<$t>, _>(idx).ok().flatten()
        };
    }

    match type_name.as_str() {
        "BOOL" => opt_get!(bool).map(Value::Bool).unwrap_or(Value::Null),
        "INT2" => opt_get!(i16).map(|v| json!(v)).unwrap_or(Value::Null),
        "INT4" => opt_get!(i32).map(|v| json!(v)).unwrap_or(Value::Null),
        // node-postgres returns int8 as a string.
        "INT8" => opt_get!(i64)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or(Value::Null),
        "FLOAT4" => opt_get!(f32)
            .map(|v| finite(v as f64))
            .unwrap_or(Value::Null),
        "FLOAT8" => opt_get!(f64).map(finite).unwrap_or(Value::Null),
        // numeric/decimal: string, so 4.50 stays 4.50.
        "NUMERIC" => opt_get!(sqlx::types::BigDecimal)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or(Value::Null),
        "UUID" => opt_get!(Uuid)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or(Value::Null),
        "TIMESTAMPTZ" => opt_get!(DateTime<Utc>)
            .map(|v| Value::String(ts(v)))
            .unwrap_or(Value::Null),
        "TIMESTAMP" => opt_get!(NaiveDateTime)
            .map(|v| Value::String(naive_ts(v)))
            .unwrap_or(Value::Null),
        "DATE" => opt_get!(NaiveDate)
            .map(|v| Value::String(date_ts(v)))
            .unwrap_or(Value::Null),
        "JSON" | "JSONB" => opt_get!(Value).unwrap_or(Value::Null),
        "TEXT" | "VARCHAR" | "BPCHAR" | "NAME" | "CITEXT" | "OID" | "CHAR" => {
            opt_get!(String).map(Value::String).unwrap_or(Value::Null)
        }
        "_BOOL" => opt_get!(Vec<bool>).map(|v| json!(v)).unwrap_or(Value::Null),
        "_INT2" => opt_get!(Vec<i16>).map(|v| json!(v)).unwrap_or(Value::Null),
        "_INT4" => opt_get!(Vec<i32>).map(|v| json!(v)).unwrap_or(Value::Null),
        "_INT8" => opt_get!(Vec<i64>)
            .map(|v| {
                Value::Array(
                    v.into_iter()
                        .map(|x| Value::String(x.to_string()))
                        .collect(),
                )
            })
            .unwrap_or(Value::Null),
        "_NUMERIC" => opt_get!(Vec<sqlx::types::BigDecimal>)
            .map(|v| {
                Value::Array(
                    v.into_iter()
                        .map(|x| Value::String(x.to_string()))
                        .collect(),
                )
            })
            .unwrap_or(Value::Null),
        "_FLOAT4" => opt_get!(Vec<f32>).map(|v| json!(v)).unwrap_or(Value::Null),
        "_FLOAT8" => opt_get!(Vec<f64>)
            .map(|v| Value::Array(v.into_iter().map(finite).collect()))
            .unwrap_or(Value::Null),
        "_TEXT" | "_VARCHAR" | "_BPCHAR" | "_NAME" => opt_get!(Vec<String>)
            .map(|v| json!(v))
            .unwrap_or(Value::Null),
        "_UUID" => opt_get!(Vec<Uuid>).map(|v| json!(v)).unwrap_or(Value::Null),
        "_TIMESTAMPTZ" => opt_get!(Vec<DateTime<Utc>>)
            .map(|v| Value::Array(v.into_iter().map(|d| Value::String(ts(d))).collect()))
            .unwrap_or(Value::Null),
        "_TIMESTAMP" => opt_get!(Vec<NaiveDateTime>)
            .map(|v| Value::Array(v.into_iter().map(|d| Value::String(naive_ts(d))).collect()))
            .unwrap_or(Value::Null),
        "_JSON" | "_JSONB" => opt_get!(Vec<Value>)
            .map(Value::Array)
            .unwrap_or(Value::Null),
        "BYTEA" => {
            // node-postgres renders a Buffer as {"type":"Buffer","data":[...]}.
            opt_get!(Vec<u8>)
                .map(|v| json!({"type": "Buffer", "data": v}))
                .unwrap_or(Value::Null)
        }
        "VOID" => Value::Null,
        _ => {
            // Last resort: ask Postgres for text when the Rust decoder has no
            // mapping for the type. Enums and domains are decoded as raw text
            // bytes: asking for `String` would fail the TEXT compatibility
            // check, but the wire format is still JSON text.
            match row.try_get_raw(idx) {
                Ok(raw) if raw.is_null() => Value::Null,
                Ok(raw) => match raw.as_str() {
                    Ok(text) => Value::String(text.to_owned()),
                    Err(_) => Value::String(String::new()),
                },
                Err(_) => Value::Null,
            }
        }
    }
}

/// Reads a column as text regardless of its SQL type. Enums (`quest_status`,
/// `report_status`, …) are not TEXT-compatible for sqlx but `pg` delivers them
/// as plain strings, so route-level checks and responses go through this.
pub fn text_col(row: &PgRow, name: &str) -> Option<String> {
    let idx = row.columns().iter().position(|col| col.name() == name)?;
    let raw = row.try_get_raw(idx).ok()?;
    raw.as_str().ok().map(str::to_owned)
}

pub fn pg_row_to_json(row: &PgRow) -> Value {
    let mut map = Map::with_capacity(row.columns().len());
    for (idx, col) in row.columns().iter().enumerate() {
        map.insert(col.name().to_string(), column_json(row, idx));
    }
    Value::Object(map)
}

pub fn rows_to_json(rows: &[PgRow]) -> Value {
    Value::Array(rows.iter().map(pg_row_to_json).collect())
}

/// `Number(req.query.x)`: numeric strings parse, everything else is `None`.
pub fn parse_num(raw: Option<&str>) -> Option<f64> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    raw.parse::<f64>().ok()
}

/// `parseInt(raw, 10)` semantics for query params/body fields.
pub fn parse_int(raw: Option<&str>) -> Option<i64> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    // parseInt accepts a leading integer prefix ("12abc" -> 12).
    let mut end = 0;
    let bytes = raw.as_bytes();
    if !bytes.is_empty() && (bytes[0] == b'-' || bytes[0] == b'+') {
        end = 1;
    }
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }
    if end == 0 || (end == 1 && !bytes[0].is_ascii_digit()) {
        return None;
    }
    raw[..end].parse().ok()
}

pub fn parse_uuid(raw: Option<&str>) -> Option<Uuid> {
    Uuid::parse_str(raw?.trim()).ok()
}

pub fn uuid_str(raw: Option<&str>) -> Option<String> {
    parse_uuid(raw).map(|u| u.to_string())
}

/// JS truthiness used by the existing query-parameter parsing (`is_demo`,
/// `pinned`, …) where the original code wrote `!!value` or compared to "true".
pub fn truthy(raw: Option<&str>) -> bool {
    matches!(raw, Some("true") | Some("1"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn js_number_serialises_whole_floats_as_integers() {
        assert_eq!(js_number(5.0).to_string(), "5");
        assert_eq!(js_number(0.0).to_string(), "0");
        assert_eq!(js_number(4.5).to_string(), "4.5");
        assert_eq!(js_number(f64::NAN), Value::Null);
    }

    #[test]
    fn date_ts_is_local_midnight_like_node_postgres() {
        let day = NaiveDate::from_ymd_opt(2026, 11, 8).unwrap();
        let stamp = date_ts(day);
        assert!(stamp.ends_with('Z'), "{stamp}");
        let back = DateTime::parse_from_rfc3339(&stamp)
            .unwrap()
            .with_timezone(&Local);
        assert_eq!(back.date_naive(), day);
        assert_eq!(
            back.time(),
            chrono::NaiveTime::from_hms_opt(0, 0, 0).unwrap()
        );
    }
}
