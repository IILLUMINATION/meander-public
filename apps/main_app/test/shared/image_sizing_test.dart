// Ширина декодирования картинок в списках.
//
// Регрессия: без `cacheWidth`/`memCacheWidth` `Image`/`CachedNetworkImage`
// декодирует исходный файл целиком (фото 12 Мп ≈ 48 МБ в куче), а в сетках это
// ещё и повторяется на каждый тайл. Правило «декодировать под размер тайла»
// проверяется здесь, без устройства.

import 'package:canvas_app/shared/widgets/image_sizing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('imageDecodeWidthFor', () {
    test('полноэкранная картинка декодируется под ширину экрана', () {
      // 1080 px × DPR 3 — обычный телефон.
      expect(imageDecodeWidthFor(1080), 1080);
    });

    test('тайл в две колонки — половина ширины', () {
      expect(imageDecodeWidthFor(1080, divisor: 2), 540);
      expect(imageDecodeWidthFor(1080, divisor: 3), 360);
    });

    test('верхний предел режет планшеты и десктоп', () {
      expect(imageDecodeWidthFor(4000), 1440);
      expect(imageDecodeWidthFor(4000, max: 900), 900);
    });

    test('нижний предел не даёт декодировать в нечитаемое', () {
      expect(imageDecodeWidthFor(120, divisor: 3), 200);
      expect(imageDecodeWidthFor(120, divisor: 3, min: 96), 96);
    });

    test('вырожденные значения не ломают счёт', () {
      expect(imageDecodeWidthFor(0), 200);
      expect(imageDecodeWidthFor(-100), 200);
      expect(imageDecodeWidthFor(double.nan), 200);
      // divisor 0 — не деление на ноль, а «как есть».
      expect(imageDecodeWidthFor(1000, divisor: 0), 1000);
    });
  });
}