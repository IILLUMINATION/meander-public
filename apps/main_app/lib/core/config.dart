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

  static const String vpsApiBaseUrl = 'https://meander.illuminat.dev';
  static const String localApiBaseUrl = 'http://192.168.0.101:3000';

  /// Зеркала в порядке приоритета: основное первое, далее reverse-proxy
  /// через Cloudflare Workers (обход DNS/SNI-блокировок домена).
  static const List<String> defaultMirrorUrls = [
    vpsApiBaseUrl,
    'https://meander.elitrycraft.workers.dev',
  ];

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
