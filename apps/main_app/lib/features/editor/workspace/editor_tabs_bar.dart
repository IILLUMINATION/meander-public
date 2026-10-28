import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:canvas_app/core/l10n/l10n.dart';

// ============================================================================
// Meander — редизайн панели вкладок
// ----------------------------------------------------------------------------
// Главная идея редизайна: активная вкладка визуально "сливается" с панелью
// контента снизу (общий фон, нет нижней границы), а переключение между
// вкладками сопровождается скользящим индикатором (AnimatedPositioned),
// а не статичной полоской, которая просто появляется/исчезает.
//
// Второстепенные изменения относительно старой версии:
//   - точка "не сохранено" плавно морфится в крестик при наведении
//     (вместо того чтобы точка и крестик существовали параллельно)
//   - иконка вкладки может иметь цвет по типу документа (граф/скрипт/ресурсы)
//   - кнопка обзора вкладок теперь открывает список всех вкладок,
//     а не просто считает переполнение
// ============================================================================

class EditorTabData {
  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color? accentColor; // null = нейтральный цвет иконки
  final bool isDirty;
  final bool isPinned;

  const EditorTabData({
    required this.id,
    required this.title,
    this.subtitle,
    required this.icon,
    this.accentColor,
    this.isDirty = false,
    this.isPinned = false,
  });
}

enum TabContextAction {
  close,
  closeOthers,
  closeToRight,
  closeAll,
  splitRight,
  splitDown,
  pinAsNewTab,
  togglePin,
}

class EditorTabsBar extends StatefulWidget {
  final List<EditorTabData> tabs;
  final String? activeTabId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final VoidCallback onNewTab;
  final VoidCallback? onCollapsePanes;
  final VoidCallback? onExitToMenu;
  final VoidCallback? onShowOverview;
  final VoidCallback? onTogglePin;
  final VoidCallback? onGuides;
  final bool isPinnedActive;
  final void Function(String tabId, TabContextAction action)? onContextAction;

  const EditorTabsBar({
    super.key,
    required this.tabs,
    required this.activeTabId,
    required this.onSelect,
    required this.onClose,
    required this.onNewTab,
    this.onCollapsePanes,
    this.onExitToMenu,
    this.onShowOverview,
    this.onTogglePin,
    this.onGuides,
    this.isPinnedActive = false,
    this.onContextAction,
  });

  @override
  State<EditorTabsBar> createState() => _EditorTabsBarState();
}

class _EditorTabsBarState extends State<EditorTabsBar> {
  final ScrollController _scroll = ScrollController();

  static const double _tabWidthCompact = 148;
  static const double _tabWidthNormal = 190;
  static const double _tabMargin = 2; // с каждой стороны вкладки
  static const double _barHeightCompact = 44;
  static const double _barHeightNormal = 48;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant EditorTabsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTabId != widget.activeTabId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
    }
  }

  void _scrollToActive() {
    if (!_scroll.hasClients) return;
    final index = widget.tabs.indexWhere((t) => t.id == widget.activeTabId);
    if (index == -1) return;

    final compact = MediaQuery.sizeOf(context).width < 620;
    final width = compact ? _tabWidthCompact : _tabWidthNormal;
    final slot = width + _tabMargin * 2;

    final targetLeft = index * slot;
    final targetRight = targetLeft + slot;
    final viewStart = _scroll.offset;
    final viewEnd = viewStart + _scroll.position.viewportDimension;

    double? target;
    if (targetLeft < viewStart) target = targetLeft;
    if (targetRight > viewEnd) target = targetRight - _scroll.position.viewportDimension;

    if (target != null) {
      _scroll.animateTo(
        target.clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final tabWidth = compact ? _tabWidthCompact : _tabWidthNormal;
        final barHeight = compact ? _barHeightCompact : _barHeightNormal;
        final scheme = Theme.of(context).colorScheme;

        return Material(
          color: scheme.surfaceContainerLow,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: barHeight,
              child: Row(
                children: [
                  if (widget.onExitToMenu != null)
                    _IconBarButton(
                      icon: Icons.home_rounded,
                      onPressed: widget.onExitToMenu!,
                      tooltip: tr('В меню квеста'),
                    ),
                  if (widget.onExitToMenu != null)
                    Container(
                      width: 1,
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      color: scheme.outlineVariant.withOpacity(0.3),
                    ),
                  Expanded(
                    child: _TabScroller(
                      controller: _scroll,
                      tabs: widget.tabs,
                      activeTabId: widget.activeTabId,
                      tabWidth: tabWidth,
                      tabMargin: _tabMargin,
                      onSelect: widget.onSelect,
                      onClose: widget.onClose,
                      onContextAction: widget.onContextAction,
                    ),
                  ),
                  if (widget.onShowOverview != null)
                    _TabsOverviewButton(
                      count: widget.tabs.length,
                      onPressed: widget.onShowOverview!,
                    ),
                  if (widget.onTogglePin != null)
                    _IconBarButton(
                      icon: widget.isPinnedActive ? Icons.push_pin : Icons.push_pin_outlined,
                      onPressed: widget.onTogglePin!,
                      tooltip: widget.isPinnedActive ? tr('Открепить вкладку') : tr('Закрепить вкладку'),
                    ),
                  if (widget.onGuides != null)
                    _IconBarButton(
                      icon: Icons.menu_book_rounded,
                      onPressed: widget.onGuides!,
                      tooltip: tr('Гайды'),
                    ),
                  _IconBarButton(icon: Icons.add_rounded, onPressed: widget.onNewTab, tooltip: tr('Новая вкладка')),
                  if (widget.onCollapsePanes != null)
                    _IconBarButton(
                      icon: Icons.vertical_split_rounded,
                      onPressed: widget.onCollapsePanes!,
                      tooltip: tr('Свернуть панели'),
                    ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
// Скроллер + скользящий индикатор активной вкладки
// ============================================================================

class _TabScroller extends StatelessWidget {
  final ScrollController controller;
  final List<EditorTabData> tabs;
  final String? activeTabId;
  final double tabWidth;
  final double tabMargin;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final void Function(String, TabContextAction)? onContextAction;

  const _TabScroller({
    required this.controller,
    required this.tabs,
    required this.activeTabId,
    required this.tabWidth,
    required this.tabMargin,
    required this.onSelect,
    required this.onClose,
    required this.onContextAction,
  });

  @override
  Widget build(BuildContext context) {
    final slot = tabWidth + tabMargin * 2;
    final activeIndex = tabs.indexWhere((t) => t.id == activeTabId);
    final scheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      controller: controller,
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: SizedBox(
        // Ширину не фиксируем: вкладка меняет её через AnimatedContainer, и
        // зафиксированный слот отстаёт на кадр при смене compact-режима —
        // ряд оказывался шире контейнера (переполнение 42 px на вкладку).
        height: double.infinity,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Плашка активной вкладки: тот же цвет, что и у панели контента
            // снизу, без нижней границы — создаёт эффект "продолжения" вкладки.
            if (activeIndex != -1)
              Positioned(
                left: activeIndex * slot + tabMargin,
                top: 0,
                bottom: 0,
                width: tabWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    border: Border(
                      left: BorderSide(color: scheme.outlineVariant.withOpacity(0.7)),
                      right: BorderSide(color: scheme.outlineVariant.withOpacity(0.7)),
                      top: BorderSide(color: scheme.outlineVariant.withOpacity(0.7)),
                    ),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < tabs.length; i++) ...[
                  if (i > 0)
                    Center(
                      child: Container(
                        width: 1,
                        margin: const EdgeInsets.symmetric(vertical: 10),
                        color: scheme.outlineVariant.withOpacity(0.3),
                      ),
                    ),
                  _EditorTab(
                    key: ValueKey(tabs[i].id),
                    data: tabs[i],
                    width: tabWidth,
                    margin: tabMargin,
                    selected: tabs[i].id == activeTabId,
                    onFocus: () => onSelect(tabs[i].id),
                    onClose: () => onClose(tabs[i].id),
                    onContextAction: onContextAction == null ? null : (a) => onContextAction!(tabs[i].id, a),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Одна вкладка
// ============================================================================

class _EditorTab extends StatefulWidget {
  final EditorTabData data;
  final double width;
  final double margin;
  final bool selected;
  final VoidCallback onFocus;
  final VoidCallback onClose;
  final ValueChanged<TabContextAction>? onContextAction;

  const _EditorTab({
    super.key,
    required this.data,
    required this.width,
    required this.margin,
    required this.selected,
    required this.onFocus,
    required this.onClose,
    required this.onContextAction,
  });

  @override
  State<_EditorTab> createState() => _EditorTabState();
}

class _EditorTabState extends State<_EditorTab> {
  bool _hovered = false;

  void _showContextMenu(Offset globalPosition) {
    if (widget.onContextAction == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<TabContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: TabContextAction.close, child: Text(tr('Закрыть'))),
        PopupMenuItem(value: TabContextAction.closeOthers, child: Text(tr('Закрыть другие'))),
        PopupMenuItem(value: TabContextAction.closeToRight, child: Text(tr('Закрыть справа'))),
        PopupMenuItem(value: TabContextAction.closeAll, child: Text(tr('Закрыть все'))),
        PopupMenuDivider(),
        PopupMenuItem(value: TabContextAction.splitRight, child: Text(tr('Разделить справа'))),
        PopupMenuItem(value: TabContextAction.splitDown, child: Text(tr('Разделить снизу'))),
        PopupMenuDivider(),
        PopupMenuItem(value: TabContextAction.pinAsNewTab, child: Text(tr('Новая вкладка'))),
        PopupMenuItem(value: TabContextAction.togglePin, child: Text(tr('Закрепить/открепить'))),
      ],
    ).then((action) {
      if (action != null) widget.onContextAction!(action);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.data.accentColor ?? scheme.onSurfaceVariant;
    final titleColor = widget.selected ? scheme.onSurface : scheme.onSurfaceVariant;

    return Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse && event.buttons == kMiddleMouseButton) {
          widget.onClose();
        }
      },
      child: GestureDetector(
        onSecondaryTapDown: (details) => _showContextMenu(details.globalPosition),
        child: Tooltip(
          message: widget.data.subtitle == null
              ? widget.data.title
              : '${widget.data.title}\n${widget.data.subtitle}',
          waitDuration: const Duration(milliseconds: 500),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              width: widget.width,
              height: double.infinity,
              margin: EdgeInsets.symmetric(horizontal: widget.margin),
              decoration: BoxDecoration(
                color: widget.selected
                    ? Colors.transparent
                    : _hovered
                        ? scheme.surfaceContainerHigh.withOpacity(0.6)
                        : Colors.transparent,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),

              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onFocus,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10, right: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          widget.data.icon,
                          size: 17,
                          color: widget.selected ? accent : accent.withOpacity(0.75),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.data.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: titleColor,
                              fontWeight: widget.selected ? FontWeight.w500 : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (widget.data.isPinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: Icon(Icons.push_pin, size: 12, color: accent.withOpacity(0.9)),
                          ),
                        const SizedBox(width: 4),
                        _DirtyOrCloseButton(
                          isDirty: widget.data.isDirty,
                          showClose: _hovered || widget.selected,
                          onClose: widget.onClose,
                        ),
                        _MoreButton(
                          visible: _hovered,
                          onPressed: widget.onContextAction == null
                              ? null
                              : () {
                                  final box = context.findRenderObject() as RenderBox;
                                  final pos = box.localToGlobal(Offset(box.size.width, box.size.height));
                                  _showContextMenu(pos);
                                },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Точка "не сохранено", морфящаяся в крестик закрытия
// ============================================================================

class _DirtyOrCloseButton extends StatelessWidget {
  final bool isDirty;
  final bool showClose;
  final VoidCallback onClose;

  const _DirtyOrCloseButton({
    required this.isDirty,
    required this.showClose,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 18,
      height: 18,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 140),
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
        child: showClose
            ? _RoundIconButton(key: const ValueKey('close'), icon: Icons.close_rounded, onPressed: onClose)
            : isDirty
                ? Center(
                    key: const ValueKey('dot'),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('empty')),
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  final bool visible;
  final VoidCallback? onPressed;

  const _MoreButton({required this.visible, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    if (onPressed == null) return const SizedBox.shrink();
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: visible ? 1 : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: _RoundIconButton(icon: Icons.more_vert_rounded, onPressed: onPressed!),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _RoundIconButton({super.key, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 18,
          height: 18,
          child: Icon(icon, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

// ============================================================================
// Кнопки панели: + / свернуть панели / обзор вкладок
// ============================================================================

class _IconBarButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  const _IconBarButton({required this.icon, required this.onPressed, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, size: 19, color: scheme.onSurfaceVariant),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: tooltip == null ? button : Tooltip(message: tooltip!, child: button),
    );
  }
}

/// Кнопка обзора вкладок: открывает полноэкранный список всех открытых
/// вкладок (поиск, переход, закрытие) вместо тесного попап-меню.
class _TabsOverviewButton extends StatelessWidget {
  final int count;
  final VoidCallback onPressed;

  const _TabsOverviewButton({required this.count, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.grid_view_rounded,
                size: 19,
                color: scheme.onSurfaceVariant,
              ),
              Positioned(
                right: 2,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 9,
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(message: tr('Все вкладки'), child: button),
    );
  }
}
