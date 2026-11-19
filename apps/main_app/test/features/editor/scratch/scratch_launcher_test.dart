import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_script_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/visual_script_editor_screen.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/editor/workspace/script_editor_mode.dart';

/// Лаунчер воркспейса строит экран документа синхронно (вкладки, восстановление
/// сессии), поэтому режим читается из кэша [ScriptEditorModeStore], а не из
/// prefs по месту.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const descriptor = EditorDocumentDescriptor(
    id: EditorDocumentId(
      questId: 'q',
      kind: EditorDocumentKind.visualScript,
      key: 'intro',
    ),
    title: 'Скрипт',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ScriptEditorModeStore.instance.resetForTests();
  });

  test('по умолчанию открывается классический редактор', () async {
    await ScriptEditorModeStore.instance.ensureLoaded();
    expect(
      EditorDocumentLauncher.buildDocument(descriptor),
      isA<VisualScriptEditorScreen>(),
    );
  });

  test('в режиме канваса открывается канвас', () async {
    await ScriptEditorModeStore.instance.set(ScriptEditorMode.canvas);
    expect(
      EditorDocumentLauncher.buildDocument(descriptor),
      isA<ScratchScriptEditorScreen>(),
    );
  });

  test('другие документы режим не трогает', () async {
    await ScriptEditorModeStore.instance.set(ScriptEditorMode.canvas);
    const chapters = EditorDocumentDescriptor(
      id: EditorDocumentId(
        questId: 'q',
        kind: EditorDocumentKind.chapters,
        key: 'chapters',
      ),
      title: 'Главы',
    );
    expect(
      EditorDocumentLauncher.buildDocument(chapters),
      isNot(isA<ScratchScriptEditorScreen>()),
    );
  });
}
