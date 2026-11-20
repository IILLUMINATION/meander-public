import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:canvas_app/app/startup_gate.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

/// Точка входа.
///
/// ⚠️ `WidgetsFlutterBinding.ensureInitialized()` вызывается ЗДЕСЬ, в корневой
/// зоне, до любых async-вызовов. `runApp` тоже в корневой зоне — поэтому
/// zone mismatch не возникает и GL-контекст чистится корректно.
///
/// `runApp` намеренно не ждёт `bootstrap`: первый кадр — это
/// [StartupGate] с индикатором загрузки, а вся инициализация идёт внутри него.
/// Иначе ошибка/зависание Rust-ядра или плагинов оставляла бы пользователя
/// на нативном launch screen без единой подсказки.
void main(List<String> args) {
  _fixLinuxLocale();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StartupGate());
}

/// mpv/libmpv требует LC_NUMERIC=C иначе `Non-C locale detected` → abort
/// (Arch en_US.UTF-8). На iOS/Android ветка не выполняется.
void _fixLinuxLocale() {
  if (!Platform.isLinux) return;
  try {
    final lib = ffi.DynamicLibrary.open('libc.so.6');
    final setlocale = lib.lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Int32, ffi.Pointer<ffi.Char>),
        ffi.Pointer<ffi.Char> Function(int, ffi.Pointer<ffi.Char>)>('setlocale');
    final cStr = 'C'.toNativeUtf8();
    setlocale(1, cStr.cast<ffi.Char>());
    calloc.free(cStr);
  } catch (_) {}
}
