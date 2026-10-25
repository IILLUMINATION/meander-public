import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Один пункт навигации.
class NavBarItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;

  /// Опциональный бейдж — число для уведомлений (0 / null = не показывать).
  final int? badge;

  const NavBarItem({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.badge,
  });
}

/// Разкладка вкладок для узкой нижней панели (#150).
///
/// Семь безымянных иконок в ряд человек различает плохо, поэтому в панели
/// держим не больше [maxTiles] плиток, причём последняя — служебное «Ещё»:
/// всё, что не влезло, возвращается в [hidden] и открывается списком.
/// Индекс экрана у скрытой вкладки = `maxTiles - 1 + позиция в hidden`.
({List<NavBarItem> visible, List<NavBarItem> hidden}) foldNavBarTiles(
  List<NavBarItem> items, {
  int maxTiles = 5,
}) {
  if (items.length <= maxTiles) {
    return (visible: items, hidden: const <NavBarItem>[]);
  }
  final keep = maxTiles - 1;
  return (visible: items.sublist(0, keep), hidden: items.sublist(keep));
}

/// Кастомный bottom-nav с плавающим «пузырём» под активной вкладкой.
///
/// Особенности:
/// • только иконки + бейджи — не зависит от количества вкладок, нет overflow;
/// • «пузырь»-индикатор позади активной иконки плавно **скользит** между
///   позициями (`AnimatedPositioned` + `easeOutCubic`);
/// • активная иконка чуть увеличивается, неактивные затухают по альфе;
/// • при тапе — мягкая haptic-обратная связь.
///
/// Сколько вкладок показать и что вынести в «Ещё», решает вызывающий код —
/// см. [foldNavBarTiles].
class AnimatedNavBar extends StatelessWidget {
  final List<NavBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const AnimatedNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Жестовая навигация на Android не сообщает нижний inset — «пилюля»
    // рисуется поверх контента, поэтому добираем зазор под неё сами.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final gestureReserve =
        bottomInset == 0 && Theme.of(context).platform == TargetPlatform.android
        ? 24.0
        : 0.0;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        10 + bottomInset + gestureReserve,
      ),
      child: SizedBox(
        height: 64,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tileWidth = constraints.maxWidth / items.length;
            return Stack(
              children: [
                // Плавающий пузырь-индикатор.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutCubic,
                  left: tileWidth * currentIndex + (tileWidth - 56) / 2,
                  top: 4,
                  bottom: 4,
                  width: 56,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                // Ряд иконок.
                Row(
                  children: List.generate(items.length, (i) {
                    return Expanded(
                      child: _NavBarTile(
                        item: items[i],
                        isSelected: i == currentIndex,
                        onTap: () {
                          if (i != currentIndex) {
                            HapticFeedback.selectionClick();
                          }
                          onTap(i);
                        },
                      ),
                    );
                  }),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NavBarTile extends StatelessWidget {
  final NavBarItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavBarTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor = isSelected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    // Тап-зона совпадает с пузырём-индикатором: 56×56 со stadium-скруглением.
    return Center(
      child: SizedBox(
        width: 56,
        height: 56,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Tooltip(
              message: item.label,
              waitDuration: const Duration(milliseconds: 600),
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                // Иконка с плавным переключением outline → filled и масштабом.
                AnimatedScale(
                  scale: isSelected ? 1.1 : 1.0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: Icon(
                      isSelected ? (item.selectedIcon ?? item.icon) : item.icon,
                      key: ValueKey(isSelected),
                      color: iconColor,
                      size: 24,
                    ),
                  ),
                ),
                // Бейдж нотификаций.
                if (item.badge != null && item.badge! > 0)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.error,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: scheme.surface, width: 1.5),
                      ),
                      constraints: const BoxConstraints(minWidth: 16),
                      alignment: Alignment.center,
                      child: Text(
                        item.badge! > 99 ? '99+' : '${item.badge}',
                        style: TextStyle(
                          color: scheme.onError,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Тот же набор вкладок, но левой колонкой — для широкого окна.
///
/// Нижняя полоса на ПК отъедает высоту у канваса и стоит далеко от курсора,
/// поэтому на десктопе вкладки разворачиваются в рельсу: подписи видны всегда,
/// переключение — `Alt+1…9` (биндинг в `MenuScreen`).
class DesktopNavRail extends StatelessWidget {
  final List<NavBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Widget? header;

  const DesktopNavRail({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NavigationRail(
      extended: true,
      minExtendedWidth: 190,
      groupAlignment: -0.95,
      selectedIndex: currentIndex,
      onDestinationSelected: (index) {
        if (index != currentIndex) {
          HapticFeedback.selectionClick();
        }
        onTap(index);
      },
      backgroundColor: scheme.surface,
      indicatorColor: scheme.secondaryContainer,
      leading: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child:
            header ??
            Row(
              children: [
                Icon(Icons.explore_rounded, color: scheme.primary, size: 26),
                const SizedBox(width: 10),
                Text(
                  'Meander',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
      ),
      destinations: [
        for (final (index, item) in items.indexed)
          NavigationRailDestination(
            icon: _badge(context, item, Icon(item.icon, size: 22)),
            selectedIcon: _badge(
              context,
              item,
              Icon(item.selectedIcon ?? item.icon, size: 22),
            ),
            label: Text(
              item.label,
              style: TextStyle(
                fontWeight: index == currentIndex
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  Widget _badge(BuildContext context, NavBarItem item, Widget icon) {
    final count = item.badge ?? 0;
    if (count <= 0) return icon;
    return Badge.count(
      count: count,
      child: Padding(padding: const EdgeInsets.only(right: 6), child: icon),
    );
  }
}
