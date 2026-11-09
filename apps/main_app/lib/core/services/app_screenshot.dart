import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Снимок экрана средствами самого Flutter.
///
/// Нужен там, где внешние скриншотеры бессильны: на Wayland окно снимается
/// только с правами X/Wayland и ломается от композитора, а здесь берётся ровно
/// тот кадр, который отрисовал движок — в том числе поверх GL-слоя.
///
/// Включён, только если задан `MND_SCREENSHOT_DIR` (рядом с запуском
/// приложения): тогда `Ctrl+Shift+S` кладёт PNG в этот каталог и печатает
/// путь в stdout. Без переменной хоткей выключен, обработчик ничего не делает —
/// обычная сборка ведёт себя как раньше.
class AppScreenshot {
  AppScreenshot._();

  /// Каталог для снимков; пусто — снимки выключены.
  static String get directory =>
      overrideDirectory ??
      Platform.environment['MND_SCREENSHOT_DIR'] ??
      '';

  /// Подмена каталога в тестах: `Platform.environment` изменить нельзя.
  @visibleForTesting
  static String? overrideDirectory;

  static bool get enabled => directory.isNotEmpty;

  /// Ключ корневого `RepaintBoundary`: по нему достаётся отрисованный кадр.
  static final GlobalKey boundaryKey = GlobalKey();

  /// Подписаться на клавиатуру (`Ctrl+Shift+S`). Вызывается один раз из корня
  /// приложения — так корневой виджет не зависит от `flutter/services`.
  static void install() => HardwareKeyboard.instance.addHandler(onKeyEvent);

  /// Отписаться (при уничтожении корневого виджета).
  static void uninstall() => HardwareKeyboard.instance.removeHandler(onKeyEvent);

  /// Обработчик клавиатуры для `HardwareKeyboard.addHandler`.
  ///
  /// Возвращает true, только когда событие наше — иначе приложение теряло бы
  /// `Ctrl+Shift+S` во всех остальных местах.
  static bool onKeyEvent(KeyEvent event) {
    if (!enabled) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyS) return false;
    if (!HardwareKeyboard.instance.isControlPressed) return false;
    if (!HardwareKeyboard.instance.isShiftPressed) return false;
    unawaited(capture());
    return true;
  }

  /// Записать текущий кадр в PNG и вернуть путь (null — если не получилось).
  static Future<String?> capture() async {
    if (!enabled) return null;
    final ro = boundaryKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    final image = await ro.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;

    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path =
        '${dir.path}/shot_${DateTime.now().millisecondsSinceEpoch}.png';
    await File(path).writeAsBytes(data.buffer.asUint8List());
    debugPrint('[Screenshot] $path');
    return path;
  }
}
