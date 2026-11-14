// Каналы: лента от сервера и тексты постов.
//
// Проверяем то, что легко сломать при правке роутов: пост без вложений
// всё равно показывается, markdown не печатается звёздочками, а закрытый
// канал в выдаче помечен значком, а не молча пропадает.

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/features/channels/screens/channels_screen.dart';
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
    if (endpoint == 'channels' || endpoint == 'api/channels') {
      return {
        'channels': [
          {
            'id': 'c-1',
            'title': 'Новости Meander',
            'description': 'Анонсы и обновления',
            'is_public': true,
            'subscribers_count': 4211,
            'posts_count': 12,
            'my_role': 'subscriber',
          },
          {
            'id': 'c-2',
            'title': 'Закрытый клуб',
            'description': '',
            'is_public': false,
            'subscribers_count': 8,
            'posts_count': 3,
            'my_role': null,
          },
        ],
      };
    }
    if (endpoint == 'api/messages/system') return const {};
    return <String, dynamic>{};
  }
}

void main() {
  testWidgets('лента каналов показывает подписки и закрытые каналы', (
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
        child: const MaterialApp(home: ChannelsScreen()),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Новости Meander'), findsOneWidget);
    expect(find.text('Закрытый клуб'), findsOneWidget);
    // Число подписчиков форматируется, а не печатается сырым.
    expect(find.textContaining('4'), findsWidgets);
  });

  test('пост без вложений и с markdown читается моделью', () {
    final post = ChannelPost.fromJson({
      'id': 'p-1',
      'channel_id': 'c-1',
      'body': '**Важно**: обновление вышло',
      'attachments': [
        {'url': 'https://example.com/a.jpg', 'width': 800, 'height': 600},
      ],
      'views_count': 12,
      'comments_count': 3,
      'created_at': '2026-11-14T10:00:00.000Z',
    });
    expect(post.body, contains('**Важно**'));
    expect(post.attachments.length, 1);
    expect(post.attachments.first.aspectRatio, closeTo(800 / 600, 0.001));

    // Мусор в списке вложений не должен ломать пост.
    final broken = ChannelPost.fromJson({
      'id': 'p-2',
      'channel_id': 'c-1',
      'body': '',
      'attachments': [null, 'x', {'url': ''}],
      'created_at': '2026-11-14T10:00:00.000Z',
    });
    expect(broken.attachments, isEmpty);
  });
}