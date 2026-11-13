import 'dart:async';
import 'dart:io';

import 'package:canvas_app/app/app.dart';
import 'package:canvas_app/core/l10n/custom_language_store.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/l10n/l10n_provider.dart';
import 'package:canvas_app/core/services/crash_log_service.dart';
import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:canvas_app/core/services/hang_watchdog.dart';
import 'package:canvas_app/core/services/firebase_messaging_service.dart';
import 'package:canvas_app/core/services/meander_core_bootstrap.dart';
import 'package:canvas_app/core/services/rebuild_storm_observer.dart';
import 'package:canvas_app/core/services/talker_service.dart';
import 'package:canvas_app/features/game/providers/game_screen_provider.dart'
    show appGameScreenHooksProvider;
import 'package:mnd_player/providers/game_screen_provider.dart'
    show gameScreenHooksProvider;
import 'package:mnd_player/utils/device_memory.dart' show physicalMemoryBytes;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:mnd_core/mnd_core.dart' show initRustCore;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

// ══════════════════════════════════════════════════════════════════
// NOTE: WidgetsFlutterBinding.ensureInitialized() вызывается в
// main.dart, в корневой зоне. Здесь НЕ вызываем — иначе zone mismatch.
// ══════════════════════════════════════════════════════════════════

Future<void> _initRustCore() async {
  try {
    final ExternalLibrary? externalLibrary = (!kIsWeb && Platform.isIOS)
        ? ExternalLibrary.process(iKnowHowToUseIt: true)
        : null;
    await initRustCore(externalLibrary: externalLibrary);
  } catch (e) {
    final buildHint = Platform.isLinux
        ? 'cargo build --release -p mnd-ffi'
        : Platform.isMacOS
        ? './scripts/build_ffi_apple.sh --macos'
        : './scripts/build_ffi_apple.sh --all';
    debugPrint(
      'Не удалось загрузить нативное Rust-ядро. '
      'Соберите библиотеку: $buildHint. Ошибка: $e',
    );
    rethrow;
  }
}

Future<void> _verifyAppIntegrity() async {
  if (kIsWeb || Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return;
  }
  try {
    await PackageInfo.fromPlatform();
  } catch (e) {
    debugPrint("Security check warning: $e");
  }
}

// ─── Main window lifecycle (window_manager) ──────────────────────

class _MainWindowCloseHandler with WindowListener {
  final WindowManager _wm;
  _MainWindowCloseHandler(this._wm);

  @override
  void onWindowClose() async {
    _wm.setPreventClose(false);
    await _wm.destroy();
  }
}

Future<void> _initMainWindowLifecycle() async {
  final wm = WindowManager.instance;
  wm.setPreventClose(true);
  wm.addListener(_MainWindowCloseHandler(wm));
}

// ─── Uncaught error handler (replaces runZonedGuarded) ────────────

void _setupGlobalErrorHandlers() {
  // Разовый дамп полного контекста для «multiple tickers» на RawTooltip:
  // короткий CrashLog не содержит «error-causing widget», без которого
  // виновника не найти.
  bool tickerDebugDumped = false;
  FlutterError.onError = (details) {
    final originalDebugPrint = debugPrint;
    if (!tickerDebugDumped &&
        kDebugMode &&
        details.exception.toString().contains(
          'multiple tickers were created',
        )) {
      tickerDebugDumped = true;
      debugPrint('═══ TICKER DEBUG: полный контекст ошибки ═══');
      debugPrint(details.toString());
      debugPrint('═══ STACK ═══');
      debugPrint(details.stack?.toString() ?? '(нет стека)');
      debugPrint('═══ END TICKER DEBUG ═══');
    }
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        for (final line in message.split('\n')) {
          CrashLogService.writeRaw('  | $line');
        }
      }
    };
    FlutterError.dumpErrorToConsole(details);
    debugPrint = originalDebugPrint;
    try {
      final full = details.toString();
      if (full.trim().isNotEmpty) {
        CrashLogService.writeRaw('  | [details] $full');
      }
    } catch (_) {}
    CrashLogService.handle(details.exception, details.stack, 'FlutterError');

    if (kDebugMode) {
      final text = details.toString();
      final isListTileWarning = text.contains(
        'ListTile background color or ink splashes may be invisible',
      );
      if (isListTileWarning) {
        debugPrint('═══ LIST TILE DEBUG: offending widget context ═══');
        debugPrint(text);
        debugPrint(
          'Источник: Flutter framework assertion; stack может быть пустым.',
        );
        debugPrint(
          'Ищите ближайший ListTile с onTap в полном widget context выше.',
        );
        debugPrint('═══ END LIST TILE DEBUG ═══');
      }
      debugPrint('🔴 Flutter ERROR: ${details.exception}');
    } else {
      talker.handle(details.exception, details.stack, 'Flutter Error');
      FlutterError.presentError(details);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    CrashLogService.handle(error, stack, 'PlatformError');
    if (kDebugMode) {
      debugPrint("🔴 UNCAUGHT ERROR: $error");
      debugPrintStack(stackTrace: stack);
      debugPrint(
        '[CrashLog] файл лога: ${CrashLogService.currentFilePath ?? "… будет создан"}',
      );
    } else {
      talker.handle(error, stack, 'Platform Error');
    }
    return true;
  };
}

// ─── Main bootstrap ───────────────────────────────────────────────

Future<void> bootstrap() async {
  _setupGlobalErrorHandlers();

  HangWatchdog.start();
  HangWatchdog.mark('bootstrap: initRustCore');

  await _initRustCore();

  HangWatchdog.mark('bootstrap: meanderCoreBootstrap');
  MeanderCoreBootstrap.initialize(debugLogs: kDebugMode);
  HangWatchdog.mark('bootstrap: deepLink');
  DeepLinkService().init();

  // Кэш декодированных картинок ограничиваем по памяти устройства. Дефолт
  // Flutter — 100 МиБ и 1000 картинок: на 2 ГБ это заметная доля бюджета, а
  // на телефоне с 8 ГБ всё равно не нужно больше. Ограничение ставим до
  // первого кадра, чтобы первый же экран не набил кэш под завязку.
  _configureImageCache();

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  if (!kDebugMode) {
    FlutterError.onError = (details) =>
        talker.handle(details.exception, details.stack, 'Flutter Error');
    PlatformDispatcher.instance.onError = (error, stack) {
      talker.handle(error, stack, 'Platform Error');
      return true;
    };
  }

  HangWatchdog.mark('bootstrap: runApp');

  // Язык читаем до первого кадра: сплэш должен выйти уже на выбранном языке,
  // а не перекрашиваться на ходу. Импортные языки регистрируем раньше выбора —
  // иначе код выбранного языка в настройках окажется неизвестным и приложение
  // стартует на русском.
  HangWatchdog.mark('bootstrap: custom languages');
  await customLanguageStore.loadAll();
  await initAppLanguage();
  // Жалобу «приложение открылось не на моём языке» иначе не проверить: язык
  // выбранного интерфейса виден только на экране, а системные локали — вообще
  // нигде. В логе обе стороны рядом.
  debugPrint(
    '[l10n] язык ${L10n.code}; системные локали: '
    '${WidgetsBinding.instance.platformDispatcher.locales.map((l) => l.toLanguageTag()).join(", ")}',
  );

  runApp(
    ProviderScope(
      observers: [if (kDebugMode) RebuildStormObserver()],
      overrides: [
        // Единый gameScreenProvider (mnd_player) использует main_app-сервисы.
        gameScreenHooksProvider.overrideWith(
          (ref) => ref.watch(appGameScreenHooksProvider),
        ),
      ],
      child: const App(),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    HangWatchdog.mark('app: first frame');
    // Всё, что не нужно для первого кадра, уходит за него: Firebase умеет
    // висеть до 10 секунд (см. таймаут), а проверка пакета — платформенный
    // вызов. Раньше пользователь всё это время видел только фон сплэша.
    unawaited(_initAfterFirstFrame());
  });

  if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    _initMainWindowLifecycle();
  }
}

/// Инициализация, которая не должна задерживать первый кадр.
Future<void> _initAfterFirstFrame() async {
  await _verifyAppIntegrity();

  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await FirebaseMessagingService().initialize().timeout(
      const Duration(seconds: 10),
    );
  } catch (e) {
    debugPrint('⚠️ FCM init skipped (timeout/error): $e');
  }
}

/// Верхняя граница кэша декодированных картинок по объёму памяти устройства.
///
/// Дефолт Flutter — 100 МиБ и 1000 картинок, независимо от телефона. На 2 ГБ
/// это четверть доступной кучи: полноразмерные фото из ленты выбивают процесс
/// раньше, чем кэш успевает принести пользу. Берём ~4% памяти, но не меньше
/// 32 МиБ (иначе кэш бесполезен) и не больше 128 МиБ.
void _configureImageCache() {
  var memoryBytes = 0;
  try {
    memoryBytes = physicalMemoryBytes();
  } catch (_) {
    memoryBytes = 0;
  }
  final cache = PaintingBinding.instance.imageCache;
  if (memoryBytes > 0) {
    final target = (memoryBytes * 0.04).round().clamp(
      32 * 1024 * 1024,
      128 * 1024 * 1024,
    );
    cache.maximumSizeBytes = target;
  }
  if (cache.maximumSize > 300) cache.maximumSize = 300;
}
