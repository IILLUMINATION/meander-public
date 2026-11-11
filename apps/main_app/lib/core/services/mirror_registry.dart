import 'dart:async';
import 'dart:convert';
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

  /// Зеркала, снятые из сборки. Они могут остаться в настройках у тех, кто
  /// обновился: такое зеркало отвечает 530, а зонд/приложение продолжали
  /// считать его живым и уводили на него весь трафик.
  static const retiredUrls = {'https://meander.elitrycraft.workers.dev'};
  static const _customUrlsKey = 'mirror_custom_urls';
  // Старый формат одиночного зеркала; читаем один раз для миграции.
  static const _legacyCustomUrlKey = 'mirror_custom_url';

  /// Сброс singleton-состояния (только тесты: книга перечитывается).
  @visibleForTesting
  void resetForTests() {
    _loaded = false;
    _activeUrl = null;
    _customUrls = [];
  }

  /// Фейк для тестов: `null` — реальные сетевые зонды, `true`/`false` —
  /// результат зонда, не трогая сеть.
  static bool? probeOverride;

  /// Проверяет ли запрос живость зеркала в фоне перед UI-попыткой.
  /// Используется тестами и явной кнопкой «Проверить».
  static bool skipRealNetwork = false;

  /// Активный базовый URL для [AppConfig.apiUrl].
  String get activeUrl => _activeUrl ?? AppConfig.vpsApiBaseUrl;
  String? _activeUrl;

  /// Пользовательские зеркала/свои серверы из настроек (в порядке
  /// добавления, дубликаты нормализуются и отсеиваются).
  List<String> _customUrls = [];
  List<String> get customUrls => List.unmodifiable(_customUrls);

  /// Загружена ли адресная книга.
  bool _loaded = false;

  /// Загрузить адресную книгу (идемпотентно). Публично — для экрана
  /// настроек, которому нужен список до первого зонда.
  Future<void> ensureLoaded() => _ensureLoaded();

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_customUrlsKey);
    if (stored != null && stored.isNotEmpty) {
      _customUrls = (jsonDecode(stored) as List)
          .map((e) => e as String)
          .where((u) => u.isNotEmpty)
          .toList();
    }
    // Миграция со старого одиночного зеркала (первый запуск после
    // обновления с прошлой версии).
    final legacy = prefs.getString(_legacyCustomUrlKey);
    if (legacy != null && legacy.isNotEmpty) {
      if (!_customUrls.contains(legacy)) {
        _customUrls = [..._customUrls, legacy];
      }
      await prefs.remove(_legacyCustomUrlKey);
      await prefs.setString(
        _customUrlsKey,
        jsonEncode(_customUrls),
      );
    }
    if (_customUrls.any(retiredUrls.contains)) {
      _customUrls =
          _customUrls.where((u) => !retiredUrls.contains(u)).toList();
      await prefs.setString(_customUrlsKey, jsonEncode(_customUrls));
    }
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
    for (final url in _customUrls) {
      if (!list.contains(url)) list.add(url);
    }
    final active = _activeUrl;
    if (active != null && list.contains(active)) {
      list
        ..remove(active)
        ..insert(0, active);
    }
    return list;
  }

  /// Дефолтные зеркала, идущие с приложением.
  List<String> get defaultUrls => List.unmodifiable(AppConfig.defaultMirrorUrls);

  /// Добавить пользовательское зеркало/сервер. Возвращает normalized URL
  /// или `null`, если адрес не парсится; дубликат — no-op.
  Future<String?> addCustomUrl(String url) async {
    await _ensureLoaded();
    final normalized = _normalize(url);
    if (normalized == null) return null;
    if (!_customUrls.contains(normalized) &&
        !AppConfig.defaultMirrorUrls.contains(normalized)) {
      _customUrls = [..._customUrls, normalized];
      await _saveCustomUrls();
    }
    return normalized;
  }

  /// Удалить пользовательское зеркало. Активное после удаления возвращается
  /// к основному домену.
  Future<void> removeCustomUrl(String url) async {
    await _ensureLoaded();
    _customUrls = _customUrls.where((u) => u != url).toList();
    await _saveCustomUrls();
    if (_activeUrl == url) {
      _activeUrl = AppConfig.defaultMirrorUrls.first;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeUrlKey, _activeUrl!);
    }
  }

  Future<void> _saveCustomUrls() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customUrlsKey, jsonEncode(_customUrls));
  }

  /// Выбрать зеркало вручную (тап по строке списка).
  Future<void> setActiveUrl(String url) async {
    await _ensureLoaded();
    if (!allUrls.contains(url)) return;
    await _persistActive(url);
  }

  /// Сохранить активное зеркало после успешной проверки.
  Future<void> _persistActive(String url) async {
    _activeUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeUrlKey, url);
  }

  /// Результат зонда: `pingMs == null` — зеркало недоступно.
  /// Пинг меряем по полному рукопожатию HEAD (DNS+TCP+TLS+HTTP): это
  /// честная «стоимость» первого запроса к зеркалу, а не ICMP-RTT,
  /// который к HTTPS-зеркалам всё равно не пробить.
  ///
  /// Таймауты щедрые (8с): на медленном старте первое рукопожатие
  /// занимает 3-5с из-за холодного DNS/TLS, и более короткий лимит
  /// отмечал живое зеркало как мёртвое. Холодный зонд получает один
  /// ретрай — единичное молчание ещё не «сервер лежит».
  Future<int?> _probe(String url) async {
    if (probeOverride != null) return probeOverride! ? 1 : null;
    if (skipRealNetwork) return 1;
    final ms = await _probeOnce(url);
    if (ms != null) return ms;
    return _probeOnce(url);
  }

  Future<int?> _probeOnce(String url) async {
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .headUrl(Uri.parse('$url/'))
          .timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      // Сбрасываем тело, иначе соединение висит до таймаута.
      await response.drain<void>().timeout(const Duration(seconds: 2));
      final status = response.statusCode;
      if (status >= 500) {
        // Прошлый зонд считал «ответил» живым зеркалом: мёртвый
        // Cloudflare-worker отдавал 530, приложение переключалось на него
        // и получало SERVER_MAINTENANCE на всей ленте.
        debugPrint('[Mirror] probe FAIL: $url (HTTP $status)');
        return null;
      }
      final ms = sw.elapsedMilliseconds;
      debugPrint('[Mirror] probe OK: $url (${ms}ms)');
      return ms;
    } catch (e) {
      debugPrint('[Mirror] probe FAIL: $url ($e)');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Перебрать зеркала слева-направо, вернуть первое живое.
  /// Каждое молчащее зерно получает один шанс за цикл, активное — первым.
  Future<String?> _findReachable() async {
    try {
      await _ensureLoaded();
    } catch (_) {}
    for (final url in allUrls) {
      if (await _probe(url) != null) return url;
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
    if (await _probe(activeUrl) != null) return true;
    final next = await _findReachable();
    if (next == null) return false;
    await _persistActive(next);
    debugPrint('[Mirror] switched to $next');
    return true;
  }

  /// Пинг/статус одного зеркала: `pingMs == null` — недоступно.
  Future<int?> probeUrl(String url) => _probe(url);

  /// Померить все зеркала параллельно: для списка в настройках.
  /// Возвращает URL → пинг (null = недоступно).
  Future<Map<String, int?>> probeAll() async {
    try {
      await _ensureLoaded();
    } catch (_) {}
    final urls = allUrls;
    final pings = await Future.wait(urls.map(_probe));
    return {
      for (var i = 0; i < urls.length; i++) urls[i]: pings[i],
    };
  }

  /// Автовыбор: переключиться на живое зеркало с минимальным пингом.
  /// Возвращает выбранный URL или `null`, если живых нет.
  Future<String?> autoSelectFastest() async {
    final pings = await probeAll();
    final alive = pings.entries
        .where((e) => e.value != null)
        .toList()
      ..sort((a, b) => a.value!.compareTo(b.value!));
    if (alive.isEmpty) return null;
    await _persistActive(alive.first.key);
    return alive.first.key;
  }

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
