import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_painters.dart';

// ============================================================================
//  Виджеты косметики
//
//  Всё, что видно на профиле, собирается из четырёх кубиков: обложка, рамка
//  аватара, ник и слой частиц. Каждый умеет рисоваться и «живьём» (с тикером),
//  и статично — статичный режим нужен для превью в витрине, для строк списка
//  (тикер на каждую строку обошёлся бы дорого) и для widget-тестов.
// ============================================================================

/// Тикер одной анимированной поверхности.
class _CosmeticTicker extends StatefulWidget {
  const _CosmeticTicker({required this.animate, required this.builder});

  final bool animate;
  final Widget Function(BuildContext context, double t) builder;

  @override
  State<_CosmeticTicker> createState() => _CosmeticTickerState();
}

class _CosmeticTickerState extends State<_CosmeticTicker>
    with SingleTickerProviderStateMixin {
  static const _cycle = Duration(seconds: 600);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _cycle,
  );
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(_CosmeticTicker old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final shouldRun = widget.animate && _visible;
    if (shouldRun && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldRun && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) return widget.builder(context, 0);
    return VisibilityDetector(
      // Шапка профиля уезжает за экран при прокрутке — тикер должен
      // останавливаться, иначе список квестов жрёт батарею ради невидимого
      // снега.
      key: ValueKey('cosmetic-ticker-${identityHashCode(this)}'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        _visible = info.visibleFraction > 0.01;
        _sync();
      },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) =>
            widget.builder(context, _controller.value * _cycle.inSeconds),
      ),
    );
  }
}

/// Уважает системное «меньше движения»: анимации выключаются, косметика
/// остаётся видимой статичным кадром.
bool cosmeticMotionAllowed(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations != true;

/// Кадр арт-обложки: живой зацикленный WebP, когда движение разрешено,
/// иначе — статичная картинка. Вынесено из виджета, чтобы ветку можно было
/// проверить без реального декодирования анимации (она оставляет таймеры).
String? artImageFor(BannerSpec spec, {required bool animate}) =>
    animate && spec.animatedImage != null ? spec.animatedImage : spec.image;

/// Цвет ника для вставки внутрь предложения (`Text.rich`).
///
/// Градиент требует известных границ текста, а они появляются только после
/// вёрстки, поэтому в строках-фзах ник получает плоский цвет из стиля.
TextStyle? cosmeticNameInlineStyle(String? styleId) {
  final def = cosmeticById(styleId);
  final spec = def?.spec;
  if (spec is! NameSpec) return null;
  return TextStyle(color: spec.primary);
}

/// Обложка профиля: градиент/эффект из каталога под [child] и частицы поверх
/// фона, но под содержимым.
class CosmeticBanner extends StatelessWidget {
  const CosmeticBanner({
    super.key,
    required this.def,
    required this.height,
    required this.child,
    this.borderRadius = 24,
    this.fallbackGradient,
    this.forceStatic = false,
    this.overlayEffect,
    this.hitReserve = 0,
  });

  /// Предмет слота `banner`; `null` — обычная тема.
  final CosmeticDef? def;
  final double height;
  final Widget child;
  final double borderRadius;

  /// Что рисовать, если предмета нет (дефолт из темы вызывающего экрана).
  final Gradient? fallbackGradient;
  final bool forceStatic;

  /// Надетый эффект слота `effect`. Без него к некоторым обложкам включается
  /// парный эффект — см. [_companionEffect].
  final CosmeticDef? overlayEffect;

  /// Сколько пикселей снизу добавить боксу под свисающий аватар.
  ///
  /// Отрисовка Stack'а не обрезается, а вот тап проверяется по границам бокса:
  /// кнопка, нарисованная ниже обложки, выглядит кликабельной и не реагирует
  /// вообще. Резерв оставляет её внутри области попаданий, картинку обложки
  /// при этом не растягивает.
  final double hitReserve;

  @override
  Widget build(BuildContext context) {
    final animate = !forceStatic && cosmeticMotionAllowed(context);
    final spec = def?.spec as BannerSpec?;
    final effect = overlayEffect ?? _companionEffect(def);

    return SizedBox(
      height: height + hitReserve,
      width: double.infinity,
      child: Stack(
        // Аватар «выезжает» за нижний край обложки — обрезка съест его.
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius),
              child: _CosmeticTicker(
                animate: animate,
                builder: (context, t) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (spec != null && spec.isArt)
                        _ArtBanner(
                          spec: spec,
                          animate: animate,
                          t: t,
                          fallbackGradient: fallbackGradient,
                        )
                      else if (spec != null)
                        CustomPaint(
                          painter: CosmeticBannerPainter(
                            spec: spec,
                            t: t,
                            borderRadius: 0,
                          ),
                        )
                      else
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient:
                                fallbackGradient ?? _themeGradient(context),
                          ),
                        ),
                      if (effect != null)
                        Positioned.fill(
                          child: ParticleOverlay(
                            def: effect,
                            t: animate ? t : 0,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }

  static Gradient _themeGradient(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        scheme.primaryContainer,
        scheme.tertiaryContainer.withValues(alpha: 0.7),
      ],
    );
  }
}

/// Арт-обложка: живописный кадр вместо процедурного градиента.
///
/// Живой WebP (если он есть у предмета) крутится сам, без нашего тикера —
/// поэтому в этом случае не добавляем ещё и «камеру»: два движения сразу
/// читаются как дрожание. Остальные кадры медленно дышат масштабом, как
/// заставка Apple TV.
class _ArtBanner extends StatelessWidget {
  const _ArtBanner({
    required this.spec,
    required this.animate,
    required this.t,
    this.fallbackGradient,
  });

  final BannerSpec spec;
  final bool animate;
  final double t;
  final Gradient? fallbackGradient;

  /// Период «дыхания камеры»: заметно, но не отвлекает.
  static const double _period = 48;

  @override
  Widget build(BuildContext context) {
    final asset = artImageFor(spec, animate: animate);
    final loop = animate && spec.animatedImage != null;
    final drift = animate && !loop && spec.motion != BannerMotion.still;
    final phase = drift ? math.sin(t * 2 * math.pi / _period) : 0.0;
    final scale = drift ? 1.045 + 0.025 * phase : 1.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(
          scale: scale,
          child: Image.asset(
            asset!,
            fit: BoxFit.cover,
            alignment: spec.imageAlignment,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => DecoratedBox(
              decoration: BoxDecoration(
                gradient: fallbackGradient ?? CosmeticBanner._themeGradient(context),
              ),
            ),
          ),
        ),
        // Затемнение по краям: белые иконки и бейдж поверх любого кадра
        // должны читаться, а сам кадр — оставаться кадром.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.30),
                Colors.transparent,
                Colors.transparent,
                Colors.black.withValues(alpha: 0.26),
              ],
              stops: const [0, 0.34, 0.62, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// Фон всей страницы профиля: тот же арт, но приглушённый темой.
///
/// [preview] — для витрины: там картинка должна быть видна целиком, а не
/// растворяться под текстом, которого в превью нет.
class CosmeticBackground extends StatelessWidget {
  const CosmeticBackground({super.key, required this.def, this.preview = false});

  final CosmeticDef? def;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final spec = def?.spec is BackgroundSpec ? def!.spec as BackgroundSpec : null;
    if (spec == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final dim = preview ? 0.18 : spec.dim.clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          spec.image,
          fit: BoxFit.cover,
          alignment: spec.alignment,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) =>
              ColoredBox(color: scheme.surface),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                scheme.surface.withValues(alpha: (dim - 0.22).clamp(0.0, 1.0)),
                scheme.surface.withValues(alpha: dim),
                scheme.surface.withValues(alpha: (dim + 0.08).clamp(0.0, 1.0)),
              ],
              stops: const [0, 0.55, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// Эффект «идёт в паре» с обложкой: снегопад к морозному стеклу выглядит
/// задуманным, а не случайным. Применяется только когда свой эффект не надет.
CosmeticDef? _companionEffect(CosmeticDef? banner) {
  if (banner == null) return null;
  final companion = switch (banner.id) {
    'frost_panel' => 'snowfall',
    'starfield' => 'stardust',
    'lava_flow' => 'campfire_embers',
    _ => null,
  };
  return cosmeticById(companion);
}

/// Частицы поверх чего угодно. Отдельный виджет — слой можно включить и на
/// весь экран, не трогая обложку.
class ParticleOverlay extends StatelessWidget {
  const ParticleOverlay({
    super.key,
    required this.def,
    this.t = 0,
    this.animate,
  });

  final CosmeticDef def;

  /// Готовое время: когда слой внутри общего тикера обложки.
  final double t;

  /// `null` — завести собственный тикер (для превью и изолированного слоя).
  final bool? animate;

  @override
  Widget build(BuildContext context) {
    final spec = def.spec as EffectSpec;
    if (animate != null) {
      final on = animate! && cosmeticMotionAllowed(context);
      return _CosmeticTicker(
        animate: on,
        builder: (context, time) => CustomPaint(
          painter: ParticleFieldPainter(spec: spec, t: time),
        ),
      );
    }
    return CustomPaint(painter: ParticleFieldPainter(spec: spec, t: t));
  }
}

/// На сколько надетая рамка увеличивает габарит аватара с каждой стороны.
///
/// Кольцо и свечение рисуются снаружи круга, поэтому `radius` — это не размер
/// плитки: с рамкой аватар становится шире на [avatarFrameOutset]*2. Вызывающий
/// код с фиксированной высотой (ленты, карточки) обязан это учесть, иначе
/// косметика платного пользователя разорвёт его ряд.
double avatarFrameOutset(CosmeticDef? frame) {
  final spec = frame?.spec is FrameSpec ? frame!.spec as FrameSpec : null;
  if (spec == null) return 0;
  return spec.width + spec.glow * 6;
}

/// Аватар с рамкой из каталога.
class CosmeticAvatar extends StatelessWidget {
  const CosmeticAvatar({
    super.key,
    required this.frame,
    required this.radius,
    this.avatarUrl,
    this.placeholderColor,
    this.forceStatic = false,
    this.fallback,
  });

  final CosmeticDef? frame;
  final double radius;
  final String? avatarUrl;
  final Color? placeholderColor;
  final bool forceStatic;

  /// Что рисовать вместо фото: по умолчанию силуэт, в комментариях — инициалы.
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Предмет мог прийти из чужого слота (строка с проката), а падать из-за
    // этого whole лента — худший из вариантов.
    final spec = frame?.spec is FrameSpec ? frame!.spec as FrameSpec : null;
    final animate =
        spec != null && !forceStatic && cosmeticMotionAllowed(context);
    // Кольцо рисуется с внешней стороны, поэтому аватару нужно место под свечение.
    final pad = avatarFrameOutset(frame);

    return SizedBox(
      width: (radius + pad) * 2,
      height: (radius + pad) * 2,
      child: _CosmeticTicker(
        animate: animate,
        builder: (context, t) {
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: spec == null
                      ? null
                      : AvatarFramePainter(
                          spec: spec,
                          t: t,
                          outerRadius: radius + pad,
                        ),
                ),
              ),
              Container(
                width: radius * 2,
                height: radius * 2,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: placeholderColor ?? scheme.surface,
                  shape: BoxShape.circle,
                ),
                child: _AvatarFace(
                  radius: radius - 3,
                  avatarUrl: avatarUrl,
                  fallback: fallback ??
                      Icon(
                        Icons.person_rounded,
                        size: radius,
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AvatarFace extends StatelessWidget {
  const _AvatarFace({
    required this.radius,
    required this.avatarUrl,
    required this.fallback,
  });

  final double radius;
  final String? avatarUrl;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final url = avatarUrl;
    if (url == null || url.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: fallback,
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      backgroundImage: CachedNetworkImageProvider(url),
    );
  }
}

/// Ник с косметикой.
///
/// [hero] == true — анимированный градиент (шапка профиля). В списках hero
/// выключен: там сотни строк, и вместо шейдера достаточно основного цвета
/// предмета — иначе прокрутка ленты начнёт жечь тикеры на каждом авторе.
class CosmeticNameText extends StatelessWidget {
  const CosmeticNameText({
    super.key,
    required this.name,
    required this.def,
    this.style,
    this.hero = false,
    this.animate = true,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
  });

  final String name;
  final CosmeticDef? def;
  final TextStyle? style;
  final bool hero;

  /// false — статичный кадр (превью в витрине: там карточек много).
  final bool animate;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final spec = def?.spec is NameSpec ? def!.spec as NameSpec : null;
    if (spec == null) {
      return Text(
        name,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
        style: style,
      );
    }

    final text = Text(
      name,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      style: hero
          ? (style ?? const TextStyle()).copyWith(color: Colors.white)
          : (style ?? const TextStyle()).copyWith(color: spec.primary),
    );

    if (!hero) return text;

    return _CosmeticTicker(
      animate:
          animate &&
          cosmeticMotionAllowed(context) &&
          spec.motion != NameMotion.flat,
      builder: (context, t) {
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => _nameShader(spec, bounds, t),
          child: text,
        );
      },
    );
  }

  static ui.Shader _nameShader(NameSpec spec, Rect bounds, double t) {
    final angle = switch (spec.motion) {
      NameMotion.hue => t * 1.2,
      NameMotion.shimmer => math.pi * 0.25 * math.sin(t * 0.9),
      NameMotion.flat => 0.0,
    };
    return LinearGradient(
      colors: spec.colors,
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      transform: GradientRotation(angle),
    ).createShader(bounds);
  }
}

/// Превью предмета для витрины: тот же рендерер, что и на реальном профиле,
/// только в рамке 96×64 и без анимации.
class CosmeticPreview extends StatelessWidget {
  const CosmeticPreview({super.key, required this.def, this.height = 64});

  final CosmeticDef def;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (def.slot) {
      case CosmeticSlot.banner:
        return CosmeticBanner(
          def: def,
          height: height,
          borderRadius: 12,
          forceStatic: true,
          child: const SizedBox.shrink(),
        );
      case CosmeticSlot.effect:
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: height,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [scheme.surfaceContainerHigh, scheme.surfaceContainer],
              ),
            ),
            child: ParticleOverlay(def: def, animate: false),
          ),
        );
      case CosmeticSlot.background:
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: height,
            child: CosmeticBackground(def: def, preview: true),
          ),
        );
      case CosmeticSlot.avatarFrame:
        return SizedBox(
          height: height,
          child: Center(
            child: CosmeticAvatar(
              frame: def,
              radius: (height - 22) / 2,
              forceStatic: true,
            ),
          ),
        );
      case CosmeticSlot.nameStyle:
        return SizedBox(
          height: height,
          child: Center(
            child: CosmeticNameText(
              name: def.name,
              def: def,
              hero: true,
              animate: false,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: scheme.onSurface,
              ),
            ),
          ),
        );
    }
  }
}
