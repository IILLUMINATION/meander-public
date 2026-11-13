import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:mnd_player/utils/platform_performance.dart';

/// Стеклянная поверхность: тон + (опционально) `BackdropFilter`.
///
/// Гейт блюра спрашивается один раз на состояние, а не на каждый `build`:
/// новый `Future` в `build` давал лишний кадр в промежуточном состоянии и
/// мигание «блюр → без блюра» при каждой перестройке родителя.
class GlassSurface extends StatefulWidget {
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final double blurSigma;
  final Color tintColor;
  final Color borderColor;
  final List<BoxShadow> shadows;
  final bool enableBlur;

  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 16,
    this.padding = const EdgeInsets.all(0),
    this.blurSigma = 6,
    this.tintColor = const Color(0x1AFFFFFF),
    this.borderColor = const Color(0x33FFFFFF),
    this.shadows = const [],
    this.enableBlur = true,
  });

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<GlassSurface> {
  late final Future<bool> _disableBlur = PlatformPerformance.instance
      .shouldDisableBlur();

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(widget.radius);

    return RepaintBoundary(
      child: FutureBuilder<bool>(
        future: _disableBlur,
        // Пока ответа нет — рисуем без блюра. Обратный дефолт (`false`) держал
        // `BackdropFilter` на первом кадре, то есть включал самый дорогой
        // эффект в тот момент, когда он точно не нужен.
        initialData: true,
        builder: (context, snapshot) {
          final shouldDisableBlur = snapshot.data ?? true;
          final effectiveBlur = (widget.enableBlur && !shouldDisableBlur)
              ? widget.blurSigma
              : 0.0;

          // Если blur отключен, используем более непрозрачный фон
          final effectiveTint = effectiveBlur == 0.0
              ? widget.tintColor.withValues(
                  alpha: (widget.tintColor.a * 2).clamp(0.0, 1.0),
                )
              : widget.tintColor;

          return Container(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              boxShadow: effectiveBlur > 0 ? widget.shadows : [],
            ),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: effectiveBlur > 0
                  ? BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: effectiveBlur,
                        sigmaY: effectiveBlur,
                      ),
                      child: _buildContent(effectiveTint, borderRadius),
                    )
                  : _buildContent(effectiveTint, borderRadius),
            ),
          );
        },
      ),
    );
  }

  Widget _buildContent(Color tint, BorderRadius borderRadius) {
    return Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: borderRadius,
        border: Border.all(color: widget.borderColor),
      ),
      child: widget.child,
    );
  }
}
