// ============================================================================
//  Трасса этапов открытия игровой сцены.
//
//  `debugPrint` уходит только в консоль `flutter run` и теряется вместе с
//  ней: по записи сессии не видно, какой `await` съел секунды между
//  `game start` и первым кадром. Пишем те же метки в файл, чтобы замер
//  пережил перезапуск и его можно было сравнить «до/после».
//
//  Только debug: в release ни файла, ни синхронных записей.
// ============================================================================
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

class LoadTrace {
  LoadTrace._();

  static final String logPath =
      '${Directory.systemTemp.path}${Platform.pathSeparator}mnd_game_load.log';

  static final Stopwatch _clock = Stopwatch();
  static bool _active = false;
  static bool _truncated = false;

  /// Начать новую трассу. Первый вызов в процессе очищает файл, чтобы
  /// старые прогоны не смешивались с новым.
  static void begin(String label) {
    if (!kDebugMode) return;
    _active = true;
    _clock
      ..reset()
      ..start();
    _write('=== BEGIN $label ===', truncate: !_truncated);
    _truncated = true;
  }

  /// Отметить этап. Метки дешёвые: несколько десятков строк на запуск.
  static void mark(String stage) {
    if (!kDebugMode || !_active) return;
    _write('$stage: ${_clock.elapsedMilliseconds}ms');
  }

  static void end() {
    if (!kDebugMode || !_active) return;
    _write('=== END: ${_clock.elapsedMilliseconds}ms ===');
    _active = false;
  }

  static void _write(String line, {bool truncate = false}) {
    final text = '${DateTime.now().toIso8601String()} $line\n';
    try {
      File(logPath).writeAsStringSync(
        text,
        mode: truncate ? FileMode.write : FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Трасса не должна ломать запуск игры.
    }
    debugPrint('[LoadTrace] $line');
  }
}
