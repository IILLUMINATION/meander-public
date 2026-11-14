import 'package:shared_preferences/shared_preferences.dart';

/// Сессия, привязанная к серверу, который её выдал.
///
/// Токен приложения подписан `JWT_SECRET` конкретного бэкенда, поэтому он
/// имеет смысл только на этом бэкенде. До этого патча токен лежал в одном
/// ключе `jwt_token` и уезжал в заголовке `Authorization` на **любой**
/// активный хост, включая добавленный пользователем сервер: тот мог
/// сохранить чужой токен и предъявить его официальному домену, где он
/// валиден 7 дней.
///
/// Теперь у каждой «области доверия» своя сессия:
/// - [primaryDomain] — основной домен и встроенные зеркала: это один
///   бэкенд (общая БД и общий секрет), поэтому одна сессия на всех;
/// - любой другой сервер — своя область, ключ = его нормализованный URL.
///
/// Вход и выход меняют только активную область; переключение зеркала
/// подставляет сессию целевой области, а если её нет — приложение на этом
/// сервере гость, и токен основного домена туда не уходит.
///
/// Ключи `jwt_token` / `user_id` остаются: это «сессия активной области»,
/// её читают все существующие экраны. Раскладка по областям — рядом.
class SessionStore {
  SessionStore._();

  /// Область доверия основного бэкенда (основной домен + встроенные зеркала).
  static const String primaryDomain = 'primary';

  static const String _tokenKey = 'jwt_token';
  static const String _userIdKey = 'user_id';
  static const String _domainKey = 'session_domain';

  static String? _activeDomain;
  static bool _loaded = false;

  /// Ключ SharedPreferences с токеном области [domain].
  static String tokenKeyFor(String domain) => 'session_token@$domain';

  /// Ключ SharedPreferences с id пользователя области [domain].
  static String userKeyFor(String domain) => 'session_user@$domain';

  /// Активная область доверия; `null` — ещё не загружено.
  static String? get activeDomain => _activeDomain;

  /// Загрузить раскладку сессий (идемпотентно).
  ///
  /// Миграция: до этого патча сессии привязки к серверу не имели, но и
  /// пользовательские серверы не были самостоятельными — токен в
  /// `jwt_token` выдан основным бэкендом (или встроенным зеркалом), поэтому
  /// он считается сессией [primaryDomain].
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_domainKey);
    if (stored != null) {
      _activeDomain = stored;
    } else {
      _activeDomain = primaryDomain;
      final legacyToken = prefs.getString(_tokenKey);
      if (legacyToken != null && legacyToken.isNotEmpty) {
        await prefs.setString(tokenKeyFor(primaryDomain), legacyToken);
        final legacyUser = prefs.getString(_userIdKey);
        if (legacyUser != null && legacyUser.isNotEmpty) {
          await prefs.setString(userKeyFor(primaryDomain), legacyUser);
        }
      }
      await prefs.setString(_domainKey, primaryDomain);
    }
    _loaded = true;
    await _materialize(prefs, _activeDomain!);
  }

  /// Сделать [domain] активной областью: подставить её сессию в
  /// `jwt_token`/`user_id` (или убрать ключи, если сессии там нет).
  static Future<void> activate(String domain) async {
    await ensureLoaded();
    if (_activeDomain == domain) return;
    final prefs = await SharedPreferences.getInstance();
    _activeDomain = domain;
    await prefs.setString(_domainKey, domain);
    await _materialize(prefs, domain);
  }

  /// Сохранить сессию области [domain] и сделать её активной.
  static Future<void> save({
    required String domain,
    required String token,
    required String userId,
  }) async {
    await ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(tokenKeyFor(domain), token);
    await prefs.setString(userKeyFor(domain), userId);
    _activeDomain = domain;
    await prefs.setString(_domainKey, domain);
    await _materialize(prefs, domain);
  }

  /// Выход из аккаунта активной области. Чужие сессии не трогаем: выход
  /// на своём сервере не должен разлогинивать основной домен.
  static Future<void> clearActive() async {
    await ensureLoaded();
    final domain = _activeDomain ?? primaryDomain;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(tokenKeyFor(domain));
    await prefs.remove(userKeyFor(domain));
    await prefs.remove(_tokenKey);
    await prefs.remove(_userIdKey);
  }

  static Future<void> _materialize(
    SharedPreferences prefs,
    String domain,
  ) async {
    final token = prefs.getString(tokenKeyFor(domain));
    final userId = prefs.getString(userKeyFor(domain));
    if (token != null && token.isNotEmpty) {
      await prefs.setString(_tokenKey, token);
    } else {
      await prefs.remove(_tokenKey);
    }
    if (userId != null && userId.isNotEmpty) {
      await prefs.setString(_userIdKey, userId);
    } else {
      await prefs.remove(_userIdKey);
    }
  }

  /// Сброс singleton-состояния (только тесты).
  static void resetForTests() {
    _activeDomain = null;
    _loaded = false;
  }
}
