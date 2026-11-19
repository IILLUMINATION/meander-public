// Центр управления — хаб: все разделы видны сразу, а не спрятаны в
// горизонтальной ленте вкладок, которую приходилось листать.

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/shell/screens/admin_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiService {
  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'reports/admin') {
      return [
        {
          'id': 'r-1',
          'reported_type': 'message',
          'reason': 'Спам',
          'created_at': DateTime.now().toIso8601String(),
        },
      ];
    }
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

void main() {
  testWidgets('хаб показывает все разделы и открывает выбранный', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(_FakeApi())],
        child: const MaterialApp(home: AdminScreen()),
      ),
    );
    await tester.pumpAndSettle();

    for (final section in AdminSection.values) {
      expect(
        find.byKey(ValueKey('admin-section-${section.name}')),
        findsOneWidget,
        reason: 'нет карточки раздела ${section.name}',
      );
    }

    await tester.tap(find.byKey(const ValueKey('admin-section-bans')));
    await tester.pumpAndSettle();
    expect(find.byType(AdminSectionScreen), findsOneWidget);
    expect(find.text('Нет заблокированных пользователей'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AdminSectionScreen), findsNothing);
    expect(find.byKey(const ValueKey('admin-section-reports')), findsOneWidget);
  });
}
