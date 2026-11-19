import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/features/channels/providers/channels_provider.dart';
import 'package:canvas_app/features/channels/screens/channel_comments_screen.dart';
import 'package:canvas_app/features/channels/screens/channel_post_editor_screen.dart';
import 'package:canvas_app/features/messages/widgets/chat_attachments.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
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
  final ScrollController _scroll = ScrollController();
  final Set<String> _viewed = {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        ref.read(channelProvider(widget.channelId).notifier).loadOlder();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Новый пост пишется на отдельном экране — тем же редактором, что пост
  /// сообщества. Возврат `true` — пост ушёл, лента уже обновлена провайдером.
  Future<void> _compose() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ChannelPostEditorScreen(channelId: widget.channelId),
      ),
    );
    if (!mounted) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Ссылка на канал — публичная страница сайта: по ней канал открывается и
  /// у того, кто ещё не подписан.
  void _shareChannel() {
    final url = '${AppConfig.vpsApiBaseUrl}/channels/${widget.channelId}';
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      Clipboard.setData(ClipboardData(text: url));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Ссылка скопирована'))));
      return;
    }
    Share.share(url);
  }

  Future<void> _toggle() async {
    final error = await ref
        .read(channelProvider(widget.channelId).notifier)
        .toggleSubscription();
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  /// Владелец задаёт @адрес канала — короткую ссылку вместо uuid.
  Future<void> _editSlug() async {
    final channel = ref.read(channelProvider(widget.channelId)).channel;
    if (channel == null) return;
    final controller = TextEditingController(text: channel.slug ?? '');
    final entered = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Адрес канала')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(
            prefixText: '@',
            hintText: 'meander',
            helperText: tr('Латинские буквы, цифры и _, от 3 до 32 символов'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (entered == null) return;
    final slug = entered.replaceFirst(RegExp(r'^@+'), '').toLowerCase();
    if (slug == (channel.slug ?? '')) return;
    if (slug.isNotEmpty && !RegExp(r'^[a-z][a-z0-9_]{2,31}$').hasMatch(slug)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Латинские буквы, цифры и _, от 3 до 32 символов')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final error = await ref
        .read(channelProvider(widget.channelId).notifier)
        .setSlug(slug);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? tr('Адрес обновлён')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(channelProvider(widget.channelId));
    final channel = state.channel;

    // Просмотр отмечаем по факту показа: первый кадр ленты = прочитано.
    for (final post in state.posts.take(3)) {
      if (_viewed.add(post.id)) {
        ref
            .read(channelProvider(widget.channelId).notifier)
            .markViewed(post.id);
      }
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Text(channel?.title ?? tr('Канал')),
        actions: [
          if (channel?.isOwner ?? false)
            IconButton(
              key: const ValueKey('channel-edit-slug'),
              tooltip: tr('Адрес канала'),
              onPressed: _editSlug,
              icon: const Icon(Icons.alternate_email_rounded),
            ),
          if (channel != null)
            IconButton(
              tooltip: tr('Поделиться'),
              onPressed: _shareChannel,
              icon: const Icon(Icons.share_outlined),
            ),
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
              tooltip: tr('Новый пост'),
              onPressed: _compose,
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
              ],
            ),
    );
  }

  void _openComments(BuildContext context, ChannelPost post) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ChannelCommentsScreen(
          post: post,
          channelTitle: ref
              .read(channelProvider(widget.channelId))
              .channel
              ?.title,
        ),
      ),
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
                    if (channel.slug != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '@${channel.slug}',
                        style: textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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
                FilledButton.tonal(onPressed: null, child: Text(tr('Владелец')))
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
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
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
