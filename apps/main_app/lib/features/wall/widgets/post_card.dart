import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/community/providers/community_feed_provider.dart';
import 'package:canvas_app/features/community/screens/post_comments_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/features/profile/widgets/user_block_actions.dart';
import 'package:canvas_app/features/wall/screens/create_post_screen.dart';
import 'package:canvas_app/features/wall/providers/wall_paginated_provider.dart';
import 'package:canvas_app/features/wall/widgets/expandable_post_text.dart';
import 'package:canvas_app/models/wall_post_model.dart';
import 'package:canvas_app/providers/wall_provider.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';

/// M3 карточка поста для стены пользователя.
class PostCard extends ConsumerStatefulWidget {
  final WallPost post;

  /// Если `true` — пост принадлежит просматриваемому пользователю
  /// (значит, можно показывать «Удалить» в меню).
  final bool isOwn;

  /// Optional callback to notify parent screens (like Community Feed) about local updates
  final ValueChanged<WallPost>? onPostUpdated;
  
  /// Optional callback to notify parent screens about deletion
  final VoidCallback? onPostDeleted;

  const PostCard({super.key, required this.post, this.isOwn = false, this.onPostUpdated, this.onPostDeleted});

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  static final Set<String> _viewedPostIds = {};
  Timer? _viewTimer;

  @override
  void initState() {
    super.initState();
    if (!_viewedPostIds.contains(widget.post.id)) {
      _viewTimer = Timer(const Duration(milliseconds: 2500), _registerView);
    }
  }

  @override
  void dispose() {
    _viewTimer?.cancel();
    super.dispose();
  }

  Future<void> _registerView() async {
    if (!mounted) return;
    _viewedPostIds.add(widget.post.id);

    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post('api/author-walls/posts/${widget.post.id}/view');
      if (response['new_view'] == true && mounted) {
        final updatedPost = widget.post.copyWith(viewsCount: widget.post.viewsCount + 1);
        ref.read(wallPaginatedProvider(widget.post.authorId).notifier).updatePostLocally(updatedPost);
        try { ref.read(communityFeedProvider('all').notifier).updatePostLocally(updatedPost); } catch (_) {}
        try { ref.read(communityFeedProvider('following').notifier).updatePostLocally(updatedPost); } catch (_) {}
        widget.onPostUpdated?.call(updatedPost);
      }
    } catch (_) {}
  }

  /// Ссылка на пост — всегда публичный хост: `apiUrl` в debug-сборке указывает
  /// на локальный сервер, и такая ссылка не открылась бы у получателя.
  /// На десктопе системный share — это `mailto:` (Linux) или ничего, поэтому
  /// там, как и в квесте с профилем, просто копируем.
  void _sharePost() {
    final link = '${AppConfig.vpsApiBaseUrl}/share/post/${widget.post.id}';
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      Clipboard.setData(ClipboardData(text: link));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Ссылка скопирована в буфер обмена')),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      Share.share(link, subject: tr('Пост в Meander'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final post = widget.post;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openComments(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(
                  post: post,
                  isOwn: widget.isOwn,
                  onAction: (a) async {
                    switch (a) {
                      case _PostAction.edit:
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CreatePostScreen(postToEdit: post),
                          ),
                        );
                        break;
                      case _PostAction.delete:
                        _confirmDelete(context, ref);
                        break;
                      case _PostAction.report:
                        showAppDialog(
                          context: context,
                          builder: (_) => ReportDialog(
                            reportedType: 'wall_post',
                            reportedId: post.id,
                            reportedTitle: tr('Пост на стене'),
                          ),
                        );
                        break;
                      case _PostAction.share:
                        _sharePost();
                        break;
                      case _PostAction.block:
                        await confirmUserBlock(
                          context,
                          ref,
                          userId: post.authorId,
                          blocked: false,
                          name: post.authorName,
                        );
                        break;
                    }
                  },
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ExpandablePostText(text: post.content),
                ),
                if (post.mediaUrls.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _PostMediaGrid(mediaUrls: post.mediaUrls),
                ],
                if (post.tags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: post.tags.map((tag) => _TagChip(tag: tag)).toList(),
                  ),
                ],
                const SizedBox(height: 10),
                _ActionsRow(post: post, onPostUpdated: widget.onPostUpdated),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openComments(BuildContext context) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => PostCommentsScreen(post: widget.post),
        transitionsBuilder: (_, animation, __, child) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 280),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final scheme = Theme.of(context).colorScheme;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('Удалить пост?')),
        content: Text(tr('Это действие нельзя отменить.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ref
          .read(wallNotifierProvider.notifier)
          .deletePost(widget.post.authorId, widget.post.id);
      ref
          .read(wallPaginatedProvider(widget.post.authorId).notifier)
          .removePostLocally(widget.post.id);
      if (widget.onPostDeleted != null) {
        widget.onPostDeleted!();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Пост удалён'))));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            backgroundColor: scheme.errorContainer,
          ),
        );
      }
    }
  }
}

enum _PostAction { edit, delete, report, share, block }

class _Header extends StatelessWidget {
  final WallPost post;
  final bool isOwn;
  final ValueChanged<_PostAction> onAction;

  const _Header({
    required this.post,
    required this.isOwn,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ProfileScreen(userId: post.authorId),
            ),
          ),
                borderRadius: BorderRadius.circular(100),
                child: CosmeticAvatar(
                  frame: cosmeticById(post.authorCosmetics.avatarFrame),
                  radius: 19,
                  avatarUrl: post.authorAvatarUrl,
                  placeholderColor: scheme.primaryContainer,
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: CosmeticNameText(
                      name: post.authorName,
                      def: cosmeticById(post.authorNameStyle),
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (post.isAuthorVerified) ...[
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.verified_rounded,
                      color: Color(0xFF1976D2),
                      size: 14,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 1),
              Text(
                formatRelativeTime(post.createdAt),
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        PopupMenuButton<_PostAction>(
          icon: Icon(
            Icons.more_horiz_rounded,
            color: scheme.onSurfaceVariant,
            size: 22,
          ),
          tooltip: tr('Действия'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          color: scheme.surfaceContainerHighest,
          elevation: 2,
          onSelected: onAction,
          itemBuilder: (context) => [
            if (isOwn) ...[
              PopupMenuItem(
                value: _PostAction.edit,
                child: Row(
                  children: [
                    Icon(
                      Icons.edit_rounded,
                      color: scheme.primary,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Text(tr('Редактировать'), style: TextStyle(color: scheme.primary)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _PostAction.delete,
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      color: scheme.error,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Text(tr('Удалить'), style: TextStyle(color: scheme.error)),
                  ],
                ),
              ),
            ],
            PopupMenuItem(
              value: _PostAction.share,
              child: Row(
                children: [
                  Icon(
                    Icons.share_rounded,
                    color: scheme.onSurfaceVariant,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    tr('Поделиться'),
                    style: TextStyle(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
            PopupMenuItem(
              value: _PostAction.report,
              child: Row(
                children: [
                  Icon(
                    Icons.flag_outlined,
                    color: scheme.onSurfaceVariant,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    tr('Пожаловаться'),
                    style: TextStyle(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
            if (!isOwn)
              PopupMenuItem(
                value: _PostAction.block,
                child: Row(
                  children: [
                    Icon(
                      Icons.block_rounded,
                      color: scheme.error,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        tr('Заблокировать автора'),
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  final String tag;
  const _TagChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '#$tag',
        style: TextStyle(
          color: scheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PostMediaGrid extends StatelessWidget {
  final List<String> mediaUrls;

  const _PostMediaGrid({required this.mediaUrls});

  @override
  Widget build(BuildContext context) {
    if (mediaUrls.isEmpty) return const SizedBox.shrink();

    final count = mediaUrls.length;
    final scheme = Theme.of(context).colorScheme;

    if (count == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: CachedNetworkImage(
          imageUrl: mediaUrls[0],
          fit: BoxFit.cover,
          width: double.infinity,
          height: 200,
          placeholder: (_, __) => Container(color: scheme.surfaceContainerHighest),
        ),
      );
    }

    if (count == 2) {
      return SizedBox(
        height: 180,
        child: Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                ),
                child: CachedNetworkImage(
                  imageUrl: mediaUrls[0],
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (_, __) => Container(color: scheme.surfaceContainerHighest),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
                child: CachedNetworkImage(
                  imageUrl: mediaUrls[1],
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (_, __) => Container(color: scheme.surfaceContainerHighest),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // For 3 or 4 images, simple grid
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: count > 4 ? 4 : count,
      itemBuilder: (context, index) {
        final isLast = index == 3 && count > 4;
        
        return ClipRRect(
          borderRadius: BorderRadius.circular(
            count == 3 && index == 2 ? 16 : 8,
          ), // Simplified border radius for grid
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                imageUrl: mediaUrls[index],
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: scheme.surfaceContainerHighest),
              ),
              if (isLast)
                Container(
                  color: Colors.black54,
                  child: Center(
                    child: Text(
                      '+${count - 4}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ActionsRow extends ConsumerStatefulWidget {
  final WallPost post;
  final ValueChanged<WallPost>? onPostUpdated;
  const _ActionsRow({required this.post, this.onPostUpdated});

  @override
  ConsumerState<_ActionsRow> createState() => _ActionsRowState();
}

class _ActionsRowState extends ConsumerState<_ActionsRow> {
  bool _animLike = false;

  Future<void> _toggleLike() async {
    // Гость видел «Не удалось изменить лайк» — про отметку, которую сервер
    // у него не принимал даже попытаться: без сессии POST /like отдаёт 401.
    final hasAccount = await ensureAccount(
      context,
      why:
          tr('Лайк сервер привязывает к аккаунту — анонимных отметок нет. Войдите на вкладке «Вход», и сердечко заработает.'),
    );
    if (!hasAccount || !mounted) return;

    setState(() => _animLike = true);
    Future.delayed(const Duration(milliseconds: 240), () {
      if (mounted) setState(() => _animLike = false);
    });

    // Optimistic UI update
    final original = widget.post;
    final currentLiked = original.isLikedByViewer;
    final paintedLiked = !currentLiked;
    final updatedPost = original.copyWith(
      isLikedByViewer: paintedLiked,
      likesCount: original.likesCount + (currentLiked ? -1 : 1),
    );
    ref.read(wallPaginatedProvider(widget.post.authorId).notifier).updatePostLocally(updatedPost);
    widget.onPostUpdated?.call(updatedPost);

    // Ядро возвращает фактическое состояние лайка, а при сетевой ошибке —
    // старое значение. Значит любое расхождение с нарисованным = запрос не
    // дошёл: без отката сердечко горело бы на посте, который сервер не
    // помеченным считает, и следующий тап отправил бы не то действие.
    final liked = await ref
        .read(wallNotifierProvider.notifier)
        .toggleLike(
          widget.post.authorId,
          widget.post.id,
          currentLiked,
        );
    if (!mounted || liked == paintedLiked) return;
    ref.read(wallPaginatedProvider(widget.post.authorId).notifier).updatePostLocally(original);
    widget.onPostUpdated?.call(original);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Не удалось изменить лайк'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final post = widget.post;
    return Row(
      children: [
        Flexible(
          child: _ActionPill(
            icon: post.isLikedByViewer
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            label: formatCompactCount(post.likesCount),
            color: post.isLikedByViewer
                ? const Color(0xFFE91E63)
                : scheme.onSurfaceVariant,
            background: post.isLikedByViewer
                ? const Color(0xFFE91E63).withOpacity(0.12)
                : Colors.transparent,
            animateIcon: _animLike,
            onTap: _toggleLike,
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: _ActionPill(
            icon: Icons.mode_comment_outlined,
            label: formatCompactCount(post.commentsCount),
            color: scheme.onSurfaceVariant,
            background: Colors.transparent,
            onTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (_, __, ___) => PostCommentsScreen(post: post),
                transitionsBuilder: (_, animation, __, child) {
                  return SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(0, 1),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                    child: child,
                  );
                },
                transitionDuration: const Duration(milliseconds: 280),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: _ActionPill(
            icon: Icons.visibility_outlined,
            label: formatCompactCount(post.viewsCount),
            color: scheme.onSurfaceVariant,
            background: Colors.transparent,
          ),
        ),
      ],
    );
  }
}

class _ActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color background;
  final bool animateIcon;

  /// `null` — пилюля не нажимается: счётчик просмотров это только цифра, и
  ///ripple по ней обещал тап, которого нет.
  final VoidCallback? onTap;

  const _ActionPill({
    required this.icon,
    required this.label,
    required this.color,
    required this.background,
    this.onTap,
    this.animateIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: animateIcon ? 1.35 : 1.0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutBack,
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
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
