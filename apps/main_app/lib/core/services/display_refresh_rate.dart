import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DisplayRefreshInfo {
  final double current;
  final double max;
  final bool enabled;

  const DisplayRefreshInfo({
    required this.current,
    required this.max,
    required this.enabled,
  });

  /// Экран умеет больше 60 Гц — переключатель имеет смысл.
  bool get supportsHighRate => max > 61;
}

/// Высокая частота обновления экрана (90/120/144 Гц) на Android.
/// Сам режим выбирается нативно ещё до первого кадра; здесь — только
/// чтение состояния и переключатель из настроек.
class DisplayRefreshRate {
  DisplayRefreshRate._();

  static const MethodChannel _channel = MethodChannel('meander/display');

  static bool get isSupportedPlatform => !kIsWeb && Platform.isAndroid;

  static Future<DisplayRefreshInfo?> info() async {
    if (!isSupportedPlatform) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('getInfo');
      if (raw == null) return null;
      return DisplayRefreshInfo(
        current: (raw['current'] as num?)?.toDouble() ?? 60,
        max: (raw['max'] as num?)?.toDouble() ?? 60,
        enabled: raw['enabled'] as bool? ?? true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // Старая нативная часть без канала — просто ничего не делаем.
    } on PlatformException {
      // Режим экрана — косметика, ошибка не должна ронять настройки.
    }
  }
}
