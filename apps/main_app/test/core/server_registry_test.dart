// Выбор пути к API: только оригинал, свой сервер и слепые ретрансляторы.
//
// Прокси-зеркал в этой модели нет вовсе, поэтому тесты стерегут три вещи:
// 1) старые адреса зеркал вычищаются и никогда не выбираются;
// 2) прямое соединение проверяется первым — ретранслятор не грузится зря;
// 3) если напрямую не вышло, перебираются ретрансляторы (свои раньше
//    встроенных), и только реальный HTTP-ответ считается успехом.
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/net/blind_tunnel.dart';
import 'package:canvas_app/core/services/relay_registry.dart';
import 'package:canvas_app/core/services/server_registry.dart';
import 'package:canvas_app/core/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final registry = ServerRegistry.instance;
  final relays = RelayRegistry.instance;
  const primary = AppConfig.vpsApiBaseUrl;
  const ownRelay = 'mine.example:9443';
  const builtInRelay = 'relay.builtin.example:8443';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    registry.resetForTests();
    relays.resetForTests();
    BlindTunnel.resetForTests();
    RelayRegistry.builtInOverride = [builtInRelay];
  });

  tearDown(() {
    registry.resetForTests();
    relays.resetForTests();
    BlindTunnel.resetForTests();
  });

  test('по умолчанию — оригинал, прокси-зеркал в списке нет', () async {
    await registry.ensureLoaded();
    expect(registry.activeUrl, primary);
    expect(registry.allUrls, [primary]);
    for (final retired in AppConfig.retiredProxyUrls) {
      expect(registry.allUrls, isNot(contains(retired)));
    }
  });

  test('старые ключи зеркал мигрируют, прокси-адреса вычищаются', () async {
    SharedPreferences.setMockInitialValues({
      'mirror_active_url': AppConfig.retiredProxyUrls.first,
      'mirror_custom_urls':
          '["${AppConfig.retiredProxyUrls.last}", "https://my.server"]',
      'mirror_custom_url': 'https://single.server',
    });
    await registry.ensureLoaded();

    expect(registry.customUrls, ['https://my.server', 'https://single.server']);
    expect(
      registry.activeUrl,
      primary,
      reason: 'активное зеркало-прокси не может остаться выбранным',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('server_active_url'), primary);
    expect(prefs.getString('mirror_active_url'), isNull);
    expect(prefs.getString('mirror_custom_urls'), isNull);
    expect(prefs.getString('mirror_custom_url'), isNull);
  });

  test('публичный http URL не принимается, чтобы токен не уходил открыто', () async {
    expect(await registry.addCustomUrl('http://public.example'), isNull);
    expect(registry.allUrls, [primary]);
  });

  test('прямой путь проверяется первым и отключает туннель', () async {
    BlindTunnel.forceForTests(builtInRelay);
    ServerRegistry.probeHook = (url) async => url == primary ? 12 : null;

    expect(await registry.ensureReachable(), isTrue);
    expect(BlindTunnel.enabled, isFalse);
  });

  test('прямой путь мёртв — включается свой ретранслятор раньше встроенного',
      () async {
    await relays.addCustom(ownRelay);
    RelayRegistry.probeHook = (endpoint) async => true;
    ServerRegistry.probeHook = (url) async =>
        BlindTunnel.enabled && BlindTunnel.endpoint == ownRelay ? 20 : null;

    expect(await registry.ensureReachable(), isTrue);
    expect(BlindTunnel.endpoint, ownRelay);
  });

  test('мёртвый ретранслятор пропускается: берётся следующий', () async {
    await relays.addCustom(ownRelay);
    RelayRegistry.probeHook = (endpoint) async => endpoint != ownRelay;
    ServerRegistry.probeHook = (url) async =>
        BlindTunnel.enabled && BlindTunnel.endpoint == builtInRelay ? 30 : null;

    expect(await registry.ensureReachable(), isTrue);
    expect(BlindTunnel.endpoint, builtInRelay);
  });

  test('выключенный ретранслятор не используется даже как последний шанс',
      () async {
    await relays.addCustom(ownRelay);
    await relays.setEnabled(ownRelay, false);
    RelayRegistry.probeHook = (endpoint) async => true;
    ServerRegistry.probeHook = (url) async =>
        BlindTunnel.enabled && BlindTunnel.endpoint == ownRelay ? 20 : null;

    expect(await registry.ensureReachable(), isFalse);
    expect(BlindTunnel.enabled, isFalse);
  });

  test('все пути мертвы — маркер и выключенный туннель', () async {
    RelayRegistry.probeHook = (endpoint) async => true;
    ServerRegistry.probeHook = (url) async => null;

    expect(await registry.ensureReachable(), isFalse);
    expect(BlindTunnel.enabled, isFalse);
    expect(ServerRegistry.allServersDownMarker, 'ALL_SERVERS_DOWN');
  });

  test('свой сервер: выбранный, но мёртвый — возврат к оригиналу', () async {
    await registry.addCustomUrl('https://my.server');
    await registry.setActiveUrl('https://my.server');
    expect(registry.activeUrl, 'https://my.server');

    ServerRegistry.probeHook = (url) async => url == primary ? 5 : null;

    expect(await registry.ensureReachable(), isTrue);
    expect(registry.activeUrl, primary);
  });

  test('выбор своего сервера выключает туннель', () async {
    await registry.addCustomUrl('https://my.server');
    BlindTunnel.forceForTests(builtInRelay);
    await registry.setActiveUrl('https://my.server');
    expect(BlindTunnel.enabled, isFalse);
  });

  test('смена пути после отказа ретранслятора: следующий, затем прямое',
      () async {
    await relays.addCustom(ownRelay);
    BlindTunnel.forceForTests(builtInRelay);
    RelayRegistry.probeHook = (endpoint) async => true;
    ServerRegistry.probeHook = (url) async =>
        BlindTunnel.enabled && BlindTunnel.endpoint == ownRelay ? 10 : null;

    await registry.handleTunnelFailure();
    expect(BlindTunnel.endpoint, ownRelay);

    // Свой тоже умер — возвращаемся на прямое соединение.
    ServerRegistry.probeHook = (url) async => BlindTunnel.enabled ? null : 7;
    await registry.handleTunnelFailure();
    expect(BlindTunnel.enabled, isFalse);
  });

  test('сессия привязана к серверу: домен области доверия', () async {
    expect(ServerRegistry.domainFor(primary), SessionStore.primaryDomain);
    expect(
      ServerRegistry.domainFor('https://my.server/'),
      'https://my.server',
    );
  });

  test('нормализация адреса: схема и хвостовой слэш', () {
    expect(
      ServerRegistry.normalizeForPreview('my.server/'),
      'https://my.server',
    );
    expect(
      ServerRegistry.normalizeForPreview('  http://my.server/  '),
      isNull,
      reason: 'публичный http отправил бы сессию открытым текстом',
    );
    expect(
      ServerRegistry.normalizeForPreview('http://192.168.0.5:3000/'),
      'http://192.168.0.5:3000',
      reason: 'локальный dev-бэкенд по http остаётся допустимым',
    );
    expect(ServerRegistry.normalizeForPreview('   '), isNull);
  });
}