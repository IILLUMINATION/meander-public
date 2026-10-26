import 'package:cached_network_image/cached_network_image.dart';
import 'package:canvas_app/core/utils/count_format.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/market/providers/recommendations_provider.dart';
import 'package:canvas_app/features/market/providers/market_provider.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/features/quests/screens/my_quests_screen.dart';
import 'package:canvas_app/models/market_activity_model.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ============================================================================
//  ОБЩИЕ КОНСТАНТЫ
// ============================================================================

const List<String> kMarketCategories = [
  'Fantasy',
  'Sci-Fi',
  'Horror',
  'Adventure',
  'Mystery',
  'Romance',
  'Comedy',
  'Thriller',
  'Historical',
  'Drama',
];

/// Английский id жанра с бэкенда -> подпись на витрине. Геттер, а не
/// const-таблица: подписи строятся под текущий язык.
Map<String, String> get kCategoryTranslations => {
  'Fantasy': tr('Фэнтези'),
  'Sci-Fi': tr('Фантастика'),
  'Horror': tr('Ужасы'),
  'Adventure': tr('Приключения'),
  'Mystery': tr('Мистика'),
  'Romance': tr('Романтика'),
  'Comedy': tr('Комедия'),
  'Thriller': tr('Триллер'),
  'Historical': tr('История'),
  'Drama': tr('Драма'),
};

const Map<String, IconData> kCategoryIcons = {
  'Fantasy': Icons.auto_fix_high_rounded,
  'Sci-Fi': Icons.rocket_launch_rounded,
  'Horror': Icons.dark_mode_rounded,
  'Adventure': Icons.terrain_rounded,
  'Mystery': Icons.psychology_rounded,
  'Romance': Icons.favorite_rounded,
  'Comedy': Icons.theater_comedy_rounded,
  'Thriller': Icons.bolt_rounded,
  'Historical': Icons.account_balance_rounded,
  'Drama': Icons.masks_rounded,
};

String translateCategory(String? category) {
  if (category == null) return '';
  return kCategoryTranslations[category] ?? category;
}

String formatRelativeTime(DateTime dateTime) {
  final now = DateTime.now();
  final diff = now.difference(dateTime);
  if (diff.inSeconds < 5) return tr('только что');
  if (diff.inSeconds < 60) return trf('{p0} сек', {'p0': diff.inSeconds});
  if (diff.inMinutes < 60) return trf('{p0} мин', {'p0': diff.inMinutes});
  if (diff.inHours < 24) return trf('{p0} ч', {'p0': diff.inHours});
  if (diff.inDays < 7) return trf('{p0} дн', {'p0': diff.inDays});
  final weeks = (diff.inDays / 7).floor();
  if (weeks < 5) return trf('{p0} нед', {'p0': weeks});
  final months = (diff.inDays / 30).floor();
  if (months < 12) return trf('{p0} мес', {'p0': months});
  final years = (diff.inDays / 365).floor();
  return trf('{p0} г', {'p0': years});
}

// ============================================================================
//  ОБЛОЖКА КВЕСТА
// ============================================================================

class MarketCoverImage extends StatelessWidget {
  final String? url;
  final Color fallbackColor;

  const MarketCoverImage({
    super.key,
    required this.url,
    required this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Container(
        color: fallbackColor,
        child: Icon(
          Icons.image_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 32,
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: url!,
      fit: BoxFit.cover,
      memCacheWidth: 600,
      filterQuality: FilterQuality.low,
      placeholder: (_, __) => Container(color: fallbackColor),
      errorWidget: (_, __, ___) => Container(
        color: fallbackColor,
        child: Icon(
          Icons.broken_image_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 32,
        ),
      ),
    );
  }
}

// ============================================================================
//  БЕЙДЖИ
// ============================================================================

class MarketBadge extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const MarketBadge({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class MarketIconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;

  const MarketIconBadge({super.key, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.92),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: 16),
    );
  }
}

// ============================================================================
//  КАРТОЧКА КВЕСТА — M3
// ============================================================================

class MarketQuestCard extends ConsumerWidget {
  final MarketQuest quest;
  final double? width;

  const MarketQuestCard({super.key, required this.quest, this.width});

  bool get _isRecentlyUpdated {
    final diff = quest.updatedAt.difference(quest.createdAt).inHours;
    final freshness = DateTime.now().difference(quest.updatedAt).inDays;
    return diff > 24 && freshness < 14;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: width,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            ref.read(recentlyViewedQuestsProvider.notifier).push(quest.id);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => QuestMarketDetailsScreen(quest: quest),
              ),
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 11,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MarketCoverImage(
                      url: quest.previewImageUrl,
                      fallbackColor: scheme.surfaceContainerHighest,
                    ),
                    if (quest.category != null && quest.category!.isNotEmpty)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: MarketBadge(
                          label: translateCategory(
                            quest.category,
                          ).toUpperCase(),
                          background: scheme.surface.withOpacity(0.88),
                          foreground: scheme.onSurface,
                        ),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (quest.isNsfw) ...[
                            const SizedBox(height: 4),
                            MarketBadge(
                              label: '18+',
                              background: scheme.error,
                              foreground: scheme.onError,
                            ),
                          ],
                          if (quest.isFeatured == true)
                            const MarketIconBadge(
                              icon: Icons.auto_awesome_rounded,
                              color: Color(0xFFFFB300),
                            ),
                          if (quest.isDemo) ...[
                            const SizedBox(height: 4),
                            MarketBadge(
                              label: tr('ДЕМО'),
                              background: scheme.errorContainer,
                              foreground: scheme.onErrorContainer,
                            ),
                          ],
                          if (_isRecentlyUpdated && !quest.isDemo) ...[
                            const SizedBox(height: 4),
                            MarketBadge(
                              label: 'UPD',
                              background: scheme.tertiaryContainer,
                              foreground: scheme.onTertiaryContainer,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      quest.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (quest.authorName != null &&
                        quest.authorName!.isNotEmpty)
                      CosmeticNameText(
                        name: quest.authorName!,
                        def: cosmeticById(quest.authorNameStyle),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _CardMetric(
                          icon: Icons.star_rounded,
                          iconColor: scheme.primary,
                          text: quest.averageRating.toStringAsFixed(1),
                          textColor: scheme.onSurface,
                        ),
                        _CardMetric(
                          icon: Icons.download_rounded,
                          iconColor: scheme.onSurfaceVariant,
                          text: formatCount(quest.downloadsCount),
                          textColor: scheme.onSurfaceVariant,
                        ),
                        _CardMetric(
                          icon: Icons.visibility_rounded,
                          iconColor: scheme.onSurfaceVariant,
                          text: formatCount(quest.viewsCount),
                          textColor: scheme.onSurfaceVariant,
                          semanticLabel: tr('Просмотры'),
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
    );
  }
}

// ============================================================================
//  HERO КАРТОЧКА (для карусели «Выбор редакции»)
// ============================================================================

class MarketHeroCard extends ConsumerWidget {
  final MarketQuest quest;

  const MarketHeroCard({super.key, required this.quest});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(32),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          ref.read(recentlyViewedQuestsProvider.notifier).push(quest.id);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => QuestMarketDetailsScreen(quest: quest),
            ),
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            MarketCoverImage(
              url: quest.previewImageUrl,
              fallbackColor: scheme.surfaceContainerHighest,
            ),
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                  stops: [0.35, 1.0],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      MarketBadge(
                        label: tr('ВЫБОР РЕДАКЦИИ'),
                        background: scheme.primaryContainer,
                        foreground: scheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 6),
                      if (quest.category != null && quest.category!.isNotEmpty)
                        MarketBadge(
                          label: translateCategory(
                            quest.category,
                          ).toUpperCase(),
                          background: const Color(0x2EFFFFFF),
                          foreground: Colors.white,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    quest.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (quest.authorName != null && quest.authorName!.isNotEmpty)
                    Text(
                      quest.authorName!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _CardMetric(
                        icon: Icons.star_rounded,
                        iconColor: Colors.amber,
                        text: quest.averageRating.toStringAsFixed(1),
                        textColor: Colors.white,
                        iconSize: 16,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      _CardMetric(
                        icon: Icons.download_rounded,
                        iconColor: Colors.white70,
                        text: formatCount(quest.downloadsCount),
                        textColor: Colors.white70,
                        fontSize: 12,
                      ),
                      _CardMetric(
                        icon: Icons.visibility_rounded,
                        iconColor: Colors.white70,
                        text: formatCount(quest.viewsCount),
                        textColor: Colors.white70,
                        fontSize: 12,
                        semanticLabel: tr('Просмотры'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  EMPTY / ERROR / HINT
// ============================================================================

class MarketEmptyState extends StatelessWidget {
  /// Поле nullable, а не const-дефолт: подпись по умолчанию строится под
  /// текущий язык, а const-конструктор к tr() не обращается.
  final String? message;
  const MarketEmptyState({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              message ?? tr('Ничего не найдено'),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

class MarketErrorBlock extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;

  const MarketErrorBlock({
    super.key,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Офлайн — не тупик: библиотека, создание квестов и скачанные истории
    // работают без сервера. Старая версия блока знала только про
    // SERVER_MAINTENANCE и прочее печатала сырым исключением, поэтому
    // человек без сети видел «Ошибка: SocketException …» и одну кнопку
    // «Попробовать снова» — и делал вывод, что офлайн нельзя ничего.
    final offline = error != null && isConnectionFailure(error!);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            offline ? Icons.cloud_off_rounded : Icons.error_outline_rounded,
            size: 64,
            color: offline ? scheme.onSurfaceVariant : scheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            offline
                ? tr('Нет подключения к серверу\n\nВозможны технические работы или пропал интернет.\n\nБиблиотека, создание квестов и уже скачанные истории работают офлайн.')
                : friendlyError(error ?? tr('Неизвестная ошибка')),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: offline ? scheme.onSurfaceVariant : scheme.error,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr('Попробовать снова')),
          ),
          if (offline) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('market-offline-library'),
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => MyQuestsScreen())),
              icon: const Icon(Icons.menu_book_rounded, size: 20),
              label: Text(tr('Мои квесты')),
            ),
          ],
        ],
      ),
    );
  }
}

class MarketInlineHint extends StatelessWidget {
  final String text;

  /// Для ошибочных состояний: пустая секция без кнопки выглядит так, будто
  /// содержимого просто нет.
  final VoidCallback? onRetry;
  const MarketInlineHint({super.key, required this.text, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.tips_and_updates_outlined,
            color: scheme.primary,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(tr('Обновить')),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
//  ФИЛЬТРЫ — BOTTOM SHEET
// ============================================================================

class MarketFiltersSheet extends ConsumerWidget {
  const MarketFiltersSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selectedCat = ref.watch(marketCategoryProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, color: scheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  tr('Фильтры'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                if (selectedCat != null)
                  TextButton(
                    onPressed: () {
                      ref.read(marketCategoryProvider.notifier).state = null;
                    },
                    child: Text(tr('Сбросить')),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tr('Подборки'),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _FilterChipItem(
                label: tr('Для вас'),
                value: 'for_you',
                icon: Icons.recommend_rounded,
              ),
              _FilterChipItem(
                label: tr('В тренде'),
                value: 'trending',
                icon: Icons.trending_up_rounded,
              ),
              _FilterChipItem(
                label: tr('Выбор редакции'),
                value: 'featured',
                icon: Icons.auto_awesome_rounded,
              ),
              _FilterChipItem(
                label: tr('Проверенные'),
                value: 'verified',
                icon: Icons.verified_rounded,
              ),
              _FilterChipItem(
                label: tr('Демо'),
                value: 'demo',
                icon: Icons.science_outlined,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            tr('Жанры'),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: kMarketCategories
                .map(
                  (c) => _FilterChipItem(
                    label: translateCategory(c),
                    value: c,
                    icon: kCategoryIcons[c] ?? Icons.label_outline_rounded,
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.check_rounded),
              label: Text(tr('Применить')),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChipItem extends ConsumerWidget {
  final String label;
  final String value;
  final IconData icon;

  const _FilterChipItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(marketCategoryProvider) == value;
    return FilterChip(
      label: Text(label),
      avatar: Icon(icon, size: 16),
      selected: selected,
      onSelected: (_) {
        ref.read(marketCategoryProvider.notifier).state = selected
            ? null
            : value;
      },
    );
  }
}

// ============================================================================
//  ЛЕНТА ПОСЛЕДНИХ ДЕЙСТВИЙ
// ============================================================================

class MarketRecentActivityFeed extends ConsumerWidget {
  final AutoDisposeFutureProvider<List<MarketActivityItem>> provider;
  final int maxItems;
  final double horizontalPadding;

  const MarketRecentActivityFeed({
    super.key,
    required this.provider,
    this.maxItems = 8,
    this.horizontalPadding = 16,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    final scheme = Theme.of(context).colorScheme;
    return async.when(
      loading: () => Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        child: SizedBox(
          height: 96,
          child: Center(
            child: CircularProgressIndicator(color: scheme.primary),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            trf('Не удалось загрузить действия: {p0}', {'p0': friendlyError(e)}),
            style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
          ),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: Text(
              tr('Пока нет событий'),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          );
        }
        final visible = items.take(maxItems).toList();
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: visible.length,
                separatorBuilder: (_, __) => Divider(
                  color: scheme.outlineVariant,
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                ),
                itemBuilder: (context, index) =>
                    _RecentActivityTile(item: visible[index]),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CardMetric extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String text;
  final Color textColor;
  final String? semanticLabel;
  final double iconSize;
  final double fontSize;
  final FontWeight fontWeight;

  const _CardMetric({
    required this.icon,
    required this.iconColor,
    required this.text,
    required this.textColor,
    this.semanticLabel,
    this.iconSize = 14,
    this.fontSize = 11,
    this.fontWeight = FontWeight.w600,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: iconColor),
          const SizedBox(width: 2),
          Text(
            text,
            style: TextStyle(
              color: textColor,
              fontSize: fontSize,
              fontWeight: fontWeight,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentActivityTile extends StatelessWidget {
  final MarketActivityItem item;
  const _RecentActivityTile({required this.item});

  IconData _iconForType() {
    switch (item.eventType) {
      case 'quest_like':
        return Icons.favorite_rounded;
      case 'quest_review':
        return Icons.rate_review_rounded;
      case 'quest_published':
        return Icons.publish_rounded;
      case 'user_follow':
        return Icons.person_add_alt_1_rounded;
      case 'quest_download':
        return Icons.download_rounded;
      default:
        return Icons.bolt_rounded;
    }
  }

  Color _iconColorForType(ColorScheme scheme) {
    switch (item.eventType) {
      case 'quest_like':
        return const Color(0xFFFF5A7A);
      case 'quest_review':
        return const Color(0xFFFFB300);
      case 'quest_published':
        return scheme.primary;
      case 'user_follow':
        return const Color(0xFF7C4DFF);
      case 'quest_download':
        return const Color(0xFF4FC3F7);
      default:
        return scheme.primary;
    }
  }

  /// Ник актёра — отдельным спаном с цветом из каталога: в середине фразы
  /// шейдер не поставить, поэтому берётся плоский цвет предмета.
  InlineSpan _buildTitle() {
    final tail = switch (item.eventType) {
      'quest_like' => tr(' поставил(а) лайк'),
      'quest_review' => tr(' оставил(а) отзыв'),
      'quest_published' => tr(' опубликовал(а) квест'),
      'user_follow' => tr(' подписался(ась)'),
      'quest_download' => tr(' скачал(а) квест'),
      _ => tr(' совершил(а) действие'),
    };
    return TextSpan(
      children: [
        TextSpan(
          text: item.actorName,
          style: cosmeticNameInlineStyle(item.actorNameStyle),
        ),
        TextSpan(text: tail),
      ],
    );
  }

  String _buildSubtitle() {
    if (item.eventType == 'user_follow') {
      final target = (item.targetUserName?.trim().isNotEmpty == true)
          ? item.targetUserName!
          : tr('автора');
      return trf('на профиль {p0}', {'p0': target});
    }
    if (item.questTitle.trim().isEmpty || item.questTitle == 'Без названия') {
      return tr('Открыть детали');
    }
    final byTarget = item.targetUserName == null || item.targetUserName!.isEmpty
        ? ''
        : trf(' • автор {p0}', {'p0': item.targetUserName});
    return '«${item.questTitle}»$byTarget';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        if (item.eventType == 'user_follow' && item.actorId.isNotEmpty) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ProfileScreen(userId: item.actorId),
            ),
          );
          return;
        }
        if (item.questId.isEmpty) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MarketQuestLoaderScreen(questId: item.questId),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CosmeticAvatar(
              frame: cosmeticById(item.actorFrame),
              radius: 18,
              avatarUrl: item.actorAvatarUrl,
              placeholderColor: scheme.surfaceContainerHighest,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    _buildTitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _buildSubtitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(
                  _iconForType(),
                  color: _iconColorForType(scheme),
                  size: 18,
                ),
                const SizedBox(height: 4),
                Text(
                  formatRelativeTime(item.createdAt),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
