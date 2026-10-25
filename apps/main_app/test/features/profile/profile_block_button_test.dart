import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';

/// Apple 1.2: человека нужно уметь заблокировать из его профиля, а не только
/// из уже открытой переписки. Кнопка переиспользует тот же серверный
/// `user_blocks`, что и меню чата: POST/DELETE `api/messages/blocks/:id`.
class _FakeApi extends ApiService {
  _FakeApi({this.blocked = const []});

  final List<Map<String, dynamic>> blocked;
  final List<String> posts = [];
  final List<String> deletes = [];

  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'api/messages/blocks') {
      return {'blocked': blocked};
    }
    if (endpoint == 'notifications/unread-count') {
      return const {'count': 0};
    }
    if (endpoint == 'profiles/author-notifs-settings') {
      return const {'mode': 'all', 'exceptions': <String>[]};
    }
    if (endpoint.endsWith('/is-following')) {
      return const {'isFollowing': false};
    }
    if (endpoint.startsWith('profiles/')) {
      final id = endpoint.split('/')[1];
      return {
        'id': id,
        'full_name': id == 'u-viewer' ? 'Я' : 'Автор',
        'created_at': '2026-01-01T00:00:00Z',
      };
    }
    return const [];
  }

  @override
  Future<dynamic> post(String endpoint, {Map<String, dynamic>? body}) async {
    posts.add(endpoint);
    return const {'success': true};
  }

  @override
  Future<dynamic> delete(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    deletes.add(endpoint);
    return const {'success': true};
  }
}

Future<void> _pumpProfile(WidgetTester tester, _FakeApi api, String userId) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(api)],
      child: MaterialApp(home: ProfileScreen(userId: userId)),
    ),
  );
  // Шиммер шапки не даёт pumpAndSettle дождаться покоя.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert_rounded));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// visibility_detector при detach слоя планирует апдейт на +500 мс. Если
/// оставить дерево жить до teardown, таймер успевает всплыть в проверке
/// «A Timer is still pending» — снимаем дерево сами и прожигаем задержку.
Future<void> _disposeTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token-1',
      'user_id': 'u-viewer',
    });
  });

  testWidgets('в чужом профиле есть «Заблокировать»', (tester) async {
    await _pumpProfile(tester, _FakeApi(), 'u-author');
    await _openMenu(tester);
    expect(find.text('Заблокировать автора'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeTree(tester);
  });

  testWidgets('в своём профиле кнопки блокировки нет — вместо неё «Выйти»', (
    tester,
  ) async {
    await _pumpProfile(tester, _FakeApi(), 'u-viewer');
    await _openMenu(tester);
    // Себя блокировать нельзя — и предлагать это в своём профиле нельзя.
    expect(find.text('Заблокировать автора'), findsNothing);
    expect(find.text('Выйти'), findsOneWidget);
    await _disposeTree(tester);
  });

  testWidgets('подтверждение блокирует и пункт меняется на «Разблокировать»', (
    tester,
  ) async {
    final api = _FakeApi();
    await _pumpProfile(tester, api, 'u-author');
    await _openMenu(tester);

    await tester.tap(find.text('Заблокировать автора'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Заблокировать автора?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Заблокировать автора'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(api.posts, ['api/messages/blocks/u-author']);
    expect(find.text('Автор заблокирован'), findsOneWidget);

    await _openMenu(tester);
    expect(find.text('Разблокировать автора'), findsOneWidget);
    expect(find.text('Заблокировать автора'), findsNothing);
    await _disposeTree(tester);
  });

  testWidgets('отмена в диалоге не трогает сервер', (tester) async {
    final api = _FakeApi();
    await _pumpProfile(tester, api, 'u-author');
    await _openMenu(tester);

    await tester.tap(find.text('Заблокировать автора'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(api.posts, isEmpty);
    await _openMenu(tester);
    expect(find.text('Заблокировать автора'), findsOneWidget);
    await _disposeTree(tester);
  });

  testWidgets('разблокировка из профиля снимает блокировку', (tester) async {
    final api = _FakeApi(
      blocked: [
        {'id': 'u-author', 'full_name': 'Автор'},
      ],
    );
    await _pumpProfile(tester, api, 'u-author');
    await _openMenu(tester);

    expect(find.text('Разблокировать автора'), findsOneWidget);
    await tester.tap(find.text('Разблокировать автора'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Разблокировать автора?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Разблокировать автора'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(api.deletes, ['api/messages/blocks/u-author']);
    expect(find.text('Автор разблокирован'), findsOneWidget);
    await _disposeTree(tester);
  });
}
