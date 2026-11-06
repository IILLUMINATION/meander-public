// Регресс: токен `{лавка[{ключ}][1]}` резолвер текста резал регуляркой
// `\{([^}]+)\}` — та не умеет вложенные `{}`. В тексте оставался хвост `][1]}`,
// а вместо значения ячейки была пустота. Скобки теперь балансируем.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/contracts/script_runtime.dart'
    show ScriptRuntimeState;
import 'package:mnd_core/engine/script_executor.dart';
import 'package:mnd_core/models/quest_table.dart';
import 'package:mnd_core/models/value_format.dart';
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

/// Ровно тот путь, которым идёт плеер без движка: схлопнули `{{}}`, подставили
/// токены через ядро.
String _resolveLegacy(String text, ScriptRuntimeState state) =>
    ScriptExecutor.substitutePlaceholders(
      ScriptExecutor.collapseDoubleBraces(text),
      (token) => formatScriptValue(
        ScriptExecutor.evaluateExpression(token, state),
      ),
    );

void main() {
  group('substitutePlaceholders', () {
    test('вложенная переменная остаётся одним токеном', () {
      final tokens = <String>[];
      final out = ScriptExecutor.substitutePlaceholders(
        'цена {лавка[{ключ}][1]} р.',
        (token) {
          tokens.add(token);
          return '30';
        },
      );
      expect(tokens, ['лавка[{ключ}][1]']);
      expect(out, 'цена 30 р.');
    });

    test('несколько маркеров и текст между ними', () {
      final out = ScriptExecutor.substitutePlaceholders(
        'a {x} b {y} c',
        (token) => '[[$token]]',
      );
      expect(out, 'a [[x]] b [[y]] c');
    });

    test('пустой токен и незакрытая скобка уходят в текст как есть', () {
      expect(
        ScriptExecutor.substitutePlaceholders('p {} q {r', (_) => '!'),
        'p {} q {r',
      );
    });

    test('текст без скобок не трогается', () {
      expect(ScriptExecutor.substitutePlaceholders('просто текст', (_) => '!'),
          'просто текст');
    });

    test('НЕГАТИВНЫЙ КОНТРОЛЬ: старая регулярка рвёт вложенный токен', () {
      const source = '{лавка[{ключ}][1]}';
      // Так резолвер жил до фикса: матчается `{лавка[{ключ}`, хвост остаётся.
      final old = source.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (m) {
        final expression = m.group(1);
        if (expression == null || expression.isEmpty) return m.group(0)!;
        return '30';
      });
      expect(old, '30][1]}');
      expect(old, isNot('30'));
      // Новый сканер отдаёт токен целиком и хвоста не оставляет.
      expect(
        ScriptExecutor.substitutePlaceholders(source, (_) => '30'),
        '30',
      );
    });
  });

  group(
    'Rust-ядро: ссылка на ячейку с переменной внутри',
    skip: _soPath == null,
    () {
      setUpAll(() async {
        await gen.RustLib.init(externalLibrary: ExternalLibrary.open(_soPath!));
      });

      test('{{т["колонка"][1]}} и {{т[{ключ}][1]}} → значение ячейки', () {
        final state = InMemoryScriptRuntimeState(
          tables: {
            'rfd': QuestTable(
              name: 'rfd',
              columns: const ['ыа', 'тест'],
              rows: [
                {'ыа': 'значение-cell', 'тест': 'тест'},
              ],
              data: const {},
            ),
          },
          variables: const {'ключ': 'ыа'},
        );
        expect(_resolveLegacy('{{rfd["ыа"][1]}}', state), 'значение-cell');
        expect(_resolveLegacy('{{rfd[{ключ}][1]}}', state), 'значение-cell');
        expect(
          _resolveLegacy('вот {rfd[{ключ}][1]} в строке', state),
          'вот значение-cell в строке',
        );
      });

      test('без скобок вокруг номера строки движок возвращает весь столбец',
          () {
        // Так автор и тестировщик получали `[тыква, киви]` вместо ячейки —
        // пикер ячейки обязан вставлять `[N]`, см. table_editor_ux_test.
        final state = InMemoryScriptRuntimeState(
          tables: {
            'rfd': QuestTable(
              name: 'rfd',
              columns: const ['ыа'],
              rows: [
                {'ыа': 'значение-cell'},
              ],
              data: const {},
            ),
          },
        );
        expect(_resolveLegacy('{rfd["ыа"]1}', state), '[значение-cell]');
        expect(_resolveLegacy('{rfd["ыа"][1]}', state), 'значение-cell');
      });

      test('имя строки со скобками: `{{т["кол"]["{имя}"]}}` → значение', () {
        // Клиент снимает внешние скобки и отдаёт ядру голый адрес
        // `т["кол"]["{имя}"]`; скобки внутри кавычек — имя строки, а не
        // плейсхолдер. Подстановка до адреса давала пустой текст (квест
        // 496e8377: таблица `чсм`, строка `{test}` = «проверка»).
        final state = InMemoryScriptRuntimeState(
          tables: {
            'т': QuestTable(
              name: 'т',
              columns: const ['кол'],
              rows: [
                {'кол': 'проверка'},
                {'кол': 'вторая'},
              ],
              rowNames: const ['{имя}', 'a}b'],
              data: const {},
            ),
          },
          variables: const {'имя': 'подмена'},
        );
        expect(_resolveLegacy('{{т["кол"]["{имя}"]}}', state), 'проверка');
        expect(_resolveLegacy('вот {т["кол"]["{имя}"]} тут', state), 'вот проверка тут');
        expect(_resolveLegacy('вот {т["кол"]["a}b"]} тут', state), 'вот вторая тут');
      });
    },
  );
}
