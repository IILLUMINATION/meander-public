import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/services/chat_media_service.dart';
import 'package:canvas_app/features/messages/widgets/chat_attachments.dart';
import 'package:canvas_app/features/support/models/support_models.dart';
import 'package:canvas_app/features/support/providers/support_provider.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Окно поддержки: бот отвечает правилами, тикет уходит команде.
class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key});

  @override
  ConsumerState<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends ConsumerState<SupportScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<DmAttachment> _draft = [];
  bool _uploading = false;
  int _lastCount = 0;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty && _draft.isEmpty) return;
    final notifier = ref.read(supportChatProvider.notifier);
    final outgoing = List<DmAttachment>.of(_draft);
    _input.clear();
    setState(_draft.clear);
    final sent = await notifier.send(text, attachments: outgoing);
    if (!mounted) return;
    if (!sent) {
      _input.text = text;
      setState(() => _draft.insertAll(0, outgoing));
      final error = ref.read(supportChatProvider).sendError;
      notifier.clearSendError();
      if (error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Future<void> _pickPhotos() async {
    if (_uploading || _draft.length >= ChatMediaService.albumLimit) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await ChatMediaService.pickAlbum(
        remaining: ChatMediaService.albumLimit - _draft.length,
      );
      if (picked.isEmpty || !mounted) return;
      for (final file in picked) {
        if (await file.length() > ChatMediaService.maxBytes) {
          messenger.showSnackBar(
            SnackBar(content: Text(tr('Фото больше 5 МБ — не прикрепилось'))),
          );
          continue;
        }
        if (!mounted) return;
        setState(() => _uploading = true);
        final attachment = await ChatMediaService.upload(file);
        if (!mounted) return;
        setState(() => _draft.add(attachment));
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(supportChatProvider);

    if (state.messages.length != _lastCount) {
      _lastCount = state.messages.length;
      _scrollToBottom();
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Поддержка')),
            Text(
              state.activeTicket == null
                  ? tr('Бот и команда Meander')
                  : trf('Обращение: {p0}', {
                      'p0': state.activeTicket!.statusTitle.toLowerCase(),
                    }),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: AdaptiveContent(
              maxWidth: 760,
              child: _body(context, state),
            ),
          ),
          AlbumDraftStrip(
            previews: _draft,
            isUploading: _uploading,
            onRemove: (index) => setState(() => _draft.removeAt(index)),
          ),
          _Composer(
            controller: _input,
            isSending: state.isSending,
            onSend: _send,
            onPickPhotos: _pickPhotos,
            uploading: _uploading,
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, SupportChatState state) {
    final scheme = Theme.of(context).colorScheme;
    if (state.isLoading && state.messages.isEmpty) {
      return Center(child: CircularProgressIndicator(color: scheme.primary));
    }
    if (state.error != null && state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(state.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () =>
                    ref.read(supportChatProvider.notifier).load(),
                child: Text(tr('Повторить')),
              ),
            ],
          ),
        ),
      );
    }

    final liveButtons = ref
        .read(supportChatProvider.notifier)
        .liveButtonMessageIds;

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: state.messages.length,
      itemBuilder: (context, index) {
        final message = state.messages[index];
        return _SupportBubble(
          message: message,
          showButtons: liveButtons.contains(message.id),
          busy: state.isSending,
          onButton: (button) =>
              ref.read(supportChatProvider.notifier).pressButton(button),
        );
      },
    );
  }
}

class _SupportBubble extends StatelessWidget {
  const _SupportBubble({
    required this.message,
    required this.showButtons,
    required this.busy,
    required this.onButton,
  });

  final SupportMessage message;
  final bool showButtons;
  final bool busy;
  final void Function(SupportButton button) onButton;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final mine = message.isMine;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        margin: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!mine) ...[
                  Icon(
                    message.isBot
                        ? Icons.smart_toy_outlined
                        : Icons.support_agent_rounded,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    message.isBot ? tr('Бот') : tr('Команда'),
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  formatRelativeTime(message.createdAt),
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: mine
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 16 : 6),
                  bottomRight: Radius.circular(mine ? 6 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.attachments.isNotEmpty)
                    ChatAttachmentGrid(
                      attachments: message.attachments,
                      mine: mine,
                      width: 240,
                    ),
                  if (message.body.trim().isNotEmpty) ...[
                    if (message.attachments.isNotEmpty)
                      const SizedBox(height: 6),
                    ChatMessageText(
                      text: message.body,
                      style: textTheme.bodyMedium?.copyWith(
                        color: mine
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (showButtons && message.buttons.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final button in message.buttons)
                    FilledButton.tonal(
                      key: ValueKey('support-btn-${button.id}'),
                      onPressed: busy ? null : () => onButton(button),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                      ),
                      child: Text(button.label),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isSending,
    required this.onSend,
    required this.onPickPhotos,
    required this.uploading,
  });

  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;
  final VoidCallback onPickPhotos;
  final bool uploading;

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
              IconButton(
                key: const ValueKey('support-attach'),
                onPressed: uploading ? null : onPickPhotos,
                tooltip: tr('Прикрепить фото'),
                icon: Icon(
                  Icons.add_photo_alternate_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: tr('Опиши проблему…'),
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