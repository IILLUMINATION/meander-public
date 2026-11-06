import 'dart:convert';

import 'package:mnd_core/mnd_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Глубокое сравнение двух значений (Map/List/скаляр) — используется для
/// `==` состояния, чтобы no-op мутации не эмитили подписчикам.
bool _deepEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!_deepEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

class GameState {
  final Map<String, dynamic> variables;
  final Map<String, QuestTable> tables;

  GameState({this.variables = const {}, this.tables = const {}});

  GameState copyWith({
    Map<String, dynamic>? variables,
    Map<String, QuestTable>? tables,
  }) {
    return GameState(
      variables: variables ?? this.variables,
      tables: tables ?? this.tables,
    );
  }

  /// Сравнение состояний: сперва дешёвое структурное (кол-во ключей и
  /// ссылки на значения), и только при подозрении — глубокое.
  ///
  /// Прежняя версия гоняла полное `_deepEquals` по всем переменным и
  /// таблицам на каждую эмиссию. В длинной сессии переменные копятся
  /// (`_SYS_HISTORY` и др.), таблицы растут, и каждая мутация стоила всё
  /// дороже — это и был источник «постепенных лагов».
  ///
  /// Теперь: если значение переменной — тот же объект, что в прошлом
  /// состоянии, сравнивать его глубоко не нужно (Map копируется целиком
  /// при каждой мутации, но сами значения передаются по ссылке). То же
  /// для таблиц: `QuestTable` пересоздаётся при каждой правке, поэтому
  /// сравнение по ссылке отсекает почти все проверки.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! GameState) return false;
    if (variables.length != other.variables.length) return false;
    for (final entry in variables.entries) {
      final otherValue = other.variables[entry.key];
      if (otherValue == null && !other.variables.containsKey(entry.key)) {
        return false;
      }
      if (!identical(entry.value, otherValue) &&
          !_deepEquals(entry.value, otherValue)) {
        return false;
      }
    }
    if (tables.length != other.tables.length) return false;
    for (final entry in tables.entries) {
      final otherTable = other.tables[entry.key];
      if (otherTable == null) return false;
      if (identical(entry.value, otherTable)) continue;
      if (entry.value.name != otherTable.name) return false;
      if (!_deepEquals(entry.value.columns, otherTable.columns)) return false;
      if (!_deepEquals(entry.value.rows, otherTable.rows)) return false;
      if (!_deepEquals(entry.value.data, otherTable.data)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    variables.length,
    tables.length,
  );
}

class GameStateNotifier extends StateNotifier<GameState>
    implements ScriptRuntimeState {
  GameStateNotifier() : super(GameState());

  /// Эмитировать только при реальном изменении содержимого: no-op мутации
  /// (установка того же значения) не должны пересобирать 11+ подписчиков.
  @override
  bool updateShouldNotify(GameState old, GameState current) => old != current;

  @override
  Map<String, dynamic> get allVariables => state.variables;
  @override
  Map<String, ScriptTable> get allTables =>
      Map<String, ScriptTable>.from(state.tables);

  @override
  void setVariable(String name, dynamic value) {
    final newVariables = Map<String, dynamic>.from(state.variables);
    newVariables[name] = value;
    state = state.copyWith(variables: newVariables);
  }

  @override
  dynamic getVariable(String name) {
    return state.variables[name];
  }

  @override
  void setTable(String tableName, ScriptTable table) {
    if (table is! QuestTable) {
      throw ArgumentError.value(
        table,
        'table',
        'GameStateNotifier supports only QuestTable implementations',
      );
    }
    final newTables = Map<String, QuestTable>.from(state.tables);
    newTables[tableName] = table;
    state = state.copyWith(tables: newTables);
  }

  @override
  ScriptTable? getTable(String tableName) {
    return state.tables[tableName] as ScriptTable?;
  }

  void restoreState({
    required Map<String, dynamic> variables,
    required Map<String, dynamic> tablesJson,
  }) {
    final Map<String, QuestTable> restoredTables = {};

    tablesJson.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        restoredTables[key] = QuestTable.fromJson(value);
      }
    });

    state = state.copyWith(
      variables: Map.from(variables),
      tables: restoredTables,
    );
  }

  /// Расшифровать плоские переменные из дельты движка (имя → JSON-строка).
  Map<String, dynamic> _decodeVariables(Map<String, dynamic> raw) {
    final out = <String, dynamic>{};
    raw.forEach((k, v) {
      final rawJson = v.toString();
      try {
        out[k] = rawJson == 'null' ? null : jsonDecode(rawJson);
      } catch (_) {
        out[k] = rawJson;
      }
    });
    return out;
  }

  /// Расшифровать таблицы из дельты движка (имя → JSON-строка полной таблицы).
  Map<String, QuestTable> _decodeTables(Map<String, dynamic> raw) {
    final out = <String, QuestTable>{};
    raw.forEach((name, tableDataRaw) {
      if (tableDataRaw is Map) {
        final tableMap = Map<String, dynamic>.from(tableDataRaw);
        out[name] = QuestTable.fromJson(tableMap);
      } else if (tableDataRaw is String) {
        try {
          final decoded = jsonDecode(tableDataRaw);
          if (decoded is Map<String, dynamic>) {
            out[name] = QuestTable.fromJson(decoded);
          }
        } catch (_) {}
      }
    });
    return out;
  }

  /// Точечно применить дельту: обновляет только переданные ключи,
  /// не трогая остальные (в отличие от полной замены в [`restoreState`]).
  ///
  /// [variables] и [tablesJson] — сырая дельта движка: отображения
  /// `имя → JSON-строка` (формат `drainStateDelta`). Декодирование происходит
  /// здесь, чтобы клиент-провайдер оставался «тупым» транслятором сейвов.
  void applyDelta({
    required Map<String, dynamic> variables,
    required Map<String, dynamic> tablesJson,
  }) {
    if (variables.isEmpty && tablesJson.isEmpty) return;

    final decodedVariables = _decodeVariables(variables);
    final decodedTables = _decodeTables(tablesJson);

    final newVariables = Map<String, dynamic>.from(state.variables);
    newVariables.addAll(decodedVariables);

    final newTables = Map<String, QuestTable>.from(state.tables);
    decodedTables.forEach((key, table) {
      newTables[key] = table;
    });

    state = state.copyWith(variables: newVariables, tables: newTables);
  }

  void clear() {
    state = GameState();
  }
}

/// Глобальное состояние игры.
///
/// НЕ autoDispose: состояние переменных/таблиц должно переживать короткие
/// отключения подписчиков (переходы между экранами, перестроение виджетов),
/// иначе игра «забывает» прогресс. Явная очистка — в [GameStateNotifier.clear],
/// который вызывается при старте новой сессии (loadInitialNode).
final gameStateProvider = StateNotifierProvider<GameStateNotifier, GameState>((
  ref,
) {
  return GameStateNotifier();
});
