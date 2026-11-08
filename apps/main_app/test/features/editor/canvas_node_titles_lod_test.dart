// Названия нод должны оставаться на канвасе при отдалении.
//
// Раньше `scale < 0.35` переводил холст в режим «миникарты» и ноды рисовались
// вообще без текста — большой граф превращался в набор одинаковых плашек.
// Теперь текст живёт отдельно от остальной детализации: описание, пилюли и
// якоря по-прежнему пропадают, а подписи режет только измеренная цена кадра
// (`CanvasFrameCost`), и то не до нуля.
//
// Негативный контроль: на старом коде тест «названия нод рисуются при
// отдалении» даёт 0 подписей вместо 12.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canvas_app/models/canvas_lod.dart';
import 'package:canvas_app/models/canvas_models.dart';
import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/shared/widgets/canvas_painter.dart';

/// Перехватывает, что именно художник попросил нарисовать.
class _SpyRenderer extends NodeRenderer {
  final List<String> titledNodeIds = [];
  final List<bool> showDetailsFlags = [];

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
    ui.Image? thumbnail,
  }) {
    showDetailsFlags.add(showDetails);
    // Тело ноды рисуем по-настоящему, а вот подпись считаем отдельно.
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
      thumbnail: thumbnail,
    );
  }

  @override
  void drawNodeTitle(Canvas canvas, Node node, {bool isDimmed = false}) {
    titledNodeIds.add(node.id);
  }
}

/// [count] нод в сетке 200x200 — все влезают в окно при зуме 0.2.
CanvasState canvasWithNodes(
  int count, {
  required double scale,
  Set<String> selectedNodeIds = const {},
}) {
  final nodes = <Node>[
    for (var i = 0; i < count; i++)
      Node(
        id: 'n$i',
        position: Offset(100 + (i % 10) * 200.0, 100 + (i ~/ 10) * 200.0),
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
  NodeRenderer renderer,
  CanvasFrameCost frameCost,
) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  InfiniteCanvasPainter(
    state,
    nodeRenderer: renderer,
    frameCost: frameCost,
    measureFrame: false,
  ).paint(canvas, const Size(1200, 800));
  recorder.endRecording().dispose();
}

/// Прокручивает [frames] медленных кадров, чтобы бюджет подписей успел урезаться.
CanvasFrameCost slowFrameCost(int visibleNodes, {int frames = 12}) {
  final cost = CanvasFrameCost();
  for (var i = 0; i < frames; i++) {
    cost.record(30.0, visibleNodes: visibleNodes);
  }
  return cost;
}

void main() {
  group('названия нод при отдалении', () {
    testWidgets('подписи рисуются на мелком зуме', (tester) async {
      final spy = _SpyRenderer();
      paintOnce(canvasWithNodes(12, scale: 0.2), spy, CanvasFrameCost());

      expect(spy.titledNodeIds, hasLength(12));
    });

    testWidgets('детали при отдалении по-прежнему пропадают', (tester) async {
      final spy = _SpyRenderer();
      paintOnce(canvasWithNodes(4, scale: 0.2), spy, CanvasFrameCost());

      expect(spy.showDetailsFlags, isNotEmpty);
      expect(spy.showDetailsFlags.every((flag) => flag == false), isTrue);
    });

    testWidgets('при обычном зуме детали рисуются', (tester) async {
      final spy = _SpyRenderer();
      paintOnce(canvasWithNodes(4, scale: 1.0), spy, CanvasFrameCost());

      expect(spy.showDetailsFlags.every((flag) => flag == true), isTrue);
      expect(spy.titledNodeIds, hasLength(4));
    });

    testWidgets('медленный кадр режет подписи, но щадит выбранные ноды', (
      tester,
    ) async {
      const total = 60;
      final cost = slowFrameCost(total);
      final spy = _SpyRenderer();
      paintOnce(
        canvasWithNodes(total, scale: 0.2, selectedNodeIds: {'n59'}),
        spy,
        cost,
      );

      expect(
        spy.titledNodeIds.length,
        lessThan(total),
        reason: 'медленный кадр обязан сократить число подписей',
      );
      expect(
        spy.titledNodeIds.length,
        greaterThanOrEqualTo(CanvasLod.minTitleBudget),
      );
      expect(spy.titledNodeIds.first, 'n59');
    });

    testWidgets('быстрые кадры возвращают подписи всем нодам', (tester) async {
      const total = 30;
      final cost = CanvasFrameCost();
      for (var i = 0; i < 12; i++) {
        cost.record(1.0, visibleNodes: total);
      }
      final spy = _SpyRenderer();
      paintOnce(canvasWithNodes(total, scale: 0.2), spy, cost);

      expect(spy.titledNodeIds, hasLength(total));
    });
  });

  group('CanvasFrameCost', () {
    test('пока кадр не измерен, подписей не ограничиваем', () {
      final cost = CanvasFrameCost();
      expect(cost.budgetFor(200), 200);
    });

    test('быстрый кадр не ограничивает', () {
      final cost = CanvasFrameCost();
      for (var i = 0; i < 10; i++) {
        cost.record(2.0, visibleNodes: 200);
      }
      expect(cost.budgetFor(200), 200);
    });

    test('медленный кадр урезает, но не в ноль', () {
      final cost = CanvasFrameCost();
      for (var i = 0; i < 30; i++) {
        cost.record(40.0, visibleNodes: 200);
      }
      expect(cost.budgetFor(200), lessThan(200));
      expect(
        cost.budgetFor(200),
        greaterThanOrEqualTo(CanvasLod.minTitleBudget),
      );
    });

    test('бюджет стабилен: не скачет при одинаковых кадрах', () {
      final cost = CanvasFrameCost();
      for (var i = 0; i < 20; i++) {
        cost.record(20.0, visibleNodes: 500);
      }
      final before = cost.budgetFor(500);
      for (var i = 0; i < 20; i++) {
        cost.record(20.0, visibleNodes: 500);
      }
      expect(cost.budgetFor(500), before);
    });

    test('бюджет никогда не больше числа видимых нод', () {
      final cost = CanvasFrameCost();
      for (var i = 0; i < 10; i++) {
        cost.record(40.0, visibleNodes: 300);
      }
      // Затем нодам стало тесно: бюджет обязан сжиматься под новый экран.
      expect(cost.budgetFor(5), lessThanOrEqualTo(5));
    });

    test('после урезания запас по времени возвращает подписи постепенно', () {
      final cost = CanvasFrameCost();
      for (var i = 0; i < 20; i++) {
        cost.record(30.0, visibleNodes: 400);
      }
      final clipped = cost.budgetFor(400);
      // Один быстрый кадр ничего не возвращает — это гистерезис, а не баг:
      // иначе бюджет гулял бы вверх-вниз на каждом кадре.
      cost.record(1.0, visibleNodes: 400);
      expect(cost.budgetFor(400), clipped);
      for (var i = 0; i < 10; i++) {
        cost.record(1.0, visibleNodes: 400);
      }
      expect(cost.budgetFor(400), greaterThan(clipped));
      // И при стабильно лёгком канвасе ограничение снимается полностью.
      for (var i = 0; i < 40; i++) {
        cost.record(1.0, visibleNodes: 400);
      }
      expect(cost.budgetFor(400), 400);
    });
  });

  group('CanvasLod.showDetails', () {
    test('порог 0.35', () {
      expect(CanvasLod.showDetails(0.34), isFalse);
      expect(CanvasLod.showDetails(0.35), isTrue);
      expect(CanvasLod.showDetails(1.0), isTrue);
    });
  });
}
