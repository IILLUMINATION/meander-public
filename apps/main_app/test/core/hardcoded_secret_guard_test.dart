import 'dart:io';

import 'package:canvas_app/core/oauth_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Гард на зашитые секреты в клиентском коде.
///
/// Клиентский бинарник распаковывается, а публичный репозиторий читается
/// машинно: любой ключ, попавший в `lib/`, считается утёкшим в момент коммита.
/// Исключение — публичные OAuth client id: это идентификаторы, а не секреты,
/// поэтому в `lib/core/oauth_config.dart` они лежат дефолтами, чтобы сборка с
/// чистого клона работала без `.env`. Секреты по-прежнему приходят только из
/// окружения при сборке (`--dart-define-from-file`).
///
/// Проверяется статически и только `lib/`: бэкенд держит секреты в `.env`, а
/// этот тест запускается из `apps/main_app` и не должен подменять собой
/// серверную проверку.
void main() {
  test('в lib/ нет строк, похожих на секреты', () {
    final hits = <String>[];
    for (final src in _clientSources().entries) {
      hits.addAll(_findSecrets(src.key, src.value));
    }
    expect(hits, isEmpty, reason: 'похоже на ключи:\n${hits.join('\n')}');
  });

  group('негативные контроли сканера', () {
    test('каждый класс секретов находится, а не пропускается', () {
      // Образцы собираются интерполяцией: в исходнике нет цельных
      // секрето-подобных литералов, но сканер получает готовые строки.
      const googlePrefix = 'GOCSPX';
      const googleTail = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const accessTail = 'a0AbCdEfGhIjKlMnOpQrStUvWxYz';
      const openAiTail = 'abcdefghijklmnopqrstuvwxyz012345';
      const githubTail = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const gitlabTail = 'aaaaaaaaaaaaaaaaaaaa';
      const awsTail = 'ABCDEFGHIJKLMNOP';
      const pemKind = 'RSA';
      final samples = <String, String>{
        'google client secret': "const s = '$googlePrefix-$googleTail';",
        'литеральный client_secret': "body: {'client_secret': 'hardcoded'};",
        'google access token': "const t = 'ya29.$accessTail';",
        'openai key': "const k = 'sk-$openAiTail';",
        'github token': "const g = 'ghp_$githubTail';",
        'gitlab token': "const g = 'glpat-$gitlabTail';",
        'aws key id': "const a = 'AKIA$awsTail';",
        'private key':
            'const pem = """\n-----BEGIN $pemKind PRIVATE KEY-----\nabc\n""";',
      };
      for (final entry in samples.entries) {
        expect(
          _findSecrets('lib/sample.dart', entry.value),
          isNotEmpty,
          reason: entry.key,
        );
      }
    });

    test('литеральный Google client id находится', () {
      // ID собирается интерполяцией: в исходнике нет цельного литерала,
      // но сканер получает готовую строку и обязан её поймать.
      const project = '123456789012';
      const suffix = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(
        _findSecrets(
          'lib/a.dart',
          "const id = '$project-$suffix.apps.googleusercontent.com';",
        ),
        isNotEmpty,
      );
    });

    test('Slack token находится', () {
      // Хвост собирается интерполяцией: в исходнике нет цельного литерала,
      // но сканер получает готовую строку и обязан её поймать.
      const tail = '123456789012-abcdefghijklmnop';
      expect(
        _findSecrets('lib/a.dart', "const s = 'xoxb-$tail';"),
        isNotEmpty,
      );
    });

    test('публичный по смыслу ключ Firebase не считается секретом', () {
      // apiKey из GoogleService-Info.plist / firebase_options.dart: клиентский
      // ключ, который всё равно лежит в собранном приложении и защищается
      // ограничением домена/bundle id на стороне Google.
      const firebaseTail = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      expect(
        _findSecrets(
          'lib/firebase_options.dart',
          "apiKey: 'AIzaSy$firebaseTail',",
        ),
        isEmpty,
      );
    });

    test('комментарии не ловятся, код — ловится', () {
      const secretPrefix = 'GOCSPX';
      expect(
        _findSecrets(
          'lib/a.dart',
          '// раньше тут был $secretPrefix-ключ, вывезли',
        ),
        isEmpty,
      );
      expect(
        _findSecrets('lib/a.dart', "const s = '$secretPrefix-ключ';"),
        isNotEmpty,
      );
    });

    test('сканер не ослеп: файлов в lib/ много', () {
      expect(_clientSources().length, greaterThan(300));
    });

    test('конфиг OAuth: публичные id как дефолты, секрета нет', () {
      final text = _clientSources()['lib/core/oauth_config.dart'] ?? '';
      expect(text, contains('String.fromEnvironment'));
      expect(text, contains('GOOGLE_DESKTOP_CLIENT_ID'));
      expect(text, contains('YANDEX_CLIENT_ID'));
      expect(text, contains('TELEGRAM_CLIENT_ID'));
      // Дефолты — обычные константы, а пустая env-переменная трактуется как
      // «не задана»: иначе старый .env выключал вход после git pull.
      expect(text, contains('oauthValueOrDefault'));
      expect(text, contains('_googleDesktopClientIdDefault'));
      expect(text, isNot(contains('GOCSPX' '-')));
      expect(text, isNot(contains("'client_secret'")));
      // У секрета desktop-клиента дефолта быть не должно: только окружение.
      expect(
        RegExp(r"'GOOGLE_DESKTOP_CLIENT_SECRET',\s*\)").hasMatch(text),
        isTrue,
        reason: 'секрет не должен иметь defaultValue',
      );
    });

    test('пустая env-переменная не перекрывает дефолт', () {
      expect(oauthValueOrDefault('', 'default'), 'default');
      expect(oauthValueOrDefault('   ', 'default'), 'default');
      // Негативный контроль: непустое значение обязано побеждать, иначе
      // --dart-define молча игнорировался бы.
      expect(oauthValueOrDefault('custom', 'default'), 'custom');
      expect(oauthValueOrDefault(' custom ', 'default'), 'custom');
    });

    test('client id разрешён только в oauth_config.dart', () {
      // Тот же литерал: в конфиге — легальный дефолт, в любом другом файле —
      // утёкший идентификатор, который сканер обязан поймать.
      const id =
          '123456789012-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.apps.googleusercontent.com';
      expect(
        _findSecrets('lib/core/oauth_config.dart', "const id = '$id';"),
        isEmpty,
      );
      expect(_findSecrets('lib/other.dart', "const id = '$id';"), isNotEmpty);
    });

    test('секрет в oauth_config.dart всё равно ловится', () {
      const secretPrefix = 'GOCSPX';
      expect(
        _findSecrets(
          'lib/core/oauth_config.dart',
          "const s = '$secretPrefix-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';",
        ),
        isNotEmpty,
      );
    });
  });

  test('без --dart-define публичные ключи не пусты', () {
    expect(OAuthConfig.googleDesktopClientId, isNotEmpty);
    expect(OAuthConfig.googleMobileServerClientId, isNotEmpty);
    expect(OAuthConfig.yandexClientId, isNotEmpty);
    expect(OAuthConfig.telegramClientId, isNotEmpty);
    expect(
      OAuthConfig.googleDesktopClientSecret,
      isEmpty,
      reason: 'секрет обязан приходить только из окружения',
    );
  });
}

/// Классы ключей, которые не имеют права жить в клиентском коде.
final _rules = <String, RegExp>{
  'Google client secret': RegExp(r'GOCSPX' r'-'),
  'Google OAuth client id': RegExp(
    r'\d{6,}-[a-z0-9_-]{10,}\.apps\.googleusercontent\.com',
  ),
  'client_secret в литерале': RegExp(
    r'''['"]client_secret['"]\s*:\s*['"][^'"]+['"]''',
  ),
  'Google access token': RegExp(r'ya29\.[A-Za-z0-9_-]{20,}'),
  'OpenAI-подобный ключ': RegExp(r'\bsk-[A-Za-z0-9]{20,}'),
  'GitHub token': RegExp(r'\b(ghp_|gho_|github_pat_)[A-Za-z0-9_]{20,}'),
  'GitLab token': RegExp(r'\bglpat-[A-Za-z0-9_-]{20}'),
  'AWS key id': RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  'Slack token': RegExp(r'\bxox[baprs]-[A-Za-z0-9-]{10,}'),
  'закрытый ключ': RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
};

/// Строки-нарушения в виде `файл:строка  класс`.
List<String> _findSecrets(String file, String text) {
  final out = <String>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    // Комментарий — не код: в нём классы ключей вспоминаются в объяснение,
    // почему их больше нет.
    if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
    for (final rule in _rules.entries) {
      // Client id — публичный идентификатор, а не секрет. Разрешаем его только
      // в конфиге OAuth, где он служит дефолтом для сборки без `.env`; секреты
      // и идентификаторы во всех остальных файлах остаются нарушениями.
      if (rule.key == 'Google OAuth client id' &&
          file == 'lib/core/oauth_config.dart') {
        continue;
      }
      if (rule.value.hasMatch(line)) {
        out.add('$file:${i + 1}  ${rule.key}');
      }
    }
  }
  return out;
}

Map<String, String> _clientSources() {
  final root = Directory('lib');
  if (!root.existsSync()) {
    throw StateError(
      'гард запускается из apps/main_app: каталог lib/ не найден '
      '(${Directory.current.path})',
    );
  }
  final out = <String, String>{};
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    out[entity.path.replaceAll(r'\', '/')] = entity.readAsStringSync();
  }
  return out;
}
