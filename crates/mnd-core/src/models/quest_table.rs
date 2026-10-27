//! Модель таблицы квеста.

use serde_json::{Map, Value, json};

/// Таблица квеста: классические строки + key-value хранилище для скриптов.
///
/// Паритет: `packages/mnd_core/lib/models/quest_table.dart`.
#[derive(Debug, Clone, PartialEq)]
pub struct QuestTable {
    pub name: String,
    pub columns: Vec<String>,
    /// Index-based доступ к строкам.
    pub rows: Vec<Map<String, Value>>,
    /// Key-value хранилище, видимое скриптам (`ScriptTable.data`).
    pub data: Map<String, Value>,
}

impl QuestTable {
    pub fn new(
        name: String,
        columns: Vec<String>,
        rows: Vec<Map<String, Value>>,
        data: Map<String, Value>,
    ) -> Self {
        Self {
            name,
            columns,
            rows,
            data,
        }
    }

    pub fn from_json(json: &Value) -> Self {
        let obj = json.as_object().cloned().unwrap_or_default();
        let name = obj
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let columns = obj
            .get("columns")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let rows = obj
            .get("rows")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|r| r.as_object().cloned())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let data = obj
            .get("data")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        Self::new(name, columns, rows, data)
    }

    pub fn to_json(&self) -> Value {
        json!({
            "name": self.name,
            "columns": self.columns,
            "rows": self.rows,
            "data": self.data,
        })
    }

    /// Ячейка сетки может хранить вложенную таблицу — объект той же формы,
    /// что и [`QuestTable::to_json`]. Формулы видят её как обычную таблицу,
    /// поэтому никакого отдельного представления не нужно.
    pub fn is_nested_value(value: &Value) -> bool {
        value.get("columns").is_some_and(Value::is_array)
            && value.get("rows").is_some_and(Value::is_array)
    }

    pub fn from_cell_value(value: &Value) -> Option<Self> {
        Self::is_nested_value(value).then(|| Self::from_json(value))
    }

    /// Значение для записи в ячейку родительской таблицы.
    pub fn to_nested_value(&self) -> Value {
        self.to_json()
    }

    /// Добавить пустую строку со всеми столбцами (`''`).
    pub fn add_empty_row(&mut self) {
        let mut row = Map::new();
        for col in &self.columns {
            row.insert(col.clone(), Value::String(String::new()));
        }
        self.rows.push(row);
    }

    /// Обновить набор столбцов: лишние дропаются, новые инициализируются `''`.
    pub fn update_columns(&mut self, new_columns: &[String]) {
        for row in &mut self.rows {
            row.retain(|key, _| new_columns.contains(key));
        }
        for col in new_columns {
            for row in &mut self.rows {
                row.entry(col.clone())
                    .or_insert_with(|| Value::String(String::new()));
            }
        }
        self.columns = new_columns.to_vec();
    }

    /// Таблица в том виде, в котором её видят формулы: key-value данные плюс
    /// сетка под служебными ключами. Сам по себе `data` строк не содержит,
    /// поэтому без этой projection функции вида `table_column(shop, "цена")`
    /// видели бы только ручной key-value.
    pub fn formula_view(&self) -> Value {
        let columns: Vec<Value> = self
            .columns
            .iter()
            .map(|c| Value::String(c.clone()))
            .collect();
        let mut column_values = Map::new();
        for column in &self.columns {
            column_values.insert(
                column.clone(),
                Value::Array(
                    self.rows
                        .iter()
                        .map(|r| r.get(column).cloned().unwrap_or(Value::Null))
                        .collect(),
                ),
            );
        }
        let mut view = self.data.clone();
        view.insert("__table".into(), Value::Bool(true));
        view.insert("__columns".into(), Value::Array(columns));
        view.insert(
            "__rows".into(),
            Value::Array(self.rows.iter().map(|r| Value::Object(r.clone())).collect()),
        );
        view.insert("__column_values".into(), Value::Object(column_values));
        Value::Object(view)
    }
}

/// Ключи, которые в `formula_view` добавлены поверх `data`.
pub const TABLE_VIEW_KEYS: [&str; 4] = ["__table", "__columns", "__rows", "__column_values"];

/// Значение — табличная projection, а не обычные данные.
pub fn is_table_view(value: &Value) -> bool {
    value.get("__table").and_then(Value::as_bool) == Some(true)
}

/// Снять projection перед тем, как значение уйдёт наружу (в переменную, в
/// текст): человек должен получить ровно то же, что давал `data`.
pub fn strip_table_view(value: &Value) -> Value {
    match value {
        Value::Object(map) if is_table_view(value) => Value::Object(
            map.iter()
                .filter(|(key, _)| !TABLE_VIEW_KEYS.contains(&key.as_str()))
                .map(|(key, val)| (key.clone(), val.clone()))
                .collect(),
        ),
        other => other.clone(),
    }
}

impl From<&QuestTable> for Value {
    fn from(t: &QuestTable) -> Self {
        t.to_json()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nested() -> QuestTable {
        QuestTable::new(
            "подтаблица".into(),
            vec!["товар".into(), "цена".into()],
            vec![serde_json::json!({"товар": "хлеб", "цена": 30})
                .as_object()
                .cloned()
                .unwrap()],
            serde_json::json!({"открыто": true})
                .as_object()
                .cloned()
                .unwrap(),
        )
    }

    #[test]
    fn nested_table_roundtrips_through_cell_value() {
        let value = nested().to_nested_value();
        assert!(QuestTable::is_nested_value(&value));
        let restored = QuestTable::from_cell_value(&value).expect("вложенная таблица");
        assert_eq!(restored.columns, vec!["товар", "цена"]);
        assert_eq!(restored.rows[0]["товар"], Value::String("хлеб".into()));
        assert_eq!(restored.data["открыто"], Value::Bool(true));
    }

    #[test]
    fn plain_values_and_kv_objects_are_not_tables() {
        assert!(!QuestTable::is_nested_value(&Value::String("хлеб".into())));
        assert!(!QuestTable::is_nested_value(
            &serde_json::json!({"columns": []})
        ));
        assert!(!QuestTable::is_nested_value(
            &serde_json::json!({"товар": "хлеб"})
        ));
        assert!(QuestTable::from_cell_value(&serde_json::json!({"товар": "хлеб"})).is_none());
    }

    /// Вложенность живёт в `rows` как обычное значение, поэтому формула
    /// `table_cell(table_cell(root, "раздел", 1), "товар", 1)` достаёт ячейку
    /// уже второй таблицы без отдельного разбора.
    #[test]
    fn nested_table_is_visible_to_table_cell_formula() {
        let parent = QuestTable::new(
            "root".into(),
            vec!["раздел".into()],
            vec![serde_json::json!({"раздел": nested().to_nested_value()})
                .as_object()
                .cloned()
                .unwrap()],
            Map::new(),
        );
        let parent_view = parent.formula_view();
        let inner = crate::expression::evaluate_parsed(
            "table_cell(outer, 'раздел', 1)",
            &serde_json::json!({"outer": parent_view})
                .as_object()
                .cloned()
                .unwrap(),
        )
        .expect("формула");
        let restored = QuestTable::from_cell_value(&inner).expect("вложенная таблица");
        assert_eq!(restored.rows[0]["цена"], serde_json::json!(30));
    }
}
