import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_repository.dart';
import 'package:canvas_app/features/profile/screens/rewards_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

// ============================================================================
//  ОФОРМЛЕНИЕ ПРОФИЛЯ — витрина косметики
//
//  Здесь нельзя рисовать свой цвет или загружать своё видео: предметы только
//  из каталога. Это осознанно — выдача права должна означать «у человека есть
//  вот ЭТО», а не «у человека есть произвольный набор пикселей». Плюс такой макет
//  целиком рендерится кодом и не требует хранилища ассетов.
// ============================================================================

class CosmeticsScreen extends ConsumerStatefulWidget {
  const CosmeticsScreen({super.key, required this.userId, this.initialSlot});

  final String userId;

  /// С какого слота открыть (например, «Изменить фон» ведёт сразу на обложки).
  final CosmeticSlot? initialSlot;

  @override
  ConsumerState<CosmeticsScreen> createState() => _CosmeticsScreenState();
}

class _CosmeticsScreenState extends ConsumerState<CosmeticsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: CosmeticSlot.values.length,
      vsync: this,
      initialIndex: widget.initialSlot?.index ?? 0,
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _equipSlot(CosmeticSlot slot, CosmeticDef? def) async {
    final my = ref.read(myCosmeticsProvider).valueOrNull ?? const MyCosmetics();
    if (def != null && !my.canEquip(def)) {
      await _showLockedInfo(def);
      return;
    }
    setState(() => _busy = true);
    try {
      await equipCosmetic(
        ref: ref,
        userId: widget.userId,
        next: my.equipped.withSlot(slot, def?.id),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(def == null ? tr('Снято') : trf('Надето: {p0}', {'p0': def.name}))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(serverErrorMessage(e)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showLockedInfo(CosmeticDef def) async {
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(def.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CosmeticPreview(def: def),
            const SizedBox(height: 12),
            Text(
              trf('Это оформление {p0}. Его выдают за победу в конкурсах, участие в событиях и промокодами. Как только право появится — предмет откроется здесь сам.', {'p0': def.tier.title.toLowerCase()}),
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Понятно')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final my = ref.watch(myCosmeticsProvider).valueOrNull ??
        const MyCosmetics();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Оформление профиля')),
        actions: [
          IconButton(
            tooltip: tr('Награды за активность'),
            icon: const Icon(Icons.card_giftcard_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RewardsScreen(),
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final slot in CosmeticSlot.values)
              Tab(
                text: slot.title,
                icon: Icon(_slotIcon(slot)),
                iconMargin: const EdgeInsets.only(bottom: 4),
              ),
          ],
        ),
      ),
      body: SafeArea(
        child: AdaptiveContent(
          maxWidth: 900,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  tr('Оформление видят все, кто зашёл на ваш профиль. В каждом слоте надет один предмет.'),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              if (my.granted.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(
                    children: [
                      Icon(
                        Icons.card_giftcard_rounded,
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        trf('Выдано предметов: {p0}', {'p0': my.granted.length}),
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_busy)
                LinearProgressIndicator(minHeight: 2, color: scheme.primary),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    for (final slot in CosmeticSlot.values)
                      _SlotGrid(
                        slot: slot,
                        my: my,
                        onPick: (def) => _equipSlot(slot, def),
                        onClear: () => _equipSlot(slot, null),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Адаптивная сетка предметов одного слота.
class _SlotGrid extends StatelessWidget {
  const _SlotGrid({
    required this.slot,
    required this.my,
    required this.onPick,
    required this.onClear,
  });

  final CosmeticSlot slot;
  final MyCosmetics my;
  final ValueChanged<CosmeticDef> onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final items = cosmeticsOfSlot(slot);
    final equipped = my.equipped.of(slot);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 220).floor().clamp(2, 5);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.82,
          ),
          itemCount: items.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return _CosmeticTile(
                name: tr('По умолчанию'),
                equipped: equipped == null,
                locked: false,
                tier: CosmeticTier.common,
                preview: _DefaultPreview(slot: slot),
                onTap: onClear,
              );
            }
            final def = items[index - 1];
            final owned = my.owns(def);
            return _CosmeticTile(
              name: def.name,
              equipped: equipped == def.id,
              locked: !owned,
              tier: def.tier,
              season: def.season,
              preview: CosmeticPreview(def: def),
              onTap: () => onPick(def),
            );
          },
        );
      },
    );
  }
}

class _CosmeticTile extends StatelessWidget {
  const _CosmeticTile({
    required this.name,
    required this.preview,
    required this.equipped,
    required this.locked,
    required this.tier,
    required this.onTap,
    this.season,
  });

  final String name;
  final Widget preview;
  final bool equipped;
  final bool locked;
  final CosmeticTier tier;
  final VoidCallback onTap;
  final String? season;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: equipped ? scheme.primary : scheme.outlineVariant,
            width: equipped ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    preview,
                    if (locked)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.45),
                          child: Center(
                            child: Icon(
                              Icons.lock_rounded,
                              color: Colors.white.withValues(alpha: 0.9),
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                    if (equipped)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check_rounded,
                            size: 14,
                            color: scheme.onPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: scheme.onSurface,
              ),
            ),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _tierColor(tier).withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    tier.title,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: _tierColor(tier),
                    ),
                  ),
                ),
                if (season != null) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: cosmeticSeasonLabel(season!),
                    child: Icon(
                      Icons.emoji_events_rounded,
                      size: 14,
                      color: scheme.tertiary,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Color _tierColor(CosmeticTier tier) => switch (tier) {
    CosmeticTier.common => const Color(0xFF6B7A90),
    CosmeticTier.rare => const Color(0xFF3D8FC7),
    CosmeticTier.epic => const Color(0xFF9A5CFF),
    CosmeticTier.legendary => const Color(0xFFE8A31B),
  };
}

/// Превью «По умолчанию» — как выглядит слот без предмета.
class _DefaultPreview extends StatelessWidget {
  const _DefaultPreview({required this.slot});

  final CosmeticSlot slot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Icon(
        _slotIcon(slot),
        size: 28,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    );
  }
}

IconData _slotIcon(CosmeticSlot slot) => switch (slot) {
  CosmeticSlot.banner => Icons.wallpaper_rounded,
  CosmeticSlot.background => Icons.landscape_rounded,
  CosmeticSlot.avatarFrame => Icons.radio_button_unchecked_rounded,
  CosmeticSlot.nameStyle => Icons.text_format_rounded,
  CosmeticSlot.effect => Icons.ac_unit_rounded,
};
