import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';

void main() {
  group('EditorDocumentId', () {
    test('same logical document has stable equality', () {
      const a = EditorDocumentId(
        questId: 'q1',
        kind: EditorDocumentKind.lua,
        key: 'lua-resource-1',
      );
      const b = EditorDocumentId(
        questId: 'q1',
        kind: EditorDocumentKind.lua,
        key: 'lua-resource-1',
      );

      expect(a, b);
      expect(a.persistenceKey, 'q1|lua|lua-resource-1');
    });

    test('route filename is separate from identity', () {
      final descriptor = EditorDocumentDescriptor.lua(
        'q1',
        'lua-resource-1',
        title: 'Intro',
        fileName: 'intro.lua',
      );

      expect(descriptor.id.key, 'lua-resource-1');
      expect(descriptor.routeKey, 'intro.lua');
    });

    test('gameFromSave identity: picker vs concrete slot', () {
      final picker = EditorDocumentDescriptor.gameFromSave('q1');
      final slot = EditorDocumentDescriptor.gameFromSave(
        'q1',
        slotId: 'slot-1',
      );

      expect(picker.id.kind, EditorDocumentKind.gameLoad);
      expect(picker.id.key, 'save:pick');
      expect(picker.routeKey, isNull);
      expect(slot.id.key, 'save:slot-1');
      expect(slot.routeKey, 'slot-1');
      expect(picker.id, isNot(slot.id));
    });

    test('gameFromSave descriptor roundtrips through json', () {
      final original = EditorDocumentDescriptor.gameFromSave(
        'q1',
        slotId: 'slot-42',
        title: 'Симуляция из сейва',
      );

      final restored = EditorDocumentDescriptor.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.routeKey, 'slot-42');
    });

    test('guide catalog and a guide article are different tabs', () {
      final catalog = EditorDocumentDescriptor.guidesCatalog('q1');
      final article = EditorDocumentDescriptor.guide(
        'q1',
        'create_quest',
        title: 'Создать квест',
      );

      expect(catalog.id.kind, EditorDocumentKind.guide);
      expect(article.id.kind, EditorDocumentKind.guide);
      expect(catalog.id.key, 'catalog');
      expect(article.id.key, 'create_quest');
      expect(catalog.id, isNot(article.id));
      expect(article.title, 'Создать квест');
    });

    test('guide and history descriptors roundtrip through json', () {
      final guide = EditorDocumentDescriptor.guide(
        'q1',
        'market',
        title: 'Маркет',
      );
      final history = EditorDocumentDescriptor.questHistory('q1');

      final restoredGuide = EditorDocumentDescriptor.fromJson(guide.toJson());
      final restoredHistory = EditorDocumentDescriptor.fromJson(
        history.toJson(),
      );

      expect(restoredGuide.id, guide.id);
      expect(restoredGuide.title, 'Маркет');
      expect(restoredHistory.id, history.id);
      expect(restoredHistory.id.kind, EditorDocumentKind.questHistory);
      expect(restoredHistory.title, history.title);
    });
  });

  group('EditorWorkspaceController', () {
    test('opening an existing document focuses instead of duplicating', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');

      controller.open(chapters);
      controller.open(resources);
      controller.open(chapters);

      expect(controller.state.documents, [chapters, resources]);
      expect(controller.state.activeId, chapters.id);
    });

    test('reorder changes tab order without changing active document', () {
      final controller = EditorWorkspaceController('q1');
      controller.open(EditorDocumentDescriptor.chapters('q1'));
      controller.open(EditorDocumentDescriptor.resources('q1'));
      controller.open(EditorDocumentDescriptor.templates('q1'));
      controller.focus(EditorDocumentDescriptor.resources('q1').id);

      controller.reorder(2, 0);

      expect(controller.state.documents.map((d) => d.id.kind).toList(), [
        EditorDocumentKind.templates,
        EditorDocumentKind.chapters,
        EditorDocumentKind.resources,
      ]);
      expect(
        controller.state.activeId,
        EditorDocumentDescriptor.resources('q1').id,
      );
    });

    test('dirty marker can be cleared from the tab descriptor', () {
      final controller = EditorWorkspaceController('q1');
      final descriptor = EditorDocumentDescriptor.node('q1', 'n1');
      controller.open(descriptor);

      controller.markDirty(descriptor.id, true);
      expect(controller.state.documents.single.subtitle, 'Изменено');
      controller.markDirty(descriptor.id, false);
      expect(controller.state.documents.single.subtitle, isNull);
    });

    test('dirty marker counts as dirty for documents without subtitle', () {
      final controller = EditorWorkspaceController('q1');
      final descriptor = EditorDocumentDescriptor.node('q1', 'n1');
      controller.open(descriptor);

      expect(controller.state.documents.single.isDirty, false);
      controller.markDirty(descriptor.id, true);
      expect(controller.state.documents.single.isDirty, true);
    });

    test('flushIfDirty saves only a dirty document', () async {
      final controller = EditorWorkspaceController('q1');
      final node = EditorDocumentDescriptor.node('q1', 'n1');
      controller.open(node);
      final saved = <String>[];
      controller.registerRuntime(
        node.id,
        EditorDocumentRuntime(
          onSave: () async {
            saved.add('node');
            return true;
          },
        ),
      );

      await controller.flushIfDirty(node.id);
      expect(saved, isEmpty);

      controller.markDirty(node.id, true);
      await controller.flushIfDirty(node.id);
      expect(saved, ['node']);
    });

    test('close callback can veto closing', () async {
      final controller = EditorWorkspaceController('q1');
      final descriptor = EditorDocumentDescriptor.node('q1', 'n1');
      controller.open(descriptor);
      controller.registerRuntime(
        descriptor.id,
        EditorDocumentRuntime(onBeforeClose: () async => false),
      );

      expect(await controller.close(descriptor.id), false);
      expect(controller.contains(descriptor.id), true);
    });

    test('close chooses neighboring tab', () async {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.focus(chapters.id);

      expect(await controller.close(chapters.id), true);
      expect(controller.state.activeId, resources.id);
    });

    test('replace swaps document at the same tab position', () {
      final controller = EditorWorkspaceController('q1');
      final picker = EditorDocumentDescriptor.gameFromSave('q1');
      controller.open(EditorDocumentDescriptor.chapters('q1'));
      controller.open(picker);

      final replaced = controller.replace(
        picker.id,
        EditorDocumentDescriptor.gameFromSave('q1', slotId: 'slot-1'),
      );

      expect(controller.state.documents.length, 2);
      expect(controller.state.documents[1].id, replaced);
      expect(controller.state.activeId, replaced);
      expect(controller.contains(picker.id), false);
    });

    test('reopenLastClosed restores the most recently closed tab', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);

      controller.closeImmediately(chapters.id);
      controller.closeImmediately(resources.id);
      expect(controller.state.documents, isEmpty);

      controller.reopenLastClosed();
      expect(controller.state.documents.single.id, resources.id);
      expect(controller.state.activeId, resources.id);
    });

    test('closeOthers keeps only the anchor tab', () async {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final templates = EditorDocumentDescriptor.templates('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.open(templates);

      await controller.closeOthers(resources.id);

      expect(controller.state.documents.length, 1);
      expect(controller.state.documents.single.id, resources.id);
    });

    test('closeRight closes tabs after the anchor', () async {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final templates = EditorDocumentDescriptor.templates('q1');
      final settings = EditorDocumentDescriptor.questSettings('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.open(templates);
      controller.open(settings);

      await controller.closeRight(resources.id);

      expect(controller.state.documents.map((d) => d.id.kind).toList(), [
        EditorDocumentKind.chapters,
        EditorDocumentKind.resources,
      ]);
    });

    test('closeAll empties the workspace', () async {
      final controller = EditorWorkspaceController('q1');
      controller.open(EditorDocumentDescriptor.chapters('q1'));
      controller.open(EditorDocumentDescriptor.resources('q1'));
      controller.open(EditorDocumentDescriptor.templates('q1'));

      await controller.closeAll();

      expect(controller.state.documents, isEmpty);
      expect(controller.state.activeId, isNull);
    });

    // --- Тайлинг (панели) ---

    test('split tiles the active document with a target', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.focus(chapters.id);

      expect(controller.split(resources.id, horizontal: true), true);

      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {chapters.id, resources.id});
      expect(controller.state.activeId, resources.id);
      expect(tree, isA<EditorDockSplit>());
    });

    test('split refuses the active document and already-visible one', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);

      expect(controller.split(resources.id), false); // активный == цель
      expect(
        controller.split(chapters.id),
        true,
      ); // создаём [resources | chapters]
      expect(controller.split(chapters.id), false); // уже виден в панели
    });

    test('focus swaps a background tab into the active pane', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final templates = EditorDocumentDescriptor.templates('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.open(templates);
      controller.focus(chapters.id);
      controller.split(resources.id); // [chapters | resources]

      controller.focus(
        templates.id,
      ); // фоновая вкладка → свап в активную панель

      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {chapters.id, templates.id});
      expect(controller.state.activeId, templates.id);
    });

    test('open while split tiles the new document into a new pane', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.focus(chapters.id);
      controller.split(resources.id); // [chapters | resources]

      controller.open(EditorDocumentDescriptor.templates('q1'));

      // Новая вкладка добавляет новую панель (тайлинг растёт), а не
      // подменяет содержимое активной.
      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {
        chapters.id,
        resources.id,
        EditorDocumentDescriptor.templates('q1').id,
      });
      expect(
        controller.state.activeId,
        EditorDocumentDescriptor.templates('q1').id,
      );
    });

    test('split moves an already-visible tab to the new position', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.focus(chapters.id);
      controller.split(
        resources.id,
      ); // [chapters | resources], active = resources
      controller.focus(chapters.id); // активная панель — chapters

      // Разделяем с уже видимой вкладкой: она переезжает на новую позицию,
      // отказ не возникает (дубликатов не появляется).
      expect(controller.split(resources.id, horizontal: false), true);
      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {chapters.id, resources.id});
      expect(controller.state.activeId, resources.id);
    });

    // --- Перетаскивание вкладки на рабочее поле (tileInto / moveToPane) ---

    test(
      'tileInto left of the single pane splits horizontally, dragged first',
      () {
        final controller = EditorWorkspaceController('q1');
        final chapters = EditorDocumentDescriptor.chapters('q1');
        final resources = EditorDocumentDescriptor.resources('q1');
        controller.open(chapters);
        controller.open(resources);
        controller.focus(chapters.id);

        expect(
          controller.tileInto(
            resources.id,
            chapters.id,
            horizontal: true,
            first: true,
          ),
          true,
        );

        final split = controller.state.layout.paneTree! as EditorDockSplit;
        expect(split.horizontal, isTrue);
        expect(
          split.first,
          EditorDockLeaf(resources.id),
        ); // перетаскиваемая — слева
        expect(split.second, EditorDockLeaf(chapters.id));
        expect(controller.state.activeId, resources.id);
      },
    );

    test('tileInto right of a pane in an existing split keeps it a leaf', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final templates = EditorDocumentDescriptor.templates('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.open(templates);
      controller.focus(chapters.id);
      controller.split(resources.id); // [chapters | resources]

      // Дроп на правый край панели templates-... на самом деле панель resources:
      // вкладка templates ещё не в панелях — дроп на панель resources справа.
      expect(
        controller.tileInto(
          templates.id,
          resources.id,
          horizontal: true,
          first: false,
        ),
        true,
      );

      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {
        chapters.id,
        resources.id,
        templates.id,
      });
      final split = tree as EditorDockSplit;
      expect(
        split.second,
        EditorDockSplit(
          horizontal: true,
          ratio: 0.5,
          first: EditorDockLeaf(resources.id),
          second: EditorDockLeaf(templates.id),
        ),
      );
      expect(controller.state.activeId, templates.id);
    });

    test('tileInto moves an already-visible tab without duplicating it', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final templates = EditorDocumentDescriptor.templates('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.open(templates);
      controller.focus(chapters.id);
      controller.split(resources.id); // [chapters | resources]
      controller.focus(chapters.id);
      controller.split(templates.id); // [[chapters | resources] | templates]

      // Дроп видимой вкладки resources на нижний край панели templates.
      expect(
        controller.tileInto(
          resources.id,
          templates.id,
          horizontal: false,
          first: false,
        ),
        true,
      );

      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {
        chapters.id,
        resources.id,
        templates.id,
      }); // дубликатов нет
      expect(controller.state.activeId, resources.id);
    });

    test('tileInto same pane just focuses it', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.focus(chapters.id);
      controller.split(resources.id);
      controller.focus(chapters.id);

      expect(
        controller.tileInto(
          chapters.id,
          chapters.id,
          horizontal: true,
          first: true,
        ),
        true,
      );
      expect(controller.state.activeId, chapters.id);
      expect(controller.state.layout.paneTree!.documentIds.length, 2);
    });

    test('moveToPane swaps the pane content, old doc stays in the tab bar', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final templates = EditorDocumentDescriptor.templates('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.open(templates);
      controller.focus(chapters.id);
      controller.split(resources.id); // [chapters | resources]

      expect(controller.moveToPane(templates.id, resources.id), true);

      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {chapters.id, templates.id});
      expect(controller.state.activeId, templates.id);
      // resources остался вкладкой (в таб-баре), просто не в панелях.
      expect(
        controller.state.documents.map((d) => d.id),
        contains(resources.id),
      );
    });

    test('moveToPane of an already-visible doc repositions it', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final templates = EditorDocumentDescriptor.templates('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.open(templates);
      controller.focus(chapters.id);
      controller.split(resources.id); // [chapters | resources]

      // Перетащили chapters (видимая) в панель templates-... на панель
      // resources нет — берём панель chapters и меняем местами с собой? Нет:
      // дроп на центр панели resources вкладкой chapters → chapters переезжает,
      // resources уходит в таб-бар.
      expect(controller.moveToPane(chapters.id, resources.id), true);

      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {chapters.id});
      expect(controller.state.activeId, chapters.id);
    });

    test('closePane keeps the document in the tab bar', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.focus(chapters.id);
      controller.split(resources.id); // [chapters | resources]

      controller.closePane(resources.id);

      expect(controller.state.documents.length, 2); // вкладка осталась
      expect(
        controller.state.layout.paneTree,
        isNull,
      ); // одна панель → обычный режим
      expect(controller.state.activeId, chapters.id);
    });

    test('closing a visible tab prunes the pane tree', () async {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final templates = EditorDocumentDescriptor.templates('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.open(templates);
      controller.focus(chapters.id);
      controller.split(resources.id); // [chapters | resources]
      controller.split(
        templates.id,
        horizontal: false,
      ); // [[chapters | resources] / templates]

      expect(await controller.close(resources.id), true);

      final tree = controller.state.layout.paneTree!;
      expect(tree.documentIds.toSet(), {chapters.id, templates.id});
    });

    test('setSplitRatio updates and clamps the first pane share', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.focus(chapters.id);
      controller.split(resources.id);

      controller.setSplitRatio(const [], 0.3);
      var split = controller.state.layout.paneTree! as EditorDockSplit;
      expect(split.ratio, closeTo(0.3, 0.001));

      controller.setSplitRatio(const [], 0.05); // ниже минимума
      split = controller.state.layout.paneTree! as EditorDockSplit;
      expect(split.ratio, closeTo(0.15, 0.001));
    });

    test('collapsePanes returns to a single pane', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      controller.open(chapters);
      controller.open(resources);
      controller.focus(chapters.id);
      controller.split(resources.id);

      controller.collapsePanes();

      expect(controller.state.layout.paneTree, isNull);
      expect(controller.state.documents.length, 2);
    });

    test('pane tree roundtrips through layout json', () {
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final layout = EditorDockLayout(
        rootTabs: [chapters.id, resources.id],
        paneTree: EditorDockSplit(
          horizontal: true,
          ratio: 0.4,
          first: EditorDockLeaf(chapters.id),
          second: EditorDockSplit(
            horizontal: false,
            ratio: 0.6,
            first: EditorDockLeaf(resources.id),
            second: EditorDockLeaf(EditorDocumentDescriptor.templates('q1').id),
          ),
        ),
      );

      final restored = EditorDockLayout.fromJson(layout.toJson());

      expect(restored.paneTree, layout.paneTree);
    });

    group('EditorDocumentContext', () {
      testWidgets('notifies dependents when isActive changes', (tester) async {
        const id = EditorDocumentId(
          questId: 'q1',
          kind: EditorDocumentKind.game,
          key: 'simulation:root',
        );
        bool? observed;

        Widget build(bool active) => EditorDocumentContext(
          id: id,
          isActive: active,
          child: Builder(
            builder: (context) {
              observed = EditorDocumentContext.maybeOf(context)?.isActive;
              return const SizedBox.shrink();
            },
          ),
        );

        await tester.pumpWidget(build(false));
        expect(observed, false);

        await tester.pumpWidget(build(true));
        expect(observed, true);
      });
    });

    test('restore drops pane leaves without documents', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');
      final missing = EditorDocumentDescriptor.templates('q1');
      controller.open(chapters);
      controller.open(resources);

      final restored = EditorWorkspaceState(
        documents: [chapters, resources],
        activeId: chapters.id,
        layout: EditorDockLayout(
          rootTabs: [chapters.id, resources.id],
          paneTree: EditorDockSplit(
            horizontal: true,
            ratio: 0.5,
            first: EditorDockLeaf(chapters.id),
            second: EditorDockLeaf(missing.id), // нет в документах
          ),
        ),
      );

      controller.restore(restored);

      // Лист без документа отброшен, сплит схлопнулся до одной панели —
      // режим панелей выключен (обычные вкладки).
      expect(controller.state.layout.paneTree, isNull);
      expect(controller.state.activeId, chapters.id);
    });

    test('restore seeds no visit history', () {
      // Сценарий: сессия восстановила «Главы», пользователь вошёл через
      // «Ресурсы». «Назад» не должен уводить на протухшие главы.
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final resources = EditorDocumentDescriptor.resources('q1');

      controller.open(chapters);
      controller.restore(
        EditorWorkspaceState(
          documents: [chapters],
          activeId: chapters.id,
          layout: EditorDockLayout(rootTabs: [chapters.id]),
        ),
      );
      controller.open(resources);
      expect(controller.activeId, resources.id);

      expect(controller.goBack(), isFalse);
      expect(controller.activeId, resources.id);
    });

    test('goBack walks the visit history without closing tabs', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final canvas = EditorDocumentDescriptor.canvas('q1', 'tag1');
      final node = EditorDocumentDescriptor.node('q1', 'node1');

      controller.open(chapters);
      controller.open(canvas);
      controller.open(node);

      // нода → канвас → главы: вкладки остаются открытыми.
      expect(controller.goBack(), isTrue);
      expect(controller.activeId, canvas.id);
      expect(controller.contains(node.id), isTrue);

      expect(controller.goBack(), isTrue);
      expect(controller.activeId, chapters.id);

      // История исчерпана.
      expect(controller.goBack(), isFalse);
      expect(controller.activeId, chapters.id);
    });

    test('goBack reopens a tab closed via close()', () async {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final canvas = EditorDocumentDescriptor.canvas('q1', 'tag1');
      final node = EditorDocumentDescriptor.node('q1', 'node1');

      controller.open(chapters);
      controller.open(canvas);
      controller.open(node);
      await controller.close(canvas.id);

      // Закрытый крестиком канвас «Назад» переоткрывает.
      expect(controller.goBack(), isTrue);
      expect(controller.activeId, canvas.id);
      expect(controller.contains(canvas.id), isTrue);
    });

    test('goBack reopens documents through a replace chain', () {
      // Режим без табов: каждая навигация заменяет единственную вкладку.
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final canvas = EditorDocumentDescriptor.canvas('q1', 'tag1');
      final node = EditorDocumentDescriptor.node('q1', 'node1');

      controller.open(chapters);
      controller.replace(chapters.id, canvas);
      controller.replace(canvas.id, node);
      expect(controller.state.documents.length, 1);
      expect(controller.activeId, node.id);

      expect(controller.goBack(), isTrue);
      expect(controller.activeId, canvas.id);
      expect(controller.contains(canvas.id), isTrue);

      expect(controller.goBack(), isTrue);
      expect(controller.activeId, chapters.id);
    });

    test('revisiting a tab via goBack then reopening pushes fresh history', () {
      final controller = EditorWorkspaceController('q1');
      final chapters = EditorDocumentDescriptor.chapters('q1');
      final canvas = EditorDocumentDescriptor.canvas('q1', 'tag1');
      final node = EditorDocumentDescriptor.node('q1', 'node1');

      controller.open(chapters);
      controller.open(canvas);
      controller.open(node);
      controller.goBack(); // на канвасе

      // Пользователь снова открывает ноду — «Назад» ведёт на канвас.
      controller.open(node);
      expect(controller.activeId, node.id);
      expect(controller.goBack(), isTrue);
      expect(controller.activeId, canvas.id);
    });

    test('sanitized() collapses duplicate documents keeping the last', () {
      final chapters1 = EditorDocumentDescriptor.chapters('q1');
      final canvas = EditorDocumentDescriptor.canvas('q1', 'tag1');
      final chapters2 = chapters1.copyWith(title: 'Главы (новое)');

      final state = EditorWorkspaceState(
        documents: [chapters1, canvas, chapters2],
        activeId: canvas.id,
        layout: EditorDockLayout(
          rootTabs: [chapters1.id, canvas.id, chapters2.id],
        ),
      );

      final safe = state.sanitized();

      expect(safe.documents.length, 2);
      // Последнее вхождение победило — свежий заголовок.
      expect(safe.documents.first.title, 'Главы (новое)');
      // rootTabs без повторов, порядок сохранён.
      expect(safe.layout.rootTabs.length, 2);
      expect(safe.activeId, canvas.id);
    });

    test('restore deduplicates a poisoned session (5 copies of one script)',
        () {
      final controller = EditorWorkspaceController('92abb');
      final script = EditorDocumentDescriptor.visualScript('92abb', 'scr1');

      // Ровно как в отравленном файле: 7 «документов», из них скрипт ×5.
      final docs = [
        EditorDocumentDescriptor.chapters('92abb'),
        script,
        script,
        EditorDocumentDescriptor.node('92abb', 'n1'),
        script,
        script,
        script,
      ];
      final restored = EditorWorkspaceState(
        documents: docs,
        activeId: script.id,
        layout: EditorDockLayout(rootTabs: [for (final d in docs) d.id]),
      );

      controller.restore(restored);

      expect(controller.state.documents.length, 3);
      // Уникальность id — главный инвариант.
      final ids = controller.state.documents.map((d) => d.id).toSet();
      expect(ids.length, controller.state.documents.length);
      expect(controller.contains(script.id), isTrue);
    });
  });
}
