// Альбом и markdown в пузыре переписки.
//
// Проверяется то, что видно по дереву виджетов: фото из ответа сервера
// превращается в сетку вложений, а разметка в тексте — в форматированный
// текст, а не в звёздочки. Картинки в тесте не загружаются (сеть выключена),
// поэтому проверяем наличие виджетов, а не пиксели.

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/screens/chat_screen.dart';
import 'package:canvas_app/features/messages/widgets/chat_attachments.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _me = 'me-1';
const String _peer = 'peer-1';
const String _thread = 'thread-1';

Map<String, dynamic> _photo(String suffix) => {
  'url': 'https://meander.illuminat.dev/uploads/00000000-0000-0000-0000-00000000000$suffix.jpg',
  'width': 1600,
  'height': 1067,
  'size': 5000,
  'mime': 'image/jpeg',
};

class _FakeApi extends ApiService {
  _FakeApi(this.messages);

  final List<Map<String, dynamic>> messages;

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
    if (endpoint == 'api/messages/threads/$_thread') {
      return {
        'thread_id': _thread,
        'has_more': false,
        'messages': messages,
      };
    }
    return {'threads': <Map<String, dynamic>>[], 'system_user_id': kSystemUserId};
  }

  @override
  Future<dynamic> post(String endpoint, {Map<String, dynamic>? body}) async =>
      const {};
}

Future<void> _open(
  WidgetTester tester,
  List<Map<String, dynamic>> messages,
) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({'user_id': _me, 'jwt_token': 't'});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(_FakeApi(messages))],
      child: const MaterialApp(home: ChatScreen(peerId: _peer)),
    ),
  );
  // `pumpAndSettle` здесь не годится: плейсхолдеры картинок крутят
  // `CircularProgressIndicator` и не дают кадрам «успокоиться».
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('одно фото из ответа сервера показывается в пузыре', (
    tester,
  ) async {
    await _open(tester, [
      {
        'id': 'm1',
        'thread_id': _thread,
        'sender_id': _peer,
        'body': '',
        'kind': 'text',
        'created_at': '2026-11-14T10:00:00.000Z',
        'attachments': [_photo('1')],
      },
    ]);

    expect(find.byType(ChatAttachmentGrid), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsWidgets);
  });

  testWidgets('альбом из трёх кадров остаётся одним блоком вложений', (
    tester,
  ) async {
    await _open(tester, [
      {
        'id': 'm2',
        'thread_id': _thread,
        'sender_id': _me,
        'body': 'смотри как получилось',
        'kind': 'text',
        'created_at': '2026-11-14T10:00:00.000Z',
        'attachments': [_photo('1'), _photo('2'), _photo('3')],
      },
    ]);

    expect(find.byType(ChatAttachmentGrid), findsOneWidget);
    expect(find.textContaining('смотри как получилось'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNWidgets(3));
  });

  testWidgets('markdown в тексте не показывается звёздочками', (tester) async {
    await _open(tester, [
      {
        'id': 'm3',
        'thread_id': _thread,
        'sender_id': _peer,
        'body': '**Важно** и ещё [ссылка](https://meander.illuminat.dev/x)',
        'kind': 'text',
        'created_at': '2026-11-14T10:00:00.000Z',
      },
    ]);

    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('Важно'), findsOneWidget);
  });
}