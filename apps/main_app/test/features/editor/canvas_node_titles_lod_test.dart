// Детализация канваса и переиспользование кадра ноды.
//
// Тела карточек прячутся по числу видимых нод, а не по измеренной цене
// кадра: решения «по времени того же кадра» гуляли на границе (замер давал
// 14 переключений за 120 кадров). После скрытия тело возвращается только
// когда нод в кадре стало заметно меньше — гистерезис.
//
// Подписи рисуются всем видимым нодам: они записаны в пикчи, поэтому
// «подписать всё» больше не стоит кадра.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canvas_app/models/canvas_lod.dart';
import 'package:canvas_app/models/canvas_models.dart';
import 'package:canvas_app/models/canvas_picture_cache.dart';
import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/shared/widgets/canvas_painter.dart';

/// Считает, что именно художник попросили нарисовать.
class _SpyRenderer extends NodeRenderer {
  final List<String> titledNodeIds = [];
  final List<bool> showDetailsFlags = [];
  int bodyCalls = 0;
  int titleCalls = 0;

  @override
  void drawNode(
    Canvas canvas,
    Node node, {
    required bool isSelected,
    required bool isHovered,
    required bool isConnectionStart,
    required bool isConnectionTarget,
    required bool isConnectionMode,
    required List<Connection> allConnections,
    bool isDimmed = false,
    bool hasValidationIssue = false,
    bool showDetails = true,
  }) {
    bodyCalls++;
    showDetailsFlags.add(showDetails);
    super.drawNode(
      canvas,
      node,
      isSelected: isSelected,
      isHovered: isHovered,
      isConnectionStart: isConnectionStart,
      isConnectionTarget: isConnectionTarget,
      isConnectionMode: isConnectionMode,
      allConnections: allConnections,
      isDimmed: isDimmed,
      hasValidationIssue: hasValidationIssue,
      showDetails: showDetails,
    );
  }

  @override
  void drawNodeTitle(Canvas canvas, Node node, {bool isDimmed = false}) {
    titleCalls++;
    titledNodeIds.add(node.id);
    super.drawNodeTitle(canvas, node, isDimmed: isDimmed);
  }
}

/// [count] нод в сетке 200x200 — все влезают в окно при зуме 0.2.
CanvasState canvasWithNodes(
  int count, {
  required double scale,
  int columns = 10,
  Set<String> selectedNodeIds = const {},
}) {
  final nodes = <Node>[
    for (var i = 0; i < count; i++)
      Node(
        id: 'n$i',
        position: Offset(
          100 + (i % columns) * 200.0,
          100 + (i ~/ columns) * 200.0,
        ),
        color: const Color(0xFF26C6DA),
        label: 'Нода $i',
        description: 'описание $i',
      ),
  ];
  final hash = SpatialHash();
  hash.rebuild(nodes);
  return CanvasState(
    nodes: nodes,
    spatialHash: hash,
    scale: scale,
    selectedNodeIds: selectedNodeIds,
  );
}

void paintOnce(
  CanvasState state,
  NodeRenderer renderer, {
  CanvasLodState? lod,
  CanvasNodePictureCache? pictures,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  InfiniteCanvasPainter(
    state,
    nodeRenderer: renderer,
    lod: lod,
    nodePictures: pictures,
  ).paint(canvas, const Size(1200, 800));
  recorder.endRecording().dispose();
}

void main() {
  group('детализация по числу нод', () {
    test('решает по числу нод, а не по зуму', () {
      final state = CanvasLodState();
      expect(state.detailsFor(1), isTrue);
      expect(state.detailsFor(CanvasLod.detailsMaxVisibleNodes), isTrue);
      expect(state.detailsFor(CanvasLod.detailsMaxVisibleNodes + 1), isFalse);
    });

    test('тело возвращается только ниже порога возврата', () {
      final state = CanvasLodState();
      expect(state.detailsFor(CanvasLod.detailsMaxVisibleNodes + 10), isFalse);
      // Мёртвая зона: между порогами решение не меняется, иначе на границе
      // тела карточек мигали бы на каждом кадре.
      expect(state.detailsFor(CanvasLod.detailsMaxVisibleNodes), isFalse);
      expect(state.detailsFor(CanvasLod.detailsRestoreBelowNodes), isFalse);
      expect(state.detailsFor(CanvasLod.detailsRestoreBelowNodes - 1), isTrue);
    });

    testWidgets('подписи рисуются на мелком зуме', (tester) async {
      final spy = _SpyRenderer();
      paintOnce(canvasWithNodes(12, scale: 0.2), spy);

      expect(spy.titledNodeIds, hasLength(12));
    });

    testWidgets('детали остаются при отдалении', (tester) async {
      final spy = _SpyRenderer();
      paintOnce(canvasWithNodes(4, scale: 0.2), spy);

      expect(spy.showDetailsFlags, isNotEmpty);
      expect(
        spy.showDetailsFlags.every((flag) => flag == true),
        isTrue,
        reason: 'масштаб сам по себе не повод убирать текст с карточек',
      );
    });

    testWidgets('тело прячется, когда в кадре слишком много нод', (
      tester,
    ) async {
      final spy = _SpyRenderer();
      paintOnce(
        canvasWithNodes(
          CanvasLod.detailsMaxVisibleNodes + 30,
          scale: 0.2,
          columns: 30,
        ),
        spy,
      );

      expect(spy.showDetailsFlags, isNotEmpty);
      expect(spy.showDetailsFlags.every((flag) => flag == false), isTrue);
      expect(
        spy.titledNodeIds,
        hasLength(CanvasLod.detailsMaxVisibleNodes + 30),
        reason: 'подписи при обзоре остаются у всех видимых нод',
      );
    });
  });

  group('пикчи нод', () {
    testWidgets('второй кадр не перерисовывает ноды', (tester) async {
      final spy = _SpyRenderer();
      final pictures = CanvasNodePictureCache();
      final state = canvasWithNodes(20, scale: 0.2);

      paintOnce(state, spy, pictures: pictures);
      final afterFirst = spy.bodyCalls;
      final titlesAfterFirst = spy.titleCalls;
      expect(afterFirst, 20);
      expect(titlesAfterFirst, 20);

      paintOnce(state, spy, pictures: pictures);
      expect(spy.bodyCalls, afterFirst, reason: 'ноды не менялись');
      expect(spy.titleCalls, titlesAfterFirst);
    });

    testWidgets('сдвиг ноды перерисовывает только её', (tester) async {
      final spy = _SpyRenderer();
      final pictures = CanvasNodePictureCache();
      final state = canvasWithNodes(20, scale: 0.2);
      paintOnce(state, spy, pictures: pictures);
      final before = spy.bodyCalls;

      state.nodes[7].position = state.nodes[7].position + const Offset(40, 0);
      state.spatialHash.rebuild(state.nodes);
      paintOnce(state, spy, pictures: pictures);

      expect(spy.bodyCalls - before, 1);
      expect(
        spy.titledNodeIds.last,
        'n7',
        reason: 'подпись едет вместе с нодой',
      );
    });

    testWidgets('выделение перерисовывает ноду', (tester) async {
      final spy = _SpyRenderer();
      final pictures = CanvasNodePictureCache();
      final base = canvasWithNodes(5, scale: 0.2);
      paintOnce(base, spy, pictures: pictures);
      final before = spy.bodyCalls;

      paintOnce(
        canvasWithNodes(5, scale: 0.2, selectedNodeIds: {'n3'}),
        spy,
        pictures: pictures,
      );

      expect(spy.bodyCalls - before, 1);
    });

    test('ревизия палитры растёт только при смене темы', () {
      final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF00796B));
      CanvasTheme.update(scheme);
      final once = CanvasTheme.revision;
      // Экран холста зовёт update на каждой перестройке: повтор с той же
      // схемой не должен выбрасывать кеш пикч.
      CanvasTheme.update(scheme);
      CanvasTheme.update(scheme);
      expect(CanvasTheme.revision, once);

      CanvasTheme.update(
        ColorScheme.fromSeed(seedColor: const Color(0xFFB00020)),
      );
      expect(CanvasTheme.revision, greaterThan(once));
    });

    test('кеш не растёт без границы', () {
      final cache = CanvasNodePictureCache(maxEntries: 2);
      for (var i = 0; i < 5; i++) {
        cache.body('n$i', i, (canvas) {
          canvas.drawRect(const Rect.fromLTWH(0, 0, 10, 10), Paint());
        });
        cache.retainOnly({'n$i'});
      }
      expect(cache.length, lessThanOrEqualTo(2));
    });

    testWidgets('смена темы выбрасывает кеш', (tester) async {
      final spy = _SpyRenderer();
      final pictures = CanvasNodePictureCache();
      final state = canvasWithNodes(6, scale: 0.2);
      paintOnce(state, spy, pictures: pictures);
      final before = spy.bodyCalls;

      CanvasTheme.revision++;
      paintOnce(state, spy, pictures: pictures);

      expect(spy.bodyCalls - before, 6);
    });
  });
}
