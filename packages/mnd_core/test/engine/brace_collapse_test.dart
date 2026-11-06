// Схлопывание лишних фигурных скобок: `{{имя["колонка"][N]}}` → `{...}`.
// Регресс багов: двойная вставка `{{...}}` теряла маркер на дисплее
// (regex `\{([^}]+)\}` захватывал лишнюю `{` → токен нерезолвился → `null`).

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/engine/script_executor.dart';
import 'package:mnd_core/models/quest_table.dart';
import 'package:mnd_core/runtime/in_memory_script_runtime_state.dart';
import 'package:mnd_core/src/gen/frb_generated.dart' as gen;

final String? _soPath = () {
  final env = Platform.environment['MND_FFI_SO'];
  if (env != null && File(env).existsSync()) return env;
  for (final c in [
    '../../target/release/libmnd_ffi.so',
  ]) {
    if (File(c).existsSync()) return File(c).absolute.path;
  }
  return null;
}();

QuestTable _table() => QuestTable(
      name: 'rfd',
      columns: const ['ыа', 'тест'],
      rows: [
        {'ыа': 'значение-cell', 'тест': 'тест'},
      ],
      data: const {'ключ': 'значение из data'},
    );

InMemoryScriptRuntimeState _state() =>
    InMemoryScriptRuntimeState(tables: {'rfd': _table()});

void main() {
  group('collapseDoubleBraces', () {
    test('двойная обёртка плейсхолдера', () {
      expect(ScriptExecutor.collapseDoubleBraces('{{rfd["ыа"]1}}'),
          '{rfd["ыа"]1}');
      expect(
        ScriptExecutor.collapseDoubleBraces('{{rfd["ыа"]1}}{{rfd["тест"]1}}'),
        '{rfd["ыа"]1}{rfd["тест"]1}',
      );
    });

    test('}} перед следующим маркером', () {
      expect(ScriptExecutor.collapseDoubleBraces('текст}} {b}'), 'текст} {b}');
      expect(ScriptExecutor.collapseDoubleBraces('{a}{b}}'), '{a}{b}');
    });

    test('одинарные скобки не трогаются', () {
      expect(ScriptExecutor.collapseDoubleBraces('{rfd["ыа"]1}'),
          '{rfd["ыа"]1}');
      expect(ScriptExecutor.collapseDoubleBraces('Просто текст'),
          'Просто текст');
      expect(ScriptExecutor.collapseDoubleBraces('a {b} c'), 'a {b} c');
    });

    test('`{{`/`}}` внутри кавычек — данные, не схлопываются', () {
      // Имя строки/колонки внутри `[...]` может содержать двойные скобки.
      expect(
        ScriptExecutor.collapseDoubleBraces('{{rfd["a{{b"]}}'),
        '{rfd["a{{b"]}',
      );
      expect(
        ScriptExecutor.collapseDoubleBraces('{{rfd["a}}b"]}}'),
        '{rfd["a}}b"]}',
      );
    });

    test('апостроф в обычном тексте не выключает нормализацию', () {
      // `'` вне `[...]` — проза, а не строковый литерал адреса.
      expect(ScriptExecutor.collapseDoubleBraces("It's {{rfd['ыа']1}}"),
          "It's {rfd['ыа']1}");
    });
  });

  group('Rust-ядро (FFI) терпит двойную обёртку', skip: _soPath == null, () {
    setUpAll(() async {
      await gen.RustLib.init(
        externalLibrary: ExternalLibrary.open(_soPath!),
      );
    });

    test('evaluateExpression("{{rfd["ыа"][1]}}") → значение ячейки', () {
      final s = _state();
      expect(ScriptExecutor.evaluateExpression('{{rfd["ыа"][1]}}', s),
          'значение-cell');
      expect(ScriptExecutor.evaluateExpression('{rfd["ыа"][1]}', s),
          'значение-cell');
    });
  });
}
