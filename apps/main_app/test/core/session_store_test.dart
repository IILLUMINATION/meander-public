// Сессия привязана к серверу, который её выдал.
//
// До патча `jwt_token` уходил в `Authorization` на любой активный хост:
// добавленный пользователем сервер получал токен основного домена и мог
// предъявить его там (он валиден 7 дней). Эти тесты держат три свойства:
//
// 1) переключение на свой сервер, где входа не было, не отправляет туда
//    чужой токен (приложение там гость);
// 2) вход на своём сервере не затирает сессию основного домена;
// 3) прокси-зеркал нет, поэтому старая сессия не может утечь на посредника.
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/server_registry.dart';
import 'package:canvas_app/core/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _customServer = 'https://my.server';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServerRegistry.instance.resetForTests();
    SessionStore.resetForTests();
    ServerRegistry.probeOverride = true;
    ServerRegistry.skipRealNetwork = false;
  });

  tearDown(() {
    ServerRegistry.probeOverride = null;
  });

  test(
    'старый безусловный токен становится сессией основного бэкенда',
    () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'legacy-token',
        'user_id': 'legacy-user',
      });
      SessionStore.resetForTests();

      await SessionStore.ensureLoaded();

      final prefs = await SharedPreferences.getInstance();
      expect(SessionStore.activeDomain, SessionStore.primaryDomain);
      expect(
        prefs.getString(SessionStore.tokenKeyFor(SessionStore.primaryDomain)),
        'legacy-token',
        reason: 'миграция не должна разлогинивать существующего пользователя',
      );
      expect(prefs.getString('jwt_token'), 'legacy-token');
      expect(prefs.getString('user_id'), 'legacy-user');
    },
  );

  test('оригинал — своя область доверия, прокси-зеркал больше нет', () {
    // Зеркал-прокси нет: они не попадают ни в перебор, ни в области доверия,
    // даже если остались в сохранённых настройках старой версии.
    for (final url in AppConfig.retiredProxyUrls) {
      expect(
        ServerRegistry.instance.allUrls,
        isNot(contains(url)),
        reason: '$url — L7-прокси, он видел токен и больше не используется',
      );
    }
    expect(
      ServerRegistry.domainFor(AppConfig.vpsApiBaseUrl),
      SessionStore.primaryDomain,
      reason: 'оригинал — одна область доверия',
    );
    expect(
      ServerRegistry.domainFor(_customServer),
      _customServer,
      reason: 'свой сервер — отдельная область доверия',
    );
  });

  test('переключение на свой сервер убирает токен основного домена', () async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'primary-token',
      'user_id': 'primary-user',
    });
    SessionStore.resetForTests();
    ServerRegistry.instance.resetForTests();

    await ServerRegistry.instance.addCustomUrl(_customServer);
    await ServerRegistry.instance.setActiveUrl(_customServer);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('jwt_token'), isNull);
    expect(prefs.getString('user_id'), isNull);
    expect(
      prefs.getString(SessionStore.tokenKeyFor(SessionStore.primaryDomain)),
      'primary-token',
      reason: 'сессия основного домена сохраняется для возврата',
    );
  });

  test('запрос на свой сервер не несёт чужой Authorization', () async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'primary-token',
      'user_id': 'primary-user',
    });
    SessionStore.resetForTests();
    ServerRegistry.instance.resetForTests();
    await ServerRegistry.instance.addCustomUrl(_customServer);
    await ServerRegistry.instance.setActiveUrl(_customServer);

    String? seenAuth;
    final api = ApiService(
      client: MockClient((req) async {
        seenAuth = req.headers['Authorization'];
        return http.Response('{}', 200);
      }),
    );
    await api.get('profiles/me');

    expect(
      seenAuth,
      isNull,
      reason:
          'токен основного домена невалиден на чужом сервере и не должен '
          'утекать туда: владелец сервера мог бы предъявить его оригиналу',
    );
  });

  test('вход на своём сервере не затирает сессию основного домена', () async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'primary-token',
      'user_id': 'primary-user',
    });
    SessionStore.resetForTests();
    ServerRegistry.instance.resetForTests();

    await ServerRegistry.instance.addCustomUrl(_customServer);
    await ServerRegistry.instance.setActiveUrl(_customServer);
    await SessionStore.save(
      domain: ServerRegistry.domainFor(_customServer),
      token: 'custom-token',
      userId: 'custom-user',
    );

    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('jwt_token'), 'custom-token');

    await ServerRegistry.instance.setActiveUrl(AppConfig.vpsApiBaseUrl);
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('jwt_token'), 'primary-token');
    expect(prefs.getString('user_id'), 'primary-user');
  });

  test('выход снимает только активную область', () async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'primary-token',
      'user_id': 'primary-user',
    });
    SessionStore.resetForTests();
    ServerRegistry.instance.resetForTests();

    await ServerRegistry.instance.addCustomUrl(_customServer);
    await ServerRegistry.instance.setActiveUrl(_customServer);
    await SessionStore.save(
      domain: ServerRegistry.domainFor(_customServer),
      token: 'custom-token',
      userId: 'custom-user',
    );

    await SessionStore.clearActive();

    await ServerRegistry.instance.setActiveUrl(AppConfig.vpsApiBaseUrl);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('jwt_token'),
      'primary-token',
      reason: 'выход на своём сервере не должен разлогинивать основной домен',
    );
    expect(
      prefs.getString(SessionStore.tokenKeyFor(_customServer)),
      isNull,
      reason: 'сессия области, из которой вышли, удалена',
    );
  });
}
