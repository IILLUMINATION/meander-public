import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/content_item.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_block_view.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_field_editor.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/content_item_picker_model.dart';

class _PopWithResult extends NavigatorObserver {
  _PopWithResult(this.result);

  final Object? result;
  bool _scheduled = false;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null || _scheduled) return;
    _scheduled = true;
    Future.microtask(() => route.navigator?.pop(result));
  }
}

Future<({Future<bool> operation})> _startEdit(
  WidgetTester tester, {
  required String questId,
  required VisualScriptBlock block,
  required ScratchFieldKind kind,
  NavigatorObserver? observer,
}) async {
  late Future<bool> operation;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        navigatorObservers: [?observer],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                operation = editScratchField(
                  context: context,
                  questId: questId,
                  block: block,
                  kind: kind,
                );
              },
              child: const Text('edit'),
            ),
          ),
        ),
      ),
    ),
  );
  final button = tester.widget<TextButton>(
    find.widgetWithText(TextButton, 'edit'),
  );
  await tester.runAsync(() async {
    button.onPressed!();
  });
  await tester.pump();
  return (operation: operation);
}

Future<bool> _letDiskRead(
  WidgetTester tester, {
  required Future<bool> operation,
}) async {
  bool? result;
  Object? error;
  operation.then<void>(
    (value) => result = value,
    onError: (Object value, StackTrace stack) => error = value,
  );
  for (var i = 0; i < 20 && result == null && error == null; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
  expect(error, isNull);
  expect(result, isNotNull, reason: 'редактор поля не завершил операцию');
  return result!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const questId = 'scratch-field-editor-test';

  late Directory appDir;
  late File nodesFile;

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_scratch_fields');
    FileStorage.overrideAppDirectory(appDir);
    QuestStore.resetDefaultInstanceForTest();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    nodesFile = File('${appDir.path}/${QuestPaths.nodesLegacy(questId)}');
    nodesFile.parent.createSync(recursive: true);
    nodesFile.writeAsStringSync(
      '{"nodes":[{"id":"same-node","title":"Новая нода"}]}',
    );
  });

  tearDown(() {
    FileStorage.invalidateJsonCache([QuestPaths.nodesLegacy(questId)]);
  });

  tearDownAll(() async {
    QuestStore.resetDefaultInstanceForTest();
    FileStorage.overrideAppDirectory(null);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  testWidgets('тот же айтем с новой подписью считается изменением', (
    tester,
  ) async {
    final block = SetVisibleBlock(itemId: 'same-item', itemName: 'Старое имя');
    final choice = ContentItemChoice(
      item: ContentItem(id: 'same-item', type: 'text'),
      nodeId: 'node-1',
      nodeTitle: 'Нода',
      label: 'Новое имя',
      typeLabel: 'Текст',
    );
    final edit = await _startEdit(
      tester,
      questId: questId,
      block: block,
      kind: ScratchFieldKind.contentItem,
      observer: _PopWithResult(choice),
    );
    expect(await _letDiskRead(tester, operation: edit.operation), isTrue);
    expect(block.itemId, 'same-item');
    expect(block.itemName, 'Новое имя · Нода');
  });

  testWidgets('тот же id картинки с новой подписью считается изменением', (
    tester,
  ) async {
    final block = SetImageBlock(itemId: 'same-image', itemName: 'Старое имя');
    final choice = ContentItemChoice(
      item: ContentItem(id: 'same-image', type: 'image'),
      nodeId: 'node-1',
      nodeTitle: 'Нода',
      label: 'Новая картинка',
      typeLabel: 'Картинка',
    );
    final edit = await _startEdit(
      tester,
      questId: questId,
      block: block,
      kind: ScratchFieldKind.contentItem,
      observer: _PopWithResult(choice),
    );
    expect(await _letDiskRead(tester, operation: edit.operation), isTrue);
    expect(block.itemId, 'same-image');
    expect(block.itemName, 'Новая картинка · Нода');
  });

  testWidgets('тот же id ноды с обновлённым названием считается изменением', (
    tester,
  ) async {
    final block = GoToNodeBlock(
      targetNodeId: 'same-node',
      targetNodeName: 'Старое название',
    );
    final edit = await _startEdit(
      tester,
      questId: questId,
      block: block,
      kind: ScratchFieldKind.node,
      observer: _PopWithResult('same-node'),
    );
    expect(await _letDiskRead(tester, operation: edit.operation), isTrue);
    expect(block.targetNodeId, 'same-node');
    expect(block.targetNodeName, 'Новая нода');
  });

  testWidgets(
    'повторный выбор всех звуков очищает stale-поля и помечает изменение',
    (tester) async {
      final block = StopSoundBlock(
        target: 'all',
        audioId: 'stale-audio',
        audioName: 'Старый звук',
      );
      final edit = await _startEdit(
        tester,
        questId: questId,
        block: block,
        kind: ScratchFieldKind.stopSoundTarget,
        observer: _PopWithResult('all'),
      );
      expect(await _letDiskRead(tester, operation: edit.operation), isTrue);
      expect(block.audioId, isNull);
      expect(block.audioName, tr('Все звуки'));
    },
  );

  testWidgets('чистый повторный выбор всех звуков не помечает изменение', (
    tester,
  ) async {
    final block = StopSoundBlock(target: 'all', audioName: tr('Все звуки'));
    final edit = await _startEdit(
      tester,
      questId: questId,
      block: block,
      kind: ScratchFieldKind.stopSoundTarget,
      observer: _PopWithResult('all'),
    );
    expect(await _letDiskRead(tester, operation: edit.operation), isFalse);
  });

  testWidgets('пустое имя Lua-функции не меняет блок и не помечает изменение', (
    tester,
  ) async {
    final block = CallLuaBlock(function: 'start');
    final edit = await _startEdit(
      tester,
      questId: questId,
      block: block,
      kind: ScratchFieldKind.luaFunction,
    );
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text(tr('Готово')));
    expect(await _letDiskRead(tester, operation: edit.operation), isFalse);
    expect(block.function, 'start');
  });
}
