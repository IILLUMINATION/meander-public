import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/providers/dm_provider.dart';
import 'package:canvas_app/features/messages/screens/chat_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/features/channels/providers/channels_provider.dart';
import 'package:canvas_app/features/channels/screens/channel_screen.dart';
import 'package:canvas_app/features/channels/screens/channels_screen.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/support/screens/support_inbox_screen.dart';
import 'package:canvas_app/features/support/screens/support_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';

/// Вкладка «Чаты»: личные переписки и диалог с аккаунтом команды.
class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  String _viewerId = '';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _viewerId = prefs.getString('user_id') ?? '');
    });
  }

  Future<void> _open(DmThread thread) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(peerId: thread.peer.id)),
    );
    if (!mounted) return;
    // Окно чата отмечает переписку прочитанной на сервере — ленте надо
    // обновиться, иначе счётчик переживёт тап по строке.
    ref.read(dmThreadsProvider.notifier).load(silent: true);
  }

  Future<void> _openChannel(Channel channel) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChannelScreen(channelId: channel.id)),
    );
    if (!mounted) return;
    // В канале можно отписаться: строка должна исчезнуть сразу.
    ref.read(channelsProvider.notifier).load(silent: true);
  }

  Future<void> _confirmHide(DmThread thread) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Скрыть переписку?')),
        content: Text(
          tr(
            'Она уйдёт из твоего списка. У собеседника переписка останется, а новое сообщение вернёт её обратно.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Скрыть')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(dmThreadsProvider.notifier).hide(thread.threadId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Не удалось скрыть переписку'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(dmThreadsProvider);
    // Каналы — те же строки ленты, что и переписки, а не отдельный раздел:
    // человек ищет «где новости», а не «раздел вещания».
    final channels = ref
        .watch(channelsProvider)
        .channels
        .where((channel) => channel.isSubscribed)
        .toList();

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await Future.wait([
              ref.read(dmThreadsProvider.notifier).load(silent: true),
              ref.read(channelsProvider.notifier).load(silent: true),
            ]);
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverAppBar.large(
                title: Text(tr('Чаты')),
                pinned: true,
                backgroundColor: scheme.surface,
                surfaceTintColor: scheme.surfaceTint,
              ),
              SliverToBoxAdapter(
                child: AdaptiveContent(
                  maxWidth: 760,
                  child: _buildBody(context, state, channels),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DmThreadsState state,
    List<Channel> channels,
  ) {
    final scheme = Theme.of(context).colorScheme;

    if (state.isLoading && state.threads.isEmpty && channels.isEmpty) {
      return Column(
        children: [for (var i = 0; i < 5; i++) _shimmerRow(context)],
      );
    }

    if (state.error != null && state.threads.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Column(
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              tr('Не удалось загрузить переписки'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              state.error!,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => ref.read(dmThreadsProvider.notifier).load(),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr('Повторить')),
            ),
          ],
        ),
      );
    }

    if (state.threads.isEmpty && channels.isEmpty) {
      return Column(
        children: [
          _SupportEntryCard(viewerId: _viewerId),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
            child: Column(
              children: [
                Icon(
                  Icons.forum_outlined,
                  size: 44,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 14),
                Text(
                  tr('Пока пусто'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  tr(
                    'Открой профиль человека и нажми «Написать» — переписка появится здесь. Новости команды приходят в чат Meander.',
                  ),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _DiscoverChannelsRow(),
        ],
      );
    }

    // Одна лента: каналы и переписки сортируются вместе по последнему
    // событию. Канал без постов уезжает вниз — как пустой чат.
    final entries = <({DateTime at, int order, Widget tile})>[];
    var order = 0;
    for (final channel in channels) {
      entries.add((
        at: channel.lastPostAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        order: order++,
        tile: _ChannelTile(
          channel: channel,
          onOpen: () => _openChannel(channel),
        ),
      ));
    }
    for (final thread in state.threads) {
      entries.add((
        at: thread.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        order: order++,
        tile: _ThreadTile(
          thread: thread,
          viewerId: _viewerId,
          onOpen: () => _open(thread),
          onMute: () => ref
              .read(dmThreadsProvider.notifier)
              .mute(thread.threadId, !thread.muted),
          // Системный чат не прячут: у новости всё равно есть колокольчик, а
          // «скрыть» оставило бы человека без окна, которое нечем вернуть.
          onHide: thread.peer.isSystem ? null : () => _confirmHide(thread),
        ),
      ));
    }
    entries.sort((a, b) {
      final byTime = b.at.compareTo(a.at);
      return byTime != 0 ? byTime : a.order.compareTo(b.order);
    });

    return Column(
      children: [
        _SupportEntryCard(viewerId: _viewerId),
        for (final entry in entries) entry.tile,
        _DiscoverChannelsRow(),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _shimmerRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Shimmer.fromColors(
      baseColor: scheme.surfaceContainerHighest,
      highlightColor: scheme.surfaceContainerHigh,
      child: Container(
        height: 76,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}

/// «Поддержка» — всегда первая строка ленты: это не переписка с человеком,
/// но искать её в глубине меню, когда что-то сломалось, никто не станет.
class _SupportEntryCard extends ConsumerWidget {
  const _SupportEntryCard({required this.viewerId});

  final String viewerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final staff = viewerId.isEmpty
        ? false
        : ref
              .watch(userProfileProvider(viewerId))
              .maybeWhen(
                data: (profile) =>
                    profile.role == 'admin' || profile.role == 'moderator',
                orElse: () => false,
              );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Material(
        color: scheme.secondaryContainer.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('support-entry'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => SupportScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: scheme.primary,
                  child: Icon(
                    Icons.support_agent_rounded,
                    color: scheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Поддержка'),
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        tr('Бот ответит сразу, команда — когда прочитает'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (staff) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    key: const ValueKey('support-inbox'),
                    tooltip: tr('Обращения'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => SupportInboxScreen()),
                    ),
                    icon: const Icon(Icons.inbox_rounded),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.thread,
    required this.viewerId,
    required this.onOpen,
    required this.onMute,
    this.onHide,
  });

  final DmThread thread;
  final String viewerId;
  final VoidCallback onOpen;
  final VoidCallback onMute;
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final peer = thread.peer;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: thread.unread > 0
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onOpen,
          onLongPress: _menu(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CosmeticAvatar(
                  frame: cosmeticById(peer.equipped.avatarFrame),
                  avatarUrl: peer.avatarUrl,
                  radius: 26,
                  placeholderColor: scheme.surfaceContainerHighest,
                  fallback: peer.isSystem
                      ? Icon(
                          Icons.campaign_outlined,
                          color: scheme.onPrimaryContainer,
                        )
                      : Text(
                          _initial(peer.name),
                          style: textTheme.titleMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
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
                              name: peer.isSystem ? 'Meander' : peer.name,
                              def: cosmeticById(peer.equipped.nameStyle),
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: thread.unread > 0
                                    ? FontWeight.w800
                                    : FontWeight.w700,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          if (peer.isSystem) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.verified_rounded,
                              size: 14,
                              color: scheme.primary,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        thread.previewFor(viewerId),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: thread.unread > 0
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      thread.lastMessageAt == null
                          ? ''
                          : formatRelativeTime(thread.lastMessageAt!),
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (thread.muted)
                          Icon(
                            Icons.notifications_off_outlined,
                            size: 15,
                            color: scheme.onSurfaceVariant,
                          ),
                        if (thread.unread > 0) ...[
                          if (thread.muted) const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              thread.unread > 99 ? '99+' : '${thread.unread}',
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onPrimary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
                IconButton(
                  onPressed: _menu(context),
                  icon: const Icon(Icons.more_horiz_rounded),
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  VoidCallback _menu(BuildContext context) => () async {
    await showAdaptiveSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                thread.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(thread.muted ? tr('Включить звук') : tr('Заглушить')),
              onTap: () {
                Navigator.pop(sheetContext);
                onMute();
              },
            ),
            if (onHide != null)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: Text(tr('Скрыть переписку')),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onHide!();
                },
              ),
          ],
        ),
      ),
    );
  };

  static String _initial(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
  }
}

/// Канал в общей ленте: та же строка, что переписка, только вместо
/// собеседника — лента постов. Отдельного раздела нет: «где новости» человек
/// ищет там же, где остальные чаты.
class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.onOpen});

  final Channel channel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final subtitle = channel.description.trim().isNotEmpty
        ? channel.description.trim()
        : (channel.postsCount == 1
              ? tr('1 пост')
              : trf('{p0} постов', {'p0': channel.postsCount}));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('channel-tile-${channel.id}'),
          borderRadius: BorderRadius.circular(20),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: scheme.surfaceContainerHighest,
                  backgroundImage: channel.avatarUrl == null
                      ? null
                      : NetworkImage(channel.avatarUrl!),
                  child: channel.avatarUrl == null
                      ? Icon(Icons.podcasts_rounded, color: scheme.primary)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              channel.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            channel.isPublic
                                ? Icons.campaign_rounded
                                : Icons.lock_outline_rounded,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  channel.lastPostAt == null
                      ? ''
                      : formatRelativeTime(channel.lastPostAt!),
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
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

/// Единственный вход в поиск и создание каналов. Стоит последней строкой:
/// подписки уже выше, а сюда заходят, только чтобы найти новый канал.
class _DiscoverChannelsRow extends StatelessWidget {
  const _DiscoverChannelsRow();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('open-channels'),
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ChannelsScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Icons.add_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr('Найти или создать канал'),
                    style: textTheme.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
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
}
