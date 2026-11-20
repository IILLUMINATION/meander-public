import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/services/hang_watchdog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Данные об ошибке, из-за которой приложение не смогло показать первый экран.
///
/// Это не пользовательская ошибка экрана, а аварийный отчёт: он должен
/// помещаться в буфер обмена целиком, чтобы тестировщик мог прислать его
/// разработчику без Xcode и консоли.
class StartupFailureInfo {
  const StartupFailureInfo({
    required this.error,
    this.stackTrace,
    this.step,
    this.elapsed,
    this.timedOut = false,
  });

  final Object error;
  final StackTrace? stackTrace;
  final String? step;
  final Duration? elapsed;
  final bool timedOut;

  String get title =>
      timedOut ? 'Запуск не завершился' : 'Не удалось запустить Meander';

  String get message => timedOut
      ? 'Инициализация не уложилась в отведённое время. '
          'Скорее всего, завис один из шагов запуска.'
      : 'При инициализации произошла ошибка. Ниже — технические детали.';

  String get report {
    final buffer = StringBuffer()
      ..writeln('Meander: ошибка запуска')
      ..writeln('Время: ${DateTime.now().toIso8601String()}')
      ..writeln(
        'Платформа: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}',
      )
      ..writeln(
        'Режим: ${kReleaseMode ? 'release' : kProfileMode ? 'profile' : 'debug'}',
      )
      ..writeln('Шаг: ${step ?? HangWatchdog.lastStep}')
      ..writeln(
        'Прошло: ${elapsed == null ? 'неизвестно' : '${elapsed!.inMilliseconds} мс'}',
      )
      ..writeln('Таймаут: ${timedOut ? 'да' : 'нет'}')
      ..writeln('Ошибка: $error');

    final stack = stackTrace;
    if (stack != null) {
      final lines = stack.toString().trimRight().split('\n');
      buffer.writeln('Стек:');
      for (final line in lines.take(80)) {
        buffer.writeln(line);
      }
      if (lines.length > 80) {
        buffer.writeln('… ещё ${lines.length - 80} строк');
      }
    }
    return buffer.toString();
  }
}

/// Аварийный экран, который можно показать и внутри `App`, и до его запуска.
class StartupFailurePane extends StatelessWidget {
  const StartupFailurePane({
    super.key,
    required this.info,
    this.onRetry,
    this.backgroundColor,
  });

  final StartupFailureInfo info;
  final VoidCallback? onRetry;
  final Color? backgroundColor;

  Future<void> _copy(BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: info.report));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось скопировать: $error')),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Текст ошибки скопирован')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = backgroundColor ?? scheme.surface;

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.error_outline, size: 44, color: scheme.error),
              const SizedBox(height: 12),
              Text(
                info.title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                info.message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Шаг: ${info.step ?? HangWatchdog.lastStep}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      info.report,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface,
                        fontFamily: 'monospace',
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Скопируйте текст и отправьте разработчику — этого достаточно, '
                'чтобы найти причину без консоли.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy_all),
                label: const Text('Скопировать ошибку'),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить запуск'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Первый кадр до завершения `bootstrap`.
///
/// Фон совпадает с `LaunchScreen.storyboard`, поэтому переход из нативного
/// launch screen не мигает. В отличие от голого фона здесь есть спиннер,
/// прошедшее время и последний шаг инициализации — по скриншоту уже можно
/// понять, где именно застряло приложение.
class StartupLoadingApp extends StatefulWidget {
  const StartupLoadingApp({
    super.key,
    this.backgroundColor = const Color(0xFF181306),
  });

  final Color backgroundColor;

  @override
  State<StartupLoadingApp> createState() => _StartupLoadingAppState();
}

class _StartupLoadingAppState extends State<StartupLoadingApp> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xFFE2D9C9);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: foreground,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: widget.backgroundColor,
      ),
      home: Scaffold(
        backgroundColor: widget.backgroundColor,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Запуск...',
                    style: TextStyle(
                      color: foreground,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${HangWatchdog.lastStep} · ${_elapsed.inSeconds} с',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (_elapsed.inSeconds >= 20) ...[
                    const SizedBox(height: 18),
                    const Text(
                      'Если так дольше минуты — сделайте скриншот этого экрана '
                      'и отправьте разработчику.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Корневое приложение на случай, если `bootstrap` упал до `runApp(App)`.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({
    super.key,
    required this.info,
    this.backgroundColor = const Color(0xFF181306),
  });

  final StartupFailureInfo info;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE2D9C9),
          brightness: Brightness.dark,
          error: const Color(0xFFFF8A80),
        ),
        scaffoldBackgroundColor: backgroundColor,
      ),
      home: StartupFailurePane(
        info: info,
        backgroundColor: backgroundColor,
      ),
    );
  }
}