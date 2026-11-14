import 'package:canvas_app/core/services/mirror_registry.dart';

enum BackendType { local, vps }

/// Конфигурация подключения к бэкенду.
///
/// Бэкенд может быть недоступен из отдельных сетей (блокировка домена):
/// приложение перебирает зеркала ([defaultMirrorUrls]) и пользовательское
/// зеркало из настроек. Активный URL хранится в [MirrorRegistry]
/// (SharedPreferences), поэтому `apiUrl` — runtime-значение, а не const.
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

  /// Зеркала в порядке приоритета: основной домен первым, дальше публичные
  /// зеркала сообщества.
  ///
  /// Основной домен могут блокировать в сети пользователя (в РФ — решением
  /// РКН), поэтому встроены три зеркала: каждое отдаёт тот же API, и
  /// [MirrorRegistry] переходит к следующему только после реального отказа
  /// (сеть, таймаут или 5xx), а не «на всякий случай». Проверено 14.11.2026:
  /// все три отдают `GET /quests` → 200 с тем же каталогом.
  ///
  /// Свои зеркала пользователь добавляет в настройках.
  static const List<String> defaultMirrorUrls = [
    vpsApiBaseUrl,
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

  /// Текущий базовый URL API. При следующей неудачной попытке подключения
  /// [MirrorRegistry] переключит зеркало, и последующие запросы пойдут
  /// уже на него.
  static String get apiUrl {
    switch (currentBackend) {
      case BackendType.vps:
        return MirrorRegistry.instance.activeUrl;
      case BackendType.local:
        return localApiBaseUrl;
    }
  }
}
