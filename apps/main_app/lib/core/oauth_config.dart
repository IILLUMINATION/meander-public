/// OAuth-учётные данные, задаваемые при сборке.
///
/// Публичные client id имеют дефолты: это идентификаторы, а не секреты — они и
/// так лежат в каждом собранном приложении, поэтому чистый клон собирается с
/// рабочим входом без `.env`. Значение из `--dart-define-from-file` эти дефолты
/// переопределяет.
///
/// Секрет desktop-клиента — единственное настоящее секретное значение; он
/// приходит только из окружения и в репозитории не хранится.
class OAuthConfig {
  static const String googleDesktopClientId = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
    defaultValue:
        '410112450155-1balrm0p8ouc90luagcodiforfq0susn.apps.googleusercontent.com',
  );
  static const String googleDesktopClientSecret = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_SECRET',
  );
  static const String googleMobileServerClientId = String.fromEnvironment(
    'GOOGLE_MOBILE_SERVER_CLIENT_ID',
    defaultValue:
        '410112450155-828dsu9o968v0vdg2g0870ioaafoa0is.apps.googleusercontent.com',
  );
  static const String yandexClientId = String.fromEnvironment(
    'YANDEX_CLIENT_ID',
    defaultValue: '003ba61515fb48e8b2ee026e97e3fada',
  );
  static const String telegramClientId = String.fromEnvironment(
    'TELEGRAM_CLIENT_ID',
    defaultValue: '8815960550',
  );
}
