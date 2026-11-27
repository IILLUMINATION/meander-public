import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/inline_image.dart';

void main() {
  test('извлекает и нормализует только пути изображений', () {
    const text =
        '[img=res/images/attack.png] '
        '[img=.\\res\\images\\fire.WEBP] '
        '[img=shield.jpg] '
        '[img=https://example.com/x.png] '
        '[img=../secret.png] '
        '[img=res/fonts/x.png] '
        '[img=res/images/readme.txt]';

    expect(extractInlineImagePaths(text), [
      'res/images/attack.png',
      'res/images/fire.WEBP',
      'shield.jpg',
    ]);
    expect(
      stripInlineImageTags(text),
      contains('[img=https://example.com/x.png]'),
    );
    expect(
      stripInlineImageTags(text),
      isNot(contains('[img=res/images/attack.png]')),
    );
  });

  test('отвергает абсолютные пути, обход каталогов и не-изображения', () {
    for (final source in [
      '/res/images/x.png',
      r'C:\res\images\x.png',
      'res/images/../config.json',
      'res/images/x.png/../../secret.png',
      'res/images/.. /secret.png',
      'res/images/.. ./secret.png',
      'res/images/.../secret.png',
      r'res\images\..\secret.png',
      'file:///res/images/x.png',
      'data:image/png;base64,AA',
      'res/audio/x.png',
      'res/images/x.svg',
      'res/images/x',
      '',
    ]) {
      expect(normalizeInlineImagePath(source), isNull, reason: source);
    }
  });

  test('тег внутри инлайн-кода не считается картинкой', () {
    const text =
        '`[img=res/images/code.png]` '
        '``[img=res/images/code2.webp]`` '
        '[img=res/images/real.png]';

    expect(
      stripInlineImageTags(text),
      '`[img=res/images/code.png]` '
      '``[img=res/images/code2.webp]`` ',
    );
  });

  test('повторяющиеся незакрытые теги не зависают и остаются текстом', () {
    final source = List<String>.filled(8000, '[img=').join();
    final stopwatch = Stopwatch()..start();

    expect(extractInlineImagePaths(source), isEmpty);
    expect(stripInlineImageTags(source), hasLength(source.length));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('длинная незакрытая кавычка не вызывает квадратичный обход', () {
    final source = List<String>.filled(100000, '`').join();
    final stopwatch = Stopwatch()..start();

    expect(stripInlineImageTags(source), source);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('общий сканер исключает картинки только внутри инлайн-кода', () {
    const text =
        '`[img=res/images/code.png]` [img=res/images/real.png] '
        '``[img=res/images/code2.webp]``';

    expect(inlineImageMatchesOutsideCode(text).map((match) => match.group(1)), [
      'res/images/real.png',
    ]);
  });

  test('инлайн-код может пересекать строку', () {
    const text =
        '`строка\n[img=res/images/code.png]\nещё` '
        '[img=res/images/real.png]';

    expect(inlineImageMatchesOutsideCode(text).map((match) => match.group(1)), [
      'res/images/real.png',
    ]);
    expect(
      stripInlineImageTags(text),
      '`строка\n[img=res/images/code.png]\nещё` ',
    );
  });

  test('вложенные backtick-прогоны не создают перекрывающиеся code span', () {
    const text =
        '`a `` ` [img=res/images/real.png] b `` [img=res/images/after.png]';

    expect(inlineImageMatchesOutsideCode(text).map((match) => match.group(1)), [
      'res/images/real.png',
      'res/images/after.png',
    ]);
  });

  test('экранированные backtick и открывающая скобка не меняют смысл тега', () {
    const text =
        r'\`[img=res/images/after-escaped-tick.png] '
        r'\[img=res/images/literal.png] [img=res/images/real.png]';

    expect(inlineImageMatchesOutsideCode(text).map((match) => match.group(1)), [
      'res/images/after-escaped-tick.png',
      'res/images/real.png',
    ]);
    expect(stripInlineImageTags(text), r'\` \[img=res/images/literal.png] ');
    expect(extractInlineImagePaths(text), [
      'res/images/after-escaped-tick.png',
      'res/images/real.png',
    ]);
  });
}
