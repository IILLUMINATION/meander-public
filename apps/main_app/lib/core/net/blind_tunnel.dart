import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/services/relay_registry.dart';
import 'package:flutter/foundation.dart';

/// Слепой ретранслятор TLS до основного домена.
///
/// Прокси обязан терминировать TLS, чтобы разложить запросы по путям, — и
/// видит всё: токен, idToken, переписку. Ретранслятор наоборот: приложение
/// открывает TCP до него, а TLS-рукопожатие делает **само с основным
/// доменом**. Сертификат проверяется по имени хоста из
/// [AppConfig.vpsApiBaseUrl], ретранслятор видит только зашифрованные байты.
///
/// Выбор пути (прямой / какой ретранслятор) — в `ServerRegistry`; здесь только
/// транспорт: включить конкретный адрес, выключить, прозрачно подставить его в
/// HTTP-клиенты.
///
/// [install] ставит [HttpOverrides] глобально, поэтому покрывает и `http`-пакет,
/// и прямые `dart:io`-запросы по экранам, и websocket socket.io.
class BlindTunnel {
  BlindTunnel._();

  static bool _installed = false;
  static bool _enabled = false;
  static String? _endpoint;
  static Set<String> _tunnelHosts = {};

  /// Сколько сетевых отказов подряд считаются падением ретранслятора.
  static const int failuresBeforeFallback = 3;
  static int _failures = 0;

  /// Что делать, когда ретранслятор признан мёртвым. Ставит `ServerRegistry`:
  /// перебрать следующий ретранслятор, затем прямой путь.
  static Future<void> Function()? onExhausted;

  /// Запросы к основному домену идут через ретранслятор.
  static bool get enabled => _enabled && _endpoint != null;

  /// `host:port` активного ретранслятора — для логов и настроек.
  static String? get endpoint => enabled ? _endpoint : null;

  /// Поставить перехват создания HTTP-клиентов. Идемпотентно; вызывается до
  /// первого кадра, чтобы все клиенты приложения уже были с фабрикой.
  static void install() {
    if (_installed) return;
    _installed = true;
    _tunnelHosts = {Uri.parse(AppConfig.vpsApiBaseUrl).host};
    HttpOverrides.global = _TunnelHttpOverrides();
  }

  /// Проверить ретранслятор и включить его. `false` — адрес не отвечает или
  /// записан некорректно.
  static Future<bool> useEndpoint(String raw) async {
    install();
    final parsed = RelayRegistry.parse(raw);
    if (parsed == null) return false;
    final ok = await RelayRegistry.instance.probe(parsed);
    if (!ok) {
      debugPrint('[Tunnel] $parsed не отвечает');
      return false;
    }
    _endpoint = parsed;
    _enabled = true;
    _failures = 0;
    debugPrint('[Tunnel] relay $parsed');
    return true;
  }

  /// Выключить туннель: соединения идут напрямую.
  static void disable() {
    _enabled = false;
    _failures = 0;
  }

  /// Сетевой отказ при активном туннеле. После [failuresBeforeFallback]
  /// отказов подряд ретранслятор считается мёртвым, и [onExhausted] выбирает
  /// следующий путь (другой ретранслятор или прямое соединение).
  static void reportFailure() {
    if (!enabled) return;
    _failures += 1;
    if (_failures < failuresBeforeFallback) return;
    final failed = _endpoint;
    _enabled = false;
    _failures = 0;
    debugPrint('[Tunnel] $failed failed, switching path');
    final handler = onExhausted;
    if (handler != null) unawaited(handler());
  }

  /// Отправлять ли запрос [uri] через ретранслятор. Вынесено ради тестов:
  /// только https основного домена.
  static bool shouldTunnel(Uri uri) =>
      enabled && uri.scheme == 'https' && _tunnelHosts.contains(uri.host);

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
      final parsed = RelayRegistry.parse(_endpoint);
      if (parsed != null) {
        final colon = parsed.lastIndexOf(':');
        final host = parsed.substring(0, colon);
        final relayPort = int.parse(parsed.substring(colon + 1));
        ConnectionTask<Socket>? relayTask;
        try {
          relayTask = _secureOver(
            await Socket.startConnect(host, relayPort),
            uri.host,
          );
        } catch (e) {
          debugPrint('[Tunnel] connect to relay failed: $e');
        }
        if (relayTask != null) {
          final relay = relayTask;
          // Ретранслятор принял TCP, но TLS-рукопожатие через него не прошло
          // (упал, отдал мусор, порт занят чужим): не роняем запрос, а
          // повторяем его напрямую. Счётчик отказов переключит путь.
          final merged = relay.socket.then<Socket>(
            (socket) => socket,
            onError: (Object error) {
              reportFailure();
              debugPrint('[Tunnel] relay handshake failed: $error');
              return Socket.startConnect(uri.host, port).then(
                (task) => uri.scheme == 'https'
                    ? _secureOver(task, uri.host).socket
                    : task.socket,
              );
            },
          );
          return ConnectionTask.fromSocket<Socket>(merged, relay.cancel);
        }
        _enabled = false;
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

  /// Сброс состояния (только тесты).
  @visibleForTesting
  static void resetForTests() {
    _installed = false;
    _enabled = false;
    _endpoint = null;
    _tunnelHosts = {};
    _failures = 0;
    onExhausted = null;
    HttpOverrides.global = null;
  }

  /// Подменить набор доменов, которые туннелируются (только тесты).
  @visibleForTesting
  static void setTunnelHostsForTests(Set<String> hosts) {
    _tunnelHosts = hosts;
  }

  /// Включить туннель на заданный адрес без сетевой пробы (только тесты).
  @visibleForTesting
  static void forceForTests(String endpoint) {
    install();
    _endpoint = endpoint;
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