// Виртуальные связи (timer/script) обязаны рисоваться пунктиром.
//
// Регрессия: батчинг «по виду связи» заменил пунктир сплошной линией, и
// скриптовые рёбра стали неотличимы от content — а на графе, где к ноде ведёт
// только скрипт, связь выглядела как её отсутствие. Этот тест смотрит на
// пиксели: сплошная связь даёт один непрерывный штрих, пунктир — серию
// коротких штрихов с разрывами.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/models/canvas_models.dart';
import 'package:canvas_app/shared/widgets/canvas_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const int _w = 900;
const int _h = 400;

/// Две ноды на одной горизонтали: связь идёт от (175, 200) к (575, 200).
CanvasState _canvas({ConnectionKind? kind}) {
  final nodes = <Node>[
    Node(
      id: 'a',
      position: const Offset(100, 200),
      label: 'A',
      description: '',
      color: const Color(0xFF26C6DA),
    ),
    Node(
      id: 'b',
      position: const Offset(700, 200),
      label: 'B',
      description: '',
      color: const Color(0xFF26C6DA),
    ),
  ];
  final connections = <Connection>[
    if (kind != null)
      Connection(
        id: 'e1',
        fromNode: nodes[0],
        toNode: nodes[1],
        kind: kind,
        isVirtual: kind != ConnectionKind.content,
      ),
  ];
  final hash = SpatialHash()..rebuild(nodes);
  return CanvasState(
    nodes: nodes,
    spatialHash: hash,
  ).copyWith(nodes: nodes, connections: connections);
}

Future<Uint8List> _render(CanvasState state) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  InfiniteCanvasPainter(
    state,
    measureFrame: false,
  ).paint(canvas, Size(_w.toDouble(), _h.toDouble()));
  final image = recorder.endRecording().toImageSync(_w, _h);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return bytes.buffer.asUint8List();
}

/// Длины непрерывных штрихов вдоль линии связи (ось X, строка y=200).
List<int> _strokeRuns(Uint8List withLink, Uint8List withoutLink) {
  final runs = <int>[];
  var current = 0;
  for (var x = 176; x < 574; x++) {
    final i = (200 * _w + x) * 4;
    final diff =
        withLink[i] != withoutLink[i] ||
        withLink[i + 1] != withoutLink[i + 1] ||
        withLink[i + 2] != withoutLink[i + 2];
    if (diff) {
      current++;
    } else if (current > 0) {
      runs.add(current);
      current = 0;
    }
  }
  if (current > 0) runs.add(current);
  return runs;
}

void main() {
  testWidgets('content-связь — непрерывная линия', (tester) async {
    await tester.runAsync(() async {
      final base = await _render(_canvas());
      final runs = _strokeRuns(
        await _render(_canvas(kind: ConnectionKind.content)),
        base,
      );

      expect(runs, isNotEmpty, reason: 'связь не нарисована');
      expect(
        runs.length,
        1,
        reason: 'у сплошной связи не должно быть разрывов',
      );
    });
  });

  for (final kind in [ConnectionKind.timer, ConnectionKind.script]) {
    testWidgets('$kind-связь — пунктир', (tester) async {
      await tester.runAsync(() async {
        final base = await _render(_canvas());
        final runs = _strokeRuns(await _render(_canvas(kind: kind)), base);

        expect(runs, isNotEmpty, reason: 'связь не нарисована');
        expect(
          runs.length,
          greaterThan(10),
          reason: 'пунктир обязан состоять из серии штрихов',
        );
        expect(
          runs.reduce((a, b) => a > b ? a : b),
          lessThan(20),
          reason: 'штрихи пунктира короткие, а не сплошная линия',
        );
      });
    });
  }
}
