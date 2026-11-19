import 'package:canvas_app/features/editor/workspace/script_editor_mode.dart';
import 'package:canvas_app/features/settings/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Выбор редактора скриптов живёт в настройках и пишется на устройство:
/// переключатель обязан и менять состояние, и сохранять выбор.
Future<void> _pumpSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: SettingsScreen())),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => ScriptEditorModeStore.instance.resetForTests());
  tearDown(() => ScriptEditorModeStore.instance.resetForTests());

  testWidgets('секция редактора предлагает оба режима', (tester) async {
    await _pumpSettings(tester);

    final title = find.text('Редактор скриптов');
    await tester.ensureVisible(title);
    await tester.pump();

    expect(title, findsOneWidget);
    expect(find.text('Классический'), findsOneWidget);
    expect(find.text('Канвас как в Scratch'), findsOneWidget);
  });

  testWidgets('выбор канваса сохраняется в prefs', (tester) async {
    await _pumpSettings(tester);

    final canvas = find.text('Канвас как в Scratch');
    await tester.ensureVisible(canvas);
    await tester.pump();
    await tester.tap(canvas);
    await tester.pumpAndSettle();

    expect(ScriptEditorModeStore.instance.mode, ScriptEditorMode.canvas);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('script_editor_mode'), 'canvas');
  });
}
