import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:canvas_app/features/shell/widgets/admin_cosmetics_panel.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/playtime_formatter.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

// ============================================================================
//  АДМИН-ЦЕНТР — Material You / Material 3 редизайн
// ============================================================================

// --- ПРОВАЙДЕРЫ ---

final moderationQueueProvider = FutureProvider.autoDispose<List<MarketQuest>>((
  ref,
) async {
  final api = ref.watch(apiServiceProvider);
  final response = await api.get('admin/moderation-queue');
  return (response as List).map((j) => MarketQuest.fromJson(j)).toList();
});

final adminStatsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(apiServiceProvider);
  final response = await api.get('admin/stats');
  return response as Map<String, dynamic>;
});

final adminActivityProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
      final api = ref.watch(apiServiceProvider);
      final response = await api.get('admin/activity?days=30');
      return response as Map<String, dynamic>;
    });

final reportsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(apiServiceProvider);
  final response = await api.get('reports/admin');
  return (response as List).map((j) => j as Map<String, dynamic>).toList();
});

final musicModerationQueueProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  final response = await api.get('admin/music-moderation-queue');
  return (response as List).map((j) => j as Map<String, dynamic>).toList();
});

final assetModerationQueueProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  final response = await api.get('admin/assets-moderation-queue');
  return (response as List).map((j) => j as Map<String, dynamic>).toList();
});

final blockedUsersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      try {
        final api = ref.watch(apiServiceProvider);
        final response = await api.get('admin/blocked-users');
        return (response as List)
            .map((j) => j as Map<String, dynamic>)
            .toList();
      } catch (e) {
        if (e.toString().contains('404')) return [];
        rethrow;
      }
    });

// ============================================================================
//  ЭКРАН
// ============================================================================

class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  /// Перечитать списки выдачи по кнопке «Обновить» в шапке.
  int _cosmeticsNonce = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _refreshAll() {
    ref.invalidate(moderationQueueProvider);
    ref.invalidate(musicModerationQueueProvider);
    ref.invalidate(assetModerationQueueProvider);
    ref.invalidate(adminStatsProvider);
    ref.invalidate(adminActivityProvider);
    ref.invalidate(reportsProvider);
    ref.invalidate(blockedUsersProvider);
    setState(() => _cosmeticsNonce++);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final queueAsync = ref.watch(moderationQueueProvider);
    final statsAsync = ref.watch(adminStatsProvider);
    final activityAsync = ref.watch(adminActivityProvider);
    final reportsAsync = ref.watch(reportsProvider);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(
          tr('Центр управления'),
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: tr('Обновить'),
            onPressed: _refreshAll,
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorSize: TabBarIndicatorSize.tab,
              splashBorderRadius: BorderRadius.circular(24),
              indicator: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(24),
              ),
              labelColor: scheme.onPrimary,
              unselectedLabelColor: scheme.onSurfaceVariant,
              dividerColor: Colors.transparent,
              labelStyle: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              tabs: [
                Tab(text: tr('Модерация')),
                Tab(text: tr('Активность')),
                Tab(text: tr('Музыка')),
                Tab(text: tr('Ассеты')),
                Tab(text: tr('Жалобы')),
                Tab(text: tr('Баны')),
                Tab(text: tr('Оформление')),
              ],
            ),
          ),
        ),
      ),
      body: AdaptiveContent(maxWidth: 1100, child: RefreshIndicator(
        onRefresh: () async => _refreshAll(),
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildModerationTab(statsAsync, queueAsync),
            _buildActivityTab(activityAsync),
            _buildMusicModerationTab(),
            _buildAssetModerationTab(),
            _buildReportsTab(reportsAsync),
            _buildBlockedUsersTab(),
            AdminCosmeticsPanel(nonce: _cosmeticsNonce),
          ],
        ),
      )),
    );
  }

  // -- Активность --------------------------------------------------------

  Widget _buildActivityTab(AsyncValue<Map<String, dynamic>> activityAsync) {
    final scheme = Theme.of(context).colorScheme;

    return activityAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) =>
          _ErrorBlock(error: err.toString(), onRetry: _refreshAll),
      data: (data) {
        final summary =
            (data['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
        final actions =
            (data['actions'] as Map?)?.cast<String, dynamic>() ?? const {};
        final series = ((data['series'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        final topUsers = ((data['top_users'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();

        int count(String key) => (actions[key] as num? ?? 0).toInt();
        int stat(String key) => (summary[key] as num? ?? 0).toInt();

        final reactions =
            count('quest_votes') + count('music_votes') + count('asset_votes');
        final reviews =
            count('reviews') + count('music_reviews') + count('asset_reviews');

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
          children: [
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    title: tr('Онлайн сейчас'),
                    value: '${stat('online_now')}',
                    icon: Icons.bolt_rounded,
                    container: scheme.primaryContainer,
                    onContainer: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: tr('Активны сегодня'),
                    value: '${stat('active_today')}',
                    icon: Icons.today_rounded,
                    container: scheme.secondaryContainer,
                    onContainer: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: tr('Заходов сегодня'),
                    value: '${stat('visits_today')}',
                    icon: Icons.login_rounded,
                    container: scheme.tertiaryContainer,
                    onContainer: scheme.onTertiaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    title: tr('Всего пользователей'),
                    value: '${stat('total_users')}',
                    icon: Icons.people_alt_rounded,
                    container: scheme.surfaceContainerHighest,
                    onContainer: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: tr('Активны за 7 дней'),
                    value: '${stat('active_7d')}',
                    icon: Icons.date_range_rounded,
                    container: scheme.secondaryContainer,
                    onContainer: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: tr('Новых за 7 дней'),
                    value: '${stat('new_7d')}',
                    icon: Icons.person_add_alt_1_rounded,
                    container: scheme.primaryContainer,
                    onContainer: scheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    title: tr('Активны за 30 дней'),
                    value: '${stat('active_period')}',
                    icon: Icons.groups_rounded,
                    container: scheme.surfaceContainerHighest,
                    onContainer: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: tr('Новых за 30 дней'),
                    value: '${stat('new_period')}',
                    icon: Icons.fiber_new_rounded,
                    container: scheme.tertiaryContainer,
                    onContainer: scheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: tr('Заходов за 7 дней'),
                    value: '${stat('visits_7d')}',
                    icon: Icons.repeat_rounded,
                    container: scheme.primaryContainer,
                    onContainer: scheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SectionTitle(
                icon: Icons.insights_rounded,
                text: tr('Активность по дням'),
              ),
            ),
            _ActivityChart(series: series),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SectionTitle(
                icon: Icons.auto_awesome_rounded,
                text: tr('Что делали'),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ActivityMetric(
                  icon: Icons.favorite_rounded,
                  label: tr('Реакции'),
                  value: '$reactions',
                ),
                _ActivityMetric(
                  icon: Icons.star_rounded,
                  label: tr('Оценки'),
                  value: '${count('ratings')}',
                ),
                _ActivityMetric(
                  icon: Icons.rate_review_rounded,
                  label: tr('Отзывы'),
                  value: '$reviews',
                ),
                _ActivityMetric(
                  icon: Icons.forum_rounded,
                  label: tr('Сообщения'),
                  value: '${count('messages')}',
                ),
                _ActivityMetric(
                  icon: Icons.videogame_asset_rounded,
                  label: tr('Квесты'),
                  value: '${count('quests_created')}',
                ),
                _ActivityMetric(
                  icon: Icons.dynamic_feed_rounded,
                  label: tr('Посты'),
                  value: '${count('posts_created')}',
                ),
                _ActivityMetric(
                  icon: Icons.visibility_rounded,
                  label: tr('Просмотры квестов'),
                  value: '${count('quest_views')}',
                ),
                _ActivityMetric(
                  icon: Icons.download_rounded,
                  label: tr('Скачивания'),
                  value: '${count('downloads')}',
                ),
                _ActivityMetric(
                  icon: Icons.schedule_rounded,
                  label: tr('Игровое время'),
                  value: PlaytimeFormatter.format(count('playtime_seconds')),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SectionTitle(
                icon: Icons.emoji_events_rounded,
                text: tr('Кто активнее всех'),
              ),
            ),
            if (topUsers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  tr('За этот период активности нет'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final user in topUsers)
                _ActivityUserCard(
                  user: user,
                  onTap: () {
                    final id = user['id']?.toString();
                    if (id == null) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProfileScreen(userId: id),
                      ),
                    );
                  },
                ),
          ],
        );
      },
    );
  }

  // -- Модерация ---------------------------------------------------------

  Widget _buildModerationTab(
    AsyncValue<Map<String, dynamic>> statsAsync,
    AsyncValue<List<MarketQuest>> queueAsync,
  ) {
    final scheme = Theme.of(context).colorScheme;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: statsAsync.when(
            data: (stats) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          title: tr('На проверке'),
                          value: stats['pending_quests']?.toString() ?? '0',
                          icon: Icons.hourglass_top_rounded,
                          container: scheme.tertiaryContainer,
                          onContainer: scheme.onTertiaryContainer,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _StatCard(
                          title: tr('Игры'),
                          value: stats['quests']?.toString() ?? '0',
                          icon: Icons.videogame_asset_rounded,
                          container: scheme.secondaryContainer,
                          onContainer: scheme.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _StatCard(
                          title: tr('Юзеры'),
                          value: stats['users']?.toString() ?? '0',
                          icon: Icons.people_rounded,
                          container: scheme.primaryContainer,
                          onContainer: scheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          title: tr('Музыка на проверке'),
                          value: stats['pending_music']?.toString() ?? '0',
                          icon: Icons.music_note_rounded,
                          container: scheme.secondaryContainer,
                          onContainer: scheme.onSecondaryContainer,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            loading: () => const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SizedBox(
                height: 110,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: _SectionTitle(
              icon: Icons.gavel_rounded,
              text: tr('Очередь модерации'),
            ),
          ),
        ),
        queueAsync.when(
          loading: () => const SliverFillRemaining(
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (err, _) => SliverFillRemaining(
            child: _ErrorBlock(error: err.toString(), onRetry: _refreshAll),
          ),
          data: (quests) {
            if (quests.isEmpty) {
              return SliverFillRemaining(
                child: _EmptyBlock(
                  icon: Icons.check_circle_outline_rounded,
                  text: tr('Очередь пуста'),
                ),
              );
            }
            return SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => _ModerationCard(quest: quests[i], ref: ref),
                childCount: quests.length,
              ),
            );
          },
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }

  Widget _buildMusicModerationTab() {
    final musicAsync = ref.watch(musicModerationQueueProvider);
    return musicAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => _ErrorBlock(error: err.toString(), onRetry: _refreshAll),
      data: (tracks) {
        if (tracks.isEmpty) {
          return _EmptyBlock(icon: Icons.music_off_rounded, text: tr('Музыка: очередь пуста'));
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
          itemCount: tracks.length,
          itemBuilder: (_, i) => _MusicModerationCard(track: tracks[i], ref: ref),
        );
      },
    );
  }

  Widget _buildAssetModerationTab() {
    final assetAsync = ref.watch(assetModerationQueueProvider);
    return assetAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => _ErrorBlock(error: err.toString(), onRetry: _refreshAll),
      data: (assets) {
        if (assets.isEmpty) {
          return _EmptyBlock(icon: Icons.widgets_rounded, text: tr('Ассеты: очередь пуста'));
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
          itemCount: assets.length,
          itemBuilder: (_, i) => _AssetModerationCard(asset: assets[i], ref: ref),
        );
      },
    );
  }

  // -- Жалобы ------------------------------------------------------------

  Widget _buildReportsTab(AsyncValue<List<Map<String, dynamic>>> reportsAsync) {
    return reportsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) =>
          _ErrorBlock(error: err.toString(), onRetry: _refreshAll),
      data: (reports) {
        if (reports.isEmpty) {
          return _EmptyBlock(
            icon: Icons.report_off_rounded,
            text: tr('Жалоб нет'),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
          itemCount: reports.length,
          itemBuilder: (_, i) => _ReportCard(report: reports[i], ref: ref),
        );
      },
    );
  }

  // -- Заблокированные ---------------------------------------------------

  Widget _buildBlockedUsersTab() {
    final blockedUsersAsync = ref.watch(blockedUsersProvider);
    return blockedUsersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) =>
          _ErrorBlock(error: err.toString(), onRetry: _refreshAll),
      data: (users) {
        if (users.isEmpty) {
          return _EmptyBlock(
            icon: Icons.lock_open_rounded,
            text: tr('Нет заблокированных пользователей'),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
          itemCount: users.length,
          itemBuilder: (_, i) => _BlockedUserCard(user: users[i], ref: ref),
        );
      },
    );
  }
}

// ============================================================================
//  ВСПОМОГАТЕЛЬНЫЕ ВИДЖЕТЫ
// ============================================================================

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SectionTitle({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: scheme.onPrimaryContainer, size: 18),
        ),
        const SizedBox(width: 10),
        Text(
          text,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color container;
  final Color onContainer;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.container,
    required this.onContainer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: container,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [Icon(icon, color: onContainer, size: 20)]),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
                color: onContainer,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: onContainer.withOpacity(0.85),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartLegend extends StatelessWidget {
  final Color color;
  final String label;
  const _ChartLegend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _ActivityChart extends StatelessWidget {
  final List<Map<String, dynamic>> series;
  const _ActivityChart({required this.series});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    if (series.isEmpty) {
      return Text(
        tr('Нет данных'),
        style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    var maxValue = 1;
    for (final point in series) {
      final visits = (point['visits'] as num? ?? 0).toInt();
      final actions = (point['actions'] as num? ?? 0).toInt();
      if (visits > maxValue) maxValue = visits;
      if (actions > maxValue) maxValue = actions;
    }

    double barHeight(num value) {
      final height = (value / maxValue) * 96;
      return height < 2 ? 2 : height.toDouble();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ChartLegend(color: scheme.primary, label: tr('Заходы')),
              const SizedBox(width: 12),
              _ChartLegend(color: scheme.tertiary, label: tr('Действия')),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final point in series)
                  Expanded(
                    child: Tooltip(
                      message:
                          '${point['day']} · ${tr('Заходы')}: ${(point['visits'] as num? ?? 0).toInt()} · ${tr('Действия')}: ${(point['actions'] as num? ?? 0).toInt()}',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              width: 3,
                              height: barHeight(point['visits'] as num? ?? 0),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 1),
                            Container(
                              width: 3,
                              height: barHeight(point['actions'] as num? ?? 0),
                              decoration: BoxDecoration(
                                color: scheme.tertiary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                series.first['day']?.toString() ?? '',
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Text(
                series.last['day']?.toString() ?? '',
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActivityMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _ActivityMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w900,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _UserMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _UserMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            '$label $value',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ActivityUserCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final VoidCallback onTap;
  const _ActivityUserCard({required this.user, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final rawName = user['full_name']?.toString().trim() ?? '';
    final avatar = user['avatar_url']?.toString() ?? '';
    final visits = (user['visits'] as num? ?? 0).toInt();
    final reactions = (user['reactions'] as num? ?? 0).toInt();
    final messages = (user['messages'] as num? ?? 0).toInt();
    final quests = (user['quests'] as num? ?? 0).toInt();
    final posts = (user['posts'] as num? ?? 0).toInt();
    final score = (user['score'] as num? ?? 0).toInt();
    final lastSeen = DateTime.tryParse(
      user['last_seen_at']?.toString() ?? '',
    )?.toLocal();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.primaryContainer,
                  backgroundImage: avatar.isEmpty
                      ? null
                      : CachedNetworkImageProvider(avatar),
                  child: avatar.isEmpty
                      ? Icon(
                          Icons.person_rounded,
                          color: scheme.onPrimaryContainer,
                        )
                      : null,
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
                              rawName.isEmpty ? tr('Без имени') : rawName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              trf('Баллы: {p0}', {'p0': '$score'}),
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        lastSeen == null
                            ? tr('Ещё не заходил(а)')
                            : trf('Последний вход: {when}', {
                                'when': _formatMoment(lastSeen),
                              }),
                        style: textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        children: [
                          _UserMetric(
                            icon: Icons.login_rounded,
                            label: tr('Заходы'),
                            value: '$visits',
                          ),
                          _UserMetric(
                            icon: Icons.favorite_rounded,
                            label: tr('Реакции'),
                            value: '$reactions',
                          ),
                          _UserMetric(
                            icon: Icons.forum_rounded,
                            label: tr('Сообщения'),
                            value: '$messages',
                          ),
                          _UserMetric(
                            icon: Icons.videogame_asset_rounded,
                            label: tr('Квесты'),
                            value: '$quests',
                          ),
                          _UserMetric(
                            icon: Icons.dynamic_feed_rounded,
                            label: tr('Посты'),
                            value: '$posts',
                          ),
                        ],
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

String _formatMoment(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)} '
      '${two(value.hour)}:${two(value.minute)}';
}

class _EmptyBlock extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyBlock({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: scheme.primary.withOpacity(0.6)),
          const SizedBox(height: 12),
          Text(
            text,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorBlock({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: scheme.error.withOpacity(0.7),
            ),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr('Повторить')),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  КАРТОЧКА — Заблокированный пользователь
// ============================================================================

class _BlockedUserCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final WidgetRef ref;

  const _BlockedUserCard({required this.user, required this.ref});

  Future<void> _unblockUser(BuildContext context) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(tr('Разблокировать пользователя?')),
          content: Text(
            trf('Пользователь «{p0}» снова сможет пользоваться приложением.', {'p0': user['full_name'] ?? 'Unknown'}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
              ),
              child: Text(tr('Разблокировать')),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;
    try {
      await ref
          .read(apiServiceProvider)
          .post('admin/users/${user['id']}/unblock');
      ref.invalidate(blockedUsersProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Пользователь разблокирован')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {e}', {'e': e})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: scheme.errorContainer,
                child: Icon(
                  Icons.block_rounded,
                  color: scheme.onErrorContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user['full_name'] ?? 'Unknown',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (user['email'] != null)
                      Text(
                        user['email'].toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'BAN',
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProfileScreen(userId: user['id']),
                      ),
                    );
                  },
                  icon: const Icon(Icons.person_outline_rounded, size: 18),
                  label: Text(tr('Профиль')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _unblockUser(context),
                  icon: const Icon(Icons.lock_open_rounded, size: 18),
                  label: Text(tr('Разбан')),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  КАРТОЧКА — Модерация квеста
// ============================================================================

class _ModerationCard extends StatelessWidget {
  final MarketQuest quest;
  final WidgetRef ref;

  const _ModerationCard({required this.quest, required this.ref});

  Future<void> _reviewQuest(BuildContext context, String status) async {
    final scheme = Theme.of(context).colorScheme;
    final commentController = TextEditingController();

    if (status == 'rejected') {
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Причина отказа')),
          content: TextField(
            controller: commentController,
            autofocus: true,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: tr('Опишите причину…'),
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              child: Text(tr('Отклонить')),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    try {
      await ref
          .read(apiServiceProvider)
          .post(
            'admin/quest/${quest.id}/review',
            body: {
              'status': status,
              'comment': status == 'published'
                  ? 'Approved'
                  : commentController.text,
            },
          );
      ref.invalidate(moderationQueueProvider);
      ref.invalidate(adminStatsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              status == 'published' ? tr('Квест опубликован') : tr('Квест отклонён'),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {e}', {'e': e})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasImg =
        quest.previewImageUrl != null && quest.previewImageUrl!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: hasImg
                      ? CachedNetworkImage(
                          imageUrl: quest.previewImageUrl!,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            width: 60,
                            height: 60,
                            color: scheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.broken_image_rounded,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : Container(
                          width: 60,
                          height: 60,
                          color: scheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.image_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        quest.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurface,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.person_outline_rounded,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              quest.authorName ?? 'Unknown',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(tr('Открыть')),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          MarketQuestLoaderScreen(questId: quest.id),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  icon: Icon(
                    Icons.close_rounded,
                    color: scheme.error,
                    size: 18,
                  ),
                  label: Text(
                    tr('Отказать'),
                    style: TextStyle(color: scheme.error),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: scheme.error.withOpacity(0.5)),
                  ),
                  onPressed: () => _reviewQuest(context, 'rejected'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text(tr('Одобрить')),
                  onPressed: () => _reviewQuest(context, 'published'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MusicModerationCard extends StatelessWidget {
  final Map<String, dynamic> track;
  final WidgetRef ref;
  const _MusicModerationCard({required this.track, required this.ref});

  Future<void> _review(BuildContext context, String status) async {
    try {
      await ref.read(apiServiceProvider).post('admin/music/${track['id']}/review', body: {'status': status});
      ref.invalidate(musicModerationQueueProvider);
      ref.invalidate(adminStatsProvider);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(status == 'published' ? tr('Трек одобрен') : tr('Трек отклонён'))));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Ошибка: {e}', {'e': e}))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 56, height: 56, decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)), child: Icon(Icons.music_note_rounded, color: scheme.onSecondaryContainer)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(track['title']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            Text('${track['performer'] ?? ''} • ${track['genre'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            if (track['license'] != null) Text(trf('Лицензия: {p0}', {'p0': track['license']}), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ])),
        ]),
        const SizedBox(height: 8),
        if (track['author_name'] != null) Row(children: [Icon(Icons.person_outline_rounded, size: 14, color: scheme.onSurfaceVariant), const SizedBox(width: 4), Text(track['author_name'].toString(), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))]),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          OutlinedButton.icon(icon: Icon(Icons.close_rounded, color: scheme.error, size: 18), label: Text(tr('Отклонить'), style: TextStyle(color: scheme.error)), onPressed: () => _review(context, 'rejected')),
          const SizedBox(width: 8),
          FilledButton.icon(icon: const Icon(Icons.check_rounded, size: 18), label: Text(tr('Одобрить')), onPressed: () => _review(context, 'published')),
        ]),
      ]),
    );
  }
}

class _AssetModerationCard extends StatelessWidget {
  final Map<String, dynamic> asset;
  final WidgetRef ref;
  const _AssetModerationCard({required this.asset, required this.ref});

  Future<void> _review(BuildContext context, String status) async {
    try {
      await ref.read(apiServiceProvider).post('admin/assets/${asset['id']}/review', body: {'status': status});
      ref.invalidate(assetModerationQueueProvider);
      ref.invalidate(adminStatsProvider);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(status == 'published' ? tr('Ассет одобрен') : tr('Ассет отклонён'))));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Ошибка: {e}', {'e': e}))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = asset['kind']?.toString() ?? 'asset';
    IconData icon;
    switch (kind) {
      case 'button_preset': icon = Icons.smart_button_rounded; break;
      case 'background': icon = Icons.wallpaper_rounded; break;
      case 'sfx': icon = Icons.music_note_rounded; break;
      case 'font': icon = Icons.text_fields_rounded; break;
      default: icon = Icons.widgets_rounded;
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 56, height: 56, decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: scheme.onSecondaryContainer)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(asset['title']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            Text('$kind • ${asset['genre'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            if (asset['license'] != null) Text(trf('Лицензия: {p0}', {'p0': asset['license']}), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ])),
        ]),
        const SizedBox(height: 8),
        if (asset['author_name'] != null) Row(children: [Icon(Icons.person_outline_rounded, size: 14, color: scheme.onSurfaceVariant), const SizedBox(width: 4), Text(asset['author_name'].toString(), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))]),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          OutlinedButton.icon(icon: Icon(Icons.close_rounded, color: scheme.error, size: 18), label: Text(tr('Отклонить'), style: TextStyle(color: scheme.error)), onPressed: () => _review(context, 'rejected')),
          const SizedBox(width: 8),
          FilledButton.icon(icon: const Icon(Icons.check_rounded, size: 18), label: Text(tr('Одобрить')), onPressed: () => _review(context, 'published')),
        ]),
      ]),
    );
  }
}

// ============================================================================
//  КАРТОЧКА — Жалоба
// ============================================================================

class _ReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final WidgetRef ref;

  const _ReportCard({required this.report, required this.ref});

  Future<void> _resolveReport(
    BuildContext context,
    String action, {
    bool blockUser = false,
  }) async {
    try {
      await ref
          .read(apiServiceProvider)
          .post(
            'reports/admin/${report['id']}/resolve',
            body: {'action': action, if (blockUser) 'block_user': true},
          );
      ref.invalidate(reportsProvider);
      // Обновляем список банов и статистику — туда мог добавиться новый
      // заблокированный пользователь.
      if (blockUser) {
        ref.invalidate(blockedUsersProvider);
      }
      ref.invalidate(adminStatsProvider);

      if (context.mounted) {
        final msg = action == 'dismiss'
            ? tr('Жалоба отклонена')
            : blockUser
            ? tr('Контент удалён, пользователь заблокирован')
            : tr('Контент удалён');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {e}', {'e': e})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context, {
    required bool withBan,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(withBan ? tr('Удалить и заблокировать?') : tr('Удалить контент?')),
        content: Text(
          withBan
              ? tr('Контент будет удалён, а автор — заблокирован. Это действие нельзя отменить.')
              : tr('Контент будет удалён без возможности восстановления.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
            child: Text(withBan ? tr('Удалить + бан') : tr('Удалить')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!context.mounted) return;
    await _resolveReport(context, 'delete', blockUser: withBan);
  }

  void _openProfile(BuildContext context, String? userId) {
    if (userId == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(userId: userId)),
    );
  }

  void _openQuest(BuildContext context, String? questId) {
    if (questId == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MarketQuestLoaderScreen(questId: questId),
      ),
    );
  }

  String _typeLabel(String? type) {
    switch (type) {
      case 'quest':
        return tr('Квест');
      case 'review':
        return tr('Отзыв');
      case 'user':
        return tr('Пользователь');
      default:
        return tr('Контент');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final String type = report['reported_type'] ?? '';
    final String? reporterId = report['reporter_id'];
    final String? reporterName = report['reporter_name'];

    final String? userIdToOpen = type == 'user'
        ? report['reported_id']
        : report['reported_user_id'];

    String? questIdToOpen;
    if (type == 'quest') {
      questIdToOpen = report['reported_id'];
    } else if (type == 'review') {
      questIdToOpen = report['quest_id'];
    }

    final String? itemTitle = report['reported_item_title'];
    final String? itemContent = report['reported_item_content'];
    final int? rating = report['rating'];

    String reviewText = tr('Текст отзыва не загружен');
    if (itemContent != null &&
        itemContent != 'null' &&
        itemContent.isNotEmpty) {
      reviewText = itemContent;
    } else if (type == 'review' && itemTitle != null && itemTitle.isNotEmpty) {
      reviewText = itemTitle;
    }
    
    String contentText = tr('Контент не загружен');
    if (itemTitle != null && itemTitle.isNotEmpty && itemTitle != 'null') {
      contentText = itemTitle;
    }

    // Можем ли мы заблокировать автора? Только если знаем, чей контент.
    final bool canBan = userIdToOpen != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _typeLabel(type),
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const Spacer(),
              if (reporterName != null)
                Flexible(
                  child: InkWell(
                    onTap: () => _openProfile(context, reporterId),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        trf('От: {reporterName}', {'reporterName': reporterName}),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // reason
          Text(
            report['reason']?.toString() ?? '',
            style: textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          if (report['description'] != null) ...[
            const SizedBox(height: 4),
            Text(
              report['description']?.toString() ?? '',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],

          // info block
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (report['reported_user_name'] != null)
                  InkWell(
                    onTap: () => _openProfile(context, userIdToOpen),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.person_rounded,
                            size: 16,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              report['reported_user_name']?.toString() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelLarge?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (type == 'quest' && itemTitle != null)
                  Row(
                    children: [
                      Icon(
                        Icons.videogame_asset_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          itemTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelLarge?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),

                if (type == 'review') ...[
                  if (rating != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: List.generate(
                          5,
                          (i) => Icon(
                            i < rating
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 18,
                            color: Colors.amber,
                          ),
                        ),
                      ),
                    ),
                  Text(
                    reviewText,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                
                if (type == 'wall_post' || type == 'wall_comment') ...[
                  Text(
                    contentText,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // actions — Wrap, чтобы не обрезалось на узких экранах
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (questIdToOpen != null)
                OutlinedButton.icon(
                  onPressed: () => _openQuest(context, questIdToOpen),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(tr('Открыть')),
                ),
              TextButton(
                onPressed: () => _resolveReport(context, 'dismiss'),
                child: Text(tr('Пропустить')),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _confirmDelete(context, withBan: false),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(tr('Удалить')),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.errorContainer,
                  foregroundColor: scheme.onErrorContainer,
                ),
              ),
              if (canBan)
                FilledButton.icon(
                  onPressed: () => _confirmDelete(context, withBan: true),
                  icon: const Icon(Icons.block_rounded, size: 18),
                  label: Text(tr('Удалить + бан')),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
