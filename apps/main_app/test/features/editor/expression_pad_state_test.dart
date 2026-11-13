import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_pad_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Палитра формул запоминает раскрытые разделы и частые вставки между
/// открытиями — это то, ради чего её вообще трогали.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('без сохранённых настроек разделы не заданы', () async {
    final state = await ExpressionPadStore.load();

    expect(state.openGroups, isNull);
    expect(state.frequent, isEmpty);
  });

  test('раскрытые разделы переживают перезагрузку', () async {
    await ExpressionPadStore.saveOpenGroups({2, 0});

    final state = await ExpressionPadStore.load();

    expect(state.openGroups, {0, 2});
  });

  test('частые вставки идут по убыванию частоты', () async {
    await ExpressionPadStore.recordInsert('{HP}');
    await ExpressionPadStore.recordInsert('[');
    await ExpressionPadStore.recordInsert('{HP}');

    final state = await ExpressionPadStore.load();

    expect(state.frequent.first, '{HP}');
    expect(state.frequent, contains('['));
  });

  test('длинный текст и перевод строки в частые не попадают', () async {
    await ExpressionPadStore.recordInsert(
      'random(1, 100) + какой-то очень длинный хвост',
    );
    await ExpressionPadStore.recordInsert('two\nlines');

    final state = await ExpressionPadStore.load();

    expect(state.frequent, isEmpty);
  });

  test('одиночные цифры в частые не попадают', () async {
    await ExpressionPadStore.recordInsert('7');
    await ExpressionPadStore.recordInsert('[');

    final state = await ExpressionPadStore.load();

    expect(state.frequent, ['[']);
  });

  test('битые настройки не роняют загрузку', () async {
    SharedPreferences.setMockInitialValues({
      'expression_editor.pad_state': 'не json',
    });

    final state = await ExpressionPadStore.load();

    expect(state.frequent, isEmpty);
  });
}