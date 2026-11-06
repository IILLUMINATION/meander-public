/// FFI-обёртка ScriptExecutor — заменяет engine/script_executor.dart.
///
/// API идентичен чистому-Dart `ScriptExecutor`, но внутри вызывает Rust-ядро
/// через flutter_rust_bridge.
///
/// Протокол синхронизации — дельта-протокол: Rust-ядро возвращает только
/// ИЗМЕНЁННЫЕ переменные и таблицы (ScriptExecuteResult), клиент применяет
/// их точечно. Никогда не делается слепая перезапись всего состояния —
/// это исключает «воскрешение» устаревших значений при повторных execute.
library;

import 'dart:convert';

import 'package:mnd_core/contracts/script_runtime.dart' show EventType, ScriptRuntimeState;
import 'package:mnd_core/models/quest_table.dart' show QuestTable;
import 'package:mnd_core/src/gen/api/models.dart' as gen;
import 'package:mnd_core/src/gen/api/script_executor.dart' as gen_exec;

/// Контроллер исполнения (заглушка — лимиты управляются Rust-ядром).
class ExecutionController {
  int steps = 0;
  bool get isExceeded => steps >= 2000;
}

// ---------------------------------------------------------------------------
// Конвертация EventType
// ---------------------------------------------------------------------------

gen.EventType _toGen(EventType t) => switch (t) {
      EventType.onQuestStart => gen.EventType.onQuestStart,
      EventType.onNodeEnter => gen.EventType.onNodeEnter,
      EventType.onPress => gen.EventType.onPress,
      EventType.onContentAppear => gen.EventType.onContentAppear,
      EventType.function => gen.EventType.function,
      EventType.onDataChange => gen.EventType.onDataChange,
    };

// ---------------------------------------------------------------------------
// Сериализация ScriptRuntimeState для синхронных плоских вызовов
// ---------------------------------------------------------------------------

Map<String, String> _serializeVariables(ScriptRuntimeState state) {
  return Map<String, String>.fromEntries(
    state.allVariables.entries.map(
      (e) => MapEntry(e.key, jsonEncode(e.value)),
    ),
  );
}

Map<String, Map<String, String>> _serializeTables(ScriptRuntimeState state) {
  return Map<String, Map<String, String>>.fromEntries(
    state.allTables.entries.map((e) {
      final data = Map<String, String>.fromEntries(
        e.value.data.entries.map(
          (de) => MapEntry(de.key, jsonEncode(de.value)),
        ),
      );
      final table = e.value;
      if (table is QuestTable) {
        data['__table_full_json__'] = jsonEncode(table.toJson());
      } else {
        data['__table_full_json__'] = jsonEncode({
          'name': e.key,
          'columns': <String>[],
          'rows': <Map<String, dynamic>>[],
          'data': table.data,
        });
      }
      return MapEntry(e.key, data);
    }),
  );
}

/// Применить дельту мутаций из Rust к Dart-состоянию.
///
/// Меняются только ключи, присутствующие в дельте. Всё остальное
/// состояние (включая переменные, которых скрипт не касался) остаётся
/// нетронутым.
void _applyMutations(
  gen_exec.ScriptExecuteResult mutations,
  ScriptRuntimeState dartState,
) {
  for (final entry in mutations.setVariable.entries) {
    dartState.setVariable(
      entry.key,
      entry.value == 'null' ? null : jsonDecode(entry.value),
    );
  }
  for (final entry in mutations.setTable.entries) {
    QuestTable table;
    final fullJson = entry.value['__table_full_json__'];
    if (fullJson != null) {
      try {
        final decoded = jsonDecode(fullJson) as Map<String, dynamic>;
        table = QuestTable.fromJson(decoded);
        table.data.removeWhere((k, _) => k.startsWith('__'));
      } catch (_) {
        final data = <String, dynamic>{};
        for (final de in entry.value.entries) {
          if (!de.key.startsWith('__')) {
            data[de.key] = jsonDecode(de.value);
          }
        }
        table = QuestTable(
          name: entry.key,
          columns: [],
          rows: [],
          data: data,
        );
      }
    } else {
      final data = <String, dynamic>{};
      for (final de in entry.value.entries) {
        if (!de.key.startsWith('__')) {
          data[de.key] = jsonDecode(de.value);
        }
      }
      table = QuestTable(
        name: entry.key,
        columns: [],
        rows: [],
        data: data,
      );
    }
    dartState.setTable(entry.key, table);
  }
}

// ---------------------------------------------------------------------------
// Публичный API (идентичен Dart-оригиналу ScriptExecutor)
// ---------------------------------------------------------------------------

class ScriptExecutor {
  ScriptExecutor._();

  /// Схлопывание лишних фигурных скобок в тексте с плейсхолдерами:
  /// `{{rfd["ыа"]1}}` → `{rfd["ыа"]1}`; `текст}} {другое}` → `текст} {другое}`.
  /// Двойная обёртка `{{}}` вокруг маркера не трогается.
  ///
  /// Где применять: перед [substitutePlaceholders], иначе токен захватывает
  /// лишнюю `{` и подстановка пропадает.
  ///
  /// Внутри кавычек скобки — данные, а не разметка: имя строки/колонки может
  /// содержать `{{`, `}}` и экранированную кавычку. Скан учитывает строковые
  /// литералы (кавычки — только внутри `[...]`) и `\`-экранирование — тот же
  /// паритет, что у Rust `normalize_placeholder_braces`.
  static String collapseDoubleBraces(String text) {
    if (!text.contains('{{') && !text.contains('}}')) return text;
    final sb = StringBuffer();
    var i = 0;
    int? quote; // code unit открывшей кавычки, null — вне строкового литерала
    var brackets = 0;
    while (i < text.length) {
      final c = text.codeUnitAt(i);
      if (quote != null) {
        sb.writeCharCode(c);
        if (c == 0x5C && i + 1 < text.length) {
          sb.writeCharCode(text.codeUnitAt(i + 1));
          i += 2;
          continue;
        }
        if (c == quote) quote = null;
        i++;
        continue;
      }
      if ((c == 0x22 || c == 0x27) && brackets > 0) {
        quote = c;
        sb.writeCharCode(c);
        i++;
        continue;
      }
      if (c == 0x5B) {
        brackets++;
      } else if (c == 0x5D && brackets > 0) {
        brackets--;
      }
      if (c == 0x7B && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x7B) {
        final after = i + 2 < text.length ? text.codeUnitAt(i + 2) : -1;
        if (after != 0x7D) {
          sb.writeCharCode(0x7B);
          i += 2;
          continue;
        }
      }
      if (c == 0x7D && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x7D) {
        final after = i + 2 < text.length ? text.codeUnitAt(i + 2) : -1;
        final isBoundary = after == -1 ||
            after == 0x7B ||
            after == 0x20 ||
            after == 0x0A ||
            after == 0x09;
        if (isBoundary) {
          sb.writeCharCode(0x7D);
          i += 2;
          continue;
        }
      }
      sb.writeCharCode(c);
      i++;
    }
    return sb.toString();
  }

  /// Подстановка `{токен}` в текст. Скобки балансируем, а не режем регуляркой
  /// `\{([^}]+)\}`: токен имеет право сам содержать `{…}` —
  /// `{лавка[{ключ}][1]}` читается целиком, а регулярка рвала его на
  /// `{лавка[{ключ}`, и мусор `][1]}` оставался в тексте.
  ///
  /// Кавычки внутри токена — данные: `{т["кол"]["a}b"]}` — имя строки `a}b`,
  /// а не закрытие маркера. `\`-экранирование тоже учитывается (паритет с
  /// Rust `resolve_inline_placeholders`).
  ///
  /// [resolve] вызывается для содержимого токена. Пустой токен и незакрытая
  /// скобка остаются в тексте как есть.
  static String substitutePlaceholders(
    String text,
    String Function(String token) resolve,
  ) {
    var start = text.indexOf('{');
    if (start < 0) return text;
    final sb = StringBuffer();
    var cursor = 0;
    while (start >= 0) {
      var depth = 0;
      var end = -1;
      var inQuote = false;
      var quoteChar = -1;
      for (var i = start; i < text.length; i++) {
        final c = text.codeUnitAt(i);
        if (inQuote) {
          if (c == 0x5C) {
            i++; // экранированный символ (кавычка или обратный слеш)
            continue;
          }
          if (c == quoteChar) inQuote = false;
          continue;
        }
        if (c == 0x22 || c == 0x27) {
          inQuote = true;
          quoteChar = c;
        } else if (c == 0x7B) {
          depth++;
        } else if (c == 0x7D && --depth == 0) {
          end = i;
          break;
        }
      }
      if (end < 0) break;
      final token = text.substring(start + 1, end).trim();
      sb.write(text.substring(cursor, start));
      sb.write(token.isEmpty ? text.substring(start, end + 1) : resolve(token));
      cursor = end + 1;
      start = text.indexOf('{', cursor);
    }
    sb.write(text.substring(cursor));
    return sb.toString();
  }

  /// Конфигурация движка.
  static void configure({
    dynamic expressionEngine,
    dynamic assetStore,
    void Function(String)? logger,
    bool debugLogsEnabled = false,
    dynamic embeddedScripts,
  }) {
    final config = {
      if (debugLogsEnabled) 'debug_logs_enabled': true,
    };
    gen_exec.configureEngine(jsonConfig: jsonEncode(config));
  }

  /// Определить тип события скрипта.
  static EventType checkScriptEventType(Map<String, dynamic> scriptData) {
    final raw = gen_exec.checkScriptEventTypeFlat(scriptJson: jsonEncode(scriptData));
    return _fromString(raw);
  }

  /// Parse имя события в EventType (fallback на onNodeEnter).
  static EventType _fromString(String raw) {
    return switch (raw) {
      'onPress' => EventType.onPress,
      'onContentAppear' => EventType.onContentAppear,
      'function' => EventType.function,
      'onQuestStart' => EventType.onQuestStart,
      'onDataChange' => EventType.onDataChange,
      _ => EventType.onNodeEnter,
    };
  }

  /// Вычислить выражение.
  /// Синхронная версия — можно вызывать из build.
  static dynamic evaluateExpression(dynamic inputValue, ScriptRuntimeState gameState) {
    if (inputValue == null) return null;
    if (inputValue is! String) return inputValue;

    final trimmed = inputValue.trim();
    if (trimmed.isEmpty) return null;

    // Быстрый путь: прямое чтение переменной из памяти Dart без оверхеда JSON/FFI
    final isSimpleVar = !trimmed.startsWith('=') &&
        !trimmed.contains('{') &&
        !trimmed.contains('(') &&
        !trimmed.contains('+') &&
        !trimmed.contains('-') &&
        !trimmed.contains('*') &&
        !trimmed.contains('/') &&
        !trimmed.contains('>') &&
        !trimmed.contains('<') &&
        !trimmed.contains('=') &&
        !trimmed.contains(' ') &&
        !trimmed.contains('.');

    if (isSimpleVar) {
      if (gameState.allVariables.containsKey(trimmed)) {
        return gameState.getVariable(trimmed);
      }
    }

    final result = gen_exec.evaluateExpressionFlat(
      inputJson: jsonEncode(inputValue),
      variables: _serializeVariables(gameState),
      tables: _serializeTables(gameState),
    );

    // null в JSON → Dart null
    if (result == 'null') return null;
    return jsonDecode(result);
  }

  /// Есть ли исполнимые блоки для события.
  static bool hasExecutableBlocksForEvent(
    Map<String, dynamic> scriptData,
    EventType eventType, {
    String? functionName,
    String? contentItemId,
    bool allowTargetMismatchFallback = false,
  }) {
    return gen_exec.hasExecutableBlocksFlat(
      scriptJson: jsonEncode(scriptData),
      eventType: _toGen(eventType),
      functionName: functionName,
      contentItemId: contentItemId,
      allowTargetMismatchFallback: allowTargetMismatchFallback,
    );
  }

  /// Вычислить условие (evaluateCondition).
  /// Синхронная версия.
  ///
  /// При `allowStateMutation: true` прелюдия (табличные операции / assign
  /// перед блоком `condition`) мутирует состояние — результат возвращается в
  /// дельте и применяется к `gameState` (паритет эталона: `evaluateCondition`
  /// мутировал состояние клиента прямо в процессе оценки — на этом построены
  /// триггеры видимости `ConditionalContentWrapper`).
  static bool evaluateCondition(
    Map<String, dynamic> scriptData,
    ScriptRuntimeState gameState, {
    EventType eventType = EventType.onContentAppear,
    String? functionName,
    String? contentItemId,
    bool allowTargetMismatchFallback = false,
    bool allowStateMutation = false,
  }) {
    final result = gen_exec.evaluateConditionFlat(
      scriptJson: jsonEncode(scriptData),
      variables: _serializeVariables(gameState),
      tables: _serializeTables(gameState),
      eventType: _toGen(eventType),
      functionName: functionName,
      contentItemId: contentItemId,
      allowTargetMismatchFallback: allowTargetMismatchFallback,
      allowStateMutation: allowStateMutation,
    );
    // Дельта прелюдии — применяем точечно (только изменённые ключи).
    if (allowStateMutation) {
      _applyEvaluateMutations(gameState, result);
    }
    return result.result;
  }

  static void _applyEvaluateMutations(
    ScriptRuntimeState dartState,
    gen_exec.ScriptEvaluateResult result,
  ) {
    for (final entry in result.setVariable.entries) {
      dartState.setVariable(
        entry.key,
        entry.value == 'null' ? null : jsonDecode(entry.value),
      );
    }
    _applyEvaluateTableMutations(dartState, result.setTable);
  }

  static void _applyEvaluateTableMutations(
    ScriptRuntimeState dartState,
    Map<String, Map<String, String>> setTable,
  ) {
    setTable.forEach((tableName, patch) {
      final fullJson = patch['__table_full_json__'];
      QuestTable table;
      if (fullJson != null) {
        try {
          final decoded = jsonDecode(fullJson) as Map<String, dynamic>;
          table = QuestTable.fromJson(decoded);
          table.data.removeWhere((k, _) => k.startsWith('__'));
        } catch (_) {
          table = QuestTable(
            name: tableName,
            columns: [],
            rows: [],
            data: {
              for (final de in patch.entries)
                if (!de.key.startsWith('__')) de.key: jsonDecode(de.value),
            },
          );
        }
      } else {
        table = (dartState.getTable(tableName) as QuestTable?) ??
            QuestTable(
              name: tableName,
              columns: [],
              rows: [],
              data: <String, dynamic>{},
            );
        patch.forEach((key, value) {
          if (!key.startsWith('__')) {
            table.data[key] = value == 'null' ? null : jsonDecode(value);
          }
        });
      }
      dartState.setTable(tableName, table);
    });
  }

  /// Исполнить скрипт.
  ///
  /// Асинхронная. Возвращает переход (id узла), если скрипт выполнил
  /// `go_to_node`. Мутации применяются точечно через дельта-протокол.
  ///
  /// FFI-вызов защищён таймаутом: зависание нативного ядра превращается
  /// в исключение `TimeoutException`, а не в бесконечный фриз UI.
  ///
  /// [embeddedScripts] — предварительно загруженные скрипты (path → JSON),
  /// используемые блоками `call_script`/`call_function`. Если скрипт не
  /// содержит вложенных вызовов, можно оставить пустым.
  static Future<String?> execute(
    Map<String, dynamic> scriptData,
    ScriptRuntimeState gameState, {
    required String questId,
    required EventType eventType,
    String? functionName,
    String? contentItemId,
    bool allowTargetMismatchFallback = false,
    Duration timeout = const Duration(seconds: 30),
    Map<String, String> embeddedScripts = const {},
  }) async {
    final result = await gen_exec.executeScript(
      scriptJson: jsonEncode(scriptData),
      variables: _serializeVariables(gameState),
      tables: _serializeTables(gameState),
      questId: questId,
      eventType: _toGen(eventType),
      functionName: functionName,
      contentItemId: contentItemId,
      allowTargetMismatchFallback: allowTargetMismatchFallback,
      embeddedScripts: embeddedScripts,
    ).timeout(timeout);
    _applyMutations(result, gameState);
    return result.transition;
  }
}