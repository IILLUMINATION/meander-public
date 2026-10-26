/// OAuth-учётные данные, задаваемые при сборке.
///
/// Публичные client id имеют дефолты: это идентификаторы, а не секреты — они и
/// так лежат в каждом собранном приложении, поэтому чистый клон собирается с
/// рабочим входом без `.env`. Значение из `--dart-define-from-file` эти дефолты
/// переопределяет.
///
/// Пустая переменная окружения считается незаданной. `String.fromEnvironment`
/// сам так не умеет: определённое, но пустое значение он возвращает как есть и
/// `defaultValue` не подставляет. Из-за этого `.env`, скопированный из
/// `.env.example` до появления дефолтов, после `git pull` выключал вход —
/// теперь пустые строки ничего не ломают.
///
/// Секрет desktop-клиента в клиенте больше не нужен: обмен кода на токен
/// делает наш сервер (`POST /auth/google/exchange`). Если секрет всё-таки
/// задан при сборке, клиент по-прежнему может обменять код напрямую.
class OAuthConfig {
  static const String _googleDesktopClientIdEnv = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
  );
  static const String _googleDesktopClientIdDefault =
      '410112450155-1balrm0p8ouc90luagcodiforfq0susn.apps.googleusercontent.com';

  static const String googleDesktopClientSecret = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_SECRET',
  );

  static const String _googleMobileServerClientIdEnv = String.fromEnvironment(
    'GOOGLE_MOBILE_SERVER_CLIENT_ID',
  );
  static const String _googleMobileServerClientIdDefault =
      '410112450155-828dsu9o968v0vdg2g0870ioaafoa0is.apps.googleusercontent.com';

  static const String _yandexClientIdEnv = String.fromEnvironment(
    'YANDEX_CLIENT_ID',
  );
  static const String _yandexClientIdDefault = '003ba61515fb48e8b2ee026e97e3fada';

  static const String _telegramClientIdEnv = String.fromEnvironment(
    'TELEGRAM_CLIENT_ID',
  );
  static const String _telegramClientIdDefault = '8815960550';

  static String get googleDesktopClientId => oauthValueOrDefault(
    _googleDesktopClientIdEnv,
    _googleDesktopClientIdDefault,
  );

  static String get googleMobileServerClientId => oauthValueOrDefault(
    _googleMobileServerClientIdEnv,
    _googleMobileServerClientIdDefault,
  );

  static String get yandexClientId =>
      oauthValueOrDefault(_yandexClientIdEnv, _yandexClientIdDefault);

  static String get telegramClientId =>
      oauthValueOrDefault(_telegramClientIdEnv, _telegramClientIdDefault);
}

/// Значение из окружения, а при пустой строке — дефолт сборки.
String oauthValueOrDefault(String envValue, String fallback) {
  final value = envValue.trim();
  return value.isEmpty ? fallback : value;
}
