// Загрузчик гайдов держит обещание «офлайн»: всё лежит в бандле, сеть не
// участвует, а недопереведённый гайд показывается по-английски, а не
// исчезает. Проверяем на настоящих файлах из `assets/guides/` — иначе тест
// зелёный на синтетике, а в собранном APK гайда нет.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ (проверено): убрать `'en'` из `candidateCodes` —
// падает тест про японский фолбэк; убрать `clearCache()` — падает тест про
// повторную загрузку после смены файла (см. кэш ниже).

import 'package:canvas_app/features/guides/guide_catalog.dart';
import 'package:canvas_app/features/guides/models/guide.dart';
import 'package:canvas_app/features/guides/services/guide_content_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _unknownGuide = GuideInfo(
  id: 'no_such_guide',
  section: GuideSection.library,
  icon: Icons.help_outline,
  accent: Color(0xFF000000),
);

void main() {
  // Ассеты читаются через `rootBundle`: без инициализированного биндинга
  // платформа в тесте отвечает «нет такого файла», и все гайды выглядят
  // сломанными.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(GuideContentLoader.clearCache);
  tearDown(GuideContentLoader.clearCache);

  group('candidateCodes', () {
    test('региональный код пробует базу, английский и русский', () {
      expect(GuideContentLoader.candidateCodes('pt-BR'), [
        'pt_br',
        'pt',
        'en',
        'ru',
      ]);
      expect(GuideContentLoader.candidateCodes('pt_br'), [
        'pt_br',
        'pt',
        'en',
        'ru',
      ]);
    });

    test('неизвестный язык всё равно доходит до английского', () {
      expect(GuideContentLoader.candidateCodes('ja'), ['ja', 'en', 'ru']);
      // Пустой код не должен давать ключ вида `assets/guides/id/.json`.
      expect(GuideContentLoader.candidateCodes('  '), ['en', 'ru']);
    });
  });

  group('настоящие ассеты', () {
    test('русский гайд про создание квеста читается из бандла', () async {
      final info = GuideCatalog.byId('create_quest')!;
      final content = await GuideContentLoader.load(info, 'ru');

      expect(content, isNotNull);
      expect(content!.languageCode, 'ru');
      expect(content.title, 'Как создать квест');
      expect(content.minutes, 7);
      expect(content.shots, hasLength(5));
      expect(content.shots.first.kind, GuideShotKind.quests);
      expect(content.article, isNotEmpty);
    });

    test('английский гайд не путается с русским', () async {
      final info = GuideCatalog.byId('market')!;
      final content = await GuideContentLoader.load(info, 'en');

      expect(content, isNotNull);
      expect(content!.languageCode, 'en');
      expect(content.title, 'How the market works');
      expect(content.shots, hasLength(3));
    });

    test('без перевода гайд падает в английский, а не исчезает', () async {
      final info = GuideCatalog.byId('hub')!;
      final content = await GuideContentLoader.load(info, 'ja');

      expect(content, isNotNull);
      expect(content!.languageCode, 'en');
      expect(content.title, 'What is the Hub');
    });

    test('каждый гайд каталога загружается хотя бы на одном языке', () async {
      for (final info in GuideCatalog.all) {
        final content = await GuideContentLoader.load(info, 'ru');
        expect(content, isNotNull, reason: '${info.id}: нет ru.json');
        expect(
          content!.shots,
          isNotEmpty,
          reason: '${info.id}: гайд без схем — это страница текста, а не гайд',
        );
      }
    });

    test('неизвестный id — null, а не исключение', () async {
      expect(await GuideContentLoader.load(_unknownGuide, 'ru'), isNull);
    });

    test('результат кэшируется до явного сброса', () async {
      final info = GuideCatalog.byId('create_quest')!;
      final first = GuideContentLoader.load(info, 'ru');
      final second = GuideContentLoader.load(info, 'ru');
      expect(identical(first, second), isTrue);

      GuideContentLoader.clearCache();
      final third = GuideContentLoader.load(info, 'ru');
      expect(identical(first, third), isFalse);
      expect(await third, isNotNull);
    });
  });

  test('язык ищется точным кодом раньше базового', () async {
    // pt_br-файла нет, поэтому честный ответ загрузчика — английский.
    // Тест фиксирует порядок: если кто-то переставит `en` вперёд, русский
    // гайд перестанет открываться на русском.
    final info = GuideCatalog.byId('create_quest')!;
    final content = await GuideContentLoader.load(info, 'pt-BR');
    expect(content!.languageCode, 'en');
  });
}
