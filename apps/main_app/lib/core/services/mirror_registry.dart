import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/config.dart';

/// Перебор зеркал бэкенда.
///
/// Основной домен может быть заблокирован в сети пользователя (в РФ —
/// по решению РКН): тогда приложение последовательно пробует зеркала из
/// [AppConfig.defaultMirrorUrls] и пользовательское зеркало из настроек.
///
/// Активное зеркало хранится в SharedPreferences и переживает запуск.
/// Переключение происходит только по реальному отказу (сеть/таймаут/5xx):
/// «недоступно прямо сейчас» не означает «недоступно навсегда», поэтому
/// список перебирается циклом и каждое заново проверяется.
class MirrorRegistry {
  MirrorRegistry._();
  static final MirrorRegistry instance = MirrorRegistry._();

  static const _activeUrlKey = 'mirror_active_url';
  static const _customUrlKey = 'mirror_custom_url';

  /// Фейк для тестов: `null` — реальные сетевые зонды, `true`/`false` —
  /// результат зонда, не трогая сеть.
  static bool? probeOverride;

  /// Проверяет ли запрос живость зеркала в фоне перед UI-попыткой.
  /// Используется тестами и явной кнопкой «Проверить».
  static bool skipRealNetwork = false;

  /// Активный базовый URL для [AppConfig.apiUrl].
  String get activeUrl => _activeUrl ?? AppConfig.vpsApiBaseUrl;
  String? _activeUrl;

  /// Пользовательское зеркало/свой сервер из настроек.
  String? _customUrl;
  String? get customUrl => _customUrl;

  /// Загружена ли адресная книга (int активное-зеркало).
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _customUrl = prefs.getString(_customUrlKey);
    _activeUrl = prefs.getString(_activeUrlKey);
    if (_activeUrl == null || !allUrls.contains(_activeUrl)) {
      _activeUrl = allUrls.first;
    }
    _loaded = true;
  }

  /// Все URL в порядке приоритета: активное первым (его проверяем раньше
  /// всего), затем остальные дефолты, пользовательское — сразу после
  /// активного, чтобы быстрее дойти до него при рабочем зеркале.
  List<String> get allUrls {
    final list = <String>[...AppConfig.defaultMirrorUrls];
    final custom = _customUrl;
    if (custom != null && custom.isNotEmpty && !list.contains(custom)) {
      list.insert(custom == _activeUrl ? 0 : 1, custom);
    }
    final active = _activeUrl;
    if (active != null && list.contains(active)) {
      list
        ..remove(active)
        ..insert(0, active);
    }
    return list;
  }

  /// Установить пользовательское зеркало/сервер. Пустая строка/`null` —
  /// сброс. Смена пользовательского адреса убивает кэш здоровья активного
  /// зеркала и проверяет его первым.
  Future<void> setCustomUrl(String? url) async {
    var normalized = _normalize(url);
    if (normalized == AppConfig.vpsApiBaseUrl ||
        normalized == '') {
      normalized = null;
    }
    _customUrl = normalized;
    _activeUrl = normalized ?? AppConfig.vpsApiBaseUrl;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customUrlKey, normalized ?? '');
    await prefs.setString(_activeUrlKey, _activeUrl!);
    debugPrint('[Mirror] custom=$normalized active=$_activeUrl');
  }

  /// Сохранить активное зеркало после успешной проверки.
  Future<void> _persistActive(String url) async {
    _activeUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeUrlKey, url);
  }

  /// Проверить доступность URL. Считаем живым любой HTTP-ответ бэкенда:
  /// даже 404/500 на случайный GET значит, что хост резолвится, TLS
  /// поднимается и фильтрация его не режет. Это быстрее и надёжнее
  /// отдельного /health, которого на старых бэкендах нет.
  Future<bool> _probe(String url) async {
    if (probeOverride != null) return probeOverride!;
    if (skipRealNetwork) return true;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final request = await client
          .headUrl(Uri.parse('$url/'))
          .timeout(const Duration(seconds: 5));
      await request.close().timeout(const Duration(seconds: 5));
      client.close();
      debugPrint('[Mirror] probe OK: $url');
      return true;
    } catch (e) {
      debugPrint('[Mirror] probe FAIL: $url ($e)');
      return false;
    }
  }

  /// Перебрать зеркала слева-направо, вернуть первое живое.
  /// Каждое молчащее зерно получает один шанс за цикл, активное — первым.
  Future<String?> _findReachable() async {
    try {
      await _ensureLoaded();
    } catch (_) {}
    for (final url in allUrls) {
      if (await _probe(url)) return url;
    }
    return null;
  }

  /// Проверить активное зеркало; если мёртв — найти следующее живое и
  /// переключиться. Возвращает `true`, если после вызова активное зеркало
  /// живое (старое или новое).
  Future<bool> ensureReachable() async {
    try {
      await _ensureLoaded();
    } catch (_) {}
    if (await _probe(activeUrl)) return true;
    final next = await _findReachable();
    if (next == null) return false;
    await _persistActive(next);
    debugPrint('[Mirror] switched to $next');
    return true;
  }

  /// Перебор всех зеркал с проверкой: для экрана настроек (кнопка
  /// «Проверить подключение»).
  Future<List<(String, bool)>> probeAll() async {
    try {
      await _ensureLoaded();
    } catch (_) {}
    final results = <(String, bool)>[];
    for (final url in allUrls) {
      results.add((url, await _probe(url)));
    }
    return results;
  }
  /// Публичная проверка одного URL (для настроек/тестов).
  Future<bool> probeUrl(String url) => _probe(url);

  /// Публичная нормализация URL: без схемы → https, без хвостовых `/`.
  /// `null` — если адрес не парсится.
  static String? normalizeForPreview(String? url) => _normalize(url);

  /// Все зеркала недоступны и сеть вроде есть — специальный маркер для
  /// UI: формулировка без запрещённых терминов (см. friendlyError).
  static const allMirrorsDownMarker = 'ALL_MIRRORS_DOWN';

  static String? _normalize(String? url) {
    if (url == null) return null;
    var trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    if (!trimmed.startsWith('http://') &&
        !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    trimmed = trimmed.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return null;
    return trimmed;
  }
}
