import 'dart:async';

import 'package:canvas_app/features/market/providers/market_provider.dart';
import 'package:canvas_app/features/market/providers/recommendations_provider.dart';
import 'package:canvas_app/features/market/widgets/market_widgets.dart';
import 'package:canvas_app/features/market/widgets/partner_banner.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:canvas_app/core/utils/count_format.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:canvas_app/plugin_host/plugin_slot_renderer.dart';
import 'package:canvas_app/shared/widgets/catalog_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

// ============================================================================
//  МАРКЕТ — Material You / Material 3 редизайн
// ============================================================================

String _getCategoryTitle(String cat) {
  switch (cat) {
    case 'best':
      return tr('Лучшие');
    case 'featured':
      return tr('Выбор редакции');
    case 'verified':
      return tr('Проверенные авторы');
    case 'trending':
      return tr('В тренде');
    case 'demo':
      return tr('Демо-версии');
    case 'for_you':
      return tr('Подобрано для вас');
    default:
      return translateCategory(cat);
  }
}

// ============================================================================
//  ОСНОВНОЙ ЭКРАН
// ============================================================================

class MarketScreen extends ConsumerStatefulWidget {
  final bool isRoot;

  const MarketScreen({super.key, this.isRoot = false});

  @override
  ConsumerState<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends ConsumerState<MarketScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    ref.invalidate(meanderRecommendsProvider);
    ref.invalidate(verifiedAuthorsQuestsProvider);
    ref.invalidate(marketQuestsProviderPopular);
    ref.invalidate(marketQuestsProviderNew);
    ref.invalidate(undiscoveredQuestsProvider);
    ref.invalidate(marketRecentActivityProvider);
    ref.invalidate(personalRecommendsProvider);
    ref.invalidate(similarToFavoritesProvider);
    final query = ref.read(marketSearchProvider);
    if (query.isNotEmpty) {
      ref.invalidate(searchQuestsProvider(query));
    }
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    ref.read(marketSearchProvider.notifier).state = '';
  }

  void _clearFilters() {
    _clearSearch();
    ref.read(marketCategoryProvider.notifier).state = null;
  }

  void _openFiltersSheet(BuildContext context) {
    showAdaptiveSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => MarketFiltersSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(marketSearchProvider);
    final selectedCategory = ref.watch(marketCategoryProvider);
    final isFiltering = searchQuery.isNotEmpty || selectedCategory != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isMedium = width >= kCatalogMediumBreakpoint;
        final isExpanded = width >= kCatalogExpandedBreakpoint;

        final mainColumnWidth = isExpanded
            ? width - 260 - 320
            : width - (isMedium ? 260 : 0);

        return PopScope(
          canPop: !isFiltering,
          onPopInvoked: (didPop) {
            if (didPop) return;
            _clearFilters();
          },
          child: Scaffold(
            body: SafeArea(
              bottom: false,
              child: RefreshIndicator(
                onRefresh: _refreshAll,
                child: Row(
                  children: [
                    if (isMedium)
                      SizedBox(
                        width: 260,
                        child: _DesktopRail(
                          onCategorySelected: (key) =>
                              ref.read(marketCategoryProvider.notifier).state =
                                  key,
                        ),
                      ),
                    Expanded(
                      child: _buildMainColumn(
                        context,
                        width: mainColumnWidth,
                        isFiltering: isFiltering,
                        selectedCategory: selectedCategory,
                      ),
                    ),
                    if (isExpanded) SizedBox(width: 320, child: _RightAside()),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMainColumn(
    BuildContext context, {
    required double width,
    required bool isFiltering,
    required String? selectedCategory,
  }) {
    final mainQuestsAsync = ref.watch(marketQuestsProviderNew);
    // Полка «Лучшие» — ручной отбор. Пока куратор никого не выбрал, секции
    // нет вовсе: пустая витрина обещала бы контент, которого ещё нет.
    final bestQuests =
        ref.watch(bestQuestsProvider).valueOrNull ?? const <MarketQuest>[];
    final total = mainQuestsAsync.valueOrNull?.length ?? 0;
    final isCompact = width < kCatalogCompactBreakpoint;
    // Читаемая колонка: на широком окне полка не растягивается.
    final hPad = width > 820 ? (width - 760) / 2 : (isCompact ? 16.0 : 24.0);

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 0),
            child: _MarketHeader(
              isRoot: widget.isRoot,
              isFiltering: isFiltering,
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: (value) =>
                  ref.read(marketSearchProvider.notifier).state = value,
              onClear: _clearSearch,
              onFilter: () => _openFiltersSheet(context),
              onCategory: (value) =>
                  ref.read(marketCategoryProvider.notifier).state = value,
              selectedCategory: selectedCategory,
              total: total,
              bestCount: bestQuests.length,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 0),
            child: PluginSlotRenderer(slotId: 'market.header'),
          ),
        ),

        if (!isFiltering && mainQuestsAsync.hasError)
          SliverToBoxAdapter(
            child: MarketErrorBlock(
              error: mainQuestsAsync.error,
              onRetry: _refreshAll,
            ),
          ),

        if (!isFiltering && !mainQuestsAsync.hasError) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 20)),

          // Hero — Выбор редакции
          SliverToBoxAdapter(
            child: _MarketSectionHeader(
              title: tr('Выбор редакции'),
              icon: Icons.auto_awesome_rounded,
              hPad: hPad,
              onSeeAll: () =>
                  ref.read(marketCategoryProvider.notifier).state = 'featured',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
          SliverToBoxAdapter(
            child: _MarketShelf(
              provider: meanderRecommendsProvider,
              hPad: hPad,
              hero: true,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),

          if (bestQuests.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _MarketSectionHeader(
                title: tr('Лучшие'),
                icon: Icons.workspace_premium_rounded,
                hPad: hPad,
                subtitle: tr('Отобраны вручную: только доделанные квесты'),
                onSeeAll: () =>
                    ref.read(marketCategoryProvider.notifier).state = 'best',
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 10)),
            SliverToBoxAdapter(
              child: _MarketShelf(provider: bestQuestsProvider, hPad: hPad),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 22)),
          ],

          SliverToBoxAdapter(
            child: _MarketSectionHeader(
              title: tr('Подобрано для вас'),
              icon: Icons.recommend_rounded,
              hPad: hPad,
              subtitle: tr('Микс из ваших жанров, авторов и трендов'),
              onSeeAll: () =>
                  ref.read(marketCategoryProvider.notifier).state = 'for_you',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
          SliverToBoxAdapter(
            child: _MarketShelf(
              provider: personalRecommendsProvider,
              hPad: hPad,
              emptyHint: tr(
                'Откройте пару квестов, и мы соберём персональную ленту',
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),

          const SliverToBoxAdapter(
            child: PartnerBannerSlot(
              slotId: 'market.top',
              format: PartnerBannerFormat.hero,
              padding: EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),

          SliverToBoxAdapter(
            child: _MarketSectionHeader(
              title: tr('В тренде'),
              icon: Icons.trending_up_rounded,
              hPad: hPad,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
          SliverToBoxAdapter(
            child: _MarketShelf(
              provider: marketQuestsProviderPopular,
              hPad: hPad,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),

          Consumer(
            builder: (context, ref, _) {
              final similar = ref.watch(similarToFavoritesProvider);
              return similar.when(
                loading: () =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
                error: (_, __) =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
                data: (list) {
                  if (list.isEmpty) {
                    return const SliverToBoxAdapter(child: SizedBox.shrink());
                  }
                  return SliverMainAxisGroup(
                    slivers: [
                      SliverToBoxAdapter(
                        child: _MarketSectionHeader(
                          title: tr('Похожие на ваши любимые'),
                          icon: Icons.favorite_rounded,
                          hPad: hPad,
                          subtitle: tr(
                            'На основе квестов, которые вы открывали',
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 10)),
                      SliverToBoxAdapter(
                        child: _MarketShelf(
                          provider: similarToFavoritesProvider,
                          hPad: hPad,
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 22)),
                    ],
                  );
                },
              );
            },
          ),

          SliverToBoxAdapter(
            child: _MarketSectionHeader(
              title: tr('Скрытые алмазы'),
              icon: Icons.diamond_outlined,
              hPad: hPad,
              subtitle: tr('Малоизвестные квесты, которые стоит попробовать'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
          SliverToBoxAdapter(
            child: _MarketShelf(
              provider: undiscoveredQuestsProvider,
              hPad: hPad,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),

          const SliverToBoxAdapter(
            child: PartnerBannerSlot(
              slotId: 'market.mid',
              format: PartnerBannerFormat.compact,
              padding: EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),

          SliverToBoxAdapter(
            child: _MarketSectionHeader(
              title: tr('Демо-версии'),
              icon: Icons.science_outlined,
              hPad: hPad,
              subtitle: tr('Незаконченные квесты для тестов и отзывов'),
              onSeeAll: () =>
                  ref.read(marketCategoryProvider.notifier).state = 'demo',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
          SliverToBoxAdapter(
            child: _MarketShelf(
              provider: demoQuestsProvider,
              hPad: hPad,
              showDemo: true,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),

          if (width < kCatalogExpandedBreakpoint) ...[
            SliverToBoxAdapter(
              child: _MarketSectionHeader(
                title: tr('Последние действия'),
                icon: Icons.bolt_rounded,
                hPad: hPad,
                subtitle: tr('Лайки, отзывы и публикации в реальном времени'),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 10)),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: hPad),
                child: MarketRecentActivityFeed(
                  provider: marketRecentActivityProvider,
                  maxItems: 8,
                  horizontalPadding: 0,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 22)),
          ],

          const SliverToBoxAdapter(
            child: PartnerBannerSlot(
              slotId: 'market.bottom',
              format: PartnerBannerFormat.hero,
              padding: EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),
        ],

        if (isFiltering || !mainQuestsAsync.hasError) ...[
          SliverToBoxAdapter(
            child: _MarketSectionHeader(
              title: isFiltering
                  ? (selectedCategory != null
                        ? _getCategoryTitle(selectedCategory)
                        : tr('Результаты поиска'))
                  : tr('Библиотека новинок'),
              icon: isFiltering
                  ? Icons.search_rounded
                  : Icons.new_releases_outlined,
              hPad: hPad,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 4)),
          if (isFiltering)
            _buildSearchResultsList(hPad)
          else
            _buildMainList(hPad),
        ],

        const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
      ],
    );
  }

  Widget _buildMainList(double hPad) {
    final questsAsync = ref.watch(marketQuestsProviderNew);
    return questsAsync.when(
      loading: () => _MarketRowsShimmer(hPad: hPad),
      error: (e, _) => SliverToBoxAdapter(
        child: MarketErrorBlock(error: e, onRetry: _refreshAll),
      ),
      data: (quests) {
        final filtered = quests.where((q) => !q.isDemo).toList();
        if (filtered.isEmpty) {
          return const SliverToBoxAdapter(child: MarketEmptyState());
        }
        return _MarketQuestList(quests: filtered, hPad: hPad);
      },
    );
  }

  Widget _buildSearchResultsList(double hPad) {
    final selectedCategory = ref.watch(marketCategoryProvider);
    final searchQuery = ref.watch(marketSearchProvider);

    if (selectedCategory == 'for_you') {
      final async = ref.watch(personalRecommendsProvider);
      return async.when(
        loading: () => _MarketRowsShimmer(hPad: hPad),
        error: (e, _) => SliverToBoxAdapter(
          child: MarketErrorBlock(error: e, onRetry: _refreshAll),
        ),
        data: (quests) {
          if (quests.isEmpty) {
            return const SliverToBoxAdapter(child: MarketEmptyState());
          }
          return _MarketQuestList(quests: quests, hPad: hPad);
        },
      );
    }

    final questsAsync = ref.watch(filteredMarketQuestsProvider);
    return questsAsync.when(
      loading: () => _MarketRowsShimmer(hPad: hPad),
      error: (e, _) => SliverToBoxAdapter(
        child: MarketErrorBlock(error: e, onRetry: _refreshAll),
      ),
      data: (quests) {
        final list = visibleMarketQuests(
          quests: quests,
          searchQuery: searchQuery,
          selectedCategory: selectedCategory,
        );
        if (list.isEmpty) {
          return const SliverToBoxAdapter(child: MarketEmptyState());
        }
        return _MarketQuestList(quests: list, hPad: hPad);
      },
    );
  }
}

// ============================================================================
//  ЛЕВАЯ НАВИГАЦИОННАЯ ПАНЕЛЬ
// ============================================================================

class _DesktopRail extends ConsumerWidget {
  final ValueChanged<String?> onCategorySelected;

  const _DesktopRail({required this.onCategorySelected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(marketCategoryProvider);

    final special = <(String, String?, IconData)>[
      (tr('Главная'), null, Icons.home_rounded),
      (tr('Лучшие'), 'best', Icons.workspace_premium_rounded),
      (tr('Для вас'), 'for_you', Icons.recommend_rounded),
      (tr('Выбор редакции'), 'featured', Icons.auto_awesome_rounded),
      (tr('В тренде'), 'trending', Icons.trending_up_rounded),
      (tr('Проверенные'), 'verified', Icons.verified_rounded),
      (tr('Демо'), 'demo', Icons.science_outlined),
    ];

    return Container(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CatalogRailHeader(
            icon: Icons.storefront_rounded,
            title: tr('Маркет'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                ...special.map(
                  (e) => CatalogRailTile(
                    label: e.$1,
                    icon: e.$3,
                    isSelected: selected == e.$2,
                    onTap: () => onCategorySelected(e.$2),
                  ),
                ),
                const SizedBox(height: 14),
                CatalogRailGroupLabel(label: tr('Жанры')),
                ...kMarketCategories.map(
                  (c) => CatalogRailTile(
                    label: translateCategory(c),
                    icon: categoryIcon(c),
                    isSelected: selected == c,
                    onTap: () => onCategorySelected(c),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  ПРАВАЯ БОКОВАЯ ПАНЕЛЬ (sticky)
// ============================================================================

class _RightAside extends ConsumerWidget {
  const _RightAside();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const PartnerBannerSlot(
            slotId: 'market.sidebar',
            format: PartnerBannerFormat.sidebar,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 24),
          Text(
            tr('Последние действия'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          MarketRecentActivityFeed(
            provider: marketRecentActivityProvider,
            maxItems: 8,
            horizontalPadding: 0,
          ),
          const SizedBox(height: 24),
          const PartnerBannerSlot(
            slotId: 'market.sidebar',
            format: PartnerBannerFormat.sidebar,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ============================================================================
//  ШАПКА, ПОИСК, ТАБЫ
// ============================================================================

class _MarketHeader extends StatelessWidget {
  final bool isRoot;
  final bool isFiltering;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onFilter;
  final ValueChanged<String?> onCategory;
  final String? selectedCategory;
  final int total;
  final int bestCount;

  const _MarketHeader({
    required this.isRoot,
    required this.isFiltering,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    required this.onFilter,
    required this.onCategory,
    required this.selectedCategory,
    required this.total,
    required this.bestCount,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[
      '$total ${trp(['квест', 'квеста', 'квестов'], total)}',
      if (bestCount > 0) '${tr('Лучшие')}: $bestCount',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isRoot)
              IconButton(
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: tr('Назад'),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Маркет'),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    parts.join(' · '),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: tr('Фильтры'),
              child: Material(
                color: scheme.surfaceContainerHigh,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onFilter,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _MarketSearchField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          onClear: onClear,
          onFilter: onFilter,
        ),
        const SizedBox(height: 4),
        _MarketFilterTabs(selected: selectedCategory, onSelected: onCategory),
      ],
    );
  }
}

class _MarketSearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onFilter;

  const _MarketSearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    required this.onFilter,
  });

  @override
  State<_MarketSearchField> createState() => _MarketSearchFieldState();
}

class _MarketSearchFieldState extends State<_MarketSearchField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = widget.controller.text.isNotEmpty;
    return SizedBox(
      height: 52,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Row(
          children: [
            const SizedBox(width: 16),
            Icon(
              Icons.search_rounded,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                style: TextStyle(color: scheme.onSurface, fontSize: 15),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: tr('Найти историю, автора, жанр…'),
                  hintStyle: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 15,
                  ),
                ),
                textInputAction: TextInputAction.search,
                onChanged: widget.onChanged,
              ),
            ),
            if (hasText)
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: tr('Очистить'),
                onPressed: widget.onClear,
              )
            else
              IconButton(
                icon: const Icon(Icons.tune_rounded),
                tooltip: tr('Фильтры'),
                onPressed: widget.onFilter,
              ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

class _MarketFilterTabs extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onSelected;

  const _MarketFilterTabs({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = <(String, String?, IconData)>[
      (tr('Все'), null, Icons.apps_rounded),
      (tr('Лучшие'), 'best', Icons.workspace_premium_rounded),
      (tr('Для вас'), 'for_you', Icons.recommend_rounded),
      (tr('Тренды'), 'trending', Icons.trending_up_rounded),
      (tr('Выбор'), 'featured', Icons.auto_awesome_rounded),
      (tr('Проверенные'), 'verified', Icons.verified_rounded),
      (tr('Демо'), 'demo', Icons.science_outlined),
      ...kMarketCategories.map(
        (c) => (translateCategory(c), c, categoryIcon(c)),
      ),
    ];

    // Табы-подчёркивания вместо «пилюль»: строка остаётся спокойной,
    // активная грань читается по подчёркиванию, а не по заливке.
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 18),
        itemBuilder: (context, i) {
          final entry = entries[i];
          final isSelected = selected == entry.$2;
          final color = isSelected ? scheme.primary : scheme.onSurfaceVariant;
          return InkWell(
            onTap: () => onSelected(entry.$2),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.only(top: 10, bottom: 7),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    width: 2,
                    color: isSelected ? scheme.primary : Colors.transparent,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.$3, size: 15, color: color),
                  const SizedBox(width: 6),
                  Text(
                    entry.$1,
                    style: TextStyle(
                      color: color,
                      fontWeight: isSelected
                          ? FontWeight.w800
                          : FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
//  СЕКЦИИ
// ============================================================================

class _MarketSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final double hPad;
  final VoidCallback? onSeeAll;

  const _MarketSectionHeader({
    required this.title,
    required this.icon,
    required this.hPad,
    this.subtitle,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Капс-надпись с линией, как в библиотеке: без квадратной плашки,
    // которая дублировала подпись и спорила с обложками.
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              const SizedBox(width: 10),
              if (onSeeAll != null)
                InkWell(
                  onTap: onSeeAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Text(
                      tr('Все'),
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                )
              else
                Icon(icon, size: 15, color: scheme.onSurfaceVariant),
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                subtitle!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _MarketShelf extends ConsumerWidget {
  final AutoDisposeFutureProvider<List<MarketQuest>> provider;
  final double hPad;
  final bool hero;
  final bool showDemo;
  final String? emptyHint;

  const _MarketShelf({
    required this.provider,
    required this.hPad,
    this.hero = false,
    this.showDemo = false,
    this.emptyHint,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    final scheme = Theme.of(context).colorScheme;
    final height = hero ? 190.0 : 230.0;
    final width = hero ? 300.0 : 160.0;
    return SizedBox(
      height: height,
      child: async.when(
        loading: () => Shimmer.fromColors(
          baseColor: scheme.surfaceContainerHigh,
          highlightColor: scheme.surfaceContainerHighest,
          child: ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: hero ? 2 : 4,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, _) => Container(
              width: width,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        error: (_, _) => Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: MarketInlineHint(
            text: tr('Не удалось загрузить подборку'),
            onRetry: () => ref.invalidate(provider),
          ),
        ),
        data: (quests) {
          final list = showDemo
              ? quests
              : quests.where((q) => !q.isDemo).toList();
          if (list.isEmpty) {
            if (emptyHint == null) return const SizedBox.shrink();
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: hPad),
              child: MarketInlineHint(text: emptyHint!),
            );
          }
          return ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            scrollDirection: Axis.horizontal,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: false,
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) => RepaintBoundary(
              child: SizedBox(
                width: width,
                child: hero
                    ? MarketHeroCard(quest: list[i])
                    : MarketQuestCard(quest: list[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
//  СПИСОК КВЕСТОВ
// ============================================================================

class _MarketQuestList extends StatelessWidget {
  final List<MarketQuest> quests;
  final double hPad;

  const _MarketQuestList({required this.quests, required this.hPad});

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      sliver: SliverList.separated(
        itemCount: quests.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _MarketQuestRow(quest: quests[i]),
      ),
    );
  }
}

class _MarketQuestRow extends ConsumerWidget {
  final MarketQuest quest;

  const _MarketQuestRow({required this.quest});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final category = quest.genres.isNotEmpty
        ? translateCategory(quest.genres.first)
        : translateCategory(quest.category);
    return InkWell(
      onTap: () {
        ref.read(recentlyViewedQuestsProvider.notifier).push(quest.id);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => QuestMarketDetailsScreen(quest: quest),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 60,
                height: 84,
                child: MarketCoverImage(
                  url: quest.previewImageUrl,
                  fallbackColor: scheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          quest.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (quest.isBest)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: MarketBadge(
                            label: tr('Лучшие'),
                            background: scheme.primaryContainer,
                            foreground: scheme.onPrimaryContainer,
                          ),
                        ),
                      if (quest.isDemo)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: MarketBadge(
                            label: tr('ДЕМО'),
                            background: scheme.errorContainer,
                            foreground: scheme.onErrorContainer,
                          ),
                        ),
                      if (quest.isNsfw)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: MarketBadge(
                            label: '18+',
                            background: scheme.error,
                            foreground: scheme.onError,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (quest.authorName != null &&
                          quest.authorName!.isNotEmpty)
                        Flexible(
                          child: CosmeticNameText(
                            name: quest.authorName!,
                            def: cosmeticById(quest.authorNameStyle),
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      if (category.isNotEmpty) ...[
                        if (quest.authorName != null &&
                            quest.authorName!.isNotEmpty)
                          Text(
                            '  ·  ',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        Flexible(
                          child: Text(
                            category,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 14,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _RowMetric(
                        icon: Icons.star_rounded,
                        color: scheme.primary,
                        text: quest.averageRating.toStringAsFixed(1),
                      ),
                      _RowMetric(
                        icon: Icons.download_rounded,
                        color: scheme.onSurfaceVariant,
                        text: formatCount(quest.downloadsCount),
                      ),
                      _RowMetric(
                        icon: Icons.visibility_rounded,
                        color: scheme.onSurfaceVariant,
                        text: formatCount(quest.viewsCount),
                        semanticLabel: tr('Просмотры'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowMetric extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final String? semanticLabel;

  const _RowMetric({
    required this.icon,
    required this.color,
    required this.text,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MarketRowsShimmer extends StatelessWidget {
  final double hPad;

  const _MarketRowsShimmer({required this.hPad});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      sliver: SliverList.separated(
        itemCount: 6,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, _) => Shimmer.fromColors(
          baseColor: scheme.surfaceContainerHigh,
          highlightColor: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 84,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: 220,
                        color: scheme.surfaceContainerHigh,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 11,
                        width: 140,
                        color: scheme.surfaceContainerHigh,
                      ),
                      const SizedBox(height: 12),
                      Container(
                        height: 11,
                        width: 100,
                        color: scheme.surfaceContainerHigh,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
