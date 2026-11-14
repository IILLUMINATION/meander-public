import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Идентификатор установки и данные клиента для журнала обращений.
///
/// Сервер пишет в журнал время, IP и пользователя; `X-Device-Id` связывает
/// несколько аккаунтов на одном устройстве и раскрывает цепочку при разборе
/// атаки (один человек — десять свежих регистраций с одного адреса).
///
/// Идентификатор — случайный UUID, созданный при первой отправке запроса и
/// сохранённый локально: он не читает никаких аппаратных данных и меняется
/// только при переустановке или очистке данных приложения.
class DeviceIdentity {
  DeviceIdentity._();

  static const String _deviceIdKey = 'device_id';
  static const String _clientName = 'meander-app';

  static String? _cachedDeviceId;
  static String? _cachedVersion;

  /// Платформа клиента: `android`, `ios`, `linux`, `windows`, `macos`, `web`.
  static String get platform {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'unknown';
  }

  /// Версия сборки. Читается один раз: `PackageInfo` — платформенный канал,
  /// а заголовок нужен на каждый запрос.
  static Future<String?> appVersion() async {
    final cached = _cachedVersion;
    if (cached != null) return cached;
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      final build = info.buildNumber.trim();
      final label = [
        _clientName,
        if (version.isNotEmpty) version,
        if (build.isNotEmpty) build,
      ].join('+');
      _cachedVersion = label;
      return label;
    } catch (_) {
      // Плагин недоступен (тесты, урезанная сборка) — заголовок не нужен
      // настолько, чтобы из-за него падал запрос.
      return null;
    }
  }

  /// Устойчивый идентификатор установки.
  static Future<String> deviceId() async {
    final cached = _cachedDeviceId;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_deviceIdKey);
    if (stored != null && stored.isNotEmpty) {
      _cachedDeviceId = stored;
      return stored;
    }
    final created = const Uuid().v4();
    await prefs.setString(_deviceIdKey, created);
    _cachedDeviceId = created;
    return created;
  }

  /// Заголовки клиента для API. Пустые значения не отправляются: сервер
  /// пишет NULL, а не пустую строку.
  static Future<Map<String, String>> headers() async {
    final id = await deviceId();
    final version = await appVersion();
    return {
      'X-Device-Id': id,
      'X-Client-Platform': platform,
      'X-Client-Version': ?version,
    };
  }
}