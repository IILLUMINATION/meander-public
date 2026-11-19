// Каналы: комментарии к посту и композер поста.
//
// Канал не заводит свой список комментариев: он открывает тот же экран, что и
// сообщество (общая шапка, карточки, пустое/ошибочное состояние и поле ввода
// из `shared/comments`). Проверяем ровно то, что легко сломать при
// унификации: комментарии приходят с эндпоинта канала, отправка уходит на
// него же и появляется в списке, сбой загрузки показывает «Повторить», а
// кнопка «написать» не висит над полем ввода, когда композер открыт.

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/features/channels/screens/channel_comments_screen.dart';
import 'package:canvas_app/features/channels/screens/channel_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends ApiService {
  _FakeApi({this.commentsError = false});

  final bool commentsError;
  final List<String> sentBodies = [];
  final List<String> publishedBodies = [];
  int commentsGetCount = 0;

  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'channels/posts/p-1/comments') {
      commentsGetCount++;
      if (commentsError) throw Exception('Сеть недоступна');
      return {
        'comments': [
          {
            'id': 'cm-1',
            'post_id': 'p-1',
            'author_id': 'u-2',
            'body': 'Первый!',
            'created_at': '2026-11-14T10:00:00.000Z',
            'author_name': 'Аня',
          },
        ],
      };
    }
    if (endpoint == 'channels/c-1') {
      return {
        'channel': {
          'id': 'c-1',
          'title': 'Новости Meander',
          'my_role': 'owner',
          'comments_enabled': true,
        },
      };
    }
    if (endpoint == 'channels/c-1/posts') {
      return {
        'posts': [
          {
            'id': 'p-1',
            'channel_id': 'c-1',
            'body': 'Обновление вышло',
            'created_at': '2026-11-14T10:00:00.000Z',
            'comments_count': 1,
          },
        ],
        'has_more': false,
      };
    }
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> post(String endpoint, {dynamic body}) async {
    if (endpoint == 'channels/c-1/posts') {
      final text = (body is Map ? body['body'] : '')?.toString() ?? '';
      publishedBodies.add(text);
      return {
        'post': {
          'id': 'p-2',
          'channel_id': 'c-1',
          'body': text,
          'created_at': '2026-11-14T12:00:00.000Z',
          'comments_count': 0,
        },
      };
    }
    if (endpoint == 'channels/posts/p-1/comments') {
      final text = (body is Map ? body['body'] : '')?.toString() ?? '';
      sentBodies.add(text);
      return {
        'comment': {
          'id': 'cm-${sentBodies.length + 1}',
          'post_id': 'p-1',
          'author_id': 'me-1',
          'body': text,
          'created_at': '2026-11-14T11:00:00.000Z',
          'author_name': 'Я',
        },
      };
    }
    return <String, dynamic>{};
  }
}

ChannelPost _post() => ChannelPost.fromJson({
  'id': 'p-1',
  'channel_id': 'c-1',
  'body': 'Обновление вышло',
  'created_at': '2026-11-14T10:00:00.000Z',
  'comments_count': 1,
});

Future<void> _pump(WidgetTester tester, Widget child, ApiService api) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(api)],
      child: MaterialApp(home: child),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'user_id': 'me-1',
      'jwt_token': 't',
    });
  });

  testWidgets('комментарии канала приходят на общий экран комментариев', (
    tester,
  ) async {
    await _pump(
      tester,
      ChannelCommentsScreen(post: _post(), channelTitle: 'Новости Meander'),
      _FakeApi(),
    );

    expect(find.text('Комментарии'), findsOneWidget);
    // Шапка: чей пост комментируют и сам текст поста.
    expect(find.text('Новости Meander'), findsOneWidget);
    expect(find.text('Обновление вышло'), findsOneWidget);
    // Карточка комментария — общая с сообществом.
    expect(find.text('Первый!'), findsOneWidget);
    expect(find.text('Аня'), findsOneWidget);
    expect(find.byKey(const ValueKey('comment-input')), findsOneWidget);
  });

  testWidgets('отправка уходит в эндпоинт канала и появляется в списке', (
    tester,
  ) async {
    final api = _FakeApi();
    await _pump(
      tester,
      ChannelCommentsScreen(post: _post()),
      api,
    );

    await tester.enterText(
      find.byKey(const ValueKey('comment-input')),
      'Спасибо за пост',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('comment-send')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(api.sentBodies, ['Спасибо за пост']);
    expect(find.text('Спасибо за пост'), findsOneWidget);
  });

  testWidgets('сбой загрузки комментариев показывает «Повторить»', (
    tester,
  ) async {
    await _pump(
      tester,
      ChannelCommentsScreen(post: _post()),
      _FakeApi(commentsError: true),
    );

    expect(find.text('Не удалось загрузить'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('пост пишется на отдельном экране, а не в поле под кнопкой', (
    tester,
  ) async {
    await _pump(tester, const ChannelScreen(channelId: 'c-1'), _FakeApi());

    await tester.tap(find.byKey(const ValueKey('channel-compose')));
    await tester.pumpAndSettle();

    // Редактор — отдельный экран: поле и «Отправить» в шапке, значит кнопка
    // «написать» физически не может висеть над отправкой.
    expect(find.byKey(const ValueKey('post-editor-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-editor-submit')), findsOneWidget);
    expect(find.text('Новый пост'), findsOneWidget);
  });

  testWidgets('пост из редактора уходит в эндпоинт канала и встаёт в ленту', (
    tester,
  ) async {
    final api = _FakeApi();
    await _pump(tester, const ChannelScreen(channelId: 'c-1'), api);

    await tester.tap(find.byKey(const ValueKey('channel-compose')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('post-editor-field')),
      'Свежие новости',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('post-editor-submit')));
    await tester.pumpAndSettle();

    expect(api.publishedBodies, ['Свежие новости']);
    // Экран закрылся, пост на месте.
    expect(find.byKey(const ValueKey('post-editor-field')), findsNothing);
    expect(find.text('Свежие новости'), findsOneWidget);
  });
}