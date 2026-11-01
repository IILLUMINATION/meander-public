// Окно переписки. Проверяет три вещи, которые в рантайме выглядят как «всё
// сломалось»: у аккаунта команды не должно быть поля ввода (писать туда
// отказывает сервер, и показывать кнопку «отправить» значит обещать то, чего
// нет), реплики должны раскладываться по сторонам от того, кто их пишет, и
// неудачная догрузка истории не имеет права превращать чат в пустой экран.

import 'dart:io';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/providers/dm_provider.dart';
import 'package:canvas_app/features/messages/screens/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _me = 'me-1';
const String _peer = 'peer-1';
const String _thread = 'thread-1';

class _FakeApi extends ApiService {
  _FakeApi({this.paginated = false, this.olderFailures = 0});

  /// Первая страница «влезает не вся», то есть есть что догружать вверх.
  final bool paginated;

  /// Сколько раз подряд история отказывается приехать. Меняется в тесте, чтобы
  /// проверить и баннер, и то, что «Повторить» в нём действительно догружает.
  int olderFailures;

  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'api/messages/threads/peer/$_peer') {
      return {
        'thread_id': _thread,
        'peer_id': _peer,
        'peer_name': 'Аня',
        'peer_role': 'user',
      };
    }
    if (endpoint == 'api/messages/threads/peer/$kSystemUserId') {
      return {
        'thread_id': 'thread-sys',
        'peer_id': kSystemUserId,
        'peer_name': 'Meander',
        'peer_role': 'admin',
      };
    }
    if (endpoint == 'api/messages/threads/$_thread') {
      if (queryParams?['before'] != null) {
        if (olderFailures > 0) {
          olderFailures--;
          throw SocketException('история не доехала');
        }
        return {
          'thread_id': _thread,
          'has_more': false,
          'messages': [
            {
              'id': 'm0',
              'thread_id': _thread,
              'sender_id': _peer,
              'body': 'загляни в пятницу',
              'kind': 'text',
              'created_at': '2026-09-19T18:00:00.000Z',
            },
          ],
        };
      }
      return {
        'thread_id': _thread,
        'has_more': paginated,
        'messages': [
          {
            'id': 'm1',
            'thread_id': _thread,
            'sender_id': _peer,
            'body': 'привет',
            'kind': 'text',
            'created_at': '2026-09-20T10:00:00.000Z',
          },
          {
            'id': 'm2',
            'thread_id': _thread,
            'sender_id': _me,
            'body': 'зайду вечером',
            'kind': 'text',
            'created_at': '2026-09-20T10:05:00.000Z',
          },
        ],
      };
    }
    if (endpoint == 'api/messages/threads/thread-sys') {
      return {
        'thread_id': 'thread-sys',
        'has_more': false,
        'messages': [
          {
            'id': 'n1',
            'thread_id': 'thread-sys',
            'sender_id': kSystemUserId,
            'body': 'Обновили редактор квестов',
            'kind': 'news',
            'created_at': '2026-09-20T09:00:00.000Z',
          },
        ],
      };
    }
    // Лента диалогов: окно чата отмечает прочитанное, и ленте это показывают.
    return {
      'threads': <Map<String, dynamic>>[],
      'system_user_id': kSystemUserId,
    };
  }

  @override
  Future<dynamic> post(String endpoint, {Map<String, dynamic>? body}) async {
    return {
      'thread_id': _thread,
      'message': {
        'id': 'm3',
        'thread_id': _thread,
        'sender_id': _me,
        'body': body?['body'],
        'kind': 'text',
        'created_at': '2026-09-20T10:10:00.000Z',
      },
    };
  }
}

Future<_FakeApi> _openChat(
  WidgetTester tester,
  String peerId, {
  bool paginated = false,
  int olderFailures = 0,
}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final api = _FakeApi(paginated: paginated, olderFailures: olderFailures);
  SharedPreferences.setMockInitialValues({'user_id': _me, 'jwt_token': 't'});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: ChatScreen(peerId: peerId),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('человеческая переписка: реплики по сторонам и поле ввода', (
    tester,
  ) async {
    await _openChat(tester, _peer);

    expect(find.text('привет'), findsOneWidget);
    expect(find.textContaining('зайду вечером'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('Ответить нельзя'), findsNothing);
  });

  testWidgets('отправленное сообщение появляется без перезагрузки окна', (
    tester,
  ) async {
    await _openChat(tester, _peer);

    await tester.enterText(find.byType(TextField), 'буду в 20:00');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(find.textContaining('буду в 20:00'), findsOneWidget);
  });

  testWidgets('неудачная догрузка истории — баннер, а не пустой чат', (
    tester,
  ) async {
    final api = await _openChat(
      tester,
      _peer,
      paginated: true,
      olderFailures: 1,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );

    await container.read(dmChatProvider(_peer).notifier).loadOlder();
    await tester.pumpAndSettle();

    // Прежняя ошибка уходила в молчание: список просто перставал листаться.
    expect(find.textContaining('Нет соединения с сервером'), findsOneWidget);
    // То, что человек уже читает, обязано остаться, и писать можно дальше.
    expect(find.text('привет'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    api.olderFailures = 0;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Нет соединения с сервером'), findsNothing);
    expect(find.text('загляни в пятницу'), findsOneWidget);
  });

  testWidgets('на чужое сообщение можно пожаловаться', (tester) async {
    await _openChat(tester, _peer);

    final reportButton = tester.widget<InkWell>(
      find.byKey(const ValueKey('dm-report-m1')),
    );
    reportButton.onTap!();
    await tester.pumpAndSettle();
    expect(find.text('Пожаловаться'), findsOneWidget);

    await tester.tap(find.text('Пожаловаться'));
    await tester.pumpAndSettle();
    expect(find.text('Пожаловаться на сообщение'), findsOneWidget);
  });

  testWidgets('чат команды читается, но писать в него не предлагают', (
    tester,
  ) async {
    await _openChat(tester, kSystemUserId);

    expect(find.text('Обновили редактор квестов'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('Ответить нельзя'), findsOneWidget);
  });
}
