import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/pkce.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Обмен кода авторизации на `id_token`.
typedef CodeExchanger =
    Future<String> Function(
      String code,
      String verifier,
      String redirectUri,
    );

/// Вход через Google в системном браузере: loopback-редирект + PKCE.
///
/// Единственный путь, который работает без Google Play Services (Huawei и
/// подобные устройства): браузеру всё равно, есть ли на телефоне сервисы
/// Google. Тот же код обслуживает компьютер и телефон, поэтому логика живёт
/// вне экрана — её можно проверить тестом без устройства.
class GoogleBrowserAuth {
  GoogleBrowserAuth({
    required this.clientId,
    required this.exchangeCode,
    this.launchBrowser,
    this.timeout = const Duration(minutes: 5),
  });

  /// Публичный client id OAuth-клиента типа «Desktop app»: только он разрешает
  /// loopback-редирект `http://localhost:<порт>` на любом устройстве.
  final String clientId;

  final CodeExchanger exchangeCode;

  /// По умолчанию — системный браузер; тест подменяет на свой.
  final Future<void> Function(Uri url)? launchBrowser;

  final Duration timeout;

  /// Открыть браузер, дождаться редиректа и вернуть `idToken`.
  ///
  /// Бросает `TimeoutException`, если окно закрыли, и `Exception` с понятным
  /// текстом, если браузер не открылся или Google вернул ошибку.
  Future<String> signIn() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirectUri = 'http://localhost:${server.port}';
      // verifier знает только этот процесс: перехваченный код без него
      // бесполезен. `state` отсекает редирект из чужой вкладки.
      final verifier = generatePkceVerifier();
      final state = generateOAuthState();
      final authUrl = Uri.parse(
        'https://accounts.google.com/o/oauth2/v2/auth',
      ).replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'scope': 'openid email profile',
          'code_challenge': pkceChallenge(verifier),
          'code_challenge_method': 'S256',
          'state': state,
        },
      );

      // Подписка на редирект встаёт раньше открытия браузера: браузер может
      // прийти на loopback мгновенно (в тесте — сразу), и соединение не
      // должно ждать в очереди без обработчика.
      final redirect = _waitForCode(server, state);
      final launch = launchBrowser ?? _openInSystemBrowser;
      await launch(authUrl);

      final code = await redirect.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          tr('Вход в браузере не завершён — окно было закрыто.'),
        ),
      );
      if (code == null) throw Exception(tr('Не получен код авторизации.'));
      return await exchangeCode(code, verifier, redirectUri);
    } finally {
      await server.close(force: true);
    }
  }

  static Future<void> _openInSystemBrowser(Uri url) async {
    if (!await canLaunchUrl(url)) {
      throw Exception(tr('Не удалось открыть браузер.'));
    }
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  /// Ждём редирект с кодом; `null` — браузер вернул `error`.
  ///
  /// Запросы с чужим `state` отбиваются 400 и не завершают ожидание: вкладка,
  /// открытая до нас, не должна подсунуть свой код.
  Future<String?> _waitForCode(HttpServer server, String expectedState) async {
    await for (final request in server) {
      final query = request.uri.queryParameters;
      if (query['state'] != expectedState) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }
      final code = query['code'];
      final error = query['error'];
      final title = error == null
          ? tr('Вход выполнен!')
          : tr('Вход не завершён');
      request.response
        ..statusCode = error == null ? HttpStatus.ok : HttpStatus.badRequest
        ..headers.contentType = ContentType.html
        ..write(
          '<html><body style="background-color:#121212;color:white;text-align:center;font-family:sans-serif;margin-top:100px;"><h1>$title</h1><script>window.close();</script></body></html>',
        );
      await request.response.close();
      return code;
    }
    return null;
  }

  /// Обмен кода напрямую в Google — только для сборок, где вшит секрет.
  static CodeExchanger exchangeWithGoogle({
    required String clientId,
    required String clientSecret,
  }) {
    return (code, verifier, redirectUri) async {
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'code': code,
          'client_id': clientId,
          'client_secret': clientSecret,
          'code_verifier': verifier,
          'redirect_uri': redirectUri,
          'grant_type': 'authorization_code',
        },
      );
      if (response.statusCode != 200) {
        throw Exception(tr('Ошибка обмена токена.'));
      }
      final data = jsonDecode(response.body);
      final idToken = data['id_token'];
      if (idToken is! String || idToken.isEmpty) {
        throw Exception(tr('Сервер не выдал idToken.'));
      }
      return idToken;
    };
  }

  /// Обмен кода на нашем сервере: он держит секрет клиента, поэтому в сборку
  /// не нужно вшивать ключи.
  static CodeExchanger exchangeWithBackend({
    required String apiUrl,
    required String clientId,
  }) {
    return (code, verifier, redirectUri) async {
      final response = await http.post(
        Uri.parse('$apiUrl/auth/google/exchange'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'clientId': clientId,
          'codeVerifier': verifier,
          'redirectUri': redirectUri,
        }),
      );
      if (response.statusCode != 200) {
        throw Exception(
          trf('Сервер не завершил вход: {p0}', {'p0': response.statusCode}),
        );
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final idToken = data['idToken'];
      if (idToken is! String || idToken.isEmpty) {
        throw Exception(tr('Сервер не выдал idToken.'));
      }
      return idToken;
    };
  }
}