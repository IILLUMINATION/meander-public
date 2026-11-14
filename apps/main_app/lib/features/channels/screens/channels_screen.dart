import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/features/channels/providers/channels_provider.dart';
import 'package:canvas_app/features/channels/screens/channel_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Лента каналов: подписки сверху, дальше — по числу подписчиков.
class ChannelsScreen extends ConsumerStatefulWidget {
  const ChannelsScreen({super.key});

  @override
  ConsumerState<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends ConsumerState<ChannelsScreen> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final created = await showModalBottomSheet<Channel>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CreateChannelSheet(),
    );
    if (created == null || !mounted) return;
    ref.read(channelsProvider.notifier).load();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChannelScreen(channelId: created.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(channelsProvider);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Text(tr('Каналы')),
        actions: [
          IconButton(
            onPressed: () => ref.read(channelsProvider.notifier).load(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              children: [
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (value) =>
                      ref.read(channelsProvider.notifier).load(query: value),
                  onChanged: (value) {
                    if (value.trim().isEmpty && state.query.isNotEmpty) {
                      ref.read(channelsProvider.notifier).load(query: '');
                    }
                  },
                  decoration: InputDecoration(
                    hintText: tr('Найти канал'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    label: Text(tr('Только мои')),
                    selected: state.mineOnly,
                    onSelected: (value) =>
                        ref.read(channelsProvider.notifier).load(mineOnly: value),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: Text(tr('Создать')),
      ),
      body: AdaptiveContent(
        maxWidth: 860,
        child: RefreshIndicator(
          onRefresh: () =>
              ref.read(channelsProvider.notifier).load(silent: true),
          child: _body(context, state),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ChannelsState state) {
    final scheme = Theme.of(context).colorScheme;
    if (state.isLoading && state.channels.isEmpty) {
      return Center(child: CircularProgressIndicator(color: scheme.primary));
    }
    if (state.channels.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
            child: Column(
              children: [
                Icon(
                  Icons.podcasts_rounded,
                  size: 44,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 14),
                Text(
                  state.query.isEmpty
                      ? tr('Каналов пока нет')
                      : tr('Ничего не нашлось'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  state.error ??
                      tr('Канал — это лента постов от одного автора. Подпишись, чтобы читать, или создай свой.'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: state.channels.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final channel = state.channels[index];
        return _ChannelRow(
          channel: channel,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChannelScreen(channelId: channel.id),
            ),
          ),
        );
      },
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.channel, required this.onTap});

  final Channel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('channel-${channel.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CosmeticAvatar(
                frame: null,
                avatarUrl: channel.avatarUrl,
                radius: 24,
                placeholderColor: scheme.surfaceContainerHighest,
                fallback: Icon(Icons.podcasts_rounded, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (channel.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        channel.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      channelMetaLine(channel),
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (channel.isSubscribed)
                Icon(Icons.check_circle_rounded, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateChannelSheet extends ConsumerStatefulWidget {
  _CreateChannelSheet();

  @override
  ConsumerState<_CreateChannelSheet> createState() =>
      _CreateChannelSheetState();
}

class _CreateChannelSheetState extends ConsumerState<_CreateChannelSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _description = TextEditingController();
  bool _isPublic = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    if (title.length < 2) {
      setState(() => _error = tr('Название минимум два символа'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post(
        'channels',
        body: {
          'title': title,
          'description': _description.text.trim(),
          'is_public': _isPublic,
        },
      );
      if (!mounted) return;
      final raw = response is Map ? response['channel'] : null;
      Navigator.pop(
        context,
        raw is Map ? Channel.fromJson(raw) : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('Новый канал'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            autofocus: true,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: tr('Название'),
              border: const OutlineInputBorder(),
            ),
          ),
          TextField(
            controller: _description,
            maxLines: 3,
            maxLength: 400,
            decoration: InputDecoration(
              labelText: tr('О чём канал'),
              border: const OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            value: _isPublic,
            onChanged: (value) => setState(() => _isPublic = value),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Публичный')),
            subtitle: Text(
              tr('Публичный канал видно в поиске, приватный — только по ссылке'),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(tr('Создать канал')),
          ),
        ],
      ),
    );
  }
}