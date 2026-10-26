// Просмотры в карточке маркета (#366).
//
// Просмотры приходят отдельным полем `views_count`, а не выводятся из
// скачиваний: это разные счётчики, и карточка должна показывать каждый свой.
// Тест держит и разбор ответа сервера, и саму строку метрик.

import 'package:canvas_app/core/utils/count_format.dart';
import 'package:canvas_app/features/market/widgets/market_widgets.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MarketQuest _quest({int views = 0, int downloads = 0}) => MarketQuest(
  id: 'q1',
  title: 'Тестовый квест',
  downloadUrl: 'https://backend.example.invalid/q1.mnd',
  downloadsCount: downloads,
  viewsCount: views,
  likeCount: 0,
  dislikeCount: 0,
  averageRating: 4.5,
  version: '1.0.0',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Future<void> _pumpCard(WidgetTester tester, MarketQuest quest) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: MarketQuestCard(quest: quest),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('views_count разбирается из ответа сервера', () {
    final quest = MarketQuest.fromJson({
      'id': 'q1',
      'title': 'Тестовый квест',
      'download_url': 'https://backend.example.invalid/q1.mnd',
      'downloads_count': 7,
      'views_count': 1234,
      'like_count': 0,
      'dislike_count': 0,
      'average_rating': 4.5,
      'version': '1.0.0',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });

    expect(quest.viewsCount, 1234);
    expect(quest.downloadsCount, 7);
  });

  test('без поля views_count квест остаётся валидным', () {
    final quest = MarketQuest.fromJson({
      'id': 'q1',
      'title': 'Тестовый квест',
      'download_url': 'https://backend.example.invalid/q1.mnd',
      'downloads_count': 7,
      'like_count': 0,
      'dislike_count': 0,
      'average_rating': 4.5,
      'version': '1.0.0',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });

    expect(quest.viewsCount, 0);
  });

  test('formatCount сворачивает крупные счётчики', () {
    expect(formatCount(999), '999');
    expect(formatCount(1234), '1.2k');
    expect(formatCount(1500000), '1.5M');
  });

  testWidgets('карточка показывает и скачивания, и просмотры', (tester) async {
    await _pumpCard(tester, _quest(views: 1234, downloads: 7));

    // Негативный контроль: если бы карточка брала просмотры из скачиваний,
    // здесь оказалось бы «7» вместо «1.2k».
    expect(find.text('7'), findsOneWidget);
    expect(find.text('1.2k'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Просмотры')), findsOneWidget);
  });
}
