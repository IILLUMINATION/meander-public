import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/shell/screens/admin_screen.dart';

/// Очередь жалоб проверяем без сети: важно, чтобы админ сразу видел, кто
/// пожаловался, на кого и за что, а не разбирал безымянные карточки.
class _FakeApi extends ApiService {
  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'reports/admin') return _reports;
    if (endpoint == 'admin/stats') return <String, dynamic>{};
    if (endpoint == 'admin/activity?days=30') {
      return {
        'summary': <String, dynamic>{},
        'actions': <String, dynamic>{},
        'series': <dynamic>[],
        'top_users': <dynamic>[],
      };
    }
    return <dynamic>[];
  }
}

final List<Map<String, dynamic>> _reports = [
  {
    'id': 'r-message',
    'reported_type': 'message',
    'reported_id': 'm-1',
    'reason': 'Спам',
    'description': 'Пишет рекламу в личку',
    'reporter_id': 'u-anya',
    'reporter_name': 'Аня Петрова',
    'reported_user_id': 'u-illuminat',
    'reported_user_name': 'Иллюминат',
    'reported_item_title': 'Как там квест?',
    'created_at': DateTime.now()
        .subtract(const Duration(hours: 2))
        .toIso8601String(),
  },
  {
    'id': 'r-post',
    'reported_type': 'wall_post',
    'reported_id': 'p-1',
    'reason': 'Оскорбления',
    'reporter_id': 'u-ivan',
    'reporter_name': 'Иван Петров',
    'reported_user_id': 'u-oleg',
    'reported_user_name': 'Олег Смирнов',
    'reported_item_title': 'Новый пост про квесты',
    'created_at': DateTime.now()
        .subtract(const Duration(hours: 5))
        .toIso8601String(),
  },
  {
    'id': 'r-quest',
    'reported_type': 'quest',
    'reported_id': 'q-1',
    'reason': 'Нарушение авторских прав',
    'reporter_id': 'u-maria',
    'reporter_name': 'Мария',
    'reported_user_id': 'u-author',
    'reported_user_name': 'Автор квеста',
    'reported_item_title': 'Проклятый лес',
    'created_at': DateTime.now()
        .subtract(const Duration(days: 1))
        .toIso8601String(),
  },
];

void main() {
  testWidgets('жалобы показывают участников, причину и фильтруются', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(_FakeApi())],
        child: const MaterialApp(home: AdminScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Жалоб к разбору: 3'), findsOneWidget);
    expect(find.text('Аня Петрова'), findsOneWidget);
    expect(find.text('Иллюминат'), findsOneWidget);
    expect(find.text('Как там квест?'), findsOneWidget);
    expect(find.text('Спам'), findsOneWidget);
    expect(find.text('Пишет рекламу в личку'), findsOneWidget);
    expect(find.text('Новый пост про квесты'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(AdminScreen),
      matchesGoldenFile('goldens/admin_reports_tab.png'),
    );

    await tester.tap(find.text('Сообщения'));
    await tester.pumpAndSettle();
    expect(find.text('Как там квест?'), findsOneWidget);
    expect(find.text('Новый пост про квесты'), findsNothing);
    expect(find.text('Проклятый лес'), findsNothing);

    await tester.tap(find.text('Все'));
    await tester.pumpAndSettle();
    expect(find.text('Новый пост про квесты'), findsOneWidget);

    await tester.tap(find.text('Удалить сообщение'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить сообщение?'), findsOneWidget);
    expect(
      find.text(
        'Сообщение будет скрыто из переписки без возможности восстановления.',
      ),
      findsOneWidget,
    );
  });
}
