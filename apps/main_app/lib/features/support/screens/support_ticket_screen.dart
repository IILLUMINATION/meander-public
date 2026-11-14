import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/crash_log_service.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/services/chat_media_service.dart';
import 'package:canvas_app/features/messages/widgets/chat_attachments.dart';
import 'package:canvas_app/features/support/models/support_models.dart';
import 'package:canvas_app/features/support/providers/support_provider.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Обращение глазами команды: вся переписка, ответ и смена статуса.
class SupportTicketScreen extends ConsumerStatefulWidget {
  const SupportTicketScreen({super.key, required this.ticketId});

  final String ticketId;

  @override
  ConsumerState<SupportTicketScreen> createState() =>
      _SupportTicketScreenState();
}

class _SupportTicketScreenState extends ConsumerState<SupportTicketScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<DmAttachment> _draft = [];

  /// Готовые ответы. Короткие: длинный текст всё равно правят под случай.
  /// Геттер, а не таблица: подписи должны следовать активному языку.
  static List<String> get _quickReplies => [
    tr('Проверяем, вернёмся с ответом'),
    tr('Попробуйте обновить приложение до последней версии'),
    tr('Пришлите, пожалуйста, скриншот или фото проблемы'),
  ];

  SupportTicket? _ticket;
  List<SupportMessage> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.get('support/tickets/${widget.ticketId}');
      if (!mounted) return;
      final map = response is Map ? response : const {};
      final rows = (map['messages'] as List?) ?? const [];
      setState(() {
        _loading = false;
        _error = null;
        _ticket = map['ticket'] is Map
            ? SupportTicket.fromJson(map['ticket'] as Map)
            : null;
        _messages = [
          for (final row in rows)
            if (row is Map) SupportMessage.fromJson(row),
        ];
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    } catch (e, s) {
      CrashLogService.log('support ticket: не открылся', error: e, stack: s);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _reply() async {
    final text = _input.text.trim();
    if ((text.isEmpty && _draft.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      final api = ref.read(apiServiceProvider);
      await api.post(
        'support/tickets/${widget.ticketId}/messages',
        body: {
          'body': text,
          if (_draft.isNotEmpty)
            'attachments': [
              for (final attachment in _draft)
                {
                  'url': attachment.url,
                  'width': attachment.width,
                  'height': attachment.height,
                  'size': attachment.size,
                },
            ],
        },
      );
      if (!mounted) return;
      _input.clear();
      setState(() {
        _sending = false;
        _draft.clear();
      });
      // Статус меняется на «answered» на сервере — перечитываем вместе с ним.
      ref.read(supportInboxProvider.notifier).load();
      await _load();
    } catch (e, s) {
      CrashLogService.log('support ticket: ответ не ушёл', error: e, stack: s);
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  Future<void> _setStatus(String status) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.post(
        'support/tickets/${widget.ticketId}/status',
        body: {'status': status, 'assign': true},
      );
      if (!mounted) return;
      ref.read(supportInboxProvider.notifier).load();
      await _load();
    } catch (e, s) {
      CrashLogService.log('support ticket: статус не сменился', error: e, stack: s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ticket = _ticket;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ticket?.subject ?? tr('Обращение'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (ticket != null)
              Text(
                '${ticket.userName ?? ''} · ${ticket.statusTitle}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          if (ticket != null && !ticket.isClosed)
            PopupMenuButton<String>(
              key: const ValueKey('ticket-menu'),
              onSelected: _setStatus,
              itemBuilder: (context) => [
                PopupMenuItem(value: 'answered', child: Text(tr('Отвечено'))),
                PopupMenuItem(value: 'closed', child: Text(tr('Закрыть'))),
              ],
            ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: scheme.primary))
          : Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                Expanded(
                  child: AdaptiveContent(
                    maxWidth: 760,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) => _TicketMessage(
                        message: _messages[index],
                      ),
                    ),
                  ),
                ),
                if (ticket != null && ticket.isClosed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
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
                            tr('Обращение закрыто. Открой его, чтобы ответить снова.'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _setStatus('open'),
                          child: Text(tr('Открыть')),
                        ),
                      ],
                    ),
                  )
                else ...[
                  // Быстрые ответы: одно и то же объяснение приходится
                  // повторять десятки раз, а набирать его на телефоне долго.
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (final reply in _quickReplies)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              key: ValueKey('quick-reply-${reply.hashCode}'),
                              label: Text(
                                reply,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onPressed: () => _input.text = reply,
                            ),
                          ),
                      ],
                    ),
                  ),
                  AlbumDraftStrip(
                    previews: _draft,
                    isUploading: _uploading,
                    onRemove: (index) => setState(() => _draft.removeAt(index)),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          IconButton(
                            onPressed: _uploading ? null : _pickPhotos,
                            icon: Icon(
                              Icons.add_photo_alternate_outlined,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _input,
                              minLines: 1,
                              maxLines: 5,
                              decoration: InputDecoration(
                                hintText: tr('Ответ от команды…'),
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
                            onPressed: _sending ? null : _reply,
                            icon: _sending
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.send_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _TicketMessage extends StatelessWidget {
  const _TicketMessage({required this.message});

  final SupportMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final mine = message.role == 'staff' || message.role == 'bot';

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.role == 'bot'
                  ? tr('Бот')
                  : mine
                  ? tr('Команда')
                  : tr('Автор обращения'),
              style: textTheme.labelSmall?.copyWith(
                color: mine ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (message.attachments.isNotEmpty) ...[
              const SizedBox(height: 6),
              ChatAttachmentGrid(
                attachments: message.attachments,
                mine: mine,
                width: 240,
              ),
            ],
            if (message.body.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              ChatMessageText(
                text: message.body,
                style: textTheme.bodyMedium?.copyWith(
                  color: mine ? scheme.onPrimaryContainer : scheme.onSurface,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              formatRelativeTime(message.createdAt),
              style: textTheme.labelSmall?.copyWith(
                color: (mine ? scheme.onPrimaryContainer : scheme.onSurface)
                    .withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}