import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/shell/screens/admin_screen.dart';

/// Дашборд активности — единственная админ-вкладка, которую можно проверить
/// без сети: данные приходят одним JSON. Голден ловит переполнения карточек,
/// графика и строк топ-юзеров, которые на телефоне не видны в analyze.
class _FakeApi extends ApiService {
  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'admin/activity?days=30') return _activity;
    if (endpoint == 'admin/stats') {
      return <String, dynamic>{
        'users': 12,
        'quests': 3,
        'pending_quests': 1,
        'pending_music': 0,
        'pending_assets': 0,
      };
    }
    if (endpoint == 'admin/moderation-queue' ||
        endpoint == 'admin/music-moderation-queue' ||
        endpoint == 'admin/assets-moderation-queue' ||
        endpoint == 'reports/admin' ||
        endpoint == 'admin/blocked-users') {
      return <dynamic>[];
    }
    return <String, dynamic>{};
  }
}

final Map<String, dynamic> _activity = {
  'days': 30,
  'summary': {
    'total_users': 3858,
    'new_today': 7,
    'new_7d': 41,
    'new_period': 168,
    'online_now': 23,
    'active_today': 214,
    'active_7d': 690,
    'active_period': 1520,
    'visits_today': 388,
    'visits_7d': 2904,
    'visits_period': 11230,
    'visited_today': 201,
  },
  'actions': {
    'quest_votes': 188,
    'music_votes': 24,
    'asset_votes': 12,
    'ratings': 96,
    'reviews': 33,
    'music_reviews': 4,
    'asset_reviews': 2,
    'messages': 512,
    'quests_created': 18,
    'quests_published': 11,
    'posts_created': 57,
    'downloads': 274,
    'quest_views': 3980,
    'playtime_seconds': 186400,
  },
  'series': [
    for (var i = 0; i < 30; i++)
      {
        'day': '2026-10-${(i + 1).toString().padLeft(2, '0')}',
        'visits': 120 + (i * 7) % 180,
        'active_users': 60 + (i * 5) % 90,
        'new_users': i % 6,
        'actions': 80 + (i * 11) % 220,
      },
  ],
  'top_users': [
    {
      'id': 'u-1',
      'full_name': 'Иван Петров',
      'avatar_url': null,
      'last_seen_at': '2026-10-24T18:04:00Z',
      'visits': 42,
      'reactions': 25,
      'messages': 61,
      'quests': 2,
      'posts': 7,
      'score': 160,
    },
    {
      'id': 'u-2',
      'full_name': 'Ирина Сидова',
      'avatar_url': null,
      'last_seen_at': '2026-10-24T12:30:00Z',
      'visits': 31,
      'reactions': 18,
      'messages': 22,
      'quests': 1,
      'posts': 3,
      'score': 83,
    },
    {
      'id': 'u-3',
      'full_name': 'Борис Ктотов',
      'avatar_url': null,
      'last_seen_at': null,
      'visits': 12,
      'reactions': 9,
      'messages': 4,
      'quests': 0,
      'posts': 1,
      'score': 27,
    },
  ],
};

void main() {
  testWidgets('дашборд активности влезает в телефонную ширину', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(_FakeApi())],
        child: const MaterialApp(home: AdminScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Активность'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('Онлайн сейчас'), findsOneWidget);
    expect(find.text('Кто активнее всех'), findsOneWidget);
    expect(find.text('Иван Петров'), findsOneWidget);

    await expectLater(
      find.byType(AdminScreen),
      matchesGoldenFile('goldens/admin_activity_tab.png'),
    );
  });
}
