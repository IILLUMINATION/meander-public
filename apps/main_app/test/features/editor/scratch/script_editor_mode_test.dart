import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/features/editor/workspace/script_editor_mode.dart';

/// Выбор редактора скриптов хранится на устройстве, а не в квесте: два автора
/// на одном квесте могут работать в разных редакторах, и переключение одного
/// не должно менять вид другого.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ScriptEditorModeStore.instance.resetForTests();
  });

  test('по умолчанию классический редактор', () async {
    await ScriptEditorModeStore.instance.ensureLoaded();
    expect(ScriptEditorModeStore.instance.mode, ScriptEditorMode.classic);
  });

  test('канвас переживает перезапуск', () async {
    await ScriptEditorModeStore.instance.set(ScriptEditorMode.canvas);

    // Имитируем холодный старт: кэш сброшен, prefs те же.
    ScriptEditorModeStore.instance.resetForTests();
    await ScriptEditorModeStore.instance.ensureLoaded();

    expect(ScriptEditorModeStore.instance.mode, ScriptEditorMode.canvas);
  });

  test('возврат к классическому тоже сохраняется', () async {
    await ScriptEditorModeStore.instance.set(ScriptEditorMode.canvas);
    await ScriptEditorModeStore.instance.set(ScriptEditorMode.classic);

    ScriptEditorModeStore.instance.resetForTests();
    await ScriptEditorModeStore.instance.ensureLoaded();

    expect(ScriptEditorModeStore.instance.mode, ScriptEditorMode.classic);
  });

  test('set обновляет кэш сразу, без повторного чтения prefs', () async {
    await ScriptEditorModeStore.instance.set(ScriptEditorMode.canvas);
    expect(ScriptEditorModeStore.instance.mode, ScriptEditorMode.canvas);
  });

  test('неизвестное значение в prefs не ломает выбор', () {
    expect(ScriptEditorMode.parse('нет такого'), ScriptEditorMode.classic);
    expect(ScriptEditorMode.parse(null), ScriptEditorMode.classic);
    expect(ScriptEditorMode.parse('canvas'), ScriptEditorMode.canvas);
  });
}
