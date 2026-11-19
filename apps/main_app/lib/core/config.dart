import 'package:canvas_app/core/services/server_registry.dart';

enum BackendType { local, vps }

/// Конфигурация подключения к бэкенду.
///
/// Оригинальный сервер один — [vpsApiBaseUrl]. Если его блокирует провайдер,
/// доступ дают **слепые ретрансляторы TLS** ([relayUrls]): они перекладывают
/// байты, а TLS терминирует сам клиент, поэтому посредник не видит ни токен,
/// ни переписку. Шлюзов-прокси, которые расшифровывают трафик, приложение
/// больше не использует ни при каких условиях.
///
/// Активный URL — [ServerRegistry] (SharedPreferences), поэтому `apiUrl` —
/// runtime-значение, а не const.
class AppConfig {
  static const BackendType currentBackend = BackendType.vps;

  /// Публичный адрес бэкенда (он же адрес сайта). Единственное место, где
  /// домен вписан в код: при переезде меняется здесь либо, без правки
  /// исходников, на сборке —
  /// `flutter build apk --dart-define=MEANDER_API_BASE=https://new.host`.
  static const String vpsApiBaseUrl = String.fromEnvironment(
    'MEANDER_API_BASE',
    defaultValue: 'https://meander.illuminat.dev',
  );

  /// Хост без схемы — для подписей, PDF и текстов («Meander · host»).
  static String get siteHost => Uri.parse(vpsApiBaseUrl).host;

  /// Ссылка на публичную страницу: `shareUrl('quest', id)`.
  static String shareUrl(String kind, String id) =>
      '$vpsApiBaseUrl/share/$kind/$id';
  static const String localApiBaseUrl = 'http://192.168.0.101:3000';

  /// Устаревшие адреса зеркал-прокси, которые раньше стояли в переборе.
  ///
  /// Каждый из них терминировал TLS (nginx/uvicorn, CF worker) или работал по
  /// открытому `http:` — значит, видел `Authorization` и переписку. Теперь
  /// такие адреса не используются и вычищаются из сохранённого списка при
  /// обновлении: `ServerRegistry._ensureLoaded`.
  static const List<String> retiredProxyUrls = [
    'http://78.154.103.40:14175',
    'https://meander.elitrycraft.workers.dev',
    'https://meander.hashai.cc.cd',
  ];

  /// Слепые ретрансляторы TLS (`host:port`), через которые запросы к
  /// основному домену идут, не раскрывая содержимого посреднику: TLS
  /// терминирует сам клиент, сертификат проверяется по [vpsApiBaseUrl].
  ///
  /// Задаются на сборке, чтобы не тащить конкретный IP в код:
  /// `--dart-define=MEANDER_RELAYS=1.2.3.4:8443,5.6.7.8:8443`.
  static List<String> get relayUrls {
    const raw = String.fromEnvironment(
      'MEANDER_RELAYS',
      defaultValue: '194.31.223.9:8443',
    );
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// Текущий базовый URL API: оригинал или явно выбранный свой сервер.
  /// Прокси-зеркал здесь не бывает.
  static String get apiUrl {
    switch (currentBackend) {
      case BackendType.vps:
        return ServerRegistry.instance.activeUrl;
      case BackendType.local:
        return localApiBaseUrl;
    }
  }
}
