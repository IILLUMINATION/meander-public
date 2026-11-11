import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/services/google_browser_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Браузерный вход проверяется живьём: настоящий loopback-сервер, настоящий
/// HTTP-редирект. Подменены только браузер (в тесте его нет) и обмен кода
/// (иначе тест ходил бы в Google).
void main() {
  /// Браузер-заглушка: забирает из auth-ссылки redirect_uri и state, затем
  /// «нажимает Разрешить», отдавая код на loopback.
  Future<void> Function(Uri) redirectWith({String? code, String? error}) {
    return (Uri authUrl) async {
      final query = authUrl.queryParameters;
      final redirect = Uri.parse(query['redirect_uri']!);
      await http.get(
        redirect.replace(
          queryParameters: {
            'state': query['state']!,
            'code': ?code,
            'error': ?error,
          },
        ),
      );
    };
  }

  test('возвращает idToken и передаёт код с verifier', () async {
    String? seenCode;
    String? seenVerifier;
    String? seenRedirect;
    final auth = GoogleBrowserAuth(
      clientId: 'client.apps.googleusercontent.com',
      launchBrowser: redirectWith(code: 'the-code'),
      exchangeCode: (code, verifier, redirectUri) async {
        seenCode = code;
        seenVerifier = verifier;
        seenRedirect = redirectUri;
        return 'id-token';
      },
    );

    expect(await auth.signIn(), 'id-token');
    expect(seenCode, 'the-code');
    expect(seenRedirect, startsWith('http://localhost:'));
    // PKCE обязателен: без verifier сервер отверг бы обмен.
    expect(seenVerifier, isNotNull);
    expect(seenVerifier!.length, inInclusiveRange(43, 128));
  });

  test('ссылка несёт PKCE-челлендж и state', () async {
    Uri? opened;
    final auth = GoogleBrowserAuth(
      clientId: 'client.apps.googleusercontent.com',
      launchBrowser: (url) async {
        opened = url;
        throw StateError('останавливаемся сразу после открытия');
      },
      exchangeCode: (_, _, _) async => 'id-token',
    );
    await expectLater(auth.signIn(), throwsStateError);

    final query = opened!.queryParameters;
    expect(query['client_id'], 'client.apps.googleusercontent.com');
    expect(query['response_type'], 'code');
    expect(query['code_challenge_method'], 'S256');
    expect(query['code_challenge'], isNotEmpty);
    // verifier в ссылку не попадает — только его хеш.
    expect(query['code_verifier'], isNull);
    expect(query['state'], isNotEmpty);
  });

  test('чужой state отбивается, а свой принимается', () async {
    final auth = GoogleBrowserAuth(
      clientId: 'client.apps.googleusercontent.com',
      exchangeCode: (code, _, _) async => 'token:$code',
      launchBrowser: (authUrl) async {
        final query = authUrl.queryParameters;
        final redirect = Uri.parse(query['redirect_uri']!);
        final foreign = await http.get(
          redirect.replace(queryParameters: {'state': 'чужой', 'code': 'bad'}),
        );
        expect(foreign.statusCode, HttpStatus.badRequest);
        await http.get(
          redirect.replace(
            queryParameters: {'state': query['state']!, 'code': 'good'},
          ),
        );
      },
    );

    expect(await auth.signIn(), 'token:good');
  });

  test('ошибка браузера не выдаёт токен', () async {
    final auth = GoogleBrowserAuth(
      clientId: 'client.apps.googleusercontent.com',
      exchangeCode: (_, _, _) async => fail('обмена быть не должно'),
      launchBrowser: redirectWith(error: 'access_denied'),
    );
    await expectLater(auth.signIn(), throwsException);
  });

  test('закрытая вкладка не висит вечно', () async {
    final auth = GoogleBrowserAuth(
      clientId: 'client.apps.googleusercontent.com',
      timeout: const Duration(milliseconds: 200),
      exchangeCode: (_, _, _) async => fail('обмена быть не должно'),
      launchBrowser: (_) async {},
    );
    await expectLater(auth.signIn(), throwsA(isA<TimeoutException>()));
  });
}