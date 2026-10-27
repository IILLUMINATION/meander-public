import 'dart:convert';
import 'package:mnd_core/contracts/script_runtime.dart';

class QuestTable implements ScriptTable {
  String name;
  List<String> columns;

  // Classic table rows: index-based access.
  List<Map<String, dynamic>> rows;

  // Key-value storage for script-friendly lookups.
  @override
  Map<String, dynamic> data;

  QuestTable({
    required this.name,
    required this.columns,
    required this.rows,
    this.data = const {},
  });

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
        if (!k.startsWith('__') && k != 'name' && k != 'columns' && k != 'rows' && k != 'data') {
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
        if (k != 'name' && k != 'columns' && k != 'rows' && !k.startsWith('__')) {
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
      data: dataMap,
    );
  }

  Map<String, dynamic> toJson() {
    return {'name': name, 'columns': columns, 'rows': rows, 'data': data};
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
