import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'theme_preset.dart';
import 'theme_registry.dart';

/// Единая фабрика тем. Берём пресет (seed + опц. оверрайды) и яркость —
/// получаем готовую `ThemeData` в стиле Material 3.
class AppTheme {
  AppTheme._();

  /// Шрифты для письменностей, которых нет в Manrope: хан, канны, хангыль,
  /// арабица, деванагари. Список покрывает и упаковку Noto на Arch/Debian
  /// («Noto Sans CJK SC»), и вариант из Google Fonts («Noto Sans SC»), и
  /// системные шрифты Windows/macOS. Без него на голом Linux иероглифы
  /// превращаются в квадратики — в системе просто нечего подставить.
  static const List<String> _scriptFallback = <String>[
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Noto Sans CJK JP',
    'Noto Sans JP',
    'Noto Sans CJK KR',
    'Noto Sans KR',
    'Microsoft YaHei',
    'PingFang SC',
    'Hiragino Sans',
    'Malgun Gothic',
    'Noto Sans Arabic',
    'Noto Naskh Arabic',
    'Noto Sans Devanagari',
  ];

  /// Собранные темы: `AppTheme.fromPreset` вызывается дважды на каждый
  /// `build` корневого `App` (светлая и тёмная), а внутри — `ColorScheme
  /// .fromSeed` (HCT-палитра) и `ThemeData` целиком. Тема за время жизни
  /// экрана не меняется, поэтому результат кэшируется по пресету и яркости.
  static final Map<(ThemePreset, Brightness), ThemeData> _cache =
      <(ThemePreset, Brightness), ThemeData>{};

  /// Главная фабрика — собирает M3-тему из пресета и яркости.
  static ThemeData fromPreset(ThemePreset preset, Brightness brightness) {
    final key = (preset, brightness);
    final cached = _cache[key];
    if (cached != null) return cached;
    final built = _build(preset, brightness);
    if (_cache.length >= 8) _cache.clear();
    _cache[key] = built;
    return built;
  }

  static ThemeData _build(ThemePreset preset, Brightness brightness) {
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    final scheme = preset.schemeFor(brightness);

    return base.copyWith(
      useMaterial3: true,
      colorScheme: scheme,
      primaryColor: scheme.primary,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      textTheme: GoogleFonts.manropeTextTheme(base.textTheme)
          .apply(fontFamilyFallback: _scriptFallback),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHigh,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.antiAlias,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.secondaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        labelStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        secondaryLabelStyle: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            color: scheme.onSurface,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
      dividerColor: scheme.outlineVariant,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      disabledColor: scheme.onSurface.withOpacity(0.38),
      cardColor: scheme.surfaceContainerHigh,
      hintColor: scheme.onSurfaceVariant,
      indicatorColor: scheme.primary,
      splashFactory: InkSparkle.splashFactory,
    );
  }

  // ---------------------------------------------------------------------
  //  Совместимость со старым кодом.
  //  Старые геттеры → дефолтный пресет beige (light) / forest (light) и т.д.
  // ---------------------------------------------------------------------

  @Deprecated('Используйте AppTheme.fromPreset(presetBeige, Brightness.light)')
  static ThemeData get lightTheme =>
      fromPreset(_byId('beige'), Brightness.light);

  @Deprecated('Используйте AppTheme.fromPreset(presetBeige, Brightness.dark)')
  static ThemeData get darkTheme => fromPreset(_byId('beige'), Brightness.dark);

  @Deprecated('Используйте AppTheme.fromPreset(presetForest, Brightness.light)')
  static ThemeData get forestLightTheme =>
      fromPreset(_byId('forest'), Brightness.light);

  @Deprecated('Используйте AppTheme.fromPreset(presetForest, Brightness.dark)')
  static ThemeData get forestDarkTheme =>
      fromPreset(_byId('forest'), Brightness.dark);

  static ThemePreset _byId(String id) =>
      ThemeRegistry.byId(id) ?? ThemeRegistry.defaultPreset;
}
