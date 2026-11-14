// Языковой порядок в маркете (#331).
//
// Игроку интересны в первую очередь квесты на его языке. Правило «совпал —
// подняли, остальные — как шли» проверяется здесь, потому что список в
// провайдере собирается из серверной выдачи и малейший рефакторинг сортировки
// легко теряет и язык, и исходный порядок внутри групп.

import 'package:canvas_app/features/market/providers/market_provider.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:flutter_test/flutter_test.dart';

MarketQuest _quest(String id, {String? language, List<String>? languages}) =>
    MarketQuest(
      id: id,
      title: id,
      downloadUrl: 'https://backend.example.invalid/quests/$id.mnd',
      downloadsCount: 0,
      likeCount: 0,
      dislikeCount: 0,
      averageRating: 0,
      version: '1.0.0',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      language: language,
      languages: languages ?? const [],
    );

List<String> _ids(List<MarketQuest> quests) => quests.map((q) => q.id).toList();

void main() {
  group('orderByPlayerLanguage', () {
    test('квесты на языке игрока идут первыми, остальные сохраняют порядок', () {
      final sorted = orderByPlayerLanguage([
        _quest('fresh-ru'),
        _quest('mid-en', language: 'en'),
        _quest('old-ja', language: 'ja'),
        _quest('new-en', language: 'en'),
      ], 'en');

      expect(_ids(sorted), ['mid-en', 'new-en', 'fresh-ru', 'old-ja']);
    });

    test('квест без метки — русский: для ru-игрока он впереди чужих', () {
      expect(
        _ids(orderByPlayerLanguage([
          _quest('marked-en', language: 'en'),
          _quest('untagged'),
        ], 'ru')),
        ['untagged', 'marked-en'],
      );
    });

    test('квест без метки не считается родным для иностранца', () {
      expect(
        _ids(orderByPlayerLanguage([
          _quest('untagged'),
          _quest('marked-en', language: 'en'),
        ], 'en')),
        ['marked-en', 'untagged'],
      );
    });

    test('региональный код ловит базовый: pt-BR игроку подходит pt', () {
      final sorted = orderByPlayerLanguage([
        _quest('en-one', language: 'en'),
        _quest('generic-pt', language: 'pt'),
      ], 'pt-BR');

      expect(_ids(sorted), ['generic-pt', 'en-one']);
    });

    test('нет совпадений — порядок не меняется', () {
      final quests = [_quest('a', language: 'de'), _quest('b', language: 'ja')];

      expect(_ids(orderByPlayerLanguage(quests, 'hi')), ['a', 'b']);
    });

    test('совпали все — порядок не меняется', () {
      final quests = [_quest('a', language: 'en'), _quest('b', language: 'en')];

      expect(_ids(orderByPlayerLanguage(quests, 'en')), ['a', 'b']);
    });

    test('квест с переводом поднимается на любом из своих языков', () {
      // Первый язык — основной, но история с переводом на язык игрока всё
      // равно родная: иначе полный перевод уезжал бы вниз из-за одного тега.
      final translated = _quest(
        'ru-en',
        language: 'en',
        languages: const ['en', 'ru'],
      );
      final onlyJa = _quest('ja', language: 'ja');

      expect(
        _ids(orderByPlayerLanguage([onlyJa, translated], 'ru')),
        ['ru-en', 'ja'],
      );
    });
  });

  group('MarketQuest.language', () {
    test('серверное поле читается и чистится', () {
      Map<String, dynamic> payload(String? language) => {
        'id': 'q1',
        'title': 'Квест',
        'download_url': 'https://backend.example.invalid/quests/q1.mnd',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-02T00:00:00Z',
        'language': language,
      };

      expect(MarketQuest.fromJson(payload(' ja ')).language, 'ja');
      expect(MarketQuest.fromJson(payload('   ')).language, isNull);
      expect(MarketQuest.fromJson(payload(null)).language, isNull);
    });

    test('список языков читается, а старый бэкенд даёт его из одного', () {
      Map<String, dynamic> payload({String? language, Object? languages}) => {
        'id': 'q1',
        'title': 'Квест',
        'download_url': 'https://backend.example.invalid/quests/q1.mnd',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-02T00:00:00Z',
        'language': language,
        'languages': languages,
      };

      expect(
        MarketQuest.fromJson(
          payload(language: 'en', languages: ['en', 'ru']),
        ).languages,
        ['en', 'ru'],
      );
      // Старый сервер поля не знает — основной язык остаётся единственным.
      expect(
        MarketQuest.fromJson(payload(language: 'en')).languages,
        ['en'],
      );
      expect(
        MarketQuest.fromJson(payload(languages: ['', '  '])).languages,
        isEmpty,
      );
    });
  });
}
