import 'package:canvas_app/core/utils/markdown_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('markdownImageUrls', () {
    test('достает адрес картинки из тела', () {
      expect(
        markdownImageUrls(
          'вот что вышло\n![Фото](https://meander.illuminat.dev/uploads/1.jpg)\n',
        ),
        ['https://meander.illuminat.dev/uploads/1.jpg'],
      );
    });

    test('картинку не путает со ссылкой', () {
      expect(
        markdownImageUrls('[квест](https://meander.illuminat.dev/share/quest/1)'),
        isEmpty,
      );
    });
  });

  group('markdownPlainText', () {
    test('тело без картинок читается как текст', () {
      const body = '# Итог\n\n**Собрал** первую главу, багов нет';
      expect(markdownPlainText(body), 'Итог Собрал первую главу, багов нет');
    });

    test('картинка уходит из превью, адрес — в миниатюру', () {
      const body =
          '![Фото](https://meander.illuminat.dev/uploads/media/4a831d1d)\n'
          'красиво вышло';
      expect(markdownPlainText(body), 'красиво вышло');
      expect(markdownImageUrls(body), [
        'https://meander.illuminat.dev/uploads/media/4a831d1d',
      ]);
    });

    test('ссылка оставляет подпись человека, а не адрес', () {
      expect(
        markdownPlainText(
          'смотри [вот этот квест](https://meander.illuminat.dev/share/quest/1)',
        ),
        'смотри вот этот квест',
      );
    });

    test('пустое тело остаётся пустым', () {
      expect(markdownPlainText(''), isEmpty);
      expect(markdownPlainText('![Фото](https://x/y.jpg)'), isEmpty);
    });
  });
}
