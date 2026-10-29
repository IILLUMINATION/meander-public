import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

/// PKCE (RFC 7636) для desktop-входа через Google.
///
/// Desktop-клиент OAuth — публичный: его бинарник распаковывается, поэтому
/// секрет, зашитый в код, не защищает ничего. Перехват кода с loopback-порта
/// закрывает verifier, который живёт только в памяти одного запуска.
const _urlSafeAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

String _randomUrlSafe(int length) {
  final random = Random.secure();
  return List.generate(
    length,
    (_) => _urlSafeAlphabet[random.nextInt(_urlSafeAlphabet.length)],
  ).join();
}

/// `code_verifier`: RFC требует 43..128 символов незащищённого алфавита
/// (`[A-Z] [a-z] [0-9] - . _ ~`) — те же символы проходят через URL и form-encode.
String generatePkceVerifier({int length = 64}) {
  assert(length >= 43 && length <= 128, 'verifier должен быть 43..128 символов');
  return _randomUrlSafe(length);
}

/// `state` — анти-CSRF nonce для OAuth-редиректа. Ограничение PKCE 43..128
/// к нему не относится, поэтому у него отдельный генератор.
String generateOAuthState({int length = 32}) => _randomUrlSafe(length);

/// `code_challenge` для метода S256: BASE64URL(SHA256(verifier)) без паддинга.
String pkceChallenge(String verifier) {
  final digest = crypto.sha256.convert(utf8.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}
