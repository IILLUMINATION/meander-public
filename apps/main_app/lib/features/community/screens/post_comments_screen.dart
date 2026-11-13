import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';

import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/shared/widgets/image_sizing.dart';
import 'package:canvas_app/features/community/providers/community_feed_provider.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/models/wall_comment_model.dart';
import 'package:canvas_app/models/wall_post_model.dart';
import 'package:canvas_app/providers/wall_provider.dart';
import 'package:canvas_app/features/wall/providers/wall_paginated_provider.dart';
import 'package:canvas_app/features/wall/widgets/expandable_post_text.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/core/services/socket_service.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

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
  }

  Future<void> _registerView() async {
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post('api/author-walls/posts/${widget.post.id}/view');
      if (response['new_view'] == true && mounted) {
        setState(() {
          _currentPost = _currentPost.copyWith(viewsCount: _currentPost.viewsCount + 1);
        });
        ref.read(wallPaginatedProvider(_currentPost.authorId).notifier).updatePostLocally(_currentPost);
        try { ref.read(communityFeedProvider('all').notifier).updatePostLocally(_currentPost); } catch (_) {}
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
      why:
          tr('Комментарии оставляют авторы с аккаунтом: модерация должна знать, от кого текст. Войдите на вкладке «Вход» — он останется в поле.'),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Комментарий опубликован'))),
        );
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final commentsAsync = ref.watch(wallPostCommentsProvider(_currentPost.id));

    Future<void> refreshComments() async {
      ref.invalidate(wallPostCommentsProvider(_currentPost.id));
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(
          tr('Комментарии'),
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 1,
      ),
      body: AdaptiveContent(maxWidth: 760, child: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: refreshComments,
              child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _PostPreview(
                    post: _currentPost,
                    communityLabel: widget.communityLabel,
                    onOpenCommunity: widget.onOpenCommunity,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Divider(height: 1, color: scheme.outlineVariant),
                ),
                commentsAsync.when(
                  loading: () => const SliverToBoxAdapter(child: _CommentsShimmer()),
                  error: (e, _) => SliverToBoxAdapter(
                    child: _CommentsError(
                      error: e,
                      onRetry: () =>
                          ref.invalidate(wallPostCommentsProvider(_currentPost.id)),
                    ),
                  ),
                  data: (comments) {
                    if (comments.isEmpty) return const SliverToBoxAdapter(child: _CommentsEmpty());
                    
                    // Build a tree of comments
                    final rootComments = comments.where((c) => c.parentId == null).toList();
                    final childrenMap = <String, List<WallComment>>{};
                    
                    for (final c in comments) {
                      if (c.parentId != null) {
                        childrenMap[c.parentId!] ??= [];
                        childrenMap[c.parentId!]!.add(c);
                      }
                    }
                    
                    final flatList = <_CommentListItem>[];
                    void traverse(WallComment comment, int depth) {
                      flatList.add(_CommentListItem(comment, depth));
                      final children = childrenMap[comment.id] ?? [];
                      // Sort children by date if needed, but they are likely already sorted from API
                      for (final child in children) {
                        traverse(child, depth + 1);
                      }
                    }
                    
                    for (final root in rootComments) {
                      traverse(root, 0);
                    }
                    
                    return SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 12,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final item = flatList[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8.0),
                              child: _CommentTile(
                                key: ValueKey(item.comment.id),
                                comment: item.comment,
                                postId: _currentPost.id,
                                depth: item.depth,
                                onReply: (userName, commentId) {
                                  setState(() {
                                    _replyingToCommentId = commentId;
                                    _replyingToUserName = userName;
                                    _commentController.text = '@$userName, ';
                                  });
                                  _commentFocus.requestFocus();
                                  _commentController.selection = TextSelection.fromPosition(
                                    TextPosition(offset: _commentController.text.length),
                                  );
                                },
                              ),
                            );
                          },
                          childCount: flatList.length,
                        ),
                      ),
                    );
                  },
                ),
                ],
              ),
            ),
          ),
          _CommentInput(
            controller: _commentController,
            focusNode: _commentFocus,
            isSubmitting: _isSubmitting,
            maxLength: _maxCommentLength,
            replyingToUserName: _replyingToUserName,
            onCancelReply: _cancelReply,
            onSubmit: _submitComment,
            onChanged: (_) => setState(() {}),
          ),
        ],
      )),
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
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
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
              children: post.tags.map((tag) => Container(
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
              )).toList(),
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
          placeholder: (_, __) => Container(height: 200, color: scheme.surfaceContainerHighest),
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
            placeholder: (_, __) => Container(color: scheme.surfaceContainerHighest),
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

// ============================================================================
//  EMPTY / ERROR
// ============================================================================

class _CommentsEmpty extends StatelessWidget {
  const _CommentsEmpty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
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
              child: Icon(
                Icons.mode_comment_outlined,
                size: 32,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              tr('Пока нет комментариев'),
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tr('Будьте первым, кто оставит мнение'),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentsError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _CommentsError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              tr('Не удалось загрузить'),
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
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
//  КАРТОЧКА КОММЕНТАРИЯ (M3)
// ============================================================================

class _CommentTile extends ConsumerStatefulWidget {
  final WallComment comment;
  final String postId;
  final int depth;
  final void Function(String userName, String commentId)? onReply;

  const _CommentTile({
    super.key,
    required this.comment, 
    required this.postId, 
    this.depth = 0,
    this.onReply,
  });

  @override
  ConsumerState<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends ConsumerState<_CommentTile> {
  bool _likeAnim = false;
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
  }

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _currentUserId = prefs.getString('user_id');
      });
    }
  }

  Future<void> _toggleLike() async {
    // Ошибку провайдер глотает, поэтому гостю оставалось недоумевать: тап,
    // анимация, и сердечко само вернулось назад.
    final hasAccount = await ensureAccount(
      context,
      why:
          tr('Отметить комментарий может только автор с аккаунтом. Войдите на вкладке «Вход», и сердечко останется гореть.'),
    );
    if (!hasAccount || !mounted) return;

    setState(() => _likeAnim = true);
    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _likeAnim = false);
    });
    await ref
        .read(wallNotifierProvider.notifier)
        .toggleCommentLike(
          widget.postId,
          widget.comment.id,
          widget.comment.isLikedByViewer,
        );
  }

  void _openMenu(BuildContext anchor) async {
    final scheme = Theme.of(anchor).colorScheme;
    final isOwn = _currentUserId == widget.comment.userId;

    final result = await showMenu<String>(
      context: anchor,
      position: RelativeRect.fromLTRB(1000, 200, 0, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: [
        PopupMenuItem(
          value: 'reply',
          child: Row(
            children: [
              Icon(Icons.reply_rounded, size: 18, color: scheme.onSurface),
              const SizedBox(width: 10),
              Text(tr('Ответить'), style: TextStyle(color: scheme.onSurface)),
            ],
          ),
        ),
        if (isOwn) ...[
          PopupMenuItem(
            value: 'edit',
            child: Row(
              children: [
                Icon(Icons.edit_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Text(tr('Редактировать'), style: TextStyle(color: scheme.primary)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline_rounded, size: 18, color: scheme.error),
                const SizedBox(width: 10),
                Text(tr('Удалить'), style: TextStyle(color: scheme.error)),
              ],
            ),
          ),
        ],
        PopupMenuItem(
          value: 'report',
          child: Row(
            children: [
              Icon(Icons.flag_outlined, size: 18, color: scheme.error),
              const SizedBox(width: 10),
              Text(tr('Пожаловаться'), style: TextStyle(color: scheme.error)),
            ],
          ),
        ),
      ],
    );

    if (!mounted) return;

    if (result == 'report') {
      showAppDialog(
        context: context,
        builder: (_) => ReportDialog(
          reportedType: 'wall_comment',
          reportedId: widget.comment.id,
          reportedTitle: tr('Комментарий'),
        ),
      );
    } else if (result == 'reply') {
      widget.onReply?.call(widget.comment.userName, widget.comment.id);
    } else if (result == 'delete') {
      _confirmDelete();
    } else if (result == 'edit') {
      _showEditDialog();
    }
  }

  Future<void> _confirmDelete() async {
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

    if (confirm != true) return;

    try {
      await ref.read(wallNotifierProvider.notifier).deleteComment(widget.postId, widget.comment.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Комментарий удалён'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
      }
    }
  }

  Future<void> _showEditDialog() async {
    final controller = TextEditingController(text: widget.comment.content);

    final newContent = await showAppDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(tr('Редактировать')),
          content: TextField(
            controller: controller,
            maxLines: 4,
            minLines: 1,
            decoration: InputDecoration(
              hintText: tr('Текст комментария...'),
              border: OutlineInputBorder(),
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
        );
      },
    );

    if (newContent != null && newContent.isNotEmpty && newContent != widget.comment.content) {
      try {
        await ref.read(wallNotifierProvider.notifier).editComment(widget.postId, widget.comment.id, newContent);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Комментарий обновлён'))));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.comment;
    final double paddingLeft = 12.0 + (widget.depth * 24.0); // Indentation for tree
    
    return Container(
      margin: EdgeInsets.only(left: widget.depth > 0 ? paddingLeft : 0),
      decoration: widget.depth > 0 ? BoxDecoration(
        border: Border(
          left: BorderSide(
            color: scheme.outlineVariant.withOpacity(0.5),
            width: 2,
          ),
        ),
      ) : null,
      child: Material(
        color: widget.depth > 0 ? scheme.surfaceContainerHigh.withOpacity(0.6) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topRight: const Radius.circular(18),
          bottomRight: const Radius.circular(18),
          topLeft: Radius.circular(widget.depth > 0 ? 4 : 18),
          bottomLeft: Radius.circular(widget.depth > 0 ? 4 : 18),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProfileScreen(userId: c.userId),
                  ),
                ),
                borderRadius: BorderRadius.circular(100),
                child: CosmeticAvatar(
                  frame: cosmeticById(c.userCosmetics.avatarFrame),
                  radius: 18,
                  avatarUrl: c.userAvatarUrl,
                  placeholderColor: scheme.primaryContainer,
                  fallback: _AvatarFallback(
                    name: c.userName,
                    color: scheme.primaryContainer,
                    textColor: scheme.onPrimaryContainer,
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
                        Flexible(
                          child: CosmeticNameText(
                            name: c.userName,
                            def: cosmeticById(c.userNameStyle),
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatRelativeTime(c.createdAt),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    MeanderEntityMarkdown(
                      data: c.content,
                      config: AppMarkdown.getConfig(context),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        InkWell(
                          onTap: _toggleLike,
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            child: Row(
                              children: [
                                AnimatedScale(
                                  scale: _likeAnim ? 1.35 : 1.0,
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOutBack,
                                  child: Icon(
                                    c.isLikedByViewer
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    size: 16,
                                    color: c.isLikedByViewer
                                        ? const Color(0xFFE91E63)
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                                if (c.likesCount > 0) ...[
                                  const SizedBox(width: 4),
                                  Text(
                                    formatCompactCount(c.likesCount),
                                    style: TextStyle(
                                      color: c.isLikedByViewer
                                          ? const Color(0xFFE91E63)
                                          : scheme.onSurfaceVariant,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 32,
                height: 32,
                child: Builder(
                  builder: (anchor) => IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    onPressed: () => _openMenu(anchor),
                    tooltip: tr('Действия'),
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

// ============================================================================
//  ПОЛЕ ВВОДА (sticky)
// ============================================================================

class _CommentInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isSubmitting;
  final int maxLength;
  final String? replyingToUserName;
  final VoidCallback onCancelReply;
  final VoidCallback onSubmit;
  final ValueChanged<String> onChanged;

  const _CommentInput({
    required this.controller,
    required this.focusNode,
    required this.isSubmitting,
    required this.maxLength,
    this.replyingToUserName,
    required this.onCancelReply,
    required this.onSubmit,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = controller.text.trim().isNotEmpty;
    final length = controller.text.runes.length;
    final overLimit = length > maxLength;
    final canSubmit = hasText && !isSubmitting && !overLimit;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (replyingToUserName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0, left: 4),
                child: Row(
                  children: [
                    Icon(Icons.reply_rounded, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      trf('Ответ пользователю {replyingToUserName}', {'replyingToUserName': replyingToUserName}),
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: onCancelReply,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Icon(Icons.close_rounded, size: 16, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Material(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 14.5,
                            height: 1.4,
                          ),
                          maxLines: 5,
                          minLines: 1,
                          maxLength: maxLength,
                          maxLengthEnforcement: MaxLengthEnforcement.enforced,
                          textCapitalization: TextCapitalization.sentences,
                          onChanged: onChanged,
                          buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                          decoration: InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            hintText: tr('Написать комментарий…'),
                            hintStyle: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 14.5,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 10,
                            ),
                          ),
                        ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: canSubmit
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: canSubmit ? onSubmit : null,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: isSubmitting
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onPrimary,
                                ),
                              )
                            : Icon(
                                Icons.send_rounded,
                                size: 20,
                                color: canSubmit
                                    ? scheme.onPrimary
                                    : scheme.onSurfaceVariant,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (length > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 56),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '$length / $maxLength',
                    style: TextStyle(
                      color: overLimit ? scheme.error : scheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  final String name;
  final Color color;
  final Color textColor;

  const _AvatarFallback({
    required this.name,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      child: Center(
        child: Text(
          (name.isNotEmpty ? name.substring(0, 1) : '?').toUpperCase(),
          style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

// ============================================================================
//  SHIMMER
// ============================================================================

class _CommentsShimmer extends StatelessWidget {
  const _CommentsShimmer();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: 5,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, __) {
        return Shimmer.fromColors(
          baseColor: scheme.surfaceContainerHigh,
          highlightColor: scheme.surfaceContainerHighest,
          child: Container(
            height: 78,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        );
      },
    );
  }
}
