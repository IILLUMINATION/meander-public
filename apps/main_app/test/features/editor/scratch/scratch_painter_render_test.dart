import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_block_shape.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_camera.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_layout.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_script_painter.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';

/// Проверка того, что painter действительно рисует силуэты, а не только
/// считает раскладку: пиксели читаются с отрисованного изображения.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const scheme = ColorScheme.light();
  const offset = Offset(20, 20);

  Future<ui.Image> render(VisualScriptBlock block) async {
    final engine = ScratchLayoutEngine();
    final layout = engine.layout([block]);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    ScratchScriptPainter(
      layout: layout,
      camera: ScratchCameraController(offset: offset),
      cache: ScratchPaintCache(),
      colorScheme: scheme,
      brightness: Brightness.light,
    ).paint(canvas, const Size(360, 260));
    return recorder.endRecording().toImage(360, 260);
  }

  Future<Color> pixelAt(ui.Image image, Offset world) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final x = (world.dx + offset.dx).floor();
    final y = (world.dy + offset.dy).floor();
    final i = (y * image.width + x) * 4;
    return Color.fromARGB(
      data!.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }

  bool same(Color a, Color b) =>
      (a.r - b.r).abs() < 0.01 &&
      (a.g - b.g).abs() < 0.01 &&
      (a.b - b.b).abs() < 0.01;

  test('событие рисуется шляпой с пазом, шипом и белой плашкой поля', () async {
    final child = DelayBlock(expression: '500');
    final event = EventBlock(children: [child]);
    final image = await render(event);

    final engine = ScratchLayoutEngine();
    final layout = engine.layout([event]);
    final head = layout.headRectOf(event.id)!;
    final childHead = layout.headRectOf(child.id)!;
    final accent = blockAccent(Brightness.light, event.category);
    final childAccent = blockAccent(Brightness.light, child.category);

    // Середина шляпы залита цветом события.
    expect(
      same(
        await pixelAt(
          image,
          Offset(head.left + 5, ScratchShape.textCenterY(head, event)),
        ),
        accent,
      ),
      isTrue,
      reason: 'корпус шляпы',
    );
    // Край шляпы ниже макушки: верх — дуга, а не прямоугольник.
    expect(
      same(await pixelAt(image, Offset(head.left + 2, head.top + 1)), accent),
      isFalse,
      reason: 'дуга шляпы не заливает угол',
    );
    // Паз сверху вырезан: в его середине цвет канваса, а не блока.
    expect(
      same(
        await pixelAt(
          image,
          Offset(
            head.left +
                ScratchMetrics.notchInset +
                ScratchMetrics.notchWidth / 2,
            head.top + 0.5,
          ),
        ),
        accent,
      ),
      isFalse,
      reason: 'паз вырезан',
    );
    // Шип под шляпой торчит ниже кромки.
    expect(
      same(
        await pixelAt(
          image,
          Offset(
            head.left + ScratchMetrics.notchInset + 4,
            head.bottom + ScratchMetrics.notchDepth / 2,
          ),
        ),
        accent,
      ),
      isTrue,
      reason: 'шип стыковки',
    );
    // Ребёнок стоит в той же колонке, его шип тоже виден.
    expect(childHead.left, head.left);
    expect(
      same(
        await pixelAt(
          image,
          Offset(
            childHead.left + ScratchMetrics.notchInset + 4,
            childHead.bottom + ScratchMetrics.notchDepth / 2,
          ),
        ),
        childAccent,
      ),
      isTrue,
      reason: 'шип ребёнка',
    );

    // Белая плашка поля: ищем белый пиксель в полосе текста ребёнка.
    final centerY = ScratchShape.textCenterY(childHead, child);
    var foundField = false;
    for (
      var x = childHead.left + ScratchMetrics.padH;
      x < childHead.right - 1;
      x += 1
    ) {
      final c = await pixelAt(image, Offset(x, centerY));
      if (same(c, Colors.white)) {
        foundField = true;
        break;
      }
    }
    expect(foundField, isTrue, reason: 'значение — белая плашка');
  });

  test('C-форма: тело ветки не залито, хвост залит', () async {
    final condition = ConditionBlock(thenBlocks: [DelayBlock()]);
    final image = await render(condition);

    final layout = ScratchLayoutEngine().layout([condition]);
    final frame = layout.frames.single;
    final accent = blockAccent(Brightness.light, condition.category);

    expect(
      same(await pixelAt(image, frame.body.center), accent),
      isFalse,
      reason: 'вырез тела',
    );
    expect(
      same(
        await pixelAt(
          image,
          Offset(frame.rect.center.dx, frame.rect.bottom - 4),
        ),
        accent,
      ),
      isTrue,
      reason: 'хвост C-формы',
    );
  });

  test('вложенные C-формы получают контрастную границу', () async {
    final condition = ConditionBlock(
      thenBlocks: [
        ConditionBlock(thenBlocks: [DelayBlock()]),
      ],
    );
    final image = await render(condition);
    final layout = ScratchLayoutEngine().layout([condition]);
    final accent = blockAccent(Brightness.light, condition.category);

    for (final frame in layout.frames) {
      final edge = await pixelAt(
        image,
        Offset(frame.rect.left + 0.25, frame.rect.top + 70),
      );
      expect(
        same(edge, accent),
        isFalse,
        reason: 'левая граница ${frame.block.id} должна быть видна',
      );
    }
  });

  testWidgets('вложенные C-формы: голден границ', (tester) async {
    final condition = ConditionBlock(
      thenBlocks: [
        ConditionBlock(thenBlocks: [DelayBlock(expression: '500')]),
      ],
    );
    final camera = ScratchCameraController(offset: offset);
    addTearDown(camera.dispose);
    final painter = ScratchScriptPainter(
      layout: ScratchLayoutEngine().layout([condition]),
      camera: camera,
      cache: ScratchPaintCache(),
      colorScheme: scheme,
      brightness: Brightness.light,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: const Key('scratch-nested-containers'),
              child: Container(
                width: 360,
                height: 260,
                color: Colors.white,
                child: CustomPaint(painter: painter),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const Key('scratch-nested-containers')),
      matchesGoldenFile('goldens/scratch_nested_containers.png'),
    );
  });
}
