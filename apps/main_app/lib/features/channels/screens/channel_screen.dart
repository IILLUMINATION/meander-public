import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/features/channels/providers/channels_provider.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/services/chat_media_service.dart';
import 'package:canvas_app/features/messages/widgets/chat_attachments.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Канал: шапка с подпиской и лента постов. Писать может владелец и его
/// админы — подписчику композер не показывается.
class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<DmAttachment> _draft = [];
  bool _uploading = false;
  bool _composerOpen = false;
  final Set<String> _viewed = {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >
          _scroll.position.maxScrollExtent - 400) {
        ref.read(channelProvider(widget.channelId).notifier).loadOlder();
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final text = _input.text.trim();
    if (text.isEmpty && _draft.isEmpty) return;
    final notifier = ref.read(channelProvider(widget.channelId).notifier);
    final outgoing = List<DmAttachment>.of(_draft);
    final error = await notifier.publish(text, attachments: outgoing);
    if (!mounted) return;
    if (error == null) {
      _input.clear();
      setState(() {
        _draft.clear();
        _composerOpen = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _pickPhotos() async {
    if (_uploading || _draft.length >= ChatMediaService.albumLimit) return;
    try {
      final picked = await ChatMediaService.pickAlbum(
        remaining: ChatMediaService.albumLimit - _draft.length,
      );
      if (picked.isEmpty || !mounted) return;
      for (final file in picked) {
        if (await file.length() > ChatMediaService.maxBytes) continue;
        if (!mounted) return;
        setState(() => _uploading = true);
        final attachment = await ChatMediaService.upload(file);
        if (!mounted) return;
        setState(() => _draft.add(attachment));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _toggle() async {
    final error = await ref
        .read(channelProvider(widget.channelId).notifier)
        .toggleSubscription();
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(channelProvider(widget.channelId));
    final channel = state.channel;

    // Просмотр отмечаем по факту показа: первый кадр ленты = прочитано.
    for (final post in state.posts.take(3)) {
      if (_viewed.add(post.id)) {
        ref.read(channelProvider(widget.channelId).notifier).markViewed(post.id);
      }
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Text(channel?.title ?? tr('Канал')),
        actions: [
          if (channel != null && channel.commentsEnabled)
            IconButton(
              tooltip: tr('Обновить'),
              onPressed: () =>
                  ref.read(channelProvider(widget.channelId).notifier).load(),
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      floatingActionButton: channel != null && channel.canPost
          ? FloatingActionButton(
              key: const ValueKey('channel-compose'),
              onPressed: () => setState(() => _composerOpen = true),
              child: const Icon(Icons.edit_rounded),
            )
          : null,
      body: state.isLoading && channel == null
          ? Center(child: CircularProgressIndicator(color: scheme.primary))
          : state.error != null && channel == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(state.error!, textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: AdaptiveContent(
                    maxWidth: 760,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                      itemCount: state.posts.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return channel == null
                              ? const SizedBox.shrink()
                              : _ChannelHeader(
                                  channel: channel,
                                  onToggle: _toggle,
                                );
                        }
                        final post = state.posts[index - 1];
                        return _PostCard(
                          post: post,
                          canDelete: channel?.canPost ?? false,
                          onDelete: () => ref
                              .read(channelProvider(widget.channelId).notifier)
                              .deletePost(post.id),
                          onComments: channel?.commentsEnabled ?? true
                              ? () => _openComments(context, post)
                              : null,
                        );
                      },
                    ),
                  ),
                ),
                if (_composerOpen && channel != null && channel.canPost)
                  _PostComposer(
                    controller: _input,
                    isSending: state.isSending,
                    draft: _draft,
                    uploading: _uploading,
                    onPickPhotos: _pickPhotos,
                    onRemove: (index) =>
                        setState(() => _draft.removeAt(index)),
                    onPublish: _publish,
                    onClose: () => setState(() {
                      _composerOpen = false;
                      _draft.clear();
                      _input.clear();
                    }),
                  ),
              ],
            ),
    );
  }

  void _openComments(BuildContext context, ChannelPost post) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CommentsSheet(post: post),
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({required this.channel, required this.onToggle});

  final Channel channel;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CosmeticAvatar(
                frame: null,
                avatarUrl: channel.avatarUrl,
                radius: 32,
                placeholderColor: scheme.surfaceContainerHighest,
                fallback: Icon(Icons.podcasts_rounded, color: scheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel.title,
                      style: textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      channelMetaLine(channel),
                      style: textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (channel.canPost)
                FilledButton.tonal(
                  onPressed: null,
                  child: Text(tr('Владелец')),
                )
              else
                FilledButton.tonal(
                  key: const ValueKey('channel-subscribe'),
                  onPressed: onToggle,
                  child: Text(
                    channel.isSubscribed ? tr('Отписаться') : tr('Подписаться'),
                  ),
                ),
            ],
          ),
          if (channel.description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              channel.description,
              style: textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
          ],
          const SizedBox(height: 8),
          Divider(color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.post,
    required this.canDelete,
    required this.onDelete,
    this.onComments,
  });

  final ChannelPost post;
  final bool canDelete;
  final Future<String?> Function() onDelete;
  final VoidCallback? onComments;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          const SizedBox(height: 8),
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
              if (onComments != null) ...[
                const SizedBox(width: 12),
                InkWell(
                  onTap: onComments,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Row(
                      children: [
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
                  ),
                ),
              ],
              const Spacer(),
              if (canDelete)
                IconButton(
                  onPressed: () => onDelete(),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
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

class _PostComposer extends StatelessWidget {
  const _PostComposer({
    required this.controller,
    required this.isSending,
    required this.draft,
    required this.uploading,
    required this.onPickPhotos,
    required this.onRemove,
    required this.onPublish,
    required this.onClose,
  });

  final TextEditingController controller;
  final bool isSending;
  final List<DmAttachment> draft;
  final bool uploading;
  final VoidCallback onPickPhotos;
  final void Function(int index) onRemove;
  final VoidCallback onPublish;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AlbumDraftStrip(
              previews: draft,
              isUploading: uploading,
              onRemove: onRemove,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: onClose,
                    icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
                  ),
                  IconButton(
                    key: const ValueKey('channel-attach'),
                    onPressed: uploading ? null : onPickPhotos,
                    icon: Icon(
                      Icons.add_photo_alternate_outlined,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 8,
                      decoration: InputDecoration(
                        hintText: tr('Пост для подписчиков…'),
                        filled: true,
                        fillColor: scheme.surfaceContainerHigh,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: isSending ? null : onPublish,
                    icon: isSending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
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

class _CommentsSheet extends ConsumerStatefulWidget {
  const _CommentsSheet({required this.post});

  final ChannelPost post;

  @override
  ConsumerState<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<_CommentsSheet> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final sent = await ref
        .read(channelCommentsProvider(widget.post.id).notifier)
        .send(text);
    if (sent && mounted) _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(channelCommentsProvider(widget.post.id));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scroll) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  tr('Комментарии'),
                  style: textTheme.titleMedium,
                ),
              ),
            ),
            Expanded(
              child: state.isLoading
                  ? Center(
                      child: CircularProgressIndicator(color: scheme.primary),
                    )
                  : state.comments.isEmpty
                  ? Center(
                      child: Text(
                        tr('Пока никто не написал'),
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: state.comments.length,
                      itemBuilder: (context, index) {
                        final comment = state.comments[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CosmeticAvatar(
                                frame: null,
                                avatarUrl: comment.authorAvatarUrl,
                                radius: 14,
                                placeholderColor:
                                    scheme.surfaceContainerHighest,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          comment.authorName ?? '',
                                          style: textTheme.labelMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          formatRelativeTime(
                                            comment.createdAt,
                                          ),
                                          style: textTheme.labelSmall
                                              ?.copyWith(
                                                color:
                                                    scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      comment.body,
                                      style: textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: tr('Комментарий…'),
                          filled: true,
                          fillColor: scheme.surfaceContainerHigh,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: state.isSending ? null : _send,
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}