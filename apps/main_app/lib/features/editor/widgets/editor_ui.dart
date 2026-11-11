import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';

// ============================================================================
//  ОБЩИЕ UI-КОМПОНЕНТЫ В СТИЛЕ M3 (как профиль/маркет/библиотека)
//  Используются на экранах: Мои главы, Нод контент, Ресурсы,
//  Мои переменные, Туториал.
// ============================================================================

/// Поисковое поле в стиле M3.
class EditorSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const EditorSearchField({
    super.key,
    required this.controller,
    this.hintText,
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: TextField(
        controller: controller,
        style: TextStyle(color: scheme.onSurface),
        cursorColor: scheme.primary,
        decoration: InputDecoration(
          hintText: hintText ?? tr('Поиск...'),
          hintStyle: TextStyle(color: scheme.onSurfaceVariant),
          prefixIcon: Icon(
            Icons.search_rounded,
            color: scheme.onSurfaceVariant,
          ),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: () {
                    controller.clear();
                    onClear?.call();
                    onChanged?.call('');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

/// Квадратная кнопка-иконка на фоне surfaceContainerHigh (рядом с поиском).
class EditorIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final Color? iconColor;

  const EditorIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: iconColor ?? scheme.onSurface),
      ),
    );
  }
}

/// Универсальная карточка-строка: иконка в цветной плитке + заголовок +
/// подзаголовок + опциональные бейджи и кнопка «ещё».
class EditorListCard extends StatelessWidget {
  final IconData icon;
  final Color? accentColor;
  final String title;
  final String? subtitle;
  final List<Widget> badges;
  final VoidCallback? onTap;
  final VoidCallback? onMore;
  final Widget? trailing;
  final bool selected;

  const EditorListCard({
    super.key,
    required this.icon,
    required this.title,
    this.accentColor,
    this.subtitle,
    this.badges = const [],
    this.onTap,
    this.onMore,
    this.trailing,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = accentColor ?? scheme.primary;
    return Material(
      color: selected
          ? scheme.primaryContainer.withOpacity(0.45)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: accent, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (badges.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 6, runSpacing: 6, children: badges),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
              if (onMore != null)
                IconButton(
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: onMore,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Тональный бейдж-чип.
class EditorBadge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const EditorBadge({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state в стиле профиля.
class EditorEmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? hint;
  final Widget? action;

  const EditorEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.hint,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, size: 36, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Опция в bottom sheet.
class EditorSheetOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color? color;
  final VoidCallback onTap;

  const EditorSheetOption({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.onSurface;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: accent.withOpacity(0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: accent, size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
      ),
      onTap: onTap,
    );
  }
}

/// Показ bottom sheet в стиле M3 (с drag handle).
///
/// На широком окне тот же лист превращается в диалог у курсора: панель
/// свойств стека, прилепленная к нижнему краю 1440 px, читается плохо —
/// содержимое не меняется, меняется только поверхность.
Future<T?> showEditorSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  double maxWidth = 480,
  Offset? anchor,
}) {
  return showAdaptiveSheet<T>(
    context: context,
    builder: builder,
    title: title,
    maxWidth: maxWidth,
    anchor: anchor,
    showDragHandle: true,
    useSafeArea: true,
  );
}

/// Короткое уведомление редактора: одно за раз и над нижними панелями.
///
/// SnackBar по умолчанию висит четыре секунды и встаёт в очередь. Пока автор
/// добавляет элементы подряд, уведомления накапливаются и десятками секунд
/// закрывают нижнюю панель с кнопками — сообщение при этом давно не нужно.
/// Поэтому предыдущее снимается сразу, а новое живёт 1.4 с и поднято над
/// панелью канваса (она стоит на 24 px от края).
void showEditorNotice(BuildContext context, String message, {Color? color}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 112),
        duration: const Duration(milliseconds: 1400),
      ),
    );
}
