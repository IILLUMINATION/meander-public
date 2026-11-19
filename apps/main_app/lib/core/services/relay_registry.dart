import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/config.dart';

/// Ретрансляторы TLS: `host:port`, через которые приложение прокладывает
/// TCP-соединение к основному домену.
///
/// Ретранслятор не расшифровывает трафик: TLS терминирует сам клиент по имени
/// основного домена, поэтому посредник видит только байты. Любой желающий
/// может поднять свой (`relay/`) — это безопасно по построению.
///
/// Список — два источника: встроенный ([AppConfig.relayUrls], задаётся на
/// сборке) и добавленный пользователем в настройках. Включать и выключать
/// можно и те, и другие. Пользовательские идут первыми: так нагрузка уходит
/// на свой сервер, а не на встроенный VPS.
class RelayRegistry {
  RelayRegistry._();
  static final RelayRegistry instance = RelayRegistry._();

  static const _customKey = 'relay_custom_endpoints';
  static const _disabledKey = 'relay_disabled_endpoints';

  /// Сброс singleton-состояния (только тесты).
  @visibleForTesting
  void resetForTests() {
    _loaded = false;
    _custom = [];
    _disabled.clear();
    probeHook = null;
    builtInOverride = null;
  }

  List<String> _custom = [];
  final Set<String> _disabled = {};
  bool _loaded = false;

  /// Зонд для тестов: `endpoint → жив`. `null` — настоящий TCP-коннект.
  @visibleForTesting
  static Future<bool> Function(String endpoint)? probeHook;

  /// Список встроенных для тестов (иначе берётся из сборки).
  @visibleForTesting
  static List<String>? builtInOverride;

  /// Встроенные ретрансляторы из сборки.
  List<String> get builtIn =>
      (builtInOverride ?? AppConfig.relayUrls)
          .map(parse)
          .whereType<String>()
          .toList();

  /// Добавленные пользователем, в порядке добавления.
  List<String> get custom => List.unmodifiable(_custom);

  /// Все ретрансляторы: свои первыми, встроенные следом; без дубликатов.
  List<String> get all {
    final list = <String>[];
    for (final url in [..._custom, ...builtIn]) {
      if (!list.contains(url)) list.add(url);
    }
    return list;
  }

  /// Ретрансляторы, которые разрешено использовать.
  List<String> get enabled => all.where((e) => !_disabled.contains(e)).toList();

  bool isEnabled(String endpoint) => !_disabled.contains(endpoint);
  bool isBuiltIn(String endpoint) => builtIn.contains(endpoint);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_customKey);
    if (raw != null && raw.isNotEmpty) {
      _custom = (jsonDecode(raw) as List)
          .map((e) => parse(e?.toString()))
          .whereType<String>()
          .toList();
    }
    final disabled = prefs.getString(_disabledKey);
    if (disabled != null && disabled.isNotEmpty) {
      _disabled
        ..clear()
        ..addAll((jsonDecode(disabled) as List).map((e) => e.toString()));
    }
    _loaded = true;
  }

  /// Нормализовать `host:port`. Схемы и пути не принимаются: ретранслятор —
  /// это TCP-адрес, а не URL, и `http://` тут означал бы, что клиент
  /// отправит запросы открытым текстом.
  static String? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.contains('/')) return null;
    final colon = trimmed.lastIndexOf(':');
    if (colon <= 0 || colon == trimmed.length - 1) return null;
    final host = trimmed.substring(0, colon).trim();
    final port = int.tryParse(trimmed.substring(colon + 1).trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    if (host.contains(' ')) return null;
    return '$host:$port';
  }

  /// Добавить свой ретранслятор. `null` — некорректный адрес.
  Future<String?> addCustom(String raw) async {
    await ensureLoaded();
    final normalized = parse(raw);
    if (normalized == null) return null;
    if (!_custom.contains(normalized)) {
      _custom = [..._custom, normalized];
      await _saveCustom();
    }
    return normalized;
  }

  Future<void> removeCustom(String endpoint) async {
    await ensureLoaded();
    _custom = _custom.where((e) => e != endpoint).toList();
    await _saveCustom();
    if (_disabled.remove(endpoint)) await _saveDisabled();
  }

  /// Включить/выключить ретранслятор. Выключенный не пробуется и не
  /// используется.
  Future<void> setEnabled(String endpoint, bool value) async {
    await ensureLoaded();
    final changed = value ? _disabled.remove(endpoint) : _disabled.add(endpoint);
    if (changed) await _saveDisabled();
  }

  Future<void> _saveCustom() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customKey, jsonEncode(_custom));
  }

  Future<void> _saveDisabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_disabledKey, jsonEncode(_disabled.toList()));
  }

  /// Проверить один ретранслятор: TCP-соединение установилось.
  ///
  /// Это именно тот путь, которым пойдут запросы: TLS поверх него проверяет
  /// уже HttpClient, и подделка возможна только с валидным сертификатом
  /// основного домена.
  Future<bool> probe(String endpoint) async {
    final parsed = parse(endpoint);
    if (parsed == null) return false;
    final hook = probeHook;
    if (hook != null) return hook(parsed);
    final colon = parsed.lastIndexOf(':');
    final host = parsed.substring(0, colon);
    final port = int.parse(parsed.substring(colon + 1));
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

  /// Параллельная проверка всех ретрансляторов: `endpoint → жив`.
  Future<Map<String, bool>> probeAll() async {
    await ensureLoaded();
    final endpoints = all;
    final results = await Future.wait(endpoints.map(probe));
    return {
      for (var i = 0; i < endpoints.length; i++) endpoints[i]: results[i],
    };
  }
}