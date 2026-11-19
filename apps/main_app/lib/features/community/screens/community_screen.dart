import 'package:canvas_app/features/editor/workspace/editor_screen_tabs.dart';
import 'package:canvas_app/features/community/models/community_user_model.dart';
import 'package:canvas_app/features/community/providers/community_feed_provider.dart';
import 'package:canvas_app/features/community/providers/community_users_provider.dart';
import 'package:canvas_app/features/community/screens/post_comments_screen.dart';
import 'package:canvas_app/features/forums/models/forum_models.dart';
import 'package:canvas_app/features/forums/providers/forum_provider.dart';
import 'package:canvas_app/features/forums/screens/forum_lobby_screen.dart';
import 'package:canvas_app/features/forums/screens/forums_catalog_screen.dart';
import 'package:canvas_app/features/forums/widgets/forum_topic_tile.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/wall/widgets/post_card.dart';
import 'package:canvas_app/features/wall/screens/create_post_screen.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/load_more_error_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';

// ============================================================================
//  СООБЩЕСТВО — Material 3 редизайн
//  Согласован визуально с market_screen.dart и profile_screen.dart:
//  крупный SliverAppBar, секционные хедеры, FilterChip-ряд для фильтра топа,
//  shimmer-скелетоны для loading, аккуратные empty/error блоки.
//  На ПК (width >= 900): боковая панель с онлайном и топ-авторами.
// ============================================================================

const double kCommunityMediumBreakpoint = 900;
const double kCommunitySidebarWidth = 320;

class CommunityScreen extends ConsumerStatefulWidget {
  const CommunityScreen({super.key});

  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  final ScrollController _scrollController = ScrollController();
  String _feedFilter = 'all'; // 'all' | 'following'
  String _topFilter = 'followers'; // 'followers' | 'likes' | 'quests'

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _showCreatePostBottomSheet(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final localId = prefs.getString('user_id');
    if (localId == null || localId.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Необходимо войти в аккаунт'))),
        );
      }
      return;
    }

    if (!context.mounted) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CreatePostScreen()),
    );

    if (result == true && mounted) {
      _refreshAll();
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(communityFeedProvider(_feedFilter).notifier).loadMore();
    }
  }

  Future<void> _refreshAll() async {
    ref.invalidate(communityOnlineProvider);
    ref.invalidate(communityTopProvider(_topFilter));
    ref.invalidate(forumHotTopicsProvider);
    await ref.read(communityFeedProvider(_feedFilter).notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final showSidebar = width >= kCommunityMediumBreakpoint;

        if (showSidebar) {
          return _buildDesktopLayout(context, scheme);
        }
        return _buildMobileLayout(context, scheme);
      },
    );
  }

  // --------------------------------------------------------------------------
  //  Desktop layout: feed + right sidebar
  // --------------------------------------------------------------------------
  Widget _buildDesktopLayout(BuildContext context, ColorScheme scheme) {
    return Scaffold(
      backgroundColor: scheme.surface,
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        onPressed: () => _showCreatePostBottomSheet(context, ref),
        child: const Icon(Icons.add_rounded),
      ),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refreshAll,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Основная лента
              Expanded(child: _buildFeedColumn(context, scheme)),
              // Боковая панель
              SizedBox(
                width: kCommunitySidebarWidth,
                child: _buildDesktopSidebar(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeedColumn(BuildContext context, ColorScheme scheme) {
    return CustomScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverAppBar.large(
          title: Text(tr('Сообщество')),
          pinned: true,
          backgroundColor: scheme.surface,
          surfaceTintColor: scheme.surfaceTint,
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        SliverToBoxAdapter(child: _buildForumsEntry(context)),
        SliverToBoxAdapter(child: _buildFeedHeader(context)),
        const SliverToBoxAdapter(child: SizedBox(height: 4)),
        ..._buildFeedOnly(context),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _buildDesktopSidebar(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 116, bottom: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildOnlineSection(context),
          const SizedBox(height: 24),
          _buildTopAuthorsSection(context),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  Mobile layout: single-column with blocks injected between posts
  // --------------------------------------------------------------------------
  Widget _buildMobileLayout(BuildContext context, ColorScheme scheme) {
    return Scaffold(
      backgroundColor: scheme.surface,
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        onPressed: () => _showCreatePostBottomSheet(context, ref),
        child: const Icon(Icons.add_rounded),
      ),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refreshAll,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverAppBar.large(
                title: Text(tr('Сообщество')),
                pinned: true,
                backgroundColor: scheme.surface,
                surfaceTintColor: scheme.surfaceTint,
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
              SliverToBoxAdapter(child: _buildForumsEntry(context)),
              SliverToBoxAdapter(child: _buildFeedHeader(context)),
              const SliverToBoxAdapter(child: SizedBox(height: 4)),
              ..._buildFeedWithInjectedBlocks(context),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  Section header (универсальный)
  // --------------------------------------------------------------------------
  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    String? subtitle,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  Online users
  // --------------------------------------------------------------------------
  Widget _buildOnlineSection(BuildContext context) {
    final onlineAsync = ref.watch(communityOnlineProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          context,
          title: tr('Активны на этой неделе'),
          subtitle: onlineAsync.maybeWhen(
            data: (u) => u.isEmpty
                ? null
                : trf('{n} участников за неделю', {'n': u.length}),
            orElse: () => null,
          ),
        ),
        SizedBox(
          height: 108,
          child: onlineAsync.when(
            data: (users) {
              if (users.isEmpty) {
                return _inlineHint(context, tr('За неделю тут никого не было'));
              }
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: users.length,
                itemBuilder: (context, index) =>
                    CommunityOnlineTile(user: users[index]),
              );
            },
            loading: () => _shimmerOnlineRow(context),
            error: (e, _) => _inlineHint(context, tr('Не удалось загрузить')),
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  //  Top authors
  // --------------------------------------------------------------------------
  Widget _buildTopAuthorsSection(BuildContext context) {
    final topAsync = ref.watch(communityTopProvider(_topFilter));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          context,
          title: tr('Топ авторов'),
          subtitle: tr('Лидеры сообщества'),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _topFilterChip(
                'followers',
                tr('По подпискам'),
                Icons.person_add_alt_1_rounded,
              ),
              const SizedBox(width: 8),
              _topFilterChip('likes', tr('По лайкам'), Icons.favorite_rounded),
              const SizedBox(width: 8),
              _topFilterChip(
                'quests',
                tr('По квестам'),
                Icons.auto_stories_rounded,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 196,
          child: topAsync.when(
            data: (users) {
              if (users.isEmpty) {
                return _inlineHint(context, tr('Здесь пока никого нет'));
              }
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: users.length,
                itemBuilder: (context, index) =>
                    _buildTopAuthorCard(context, users[index], index),
              );
            },
            loading: () => _shimmerTopAuthorsRow(context),
            error: (e, _) => _inlineHint(context, tr('Не удалось загрузить')),
          ),
        ),
      ],
    );
  }

  Widget _topFilterChip(String value, String label, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _topFilter == value;
    return FilterChip(
      selected: selected,
      onSelected: (_) => setState(() => _topFilter = value),
      avatar: Icon(
        icon,
        size: 16,
        color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      ),
      label: Text(label),
      labelStyle: TextStyle(
        fontWeight: FontWeight.w600,
        color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
      ),
      showCheckmark: false,
      side: BorderSide(
        color: selected ? Colors.transparent : scheme.outlineVariant,
      ),
      backgroundColor: scheme.surface,
      selectedColor: scheme.secondaryContainer,
    );
  }

  Widget _buildTopAuthorCard(
    BuildContext context,
    CommunityUser user,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isPodium = index < 3;
    final podiumColor = switch (index) {
      0 => const Color(0xFFFFD54F), // gold
      1 => const Color(0xFFB0BEC5), // silver
      2 => const Color(0xFFBCAAA4), // bronze
      _ => scheme.surfaceContainerHighest,
    };
    final metricLabel = _topFilter == 'followers'
        ? tr('подписч.')
        : _topFilter == 'likes'
        ? tr('лайков')
        : tr('квестов');
    return Container(
      width: 156,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => EditorScreenTabs.openProfile(context, user.id),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isPodium
                            ? podiumColor.withOpacity(0.25)
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '#${index + 1}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                          color: isPodium
                              ? podiumColor
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (user.streakCount != null && user.streakCount! > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('🔥', style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 2),
                          Text(
                            '${user.streakCount}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Center(
                  child: CosmeticAvatar(
                    frame: cosmeticById(user.equipped.avatarFrame),
                    radius: 30,
                    avatarUrl: user.avatarUrl,
                    placeholderColor: scheme.primaryContainer,
                  ),
                ),
                const SizedBox(height: 10),
                CosmeticNameText(
                  name: user.fullName,
                  def: cosmeticById(user.nameStyle),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${user.metricCount ?? 0} $metricLabel',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  Вход в форумы
  // --------------------------------------------------------------------------
  /// Сообщество выросло из одной ленты: у тем и у квестов теперь свои полки.
  /// Вход держим карточкой над лентой, а не пятой вкладкой — иначе оболочка
  /// начинает конкурировать с самим содержимым.
  Widget _buildForumsEntry(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ForumsCatalogScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.groups_rounded,
                    color: scheme.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Сообщества'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tr('Форумы по темам и обсуждение каждого квеста'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  Обсуждения из сообществ
  // --------------------------------------------------------------------------
  /// Лента — это стена постов, и разговора в ней не было видно: топик живёт на
  /// своей полке, а до каталога сообществ человек либо не дошёл, либо забыл.
  /// Поэтому несколько горяжих тем встают прямо между постами.
  ///
  /// `null` — блока просто нет: обсуждений может не быть ни у кого, и
  /// показывать пустую секцию (или ошибку на ровном месте) вместо ленты
  /// смысла нет.
  Widget? _discussionsSliver(BuildContext context) {
    final hot = ref.watch(forumHotTopicsProvider);
    if (!hot.loaded || hot.topics.isEmpty) return null;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 24),
        child: _buildDiscussionsSection(context, hot.topics),
      ),
    );
  }

  Widget _buildDiscussionsSection(
    BuildContext context,
    List<ForumHotTopic> items,
  ) {
    final shown = items.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          context,
          title: tr('Обсуждают'),
          subtitle: tr('Темы из сообществ за две недели'),
          trailing: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ForumsCatalogScreen()),
            ),
            child: Text(tr('Все сообщества')),
          ),
        ),
        for (final item in shown)
          ForumTopicTile(
            key: ValueKey('feed-topic-${item.topic.id}'),
            topic: item.topic,
            communityName: item.forumName,
            onOpenCommunity: () => _openFeedCommunity(item),
            onOpen: () => _openFeedTopic(item),
            onLike: () =>
                ref.read(forumHotTopicsProvider.notifier).toggleLike(item),
          ),
      ],
    );
  }

  void _openFeedCommunity(ForumHotTopic item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ForumLobbyScreen(slug: item.forumSlug)),
    );
  }

  Future<void> _openFeedTopic(ForumHotTopic item) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostCommentsScreen(
          post: item.topic.toWallPost(),
          // Топик в ленте оторван от своей полки: без подписи человек не
          // понимает, чей это разговор, и не может в неё вернуться.
          communityLabel: item.forumName,
          onOpenCommunity: () => _openFeedCommunity(item),
        ),
      ),
    );
    if (!mounted) return;
    // В треде ответили или сняли лайк — карточка в ленте должна сойтись с
    // сервером сразу, а не врать до ближайшего pull-to-refresh.
    ref.invalidate(forumHotTopicsProvider);
  }

  // --------------------------------------------------------------------------
  //  Feed
  // --------------------------------------------------------------------------
  Widget _buildFeedHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tr('Лента активности'),
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'all', label: Text(tr('Все'))),
              ButtonSegment(value: 'following', label: Text(tr('Подписки'))),
            ],
            selected: {_feedFilter},
            onSelectionChanged: (set) =>
                setState(() => _feedFilter = set.first),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFeedWithInjectedBlocks(BuildContext context) {
    final state = ref.watch(communityFeedProvider(_feedFilter));
    final posts = state.posts;
    final discussions = _discussionsSliver(context);

    if (state.isLoading && posts.isEmpty) {
      return [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, __) => _shimmerPostCard(context),
            childCount: 3,
          ),
        ),
        SliverToBoxAdapter(child: const SizedBox(height: 24)),
        SliverToBoxAdapter(child: _buildOnlineSection(context)),
        SliverToBoxAdapter(child: const SizedBox(height: 24)),
        SliverToBoxAdapter(child: _buildTopAuthorsSection(context)),
        ?discussions,
      ];
    }

    if (state.error != null && posts.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _errorBlock(
            context,
            title: tr('Не удалось загрузить ленту'),
            detail: '${state.error}',
            onRetry: () =>
                ref.read(communityFeedProvider(_feedFilter).notifier).refresh(),
          ),
        ),
      ];
    }

    if (posts.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _emptyBlock(
            context,
            icon: Icons.dynamic_feed_rounded,
            title: tr('Лента пуста'),
            subtitle: _feedFilter == 'following'
                ? tr('Подпишитесь на авторов, чтобы видеть их посты здесь')
                : tr('Скоро здесь появятся новые посты сообщества'),
          ),
        ),
        SliverToBoxAdapter(child: const SizedBox(height: 24)),
        SliverToBoxAdapter(child: _buildOnlineSection(context)),
        SliverToBoxAdapter(child: const SizedBox(height: 24)),
        SliverToBoxAdapter(child: _buildTopAuthorsSection(context)),
        ?discussions,
      ];
    }

    // Инъекция блоков:
    // После 2-го поста (индекс 1) -> _buildOnlineSection
    // После 5-го поста (индекс 4) -> _buildTopAuthorsSection
    // Если постов меньше, блоки ставятся в конец.
    final slivers = <Widget>[];

    // Первая порция постов (до 2 штук)
    final chunk1Count = posts.length > 2 ? 2 : posts.length;
    if (chunk1Count > 0) {
      slivers.add(_buildPostSliverList(posts.sublist(0, chunk1Count)));
    }

    // Инъекция "Онлайн"
    slivers.add(SliverToBoxAdapter(child: const SizedBox(height: 24)));
    slivers.add(SliverToBoxAdapter(child: _buildOnlineSection(context)));
    slivers.add(SliverToBoxAdapter(child: const SizedBox(height: 24)));

    // Инъекция "Обсуждают" — сразу после онлайна: здесь человек уже
    // притормозил, и разговор показывать вовремя.
    if (discussions != null) slivers.add(discussions);

    // Вторая порция постов (с 3-го по 5-й)
    if (posts.length > 2) {
      final chunk2End = posts.length > 5 ? 5 : posts.length;
      slivers.add(_buildPostSliverList(posts.sublist(2, chunk2End)));
    }

    // Инъекция "Топ авторов"
    slivers.add(SliverToBoxAdapter(child: const SizedBox(height: 24)));
    slivers.add(SliverToBoxAdapter(child: _buildTopAuthorsSection(context)));
    slivers.add(SliverToBoxAdapter(child: const SizedBox(height: 24)));

    // Оставшиеся посты (с 6-го и до конца)
    if (posts.length > 5) {
      slivers.add(_buildPostSliverList(posts.sublist(5, posts.length)));
    }

    // Индикатор загрузки "Показать еще"
    slivers.add(
      SliverToBoxAdapter(
        child: state.isLoadingMore
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : state.error != null
            // Первая страница уже на экране, поэтому ошибку «ещё» показываем
            // хвостом, а не вместо списка.
            ? LoadMoreErrorTile(
                onRetry: () => ref
                    .read(communityFeedProvider(_feedFilter).notifier)
                    .loadMore(),
              )
            : const SizedBox(height: 16),
      ),
    );

    return slivers;
  }

  // --------------------------------------------------------------------------
  //  Feed (desktop: чистая лента без инъекций блоков)
  // --------------------------------------------------------------------------
  List<Widget> _buildFeedOnly(BuildContext context) {
    final state = ref.watch(communityFeedProvider(_feedFilter));
    final posts = state.posts;
    final discussions = _discussionsSliver(context);

    if (state.isLoading && posts.isEmpty) {
      return [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, __) => _shimmerPostCard(context),
            childCount: 5,
          ),
        ),
      ];
    }

    if (state.error != null && posts.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _errorBlock(
            context,
            title: tr('Не удалось загрузить ленту'),
            detail: '${state.error}',
            onRetry: () =>
                ref.read(communityFeedProvider(_feedFilter).notifier).refresh(),
          ),
        ),
      ];
    }

    if (posts.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _emptyBlock(
            context,
            icon: Icons.dynamic_feed_rounded,
            title: tr('Лента пуста'),
            subtitle: _feedFilter == 'following'
                ? tr('Подпишитесь на авторов, чтобы видеть их посты здесь')
                : tr('Скоро здесь появятся новые посты сообщества'),
          ),
        ),
        ?discussions,
      ];
    }

    // На широком экране лента читается колонкой, и блок всё равно нужен: без
    // него сообщества остаются отдельной вкладкой, о которой забывают.
    final slivers = <Widget>[];
    final before = posts.length > 3 ? 3 : posts.length;
    slivers.add(_buildPostSliverList(posts.sublist(0, before)));
    if (discussions != null) slivers.add(discussions);
    if (posts.length > before) {
      slivers.add(_buildPostSliverList(posts.sublist(before)));
    }
    slivers.add(
      SliverToBoxAdapter(
        child: state.isLoadingMore
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : state.error != null
            // Первая страница уже на экране, поэтому ошибку «ещё» показываем
            // хвостом, а не вместо списка.
            ? LoadMoreErrorTile(
                onRetry: () => ref
                    .read(communityFeedProvider(_feedFilter).notifier)
                    .loadMore(),
              )
            : const SizedBox(height: 16),
      ),
    );

    return slivers;
  }

  Widget _buildPostSliverList(List<dynamic> chunk) {
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final post = chunk[index];
        return PostCard(
          key: ValueKey(post.id),
          post: post,
          isOwn: false,
          onPostUpdated: (updated) => ref
              .read(communityFeedProvider(_feedFilter).notifier)
              .updatePostLocally(updated),
          onPostDeleted: () => ref
              .read(communityFeedProvider(_feedFilter).notifier)
              .removePostLocally(post.id),
        );
      }, childCount: chunk.length),
    );
  }

  // --------------------------------------------------------------------------
  //  Inline / block helpers
  // --------------------------------------------------------------------------
  Widget _inlineHint(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      ),
    );
  }

  Widget _emptyBlock(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withOpacity(0.4),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: scheme.primary, size: 32),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _errorBlock(
    BuildContext context, {
    required String title,
    required String detail,
    required VoidCallback onRetry,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
      child: Column(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.error, size: 40),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr('Повторить')),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  Shimmer skeletons (consistent with market_screen)
  // --------------------------------------------------------------------------
  Widget _shimmerOnlineRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Shimmer.fromColors(
      baseColor: scheme.surfaceContainerHighest,
      highlightColor: scheme.surfaceContainerHigh,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 8,
        itemBuilder: (_, __) => Container(
          width: 80,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: 52,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shimmerTopAuthorsRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Shimmer.fromColors(
      baseColor: scheme.surfaceContainerHighest,
      highlightColor: scheme.surfaceContainerHigh,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 5,
        itemBuilder: (_, __) => Container(
          width: 156,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }

  Widget _shimmerPostCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Shimmer.fromColors(
        baseColor: scheme.surfaceContainerHighest,
        highlightColor: scheme.surfaceContainerHigh,
        child: Container(
          height: 140,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }
}

/// Плитка ленты «Активны на этой неделе».
///
/// Ряд имеет фиксированную высоту, а рамка из каталога косметики растёт
/// наружу круга: без компенсации радиуса имя уезжает за нижний край, и
/// Flutter рвёт ряд полосатым переполнением на 6–11 px. Публичная — чтобы
/// это ограничение можно было разложить в тесте.
class CommunityOnlineTile extends StatelessWidget {
  const CommunityOnlineTile({super.key, required this.user});

  final CommunityUser user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isOnline =
        user.lastSeenAt != null &&
        DateTime.now().difference(user.lastSeenAt!).inMinutes < 15;
    final frameDef = cosmeticById(user.equipped.avatarFrame);
    final avatarRadius = (28 - avatarFrameOutset(frameDef)).clamp(16.0, 28.0);
    return InkWell(
      onTap: () => EditorScreenTabs.openProfile(context, user.id),
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: 80,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isOnline
                            ? Colors.green
                            : scheme.outlineVariant.withOpacity(0.5),
                        width: 2,
                      ),
                    ),
                    child: CosmeticAvatar(
                      frame: frameDef,
                      radius: avatarRadius,
                      avatarUrl: user.avatarUrl,
                      placeholderColor: scheme.primaryContainer,
                    ),
                  ),
                  if (isOnline)
                    Positioned(
                      bottom: 2,
                      right: 2,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              // Имя берёт остаток высоты: крупный системный шрифт должен
              // резать подпись, а не разрывать ряд.
              Flexible(
                child: CosmeticNameText(
                  name: user.fullName,
                  def: cosmeticById(user.nameStyle),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
