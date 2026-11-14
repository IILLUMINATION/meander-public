// Лента «Чаты»: входы, которые иначе ищут в глубине меню.
//
// Поддержка — первая строка всегда, даже когда переписок нет: именно в этот
// момент её и открывают. Каналы живут за иконкой в шапке, потому что это не
// переписка, а вещание.

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/messages/screens/chats_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends ApiService {
  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'api/messages/system') return const {};
    if (endpoint == 'api/messages/threads') {
      return {'threads': <Map<String, dynamic>>[]};
    }
    throw Exception('неизвестный эндпоинт $endpoint');
  }

  @override
  Future<dynamic> post(String endpoint, {Map<String, dynamic>? body}) async =>
      const {};
}

void main() {
  testWidgets('поддержка и каналы доступны из ленты без переписок', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({'user_id': 'me-1', 'jwt_token': 't'});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiServiceProvider.overrideWithValue(_FakeApi())],
        child: const MaterialApp(home: ChatsScreen()),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byKey(const ValueKey('support-entry')), findsOneWidget);
    expect(find.text('Поддержка'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-channels')), findsOneWidget);

    // Обычному человеку инбокс обращений не показывается: он видит его только
    // у команды, иначе кнопка вела бы к отказу 403.
    expect(find.byKey(const ValueKey('support-inbox')), findsNothing);
  });
}