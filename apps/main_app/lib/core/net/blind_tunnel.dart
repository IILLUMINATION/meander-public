import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:flutter/foundation.dart';

/// Слепой ретранслятор TLS до основного домена.
///
/// Зеркало-прокси (`https://…`) расшифровывает трафик, чтобы разложить его по
/// путям, — поэтому оно видит `Authorization`, idToken и переписку. Здесь
/// наоборот: приложение открывает TCP до ретранслятора, а TLS-рукопожатие
/// делает **само с основным доменом**. Сертификат проверяется по имени
/// хоста из [AppConfig.vpsApiBaseUrl], ретранслятор видит только
/// зашифрованные байты.
///
/// Так устроены прокси у Telegram: посредник перекладывает байты и не знает
/// ключей, поэтому «украсть токен» ему не из чего.
///
/// Подменять можно только `https` на основном домене: tunneled `http://`
/// означал бы, что ретранслятор видит открытый текст, а tunneled зеркало —
/// лишний хоп.
///
/// [install] ставит [HttpOverrides] глобально, поэтому покрывает и `http`-пакет,
/// и прямые `dart:io`-запросы по экранам, и websocket socket.io.
class BlindTunnel {
  BlindTunnel._();

  static bool _installed = false;
  static bool _enabled = false;
  static String? _relayHost;
  static int? _relayPort;
  static Set<String> _tunnelHosts = {};

  /// Только тесты: `true` — ретранслятор «жив», не трогая сеть.
  static bool? probeOverride;

  /// Сколько сетевых отказов подряд выключают туннель: ретранслятор мог
  /// умереть, и тогда честнее вернуться к зеркалам, чем отдавать маркер
  /// «все зеркала недоступны».
  static const int failuresBeforeFallback = 3;
  static int _failures = 0;
  static Timer? _retryTimer;
  static bool _activating = false;

  /// Туннель активен и запросы к основному домену идут через ретранслятор.
  static bool get enabled => _enabled && _relayHost != null;

  /// `host:port` активного ретранслятора — для логов и настроек.
  static String? get relay => enabled ? '$_relayHost:$_relayPort' : null;

  /// Поставить перехват создания HTTP-клиентов. Идемпотентно; вызывается до
  /// первого кадра, чтобы все клиенты приложения уже были с фабрикой.
  static void install() {
    if (_installed) return;
    _installed = true;
    _tunnelHosts = {Uri.parse(AppConfig.vpsApiBaseUrl).host};
    HttpOverrides.global = _TunnelHttpOverrides();
  }

  /// Проверить ретрансляторы и включить первый живой. `false` — ни один не
  /// ответил, приложение работает напрямую, как раньше.
  ///
  /// Зонды идут параллельно: последовательный перебор при мёртвом первом
  /// адресе задерживал старт на таймаут каждого.
  static Future<bool> activate({Iterable<String>? endpoints}) async {
    install();
    if (_activating) return enabled;
    _activating = true;
    try {
      final candidates = (endpoints ?? AppConfig.relayUrls)
          .map(parseEndpoint)
          .whereType<(String, int)>()
          .toList();
      final probes = await Future.wait(
        candidates.map((e) => _probe(e.$1, e.$2)),
      );
      final index = probes.indexOf(true);
      if (index >= 0) {
        final (host, port) = candidates[index];
        _relayHost = host;
        _relayPort = port;
        _enabled = true;
        _failures = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
        debugPrint('[Tunnel] relay $host:$port');
        return true;
      }
      _enabled = false;
      debugPrint('[Tunnel] no relay reachable, direct connection');
      _scheduleRetry();
      return false;
    } finally {
      _activating = false;
    }
  }

  /// Ретранслятор может быть просто занят или сеть медленная на старте:
  /// пробуем ещё раз в фоне, не задерживая приложение.
  static void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(minutes: 2), () {
      unawaited(activate());
    });
  }

  /// Сетевой отказ при активном туннеле. После [failuresBeforeFallback]
  /// отказов подряд туннель выключается и пробуется снова через минуту, а
  /// вызывающий код идёт обычным перебором зеркал.
  static void reportFailure() {
    if (!enabled) return;
    _failures += 1;
    if (_failures < failuresBeforeFallback) return;
    _enabled = false;
    _failures = 0;
    debugPrint('[Tunnel] relay ${relay ?? '?'} failed, falling back to mirrors');
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(minutes: 1), () {
      unawaited(activate());
    });
  }

  /// Отправлять ли запрос [uri] через ретранслятор. Вынесено ради тестов:
  /// https + основной домен + живой ретранслятор.
  static bool shouldTunnel(Uri uri) =>
      enabled && uri.scheme == 'https' && _tunnelHosts.contains(uri.host);

  /// Разобрать `host:port` из настроек сборки.
  static (String, int)? parseEndpoint(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final colon = trimmed.lastIndexOf(':');
    if (colon <= 0 || colon == trimmed.length - 1) return null;
    final host = trimmed.substring(0, colon).trim();
    final port = int.tryParse(trimmed.substring(colon + 1).trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    return (host, port);
  }

  /// Соединение для [uri]: через ретранслятор или напрямую.
  ///
  /// Важно: если [HttpClient.connectionFactory] задана, dart:io **не**
  /// оборачивает сокет в TLS сам — он считает, что фабрика вернула готовое
  /// соединение. Поэтому TLS поднимаем здесь: и для ретранслятора, и для
  /// прямого соединения. Иначе запрос уходит в 443 открытым текстом, и
  /// nginx отвечает «The plain HTTP request was sent to HTTPS port».
  ///
  /// Отказ ретранслятора на этом шаге не роняет запрос — соединение
  /// открывается напрямую. Сертификат в обоих случаях проверяется по имени
  /// из [uri].
  static Future<ConnectionTask<Socket>> connect(Uri uri) async {
    final port = uri.port == 0
        ? (uri.scheme == 'https' ? 443 : 80)
        : uri.port;

    if (shouldTunnel(uri)) {
      try {
        final task = await Socket.startConnect(_relayHost!, _relayPort!);
        return _secureOver(task, uri.host);
      } catch (e) {
        _enabled = false;
        debugPrint('[Tunnel] connect to relay failed: $e');
      }
    }

    final task = await Socket.startConnect(uri.host, port);
    return uri.scheme == 'https' ? _secureOver(task, uri.host) : task;
  }

  /// Обернуть соединение в TLS с проверкой сертификата по [host].
  static ConnectionTask<Socket> _secureOver(
    ConnectionTask<Socket> task,
    String host,
  ) {
    final secure = task.socket.then<Socket>(
      (raw) => SecureSocket.secure(raw, host: host),
    );
    return ConnectionTask.fromSocket<Socket>(secure, task.cancel);
  }

  static Future<bool> _probe(String host, int port) async {
    if (probeOverride != null) return probeOverride!;
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 1500),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Сброс состояния (только тесты).
  @visibleForTesting
  static void resetForTests() {
    _installed = false;
    _enabled = false;
    _relayHost = null;
    _relayPort = null;
    _tunnelHosts = {};
    _failures = 0;
    probeOverride = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _activating = false;
    HttpOverrides.global = null;
  }

  /// Подменить набор доменов, которые туннелируются (только тесты).
  @visibleForTesting
  static void setTunnelHostsForTests(Set<String> hosts) {
    _tunnelHosts = hosts;
  }

  /// Включить туннель на заданный адрес без сетевой пробы (только тесты).
  @visibleForTesting
  static void forceForTests(String host, int port) {
    install();
    _relayHost = host;
    _relayPort = port;
    _enabled = true;
  }
}

/// Все HTTP-клиенты, созданные после [BlindTunnel.install], получают фабрику
/// соединений. Через них идут и `http`-пакет, и прямые `dart:io`-запросы, и
/// websocket socket.io.
class _TunnelHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      return BlindTunnel.connect(uri);
    };
    return client;
  }
}