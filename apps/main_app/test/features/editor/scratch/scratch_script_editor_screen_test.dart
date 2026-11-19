import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_layout.dart';
import 'package:canvas_app/features/editor/workspace/script_document_store.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_script_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_script_painter.dart';

/// Экран канваса открывается на реальном файле скрипта и рисует дерево
/// painter'ом. Тест держит контракт «файл прочитан → блоки на канвасе», а не
/// пиксели: раскладка проверена отдельно.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;
  const questId = 'scratch-smoke-quest';
  const scriptId = 'intro';

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_scratch_smoke');
    FileStorage.overrideAppDirectory(appDir);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ScriptDocumentStore.resetQueuesForTest();
    final file = File(
      '${appDir.path}/${QuestPaths.scriptFile(questId, '$scriptId.json')}',
    );
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    file.writeAsStringSync('''
{
  "id": "$scriptId",
  "name": "Вступление",
  "blocks": [
    {
      "type": "event",
      "id": "event-1",
      "eventType": "onNodeEnter",
      "children": [
        {"type": "wait", "id": "wait-1", "expression": "500"}
      ]
    }
  ]
}
''');
  });

  tearDown(() {
    FileStorage.invalidateJsonCache([
      QuestPaths.scriptFile(questId, '$scriptId.json'),
    ]);
  });

  tearDownAll(() async {
    FileStorage.overrideAppDirectory(null);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  testWidgets('открывает скрипт и раскладывает блоки', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ScratchScriptEditorScreen(questId: questId, scriptId: scriptId),
      ),
    );
    await _letDiskRead(tester);

    expect(find.text('Вступление'), findsOneWidget);
    expect(find.text('Скрипт пуст'), findsNothing);

    final canvas = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((c) => c.painter is ScratchScriptPainter)
        .toList();
    expect(canvas, hasLength(1));

    final painter = canvas.single.painter! as ScratchScriptPainter;
    expect(painter.layout.rows.length, greaterThanOrEqualTo(2));
    expect(
      painter.layout.rows.map((r) => r.block.id),
      containsAll(<String>['event-1', 'wait-1']),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('пустой скрипт показывает приглашение', (tester) async {
    const emptyScriptId = 'empty';
    final file = File(
      '${appDir.path}/${QuestPaths.scriptFile(questId, '$emptyScriptId.json')}',
    );
    file.writeAsStringSync(
      '{"id": "$emptyScriptId", "name": "", "blocks": []}',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: ScratchScriptEditorScreen(
          questId: questId,
          scriptId: emptyScriptId,
        ),
      ),
    );
    await _letDiskRead(tester);

    expect(find.text('Скрипт пуст'), findsOneWidget);
    expect(find.text('Добавить событие'), findsOneWidget);

    FileStorage.invalidateJsonCache([
      QuestPaths.scriptFile(questId, '$emptyScriptId.json'),
    ]);
  });

  testWidgets('событие добавляется кнопкой и при непустом скрипте', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ScratchScriptEditorScreen(questId: questId, scriptId: scriptId),
      ),
    );
    await _letDiskRead(tester);
    await tester.pumpAndSettle();

    final before = _painter(tester).layout;
    final headsBefore = before.rows
        .where((r) => r.kind == ScratchRowKind.head)
        .map((r) => r.block.id)
        .toSet();

    await tester.tap(find.byTooltip('Добавить событие'));
    await tester.pump();

    final after = _painter(tester).layout;
    final headsAfter = after.rows
        .where((r) => r.kind == ScratchRowKind.head)
        .map((r) => r.block.id)
        .toSet();
    expect(headsAfter.length, headsBefore.length + 1);
    final added = headsAfter.difference(headsBefore).single;
    // Новое событие — отдельный стек: у него есть своя шляпа и зона броска
    // под ней (фрейма у события нет, это не C-форма).
    expect(after.headRectOf(added), isNotNull);
    expect(after.slots.any((s) => s.key == '$added:0'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('панель выделения не пересекается с FAB', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ScratchScriptEditorScreen(questId: questId, scriptId: scriptId),
      ),
    );
    await _letDiskRead(tester);
    await tester.pumpAndSettle();

    final painter = _painter(tester);
    final head = painter.layout.rows.firstWhere(
      (r) => r.kind == ScratchRowKind.head,
    );
    await tester.tapAt(_globalOf(tester, painter, head.rect.center));
    // Одиночный тап ждёт таймаут двойного (300 мс), иначе выделения не будет.
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byTooltip('Изменить'), findsOneWidget);
    final bar = tester.getRect(
      find.ancestor(of: find.byTooltip('Изменить'), matching: find.byType(Card)),
    );
    final fab = tester.getRect(
      find.ancestor(
        of: find.text('Блок'),
        matching: find.byType(FloatingActionButton),
      ),
    );
    expect(bar.overlaps(fab), isFalse, reason: 'панель лежит под кнопкой +');
  });

  testWidgets('блок остаётся там, куда его бросили', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ScratchScriptEditorScreen(questId: questId, scriptId: scriptId),
      ),
    );
    await _letDiskRead(tester);
    await tester.pumpAndSettle();

    final painter = _painter(tester);
    final head = painter.layout.rows.firstWhere(
      (r) => r.kind == ScratchRowKind.head,
    );
    final start = _globalOf(tester, painter, head.rect.center);
    // Экранная дельта переводится в мировую делителем масштаба.
    final delta = const Offset(180, 160) / painter.camera.scale;
    final expected = head.rect.topLeft + delta;

    await tester.dragFrom(start, const Offset(180, 160));
    await tester.pump(const Duration(milliseconds: 100));

    final moved = _painter(
      tester,
    ).layout.rows.firstWhere((r) => r.block.id == head.block.id);
    // Схватили за середину шапки: верхний левый угол уезжает на ту же дельту.
    expect(moved.rect.topLeft.dx, closeTo(expected.dx, 1.5));
    expect(moved.rect.topLeft.dy, closeTo(expected.dy, 1.5));

    // Автосейв — таймер на 1 с: сначала кадр через него, потом настоящий диск.
    await tester.pump(const Duration(milliseconds: 1200));
    final file = File(
      '${appDir.path}/${QuestPaths.scriptFile(questId, '$scriptId.json')}',
    );
    var saved = '';
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      saved = file.readAsStringSync();
      if (saved.contains('"layout"')) break;
    }
    expect(saved, contains('"layout"'));
    expect(saved, contains(head.block.id));
  });

  testWidgets(
    'бросок в ветку вкладывает блок, бросок в пустоту — возвращает в корень',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScratchScriptEditorScreen(questId: questId, scriptId: scriptId),
        ),
      );
      await _letDiskRead(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Добавить событие'));
      await tester.pump();

      final painter = _painter(tester);
      final eventHead = painter.layout.rows.firstWhere(
        (r) => r.kind == ScratchRowKind.head && r.block.id == 'event-1',
      );
      final added = painter.layout.rows.lastWhere(
        (r) => r.kind == ScratchRowKind.head,
        orElse: () => throw StateError('новое событие не разложено'),
      );
      expect(added.block.id, isNot('event-1'));

      final slot = painter.layout.slots.firstWhere((s) => s.key == 'event-1:0');
      final start = _globalOf(tester, painter, added.rect.center);
      final drop = _globalOf(tester, painter, slot.rect.center);
      await tester.dragFrom(start, drop - start);
      await tester.pump(const Duration(milliseconds: 100));

      final nested = _painter(tester).layout.rows.firstWhere(
        (r) => r.kind == ScratchRowKind.head && r.block.id == added.block.id,
      );
      expect(nested.depth, greaterThan(0), reason: 'блок должен лечь в ветку');

      // Теперь обратно: из ветки в пустое место справа-снизу.
      final nestedPic = _painter(tester);
      final visible = nestedPic.camera.visibleWorldRect(
        _canvasRect(tester).size,
      );
      final freeWorld = visible.bottomRight - const Offset(40, 40);
      expect(nestedPic.layout.blockAt(freeWorld), isNull);
      final from = _globalOf(tester, nestedPic, nested.rect.center);
      final to = _globalOf(tester, nestedPic, freeWorld);
      await tester.dragFrom(from, to - from);
      await tester.pump(const Duration(milliseconds: 100));

      final freed = _painter(tester).layout.rows.firstWhere(
        (r) => r.kind == ScratchRowKind.head && r.block.id == added.block.id,
      );
      expect(freed.depth, 0, reason: 'бросок в пустоту делает блок корнем');
      expect(eventHead.block.id, 'event-1');
    },
  );
}

ScratchScriptPainter _painter(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((c) => c.painter is ScratchScriptPainter);
  return paint.painter! as ScratchScriptPainter;
}

/// Экранная точка канваса → глобальная: жесты идут в глобальных координатах.
Offset _globalOf(
  WidgetTester tester,
  ScratchScriptPainter painter,
  Offset world,
) {
  return _canvasRect(tester).topLeft + painter.camera.worldToScreen(world);
}

Rect _canvasRect(WidgetTester tester) => tester.getRect(
  find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is ScratchScriptPainter,
  ),
);

/// Дождаться настоящего диска: `pumpAndSettle` ждёт только кадры, а чтение
/// файла идёт в реальном времени, и пока идёт загрузка, индикатор крутится —
/// то есть кадры не заканчиваются никогда.
Future<void> _letDiskRead(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (find.text('Вступление').evaluate().isNotEmpty ||
        find.text('Скрипт пуст').evaluate().isNotEmpty) {
      return;
    }
  }
}
