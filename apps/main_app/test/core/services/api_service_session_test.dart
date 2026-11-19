// Сессия и NetworkBehaviour: 401 роняет логин, 403 по правилу — нет, а 403 с
// мёртвым токеном роняет; молчаливый сервер не должен оставлять кнопку
// крутиться навсегда.

import 'dart:async';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

ApiService _apiReturning(int status, {String body = ''}) => ApiService(
  client: MockClient((_) async => http.Response(body, status)),
);

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'tok',
      'user_id': '42',
    });
  });

  test('403 — отказ по правилу: токен на месте, текст бэкенда наружу',
      () async {
    final api = _apiReturning(
      403,
      body: '{"error":"Only the author can post on their wall"}',
    );

    Object? thrown;
    try {
      await api.post('author-walls/wall/comments');
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull, reason: '403 обязан долететь до вызывающего');
    expect(thrown.toString(), contains('403'));
    expect(thrown.toString(), contains('Only the author'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('jwt_token'), 'tok');
    expect(prefs.getString('user_id'), '42');
  });

  test('401 — сессия протухла: токен сброшен', () async {
    final api = _apiReturning(401, body: '{"error":"invalid token"}');

    await expectLater(api.get('profiles/me'), throwsA(isA<Exception>()));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('jwt_token'), isNull);
  });

  // Прод до правки middleware на мёртвом JWT отвечал 403, поэтому клиент
  // обязан распознавать и его: без этого человек остаётся в зомби-сессии.
  test('403 «Token is not valid» — это мёртвый токен, а не отказ правила',
      () async {
    final api = _apiReturning(
      403,
      body: '{"error":"Token is not valid"}',
    );

    await expectLater(api.get('profiles/me'), throwsA(isA<Exception>()));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('jwt_token'), isNull, reason: 'сессия порвана');
    expect(prefs.getString('user_id'), isNull);
  });

  test('500 — ошибка бэкенда, а не «сервер на обслуживании»', () async {
    final api = _apiReturning(500, body: '{"error":"Server error"}');

    Object? thrown;
    try {
      await api.post('quests/0/admin/action', body: {'action': 'x'});
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull);
    expect(thrown.toString(), contains('500'));
    expect(thrown.toString(), contains('Server error'));
    expect(
      thrown.toString(),
      isNot(contains('SERVER_MAINTENANCE')),
      reason: 'иначе админ видит техработы вместо причины',
    );
  });

  test('сервер не отвечает — запрос завершается сам', () async {
    final api = ApiService(
      client: MockClient(
        (_) => Future<http.Response>.delayed(
          const Duration(seconds: 5),
          () => http.Response('{}', 200),
        ),
      ),
      requestTimeout: const Duration(milliseconds: 100),
    );

    await expectLater(api.get('quests'), throwsA(isA<TimeoutException>()));
  });
}
