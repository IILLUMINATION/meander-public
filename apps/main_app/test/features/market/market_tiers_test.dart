// Три уровня каталога: ручной отбор, модерированные и демо.
//
// Главная гарантия для игрока — лучшие идут первыми независимо от свежести,
// а внутри уровня родной язык не тонет. Негативные контроли ниже падают, если
// убрать сортировку по уровню или вывод уровня из демо-флага для старого
// бэкенда.

import 'package:canvas_app/features/market/providers/market_provider.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:flutter_test/flutter_test.dart';

MarketQuest _quest(
  String id, {
  int tier = kMarketTierModerated,
  bool isDemo = false,
  String? language,
}) => MarketQuest(
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
  isDemo: isDemo,
  marketTier: tier,
  language: language,
);

List<String> _ids(List<MarketQuest> quests) => quests.map((q) => q.id).toList();

void main() {
  group('orderByMarketTier', () {
    test('лучшие впереди демо, даже если демо свежее', () {
      final sorted = orderByMarketTier([
        _quest('demo', tier: kMarketTierDemo, isDemo: true),
        _quest('moderated', tier: kMarketTierModerated),
        _quest('best', tier: kMarketTierBest),
      ]);

      expect(_ids(sorted), ['best', 'moderated', 'demo']);
    });

    test('внутри уровня порядок входа сохраняется', () {
      final sorted = orderByMarketTier([
        _quest('moderated-a'),
        _quest('best-a', tier: kMarketTierBest),
        _quest('moderated-b'),
        _quest('best-b', tier: kMarketTierBest),
      ]);

      expect(_ids(sorted), ['best-a', 'best-b', 'moderated-a', 'moderated-b']);
    });
  });

  group('orderCatalogForPlayer', () {
    test('уровень важнее языка: чужой лучший выше родного второго', () {
      final sorted = orderCatalogForPlayer([
        _quest('own-tier2', language: 'ru'),
        _quest('foreign-best', tier: kMarketTierBest, language: 'en'),
      ], 'ru');

      expect(_ids(sorted), ['foreign-best', 'own-tier2']);
    });

    test('внутри уровня квесты на языке игрока первыми', () {
      final sorted = orderCatalogForPlayer([
        _quest('foreign', language: 'en'),
        _quest('own', language: 'ru'),
        _quest('untagged'),
      ], 'ru');

      expect(_ids(sorted), ['own', 'untagged', 'foreign']);
    });
  });

  group('MarketQuest.fromJson: уровень', () {
    Map<String, dynamic> payload({Object? tier, bool? demo}) => {
      'id': 'q1',
      'title': 'Квест',
      'download_url': 'https://backend.example.invalid/quests/q1.mnd',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-02T00:00:00Z',
      'market_tier': ?tier,
      'is_demo': ?demo,
    };

    test('явные уровни читаются как есть', () {
      expect(MarketQuest.fromJson(payload(tier: 1)).marketTier, kMarketTierBest);
      expect(
        MarketQuest.fromJson(payload(tier: 2)).marketTier,
        kMarketTierModerated,
      );
      expect(
        MarketQuest.fromJson(payload(tier: 3, demo: true)).marketTier,
        kMarketTierDemo,
      );
      expect(MarketQuest.fromJson(payload(tier: 1)).isBest, isTrue);
    });

    test('строка и мусор: строка разбирается, мусор уходит во второй уровень', () {
      expect(MarketQuest.fromJson(payload(tier: '1')).marketTier, kMarketTierBest);
      expect(
        MarketQuest.fromJson(payload(tier: 'best')).marketTier,
        kMarketTierModerated,
      );
      expect(
        MarketQuest.fromJson(payload(tier: 99)).marketTier,
        kMarketTierModerated,
      );
    });

    test('старый бэкенд без поля: не-демо — второй уровень, демо — третий', () {
      expect(
        MarketQuest.fromJson(payload()).marketTier,
        kMarketTierModerated,
      );
      expect(
        MarketQuest.fromJson(payload(demo: true)).marketTier,
        kMarketTierDemo,
      );
    });

    test('демо всегда третий уровень, даже если сервер прислал другой', () {
      expect(
        MarketQuest.fromJson(payload(tier: 1, demo: true)).marketTier,
        kMarketTierDemo,
      );
    });

    test('третий уровень без флага демо не протекает в клиент', () {
      expect(
        MarketQuest.fromJson(payload(tier: 3, demo: false)).marketTier,
        kMarketTierModerated,
      );
    });
  });
}
