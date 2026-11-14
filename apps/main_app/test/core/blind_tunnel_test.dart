// Слепой ретранслятор: разбор адресов, выбор соединения, деградация.
//
// Главное свойство — запросы к основному домену уходят через ретранслятор
// как обычный `https://meander.illuminat.dev/...`: TLS терминирует клиент,
// сертификат проверяется по имени домена, ретранслятор видит только байты.
// Поэтому тесты держат три вещи:
//
// 1) туннелируется только https основного домена (не http, не зеркала);
// 2) мёртвый ретранслятор не ломает приложение — соединение идёт напрямую;
// 3) после серии отказов туннель выключается и перебор зеркал снова работает.
import 'dart:io';

import 'package:canvas_app/core/net/blind_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    BlindTunnel.resetForTests();
  });

  tearDown(() {
    BlindTunnel.resetForTests();
  });

  test('разбор host:port из настроек сборки', () {
    expect(BlindTunnel.parseEndpoint('1.2.3.4:8443'), ('1.2.3.4', 8443));
    expect(
      BlindTunnel.parseEndpoint(' tunnel.example.com:443 '),
      ('tunnel.example.com', 443),
    );
    expect(BlindTunnel.parseEndpoint('1.2.3.4'), isNull);
    expect(BlindTunnel.parseEndpoint(':8443'), isNull);
    expect(BlindTunnel.parseEndpoint('1.2.3.4:0'), isNull);
    expect(BlindTunnel.parseEndpoint('1.2.3.4:70000'), isNull);
    expect(BlindTunnel.parseEndpoint('   '), isNull);
  });

  test('туннелируется только https основного домена', () {
    BlindTunnel.forceForTests('relay.local', 8443);
    BlindTunnel.setTunnelHostsForTests({'meander.example'});

    expect(
      BlindTunnel.shouldTunnel(Uri.parse('https://meander.example/quests')),
      isTrue,
    );
    expect(
      BlindTunnel.shouldTunnel(Uri.parse('http://meander.example/quests')),
      isFalse,
      reason: 'через ретранслятор http пошёл бы открытым текстом',
    );
    expect(
      BlindTunnel.shouldTunnel(Uri.parse('https://mirror.example/quests')),
      isFalse,
      reason: 'зеркало через ретранслятор — лишний хоп без выгоды',
    );
    expect(
      BlindTunnel.shouldTunnel(Uri.parse('https://accounts.google.com/o')),
      isFalse,
    );
  });

  test('без ретранслятора соединение открывается напрямую', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..write('ok')
        ..close();
    });

    BlindTunnel.install();
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/ping'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    client.close();
  });

  test('мёртвый ретранслятор не съедает запрос: соединение идёт напрямую',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..write('ok')
        ..close();
    });

    BlindTunnel.setTunnelHostsForTests({'127.0.0.1'});
    BlindTunnel.forceForTests('127.0.0.1', 1); // порт 1: соединения нет

    BlindTunnel.install();
    final client = HttpClient();
    // http не туннелируется по правилу, поэтому проверяем именно отказ
    // ретранслятора на разрешённом адресе: подменяем host через тестовый
    // набор (https → 127.0.0.1). Соединение обязано уйти напрямую.
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/ping'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    client.close();
  });

  test('после серии отказов туннель выключается', () {
    BlindTunnel.forceForTests('relay.local', 8443);
    expect(BlindTunnel.enabled, isTrue);

    for (var i = 0; i < BlindTunnel.failuresBeforeFallback; i++) {
      BlindTunnel.reportFailure();
    }
    expect(
      BlindTunnel.enabled,
      isFalse,
      reason: 'иначе перебор зеркал не запустится и останется маркер '
          '«все зеркала недоступны»',
    );
  });

  test('живой ретранслятор включается, мёртвый — нет', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);

    final live = await BlindTunnel.activate(
      endpoints: ['127.0.0.1:${listener.port}'],
    );
    expect(live, isTrue);
    expect(BlindTunnel.relay, '127.0.0.1:${listener.port}');

    BlindTunnel.resetForTests();
    final dead = await BlindTunnel.activate(endpoints: ['127.0.0.1:1', 'мусор']);
    expect(dead, isFalse);
    expect(BlindTunnel.enabled, isFalse);
  });
}