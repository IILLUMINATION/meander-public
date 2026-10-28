import 'dart:convert';
import 'package:mnd_core/contracts/script_runtime.dart';

/// Экранирует имя колонки или строки для адреса `{таблица["имя"]…}`:
/// содержимое квадратных скобок — строковый литерал, поэтому обратный слэш и
/// кавычка внутри имени обязаны быть экранированы. Слэш — первым, иначе
/// экранируется слэш, добавленный для кавычки.
String escapeTableKey(String name) =>
    name.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

class QuestTable implements ScriptTable {
  String name;
  List<String> columns;

  // Classic table rows: index-based access.
  List<Map<String, dynamic>> rows;

  /// Человекочитаемые имена строк — параллельный [rows] список. Пустая строка
  /// означает «имени нет», доступ по номеру продолжает работать.
  List<String> rowNames;

  // Key-value storage for script-friendly lookups.
  @override
  Map<String, dynamic> data;

  QuestTable({
    required this.name,
    required this.columns,
    required this.rows,
    List<String>? rowNames,
    this.data = const {},
  }) : rowNames = _normalizeRowNames(rowNames, rows.length);

  static List<String> _normalizeRowNames(List<String>? names, int rowCount) {
    final out = List<String>.generate(rowCount, (_) => '');
    if (names != null) {
      for (var i = 0; i < rowCount && i < names.length; i++) {
        out[i] = names[i];
      }
    }
    return out;
  }

  /// Имя строки или пустая строка.
  String rowName(int index) {
    if (index < 0 || index >= rowNames.length) return '';
    return rowNames[index];
  }

  /// Индекс строки по имени (первое совпадение), `null` — имени нет.
  int? rowIndexByName(String name) {
    final needle = name.trim();
    if (needle.isEmpty) return null;
    final index = rowNames.indexOf(needle);
    return index < 0 ? null : index;
  }

  /// Есть ли у таблицы хотя бы одно имя строки.
  bool get hasRowNames => rowNames.any((n) => n.trim().isNotEmpty);

  void insertRowAt(int index, Map<String, dynamic> row, {String name = ''}) {
    final at = index.clamp(0, rows.length);
    rows.insert(at, row);
    rowNames.insert(at, name.trim());
  }

  void removeRowAt(int index) {
    if (index < 0 || index >= rows.length) return;
    rows.removeAt(index);
    if (index < rowNames.length) rowNames.removeAt(index);
  }

  void moveRow(int from, int to) {
    if (from < 0 || from >= rows.length) return;
    if (to < 0 || to >= rows.length) return;
    final row = rows.removeAt(from);
    rows.insert(to, row);
    final name = from < rowNames.length ? rowNames.removeAt(from) : '';
    rowNames.insert(to.clamp(0, rowNames.length), name);
  }

  void setRowName(int index, String name) {
    if (index < 0 || index >= rows.length) return;
    while (rowNames.length < rows.length) {
      rowNames.add('');
    }
    rowNames[index] = name.trim();
  }

  factory QuestTable.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('__table_full_json__')) {
      final full = json['__table_full_json__'];
      Map<String, dynamic> decoded;
      if (full is String) {
        try {
          decoded = Map<String, dynamic>.from(jsonDecode(full) as Map);
        } catch (_) {
          decoded = json;
        }
      } else if (full is Map) {
        decoded = Map<String, dynamic>.from(full);
      } else {
        decoded = json;
      }
      final table = QuestTable.fromJson(decoded);
      json.forEach((k, v) {
        if (!k.startsWith('__') &&
            k != 'name' &&
            k != 'columns' &&
            k != 'rows' &&
            k != 'rowNames' &&
            k != 'row_names' &&
            k != 'data') {
          dynamic val = v;
          if (v is String) {
            try {
              val = jsonDecode(v);
            } catch (_) {
              val = v;
            }
          }
          table.data[k] = val;
        }
      });
      table.data.removeWhere((k, _) => k.startsWith('__'));
      return table;
    }

    final rawData = json['data'];
    Map<String, dynamic> dataMap;
    if (rawData is Map) {
      dataMap = Map<String, dynamic>.from(rawData);
    } else {
      dataMap = <String, dynamic>{};
      json.forEach((k, v) {
        if (k != 'name' &&
            k != 'columns' &&
            k != 'rows' &&
            k != 'rowNames' &&
            k != 'row_names' &&
            !k.startsWith('__')) {
          dynamic val = v;
          if (v is String) {
            try {
              val = jsonDecode(v);
            } catch (_) {
              val = v;
            }
          }
          dataMap[k] = val;
        }
      });
    }
    dataMap.removeWhere((k, _) => k.startsWith('__'));

    return QuestTable(
      name: (json['name'] as String?) ?? '',
      columns: List<String>.from(json['columns'] ?? []),
      rows: (json['rows'] as List<dynamic>? ?? [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(),
      rowNames: List<String>.from(
        (json['rowNames'] ?? json['row_names']) as List<dynamic>? ?? [],
      ),
      data: dataMap,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'columns': columns,
      'rows': rows,
      'rowNames': rowNames,
      'data': data,
    };
  }

  /// Ячейка сетки может хранить вложенную таблицу — объект той же формы,
  /// что и [toJson]. Формулы движка видят её как обычную таблицу.
  static bool isNestedValue(dynamic value) {
    if (value is! Map) return false;
    return value['columns'] is List && value['rows'] is List;
  }

  static QuestTable? nestedFromValue(dynamic value) {
    if (!isNestedValue(value)) return null;
    return QuestTable.fromJson(Map<String, dynamic>.from(value as Map));
  }

  /// Значение для записи в ячейку родительской таблицы.
  Map<String, dynamic> toNestedValue() => toJson();

  void addEmptyRow() {
    final Map<String, dynamic> newRow = {};
    for (final col in columns) {
      newRow[col] = '';
    }
    rows.add(newRow);
    rowNames.add('');
  }

  void updateColumns(List<String> newColumns) {
    for (final row in rows) {
      row.removeWhere((key, value) => !newColumns.contains(key));
    }
    for (final col in newColumns) {
      for (final row in rows) {
        row.putIfAbsent(col, () => '');
      }
    }
    columns = newColumns;
  }
}
