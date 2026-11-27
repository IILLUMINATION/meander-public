import 'dart:async';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/logic/item_editor_helper.dart';
import 'package:canvas_app/features/editor/screens/node_content/content_editor_logic.dart';
import 'package:canvas_app/features/editor/screens/node_content/modal_editor_screen.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_nested_documents.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(EditorNestedDocuments.resetForTest);

  testWidgets('пересозданная вкладка модалки берёт актуальный скрипт', (
    tester,
  ) async {
    final items = <ContentItem>[
      ContentItem(
        id: 'modal-1',
        type: 'modal',
        targetNodeId: 'node-2',
        buttonText: 'Уведомление',
      ),
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
    final firstBuild = builder(context) as ModalEditorScreen;
    expect(firstBuild.existingItem!.scriptAssetId, isNull);

    firstBuild.onChanged!(
      firstBuild.existingItem!.copyWith(
        scriptAssetId: 'scripts/gs-hp.json',
        clearTargetNodeId: true,
      ),
    );
    expect(items.single.scriptAssetId, 'scripts/gs-hp.json');

    final rebuilt = builder(context) as ModalEditorScreen;
    expect(rebuilt.existingItem!.scriptAssetId, 'scripts/gs-hp.json');
    expect(rebuilt.existingItem!.targetNodeId, isNull);
    expect(
      ContentItem.fromJson(rebuilt.existingItem!.toJson()).scriptAssetId,
      'scripts/gs-hp.json',
    );
  });

  testWidgets('сохранённый скрипт не сбрасывается при открытии модалки', (
    tester,
  ) async {
    final emitted = <ContentItem>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ModalEditorScreen(
            questId: 'q1',
            existingItem: ContentItem(
              id: 'modal-1',
              type: 'modal',
              scriptAssetId: 'scripts/gs-hp.json',
            ),
            onChanged: emitted.add,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(emitted, isEmpty);
    final nodeAction = find.widgetWithText(ListTile, tr('Перейти к ноде'));
    final scriptAction = find.widgetWithText(ListTile, tr('Выполнить скрипт'));
    expect(tester.widget<ListTile>(nodeAction).selected, isFalse);
    expect(tester.widget<ListTile>(scriptAction).selected, isTrue);
    expect(find.widgetWithText(OutlinedButton, tr('Не выбрана')), findsNothing);
  });
}
