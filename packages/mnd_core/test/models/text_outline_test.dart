// Единый источник решений об обводке текста: толщина, кисть и кольцо
// смещений для теневых рендереров. Тесты держат контракт, который используют
// плеер, редактор, редактор стека, web-плеер и экспорт в HTML.

import 'dart:ui' show Color, Offset, PaintingStyle, StrokeCap, StrokeJoin;

import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/text_outline.dart';

const _blue = Color(0xFF0000FF);

void main() {
  group('толщина', () {
    test('без значения — дефолт', () {
      expect(normalizeTextOutlineWidth(null), kTextOutlineWidthDefault);
    });

    test('вне диапазона — крайние значения', () {
      expect(normalizeTextOutlineWidth(0.1), kTextOutlineWidthMin);
      expect(normalizeTextOutlineWidth(50), kTextOutlineWidthMax);
    });

    test('внутри диапазона — как есть', () {
      expect(normalizeTextOutlineWidth(3.5), 3.5);
    });
  });

  group('штриховая кисть', () {
    test('штрих со скруглёнными стыками и точной толщиной', () {
      final paint = textOutlineStroke(_blue, width: 4);
      expect(paint.style, PaintingStyle.stroke);
      expect(paint.color, _blue);
      expect(paint.strokeWidth, 4.0);
      // Miter на острых стыках глифа даёт шипы, butt — рваные концы.
      expect(paint.strokeJoin, StrokeJoin.round);
      expect(paint.strokeCap, StrokeCap.round);
      expect(paint.isAntiAlias, isTrue);
    });

    test('кисть нормирует толщину сама', () {
      expect(
        textOutlineStroke(_blue, width: 99).strokeWidth,
        kTextOutlineWidthMax,
      );
      expect(textOutlineStroke(_blue).strokeWidth, kTextOutlineWidthDefault);
    });

    test('прозрачный штрих действительно прозрачен', () {
      expect(transparentTextOutlineStroke.color.a, 0);
      expect(transparentTextOutlineStroke.style, PaintingStyle.stroke);
    });
  });

  group('кольцо смещений для теневых рендереров', () {
    test('восемь направлений без центральной копии', () {
      final offsets = textOutlineShadowOffsets(width: 4);
      expect(offsets, hasLength(8));
      expect(offsets, isNot(contains(Offset.zero)));
    });

    test('смещения — на полтолщины, кольцо симметрично', () {
      final offsets = textOutlineShadowOffsets(width: 6);
      for (final offset in offsets) {
        expect(offset.dx.abs(), anyOf(0.0, 3.0));
        expect(offset.dy.abs(), anyOf(0.0, 3.0));
        expect(offsets, contains(Offset(-offset.dx, -offset.dy)));
      }
    });

    test('толщина нормируется и здесь', () {
      expect(
        textOutlineShadowOffsets(
          width: 99,
        ).map((o) => o.dx).reduce((a, b) => a.abs() > b.abs() ? a : b),
        kTextOutlineWidthMax / 2,
      );
      expect(
        textOutlineShadowOffsets().first.distance,
        closeTo(kTextOutlineWidthDefault / 2 * 1.4142, 0.01),
      );
    });

    test('тени повторяют кольцо и не размываются', () {
      final shadows = textOutlineShadows(_blue, width: 4);
      expect(shadows, hasLength(8));
      expect(shadows.every((s) => s.color == _blue), isTrue);
      expect(shadows.every((s) => s.blurRadius == 0), isTrue);
      expect(
        shadows.map((s) => s.offset).toList(),
        textOutlineShadowOffsets(width: 4),
      );
    });
  });

  group('разметка', () {
    test('тег без толщины и с толщиной', () {
      expect(hasInlineOutline('[outline=#FF0000]текст[/outline]'), isTrue);
      expect(hasInlineOutline('[outline=#FF0000:3.5]текст[/outline]'), isTrue);
      expect(hasInlineOutline('обычный текст'), isFalse);
    });

    test('шаблон захватывает цвет, толщину и содержимое', () {
      final match = inlineOutlineTag.firstMatch(
        'до [outline=#00FF0080:2.5]внутри[/outline] после',
      )!;
      expect(match.group(1), '#00FF0080');
      expect(match.group(2), '2.5');
      expect(match.group(3), 'внутри');
    });

    test('содержимое может быть многострочным', () {
      expect(
        hasInlineOutline('[outline=#FF0000]первая\nвторая[/outline]'),
        isTrue,
      );
    });
  });
}
