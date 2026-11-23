// #39: контент, добавленный внутрь ряда, должен переживать запуск симуляции.
//
// Запуск игры из редактора ряда заменяет вкладку ряда вкладкой игры
// (`QuestEditorShell._open` → `controller.replace`), а «Назад» переоткрывает
// ряд из дескриптора стека посещений. Экран собирается заново из builder'а
// `ItemEditorHelper`, и раньше он стартовал со снапшота элемента на момент
// первого открытия — добавленное фото из списка исчезало, хотя в ноде и на
// диске оно было. Тест дёргает builder дважды: второй раз (пересоздание)
// должен взять детей у живого элемента.

import 'dart:async';

import 'package:canvas_app/features/editor/logic/item_editor_helper.dart';
import 'package:canvas_app/features/editor/screens/node_content/container_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_content/content_editor_logic.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_nested_documents.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(EditorNestedDocuments.resetForTest);

  testWidgets('пересозданная вкладка ряда берёт актуальных детей', (
    tester,
  ) async {
    final items = <ContentItem>[
      ContentItem(id: 'row-1', type: 'row', children: const []),
    ];
    final opened = <EditorDocumentDescriptor>[];
    late BuildContext context;

    await tester.pumpWidget(
      MaterialApp(
        home: EditorWorkspaceScope(
          questId: 'q1',
          openDocument: (_) {},
          openForcedAsNewTab: opened.add,
          showNewTabSheet: () {},
          togglePin: (_) {},
          isPinned: (_) => false,
          closeDocument: (_) async => true,
          focusDocument: (_) {},
          replaceDocument: (_, _) {},
          registerRuntime: (_, _) {},
          unregisterRuntime: (_) {},
          markDirty: (_, _) {},
          requestBack: () async {},
          child: EditorDocumentContext(
            id: EditorDocumentDescriptor.node('q1', 'n1').id,
            child: Builder(
              builder: (ctx) {
                context = ctx;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    final helper = ItemEditorHelper(
      context: context,
      questId: 'q1',
      nodeId: 'n1',
      logic: ContentEditorLogic(
        context: context,
        questId: 'q1',
        currentNodeId: 'n1',
      ),
      getItem: (i) => items[i],
      updateItem: (i, item) => items[i] = item,
    );

    unawaited(helper.editItem(0));
    await tester.pump();

    expect(opened, hasLength(1));
    final builder = EditorNestedDocuments.builderForTest(opened.single.id)!;
    final firstBuild = builder(context) as ContainerEditorScreen;
    expect(firstBuild.initialChildren, isEmpty);

    // Фото добавили внутрь ряда: правка доехала до родительской ноды.
    items[0] = items[0].copyWith(
      children: [ContentItem(id: 'photo-1', type: 'image')],
    );

    // Симуляция заменила вкладку, «Назад» пересоздал её из дескриптора.
    final rebuilt = builder(context) as ContainerEditorScreen;
    expect(rebuilt.initialChildren.map((child) => child.id), ['photo-1']);
  });
}
