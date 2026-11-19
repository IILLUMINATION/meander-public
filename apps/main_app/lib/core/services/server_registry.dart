import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/net/blind_tunnel.dart';
import 'package:canvas_app/core/services/relay_registry.dart';
import 'package:canvas_app/core/services/session_store.dart';

/// Куда приложение ходит за API.
///
/// Серверов ровно два вида, и оба — настоящие бэкенды:
/// - оригинал ([AppConfig.vpsApiBaseUrl]);
/// - свой сервер, добавленный пользователем (своя база, своя сессия).
///
/// Зеркал-прокси больше нет и быть не может: прокси обязан терминировать TLS,
/// чтобы разложить запросы по путям, — значит, видит `Authorization`, idToken
/// и переписку. Если оригинал заблокирован, доступ даёт [BlindTunnel] —
/// слепой ретранслятор, который видит только шифртекст.
///
/// Порядок выбора пути при каждом [ensureReachable]:
/// 1. прямое соединение с оригиналом (дешевле и не грузит чужой VPS);
/// 2. ретрансляторы по порядку [RelayRegistry]: свои первыми, встроенные
///    следом;
/// 3. ничего не вышло — [allServersDownMarker], UI показывает подсказку.
class ServerRegistry {
  ServerRegistry._();
  static final ServerRegistry instance = ServerRegistry._();

  static const _activeUrlKey = 'server_active_url';
  static const _customUrlsKey = 'server_custom_urls';

  // Ключи прежней версии (зеркала-прокси). Читаются один раз и переезжают.
  static const _legacyActiveKey = 'mirror_active_url';
  static const _legacyCustomKey = 'mirror_custom_urls';
  static const _legacySingleKey = 'mirror_custom_url';

  /// Фейк для тестов: `null` — реальные зонды, `true`/`false` — результат
  /// зонда, не трогая сеть.
  static bool? probeOverride;
  static bool skipRealNetwork = false;

  /// Тонкий зонд для тестов: путь запроса → результат. Позволяет проверить
  /// порядок «прямой → свои ретрансляторы → встроенные», не поднимая сеть.
  @visibleForTesting
  static Future<int?> Function(String url)? probeHook;

  String get primaryUrl => AppConfig.vpsApiBaseUrl;
  String get activeUrl => _activeUrl ?? primaryUrl;
  String? _activeUrl;

  /// Свои серверы (не зеркала: у каждого своя база и своя сессия).
  List<String> _customUrls = [];
  List<String> get customUrls => List.unmodifiable(_customUrls);

  bool _loaded = false;
  Future<bool>? _ensureInFlight;
  bool _handlingFailure = false;
  Timer? _reviewTimer;

  /// Сброс singleton-состояния (только тесты).
  @visibleForTesting
  void resetForTests() {
    _loaded = false;
    _activeUrl = null;
    _customUrls = [];
    probeHook = null;
    probeOverride = null;
    skipRealNetwork = false;
    _ensureInFlight = null;
    _handlingFailure = false;
    _reviewTimer?.cancel();
    _reviewTimer = null;
  }

  bool get onPrimaryServer => activeUrl == primaryUrl;

  Future<void> ensureLoaded() => _ensureLoaded();

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();

    final storedCustom =
        prefs.getString(_customUrlsKey) ?? prefs.getString(_legacyCustomKey);
    if (storedCustom != null && storedCustom.isNotEmpty) {
      _customUrls = (jsonDecode(storedCustom) as List)
          .map((e) => _normalize(e?.toString()))
          .whereType<String>()
          .toList();
    }
    final legacySingle = prefs.getString(_legacySingleKey);
    if (legacySingle != null && legacySingle.isNotEmpty) {
      final normalized = _normalize(legacySingle);
      if (normalized != null && !_customUrls.contains(normalized)) {
        _customUrls = [..._customUrls, normalized];
      }
      await prefs.remove(_legacySingleKey);
    }

    // Прокси-зеркала прежних версий и сам оригинал в списке «своих» не
    // нужны: первое небезопасно, второе избыточно.
    final cleaned = _customUrls
        .where((url) => url != primaryUrl)
        .where((url) => !AppConfig.retiredProxyUrls.contains(url))
        .toList();
    if (cleaned.length != _customUrls.length) {
      _customUrls = cleaned;
      await _saveCustomUrls();
    }

    final storedActive =
        prefs.getString(_activeUrlKey) ?? prefs.getString(_legacyActiveKey);
    final normalizedActive = _normalize(storedActive);
    _activeUrl =
        (normalizedActive != null &&
            (normalizedActive == primaryUrl ||
                _customUrls.contains(normalizedActive)))
        ? normalizedActive
        : primaryUrl;
    await prefs.remove(_legacyActiveKey);
    await prefs.remove(_legacyCustomKey);
    await prefs.setString(_activeUrlKey, _activeUrl!);
    await prefs.setString(_customUrlsKey, jsonEncode(_customUrls));

    _loaded = true;
    // Сессия привязана к серверу: на старте подставляем сессию активного.
    await SessionStore.activate(domainFor(_activeUrl!));
  }

  /// Область доверия для сессии: оригинал — [SessionStore.primaryDomain],
  /// свой сервер — его собственный URL.
  static String domainFor(String url) {
    final normalized = _normalize(url) ?? url;
    return normalized == AppConfig.vpsApiBaseUrl
        ? SessionStore.primaryDomain
        : normalized;
  }

  String get activeDomain => domainFor(activeUrl);

  /// Оригинал и свои серверы. Прокси-зеркал в этом списке нет.
  List<String> get allUrls {
    final list = [primaryUrl];
    for (final url in _customUrls) {
      if (!list.contains(url)) list.add(url);
    }
    return list;
  }

  /// Добавить свой сервер. Возвращает нормализованный URL или `null`.
  Future<String?> addCustomUrl(String url) async {
    await _ensureLoaded();
    final normalized = _normalize(url);
    if (normalized == null) return null;
    if (normalized == primaryUrl) return normalized;
    if (!_customUrls.contains(normalized)) {
      _customUrls = [..._customUrls, normalized];
      await _saveCustomUrls();
    }
    return normalized;
  }

  Future<void> removeCustomUrl(String url) async {
    await _ensureLoaded();
    _customUrls = _customUrls.where((u) => u != url).toList();
    await _saveCustomUrls();
    if (_activeUrl == url) await _persistActive(primaryUrl);
  }

  Future<void> _saveCustomUrls() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customUrlsKey, jsonEncode(_customUrls));
  }

  Future<void> setActiveUrl(String url) async {
    await _ensureLoaded();
    if (!allUrls.contains(url)) return;
    await _persistActive(url);
  }

  Future<void> _persistActive(String url) async {
    _activeUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeUrlKey, url);
    // Выбор своего сервера отменяет туннель: он прокладывает путь только к
    // оригиналу, а на своём сервере трафик и так идёт по HTTPS напрямую.
    if (url != primaryUrl) BlindTunnel.disable();
    await SessionStore.activate(domainFor(url));
  }

  /// Проверить путь до [url].
  ///
  /// [fast] — короткий таймаут без повтора: нужен для выбора пути, где
  /// пользователь ждёт результат. Точный пинг для настроек остаётся
  /// восьмисекундным с одним повтором: холодный DNS/TLS на мобильной сети
  /// иначе выглядит как «сервер недоступен».
  Future<int?> probeUrl(String url, {bool fast = false}) async {
    final hook = probeHook;
    if (hook != null) return hook(url);
    if (probeOverride != null) return probeOverride! ? 1 : null;
    if (skipRealNetwork) return 1;
    final ms = await _probeOnce(url, fast: fast);
    if (ms != null || fast) return ms;
    return _probeOnce(url, fast: false);
  }

  Future<int?> _probeOnce(String url, {required bool fast}) async {
    final budget = Duration(seconds: fast ? 4 : 8);
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = budget;
    try {
      final request = await client.headUrl(Uri.parse('$url/')).timeout(budget);
      final response = await request.close().timeout(budget);
      await response.drain<void>().timeout(const Duration(seconds: 2));
      final status = response.statusCode;
      if (status >= 500) {
        debugPrint('[Net] probe FAIL: $url (HTTP $status)');
        return null;
      }
      final ms = sw.elapsedMilliseconds;
      debugPrint('[Net] probe OK: $url (${ms}ms)');
      return ms;
    } catch (e) {
      debugPrint('[Net] probe FAIL: $url ($e)');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Пинг всех серверов для настроек: URL → мс (`null` — не отвечает).
  Future<Map<String, int?>> probeAll() async {
    try {
      await _ensureLoaded();
    } catch (_) {}
    final urls = allUrls;
    final pings = await Future.wait(urls.map(probeUrl));
    return {
      for (var i = 0; i < urls.length; i++) urls[i]: pings[i],
    };
  }

  /// Выбрать рабочий путь до API. Возвращает `true`, если хоть один путь жив.
  ///
  /// Сначала честно проверяется прямое соединение (туннель на это время
  /// выключается): если домен доступен, ретранслятор не нужен и чужой VPS не
  /// нагружается. Если нет — ретрансляторы по порядку; каждый проверяется
  /// реальным HTTP-запросом через себя, а не только TCP-коннектом.
  Future<bool> ensureReachable() {
    // Параллельные вызовы (старт приложения, первый REST, коннект сокета) не
    // должны ни дублировать пробы, ни получать оптимистичное «жив».
    return _ensureInFlight ??=
        _ensureReachableOnce().whenComplete(() => _ensureInFlight = null);
  }

  Future<bool> _ensureReachableOnce() async {
    await _ensureLoaded();

    // Явно выбранный свой сервер: если он мёртв — возвращаемся к оригиналу.
    if (!onPrimaryServer) {
      if (await probeUrl(activeUrl, fast: true) != null) return true;
      await _persistActive(primaryUrl);
    }

    // Прямой путь пробуем честно: туннель на это время выключен.
    BlindTunnel.disable();
    if (await probeUrl(primaryUrl, fast: true) != null) {
      debugPrint('[Net] direct path');
      return true;
    }

    for (final endpoint in RelayRegistry.instance.enabled) {
      if (!await BlindTunnel.useEndpoint(endpoint)) continue;
      if (await probeUrl(primaryUrl, fast: true) != null) {
        debugPrint('[Net] via relay $endpoint');
        _scheduleReview();
        return true;
      }
      BlindTunnel.disable();
    }

    _scheduleReview();
    return false;
  }

  /// Ретранслятор отказал в процессе работы (см. [BlindTunnel.reportFailure]).
  ///
  /// Порядок: следующий ретранслятор из списка, затем прямое соединение.
  /// Прокси-зеркал здесь нет намеренно — в них нельзя вернуться ни при каких
  /// условиях.
  Future<void> handleTunnelFailure() async {
    if (_handlingFailure) return;
    _handlingFailure = true;
    try {
      final failed = BlindTunnel.endpoint;
      for (final endpoint in RelayRegistry.instance.enabled) {
        if (endpoint == failed) continue;
        if (!await BlindTunnel.useEndpoint(endpoint)) continue;
        if (await probeUrl(primaryUrl, fast: true) != null) {
          debugPrint('[Net] switched to relay $endpoint');
          _scheduleReview();
          return;
        }
        BlindTunnel.disable();
      }
      if (await probeUrl(primaryUrl, fast: true) != null) {
        debugPrint('[Net] relay failed, direct path works');
      } else {
        _scheduleReview();
      }
    } finally {
      _handlingFailure = false;
    }
  }

  /// Пока туннель активен, раз в 10 минут проверяем прямой путь: если
  /// блокировку сняли, возвращаемся на него и не грузим ретранслятор.
  void _scheduleReview() {
    if (_reviewTimer?.isActive ?? false) return;
    _reviewTimer = Timer(const Duration(minutes: 10), () async {
      _reviewTimer = null;
      if (!BlindTunnel.enabled) return;
      BlindTunnel.disable();
      if (await probeUrl(primaryUrl, fast: true) == null) {
        await ensureReachable();
      } else {
        debugPrint('[Net] direct path is back, relay off');
      }
    });
  }

  /// Публичная нормализация: без схемы → https, без хвостовых `/`.
  static String? normalizeForPreview(String? url) => _normalize(url);

  /// Все пути к API недоступны — маркер для UI (см. `friendlyError`).
  static const allServersDownMarker = 'ALL_SERVERS_DOWN';

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
    // Открытый http допустим только для локальной разработки: на публичный
    // хост сессия ушла бы в открытом виде, а приложение этого не делает
    // даже по просьбе — тогда адрес просто не принимается.
    if (uri.scheme == 'http' && !_isLocalHost(uri.host)) return null;
    return trimmed;
  }

  /// Локальные адреса: петля и приватные диапазоны (свой dev-бэкенд).
  static bool _isLocalHost(String host) {
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return true;
    }
    if (host.startsWith('10.')) return true;
    if (host.startsWith('192.168.')) return true;
    final parts = host.split('.');
    if (parts.length == 4 && parts[0] == '172') {
      final second = int.tryParse(parts[1]);
      return second != null && second >= 16 && second <= 31;
    }
    return false;
  }
}