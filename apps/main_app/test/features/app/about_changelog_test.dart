// Список изменений в «О приложении» — человеческий текст (#7).
//
// sekator просил changelog простыми словами, без смайлов. До этого список
// выглядел как реклама: «🔥 AES-256 Шифрование квестов…», «⚡ Real-Time…».
// Тест держит формат — чтобы в следующий раз список не скатился обратно в
// значки и капслок, потому что экран рендерит строки как есть и править
// потом приходится вёрстку.
//
// Список с тех пор живёт в коде (`about_content.dart`), а не в JSON-ассете:
// проверяем те ровно те константы, которые рендерит экран.

import 'package:canvas_app/features/app/data/about_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Пиктографы, модификаторы эмодзи и прочая значковая графика.
  final emoji = RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{1F1E6}-\u{1F1FF}]',
    unicode: true,
  );

  test('список на месте и заполнен', () {
    expect(aboutChangelog(), isNotEmpty);
    expect(aboutNotes(), isNotEmpty);
    expect(aboutDeveloperName, isNotEmpty);
  });

  test('в списке изменений нет смайлов', () {
    for (final line in aboutChangelog()) {
      expect(emoji.hasMatch(line), isFalse, reason: 'эмодзи в строке: $line');
    }
  });

  test('строки — обычные предложения, а не капслок-объявления', () {
    for (final line in aboutChangelog()) {
      expect(line.length, lessThan(400), reason: 'простыня: $line');
      final letters = line.replaceAll(RegExp('[^А-Яа-яA-Za-z]'), '');
      final upper = line.replaceAll(RegExp('[^А-ЯA-Z]'), '');
      if (letters.length > 12) {
        expect(
          upper.length / letters.length,
          lessThan(0.4),
          reason: 'кричит капслоком: $line',
        );
      }
    }
  });

  test('каждая строка — про то, что увидит человек, а не про внутренний код', () {
    // changelog читают игроки и авторы квестов.
    final internals = RegExp(
      r'\b(ffi|ff|dart:io|git|merge|rebase|CI|юнит|рефакторинг|коммит|sdk|utf-8)\b',
      caseSensitive: false,
      unicode: true,
    );
    for (final line in aboutChangelog()) {
      expect(
        internals.hasMatch(line),
        isFalse,
        reason: 'внутренняя кухня: $line',
      );
    }
  });
}
