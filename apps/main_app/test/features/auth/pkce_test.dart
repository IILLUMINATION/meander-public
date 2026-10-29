import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/core/utils/pkce.dart';

/// PKCE-примитивы desktop-входа через Google.
///
/// Живой consent-экран Google попросит браузер и аккаунт, поэтому проверяется
/// то, что можно проверить офлайн: соответствие хеша эталону и форма
/// verifier'а. Эталон берём у Node (`crypto` из backend) — тот же язык, что и
/// у сервера, который будет сверять обмен.
void main() {
  final nodeAvailable = Process.runSync('node', ['--version']).exitCode == 0;

  String nodeS256(String verifier) {
    final script =
        "process.stdout.write("
        "require('crypto').createHash('sha256')"
        ".update(process.argv[1], 'utf8').digest('base64url'))";
    // `--` обязателен: verifier по RFC 7636 может начинаться с `-`, и без
    // терминатора node принимает его за собственную опцию (`bad option: -A…`).
    final r = Process.runSync('node', ['-e', script, '--', verifier]);
    expect(r.exitCode, 0, reason: 'node -e failed: ${r.stderr}');
    return r.stdout.toString();
  }

  group('pkceChallenge', () {
    test('совпадает с эталоном Node: BASE64URL(SHA256(verifier))', () {
      for (final v in [
        'abcDEF123-._~',
        '-leading-dash-._~ABC123',
        generatePkceVerifier(),
        generatePkceVerifier(length: 128),
      ]) {
        expect(pkceChallenge(v), nodeS256(v), reason: 'verifier=$v');
      }
    }, skip: !nodeAvailable);

    test('метод S256, а не plain', () {
      // `plain` — это verifier, отправленный как challenge. Такой код проходит
      // локально, но Google отвергает запрос, а выглядит это как «вход не
      // работает только на десктопе».
      final v = generatePkceVerifier();
      final c = pkceChallenge(v);
      expect(c, isNot(v));
      // SHA-256 = 32 байта = 43 знака base64url без паддинга.
      expect(c.length, 43);
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(c), isTrue);
      expect(c, isNot(contains('=')));
      expect(c, isNot(anyOf(contains('+'), contains('/'))));
    });

    test('разные verifier-ы дают разные challenge', () {
      expect(
        pkceChallenge(generatePkceVerifier()),
        isNot(pkceChallenge(generatePkceVerifier())),
      );
    });
  });

  group('generatePkceVerifier', () {
    test('длина в границах RFC 7636: 43..128', () {
      expect(generatePkceVerifier().length, 64);
      expect(generatePkceVerifier(length: 43).length, 43);
      expect(generatePkceVerifier(length: 128).length, 128);
      expect(() => generatePkceVerifier(length: 32), throwsA(isA<AssertionError>()));
      expect(() => generatePkceVerifier(length: 42), throwsA(isA<AssertionError>()));
      expect(() => generatePkceVerifier(length: 129), throwsA(isA<AssertionError>()));
    });

    test('алфавит незащищённый: проходит через URL без percent-encoding', () {
      final v = generatePkceVerifier(length: 128);
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(v), isTrue);
      expect(Uri.encodeQueryComponent(v), v);
    });

    test('два вызова дают разные значения', () {
      expect(generatePkceVerifier(), isNot(generatePkceVerifier()));
    });
  });

  group('generateOAuthState', () {
    test('не наследует ограничение PKCE: 32 символа допустимы', () {
      expect(generateOAuthState().length, 32);
      expect(generateOAuthState(length: 16).length, 16);
    });

    test('алфавит url-safe и значения не повторяются', () {
      final s = generateOAuthState();
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(s), isTrue);
      expect(Uri.encodeQueryComponent(s), s);
      expect(generateOAuthState(), isNot(generateOAuthState()));
    });
  });
}
