// Перебор зеркал в ApiService: сетевой отказ на активном зеркале
// триггерит поиск живого; если живых нет — маркер ALL_MIRRORS_DOWN.
// Протокольные ответы (403) ретраев и переключение не запускают.

import 'dart:io';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/mirror_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Клиент, который отвечает SocketException на любой запрос: эмулирует
/// недоступность всех зеркал (probe в MirrorRegistry завяжем на фейк).
http.Client _deadClient() => MockClient(
      (req) async => throw const SocketException('blocked'),
    );

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    // Все зонды «мертвы» без реальной сети: детерминированный FAIL.
    MirrorRegistry.probeOverride = false;
  });

  tearDown(() {
    MirrorRegistry.probeOverride = null;
  });

  test(
      'все зеркала недоступны — запрос заканчивается маркером '
      'ALL_MIRRORS_DOWN, который UI разворачивает в подсказку',
      () async {
    final api = ApiService(
      client: _deadClient(),
      requestTimeout: const Duration(milliseconds: 50),
    );

    Object? thrown;
    try {
      await api.get('profiles/me');
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull);
    expect(thrown.toString(), contains('ALL_MIRRORS_DOWN'));
  });

  test('403 — ответ бэкенда: перебор зеркал не запускается', () async {
    final api = ApiService(
      client: MockClient(
        (req) async => http.Response('{"error":"Only the author"}', 403),
      ),
    );

    Object? thrown;
    try {
      await api.get('author-walls/wall');
    } catch (e) {
      thrown = e;
    }
    expect(thrown.toString(), contains('403'));
    expect(thrown.toString(), isNot(contains('ALL_MIRRORS_DOWN')));
    // Активное зеркало не переключено: бэкенд отвечал, значит он жив.
    expect(
      thrown.toString(),
      isNot(contains('зеркал')),
    );
  });
}
