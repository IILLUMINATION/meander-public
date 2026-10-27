import 'dart:async';

import 'package:canvas_app/features/market/providers/market_provider.dart';
import 'package:canvas_app/features/market/providers/recommendations_provider.dart';
import 'package:canvas_app/features/market/widgets/market_widgets.dart';
import 'package:canvas_app/features/market/widgets/partner_banner.dart';
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
                    if (isExpanded)
                      SizedBox(width: 320, child: _RightAside()),
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
    final isCompact = width < kCatalogCompactBreakpoint;
    final hPad = isCompact ? 16.0 : 24.0;

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        _buildAppBar(context, isFiltering),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 0),
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
          if (isCompact) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverToBoxAdapter(child: _CategoryChipsRow()),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 16)),

          // Hero — Выбор редакции
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Выбор редакции'),
              icon: Icons.auto_awesome_rounded,
              onSeeAll: () =>
                  ref.read(marketCategoryProvider.notifier).state = 'featured',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _FeaturedCarousel(provider: meanderRecommendsProvider),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Подобрано для вас
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Подобрано для вас'),
              icon: Icons.recommend_rounded,
              subtitle: tr('Микс из ваших жанров, авторов и трендов'),
              onSeeAll: () =>
                  ref.read(marketCategoryProvider.notifier).state = 'for_you',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _HorizontalQuestList(
              provider: personalRecommendsProvider,
              height: 215,
              cardWidth: 170,
              emptyHint:
                  tr('Откройте пару квестов, и мы соберём персональную ленту'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Партнёрский баннер №1
          const SliverToBoxAdapter(
            child: PartnerBannerSlot(
              slotId: 'market.top',
              format: PartnerBannerFormat.hero,
              padding: EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // В тренде
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('В тренде'),
              icon: Icons.trending_up_rounded,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _HorizontalQuestList(
              provider: marketQuestsProviderPopular,
              height: 215,
              cardWidth: 170,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Похожие на ваши любимые (опционально)
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
                        child: CatalogSectionHeader(
                          title: tr('Похожие на ваши любимые'),
                          icon: Icons.favorite_rounded,
                          subtitle: tr('На основе квестов, которые вы открывали'),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 12)),
                      SliverToBoxAdapter(
                        child: _HorizontalQuestList(
                          provider: similarToFavoritesProvider,
                          height: 215,
                          cardWidth: 170,
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  );
                },
              );
            },
          ),

          // Скрытые алмазы
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Скрытые алмазы'),
              icon: Icons.diamond_outlined,
              subtitle: tr('Малоизвестные квесты, которые стоит попробовать'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _HorizontalQuestList(
              provider: undiscoveredQuestsProvider,
              height: 215,
              cardWidth: 170,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Партнёрский баннер №2 (компактный)
          const SliverToBoxAdapter(
            child: PartnerBannerSlot(
              slotId: 'market.mid',
              format: PartnerBannerFormat.compact,
              padding: EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Демо-версии
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Демо-версии'),
              icon: Icons.science_outlined,
              subtitle: tr('Незаконченные квесты для тестов и отзывов'),
              onSeeAll: () =>
                  ref.read(marketCategoryProvider.notifier).state = 'demo',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _HorizontalQuestList(
              provider: demoQuestsProvider,
              height: 205,
              cardWidth: 160,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Последние действия (только если нет правой панели)
          if (width < kCatalogExpandedBreakpoint) ...[
            SliverToBoxAdapter(
              child: CatalogSectionHeader(
                title: tr('Последние действия'),
                icon: Icons.bolt_rounded,
                subtitle: tr('Лайки, отзывы и публикации в реальном времени'),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverToBoxAdapter(
              child: MarketRecentActivityFeed(
                provider: marketRecentActivityProvider,
                maxItems: 8,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],

          // Партнёрский баннер №3
          const SliverToBoxAdapter(
            child: PartnerBannerSlot(
              slotId: 'market.bottom',
              format: PartnerBannerFormat.hero,
              padding: EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],

        // Главный grid (скрываем заголовок и сетку, если уже показан блок ошибки выше)
        if (isFiltering || !mainQuestsAsync.hasError) ...[
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: isFiltering
                  ? (selectedCategory != null
                        ? _getCategoryTitle(selectedCategory)
                        : tr('Результаты поиска'))
                  : tr('Библиотека новинок'),
              icon: isFiltering
                  ? Icons.search_rounded
                  : Icons.new_releases_outlined,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (isFiltering)
            _buildSearchResultsGrid(width)
          else
            _buildMainGrid(width),
        ],

        const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
      ],
    );
  }

  SliverAppBar _buildAppBar(BuildContext context, bool isFiltering) {
    final showClear = isFiltering;
    return SliverAppBar(
      backgroundColor: Colors.transparent,
      floating: true,
      pinned: false,
      snap: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      toolbarHeight: 76,
      automaticallyImplyLeading: !widget.isRoot && !showClear,
      leading: showClear
          ? IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: tr('Сбросить фильтр'),
              onPressed: _clearFilters,
            )
          : null,
      titleSpacing: showClear ? 0 : 16,
      title: CatalogSearchField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        hintText: tr('Найти историю, автора, жанр…'),
        onChanged: (value) =>
            ref.read(marketSearchProvider.notifier).state = value,
        onClear: _clearSearch,
        onFilterTap: () => _openFiltersSheet(context),
      ),
      actions: const [],
    );
  }

  Widget _buildMainGrid(double width) {
    final questsAsync = ref.watch(marketQuestsProviderNew);
    return questsAsync.when(
      loading: () => CatalogGridShimmer(width: width),
      error: (e, _) => SliverToBoxAdapter(
        child: MarketErrorBlock(error: e, onRetry: _refreshAll),
      ),
      data: (quests) {
        final filtered = quests.where((q) => !q.isDemo).toList();
        return _QuestSliverGrid(quests: filtered, width: width);
      },
    );
  }

  Widget _buildSearchResultsGrid(double width) {
    final selectedCategory = ref.watch(marketCategoryProvider);
    final searchQuery = ref.watch(marketSearchProvider);

    if (selectedCategory == 'for_you') {
      final async = ref.watch(personalRecommendsProvider);
      return async.when(
        loading: () => CatalogGridShimmer(width: width),
        error: (e, _) => SliverToBoxAdapter(
          child: MarketErrorBlock(error: e, onRetry: _refreshAll),
        ),
        data: (quests) {
          if (quests.isEmpty) {
            return const SliverToBoxAdapter(child: MarketEmptyState());
          }
          return _QuestSliverGrid(quests: quests, width: width);
        },
      );
    }

    final questsAsync = ref.watch(filteredMarketQuestsProvider);
    return questsAsync.when(
      loading: () => CatalogGridShimmer(width: width),
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
        return _QuestSliverGrid(quests: list, width: width);
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
//  ЧИПЫ КАТЕГОРИЙ (компактный режим)
// ============================================================================

class _CategoryChipsRow extends ConsumerWidget {
  const _CategoryChipsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(marketCategoryProvider);

    final entries = <(String, String?, IconData)>[
      (tr('Все'), null, Icons.apps_rounded),
      (tr('Для вас'), 'for_you', Icons.recommend_rounded),
      (tr('Тренды'), 'trending', Icons.trending_up_rounded),
      (tr('Выбор'), 'featured', Icons.auto_awesome_rounded),
      (tr('Проверенные'), 'verified', Icons.verified_rounded),
      (tr('Демо'), 'demo', Icons.science_outlined),
      ...kMarketCategories.map(
        (c) => (
          translateCategory(c),
          c,
          categoryIcon(c),
        ),
      ),
    ];

    return CatalogCategoryChipsRow(
      entries: entries
          .map((e) => CatalogChipEntry(e.$1, e.$2, e.$3))
          .toList(),
      selected: selected,
      onSelected: (value) =>
          ref.read(marketCategoryProvider.notifier).state = value,
    );
  }
}

// ============================================================================
//  ГОРИЗОНТАЛЬНЫЙ СПИСОК
// ============================================================================

class _HorizontalQuestList extends ConsumerWidget {
  /// Все ленты — обычные FutureProvider, тип нужен чтобы на ошибке уметь
  /// дёрнуть ref.invalidate (ProviderListenable для этого не годится).
  final AutoDisposeFutureProvider<List<MarketQuest>> provider;
  final double height;
  final double cardWidth;
  final String? emptyHint;

  const _HorizontalQuestList({
    required this.provider,
    required this.height,
    required this.cardWidth,
    this.emptyHint,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: async.when(
        loading: () => Shimmer.fromColors(
          baseColor: scheme.surfaceContainerHigh,
          highlightColor: scheme.surfaceContainerHighest,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: false,
            itemCount: 4,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, __) => Container(
              width: cardWidth,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
        ),
        error: (_, __) => Padding(
          // Пустая лента без кнопки неотличима от «в этой подборке ничего нет»,
          // а причина чаще всего одна — не дошло до бэкенда.
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: MarketInlineHint(
            text: tr('Не удалось загрузить подборку'),
            onRetry: () => ref.invalidate(provider),
          ),
        ),
        data: (quests) {
          final isDemoSection = provider == demoQuestsProvider;
          final list = isDemoSection
              ? quests
              : quests.where((q) => !q.isDemo).toList();
          if (list.isEmpty) {
            if (emptyHint == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: MarketInlineHint(text: emptyHint!),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            scrollDirection: Axis.horizontal,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: false,
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) => RepaintBoundary(
              child: MarketQuestCard(quest: list[i], width: cardWidth),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
//  HERO-КАРУСЕЛЬ
// ============================================================================

class _FeaturedCarousel extends ConsumerWidget {
  final ProviderListenable<AsyncValue<List<MarketQuest>>> provider;
  const _FeaturedCarousel({required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    return SizedBox(
      height: 240,
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: CatalogShimmerCard(width: double.infinity),
        ),
        error: (_, __) => const SizedBox.shrink(),
        data: (quests) {
          final list = quests.where((q) => !q.isDemo).toList();
          if (list.isEmpty) return const SizedBox.shrink();
          return PageView.builder(
            controller: PageController(viewportFraction: 0.92),
            itemCount: list.length,
            physics: const BouncingScrollPhysics(),
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: RepaintBoundary(child: MarketHeroCard(quest: list[i])),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
//  СЕТКА КВЕСТОВ
// ============================================================================

class _QuestSliverGrid extends StatelessWidget {
  final List<MarketQuest> quests;
  final double width;

  const _QuestSliverGrid({required this.quests, required this.width});

  @override
  Widget build(BuildContext context) {
    return CatalogSliverGrid(
      itemCount: quests.length,
      width: width,
      itemBuilder: (context, i) =>
          RepaintBoundary(child: MarketQuestCard(quest: quests[i])),
    );
  }
}

