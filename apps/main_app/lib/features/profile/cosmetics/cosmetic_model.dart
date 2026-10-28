import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/theme/banner_presets.dart';

/// Слот оформления: ровно один предмет может быть надет в каждом слоте.
enum CosmeticSlot {
  banner('banner'),
  background('background'),
  avatarFrame('avatar_frame'),
  nameStyle('name_style'),
  effect('effect');

  const CosmeticSlot(this.wireName);

  /// Ключ в JSON (`profiles.cosmetics` на бэке и в запросах).
  final String wireName;

  /// Название слота человеку: в const-поле перевод не живёт, витрина — геттер.
  String get title => switch (this) {
    CosmeticSlot.banner => tr('Обложка'),
    CosmeticSlot.background => tr('Фон профиля'),
    CosmeticSlot.avatarFrame => tr('Рамка аватара'),
    CosmeticSlot.nameStyle => tr('Стиль ника'),
    CosmeticSlot.effect => tr('Эффект профиля'),
  };

  static CosmeticSlot? fromWire(String? name) {
    for (final slot in values) {
      if (slot.wireName == name) return slot;
    }
    return null;
  }
}

/// Редкость определяет, выдаётся ли предмет бесплатно или только правом.
///
/// [CosmeticTier.common] не проверяется на бэке — остальное требует записи в
/// `user_cosmetics`. Поэтому список правок здесь и whitelist на бэке обязаны
/// совпадать по id, иначе выдача «не сработает» без внятной ошибки.
enum CosmeticTier {
  common('common', 0),
  rare('rare', 1),
  epic('epic', 2),
  legendary('legendary', 3);

  const CosmeticTier(this.wireName, this.rank);

  final String wireName;
  final int rank;

  String get title => switch (this) {
    CosmeticTier.common => tr('Доступно всем'),
    CosmeticTier.rare => tr('Редкое'),
    CosmeticTier.epic => tr('Эпическое'),
    CosmeticTier.legendary => tr('Легендарное'),
  };
}

/// Как именно живёт обложка: чем рисуется и с какой скоростью дышит.
enum BannerMotion { still, drift, waves, ribbons, grid, starfield }

enum FrameMotion { conic, pulse, orbit, shine, glitch, dashed }

enum NameMotion { flat, shimmer, hue }

enum ParticleKind {
  snow,
  ember,

  /// Разлёт пачками из точек-взрывов: у частиц нет своей траектории, они
  /// привязаны к «залпу», поэтому считаются отдельно от [ember].
  burst,
  stardust,
  firefly,
  coin,
  petal,
  heart,
  confetti,
  rain,
}

@immutable
class BannerSpec {
  const BannerSpec({
    required this.colors,
    this.motion = BannerMotion.drift,
    this.speed = 1,
    this.accentIcon,
    this.image,
    this.animatedImage,
    this.imageAlignment = Alignment.center,
  });

  final List<Color> colors;
  final BannerMotion motion;

  /// Множитель скорости анимации. 0 == статичная картинка.
  final double speed;
  final IconData? accentIcon;

  /// Арт-обложка из бандла: холст/пейзаж вместо процедурного градиента.
  /// В этом случае [colors] — запасной фон, пока картинка не загрузилась.
  final String? image;

  /// Зацикленный WebP (этот же кадр, но живой). Показывается вместо [image],
  /// когда системе не запрещено движение; в превью всегда остаётся [image].
  final String? animatedImage;

  /// Что оставить в кадре при обрезке под нестандартное соотношение сторон.
  final Alignment imageAlignment;

  bool get isArt => image != null;
}

/// Фон страницы профиля: та же образность, что у арт-обложек, но под
/// содержимым. [dim] — насколько сильно тема перекрывает картинку: текст и
/// карточки должны читаться на любом кадре.
@immutable
class BackgroundSpec {
  const BackgroundSpec({
    required this.image,
    this.dim = 0.55,
    this.alignment = Alignment.topCenter,
  });

  final String image;
  final double dim;
  final Alignment alignment;
}

@immutable
class FrameSpec {
  const FrameSpec({
    required this.colors,
    this.motion = FrameMotion.conic,
    this.width = 4,
    this.glow = 0.5,
    this.speed = 1,
  });

  final List<Color> colors;
  final FrameMotion motion;
  final double width;

  /// 0..1 — насколько сильно свечение за кольцом.
  final double glow;
  final double speed;
}

@immutable
class NameSpec {
  const NameSpec({required this.colors, this.motion = NameMotion.shimmer});

  final List<Color> colors;
  final NameMotion motion;

  Color get primary => colors.first;
}

@immutable
class EffectSpec {
  const EffectSpec({
    required this.kind,
    required this.colors,
    this.count = 34,
    this.speed = 1,
  });

  final ParticleKind kind;
  final List<Color> colors;

  /// Число частиц на обложку. Держим небольшим: эффект видит каждый гость.
  final int count;
  final double speed;
}

/// Предмет каталога. [spec] — один из четырёх типов, по слоту.
@immutable
class CosmeticDef {
  const CosmeticDef({
    required this.id,
    required this.slot,
    required this.tier,
    required this.name,
    required this.spec,
    this.season,
  });

  final String id;
  final CosmeticSlot slot;
  final CosmeticTier tier;

  /// Название для витрины.
  final String name;
  final Object spec;

  /// Пометка сезона («new_year», «valentine») — для будущей витрины по датам.
  final String? season;

  BannerSpec get banner => spec as BannerSpec;
  BackgroundSpec get background => spec as BackgroundSpec;
  FrameSpec get frame => spec as FrameSpec;
  NameSpec get nameStyle => spec as NameSpec;
  EffectSpec get effect => spec as EffectSpec;

  bool get free => tier == CosmeticTier.common;
}

// ============================================================================
//  КАТАЛОГ
// ============================================================================

/// Статичные градиенты унаследованы от старых пресетов баннеров: их id уже
/// лежат в `profiles.banner_style` у пользователей, поэтому новые предметы не
/// должны их перекрывать.
final List<CosmeticDef> _legacyBanners = [
  for (final p in kBannerPresets)
    CosmeticDef(
      id: p.id,
      slot: CosmeticSlot.banner,
      tier: CosmeticTier.common,
      name: p.name,
      spec: BannerSpec(
        colors: p.colors,
        motion: BannerMotion.still,
        accentIcon: p.accentIcon,
      ),
    ),
];

/// Предметы каталога. id — контракт с бэком (`src/services/cosmetics.ts`):
/// выдача права по id, которого бэк не знает, обязан быть отвергнут, поэтому
/// каталог и whitelist правок надо менять вместе.
///
/// `_legacyBanners` идут первыми: их id уже живут в `profiles.banner_style`
/// у пользователей, и новый предмет не должен занять чужое место.
// Геттер, а не final-таблица: список строится под текущий язык, иначе
// переключение языка не перекрасило бы эти подписи.
List<CosmeticDef> get kCosmetics => [
  ..._legacyBanners,

  // — Арт-обложки —
  // Живописные кадры вместо абстракций: один и тот же арт можно повесить и
  // обложкой, и фоном страницы (см. слот background ниже). Все бесплатные —
  // это не награда, а базовый выбор внешнего вида.
  CosmeticDef(
    id: 'art_night_meadow',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.common,
    name: tr('Ночной луг'),
    spec: BannerSpec(
      colors: [Color(0xFF0B1B33), Color(0xFF3E6E9B)],
      image: 'assets/images/cosmetics/art_0.webp',
      // Тот же кадр, зацикленный в WebP: звёзды и светлячки двигаются.
      animatedImage: 'assets/images/cosmetics/art_0_loop.webp',
    ),
  ),
  CosmeticDef(
    id: 'art_golden_field',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.common,
    name: tr('Золотое поле'),
    spec: BannerSpec(
      colors: [Color(0xFF3B2C12), Color(0xFFD9A64B)],
      image: 'assets/images/cosmetics/art_1.webp',
    ),
  ),
  CosmeticDef(
    id: 'art_lone_tree',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.common,
    name: tr('Одинокое дерево'),
    spec: BannerSpec(
      colors: [Color(0xFF1E5E52), Color(0xFFB9E3A6)],
      image: 'assets/images/cosmetics/art_2.webp',
    ),
  ),
  CosmeticDef(
    id: 'art_forest_bridge',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.common,
    name: tr('Мост в лесу'),
    spec: BannerSpec(
      colors: [Color(0xFF16240F), Color(0xFF7FA24B)],
      image: 'assets/images/cosmetics/art_3.webp',
    ),
  ),
  CosmeticDef(
    id: 'art_pond_robot',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.common,
    name: tr('У пруда'),
    spec: BannerSpec(
      colors: [Color(0xFF1B2413), Color(0xFF9DBF4A)],
      image: 'assets/images/cosmetics/art_4.webp',
      imageAlignment: Alignment.center,
    ),
  ),
  CosmeticDef(
    id: 'art_open_road',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.common,
    name: tr('Дорога домой'),
    spec: BannerSpec(
      colors: [Color(0xFF2A3B3F), Color(0xFFD8C48A)],
      image: 'assets/images/cosmetics/art_5.webp',
    ),
  ),

  // — Фоны профиля —
  // Те же кадры, но как воздушная подложка всей страницы: тема перекрывает
  // их настолько, чтобы карточки и текст читались при любом выборе.
  CosmeticDef(
    id: 'bg_night_meadow',
    slot: CosmeticSlot.background,
    tier: CosmeticTier.common,
    name: tr('Ночная синева'),
    spec: BackgroundSpec(image: 'assets/images/cosmetics/art_0.webp'),
  ),
  CosmeticDef(
    id: 'bg_golden_field',
    slot: CosmeticSlot.background,
    tier: CosmeticTier.common,
    name: tr('Пшеничное утро'),
    spec: BackgroundSpec(image: 'assets/images/cosmetics/art_1.webp'),
  ),
  CosmeticDef(
    id: 'bg_lone_tree',
    slot: CosmeticSlot.background,
    tier: CosmeticTier.common,
    name: tr('Зелёный простор'),
    spec: BackgroundSpec(image: 'assets/images/cosmetics/art_2.webp'),
  ),
  CosmeticDef(
    id: 'bg_forest_bridge',
    slot: CosmeticSlot.background,
    tier: CosmeticTier.common,
    name: tr('Лесная тень'),
    spec: BackgroundSpec(image: 'assets/images/cosmetics/art_3.webp'),
  ),
  CosmeticDef(
    id: 'bg_pond_robot',
    slot: CosmeticSlot.background,
    tier: CosmeticTier.common,
    name: tr('Тихая заводь'),
    spec: BackgroundSpec(image: 'assets/images/cosmetics/art_4.webp'),
  ),
  CosmeticDef(
    id: 'bg_open_road',
    slot: CosmeticSlot.background,
    tier: CosmeticTier.common,
    name: tr('Дорожная дымка'),
    spec: BackgroundSpec(image: 'assets/images/cosmetics/art_5.webp'),
  ),

  // — Обложки —
  CosmeticDef(
    id: 'aurora_drift',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.rare,
    name: tr('Северное сияние'),
    spec: BannerSpec(
      colors: [Color(0xFF0B3B5C), Color(0xFF1CC8A8), Color(0xFF7B5CFF), Color(0xFF0B3B5C)],
      motion: BannerMotion.ribbons,
      speed: 0.5,
    ),
  ),
  CosmeticDef(
    id: 'lava_flow',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.rare,
    name: tr('Поток лавы'),
    spec: BannerSpec(
      colors: [Color(0xFF1B0505), Color(0xFFB3260B), Color(0xFFFF8A34), Color(0xFF1B0505)],
      motion: BannerMotion.waves,
      speed: 0.45,
    ),
  ),
  CosmeticDef(
    id: 'neon_grid',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.epic,
    name: tr('Неоновая сетка'),
    spec: BannerSpec(
      colors: [Color(0xFF05010F), Color(0xFF7C1FFF), Color(0xFF00E5FF)],
      motion: BannerMotion.grid,
      speed: 1,
    ),
  ),
  CosmeticDef(
    id: 'starfield',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.epic,
    name: tr('Звёздное поле'),
    spec: BannerSpec(
      colors: [Color(0xFF01030E), Color(0xFF0A1B4A), Color(0xFF6FC3FF)],
      motion: BannerMotion.starfield,
      speed: 0.8,
    ),
  ),
  CosmeticDef(
    id: 'oil_slick',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.epic,
    name: tr('Нефтяная плёнка'),
    spec: BannerSpec(
      colors: [Color(0xFF12061F), Color(0xFF00A6A0), Color(0xFFD24BE0), Color(0xFF2B6BFF)],
      motion: BannerMotion.drift,
      speed: 0.5,
    ),
  ),
  CosmeticDef(
    id: 'gold_leaf',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.legendary,
    name: tr('Золотая фольга'),
    spec: BannerSpec(
      colors: [Color(0xFF241703), Color(0xFFC9962B), Color(0xFFFFE9A8), Color(0xFF8A5B12)],
      motion: BannerMotion.drift,
      speed: 0.35,
    ),
  ),
  CosmeticDef(
    id: 'frost_panel',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.rare,
    name: tr('Морозное стекло'),
    season: 'new_year',
    spec: BannerSpec(
      colors: [Color(0xFF061A2B), Color(0xFF1E5F8B), Color(0xFFBFEFFF)],
      motion: BannerMotion.drift,
      speed: 0.3,
    ),
  ),
  CosmeticDef(
    id: 'midnight_surf',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.rare,
    name: tr('Полночный прибой'),
    spec: BannerSpec(
      colors: [
        Color(0xFF02101F),
        Color(0xFF0B4F6C),
        Color(0xFF5FCBE0),
        Color(0xFF02101F),
      ],
      motion: BannerMotion.waves,
      speed: 0.5,
    ),
  ),
  CosmeticDef(
    id: 'vapor_silk',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.epic,
    name: tr('Неоновый шёлк'),
    spec: BannerSpec(
      colors: [
        Color(0xFF1A0033),
        Color(0xFF6A0DAD),
        Color(0xFFE0AAFF),
        Color(0xFF1A0033),
      ],
      motion: BannerMotion.drift,
      speed: 0.4,
    ),
  ),
  CosmeticDef(
    id: 'solar_prominence',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.epic,
    name: tr('Протуберанец'),
    spec: BannerSpec(
      colors: [
        Color(0xFF2B0A00),
        Color(0xFFFF6D00),
        Color(0xFFFFD24D),
        Color(0xFF2B0A00),
      ],
      motion: BannerMotion.waves,
      speed: 0.7,
    ),
  ),
  CosmeticDef(
    id: 'green_horizon',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.legendary,
    name: tr('Зелёный горизонт'),
    spec: BannerSpec(
      colors: [Color(0xFF010604), Color(0xFF005C3A), Color(0xFF00FF9C)],
      motion: BannerMotion.grid,
      speed: 0.8,
    ),
  ),
  CosmeticDef(
    id: 'rose_quartz',
    slot: CosmeticSlot.banner,
    tier: CosmeticTier.common,
    name: tr('Розовый кварц'),
    spec: BannerSpec(
      colors: [
        Color(0xFF3A1030),
        Color(0xFFB85C8E),
        Color(0xFFFFD9E8),
        Color(0xFF3A1030),
      ],
      motion: BannerMotion.drift,
      speed: 0.35,
    ),
  ),

  // — Рамки аватара —
  CosmeticDef(
    id: 'prism_ring',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.rare,
    name: tr('Призма'),
    spec: FrameSpec(
      colors: [Color(0xFFFF4D8D), Color(0xFFFFD24D), Color(0xFF4DFFB8), Color(0xFF4D8DFF), Color(0xFFFF4D8D)],
      motion: FrameMotion.dashed,
      width: 4.5,
      glow: 0.45,
    ),
  ),
  CosmeticDef(
    id: 'neon_pulse',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.rare,
    name: tr('Неон-пульс'),
    spec: FrameSpec(
      colors: [Color(0xFF00E5FF), Color(0xFF7C4DFF)],
      motion: FrameMotion.pulse,
      glow: 0.8,
    ),
  ),
  CosmeticDef(
    id: 'gold_laurel',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.legendary,
    name: tr('Золотой лавр'),
    spec: FrameSpec(
      colors: [Color(0xFFFFF1B8), Color(0xFFC9962B), Color(0xFF7A4E0B), Color(0xFFFFF1B8)],
      motion: FrameMotion.shine,
      width: 5,
      glow: 0.5,
    ),
  ),
  CosmeticDef(
    id: 'ember_orbit',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.epic,
    name: tr('Искры по кругу'),
    spec: FrameSpec(
      colors: [Color(0xFF3A1000), Color(0xFFFF7A18)],
      motion: FrameMotion.orbit,
      glow: 0.7,
    ),
  ),
  CosmeticDef(
    id: 'glitch_ring',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.epic,
    name: tr('Глитч'),
    spec: FrameSpec(
      colors: [Color(0xFFFF2E63), Color(0xFF00E5FF)],
      motion: FrameMotion.glitch,
      width: 3,
      glow: 0.35,
    ),
  ),
  CosmeticDef(
    id: 'frost_circle',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.rare,
    name: tr('Иней'),
    season: 'new_year',
    spec: FrameSpec(
      colors: [Color(0xFFBFEFFF), Color(0xFF3D8FC7)],
      motion: FrameMotion.orbit,
      glow: 0.55,
    ),
  ),
  CosmeticDef(
    id: 'soft_line',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.common,
    name: tr('Тонкая линия'),
    spec: FrameSpec(
      colors: [Color(0xFFB9C0E0)],
      motion: FrameMotion.pulse,
      width: 2,
      glow: 0,
      speed: 0.4,
    ),
  ),
  CosmeticDef(
    id: 'solar_corona',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.legendary,
    name: tr('Солнечная корона'),
    spec: FrameSpec(
      colors: [Color(0xFFFFF3B0), Color(0xFFFFB300), Color(0xFFFF5400)],
      motion: FrameMotion.orbit,
      width: 4.5,
      glow: 0.85,
    ),
  ),
  CosmeticDef(
    id: 'holo_band',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.epic,
    name: tr('Голограмма'),
    spec: FrameSpec(
      colors: [
        Color(0xFF4FD8FF),
        Color(0xFFFF5FD0),
        Color(0xFF9CFF5C),
        Color(0xFF4FD8FF),
      ],
      motion: FrameMotion.shine,
      glow: 0.55,
    ),
  ),
  CosmeticDef(
    id: 'frost_crown',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.rare,
    name: tr('Ледяная корона'),
    season: 'new_year',
    spec: FrameSpec(
      colors: [
        Color(0xFFDFF3FF),
        Color(0xFF4FA8E0),
        Color(0xFF0B3B5C),
        Color(0xFFDFF3FF),
      ],
      motion: FrameMotion.conic,
      glow: 0.5,
    ),
  ),
  CosmeticDef(
    id: 'mint_halo',
    slot: CosmeticSlot.avatarFrame,
    tier: CosmeticTier.common,
    name: tr('Мятный ореол'),
    spec: FrameSpec(
      colors: [Color(0xFF7BE0C0), Color(0xFFB8FFE8)],
      motion: FrameMotion.pulse,
      width: 2.5,
      glow: 0.2,
      speed: 0.5,
    ),
  ),

  // — Стили ника —
  CosmeticDef(
    id: 'sunset_glow',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.rare,
    name: tr('Закатный'),
    spec: NameSpec(
      colors: [Color(0xFFFF7043), Color(0xFFFFC94D), Color(0xFFFF4D8D)],
      motion: NameMotion.shimmer,
    ),
  ),
  CosmeticDef(
    id: 'frost_blue',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.rare,
    name: tr('Ледяной'),
    spec: NameSpec(
      colors: [Color(0xFF7FD8FF), Color(0xFF3D8FC7), Color(0xFFDFF3FF)],
    ),
  ),
  CosmeticDef(
    id: 'toxic_lime',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.rare,
    name: tr('Токсичный'),
    spec: NameSpec(colors: [Color(0xFFB6FF3C), Color(0xFF2FD98A)]),
  ),
  CosmeticDef(
    id: 'royal_gold',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.legendary,
    name: tr('Королевское золото'),
    spec: NameSpec(
      colors: [Color(0xFF8A5B12), Color(0xFFFFE9A8), Color(0xFFC9962B), Color(0xFFFFE9A8)],
    ),
  ),
  CosmeticDef(
    id: 'magenta_neon',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.epic,
    name: tr('Магента-неон'),
    spec: NameSpec(
      colors: [Color(0xFFFF2E9A), Color(0xFFB04DFF), Color(0xFFFF2E9A)],
      motion: NameMotion.hue,
    ),
  ),
  CosmeticDef(
    id: 'pride_wave',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.epic,
    name: tr('Радужный'),
    spec: NameSpec(
      colors: [
        Color(0xFFFF4D4D),
        Color(0xFFFFC94D),
        Color(0xFF4DFF8F),
        Color(0xFF4DB8FF),
        Color(0xFFB84DFF),
        Color(0xFFFF4D4D),
      ],
      motion: NameMotion.hue,
    ),
  ),
  CosmeticDef(
    id: 'ink_violet',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.common,
    name: tr('Чернильный'),
    spec: NameSpec(colors: [Color(0xFF9F7BFF), Color(0xFF6A3DE8)]),
  ),
  CosmeticDef(
    id: 'polar_shimmer',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.epic,
    name: tr('Полярное сияние'),
    spec: NameSpec(
      colors: [
        Color(0xFF4DFFB8),
        Color(0xFF7B5CFF),
        Color(0xFFFF4D8D),
        Color(0xFF4DFFB8),
      ],
      motion: NameMotion.hue,
    ),
  ),
  CosmeticDef(
    id: 'copper_name',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.rare,
    name: tr('Медь'),
    spec: NameSpec(
      colors: [Color(0xFFFFC98A), Color(0xFFB4652A), Color(0xFF8A4A1B)],
    ),
  ),
  CosmeticDef(
    id: 'pulsar',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.legendary,
    name: tr('Пульсар'),
    spec: NameSpec(
      colors: [Color(0xFF9FD8FF), Color(0xFF4D8DFF), Color(0xFF2E5BCC)],
      motion: NameMotion.shimmer,
    ),
  ),
  CosmeticDef(
    id: 'rose_neon',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.rare,
    name: tr('Розовый неон'),
    season: 'valentine',
    spec: NameSpec(
      colors: [Color(0xFFFF2E9A), Color(0xFFFF8FB8), Color(0xFFFF2E9A)],
      motion: NameMotion.hue,
    ),
  ),
  CosmeticDef(
    id: 'graphite',
    slot: CosmeticSlot.nameStyle,
    tier: CosmeticTier.common,
    name: tr('Графит'),
    spec: NameSpec(
      colors: [Color(0xFFA8B2D8), Color(0xFF6E7BA6)],
      motion: NameMotion.flat,
    ),
  ),

  // — Эффекты —
  CosmeticDef(
    id: 'snowfall',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.rare,
    name: tr('Снегопад'),
    season: 'new_year',
    spec: EffectSpec(
      kind: ParticleKind.snow,
      colors: [Colors.white, Color(0xFFCFEBFF)],
      count: 46,
      speed: 0.8,
    ),
  ),
  CosmeticDef(
    id: 'campfire_embers',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.rare,
    name: tr('Угли костра'),
    spec: EffectSpec(
      kind: ParticleKind.ember,
      colors: [Color(0xFFFFB74D), Color(0xFFFF6B2C), Color(0xFFFFE3A1)],
      count: 30,
      speed: 0.9,
    ),
  ),
  CosmeticDef(
    id: 'stardust',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.epic,
    name: tr('Звёздная пыль'),
    spec: EffectSpec(
      kind: ParticleKind.stardust,
      colors: [Colors.white, Color(0xFF9FD8FF), Color(0xFFE3B8FF)],
      count: 40,
      speed: 0.5,
    ),
  ),
  CosmeticDef(
    id: 'fireflies',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.rare,
    name: tr('Светлячки'),
    spec: EffectSpec(
      kind: ParticleKind.firefly,
      colors: [Color(0xFFD8FF6B), Color(0xFFFFF59B)],
      count: 18,
      speed: 0.4,
    ),
  ),
  CosmeticDef(
    id: 'coin_rain',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.legendary,
    name: tr('Денежный дождь'),
    spec: EffectSpec(
      kind: ParticleKind.coin,
      colors: [Color(0xFFFFD24D), Color(0xFFC9962B)],
      count: 34,
      speed: 1.1,
    ),
  ),
  CosmeticDef(
    id: 'cherry_blossom',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.rare,
    name: tr('Сакура'),
    season: 'spring',
    spec: EffectSpec(
      kind: ParticleKind.petal,
      colors: [Color(0xFFFFC1D4), Color(0xFFFFE3EC)],
      count: 24,
      speed: 0.55,
    ),
  ),
  CosmeticDef(
    id: 'hearts',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.rare,
    name: tr('Сердца'),
    season: 'valentine',
    spec: EffectSpec(
      kind: ParticleKind.heart,
      colors: [Color(0xFFFF4D7A), Color(0xFFFF97B4)],
      count: 16,
      speed: 0.5,
    ),
  ),
  CosmeticDef(
    id: 'confetti',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.common,
    name: tr('Конфетти'),
    spec: EffectSpec(
      kind: ParticleKind.confetti,
      colors: [
        Color(0xFFFF4D4D),
        Color(0xFFFFC94D),
        Color(0xFF4DFF8F),
        Color(0xFF4DB8FF),
        Color(0xFFB84DFF),
      ],
      count: 34,
      speed: 1,
    ),
  ),
  CosmeticDef(
    id: 'cold_rain',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.common,
    name: tr('Холодный дождь'),
    spec: EffectSpec(
      kind: ParticleKind.rain,
      colors: [Color(0xFF9FD8FF), Color(0xFFCFEBFF)],
      count: 40,
      speed: 1.4,
    ),
  ),
  CosmeticDef(
    id: 'blizzard',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.epic,
    name: tr('Метель'),
    season: 'new_year',
    spec: EffectSpec(
      kind: ParticleKind.snow,
      colors: [
        Colors.white,
        Color(0xFFCFEBFF),
        Color(0xFF9FD8FF),
      ],
      count: 64,
      speed: 1.9,
    ),
  ),
  CosmeticDef(
    id: 'fireworks',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.legendary,
    name: tr('Салют'),
    season: 'new_year',
    spec: EffectSpec(
      kind: ParticleKind.burst,
      colors: [
        Color(0xFFFF4D4D),
        Color(0xFFFFD24D),
        Color(0xFF4DFF8F),
        Color(0xFF4DB8FF),
        Color(0xFFB84DFF),
      ],
      count: 64,
      speed: 0.85,
    ),
  ),
  CosmeticDef(
    id: 'rose_down',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.epic,
    name: tr('Розовый снег'),
    season: 'valentine',
    spec: EffectSpec(
      kind: ParticleKind.petal,
      colors: [
        Color(0xFFFF4D7A),
        Color(0xFFFFC1D4),
        Color(0xFFFFE3EC),
      ],
      count: 34,
      speed: 0.9,
    ),
  ),
  CosmeticDef(
    id: 'monsoon',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.rare,
    name: tr('Муссон'),
    spec: EffectSpec(
      kind: ParticleKind.rain,
      colors: [Color(0xFF6FC3FF), Color(0xFFBFEFFF)],
      count: 58,
      speed: 2.2,
    ),
  ),
  CosmeticDef(
    id: 'witchfire',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.rare,
    name: tr('Ведьмино пламя'),
    spec: EffectSpec(
      kind: ParticleKind.ember,
      colors: [Color(0xFF9F7BFF), Color(0xFF4DFFB8), Color(0xFFE0AAFF)],
      count: 36,
      speed: 1.1,
    ),
  ),
  CosmeticDef(
    id: 'glitter',
    slot: CosmeticSlot.effect,
    tier: CosmeticTier.common,
    name: tr('Блёстки'),
    spec: EffectSpec(
      kind: ParticleKind.stardust,
      colors: [
        Colors.white,
        Color(0xFFFFF1B8),
        Color(0xFFB8E6FF),
      ],
      count: 30,
      speed: 0.7,
    ),
  ),
];

final Map<String, CosmeticDef> _byId = {
  for (final c in kCosmetics) c.id: c,
};

CosmeticDef? cosmeticById(String? id) {
  if (id == null) return null;
  return _byId[id];
}

/// Стиль ника автора из сырой строки ответа маркета: отзывы в бэке отдают
/// то `author_name_style`, то `authorNameStyle`, и витрина не должна держать
/// это в голове на каждом экране.
String? nameStyleOf(dynamic row) {
  if (row is! Map) return null;
  for (final key in const [
    'author_name_style',
    'authorNameStyle',
    'user_name_style',
    'actor_name_style',
  ]) {
    final value = row[key];
    if (value != null) return value.toString();
  }
  return null;
}

/// Вся экипировка человека из сырой строки ответа ленты.
///
/// Плоская колонка `*_name_style` старше, чем карта `cosmetics`, и старые
/// сборки клиента читают именно её, поэтому бэкенд отдаёт и то, и другое.
/// Здесь карта приоритетна: в ней есть рамка аватара, которой в плоской
/// колонке нет.
EquippedCosmetics equippedOf(dynamic row) {
  if (row is! Map) return EquippedCosmetics.none;
  for (final key in const [
    'author_cosmetics',
    'user_cosmetics',
    'actor_cosmetics',
    'cosmetics',
  ]) {
    final equipped = EquippedCosmetics.fromJson(row[key]);
    if (!equipped.isEmpty) return equipped;
  }
  final style = nameStyleOf(row);
  return style == null
      ? EquippedCosmetics.none
      : EquippedCosmetics(nameStyle: style);
}

/// Предметы одного слота, для витрины: сначала купленные по редкости.
List<CosmeticDef> cosmeticsOfSlot(CosmeticSlot slot) {
  final list = _byId.values.where((c) => c.slot == slot).toList();
  list.sort((a, b) {
    final byTier = b.tier.rank.compareTo(a.tier.rank);
    if (byTier != 0) return byTier;
    return a.name.compareTo(b.name);
  });
  return list;
}

/// Как назвать сезонный выпуск человеку: метка `season` у предмета — служебная,
/// её показывают и на витрине, и в фильтре выдачи.
String cosmeticSeasonLabel(String season) => switch (season) {
  'new_year' => tr('Новогодний выпуск'),
  'valentine' => tr('Ко Дню святого Валентина'),
  'spring' => tr('Весенний выпуск'),
  _ => tr('Сезонный выпуск'),
};

/// Порядок известным сезонам; неизвестные доезжают в конец по алфавиту.
const List<String> _knownSeasons = ['new_year', 'valentine', 'spring'];

/// Сезоны, которые действительно есть в каталоге, — чтобы фильтр выдачи не
/// предлагал пустые вкладки.
List<String> get kCosmeticSeasons {
  final present = {for (final def in kCosmetics) if (def.season != null) def.season!};
  return [
    for (final season in _knownSeasons)
      if (present.contains(season)) season,
    ...present.difference(_knownSeasons.toSet()).toList()..sort(),
  ];
}

/// Все id каталога — зеркалируется в таблицу `cosmetic_catalog` на бэке.
Set<String> get kCosmeticIds => _byId.keys.toSet();

/// Снап экипировки: слот -> id предмета (или null — «по умолчанию»).
@immutable
class EquippedCosmetics {
  const EquippedCosmetics({
    this.banner,
    this.background,
    this.avatarFrame,
    this.nameStyle,
    this.effect,
  });

  final String? banner;
  final String? background;
  final String? avatarFrame;
  final String? nameStyle;
  final String? effect;

  static const EquippedCosmetics none = EquippedCosmetics();

  String? of(CosmeticSlot slot) {
    switch (slot) {
      case CosmeticSlot.banner:
        return banner;
      case CosmeticSlot.background:
        return background;
      case CosmeticSlot.avatarFrame:
        return avatarFrame;
      case CosmeticSlot.nameStyle:
        return nameStyle;
      case CosmeticSlot.effect:
        return effect;
    }
  }

  EquippedCosmetics withSlot(CosmeticSlot slot, String? id) {
    switch (slot) {
      case CosmeticSlot.banner:
        return EquippedCosmetics(
          banner: id,
          background: background,
          avatarFrame: avatarFrame,
          nameStyle: nameStyle,
          effect: effect,
        );
      case CosmeticSlot.background:
        return EquippedCosmetics(
          banner: banner,
          background: id,
          avatarFrame: avatarFrame,
          nameStyle: nameStyle,
          effect: effect,
        );
      case CosmeticSlot.avatarFrame:
        return EquippedCosmetics(
          banner: banner,
          background: background,
          avatarFrame: id,
          nameStyle: nameStyle,
          effect: effect,
        );
      case CosmeticSlot.nameStyle:
        return EquippedCosmetics(
          banner: banner,
          background: background,
          avatarFrame: avatarFrame,
          nameStyle: id,
          effect: effect,
        );
      case CosmeticSlot.effect:
        return EquippedCosmetics(
          banner: banner,
          background: background,
          avatarFrame: avatarFrame,
          nameStyle: nameStyle,
          effect: id,
        );
    }
  }

  bool get isEmpty =>
      banner == null &&
      background == null &&
      avatarFrame == null &&
      nameStyle == null &&
      effect == null;

  factory EquippedCosmetics.fromJson(Object? raw) {
    Map<String, dynamic>? map;
    if (raw is Map<String, dynamic>) {
      map = raw;
    } else if (raw is String && raw.trim().startsWith('{')) {
      try {
        // Бэкенд иногда отдаёт jsonb как строку (старый pg-драйвер).
        map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {
        map = null;
      }
    }
    if (map == null) return none;
    String? id(String key) {
      final v = map![key];
      return v is String && v.isNotEmpty ? v : null;
    }

    // Проверяем, что id жив в каталоге и лежит в своём слоте: профиль мог
    // сохраниться со старой сборкой, а кривой снап не должен надеть обложку
    // в слот фона.
    String? known(String? value, CosmeticSlot slot) {
      final def = cosmeticById(value);
      return def != null && def.slot == slot ? value : null;
    }

    return EquippedCosmetics(
      banner: known(id(CosmeticSlot.banner.wireName), CosmeticSlot.banner),
      background: known(id(CosmeticSlot.background.wireName), CosmeticSlot.background),
      avatarFrame: known(id(CosmeticSlot.avatarFrame.wireName), CosmeticSlot.avatarFrame),
      nameStyle: known(id(CosmeticSlot.nameStyle.wireName), CosmeticSlot.nameStyle),
      effect: known(id(CosmeticSlot.effect.wireName), CosmeticSlot.effect),
    );
  }

  Map<String, dynamic> toJson() => {
    for (final slot in CosmeticSlot.values) slot.wireName: of(slot),
  };
}
