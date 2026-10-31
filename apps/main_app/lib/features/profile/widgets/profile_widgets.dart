import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:canvas_app/models/notification_model.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/models/review_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ============================================================================
//  СТАТ-ПЛИТКА В ШАПКЕ ПРОФИЛЯ
// ============================================================================

class ProfileStatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final VoidCallback? onTap;

  const ProfileStatTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Плоская цифра вместо плитки с заливкой: в шапке профиля четыре плитки
    // образовывали «клавиатуру» из одинаковых прямоугольников, и глаз не
    // находил в ней главного.
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
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
//  EMPTY STATE
// ============================================================================

class ProfileEmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? hint;
  final Widget? action;

  const ProfileEmptyState({
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

// ============================================================================
//  СЕТКА КВЕСТОВ (ПУБЛИКАЦИИ ПРОФИЛЯ)
// ============================================================================

class ProfileQuestCard extends StatelessWidget {
  final MarketQuest quest;

  const ProfileQuestCard({super.key, required this.quest});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => QuestMarketDetailsScreen(quest: quest),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 11,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (quest.previewImageUrl != null &&
                      quest.previewImageUrl!.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: quest.previewImageUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: 400,
                      filterQuality: FilterQuality.low,
                      placeholder: (_, __) =>
                          Container(color: scheme.surfaceContainerHighest),
                      errorWidget: (_, __, ___) => Container(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: scheme.onSurfaceVariant,
                          size: 28,
                        ),
                      ),
                    )
                  else
                    Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.image_outlined,
                        color: scheme.onSurfaceVariant,
                        size: 28,
                      ),
                    ),
                  if (quest.isDemo)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          tr('ДЕМО'),
                          style: TextStyle(
                            color: scheme.onErrorContainer,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    quest.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.star_rounded, size: 14, color: scheme.primary),
                      const SizedBox(width: 2),
                      Text(
                        quest.averageRating.toStringAsFixed(1),
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        Icons.download_rounded,
                        size: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        formatCompactCount(quest.downloadsCount),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
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
    );
  }
}

// ============================================================================
//  КАРТОЧКА ДОСТИЖЕНИЯ
// ============================================================================

IconData _achievementIcon(String name) {
  switch (name) {
    case 'star':
      return Icons.star_rounded;
    case 'trophy':
    case 'emoji_events':
      return Icons.emoji_events_rounded;
    case 'medal':
    case 'military_tech':
      return Icons.military_tech_rounded;
    case 'fire':
    case 'local_fire_department':
      return Icons.local_fire_department_rounded;
    case 'rocket':
      return Icons.rocket_launch_rounded;
    case 'bolt':
      return Icons.bolt_rounded;
    case 'diamond':
      return Icons.diamond_outlined;
    case 'verified':
      return Icons.verified_rounded;
    case 'workspace_premium':
      return Icons.workspace_premium_rounded;
    case 'auto_awesome':
      return Icons.auto_awesome_rounded;
    case 'favorite':
      return Icons.favorite_rounded;
    case 'people':
      return Icons.people_alt_rounded;
    default:
      return Icons.emoji_events_outlined;
  }
}

Color _achievementCategoryColor(String category, ColorScheme scheme) {
  switch (category) {
    case 'gold':
    case 'rare':
      return const Color(0xFFFFB300);
    case 'silver':
      return const Color(0xFF9E9E9E);
    case 'bronze':
      return const Color(0xFFCD7F32);
    case 'epic':
      return const Color(0xFF7C4DFF);
    case 'legendary':
      return const Color(0xFFFF5A7A);
    default:
      return scheme.primary;
  }
}

class ProfileAchievementCard extends StatelessWidget {
  final UserAchievement userAchievement;

  const ProfileAchievementCard({super.key, required this.userAchievement});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ach = userAchievement.achievement;
    final accent = _achievementCategoryColor(ach.category, scheme);

    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.16),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                _achievementIcon(ach.iconName),
                color: accent,
                size: 28,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          ach.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (ach.xpReward > 0) ...[
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
                            '+${ach.xpReward} XP',
                            style: TextStyle(
                              color: scheme.onPrimaryContainer,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ach.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    trf('Получено {p0}', {
                      'p0': formatDayMonthYear(userAchievement.achievedAt),
                    }),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant.withOpacity(0.7),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
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
//  КАРТОЧКА ОТЗЫВА
// ============================================================================

class ProfileReviewCard extends StatelessWidget {
  final Review review;

  const ProfileReviewCard({super.key, required this.review});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CosmeticAvatar(
                  frame: cosmeticById(review.authorCosmetics.avatarFrame),
                  radius: 18,
                  avatarUrl: review.authorAvatarUrl,
                  placeholderColor: scheme.primaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CosmeticNameText(
                        name: review.authorName ?? tr('Пользователь'),
                        def: cosmeticById(review.authorNameStyle),
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (review.questTitle != null)
                        Text(
                          trf('к квесту «{p0}»', {'p0': review.questTitle}),
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
                if (review.rating != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.star_rounded,
                          size: 13,
                          color: scheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          review.rating.toString(),
                          style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              review.textContent,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              formatRelativeOrDate(review.createdAt),
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (review.authorReply != null &&
                review.authorReply!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.reply_rounded,
                          size: 14,
                          color: scheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          tr('Ответ автора'),
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      review.authorReply!,
                      style: TextStyle(
                        color: scheme.onSecondaryContainer,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  КАРТОЧКА УВЕДОМЛЕНИЯ
// ============================================================================

IconData _notificationIcon(String type) {
  switch (type) {
    case 'quest_like':
    case 'wall_post_like':
    case 'comment_like':
      return Icons.favorite_rounded;
    case 'quest_review':
    case 'review_reply':
      return Icons.rate_review_rounded;
    case 'follow':
    case 'user_follow':
      return Icons.person_add_alt_1_rounded;
    case 'quest_published':
      return Icons.publish_rounded;
    case 'quest_updated':
      return Icons.update_rounded;
    case 'quest_download':
      return Icons.download_rounded;
    case 'quest_approved':
      return Icons.verified_rounded;
    case 'quest_rejected':
      return Icons.block_rounded;
    case 'achievement':
      return Icons.emoji_events_rounded;
    case 'comment':
    case 'reply':
    case 'wall_post_comment':
    case 'wall_post_comment_reply':
      return Icons.mode_comment_rounded;
    case 'wall_post_new':
      return Icons.article_rounded;
    case 'dm_message':
      return Icons.mail_outline_rounded;
    case 'system_news':
      return Icons.campaign_outlined;
    case 'forum_ban':
      return Icons.gavel_rounded;
    case 'forum_topic_removed':
      return Icons.remove_circle_outline_rounded;
    default:
      return Icons.notifications_rounded;
  }
}

Color _notificationColor(String type, ColorScheme scheme) {
  switch (type) {
    case 'quest_like':
    case 'wall_post_like':
    case 'comment_like':
      return const Color(0xFFE91E63);
    case 'quest_review':
    case 'review_reply':
      return const Color(0xFFFFB300);
    case 'follow':
    case 'user_follow':
      return const Color(0xFF7C4DFF);
    case 'quest_published':
    case 'quest_updated':
    case 'quest_approved':
    case 'wall_post_new':
      return const Color(0xFF3DDC84);
    case 'quest_download':
      return const Color(0xFF4FC3F7);
    case 'achievement':
      return const Color(0xFFFFB300);
    case 'quest_rejected':
      return scheme.error;
    default:
      return scheme.primary;
  }
}

/// Заголовок уведомления. Ник актёра — отдельным спаном с цветом из каталога:
/// градиент рисуют шейдером по границам текста, а они внутри фразы неизвестны,
/// поэтому здесь плоский цвет предмета.
InlineSpan _notificationTitle(AppNotification n) {
  final tail = switch (n.type) {
    'quest_like' => tr(' лайкнул(а) ваш квест'),
    'wall_post_like' => tr(' лайкнул(а) ваш пост'),
    'comment_like' => tr(' лайкнул(а) ваш комментарий'),
    'wall_post_comment' => tr(' прокомментировал(а) ваш пост'),
    'wall_post_comment_reply' => tr(' ответил(а) на ваш комментарий'),
    'quest_review' => tr(' оставил(а) отзыв'),
    'review_reply' => tr(' ответил(а) на ваш отзыв'),
    'follow' => tr(' подписался(ась) на вас'),
    'user_follow' => tr(' подписался(ась) на вас'),
    'wall_post_new' => tr(' опубликовал(а) новый пост'),
    'quest_published' => tr(' опубликовал(а) новый квест'),
    'quest_updated' => tr(' обновил(а) квест'),
    'quest_download' => tr(' скачал(а) ваш квест'),
    'comment' => tr(' написал(а) комментарий'),
    'reply' => tr(' написал(а) комментарий'),
    'dm_message' => tr(' написал(а) в личные сообщения'),
    _ => null,
  };
  if (tail == null) {
    return TextSpan(
      text: switch (n.type) {
        'quest_approved' => tr('Квест прошёл модерацию'),
        'quest_rejected' => tr('Квест отклонён модератором'),
        'achievement' => tr('Новое достижение!'),
        'system_news' => tr('Новости Meander'),
        'forum_ban' => tr('Бан в сообществе'),
        'forum_topic_removed' => tr('Топик удалён модератором'),
        _ => tr('Новое уведомление'),
      },
    );
  }
  return TextSpan(
    children: [
      TextSpan(
        text: n.actorName ?? tr('Кто-то'),
        style: cosmeticNameInlineStyle(n.actorNameStyle),
      ),
      TextSpan(text: tail),
    ],
  );
}

class ProfileNotificationTile extends ConsumerWidget {
  final AppNotification notification;
  final VoidCallback? onTap;

  const ProfileNotificationTile({
    super.key,
    required this.notification,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isRead = notification.isRead;
    final accent = _notificationColor(notification.type, scheme);
    // Форумское уведомление называет сообщество: «Бан в сообществе» без этого
    // так и остаётся гаданием, в каком именно.
    final forumNote = switch (notification.type) {
      'forum_ban' ||
      'forum_topic_removed' => notification.payload?['forum']?.toString(),
      _ => null,
    };
    final subtitle = notification.questTitle != null
        ? '«${notification.questTitle}»'
        : (forumNote == null || forumNote.isEmpty)
        ? null
        : trf('Сообщество: {p0}', {'p0': forumNote});

    return Material(
      color: isRead
          ? Colors.transparent
          : scheme.primaryContainer.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        onTap:
            onTap ??
            () {
              if (notification.postId != null &&
                  notification.postId!.isNotEmpty) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        PostLinkLoaderScreen(postId: notification.postId!),
                  ),
                );
              } else if (notification.questId != null &&
                  notification.questId!.isNotEmpty) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        MarketQuestLoaderScreen(questId: notification.questId!),
                  ),
                );
              } else if (notification.actorId != null &&
                  notification.actorId!.isNotEmpty) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ProfileScreen(userId: notification.actorId!),
                  ),
                );
              }
            },
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  CosmeticAvatar(
                    frame: cosmeticById(notification.actorAvatarFrame),
                    radius: 19,
                    avatarUrl: notification.actorAvatarUrl,
                    placeholderColor: accent.withOpacity(0.16),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isRead
                              ? scheme.surfaceContainerHigh
                              : scheme.primaryContainer,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        _notificationIcon(notification.type),
                        color: Colors.white,
                        size: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      _notificationTitle(notification),
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 13.5,
                        fontWeight: isRead ? FontWeight.w600 : FontWeight.w800,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      formatRelativeOrDate(notification.createdAt),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isRead) ...[
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
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
