import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

/// Переводит текущую Flutter-тему приложения в токены M3E.
///
/// Без этого M3E-компоненты строят собственную палитру из seed-цвета и
/// расходятся с тёмной/светлой темой приложения: тёмный экран получал светлые
/// листы и меню, а акцентные карточки — чужой оттенок. Здесь роли ColorScheme
/// переносятся один в один, поэтому surfaces и акценты совпадают.
M3EThemeData m3eThemeFrom(ThemeData theme) {
  final scheme = theme.colorScheme;
  final isDark = scheme.brightness == Brightness.dark;
  return M3EThemeData(
    colorScheme: M3EColorScheme(
      brightness: scheme.brightness,
      primary: scheme.primary,
      onPrimary: scheme.onPrimary,
      primaryContainer: scheme.primaryContainer,
      onPrimaryContainer: scheme.onPrimaryContainer,
      secondary: scheme.secondary,
      onSecondary: scheme.onSecondary,
      secondaryContainer: scheme.secondaryContainer,
      onSecondaryContainer: scheme.onSecondaryContainer,
      tertiary: scheme.tertiary,
      onTertiary: scheme.onTertiary,
      tertiaryContainer: scheme.tertiaryContainer,
      onTertiaryContainer: scheme.onTertiaryContainer,
      error: scheme.error,
      onError: scheme.onError,
      errorContainer: scheme.errorContainer,
      onErrorContainer: scheme.onErrorContainer,
      surface: scheme.surface,
      onSurface: scheme.onSurface,
      onSurfaceVariant: scheme.onSurfaceVariant,
      surfaceContainerLowest: scheme.surfaceContainerLowest,
      surfaceContainerLow: scheme.surfaceContainerLow,
      surfaceContainer: scheme.surfaceContainer,
      surfaceContainerHigh: scheme.surfaceContainerHigh,
      surfaceContainerHighest: scheme.surfaceContainerHighest,
      surfaceDim: scheme.surfaceDim,
      surfaceBright: scheme.surfaceBright,
      inverseSurface: scheme.inverseSurface,
      onInverseSurface: scheme.onInverseSurface,
      inversePrimary: scheme.inversePrimary,
      outline: scheme.outline,
      outlineVariant: scheme.outlineVariant,
      shadow: scheme.shadow,
      scrim: scheme.scrim,
      surfaceTint: scheme.surfaceTint,
      emphasis: scheme.primary,
      onEmphasis: scheme.onPrimary,
      info: scheme.tertiary,
      success: isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
      warning: isDark ? const Color(0xFFFFB74D) : const Color(0xFFEF6C00),
      danger: scheme.error,
      surfaceStrong: scheme.surfaceContainerHighest,
      onSurfaceStrong: scheme.onSurface,
      outlineStrong: scheme.outline,
    ),
    iconTheme: theme.iconTheme,
    platform: theme.platform,
    useMaterial3: theme.useMaterial3,
    splashColor: theme.splashColor,
    highlightColor: theme.highlightColor,
  );
}
