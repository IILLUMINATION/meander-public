// Тесты книги зеркал: нормализация адреса, порядок зеркал, добавление и
// удаление пользовательских серверов, миграция старого одиночного зеркала,
// маркер все-зеркала-недоступны и текст ошибки.
import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/services/mirror_registry.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MirrorRegistry.skipRealNetwork = false;
    MirrorRegistry.probeOverride = null;
    MirrorRegistry.instance.resetForTests();
  });

  test('normalizeForPreview: добавляет https, срезает хвостовые слэши',
      () async {
    expect(
      MirrorRegistry.normalizeForPreview('example.com'),
      'https://example.com',
    );
    expect(
      MirrorRegistry.normalizeForPreview('https://example.com/'),
      'https://example.com',
    );
    expect(MirrorRegistry.normalizeForPreview('  '), isNull);
    expect(MirrorRegistry.normalizeForPreview('http://'), isNull);
    expect(MirrorRegistry.normalizeForPreview(null), isNull);
  });

  test('активное зеркало по умолчанию — основной домен', () async {
    expect(AppConfig.apiUrl, AppConfig.vpsApiBaseUrl);
  });

  test('несколько своих серверов попадают в книгу после дефолтов', () async {
    await MirrorRegistry.instance.ensureLoaded();
    await MirrorRegistry.instance.addCustomUrl('https://a.server');
    await MirrorRegistry.instance.addCustomUrl('https://b.server');
    final urls = MirrorRegistry.instance.allUrls;
    expect(urls, containsAll(['https://a.server', 'https://b.server']),
        reason: 'все пользовательские серверы в переборе');
    expect(
      urls,
      contains(AppConfig.vpsApiBaseUrl),
      reason: 'встроенные зеркала остаются в переборе',
    );
  });

  test('дубликат и дефолтный URL не добавляются дважды', () async {
    await MirrorRegistry.instance.ensureLoaded();
    final first = await MirrorRegistry.instance
        .addCustomUrl('https://a.server');
    final dup = await MirrorRegistry.instance
        .addCustomUrl('https://a.server/');
    final def = await MirrorRegistry.instance
        .addCustomUrl(AppConfig.vpsApiBaseUrl);
    expect(first, 'https://a.server');
    expect(dup, 'https://a.server');
    expect(def, AppConfig.vpsApiBaseUrl);
    expect(
      MirrorRegistry.instance.customUrls.where((u) => u == first).length,
      1,
      reason: 'дубликат не расширяет книгу',
    );
    expect(MirrorRegistry.instance.customUrls, isNot(contains(def)),
        reason: 'дефолтное зеркало уже в книге отдельной строкой');
  });

  test('удаление своего сервера возвращает активным основной домен',
      () async {
    await MirrorRegistry.instance.ensureLoaded();
    await MirrorRegistry.instance.addCustomUrl('https://my.server');
    await MirrorRegistry.instance.setActiveUrl('https://my.server');
    await MirrorRegistry.instance.removeCustomUrl('https://my.server');
    expect(MirrorRegistry.instance.activeUrl, AppConfig.vpsApiBaseUrl);
    expect(MirrorRegistry.instance.customUrls, isEmpty);
  });

  test('пинг от probe — число; probeOverride=false убивает все зеркала',
      () async {
    await MirrorRegistry.instance.ensureLoaded();
    MirrorRegistry.probeOverride = true;
    expect(await MirrorRegistry.instance.probeUrl('https://x'), 1);
    MirrorRegistry.probeOverride = false;
    expect(await MirrorRegistry.instance.probeUrl('https://x'), isNull);
    final pings = await MirrorRegistry.instance.probeAll();
    expect(pings.values, everyElement(isNull));
    expect(await MirrorRegistry.instance.autoSelectFastest(), isNull);
  });

  test('автовыбор при живых зеркалах переключает активное', () async {
    await MirrorRegistry.instance.ensureLoaded();
    MirrorRegistry.probeOverride = true; // все зеркала «живые», пинг 1ms
    final chosen = await MirrorRegistry.instance.autoSelectFastest();
    expect(chosen, isNotNull,
        reason: 'при живых зеркалах автовыбор обязан выбрать что-то');
    expect(MirrorRegistry.instance.activeUrl, chosen);
  });

  test('миграция: старый одиночный custom url переезжает в книгу', () async {
    SharedPreferences.setMockInitialValues({
      'mirror_custom_url': 'https://legacy.server',
    });
    await MirrorRegistry.instance.ensureLoaded();
    expect(
      MirrorRegistry.instance.customUrls,
      contains('https://legacy.server'),
      reason: 'зеркало из прошлой версии не теряется',
    );
  });

  test(
      'все зеркала недоступны — friendlyError формулирует через '
      '«ускоритель интернета», без запрещённых терминов', () async {
    final text = friendlyError(
      Exception(MirrorRegistry.allMirrorsDownMarker),
    );
    expect(text, contains('ускорител'));
    expect(text, contains('зеркало'));
    // Термин VPN в интерфейсе нельзя упоминать.
    expect(text.toLowerCase(), isNot(contains('vpn')));
  });

  test('обычные сетевые ошибки не превращаются в сообщение про зеркала',
      () async {
    final text = friendlyError(Exception('SERVER_MAINTENANCE'));
    expect(text, contains('обслуживании'));
  });

  group('встроенные зеркала', () {
    test('основной домен первым, публичные зеркала после него', () {
      // Зеркала нужны, когда основной домен заблокирован в сети игрока;
      // порядок — приоритет перебора, поэтому первым идёт свой домен.
      expect(AppConfig.defaultMirrorUrls.first, AppConfig.vpsApiBaseUrl);
      expect(
        AppConfig.defaultMirrorUrls,
        containsAll(<String>[
          'http://78.154.103.40:14175',
          'https://meander.elitrycraft.workers.dev',
          'https://meander.hashai.cc.cd',
        ]),
      );
      expect(
        AppConfig.defaultMirrorUrls.toSet().length,
        AppConfig.defaultMirrorUrls.length,
        reason: 'одно зеркало не должно попасть в список дважды',
      );
    });

    test('зонд отвергает зеркало с 5xx, живое — принимает', () async {
      // Flutter-тест подменяет HttpClient заглушкой, отвечающей 400 на всё:
      // для зонда нужен настоящий клиент к локальному серверу.
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = saved);
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      dead.listen((req) async {
        // Ровно то, что отдавал Cloudflare для снятого worker'а.
        req.response.statusCode = 530;
        await req.response.close();
      });
      final alive = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      alive.listen((req) async {
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
      });
      addTearDown(() async {
        await dead.close(force: true);
        await alive.close(force: true);
      });

      expect(
        await MirrorRegistry.instance
            .probeUrl('http://127.0.0.1:${dead.port}'),
        isNull,
        reason: 'ответ 530 — это не «зеркало живо»',
      );
      expect(
        await MirrorRegistry.instance
            .probeUrl('http://127.0.0.1:${alive.port}'),
        isNotNull,
      );
    });

    test('сохранённое активное зеркало, которого нет в списке, сбрасывается '
        'на основной домен', () async {
      SharedPreferences.setMockInitialValues({
        'mirror_active_url': 'https://gone.example',
      });
      MirrorRegistry.instance.resetForTests();
      await MirrorRegistry.instance.ensureLoaded();
      expect(MirrorRegistry.instance.activeUrl, AppConfig.vpsApiBaseUrl);
    });
  });

    test('встроенное зеркало не дублируется в пользовательских', () async {
      SharedPreferences.setMockInitialValues({
        'mirror_custom_urls': '["https://meander.hashai.cc.cd"]',
        'mirror_active_url': 'https://meander.hashai.cc.cd',
      });
      MirrorRegistry.instance.resetForTests();
      await MirrorRegistry.instance.ensureLoaded();
      expect(
        MirrorRegistry.instance.allUrls
            .where((u) => u == 'https://meander.hashai.cc.cd')
            .length,
        1,
        reason: 'зеркало из сборки перебирается один раз',
      );
      expect(MirrorRegistry.instance.activeUrl, 'https://meander.hashai.cc.cd');
    });
}
