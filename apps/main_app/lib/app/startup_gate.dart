import 'dart:async';

import 'package:canvas_app/app/bootstrap.dart';
import 'package:canvas_app/app/startup_failure.dart';
import 'package:canvas_app/core/services/crash_log_service.dart';
import 'package:canvas_app/core/services/hang_watchdog.dart';
import 'package:flutter/material.dart';

typedef StartupLoader = Future<Widget> Function();

/// Корневой виджет, который гарантирует первый кадр до тяжёлой инициализации.
///
/// Раньше `main()` ждал `bootstrap()`, а `bootstrap()` вызывал `runApp` в самом
/// конце. Любая ошибка или зависание в Rust/плагинах/SharedPreferences
/// оставляли пользователя на нативном launch screen — визуально «залитый
/// цветом экран». Теперь `runApp` происходит сразу, а `bootstrap` идёт внутри
/// этого виджета. Ошибка превращается в экран с текстом, который можно
/// скопировать и прислать без Mac/Xcode.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    this.boot = bootApplication,
    this.timeout = const Duration(seconds: 45),
  });

  final StartupLoader boot;
  final Duration timeout;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  Widget? _app;
  StartupFailureInfo? _failure;
  bool _running = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    // Сначала даём Flutter нарисовать экран загрузки. Если запустить
    // bootstrap прямо здесь, его синхронная часть (нативные вызовы FRB)
    // может задержать первый кадр — и пользователь снова увидит только
    // нативный LaunchScreen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_boot());
    });
  }

  Future<void> _boot() async {
    if (_running) return;
    _running = true;
    HangWatchdog.mark('startup: boot');
    final attempt = ++_attempt;
    final stopwatch = Stopwatch()..start();

    try {
      final app = await widget.boot().timeout(widget.timeout);
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _app = app;
        _failure = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        HangWatchdog.mark('app: first frame');
        unawaited(runAfterFirstFrame());
      });
    } on TimeoutException catch (error, stack) {
      _fail(attempt, error, stack, stopwatch.elapsed, timedOut: true);
    } catch (error, stack) {
      _fail(attempt, error, stack, stopwatch.elapsed, timedOut: false);
    } finally {
      _running = false;
    }
  }

  void _fail(
    int attempt,
    Object error,
    StackTrace stack,
    Duration elapsed, {
    required bool timedOut,
  }) {
    if (!mounted || attempt != _attempt) return;
    // Старый bootstrap мог зависнуть, а не упасть. Инвалидируем его результат,
    // чтобы позднее завершение не подменило уже показанный экран ошибки.
    _attempt++;
    CrashLogService.handle(
      error,
      stack,
      timedOut ? 'Startup timeout' : 'Startup error',
    );
    setState(() {
      _failure = StartupFailureInfo(
        error: error,
        stackTrace: stack,
        step: HangWatchdog.lastStep,
        elapsed: elapsed,
        timedOut: timedOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null) {
      return StartupFailureApp(info: failure);
    }
    final app = _app;
    if (app != null) return app;
    return const StartupLoadingApp();
  }
}