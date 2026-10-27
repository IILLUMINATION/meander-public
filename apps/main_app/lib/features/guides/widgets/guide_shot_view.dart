import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/guide.dart';

/// Один шаг гайда: схема экрана, стрелки и подпись.
///
/// Стрелки живут поверх «скриншота» и двигаются по кривой; схема остаётся
/// статичной. Это дешёвая интерактивность: человек листает шаги, видит
/// направление движения и читает подпись под картинкой.
class GuideShotView extends StatefulWidget {
  final GuideShot shot;
  final Color accent;
  final int stepIndex;
  final int stepCount;

  /// Экран гайда показывает подпись шага отдельной панелью: так высота
  /// карусели не зависит от длины текста и не прыгает при листании.
  final bool showCaption;

  const GuideShotView({
    super.key,
    required this.shot,
    required this.accent,
    required this.stepIndex,
    required this.stepCount,
    this.showCaption = true,
  });

  @override
  State<GuideShotView> createState() => _GuideShotViewState();
}

class _GuideShotViewState extends State<GuideShotView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _flow.stop();
      _flow.value = 0;
    } else if (!_flow.isAnimating) {
      _flow.repeat();
    }
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shot = widget.shot;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    GuideShotSkeleton(
                      kind: shot.kind,
                      accent: widget.accent,
                    ),
                    if (shot.imageAsset != null)
                      Image.asset(
                        shot.imageAsset!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    AnimatedBuilder(
                      animation: _flow,
                      builder: (context, _) => CustomPaint(
                        painter: _ShotOverlayPainter(
                          shot: shot,
                          accent: widget.accent,
                          progress: _flow.value,
                        ),
                      ),
                    ),
                    ..._labels(context, size),
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${widget.stepIndex + 1}/${widget.stepCount}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (widget.showCaption)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StepBadge(
                    number: widget.stepIndex + 1,
                    accent: widget.accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          shot.title,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          shot.caption,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _labels(BuildContext context, Size size) {
    final scheme = Theme.of(context).colorScheme;
    return [
      for (final label in widget.shot.labels)
        Positioned(
          left: label.at.dx * size.width,
          top: label.at.dy * size.height,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: size.width * 0.55),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  label.text,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
  }
}

class _StepBadge extends StatelessWidget {
  final int number;
  final Color accent;

  const _StepBadge({required this.number, required this.accent});

  @override
  Widget build(BuildContext context) {
    final foreground =
        ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        '$number',
        style: TextStyle(
          color: foreground,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Схема «скриншота»: узнаваемый каркас раздела без реального снимка.
/// Тема и размер экрана подставляются сами, поэтому подсказка не устаревает
/// после редизайна и не тащит в бандл десяток PNG под каждый язык.
class GuideShotSkeleton extends StatelessWidget {
  final GuideShotKind kind;
  final Color accent;

  const GuideShotSkeleton({
    super.key,
    required this.kind,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = Color.alphaBlend(
      accent.withValues(alpha: 0.05),
      scheme.surfaceContainerLow,
    );
    return ColoredBox(
      color: background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          Positioned box(
            double x,
            double y,
            double width,
            double height, {
            Color? color,
            double radius = 6,
            Widget? child,
            Border? border,
          }) {
            return Positioned(
              left: x * w,
              top: y * h,
              width: width * w,
              height: height * h,
              child: Container(
                decoration: BoxDecoration(
                  color: color ?? scheme.onSurface.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(radius),
                  border: border,
                ),
                child: child,
              ),
            );
          }

          Widget bar(
            double x,
            double y,
            double width,
            double height, {
            double alpha = 0.14,
            double radius = 3,
          }) {
            return box(
              x,
              y,
              width,
              height,
              color: scheme.onSurface.withValues(alpha: alpha),
              radius: radius,
            );
          }

          final children = <Widget>[
            // Общая шапка приложения.
            bar(0.04, 0.04, 0.26, 0.035, alpha: 0.22),
            bar(0.86, 0.04, 0.04, 0.035, alpha: 0.12),
            bar(0.92, 0.04, 0.04, 0.035, alpha: 0.12),
            bar(0.04, 0.09, 0.92, 0.006, alpha: 0.08),
          ];

          switch (kind) {
            case GuideShotKind.quests:
              children.addAll(_quests(box, bar));
              break;
            case GuideShotKind.editor:
              children.addAll(_editor(box, bar, scheme));
              break;
            case GuideShotKind.node:
              children.addAll(_node(box, bar));
              break;
            case GuideShotKind.links:
              children.addAll(_links(box, bar, scheme));
              break;
            case GuideShotKind.publish:
              children.addAll(_publish(box, bar, scheme, accent));
              break;
            case GuideShotKind.market:
              children.addAll(_market(box, bar, scheme, accent));
              break;
            case GuideShotKind.hub:
              children.addAll(_hub(box, bar, scheme, accent));
              break;
            case GuideShotKind.library:
              children.addAll(_library(box, bar, scheme));
              break;
          }

          return Stack(children: children);
        },
      ),
    );
  }

  List<Widget> _quests(
    Positioned Function(
      double,
      double,
      double,
      double, {
      Color? color,
      double radius,
      Widget? child,
      Border? border,
    })
    box,
    Widget Function(
      double,
      double,
      double,
      double, {
      double alpha,
      double radius,
    })
    bar,
  ) {
    return [
      bar(0.04, 0.15, 0.48, 0.055, alpha: 0.24),
      bar(0.04, 0.22, 0.30, 0.028, alpha: 0.10),
      box(0.04, 0.29, 0.13, 0.055, radius: 999),
      box(0.19, 0.29, 0.13, 0.055, radius: 999),
      for (var i = 0; i < 3; i++)
        box(
          0.04,
          0.39 + i * 0.18,
          0.66,
          0.15,
          color: Colors.white.withValues(alpha: 0.35),
          radius: 10,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        height: 5,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: 4,
                        width: 70,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      box(
        0.72,
        0.78,
        0.24,
        0.12,
        color: accent,
        radius: 14,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, size: 16, color: _on(accent)),
              const SizedBox(width: 5),
              Flexible(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: _on(accent).withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _editor(
    Positioned Function(
      double,
      double,
      double,
      double, {
      Color? color,
      double radius,
      Widget? child,
      Border? border,
    })
    box,
    Widget Function(
      double,
      double,
      double,
      double, {
      double alpha,
      double radius,
    })
    bar,
    ColorScheme scheme,
  ) {
    return [
      for (var i = 0; i < 3; i++)
        box(
          0.04 + i * 0.12,
          0.14,
          0.10,
          0.04,
          color: i == 0
              ? scheme.primary.withValues(alpha: 0.25)
              : Colors.black.withValues(alpha: 0.06),
          radius: 999,
        ),
      box(
        0.03,
        0.21,
        0.25,
        0.72,
        color: Colors.black.withValues(alpha: 0.05),
        radius: 10,
      ),
      for (var i = 0; i < 4; i++)
        box(
          0.05,
          0.25 + i * 0.13,
          0.21,
          0.09,
          color: i == 1
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.black.withValues(alpha: 0.06),
          radius: 6,
        ),
      box(
        0.30,
        0.21,
        0.66,
        0.72,
        color: Colors.white.withValues(alpha: 0.28),
        radius: 10,
      ),
      // Три карточки-ноды на канвасе.
      box(
        0.35,
        0.31,
        0.16,
        0.13,
        color: scheme.primary.withValues(alpha: 0.30),
        radius: 8,
      ),
      box(
        0.56,
        0.27,
        0.16,
        0.13,
        color: Colors.white.withValues(alpha: 0.75),
        radius: 8,
      ),
      box(
        0.57,
        0.53,
        0.17,
        0.13,
        color: accent,
        radius: 8,
      ),
      for (var i = 0; i < 4; i++)
        box(
          0.33 + i * 0.16,
          0.86,
          0.12,
          0.05,
          color: Colors.black.withValues(alpha: 0.07),
          radius: 4,
        ),
      bar(0.33, 0.10, 0.30, 0.02, alpha: 0.08),
    ];
  }

  List<Widget> _node(
    Positioned Function(
      double,
      double,
      double,
      double, {
      Color? color,
      double radius,
      Widget? child,
      Border? border,
    })
    box,
    Widget Function(
      double,
      double,
      double,
      double, {
      double alpha,
      double radius,
    })
    bar,
  ) {
    return [
      bar(0.06, 0.16, 0.28, 0.045, alpha: 0.22),
      box(
        0.06,
        0.24,
        0.88,
        0.66,
        color: Colors.white.withValues(alpha: 0.30),
        radius: 12,
      ),
      bar(0.10, 0.29, 0.50, 0.035, alpha: 0.20),
      bar(0.10, 0.35, 0.78, 0.025, alpha: 0.10),
      bar(0.10, 0.40, 0.70, 0.025, alpha: 0.10),
      box(
        0.10,
        0.46,
        0.78,
        0.24,
        color: accent.withValues(alpha: 0.22),
        radius: 8,
      ),
      box(
        0.10,
        0.74,
        0.36,
        0.08,
        color: accent.withValues(alpha: 0.85),
        radius: 999,
      ),
      box(
        0.50,
        0.74,
        0.36,
        0.08,
        color: Colors.black.withValues(alpha: 0.08),
        radius: 999,
      ),
    ];
  }

  List<Widget> _links(
    Positioned Function(
      double,
      double,
      double,
      double, {
      Color? color,
      double radius,
      Widget? child,
      Border? border,
    })
    box,
    Widget Function(
      double,
      double,
      double,
      double, {
      double alpha,
      double radius,
    })
    bar,
    ColorScheme scheme,
  ) {
    const points = <Offset>[
      Offset(0.12, 0.58),
      Offset(0.38, 0.32),
      Offset(0.66, 0.56),
      Offset(0.82, 0.24),
    ];
    return [
      bar(0.06, 0.15, 0.30, 0.045, alpha: 0.22),
      Positioned.fill(
        child: CustomPaint(
          painter: _LinkLinesPainter(
            points: points,
            color: scheme.primary.withValues(alpha: 0.45),
          ),
        ),
      ),
      box(
        0.05,
        0.49,
        0.17,
        0.16,
        color: scheme.primary.withValues(alpha: 0.25),
        radius: 8,
      ),
      box(
        0.31,
        0.23,
        0.17,
        0.16,
        color: Colors.white.withValues(alpha: 0.75),
        radius: 8,
      ),
      box(
        0.58,
        0.47,
        0.17,
        0.16,
        color: accent,
        radius: 8,
      ),
      box(
        0.74,
        0.15,
        0.17,
        0.16,
        color: Colors.white.withValues(alpha: 0.75),
        radius: 8,
      ),
      bar(0.06, 0.86, 0.40, 0.03, alpha: 0.08),
    ];
  }

  List<Widget> _publish(
    Positioned Function(
      double,
      double,
      double,
      double, {
      Color? color,
      double radius,
      Widget? child,
      Border? border,
    })
    box,
    Widget Function(
      double,
      double,
      double,
      double, {
      double alpha,
      double radius,
    })
    bar,
    ColorScheme scheme,
    Color accent,
  ) {
    return [
      for (var i = 0; i < 3; i++)
        bar(0.06, 0.16 + i * 0.10, 0.55 - i * 0.08, 0.035, alpha: 0.10),
      box(
        0.03,
        0.54,
        0.94,
        0.42,
        color: Colors.white.withValues(alpha: 0.88),
        radius: 16,
      ),
      bar(0.08, 0.59, 0.36, 0.045, alpha: 0.25),
      for (var i = 0; i < 3; i++)
        box(
          0.08,
          0.66 + i * 0.055,
          0.84,
          0.032,
          color: Colors.black.withValues(alpha: 0.06),
          radius: 4,
        ),
      box(
        0.08,
        0.82,
        0.84,
        0.10,
        color: accent,
        radius: 12,
        child: Center(
          child: Container(
            width: 86,
            height: 5,
            decoration: BoxDecoration(
              color: _on(accent).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
      box(
        0.80,
        0.06,
        0.08,
        0.04,
        color: scheme.error.withValues(alpha: 0.35),
        radius: 999,
      ),
    ];
  }

  List<Widget> _market(
    Positioned Function(
      double,
      double,
      double,
      double, {
      Color? color,
      double radius,
      Widget? child,
      Border? border,
    })
    box,
    Widget Function(
      double,
      double,
      double,
      double, {
      double alpha,
      double radius,
    })
    bar,
    ColorScheme scheme,
    Color accent,
  ) {
    return [
      bar(0.04, 0.15, 0.30, 0.045, alpha: 0.24),
      box(
        0.04,
        0.22,
        0.60,
        0.06,
        color: Colors.black.withValues(alpha: 0.06),
        radius: 999,
      ),
      box(0.78, 0.22, 0.18, 0.06, color: accent, radius: 999),
      for (var i = 0; i < 3; i++)
        box(
          0.04 + i * 0.32,
          0.33,
          0.28,
          0.28,
          color: Colors.white.withValues(alpha: i == 0 ? 0.9 : 0.55),
          radius: 12,
          border: i == 0
              ? Border.all(color: accent.withValues(alpha: 0.8), width: 2)
              : null,
        ),
      for (var i = 0; i < 2; i++)
        box(
          0.04,
          0.66 + i * 0.16,
          0.92,
          0.13,
          color: Colors.black.withValues(alpha: 0.055),
          radius: 10,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 5,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: 4,
                        width: 64,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 34,
                  height: 16,
                  decoration: BoxDecoration(
                    color: i == 0
                        ? accent.withValues(alpha: 0.85)
                        : scheme.tertiary.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  List<Widget> _hub(
    Positioned Function(
      double,
      double,
      double,
      double, {
      Color? color,
      double radius,
      Widget? child,
      Border? border,
    })
    box,
    Widget Function(
      double,
      double,
      double,
      double, {
      double alpha,
      double radius,
    })
    bar,
    ColorScheme scheme,
    Color accent,
  ) {
    return [
      bar(0.04, 0.15, 0.34, 0.045, alpha: 0.24),
      for (var i = 0; i < 3; i++)
        box(
          0.04 + i * 0.16,
          0.23,
          0.14,
          0.05,
          color: i == 0
              ? accent.withValues(alpha: 0.8)
              : Colors.black.withValues(alpha: 0.06),
          radius: 999,
        ),
      for (var i = 0; i < 4; i++)
        box(
          0.04 + (i % 2) * 0.47,
          0.33 + (i ~/ 2) * 0.30,
          0.45,
          0.26,
          color: Colors.white.withValues(alpha: 0.55),
          radius: 12,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
                const Spacer(),
                Container(
                  height: 4,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  height: 4,
                  width: 52,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  List<Widget> _library(
    Positioned Function(
      double,
      double,
      double,
      double, {
      Color? color,
      double radius,
      Widget? child,
      Border? border,
    })
    box,
    Widget Function(
      double,
      double,
      double,
      double, {
      double alpha,
      double radius,
    })
    bar,
    ColorScheme scheme,
  ) {
    return [
      bar(0.04, 0.15, 0.32, 0.045, alpha: 0.24),
      box(0.04, 0.23, 0.44, 0.05, color: Colors.black.withValues(alpha: 0.06)),
      box(0.52, 0.23, 0.18, 0.05, color: Colors.black.withValues(alpha: 0.03)),
      for (var i = 0; i < 4; i++)
        box(
          0.04 + i * 0.13,
          0.32,
          0.11,
          0.045,
          color: i == 0
              ? scheme.primary.withValues(alpha: 0.22)
              : Colors.black.withValues(alpha: 0.05),
          radius: 999,
        ),
      for (var i = 0; i < 6; i++)
        box(
          0.04 + (i % 3) * 0.32,
          0.42 + (i ~/ 3) * 0.28,
          0.29,
          0.24,
          color: Colors.white.withValues(alpha: 0.55),
          radius: 10,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  height: 4,
                  width: 50,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  Color _on(Color color) =>
      ThemeData.estimateBrightnessForColor(color) == Brightness.dark
      ? Colors.white
      : Colors.black87;
}

class _LinkLinesPainter extends CustomPainter {
  final List<Offset> points;
  final Color color;

  const _LinkLinesPainter({required this.points, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final start = Offset(points[0].dx * size.width, points[0].dy * size.height);
    path.moveTo(start.dx, start.dy);
    for (var i = 1; i < points.length; i++) {
      final point = Offset(
        points[i].dx * size.width,
        points[i].dy * size.height,
      );
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_LinkLinesPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}

class _ShotOverlayPainter extends CustomPainter {
  final GuideShot shot;
  final Color accent;
  final double progress;

  const _ShotOverlayPainter({
    required this.shot,
    required this.accent,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final focus = shot.focus;
    if (focus != null) {
      final rect = Rect.fromLTWH(
        focus.left * size.width,
        focus.top * size.height,
        focus.width * size.width,
        focus.height * size.height,
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
      final scrim = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(rrect),
      );
      canvas.drawPath(
        scrim,
        Paint()..color = Colors.black.withValues(alpha: 0.38),
      );
      canvas.drawRRect(
        rrect.inflate(4),
        Paint()
          ..color = accent.withValues(alpha: 0.18)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6,
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    for (final arrow in shot.arrows) {
      _paintArrow(canvas, size, arrow);
    }
  }

  void _paintArrow(Canvas canvas, Size size, GuideArrow arrow) {
    final from = Offset(arrow.from.dx * size.width, arrow.from.dy * size.height);
    final to = Offset(arrow.to.dx * size.width, arrow.to.dy * size.height);
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final control = Offset(
      (from.dx + to.dx) / 2 - dy * 0.16,
      (from.dy + to.dy) / 2 + dx * 0.16,
    );
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(control.dx, control.dy, to.dx, to.dy);

    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawCircle(
      from,
      4,
      Paint()..color = accent.withValues(alpha: 0.9),
    );

    final metric = path.computeMetrics().isEmpty
        ? null
        : path.computeMetrics().first;
    if (metric != null) {
      final tangent = metric.getTangentForOffset(metric.length * progress);
      if (tangent != null) {
        canvas.drawCircle(
          tangent.position,
          3.5,
          Paint()..color = Colors.white.withValues(alpha: 0.92),
        );
      }
      final end = metric.getTangentForOffset(metric.length);
      if (end != null) {
        _paintHead(canvas, to, end.vector);
      }
    }
  }

  void _paintHead(Canvas canvas, Offset tip, Offset direction) {
    final angle = math.atan2(direction.dy, direction.dx);
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(angle);
    final head = Path()
      ..moveTo(0, 0)
      ..lineTo(-9, -5)
      ..lineTo(-9, 5)
      ..close();
    canvas.drawPath(head, Paint()..color = accent);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShotOverlayPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.shot != shot ||
      oldDelegate.accent != accent;
}
