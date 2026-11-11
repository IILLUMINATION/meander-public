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

  /// Зеркала в порядке приоритета. Сейчас встроенное одно — основной
  /// домен: Cloudflare-workers зеркало (`meander.elitrycraft.workers.dev`)
  /// умерло вместе с `meander.sbs` и отвечало 530, но зонд считал его
  /// живым и переключал на него весь API, включая websocket. Свои зеркала
  /// пользователь добавляет в настройках.
  static const List<String> defaultMirrorUrls = [vpsApiBaseUrl];

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
