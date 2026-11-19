// Слепой ретранслятор: разбор адресов, выбор соединения, деградация.
//
// Главное свойство — запросы к основному домену уходят через ретранслятор
// как обычный `https://meander.illuminat.dev/...`: TLS терминирует клиент,
// сертификат проверяется по имени домена, ретранслятор видит только байты.
// Поэтому тесты держат три вещи:
//
// 1) туннелируется только https основного домена (не http, не чужие хосты);
// 2) мёртвый ретранслятор не ломает приложение — соединение идёт напрямую;
// 3) после серии отказов туннель выключается и зовёт обработчик смены пути.
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

  test('туннелируется только https основного домена', () {
    BlindTunnel.forceForTests('relay.local:8443');
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
      BlindTunnel.shouldTunnel(Uri.parse('https://other.example/quests')),
      isFalse,
      reason: 'чужой хост через наш ретранслятор — лишний хоп без выгоды',
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
    // Счётчик принятых соединений: TLS-рукопожатие тут заведомо провалится
    // (сервер не TLS), важно лишь, что TCP дошёл до цели, а не до ретранслятора.
    var accepted = 0;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      accepted++;
      socket.destroy();
    });

    // Сначала ретранслятор (install() выставляет хосты сборки), потом
    // подмена набора хостов для теста.
    BlindTunnel.forceForTests('127.0.0.1:1'); // порт 1: соединения нет
    BlindTunnel.setTunnelHostsForTests({'127.0.0.1'});

    // connect() возвращает задачу сразу; TLS-рукопожатие падает при ожидании
    // сокета — сервер не TLS и рвёт соединение. Каждая попытка обязана дойти
    // до цели напрямую, а не умереть на мёртвом ретрансляторе.
    for (var i = 1; i <= BlindTunnel.failuresBeforeFallback; i++) {
      final task = await BlindTunnel.connect(
        Uri.parse('https://127.0.0.1:${server.port}/'),
      );
      await expectLater(task.socket, throwsA(anything));
      expect(
        accepted,
        i,
        reason: 'после отказа ретранслятора соединение открывается напрямую',
      );
    }
    expect(
      BlindTunnel.enabled,
      isFalse,
      reason: 'серия отказов выключает ретранслятор и запускает смену пути',
    );
  });

  test('после серии отказов туннель выключается и зовёт смену пути', () {
    var switches = 0;
    BlindTunnel.onExhausted = () async => switches++;
    BlindTunnel.forceForTests('relay.local:8443');
    expect(BlindTunnel.enabled, isTrue);

    for (var i = 1; i < BlindTunnel.failuresBeforeFallback; i++) {
      BlindTunnel.reportFailure();
      expect(BlindTunnel.enabled, isTrue, reason: 'один сбой — ещё не приговор');
      expect(switches, 0);
    }
    BlindTunnel.reportFailure();

    expect(BlindTunnel.enabled, isFalse);
    expect(switches, 1);
    expect(BlindTunnel.endpoint, isNull);
  });

  test('отказы без туннеля игнорируются', () {
    var switches = 0;
    BlindTunnel.onExhausted = () async => switches++;
    for (var i = 0; i < BlindTunnel.failuresBeforeFallback * 2; i++) {
      BlindTunnel.reportFailure();
    }
    expect(switches, 0);
  });

  test('живой ретранслятор включается, мёртвый — нет', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);

    final live = await BlindTunnel.useEndpoint('127.0.0.1:${listener.port}');
    expect(live, isTrue);
    expect(BlindTunnel.endpoint, '127.0.0.1:${listener.port}');
    expect(BlindTunnel.enabled, isTrue);

    BlindTunnel.disable();
    expect(BlindTunnel.enabled, isFalse);

    expect(await BlindTunnel.useEndpoint('127.0.0.1:1'), isFalse);
    expect(await BlindTunnel.useEndpoint('мусор'), isFalse);
    expect(BlindTunnel.enabled, isFalse);
  });
}