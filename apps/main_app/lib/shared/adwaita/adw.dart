/// Adwaita (GNOME HIG) для Flutter — палитра, типографика и несколько
/// примитивов, из которых собран редизайн библиотеки.
///
/// Почему руками, а не пакетами. Все три пакета из «стекa» (`adwaita`,
/// `libadwaita`, `adwaita_icons`) последний раз публиковались в 2023 и на
/// Flutter 3.47 не собираются: `libadwaita` 1.0.0-rc.2 обращается к
/// `ThemeData.backgroundColor` и `TextTheme.headline6/bodyText2`, которых
/// больше нет, `adwaita` 1.1.0 отдаёт `DialogTheme` вместо `DialogThemeData`,
/// `adwaita_icons` требует `sdk <3.0.0` и тянет `flutter_svg` 1.x, который
/// не совместим с `pdf` (`xml` 6 против 7). Свежий `libadwaita` 2.0.2 не
/// резолвится из-за `package_info_plus ^4.0.0` (в приложении ^10).
///
/// Поэтому здесь только то, что реально определяет вид: палитра libadwaita,
/// радиусы 12/8/6, символические иконки GNOME из `assets/icons/adwaita`.
/// Цвета — из `src/stylesheet/_palette.scss` и `_defaults.scss` libadwaita.
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Палитра Adwaita: цвета и типографика одной темы.
///
/// Значения — из `src/stylesheet/_palette.scss` и `_defaults.scss` libadwaita
/// (тёмная и светлая темы). Тема выбирается по яркости окружения, чтобы экран
/// не выпадал из темы приложения.
class AdwPalette {
  const AdwPalette({
    required this.window,
    required this.view,
    required this.card,
    required this.cardHover,
    required this.headerBar,
    required this.accent,
    required this.accentHover,
    required this.accentPressed,
    required this.destructive,
    required this.warning,
    required this.success,
    required this.fg,
    required this.fgDim,
    required this.border,
    required this.divider,
    required this.hover,
    required this.active,
    required this.button,
    required this.buttonHover,
    required this.entry,
  });

  /// Тёмная тема libadwaita.
  static const dark = AdwPalette(
    window: Color(0xFF242424),
    view: Color(0xFF1E1E1E),
    card: Color(0xFF383838),
    cardHover: Color(0xFF414141),
    headerBar: Color(0xFF303030),
    accent: Color(0xFF3584E4),
    accentHover: Color(0xFF4A90E8),
    accentPressed: Color(0xFF2A6FC0),
    destructive: Color(0xFFE01B24),
    warning: Color(0xFFE5A50A),
    success: Color(0xFF33D17A),
    fg: Color(0xFFFFFFFF),
    fgDim: Color(0xFFC0BFBC),
    border: Color(0x26FFFFFF),
    divider: Color(0x1FFFFFFF),
    hover: Color(0x14FFFFFF),
    active: Color(0x24FFFFFF),
    button: Color(0x1AFFFFFF),
    buttonHover: Color(0x26FFFFFF),
    entry: Color(0x1AFFFFFF),
  );

  /// Светлая тема libadwaita.
  static const light = AdwPalette(
    window: Color(0xFFFAFAFA),
    view: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    cardHover: Color(0xFFF6F5F4),
    headerBar: Color(0xFFEBEBEB),
    accent: Color(0xFF3584E4),
    accentHover: Color(0xFF4A90E8),
    accentPressed: Color(0xFF2A6FC0),
    destructive: Color(0xFFE01B24),
    warning: Color(0xFFE5A50A),
    success: Color(0xFF26A269),
    fg: Color(0xFF000000),
    fgDim: Color(0xFF5E5C64),
    border: Color(0x24000000),
    divider: Color(0x1F000000),
    hover: Color(0x0D000000),
    active: Color(0x1A000000),
    button: Color(0x1A000000),
    buttonHover: Color(0x26000000),
    entry: Color(0x0D000000),
  );

  /// window bg — `.background-color`.
  final Color window;

  /// view bg — область контента.
  final Color view;

  /// `.card`.
  final Color card;

  /// `.card` под курсором.
  final Color cardHover;

  /// headerbar.
  final Color headerBar;

  /// blue-3 — акцент GNOME по умолчанию.
  final Color accent;
  final Color accentHover;
  final Color accentPressed;

  /// red-3, yellow-5, green-3 — семантика libadwaita.
  final Color destructive;
  final Color warning;
  final Color success;

  final Color fg;
  final Color fgDim;

  /// `alpha(currentColor, .15)` — разделители и рамки.
  final Color border;
  final Color divider;

  /// Фоны интерактивных поверхностей.
  final Color hover;
  final Color active;
  final Color button;
  final Color buttonHover;
  final Color entry;

  static AdwPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// Типографика Adwaita в размерах, которые читаются на 390 px.
  TextStyle get title1 => TextStyle(
    fontSize: 22,
    height: 1.18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: fg,
  );
  TextStyle get title2 => TextStyle(
    fontSize: 15,
    height: 1.25,
    fontWeight: FontWeight.w700,
    color: fg,
  );
  TextStyle get body => TextStyle(
    fontSize: 14,
    height: 1.35,
    fontWeight: FontWeight.w400,
    color: fg,
  );
  TextStyle get bodyStrong => TextStyle(
    fontSize: 14,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: fg,
  );
  TextStyle get caption => TextStyle(
    fontSize: 12.5,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: fgDim,
  );
  TextStyle get captionStrong => TextStyle(
    fontSize: 12.5,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: fgDim,
  );

  /// `.heading` — капс-подпись раздела.
  TextStyle get heading => TextStyle(
    fontSize: 11.5,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.9,
    color: fgDim,
  );
}

extension AdwBuildContext on BuildContext {
  /// Палитра и типографика Adwaita текущей яркости.
  AdwPalette get adw => AdwPalette.of(this);
}

/// Радиусы libadwaita: карточки 12, контролы 8, кнопки 6.
abstract final class AdwRadius {
  static const card = 12.0;
  static const control = 8.0;
  static const button = 6.0;
  static const pill = 999.0;
}

/// Имена символических иконок GNOME (файлы `assets/icons/adwaita`).
abstract final class AdwIcons {
  static const add = 'list-add';
  static const archive = 'document-save';
  static const author = 'avatar-default';
  static const back = 'go-previous';
  static const check = 'object-select';
  static const clear = 'edit-clear';
  static const cloudOff = 'weather-overcast';
  static const delete = 'user-trash';
  static const edit = 'document-edit';
  static const error = 'dialog-error';
  static const forward = 'go-next';
  static const image = 'image-x-generic';
  static const import = 'document-send';
  static const library = 'folder-documents';
  static const local = 'drive-harddisk';
  static const lock = 'changes-prevent';
  static const market = 'system-software-install';
  static const menu = 'view-more';
  static const open = 'document-open';
  static const play = 'media-playback-start';
  static const presets = 'view-grid';
  static const print = 'document-print';
  static const recent = 'document-open-recent';
  static const restore = 'document-revert';
  static const search = 'system-search';
  static const sort = 'view-sort-descending';
  static const sync = 'view-refresh';
  static const timer = 'alarm';
  static const warning = 'dialog-warning';
  static const folder = 'folder';
}

/// Одна символическая иконка, перекрашенная в цвет текста.
class AdwIcon extends StatelessWidget {
  const AdwIcon(this.name, {super.key, this.size = 16, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/adwaita/$name-symbolic.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color ?? context.adw.fgDim, BlendMode.srcIn),
      excludeFromSemantics: true,
    );
  }
}

/// Круглая icon-кнопка из headerbar: 34 px, подсветка под курсором.
class AdwIconButton extends StatefulWidget {
  const AdwIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.onLongPress,
    this.size = 34,
    this.iconSize = 16,
    this.selected = false,
    this.overlay,
  });

  final String icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final double size;
  final double iconSize;
  final bool selected;

  /// Вместо иконки — например, индикатор синхронизации.
  final Widget? overlay;

  @override
  State<AdwIconButton> createState() => _AdwIconButtonState();
}

class _AdwIconButtonState extends State<AdwIconButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null || widget.onLongPress != null;
    final background = !enabled
        ? Colors.transparent
        : (widget.selected
              ? context.adw.active
              : (_down
                    ? context.adw.active
                    : (_hover ? context.adw.hover : Colors.transparent)));
    final color = enabled
        ? (widget.selected ? context.adw.fg : context.adw.fgDim)
        : context.adw.fgDim.withValues(alpha: 0.4);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = _down = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          onLongPress: widget.onLongPress,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(color: background, shape: BoxShape.circle),
            child: Center(
              child:
                  widget.overlay ??
                  AdwIcon(widget.icon, size: widget.iconSize, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// Варианты кнопки libadwaita.
enum AdwButtonVariant { suggested, flat, regular, destructive }

/// Кнопка Adwaita: 6 px радиус, 999 для пилюли, подсветка состояний.
class AdwButton extends StatefulWidget {
  const AdwButton({
    super.key,
    required this.child,
    this.onPressed,
    this.variant = AdwButtonVariant.regular,
    this.pill = false,
    this.expanded = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
  });

  final Widget child;
  final VoidCallback? onPressed;
  final AdwButtonVariant variant;
  final bool pill;
  final bool expanded;
  final EdgeInsetsGeometry padding;

  @override
  State<AdwButton> createState() => _AdwButtonState();
}

class _AdwButtonState extends State<AdwButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final Color background;
    switch (widget.variant) {
      case AdwButtonVariant.suggested:
        background = !enabled
            ? context.adw.accent.withValues(alpha: 0.4)
            : (_down
                  ? context.adw.accentPressed
                  : (_hover ? context.adw.accentHover : context.adw.accent));
      case AdwButtonVariant.destructive:
        background = !enabled
            ? context.adw.destructive.withValues(alpha: 0.4)
            : (_down
                  ? const Color(0xFFB5161D)
                  : (_hover
                        ? const Color(0xFFF0323B)
                        : context.adw.destructive));
      case AdwButtonVariant.flat:
        background = !enabled
            ? Colors.transparent
            : (_down
                  ? context.adw.active
                  : (_hover ? context.adw.hover : Colors.transparent));
      case AdwButtonVariant.regular:
        background = !enabled
            ? context.adw.button.withValues(alpha: 0.5)
            : (_down
                  ? context.adw.active
                  : (_hover ? context.adw.buttonHover : context.adw.button));
    }
    final foreground = !enabled
        ? context.adw.fg.withValues(alpha: 0.5)
        : (widget.variant == AdwButtonVariant.suggested ||
                  widget.variant == AdwButtonVariant.destructive
              ? context.adw.fg
              : context.adw.fg);

    final content = DefaultTextStyle.merge(
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: foreground,
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground, size: 16),
        child: widget.child,
      ),
    );

    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = _down = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(
              widget.pill ? AdwRadius.pill : AdwRadius.button,
            ),
          ),
          child: Center(widthFactor: 1, heightFactor: 1, child: content),
        ),
      ),
    );

    return widget.expanded
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }
}

/// Карточка Adwaita: 12 px радиус, `#383838` в тёмной теме.
class AdwCard extends StatefulWidget {
  const AdwCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(12),
    this.color,
    this.border,
    this.radius = AdwRadius.card,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final BoxBorder? border;
  final double radius;

  @override
  State<AdwCard> createState() => _AdwCardState();
}

class _AdwCardState extends State<AdwCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color ?? context.adw.card;
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: widget.onTap == null
                ? base
                : Color.alphaBlend(
                    _hover ? context.adw.hover : Colors.transparent,
                    base,
                  ),
            borderRadius: BorderRadius.circular(widget.radius),
            border: widget.border ??
                (Theme.of(context).brightness == Brightness.light
                    ? Border.all(color: context.adw.border)
                    : null),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Группа строк Adwaita: одна плашка-карточка, строки через волосяную линию.
class AdwGroup extends StatelessWidget {
  const AdwGroup({
    super.key,
    required this.children,
    this.title,
    this.description,
  });

  final List<Widget> children;
  final String? title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(title!.toUpperCase(), style: context.adw.heading),
          ),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(AdwRadius.card),
          child: Container(
            decoration: BoxDecoration(
              color: context.adw.card,
              border: Theme.of(context).brightness == Brightness.light
                  ? Border.all(color: context.adw.border)
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, child) in children.indexed) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: context.adw.divider,
                    ),
                  child,
                ],
              ],
            ),
          ),
        ),
        if (description != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(description!, style: context.adw.caption),
          ),
      ],
    );
  }
}

/// Строка списка Adwaita (`AdwActionRow`): иконка, заголовок, подпись,
/// хвостовой виджет. Подсветка под курсором.
class AdwActionRow extends StatefulWidget {
  const AdwActionRow({
    super.key,
    this.leading,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final Widget? leading;
  final String? icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  State<AdwActionRow> createState() => _AdwActionRowState();
}

class _AdwActionRowState extends State<AdwActionRow> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final accentColor = widget.destructive
        ? context.adw.destructive
        : context.adw.fg;
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = _down = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: widget.onTap != null
            ? (_) => setState(() => _down = true)
            : null,
        onTapUp: widget.onTap != null ? (_) => setState(() => _down = false) : null,
        onTapCancel: widget.onTap != null
            ? () => setState(() => _down = false)
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: _down
              ? context.adw.active
              : (_hover ? context.adw.hover : Colors.transparent),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 12),
              ] else if (widget.icon != null) ...[
                SizedBox(
                  width: 20,
                  child: Center(
                    child: AdwIcon(
                      widget.icon!,
                      size: 16,
                      color: widget.destructive
                          ? context.adw.destructive
                          : context.adw.fgDim,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.adw.bodyStrong.copyWith(
                        color: widget.destructive
                            ? context.adw.destructive
                            : context.adw.fg,
                      ),
                    ),
                    if (widget.subtitle != null &&
                        widget.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.adw.caption,
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ] else if (widget.onTap != null) ...[
                const SizedBox(width: 8),
                AdwIcon(
                  AdwIcons.forward,
                  size: 14,
                  color: accentColor.withValues(alpha: 0.55),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Тон баннера libadwaita.
enum AdwBannerTone { neutral, warning, error, success }

/// Полоса-предупреждение (`AdwBanner`): иконка, заголовок, подпись, действие.
class AdwBanner extends StatelessWidget {
  const AdwBanner({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.tone = AdwBannerTone.neutral,
    this.actionLabel,
    this.onAction,
    this.onTap,
    this.showChevron = false,
    this.progress,
    this.trailing,
  });

  final String icon;
  final String title;
  final String? subtitle;
  final AdwBannerTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onTap;
  final bool showChevron;
  final double? progress;
  final Widget? trailing;

  Color _iconColor(BuildContext context) => switch (tone) {
    AdwBannerTone.warning => context.adw.warning,
    AdwBannerTone.error => context.adw.destructive,
    AdwBannerTone.success => context.adw.success,
    AdwBannerTone.neutral => context.adw.accent,
  };

  @override
  Widget build(BuildContext context) {
    return AdwCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AdwIcon(icon, size: 18, color: _iconColor(context)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: context.adw.bodyStrong),
                    if (subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(subtitle!, style: context.adw.caption),
                    ],
                  ],
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(width: 8),
                AdwButton(
                  variant: AdwButtonVariant.regular,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ],
              if (trailing != null) ...[const SizedBox(width: 4), trailing!],
              if (showChevron && trailing == null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: AdwIcon(
                    AdwIcons.forward,
                    size: 14,
                    color: context.adw.fgDim.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress! <= 0 ? null : progress,
                minHeight: 3,
                color: context.adw.accent,
                backgroundColor: context.adw.active,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Поле поиска в стиле `entry`: 8 px радиус, фон `alpha(1, .08)`,
/// акцентная рамка по фокусу.
class AdwSearchEntry extends StatefulWidget {
  const AdwSearchEntry({
    super.key,
    required this.controller,
    this.focusNode,
    required this.hint,
    this.onChanged,
    this.trailing,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final Widget? trailing;

  @override
  State<AdwSearchEntry> createState() => _AdwSearchEntryState();
}

class _AdwSearchEntryState extends State<AdwSearchEntry> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() => setState(() => _focused = widget.focusNode?.hasFocus ?? false);

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: 42,
      padding: EdgeInsets.only(left: 10, right: widget.trailing == null ? 10 : 4),
      decoration: BoxDecoration(
        color: context.adw.entry,
        borderRadius: BorderRadius.circular(AdwRadius.control),
        border: Border.all(
          color: _focused ? context.adw.accent : Colors.transparent,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          AdwIcon(AdwIcons.search, size: 15, color: context.adw.fgDim),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              onChanged: widget.onChanged,
              cursorColor: context.adw.accent,
              style: context.adw.body,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: context.adw.body.copyWith(color: context.adw.fgDim),
              ),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }
}

/// Элемент переключателя видов.
class AdwSwitcherItem {
  const AdwSwitcherItem({
    required this.label,
    this.count,
    this.icon,
  });

  final String label;
  final int? count;
  final String? icon;
}

/// `AdwViewSwitcher`: сегментированный переключатель в общей капсуле.
class AdwViewSwitcher extends StatelessWidget {
  const AdwViewSwitcher({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.padding = EdgeInsets.zero,
  });

  final List<AdwSwitcherItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: context.adw.entry,
        borderRadius: BorderRadius.all(Radius.circular(AdwRadius.control)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            for (final (i, item) in items.indexed)
              _SwitcherButton(
                item: item,
                selected: i == selectedIndex,
                onTap: () => onSelected(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _SwitcherButton extends StatefulWidget {
  const _SwitcherButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final AdwSwitcherItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SwitcherButton> createState() => _SwitcherButtonState();
}

class _SwitcherButtonState extends State<_SwitcherButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? context.adw.card
                : (_hover ? context.adw.hover : Colors.transparent),
            borderRadius: BorderRadius.circular(AdwRadius.control - 2),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.item.icon != null) ...[
                AdwIcon(
                  widget.item.icon!,
                  size: 14,
                  color: selected ? context.adw.fg : context.adw.fgDim,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.item.label,
                style: context.adw.captionStrong.copyWith(
                  color: selected ? context.adw.fg : context.adw.fgDim,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              if (widget.item.count != null) ...[
                const SizedBox(width: 5),
                Text(
                  '${widget.item.count}',
                  style: context.adw.caption.copyWith(
                    fontSize: 11.5,
                    color: context.adw.fgDim.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Капс-заголовок раздела — `.heading` из Adwaita.
class AdwSectionLabel extends StatelessWidget {
  const AdwSectionLabel({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title.toUpperCase(), style: context.adw.heading)),
        ?trailing,
      ],
    );
  }
}