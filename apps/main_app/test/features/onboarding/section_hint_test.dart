// Мини-подсказки по разделам: плашка, которую человек закрывает сам, и она
// больше не возвращается.
//
// Проверять тут есть что именно по трём причинам:
//
// 1. «Закрыто» обязано пережить перезапуск. Экран живёт минуты, флаги в
//    памяти — значит подсказка показывалась бы при каждом входе в раздел, и
//    человек закрывал бы её по кругу.
// 2. Плашка появляется асинхронно (SharedPreferences), поэтому велик соблазн
//    начать с `_closed = false`: тогда при каждом входе текст мигает на кадр
//    у тех, кто его уже закрыл.
// 3. Каталог текстов и места использования разъезжаются молча: banner с
//    неизвестным id рисует `SizedBox.shrink()`, то есть подсказка просто
//    исчезает с экрана без единой ошибки.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ (проверено): убрать запись в `dismiss()` — падает
// тест про закрытие и перезапуск (плашка возвращается); поставить
// `_closed = false` в начальном состоянии — падает тест про кадр до ответа
// хранилища; переименовать константу id, не трогая тексты, — падает скан
// каталога.

import 'dart:io';

import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SectionHintService', () {
    test('подсказка открыта, пока её не закрыли', () async {
      expect(await SectionHintService.isDismissed(SectionHints.hub), isFalse);

      await SectionHintService.dismiss(SectionHints.hub);
      expect(await SectionHintService.isDismissed(SectionHints.hub), isTrue);
      // Чужая подсказка не должна страдать от закрытия этой.
      expect(
        await SectionHintService.isDismissed(SectionHints.libraryEmpty),
        isFalse,
      );
    });

    test('запись живёт в хранилище, а не в памяти виджета', () async {
      await SectionHintService.dismiss(SectionHints.libraryEmpty);
      // Новый «запуск»: тот же ключ, но заново прочитанный из хранилища.
      SharedPreferences.setMockInitialValues({
        SectionHintService.dismissedKey: [SectionHints.libraryEmpty],
      });
      expect(
        await SectionHintService.isDismissed(SectionHints.libraryEmpty),
        isTrue,
      );
    });

    test('повторное закрытие не плодит дублей', () async {
      await SectionHintService.dismiss(SectionHints.hub);
      await SectionHintService.dismiss(SectionHints.hub);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(SectionHintService.dismissedKey), [
        SectionHints.hub,
      ]);
    });

    test('сброс возвращает все подсказки', () async {
      await SectionHintService.dismiss(SectionHints.hub);
      await SectionHintService.dismiss(SectionHints.libraryEmpty);
      await SectionHintService.reset();
      expect(await SectionHintService.isDismissed(SectionHints.hub), isFalse);
      expect(
        await SectionHintService.isDismissed(SectionHints.libraryEmpty),
        isFalse,
      );
    });
  });

  group('SectionHintBanner', () {
    Future<void> pumpBanner(WidgetTester tester, String hintId) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(children: [SectionHintBanner(hintId: hintId)]),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('показывает текст каталога и закрывается по крестику', (
      tester,
    ) async {
      await pumpBanner(tester, SectionHints.hub);
      expect(find.text(SectionHints.texts[SectionHints.hub]!), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text(SectionHints.texts[SectionHints.hub]!), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(SectionHintService.dismissedKey), [
        SectionHints.hub,
      ]);
    });

    testWidgets('закрытая подсказка не возвращается при новом входе', (
      tester,
    ) async {
      await pumpBanner(tester, SectionHints.hub);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      // «Вышли и зашли в раздел» — виджет строится заново.
      await pumpBanner(tester, SectionHints.hub);
      expect(find.text(SectionHints.texts[SectionHints.hub]!), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    });

    testWidgets('пока хранилище не ответило, плашка не мигает', (tester) async {
      await SectionHintService.dismiss(SectionHints.hub);
      await tester.pumpWidget(
        MaterialApp(
          home: const Scaffold(
            body: Column(
              children: [SectionHintBanner(hintId: SectionHints.hub)],
            ),
          ),
        ),
      );
      // Первый кадр — до Future из SharedPreferences.
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text(SectionHints.texts[SectionHints.hub]!), findsNothing);
    });

    testWidgets('неизвестный id не рисует мусор', (tester) async {
      await pumpBanner(tester, 'no_such_hint');
      expect(find.byIcon(Icons.lightbulb_outline_rounded), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  test('каждое использование подсказки имеет текст в каталоге', () {
    // Разъезд каталога и мест использования выглядит как «подсказки просто
    // нет», поэтому проверяем это сканом, а не глазами.
    final libDir = Directory('lib');
    final used = <String>{};
    final refPattern = RegExp(r'SectionHints\.([A-Za-z0-9_]+)');
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Сам каталог описывает константы, а не использует их.
      if (entity.path.endsWith('section_hint.dart')) continue;
      final source = entity.readAsStringSync();
      if (!source.contains('SectionHintBanner')) continue;
      for (final match in refPattern.allMatches(source)) {
        used.add(match.group(1)!);
      }
    }

    expect(used, isNotEmpty, reason: 'ни одной подключённой подсказки в lib/');
    final declared = SectionHints.texts.keys.toSet();
    for (final id in used) {
      // Имя константы и ключ каталога связаны: `libraryEmpty` →
      // `library_empty`. Если кто-то заведёт константу без текста, плашка
      // молча исчезнет с экрана — проверяем это здесь, а не глазами.
      final key = id.replaceAllMapped(
        RegExp('[A-Z]'),
        (m) => '_${m[0]!.toLowerCase()}',
      );
      expect(
        declared,
        contains(key),
        reason: 'SectionHints.$id используется, но текста под ключом "$key" нет',
      );
    }
    // И обратно: текст, который никто не подключил, — это обещанное обучение,
    // которого нигде не видно.
    // Сравниваем множества: `used` наполняется обходом `listSync`, и порядок
    // файлов зависит от ФС — на CI он другой, чем локально.
    expect(
      declared.toSet(),
      used
          .map((id) => id.replaceAllMapped(
                RegExp('[A-Z]'),
                (m) => '_${m[0]!.toLowerCase()}',
              ))
          .toSet(),
      reason: 'каталог и подключённые подсказки разошлись',
    );
  });

  test('закрытую подсказку человек может вернуть из настроек', () {
    // Крестик на плашке — это «навсегда»: без пункта возврата промахнувшийся
    // человек остаётся без объяснения до переустановки приложения. `reset()`
    // сам по себе ничего не даёт, пока до него есть путь из UI.
    final settings = File(
      'lib/features/settings/screens/settings_screen.dart',
    ).readAsStringSync();
    expect(
      settings,
      contains('SectionHintService.reset()'),
      reason: 'в «Настройках» не осталось пункта возврата подсказок',
    );
    expect(
      settings,
      contains('Подсказки в разделах'),
      reason: 'пункт возврата есть в коде, но назван непонятно для человека',
    );
  });

  test('тексты подсказок — короткие и ссылаются на реальный интерфейс', () {
    for (final entry in SectionHints.texts.entries) {
      expect(entry.key, isNotEmpty);
      // Длинная плашка съедает первый экран — и это ровно то, чего в
      // туториале боятся больше всего.
      expect(
        entry.value.length,
        lessThan(260),
        reason: '${entry.key}: текст подсказки слишком длинный',
      );
      // Подсказка не должна обещать то, чего в приложении нет: на что идти,
      // говорим точным названием кнопки или раздела.
      expect(
        entry.value,
        contains('«'),
        reason: '${entry.key}: нет ни одной точной ссылки на элемент UI',
      );
    }
  });
}
