import 'package:canvas_app/features/editor/workspace/editor_screen_tabs.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/features/channels/providers/channels_provider.dart';
import 'package:canvas_app/features/messages/widgets/chat_attachments.dart';
import 'package:canvas_app/shared/comments/comment_composer.dart';
import 'package:canvas_app/shared/comments/comment_tile.dart';
import 'package:canvas_app/shared/comments/comment_view.dart';
import 'package:canvas_app/shared/comments/comments_screen.dart';
import 'package:canvas_app/shared/comments/comments_states.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Комментарии к посту канала.
///
/// Экран не свой: та же оболочка, карточки, пустое/ошибочное состояние и поле
/// ввода, что у комментариев сообщества (`shared/comments`). Отличается только
/// источник данных — эндпоинт канала — и тем, что лайков и ответов в канале
/// нет, поэтому карточке не передаются соответствующие действия.
class ChannelCommentsScreen extends ConsumerStatefulWidget {
  const ChannelCommentsScreen({
    super.key,
    required this.post,
    this.channelTitle,
  });

  final ChannelPost post;

  /// Название канала в шапке: комментарий открывается из ленты, и без него
  /// непонятно, чей это пост.
  final String? channelTitle;

  @override
  ConsumerState<ChannelCommentsScreen> createState() =>
      _ChannelCommentsScreenState();
}

class _ChannelCommentsScreenState extends ConsumerState<ChannelCommentsScreen> {
  /// Серверный предел `COMMENT_BODY_MAX`.
  static const int _maxCommentLength = 1000;

  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final hasAccount = await ensureAccount(
      context,
      why: tr(
        'Комментарии оставляют авторы с аккаунтом: модерация должна знать, от кого текст. Войдите на вкладке «Вход» — он останется в поле.',
      ),
    );
    if (!hasAccount || !mounted) return;
    final sent = await ref
        .read(channelCommentsProvider(widget.post.id).notifier)
        .send(text);
    if (!mounted) return;
    if (sent) {
      _input.clear();
      setState(() {});
      ref
          .read(channelProvider(widget.post.channelId).notifier)
          .noteCommentAdded(widget.post.id);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Не удалось отправить комментарий'))),
      );
    }
  }

  void _openAuthor(String userId) {
    if (userId.isEmpty) return;
    EditorScreenTabs.openProfile(context, userId);
  }

  void _report(ChannelComment comment) {
    showAppDialog(
      context: context,
      builder: (_) => ReportDialog(
        reportedType: 'channel_comment',
        reportedId: comment.id,
        reportedTitle: tr('Комментарий'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(channelCommentsProvider(widget.post.id));

    Future<void> refresh() async {
      await ref.read(channelCommentsProvider(widget.post.id).notifier).load();
    }

    return CommentsScreen(
      onRefresh: refresh,
      header: _ChannelPostHeader(
        post: widget.post,
        channelTitle: widget.channelTitle,
      ),
      slivers: [
        if (state.isLoading)
          const SliverToBoxAdapter(child: CommentsShimmer())
        else if (state.error != null)
          SliverToBoxAdapter(child: CommentsError(onRetry: () => refresh()))
        else if (state.comments.isEmpty)
          SliverToBoxAdapter(child: CommentsEmpty())
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final comment = state.comments[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: CommentTile(
                    key: ValueKey(comment.id),
                    comment: CommentView(
                      id: comment.id,
                      authorId: comment.authorId,
                      authorName: comment.authorName ?? tr('Пользователь'),
                      avatarUrl: comment.authorAvatarUrl,
                      body: comment.body,
                      createdAt: comment.createdAt,
                    ),
                    onReport: () => _report(comment),
                    onOpenAuthor: () => _openAuthor(comment.authorId),
                  ),
                );
              }, childCount: state.comments.length),
            ),
          ),
      ],
      composer: CommentComposer(
        controller: _input,
        focusNode: _focus,
        isSubmitting: state.isSending,
        maxLength: _maxCommentLength,
        onSubmit: _send,
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}

/// Шапка: что именно комментируют. Вложения и текст поста — те же виджеты,
/// что в ленте канала, чтобы пост не выглядел другим в обсуждении.
class _ChannelPostHeader extends StatelessWidget {
  const _ChannelPostHeader({required this.post, this.channelTitle});

  final ChannelPost post;
  final String? channelTitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final title = channelTitle?.trim() ?? '';

    return Container(
      width: double.infinity,
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Material(
              color: scheme.secondaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.podcasts_rounded,
                      size: 14,
                      color: scheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSecondaryContainer,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (post.attachments.isNotEmpty) ...[
            ChatAttachmentGrid(attachments: post.attachments, width: 320),
            const SizedBox(height: 10),
          ],
          if (post.body.trim().isNotEmpty)
            AppMarkdownBlock(
              data: post.body,
              config: AppMarkdown.getConfig(context),
              selectable: false,
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                formatRelativeTime(post.createdAt),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.visibility_outlined,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '${post.viewsCount}',
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.mode_comment_outlined,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '${post.commentsCount}',
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
