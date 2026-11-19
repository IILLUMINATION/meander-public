// Вложенный редактор (стек, контейнер, текст…) должен стать вкладкой, а не
// маршрутом поверх воркспейса. Здесь держим две вещи, которые легко
// сломать: вкладка создаётся с родителем (он остаётся смонтированным) и
// `Navigator.pop` внутри экрана закрывает её, возвращая результат
// вызывающему коду.

import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_nested_documents.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(EditorNestedDocuments.resetForTest);

  testWidgets('вложенный редактор открывается вкладкой с родителем', (
    tester,
  ) async {
    final opened = <EditorDocumentDescriptor>[];
    final focused = <EditorDocumentId>[];
    final runtime = <EditorDocumentId, EditorDocumentRuntime>{};
    final parent = EditorDocumentDescriptor.node('q1', 'n1');
    late BuildContext context;

    final scope = EditorWorkspaceScope(
      questId: 'q1',
      openDocument: (_) {},
      openForcedAsNewTab: opened.add,
      showNewTabSheet: () {},
      togglePin: (_) {},
      isPinned: (_) => false,
      closeDocument: (_) async => true,
      focusDocument: focused.add,
      replaceDocument: (_, _) {},
      registerRuntime: (id, value) => runtime[id] = value,
      unregisterRuntime: (_) {},
      markDirty: (_, _) {},
      requestBack: () async {},
      child: EditorDocumentContext(
        id: parent.id,
        child: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await tester.pumpWidget(MaterialApp(home: scope));

    final first = EditorNestedDocuments.open<void>(
      context,
      questId: 'q1',
      identity: 'stack:n1:item1',
      title: 'Стек',
      builder: (_) => const SizedBox.shrink(),
    );
    final second = EditorNestedDocuments.open<void>(
      context,
      questId: 'q1',
      identity: 'stack:n1:item1',
      title: 'Стек',
      builder: (_) => const SizedBox.shrink(),
    );

    expect(opened, hasLength(1));
    final descriptor = opened.single;
    expect(descriptor.id.kind, EditorDocumentKind.tool);
    expect(descriptor.id.key, 'stack:n1:item1');
    expect(descriptor.parentId, parent.id);
    expect(focused, [descriptor.id]);
    expect(runtime[descriptor.id]?.keepAlive, isTrue);

    EditorNestedDocuments.complete(descriptor.id, null);
    await first;
    await second;
  });

  testWidgets(
    'pop вложенного экрана возвращает результат и закрывает вкладку',
    (tester) async {
      final opened = <EditorDocumentDescriptor>[];
      final closed = <EditorDocumentId>[];
      late BuildContext context;
      final scope = EditorWorkspaceScope(
        questId: 'q1',
        openDocument: (_) {},
        openForcedAsNewTab: opened.add,
        showNewTabSheet: () {},
        togglePin: (_) {},
        isPinned: (_) => false,
        closeDocument: (id) async {
          closed.add(id);
          return true;
        },
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
      );

      await tester.pumpWidget(MaterialApp(home: scope));

      final future = EditorNestedDocuments.open<String>(
        context,
        questId: 'q1',
        identity: 'text:n1:item1',
        title: 'Текст',
        builder: (screenContext) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.pop(screenContext, 'saved'),
              child: const Text('save'),
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(home: EditorNestedDocuments.build(opened.single.id)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('save'));
      await tester.pumpAndSettle();

      expect(await future, 'saved');
      expect(closed, [opened.single.id]);
    },
  );

  test(
    'restore выбрасывает вкладки инструментов и экранов: builder не сохранён',
    () {
      final node = EditorDocumentDescriptor.node('q1', 'n1');
      final tool = EditorDocumentDescriptor(
        id: const EditorDocumentId(
          questId: 'q1',
          kind: EditorDocumentKind.tool,
          key: 'stack:n1:item1',
        ),
        title: 'Стек',
        parentId: node.id,
      );
      final screen = EditorDocumentDescriptor(
        id: const EditorDocumentId(
          questId: 'q1',
          kind: EditorDocumentKind.screen,
          key: 'market',
        ),
        title: 'Каталог',
      );
      final controller = EditorWorkspaceController('q1');

      controller.restore(
        EditorWorkspaceState(
          documents: [node, tool, screen],
          activeId: screen.id,
          layout: EditorDockLayout(rootTabs: [node.id, tool.id, screen.id]),
        ),
      );

      expect(controller.state.documents.map((d) => d.id), [node.id]);
      expect(controller.state.activeId, node.id);
      expect(controller.state.layout.rootTabs, [node.id]);
    },
  );
}
