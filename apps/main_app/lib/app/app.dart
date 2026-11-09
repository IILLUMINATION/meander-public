import 'package:canvas_app/app/app_scroll_behavior.dart';
import 'package:canvas_app/core/l10n/app_localizations.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/l10n/l10n_provider.dart';
import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:canvas_app/core/services/app_screenshot.dart';
import 'package:canvas_app/core/theme/app_theme.dart';
import 'package:canvas_app/core/theme/init_provider.dart';
import 'package:canvas_app/core/theme/theme_preset_provider.dart';
import 'package:canvas_app/core/theme/theme_provider.dart';
import 'package:canvas_app/core/services/playtime_service.dart';
import 'package:canvas_app/core/services/streak_service.dart';
import 'package:canvas_app/features/app/screens/splash_screen.dart';
import 'package:canvas_app/features/onboarding/widgets/tutorial_host.dart';
import 'package:canvas_app/plugin_host/plugin_host_runner.dart';
import 'package:canvas_app/shared/widgets/desktop_navigation_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  @override
  void initState() {
    super.initState();
    // Снимок экрана по Ctrl+Shift+S — только когда задан MND_SCREENSHOT_DIR.
    AppScreenshot.install();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(playtimeServiceProvider).init();
      ref.read(streakServiceProvider).checkAndUpdateStreak();
    });
  }

  @override
  void dispose() {
    AppScreenshot.uninstall();
    ref.read(playtimeServiceProvider).dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(initThemeProvider);

    final themeMode = ref.watch(themeModeProvider);
    final preset = ref.watch(themePresetProvider).active;
    final language = ref.watch(appLanguageProvider);

    final lightTheme = AppTheme.fromPreset(preset, Brightness.light);
    final darkTheme = AppTheme.fromPreset(preset, Brightness.dark);

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Meander',
      debugShowCheckedModeBanner: false,
      // Язык интерфейса: `tr()` берёт строки из L10n, а locale нужен
      // виджетам Material (даты, подсказки, направление текста).
      // `materialLocale`, а не сам код: импортированный язык Material может
      // не знать, и тогда обвеска падает с «No MaterialLocalizations found».
      locale: language.materialLocale,
      supportedLocales: [
        for (final item in L10n.supported) item.materialLocale
      ],
      localizationsDelegates: appLocalizationsDelegates,
      scrollBehavior: AppScrollBehavior(),
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      navigatorObservers: [],
      builder: (context, child) => RepaintBoundary(
        key: AppScreenshot.boundaryKey,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => ref.read(playtimeServiceProvider).registerInteraction(),
          child: MouseRegion(
            onHover: (_) => ref.read(playtimeServiceProvider).registerInteraction(),
            child: PluginHostRunner(
              child: DesktopNavigationWrapper(
                child: TutorialHost(child: child ?? const SizedBox.shrink()),
              ),
            ),
          ),
        ),
      ),
      home: SplashScreen(),
    );
  }
}
