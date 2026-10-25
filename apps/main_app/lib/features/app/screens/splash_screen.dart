import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:canvas_app/core/services/version_check_service.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/features/shell/screens/menu_screen.dart';
import 'package:canvas_app/features/app/screens/onboarding_screen.dart';
import 'package:canvas_app/features/app/screens/policy_screen.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/app/screens/update_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _statusMessage = tr('Запуск...');
  final Random _random = Random();

  /// Минимальная длина сплэша.
  ///
  /// Было 2000 мс: на iPhone `getAppDirectory` + audio-сессия занимают
  /// порядка 300 мс, и остальное время человек смотрел на нарисованный
  /// логотип, который ничего не ждёт. 600 мс — чтобы логотип не мигнул
  /// кадром, но и не держал экран.
  static const int _minSplashMillis = 600;

  /// Показывать в debug-сборке окно обновления «насильно», не спрашивая
  /// сервер. Стояло включённым по умолчанию: в dev-сборке на iPhone поверх
  /// каждого запуска вставал UpdateScreen с пустой ссылкой. Включить, только
  /// когда нужно посмотреть сам экран.
  static const bool _debugForceUpdatePrompt = false;

  final List<String> _loadingMessages = [
    // Советы по meander
    tr('Совет: не стоит создавать много скриптов — можно обойтись кучей функций в одном скрипте'),
    // Интересные факты о текстовых квестах
    tr('Факт: первой текстовой игрой считается Colossal Cave Adventure (1976) — она была основана на реальной пещерной системе в Кентукки, которую исследовал автор игры'),
    tr('Факт: Zork (1977) стал одной из первых коммерчески успешных текстовых игр и породил движок Z-machine, который используется энтузиастами до сих пор'),
    tr('Факт: в 1980-х текстовые квесты нередко продавались с дополнительными физическими предметами в коробке — картами, письмами, монетами — которые были нужны для решения загадок'),
    tr('Факт: жанр текстовых квестов почти исчез в 90-х с приходом графических игр, но выжил благодаря энтузиастам и продолжает существовать в виде инди-сцены'),
    tr('Факт: с 1995 года ежегодно проводится IFComp — конкурс интерактивной прозы, в котором участвуют сотни авторов со всего мира'),
    tr('Факт: в классических парсерных играх движок обычно понимал от 200 до 300 глаголов-команд'),
    tr('Факт: «пустая комната» без уникального описания — один из главных признаков слабого левел-дизайна в текстовом квесте'),
    tr('Факт: в interactive fiction вся «графика» существует только в воображении игрока — жанр целиком держится на тексте и структуре повествования'),
    tr('Факт: ветвящийся сюжет в современных движках (Twine, Ink, Meander) часто визуализируют как граф узлов — это прямое развитие идей из ранних текстовых квестов'),
    tr('Факт: одна из главных проблем классических текстовых квестов — «проблема лабиринта»: игроки легко теряются в однотипных комнатах без визуальной карты'),
    tr('Факт: некоторые текстовые квесты 80-х были настолько сложными, что издатели прикладывали к коробке телефон горячей линии подсказок'),
    tr('Факт: жанр visual novel во многом вырос из текстовых квестов, добавив статичные иллюстрации и музыку к тексту'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startApp();
    });
  }

  String _getRandomMessage() {
    return _loadingMessages[_random.nextInt(_loadingMessages.length)];
  }

  Future<void> _startApp() async {
    final stopwatch = Stopwatch()..start();

    if (mounted) setState(() => _statusMessage = _getRandomMessage());
    await FileStorage.getAppDirectory();
    await _initAudio();

    if (stopwatch.elapsedMilliseconds < _minSplashMillis) {
      await Future.delayed(
        Duration(milliseconds: _minSplashMillis - stopwatch.elapsedMilliseconds),
      );
    }

    if (!mounted) return;

    // Корневой навигатор перехватываем здесь: он переживает замену сплэш-роута,
    // а `context` после await'ов ниже использовать нельзя.
    final rootNavigator = Navigator.of(context);
    final prefs = await SharedPreferences.getInstance();

    final packageInfo = await PackageInfo.fromPlatform();
    final currentAppVersion =
        '${packageInfo.version}+${packageInfo.buildNumber}';
    await prefs.setString('app_version', currentAppVersion);

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      // Проверка версии не должна держать первый экран: запрос ждёт ответа до
      // 8 секунд, и на слабой сети человек висел бы на сплэше. Окно обновления
      // догонит уже открытый экран.
      unawaited(_showUpdateIfAny(rootNavigator));
    }

    final policyAccepted = prefs.getBool('policy_accepted') ?? false;

    if (!policyAccepted) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => PolicyScreen()),
        );
        Future.delayed(const Duration(milliseconds: 350), () {
          DeepLinkService().signalReady();
        });
      }
      return;
    }

    final hasCompletedOnboarding =
        prefs.getBool('has_completed_onboarding') ?? false;

    if (!hasCompletedOnboarding) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => OnboardingScreen()),
        );
        Future.delayed(const Duration(milliseconds: 350), () {
          DeepLinkService().signalReady();
        });
      }
      return;
    }

    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => MenuScreen(),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 800),
        ),
      );
      Future.delayed(const Duration(milliseconds: 350), () {
        DeepLinkService().signalReady();
      });
    }
  }

  /// Проверка новой версии и показ окна обновления. Отдельно от `_startApp`,
  /// чтобы сетевой запрос не блокировал переход на первый экран.
  Future<void> _showUpdateIfAny(NavigatorState rootNavigator) async {
    if (kDebugMode && !_debugForceUpdatePrompt) return;
    final updateResult = kDebugMode
        ? VersionCheckResult(
            hasUpdate: true,
            isCritical: false,
            latestVersion: '99.0.0',
            latestBuild: 999,
            changelog:
                tr('• Новый дизайн окна обновления\n• Исправлен pinch-to-zoom на канвасе\n• Исправлено выделение текста в редакторе\n• Плеер квестов вынесен в отдельный модуль\n• Добавлен template_quest_app для сборки standalone квестов'),
            downloadUrl: '',
          )
        : await VersionCheckService.check();
    if (!updateResult.hasUpdate) return;
    // Сплэш к этому моменту уже заменён первым экраном, поэтому ориентируемся
    // не на себя, а на живость корневого навигатора.
    if (!rootNavigator.mounted) return;
    rootNavigator.push(
      MaterialPageRoute(
        builder: (_) => UpdateScreen(
          version: updateResult.latestVersion,
          changelog: updateResult.changelog,
          downloadUrl: updateResult.downloadUrl,
          isCritical: updateResult.isCritical,
        ),
      ),
    );
  }

  Future<void> _initAudio() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedLogo(
                  nodeColor: scheme.primary,
                  lineColor: scheme.outlineVariant,
                  shadowColor: scheme.shadow.withOpacity(0.28),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AnimatedLogo extends StatefulWidget {
  final Color nodeColor;
  final Color lineColor;
  final Color shadowColor;
  const AnimatedLogo({
    super.key,
    required this.nodeColor,
    required this.lineColor,
    required this.shadowColor,
  });
  @override
  State<AnimatedLogo> createState() => _AnimatedLogoState();
}

class _AnimatedLogoState extends State<AnimatedLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 4000),
      vsync: this,
    )..repeat();
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => CustomPaint(
        size: const Size(250, 250),
        painter: AnimatedLogoPainter(
          _animation.value,
          nodeColor: widget.nodeColor,
          lineColor: widget.lineColor,
          shadowColor: widget.shadowColor,
        ),
      ),
    );
  }
}

class AnimatedLogoPainter extends CustomPainter {
  final double progress;
  final Color nodeColor;
  final Color lineColor;
  final Color shadowColor;
  AnimatedLogoPainter(
    this.progress, {
    required this.nodeColor,
    required this.lineColor,
    required this.shadowColor,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    double m;
    if (progress < 0.3) {
      m = progress / 0.3;
    } else if (progress < 0.5) {
      m = 1.0;
    } else if (progress < 0.8) {
      m = 1.0 - (progress - 0.5) / 0.3;
    } else {
      m = 0.0;
    }
    final mc = Curves.easeInOutCubic.transform(m);
    final ns = size.width * 0.26, d = size.width * 0.28;
    final tn = Offset(center.dx, center.dy - d),
        bln = Offset(center.dx - d * 0.866, center.dy + d * 0.5),
        brn = Offset(center.dx + d * 0.866, center.dy + d * 0.5);
    final ctn = Offset.lerp(tn, center, mc)!,
        cbln = Offset.lerp(bln, center, mc)!,
        cbrn = Offset.lerp(brn, center, mc)!;
    final cns = ns + (ns * 0.8) * mc;
    double ps = 1.0;
    if (progress >= 0.3 && progress <= 0.5) {
      ps = 1.0 + math.sin((progress - 0.3) / 0.2 * math.pi) * 0.05;
    }
    final lo = (1.0 - mc).clamp(0.0, 1.0);
    if (lo > 0.0) {
      final lp = Paint()
        ..color = lineColor.withOpacity(lo)
        ..strokeWidth = size.width * 0.055
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.butt;
      final g = cns * 0.5 + size.width * 0.045;
      void drawEdge(Offset p1, Offset p2) {
        final v = p2 - p1;
        final dist = v.distance;
        if (dist <= 0.001) return;
        // Inset each endpoint by `g`, but clamp so the line never
        // overshoots past the midpoint when the nodes collapse together.
        final t = math.min(g, dist / 2) / dist;
        canvas.drawLine(p1 + v * t, p2 - v * t, lp);
      }

      drawEdge(ctn, cbln);
      drawEdge(ctn, cbrn);
      drawEdge(cbln, cbrn);
    }
    void drawNode(Canvas c, Offset nc, double s) {
      final a = s * ps, r = a * 0.45;
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: nc, width: a, height: a),
        Radius.circular(r),
      );
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(nc.dx + 1, nc.dy + 2),
            width: a,
            height: a,
          ),
          Radius.circular(r),
        ),
        Paint()
          ..color = shadowColor
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * ps),
      );
      c.drawRRect(rect, Paint()..color = nodeColor);
    }

    drawNode(canvas, ctn, cns);
    drawNode(canvas, cbln, cns);
    drawNode(canvas, cbrn, cns);
  }

  @override
  bool shouldRepaint(covariant AnimatedLogoPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.nodeColor != nodeColor ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.shadowColor != shadowColor;
}
