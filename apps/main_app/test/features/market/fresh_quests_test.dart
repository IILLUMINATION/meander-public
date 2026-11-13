// Полка «Новинки» в маркете.
//
// Каталог сортирует уровни выше свежести, поэтому только что одобренный
// квест встаёт за всеми отобранными вручную и на первом экране его не видно:
// автор проходит модерацию и не находит историю в маркете. Полка «Новинки»
// показывает свежее поверх уровней. Негативный контроль ниже падает, если
// вернуть в полку сортировку по уровню.

import 'package:canvas_app/features/market/providers/market_provider.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MarketQuest _quest(
  String id, {
  int tier = kMarketTierModerated,
  bool isDemo = false,
  DateTime? updatedAt,
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
  updatedAt: updatedAt ?? DateTime(2026),
  isDemo: isDemo,
  marketTier: tier,
);

Future<List<MarketQuest>> _fresh(List<MarketQuest> catalog) async {
  final container = ProviderContainer(
    overrides: [marketCatalogProvider.overrideWith((ref) async => catalog)],
  );
  addTearDown(container.dispose);
  return await container.read(freshQuestsProvider.future);
}

void main() {
  group('freshQuestsProvider', () {
    test('свежая модерация выше старого ручного отбора', () async {
      final fresh = await _fresh([
        _quest('best-old', tier: kMarketTierBest),
        _quest('just-approved', updatedAt: DateTime(2026, 11, 13)),
        _quest('moderated-old', updatedAt: DateTime(2026, 10, 1)),
      ]);

      expect(
        fresh.map((q) => q.id).toList(),
        ['just-approved', 'moderated-old', 'best-old'],
      );
    });

    test('демо в полку не попадает', () async {
      final fresh = await _fresh([
        _quest('demo', tier: kMarketTierDemo, isDemo: true),
        _quest('normal'),
      ]);

      expect(fresh.map((q) => q.id), ['normal']);
    });

    test('полка не длиннее десяти карточек', () async {
      final fresh = await _fresh([
        for (var i = 0; i < 14; i++)
          _quest('q$i', updatedAt: DateTime(2026, 1, 1 + i)),
      ]);

      expect(fresh.length, 10);
      expect(fresh.first.id, 'q13');
    });
  });
}