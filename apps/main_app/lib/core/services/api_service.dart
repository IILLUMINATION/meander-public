import 'dart:convert';
import 'dart:io';
import 'package:canvas_app/core/services/mirror_registry.dart';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:canvas_app/core/services/session_service.dart';
import 'package:canvas_app/features/shell/screens/menu_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36';

  /// Без этого запрос висит до тех пор, пока жив сокет: бэкенд в
  /// `reports.ts`/`profiles.ts` умеет не ответить никогда (ошибка пула
  /// вне `try`), и кнопка крутится бесконечно.
  static const Duration defaultRequestTimeout = Duration(seconds: 30);

  final http.Client _client;
  final Duration _requestTimeout;

  /// [client] подменяется в тестах; в проде — обычный HTTP-клиент.
  ApiService({http.Client? client, Duration? requestTimeout})
    : _client = client ?? http.Client(),
      _requestTimeout = requestTimeout ?? defaultRequestTimeout;

  /// Выполнить запрос с перебором зеркал бэкенда.
  ///
  /// Основной домен может быть заблокирован в сети пользователя (РКН):
  /// тогда сетевой отказ на активном зеркале триггерит поиск живого
  /// ([MirrorRegistry.ensureReachable]) и один повтор запроса уже на
  /// новом зеркале. Если живых нет вовсе — маркер [MirrorRegistry.allMirrorsDownMarker],
  /// который UI разворачивает в подсказку про «ускоритель интернета».
  /// Ошибки протокола (403/404/401) ретраев не дают — это ответ бэкенда,
  /// значит зеркало живое.
  Future<T> _withMirrorFallback<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on Exception catch (e) {
      if (e.toString().contains('SERVER_MAINTENANCE')) {
        final ok = await MirrorRegistry.instance.ensureReachable();
        if (!ok) {
          throw Exception(MirrorRegistry.allMirrorsDownMarker);
        }
        return await action();
      }
      rethrow;
    } catch (e) {
      // TimeoutException и транспортные ошибки — тоже кандидат на
      // заблокированное зеркало.
      final ok = await MirrorRegistry.instance.ensureReachable();
      if (!ok) {
        throw Exception(MirrorRegistry.allMirrorsDownMarker);
      }
      return await action();
    }
  }
  Future<Map<String, String>> _getHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');

    final String authorization = token != null ? 'Bearer $token' : '';

    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': authorization,
      'User-Agent': _userAgent,
    };
  }

  Future<void> _handleUnauthorized() async {
    final prefs = await SharedPreferences.getInstance();
    final hadToken = prefs.getString('jwt_token') != null;
    if (!hadToken) {
      // Гость: не выкидываем из приложения, просто прокидываем ошибку
      // чтобы UI мог показать snackbar / заглушку. Иначе каждый 401 у
      // неавторизованного приводил к сбросу навигации.
      return;
    }
    await prefs.remove('jwt_token');
    await prefs.remove('user_id');

    // Откладываем навигацию до конца текущего фрейма - безопасно даже
    // если 401 пришёл во время build провайдера.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final nav = navigatorKey.currentState;
      if (nav == null || !nav.mounted) return;
      // Сессия рвётся целиком: сокет жил своим токеном и после 401
      // продолжал приносить чужие сообщения, а кэши ЛС и ленты
      // доезжали следующему вошедшему.
      await endSession(context: nav.context, notifyServer: false);
      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => MenuScreen()),
        (route) => false,
      );
    });
  }

  /// Человекочитаемый `error` из ответа бэкенда (`{ "error": "..." }`),
  /// если он там есть.
  static String? _serverMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // Не JSON — вернём null, вызывающий покажет тело как есть.
    }
    return null;
  }

  /// Что подставить в текст ошибки вместо сырого тела ответа.
  ///
  /// Бэкенд отвечает `{ "error": "…" }`, но 404 и 502 часто приходят страницей
  /// nginx: без этой фильтрации `<!DOCTYPE html>…` доезжал до снэкбара
  /// человека (проверка удаления аккаунта на проде).
  static String _failureDetail(http.Response response) {
    final server = _serverMessage(response);
    if (server != null) return server;
    final body = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (body.isEmpty || body.startsWith('<')) return '';
    final firstLine = body.split('\n').first.trim();
    return firstLine.length > 120
        ? '${firstLine.substring(0, 120)}…'
        : firstLine;
  }

  static Exception _failure(String action, http.Response response) {
    final detail = _failureDetail(response);
    return Exception(
      '$action: ${response.statusCode}${detail.isEmpty ? '' : ' $detail'}',
    );
  }

  /// Просроченный или подделанный JWT. Токен живёт 7 дней, поэтому это не
  /// экзотика, а штатный случай: у человека просто давно не было входа.
  static bool _isDeadToken(http.Response response) {
    return _serverMessage(response) == 'Token is not valid';
  }

  /// Смерть сессии приходит в двух кодах: 401 и — так исторически отвечает
  /// `authMiddleware` — 403 "Token is not valid". Остальные 403 это отказ по
  /// правилу (квота, «только автор»), и их трогать нельзя: иначе любой
  /// отказ выкидывал бы человека из аккаунта.
  ///
  /// Без этого 403 по мёртвому токену превращается в зомби-сессию: падает
  /// каждый запрос, переписки и лента не грузятся, а выйти нечем.
  Future<Exception?> _handleDeadSession(http.Response response) async {
    if (response.statusCode != 401 &&
        !(response.statusCode == 403 && _isDeadToken(response))) {
      return null;
    }
    await _handleUnauthorized();
    return response.statusCode == 401
        ? Exception('Unauthorized: ${response.body}')
        : Exception('403 ${_failureDetail(response)}');
  }

  void _checkMaintenanceError(dynamic error) {
    if (error is SocketException || error is http.ClientException) {
      throw Exception('SERVER_MAINTENANCE');
    }
  }

  void _checkStatusCode(http.Response response) {
    if (response.statusCode >= 500 && response.statusCode < 600) {
      throw Exception('SERVER_MAINTENANCE');
    }
  }

  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) {
    return _withMirrorFallback(() async {
      final baseUrl = AppConfig.apiUrl;
      final url = Uri.parse(
        '$baseUrl/$endpoint',
      ).replace(queryParameters: queryParams);
      final headers = await _getHeaders();

      try {
        final response = await _client
            .get(url, headers: headers)
            .timeout(_requestTimeout);
        _checkStatusCode(response);

        final deadSession = await _handleDeadSession(response);
        if (deadSession != null) throw deadSession;

        if (response.statusCode == 403) {
          // 403 — отказ по правилу (квота, «только автор», «не опубликовано»),
          // сессия цела: показываем текст бэкенда вместо разлогина. Код
          // оставляем в начале — на него смотрит `_friendlyError` в UI.
          throw Exception(
            '403 ${_failureDetail(response)}',
          );
        }

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return jsonDecode(utf8.decode(response.bodyBytes));
        } else {
          throw _failure('Failed to load data', response);
        }
      } catch (e) {
        _checkMaintenanceError(e);
        rethrow;
      }
    });
  }

  Future<dynamic> post(String endpoint, {Map<String, dynamic>? body}) {
    return _withMirrorFallback(() async {
      final baseUrl = AppConfig.apiUrl;
      final url = Uri.parse('$baseUrl/$endpoint');
      final headers = await _getHeaders();

      try {
        final response = await _client
            .post(url, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(_requestTimeout);

        _checkStatusCode(response);

        final deadSession = await _handleDeadSession(response);
        if (deadSession != null) throw deadSession;

        if (response.statusCode == 403) {
          // 403 — отказ по правилу (квота, «только автор», «не опубликовано»),
          // сессия цела: показываем текст бэкенда вместо разлогина. Код
          // оставляем в начале — на него смотрит `_friendlyError` в UI.
          throw Exception(
            '403 ${_failureDetail(response)}',
          );
        }

        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (response.body.isEmpty) return null;
          return jsonDecode(utf8.decode(response.bodyBytes));
        } else {
          throw _failure('Failed to post data', response);
        }
      } catch (e) {
        _checkMaintenanceError(e);
        rethrow;
      }
    });
  }

  Future<dynamic> put(String endpoint, {Map<String, dynamic>? body}) {
    return _withMirrorFallback(() async {
      final baseUrl = AppConfig.apiUrl;
      final url = Uri.parse('$baseUrl/$endpoint');
      final headers = await _getHeaders();

      try {
        final response = await _client
            .put(url, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(_requestTimeout);

        _checkStatusCode(response);

        final deadSession = await _handleDeadSession(response);
        if (deadSession != null) throw deadSession;

        if (response.statusCode == 403) {
          // 403 — отказ по правилу (квота, «только автор», «не опубликовано»),
          // сессия цела: показываем текст бэкенда вместо разлогина. Код
          // оставляем в начале — на него смотрит `_friendlyError` в UI.
          throw Exception(
            '403 ${_failureDetail(response)}',
          );
        }

        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (response.body.isEmpty) return null;
          return jsonDecode(utf8.decode(response.bodyBytes));
        } else {
          throw _failure('Failed to put data', response);
        }
      } catch (e) {
        throw Exception('Failed to put data: $e');
      }
    });
  }

  /// Частичное обновление. Им пользуется лобби форума: правит название,
  /// описание и «пишут только участники», не затыкая пустотой остальные
  /// колонки.
  Future<dynamic> patch(String endpoint, {Map<String, dynamic>? body}) {
    return _withMirrorFallback(() async {
      final baseUrl = AppConfig.apiUrl;
      final url = Uri.parse('$baseUrl/$endpoint');
      final headers = await _getHeaders();

      try {
        final response = await _client
            .patch(url, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(_requestTimeout);

        _checkStatusCode(response);

        final deadSession = await _handleDeadSession(response);
        if (deadSession != null) throw deadSession;

        if (response.statusCode == 403) {
          // 403 — отказ по правилу (квота, «только автор», «не опубликовано»),
          // сессия цела: показываем текст бэкенда вместо разлогина. Код
          // оставляем в начале — на него смотрит `_friendlyError` в UI.
          throw Exception(
            '403 ${_failureDetail(response)}',
          );
        }

        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (response.body.isEmpty) return null;
          return jsonDecode(utf8.decode(response.bodyBytes));
        } else {
          throw _failure('Failed to patch data', response);
        }
      } catch (e) {
        _checkMaintenanceError(e);
        rethrow;
      }
    });
  }
  Future<dynamic> delete(
    String endpoint, {
    Map<String, dynamic>? body,
  }) {
    return _withMirrorFallback(() async {
      final baseUrl = AppConfig.apiUrl;
      final url = Uri.parse('$baseUrl/$endpoint');
      final headers = await _getHeaders();

      try {
        final response = await _client
            .delete(
              url,
              headers: headers,
              body: body == null ? null : jsonEncode(body),
            )
            .timeout(_requestTimeout);
        _checkStatusCode(response);

        final deadSession = await _handleDeadSession(response);
        if (deadSession != null) throw deadSession;

        if (response.statusCode == 403) {
          // 403 — отказ по правилу (квота, «только автор», «не опубликовано»),
          // сессия цела: показываем текст бэкенда вместо разлогина. Код
          // оставляем в начале — на него смотрит `_friendlyError` в UI.
          throw Exception(
            '403 ${_failureDetail(response)}',
          );
        }

        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (response.body.isEmpty) return null;
          return jsonDecode(utf8.decode(response.bodyBytes));
        } else {
          throw _failure('Failed to delete', response);
        }
      } catch (e) {
        _checkMaintenanceError(e);
        rethrow;
      }
    });
  }
}

final apiServiceProvider = Provider((ref) => ApiService());
