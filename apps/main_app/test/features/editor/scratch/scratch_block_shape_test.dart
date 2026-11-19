import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_block_shape.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_layout.dart';

/// Грамматика Scratch: паз сверху, шип снизу, шляпа у события и C-форма у
/// контейнера. Тест держит геометрию, а не пиксели: painter только заливает
/// эти пути, поэтому форма проверяется здесь.
void main() {
  const rect = Rect.fromLTWH(0, 0, 220, 40);

  test('обычная шапка: паз сверху и шип снизу', () {
    final path = ScratchShape.head(
      rect,
      hat: false,
      topNotch: true,
      bottomTab: true,
    );

    expect(
      path.getBounds().bottom,
      closeTo(rect.bottom + ScratchMetrics.notchDepth, 0.01),
      reason: 'шип торчит за нижнюю кромку',
    );
    expect(
      path.contains(
        Offset(
          rect.left + ScratchMetrics.notchInset + ScratchMetrics.notchWidth / 2,
          rect.top + 0.5,
        ),
      ),
      isFalse,
      reason: 'середина паза вырезана',
    );
    expect(
      path.contains(Offset(rect.right - 30, rect.top + 0.5)),
      isTrue,
      reason: 'вне паза кромка залита',
    );
  });

  test('шляпа события поднимается дугой', () {
    final event = EventBlock();
    final head = Rect.fromLTWH(0, 0, 220, ScratchShape.headHeight(event));

    final path = ScratchShape.head(head, hat: true);
    expect(head.height, ScratchMetrics.headHeight + ScratchMetrics.hatRise);
    expect(path.contains(Offset(110, 1)), isTrue, reason: 'макушка шляпы');
    expect(
      path.contains(const Offset(2, 1)),
      isFalse,
      reason: 'по краям верх ниже: это дуга, а не прямоугольник',
    );
    expect(
      ScratchShape.textCenterY(head, event),
      closeTo(ScratchMetrics.hatRise + ScratchMetrics.headHeight / 2, 0.01),
    );
  });

  test('C-форма: тело вырезано, хвост и левая колонка целы', () {
    const frame = Rect.fromLTWH(0, 0, 220, 100);
    const body = Rect.fromLTRB(20, 44, 220, 88);
    final path = ScratchShape.container(frame, body);

    expect(path.contains(const Offset(100, 60)), isFalse, reason: 'тело ветки');
    expect(path.contains(const Offset(100, 20)), isTrue, reason: 'шапка');
    expect(
      path.contains(const Offset(10, 60)),
      isTrue,
      reason: 'левая колонка C-формы',
    );
    expect(
      path.contains(
        Offset(
          frame.left + ScratchMetrics.notchInset + 4,
          frame.bottom + ScratchMetrics.notchDepth / 2,
        ),
      ),
      isTrue,
      reason: 'шип под хвостом',
    );
  });
}
