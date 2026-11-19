// Перебор путей в ApiService: сетевой отказ на текущем пути триггерит поиск
// живого (прямое соединение → ретрансляторы); если живых нет — маркер
// ALL_SERVERS_DOWN. Протокольные ответы (403) ретраев не запускают, и ни при
// каком отказе приложение не уходит на прокси-зеркало: такого пути нет.

import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/server_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Клиент, который отвечает SocketException на любой запрос: эмулирует
/// недоступность всех путей (probe в ServerRegistry завязан на фейк).
http.Client _deadClient() => MockClient(
      (req) async => throw const SocketException('blocked'),
    );

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    // Все зонды «мертвы» без реальной сети: детерминированный FAIL.
    ServerRegistry.probeOverride = false;
  });

  tearDown(() {
    ServerRegistry.probeOverride = null;
  });

  test(
      'все пути недоступны — запрос заканчивается маркером '
      'ALL_SERVERS_DOWN, который UI разворачивает в подсказку',
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
    expect(thrown.toString(), contains('ALL_SERVERS_DOWN'));
    expect(
      ServerRegistry.instance.activeUrl,
      AppConfig.vpsApiBaseUrl,
      reason: 'прокси-зеркал нет: активный адрес остаётся оригиналом',
    );
  });

  test('403 — ответ бэкенда: перебор путей не запускается', () async {
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
    expect(thrown.toString(), isNot(contains('ALL_SERVERS_DOWN')));
    // Путь не переключён: бэкенд отвечал, значит он жив.
    expect(ServerRegistry.instance.activeUrl, AppConfig.vpsApiBaseUrl);
  });
}
