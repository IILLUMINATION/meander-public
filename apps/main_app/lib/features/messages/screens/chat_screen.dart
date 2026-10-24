import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/providers/dm_provider.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Единая точка входа в переписку — из профиля, из ленты и из уведомления.
///
/// Гость сюда зайти может (кнопка «Написать» есть в чужом профиле), а сервер
/// на запрос без токена отвечает 401 так, что клиента выбрасывает в MenuScreen.
/// Поэтому порог проверяем здесь.
Future<void> openChat(BuildContext context, String peerId) async {
  final prefs = await SharedPreferences.getInstance();
  final me = prefs.getString('user_id');
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);

  if (me == null || me.isEmpty) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Чтобы писать, войди в аккаунт'))),
    );
    return;
  }
  if (me == peerId) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Себе написать нельзя'))),
    );
    return;
  }
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ChatScreen(peerId: peerId)),
  );
}

/// Окно переписки. Открывается по id собеседника: пара «я ↔ он» на сервере
/// одна, а тред может ещё не существовать.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.peerId});

  final String peerId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _hasScrolledToBottom = false;

  /// Сам нотификатор провайдера переписки: он живёт дольше экрана, поэтому
  /// «окно закрыли» надо сообщить ему напрямую, без `ref` в `dispose`.
  DmChatNotifier? _chat;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _chat = ref.read(dmChatProvider(widget.peerId).notifier);
      _chat!.setViewed(true);
    });
  }

  @override
  void dispose() {
    _chat?.setViewed(false);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels <= 240) {
      ref.read(dmChatProvider(widget.peerId).notifier).loadOlder();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final sent = await ref
        .read(dmChatProvider(widget.peerId).notifier)
        .send(text);
    if (!mounted) return;
    if (sent) {
      _scrollToBottom();
    } else {
      final error = ref.read(dmChatProvider(widget.peerId)).sendError;
      ref.read(dmChatProvider(widget.peerId).notifier).clearSendError();
      if (error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Future<void> _menu() async {
    final scheme = Theme.of(context).colorScheme;
    final peer = ref.read(dmChatProvider(widget.peerId)).peer;
    if (peer == null || peer.isSystem) return;
    final blocked = ref.read(dmBlocksProvider).any((p) => p.id == peer.id);

    await showAdaptiveSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                blocked ? Icons.lock_open_rounded : Icons.block_outlined,
                color: blocked ? null : scheme.error,
              ),
              title: Text(
                blocked
                    ? tr('Разблокировать пользователя')
                    : tr('Заблокировать пользователя'),
              ),
              subtitle: Text(
                blocked
                    ? tr('Переписка и новый чат снова будут доступны')
                    : tr('Человек не сможет писать тебе, пока ты не разблокируешь'),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _toggleBlock(peer, blocked);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleBlock(DmPeer peer, bool blocked) async {
    final notifier = ref.read(dmBlocksProvider.notifier);
    final error = blocked
        ? await notifier.unblock(peer.id)
        : await notifier.block(peer);
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(dmChatProvider(widget.peerId));

    if (state.messages.isNotEmpty && !_hasScrolledToBottom) {
      _hasScrolledToBottom = true;
      _scrollToBottom();
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        titleSpacing: 0,
        title: _ChatHead(peer: state.peer, systemFallback: state.isSystem),
        actions: [
          if (state.peer != null && !state.isSystem)
            IconButton(
              onPressed: _menu,
              icon: const Icon(Icons.more_horiz_rounded),
              color: scheme.onSurfaceVariant,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: AdaptiveContent(
              maxWidth: 760,
              child: _buildMessages(context, state),
            ),
          ),
          if (state.error == null)
            state.isSystem
                ? const _SystemChatFooter()
                : _Composer(
                    controller: _input,
                    isSending: state.isSending,
                    onSend: _send,
                  ),
        ],
      ),
    );
  }

  Widget _buildMessages(BuildContext context, DmChatState state) {
    final scheme = Theme.of(context).colorScheme;

    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                state.error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    if (state.isLoading) {
      return Center(child: CircularProgressIndicator(color: scheme.primary));
    }

    if (state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            state.isSystem
                ? tr('Здесь появятся новости команды и уведомления о том, что происходило с аккаунтом.')
                : tr('Сообщений пока нет — напиши первым.'),
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    // Строки над первым сообщением: спиннер догрузки и баннер неудачи.
    final olderRetry = state.olderError != null && !state.isLoadingMore;
    final leading = (state.isLoadingMore ? 1 : 0) + (olderRetry ? 1 : 0);

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: state.messages.length + leading,
      itemBuilder: (context, index) {
        if (index == 0 && state.isLoadingMore) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        if (olderRetry && index == (state.isLoadingMore ? 1 : 0)) {
          return _OlderErrorBanner(
            message: state.olderError!,
            onRetry: () => ref
                .read(dmChatProvider(widget.peerId).notifier)
                .loadOlder(),
          );
        }
        final position = index - leading;
        final message = state.messages[position];
        final previous = position > 0 ? state.messages[position - 1] : null;
        final following = position + 1 < state.messages.length
            ? state.messages[position + 1]
            : null;
        final mine = message.senderId == state.viewerId;

        // Реплики подряд от одного человека слипаются в группу: часы у каждой
        // строки и одинаковый отступ превращали пять сообщений в пять карточек.
        final groupContinues =
            following != null &&
            following.senderId == message.senderId &&
            !following.isService &&
            !message.isService &&
            _sameDay(message.createdAt, following.createdAt) &&
            following.createdAt.difference(message.createdAt).inMinutes.abs() <
                5;
        final startsNewDay =
            previous == null ||
            !_sameDay(previous.createdAt, message.createdAt);

        return Column(
          children: [
            if (startsNewDay) _DayDivider(date: message.createdAt),
            _Bubble(
              message: message,
              mine: mine,
              isGroupEnd: !groupContinues,
              showStamp: !groupContinues,
            ),
          ],
        );
      },
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Разделитель дня: без него переписка за вчера и за неделю выглядит одним
/// экраном, и время под репликой перестаёт что-либо значить.
class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    final label = _sameDay(date, now)
        ? tr('Сегодня')
        : _sameDay(date, yesterday)
        ? tr('Вчера')
        : formatDayMonthYear(date);

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Баннер неудачной догрузки истории. Без него список молча перестаёт
/// листаться вверх, и человек думает, что старых сообщений нет.
class _OlderErrorBanner extends StatelessWidget {
  const _OlderErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 16,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onErrorContainer,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(tr('Повторить')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatHead extends StatelessWidget {
  const _ChatHead({required this.peer, required this.systemFallback});

  final DmPeer? peer;
  final bool systemFallback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final current = peer;
    if (current == null) {
      return Text(
        systemFallback ? 'Meander' : tr('Переписка'),
        style: textTheme.titleMedium,
      );
    }

    // Аккаунт команды — не человек: страницы профиля у него нет, и тап по
    // шапке вёл бы на экран с пустой ошибкой.
    return InkWell(
      onTap: current.isSystem
          ? null
          : () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ProfileScreen(userId: current.id)),
            ),
      child: Row(
        children: [
          CosmeticAvatar(
            frame: cosmeticById(current.equipped.avatarFrame),
            avatarUrl: current.avatarUrl,
            radius: 20,
            placeholderColor: scheme.surfaceContainerHighest,
            fallback: current.isSystem
                ? Icon(
                    Icons.campaign_outlined,
                    color: scheme.onPrimaryContainer,
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CosmeticNameText(
                  name: current.isSystem ? 'Meander' : current.name,
                  def: cosmeticById(current.equipped.nameStyle),
                  style: textTheme.titleSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  current.presenceLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.isGroupEnd,
    required this.showStamp,
  });

  final DmMessage message;
  final bool mine;

  /// Хвостик у пузыря только у последней реплики группы: иначе подряд идущие
  /// сообщения читаются как отдельные карточки.
  final bool isGroupEnd;
  final bool showStamp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (message.isService) {
      // Служебная реплика команды — не «пузырь», а строка-событие: их читают
      // списком, и красить каждую пузырём было бы шумом.
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              message.kind == 'news'
                  ? Icons.campaign_outlined
                  : Icons.info_outline_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MeanderEntityLinkText(
                data: message.body,
                style: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatRelativeTime(message.createdAt),
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // M3 просит для своей реплики контейнер с тоном, а не залитый primary:
    // сплошной акцентный цвет спорит с текстом и режет глаз в длинном окне.
    final bubbleColor = mine
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final textColor = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    final tail = Radius.circular(isGroupEnd ? 6 : 18);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        margin: EdgeInsets.only(bottom: isGroupEnd ? 8 : 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: mine ? const Radius.circular(18) : tail,
            bottomRight: mine ? tail : const Radius.circular(18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            MeanderEntityLinkText(
              data: message.body,
              style: textTheme.bodyMedium?.copyWith(
                color: textColor,
                height: 1.35,
              ),
            ),
            if (showStamp) ...[
              const SizedBox(height: 2),
              Text(
                _stamp(message.createdAt),
                style: textTheme.labelSmall?.copyWith(
                  color: textColor.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// В переписке важнее время, а дата нужна только у вчерашних и старых реплик.
  static String _stamp(DateTime date) {
    final clock =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    final today =
        date.year == now.year && date.month == now.month && date.day == now.day;
    return today ? clock : '$clock · ${formatDayMonth(date)}';
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isSending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;

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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: tr('Сообщение…'),
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
                onPressed: isSending ? null : onSend,
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
      ),
    );
  }
}

/// Аккаунт команды не читает входящие — писать туда нельзя намеренно, иначе
/// «чат по умолчанию» мгновенно стал бы ещё одной витриной для спама.
class _SystemChatFooter extends StatelessWidget {
  const _SystemChatFooter();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr('Ответить нельзя: это аккаунт команды. Сюда приходят новости и системные уведомления.'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
