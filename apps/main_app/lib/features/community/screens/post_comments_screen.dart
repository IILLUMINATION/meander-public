import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:canvas_app/features/editor/workspace/editor_screen_tabs.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/shared/widgets/image_sizing.dart';
import 'package:canvas_app/features/community/providers/community_feed_provider.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/models/wall_comment_model.dart';
import 'package:canvas_app/models/wall_post_model.dart';
import 'package:canvas_app/providers/wall_provider.dart';
import 'package:canvas_app/features/wall/providers/wall_paginated_provider.dart';
import 'package:canvas_app/features/wall/widgets/expandable_post_text.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/core/services/socket_service.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/comments/comment_composer.dart';
import 'package:canvas_app/shared/comments/comment_tile.dart';
import 'package:canvas_app/shared/comments/comment_view.dart';
import 'package:canvas_app/shared/comments/comments_screen.dart';
import 'package:canvas_app/shared/comments/comments_states.dart';

/// Экран комментариев к посту — M3 редизайн.
class PostCommentsScreen extends ConsumerStatefulWidget {
  final WallPost post;

  /// Чьё это обсуждение. Топик живёт на стене сообщества, но в общую ленту
  /// попадает перемешанным с постами людей — без подписи неясно, откуда
  /// человек и как вернуться к полке. У стены обоих полей нет, и строки нет.
  final String? communityLabel;
  final VoidCallback? onOpenCommunity;

  const PostCommentsScreen({
    super.key,
    required this.post,
    this.communityLabel,
    this.onOpenCommunity,
  });

  @override
  ConsumerState<PostCommentsScreen> createState() => _PostCommentsScreenState();
}

class _PostCommentsScreenState extends ConsumerState<PostCommentsScreen> {
  static const int _maxCommentLength = 500;

  final TextEditingController _commentController = TextEditingController();
  final FocusNode _commentFocus = FocusNode();
  bool _isSubmitting = false;
  late WallPost _currentPost;

  String? _replyingToCommentId;
  String? _replyingToUserName;
  AppLifecycleListener? _lifecycleListener;
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _currentPost = widget.post;
    _setupSockets();
    _lifecycleListener = AppLifecycleListener(
      onPause: _stopSockets,
      onResume: _setupSockets,
    );
    _registerView();
    _loadCurrentUser();
  }

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _currentUserId = prefs.getString('user_id'));
  }

  Future<void> _registerView() async {
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post(
        'api/author-walls/posts/${widget.post.id}/view',
      );
      if (response['new_view'] == true && mounted) {
        setState(() {
          _currentPost = _currentPost.copyWith(
            viewsCount: _currentPost.viewsCount + 1,
          );
        });
        ref
            .read(wallPaginatedProvider(_currentPost.authorId).notifier)
            .updatePostLocally(_currentPost);
        try {
          ref
              .read(communityFeedProvider('all').notifier)
              .updatePostLocally(_currentPost);
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _setupSockets() {
    SocketService().joinPostRoom(_currentPost.id, (data) {
      if (mounted) {
        ref.invalidate(wallPostCommentsProvider(_currentPost.id));
      }
    });
  }

  void _stopSockets() {
    SocketService().leavePostRoom(_currentPost.id);
  }

  void _cancelReply() {
    setState(() {
      _replyingToCommentId = null;
      _replyingToUserName = null;
      _commentController.clear();
    });
    _commentFocus.unfocus();
  }

  @override
  void dispose() {
    _stopSockets();
    _lifecycleListener?.dispose();
    _commentController.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  Future<void> _submitComment() async {
    final content = _commentController.text.trim();
    if (content.isEmpty || _isSubmitting) return;

    // Гость мог набрать комментарий целиком и потерять его об сырой 401 в
    // конце. Проверяем сессию до отправки — поле при этом не чистим.
    final hasAccount = await ensureAccount(
      context,
      why: tr(
        'Комментарии оставляют авторы с аккаунтом: модерация должна знать, от кого текст. Войдите на вкладке «Вход» — он останется в поле.',
      ),
    );
    if (!hasAccount || !mounted) return;

    setState(() => _isSubmitting = true);
    try {
      await ref
          .read(wallNotifierProvider.notifier)
          .addComment(_currentPost.id, content, parentId: _replyingToCommentId);

      _cancelReply();
      ref.invalidate(wallPostCommentsProvider(_currentPost.id));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Комментарий опубликован'))));
      }
    } catch (e) {
      if (mounted) {
        final scheme = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            backgroundColor: scheme.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // ── Действия с комментарием ────────────────────────────────────────
  //
  // Логика живёт на экране, а не внутри карточки: карточка общая с каналами,
  // и она не должна знать про `wallNotifierProvider`.

  Future<void> _toggleLike(WallComment comment) async {
    // Ошибку провайдер глотает, поэтому гостю оставалось недоумевать: тап,
    // анимация, и сердечко само вернулось назад.
    final hasAccount = await ensureAccount(
      context,
      why: tr(
        'Отметить комментарий может только автор с аккаунтом. Войдите на вкладке «Вход», и сердечко останется гореть.',
      ),
    );
    if (!hasAccount || !mounted) return;
    await ref
        .read(wallNotifierProvider.notifier)
        .toggleCommentLike(
          _currentPost.id,
          comment.id,
          comment.isLikedByViewer,
        );
  }

  void _startReply(WallComment comment) {
    setState(() {
      _replyingToCommentId = comment.id;
      _replyingToUserName = comment.userName;
      _commentController.text = '@${comment.userName}, ';
    });
    _commentFocus.requestFocus();
    _commentController.selection = TextSelection.fromPosition(
      TextPosition(offset: _commentController.text.length),
    );
  }

  Future<void> _editComment(WallComment comment) async {
    final controller = TextEditingController(text: comment.content);
    final newContent = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Редактировать')),
        content: TextField(
          controller: controller,
          maxLines: 4,
          minLines: 1,
          decoration: InputDecoration(
            hintText: tr('Текст комментария...'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (newContent == null ||
        newContent.isEmpty ||
        newContent == comment.content ||
        !mounted) {
      return;
    }
    try {
      await ref
          .read(wallNotifierProvider.notifier)
          .editComment(_currentPost.id, comment.id, newContent);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Комментарий обновлён'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
          ),
        );
      }
    }
  }

  Future<void> _deleteComment(WallComment comment) async {
    final scheme = Theme.of(context).colorScheme;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('Удалить комментарий?')),
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
    if (confirm != true || !mounted) return;
    try {
      await ref
          .read(wallNotifierProvider.notifier)
          .deleteComment(_currentPost.id, comment.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Комментарий удалён'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
          ),
        );
      }
    }
  }

  void _reportComment(WallComment comment) {
    showAppDialog(
      context: context,
      builder: (_) => ReportDialog(
        reportedType: 'wall_comment',
        reportedId: comment.id,
        reportedTitle: tr('Комментарий'),
      ),
    );
  }

  void _openAuthor(String userId) {
    if (userId.isEmpty) return;
    EditorScreenTabs.openProfile(context, userId);
  }

  /// Ветка комментариев в плоский список с глубиной — так вложенность
  /// читается, а виртуализация списка не теряется.
  List<_CommentListItem> _flatten(List<WallComment> comments) {
    final children = <String, List<WallComment>>{};
    for (final comment in comments) {
      if (comment.parentId != null) {
        children.putIfAbsent(comment.parentId!, () => []).add(comment);
      }
    }
    final flat = <_CommentListItem>[];
    void traverse(WallComment comment, int depth) {
      flat.add(_CommentListItem(comment, depth));
      for (final child in children[comment.id] ?? const []) {
        traverse(child, depth + 1);
      }
    }

    for (final root in comments.where((c) => c.parentId == null)) {
      traverse(root, 0);
    }
    return flat;
  }

  @override
  Widget build(BuildContext context) {
    final commentsAsync = ref.watch(wallPostCommentsProvider(_currentPost.id));

    Future<void> refreshComments() async {
      ref.invalidate(wallPostCommentsProvider(_currentPost.id));
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return CommentsScreen(
      onRefresh: refreshComments,
      header: _PostPreview(
        post: _currentPost,
        communityLabel: widget.communityLabel,
        onOpenCommunity: widget.onOpenCommunity,
      ),
      slivers: [
        commentsAsync.when(
          loading: () => const SliverToBoxAdapter(child: CommentsShimmer()),
          error: (_, _) => SliverToBoxAdapter(
            child: CommentsError(
              onRetry: () =>
                  ref.invalidate(wallPostCommentsProvider(_currentPost.id)),
            ),
          ),
          data: (comments) {
            if (comments.isEmpty) {
              return const SliverToBoxAdapter(child: CommentsEmpty());
            }
            final flat = _flatten(comments);
            return SliverPadding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = flat[index];
                  final comment = item.comment;
                  final isOwn =
                      _currentUserId != null &&
                      _currentUserId == comment.userId;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CommentTile(
                      key: ValueKey(comment.id),
                      depth: item.depth,
                      comment: CommentView(
                        id: comment.id,
                        authorId: comment.userId,
                        authorName: comment.userName,
                        avatarUrl: comment.userAvatarUrl,
                        nameStyle: comment.userNameStyle,
                        cosmetics: comment.userCosmetics,
                        body: comment.content,
                        createdAt: comment.createdAt,
                        likesCount: comment.likesCount,
                        likedByMe: comment.isLikedByViewer,
                        parentId: comment.parentId,
                      ),
                      onLike: () => _toggleLike(comment),
                      onReply: () => _startReply(comment),
                      onEdit: isOwn ? () => _editComment(comment) : null,
                      onDelete: isOwn ? () => _deleteComment(comment) : null,
                      onReport: () => _reportComment(comment),
                      onOpenAuthor: () => _openAuthor(comment.userId),
                    ),
                  );
                }, childCount: flat.length),
              ),
            );
          },
        ),
      ],
      composer: CommentComposer(
        controller: _commentController,
        focusNode: _commentFocus,
        isSubmitting: _isSubmitting,
        maxLength: _maxCommentLength,
        replyingToUserName: _replyingToUserName,
        onCancelReply: _cancelReply,
        onSubmit: _submitComment,
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}

class _CommentListItem {
  final WallComment comment;
  final int depth;
  _CommentListItem(this.comment, this.depth);
}

// ============================================================================
//  ПРЕВЬЮ ПОСТА (шапка над списком комментариев)
// ============================================================================

class _PostPreview extends StatelessWidget {
  final WallPost post;
  final String? communityLabel;
  final VoidCallback? onOpenCommunity;

  const _PostPreview({
    required this.post,
    this.communityLabel,
    this.onOpenCommunity,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final community = communityLabel;
    return Container(
      width: double.infinity,
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (community != null && community.trim().isNotEmpty) ...[
            _CommunityChip(label: community.trim(), onTap: onOpenCommunity),
            const SizedBox(height: 10),
          ],
          // Заголовок есть только у топика форума: у поста стены его никогда
          // не было, и экран не должен резервировать под него строку.
          if (post.title != null) ...[
            Text(
              post.title!,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              InkWell(
                onTap: () =>
                    EditorScreenTabs.openProfile(context, post.authorId),
                borderRadius: BorderRadius.circular(100),
                child: CosmeticAvatar(
                  frame: cosmeticById(post.authorCosmetics.avatarFrame),
                  radius: 18,
                  avatarUrl: post.authorAvatarUrl,
                  placeholderColor: scheme.primaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CosmeticNameText(
                      name: post.authorName,
                      def: cosmeticById(post.authorNameStyle),
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
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
              // Лайки/комментарии/просмотры — компактно
              _MiniStat(
                icon: post.isLikedByViewer
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                value: post.likesCount,
                color: post.isLikedByViewer
                    ? const Color(0xFFE91E63)
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              _MiniStat(
                icon: Icons.mode_comment_outlined,
                value: post.commentsCount,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              _MiniStat(
                icon: Icons.visibility_outlined,
                value: post.viewsCount,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ExpandablePostText(text: post.content, maxLines: 999),
          if (post.mediaUrls.isNotEmpty) ...[
            const SizedBox(height: 12),
            _PostCommentsMediaGrid(mediaUrls: post.mediaUrls),
          ],
          if (post.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: post.tags
                  .map(
                    (tag) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
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
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

/// Откуда топик. Пилюля кликабельна только когда вызывающий дал маршрут:
/// у поста стены сообщества нет, и мёртвая кнопка человеку не нужна.
class _CommunityChip extends StatelessWidget {
  const _CommunityChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      color: scheme.onSecondaryContainer,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    );

    return Material(
      color: scheme.secondaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.group_rounded,
                size: 14,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: scheme.onSecondaryContainer,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PostCommentsMediaGrid extends StatelessWidget {
  final List<String> mediaUrls;

  const _PostCommentsMediaGrid({required this.mediaUrls});

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
          memCacheWidth: imageDecodeWidth(context),
          placeholder: (_, _) =>
              Container(height: 200, color: scheme.surfaceContainerHighest),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: count,
      itemBuilder: (context, index) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: mediaUrls[index],
            fit: BoxFit.cover,
            memCacheWidth: imageDecodeWidth(context, divisor: 2),
            placeholder: (_, _) =>
                Container(color: scheme.surfaceContainerHighest),
          ),
        );
      },
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final int value;
  final Color color;
  const _MiniStat({
    required this.icon,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          formatCompactCount(value),
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
