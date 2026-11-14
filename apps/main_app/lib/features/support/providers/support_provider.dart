import 'dart:async';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/crash_log_service.dart';
import 'package:canvas_app/core/services/socket_service.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/support/models/support_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Окно «Поддержка» у обычного человека.
///
/// Не тред личных сообщений: у обращения бывает несколько ответчиков и
/// статус, а писать в него может команда. Поэтому своя модель состояния и
/// свои адреса (`/support/*`).
class SupportChatState {
  const SupportChatState({
    this.messages = const [],
    this.activeTicket,
    this.language = 'ru',
    this.isLoading = true,
    this.isSending = false,
    this.error,
    this.sendError,
  });

  final List<SupportMessage> messages;
  final SupportTicket? activeTicket;
  final String language;
  final bool isLoading;
  final bool isSending;
  final String? error;
  final String? sendError;

  bool get hasOpenTicket => activeTicket != null;

  SupportChatState copyWith({
    List<SupportMessage>? messages,
    SupportTicket? activeTicket,
    bool clearActiveTicket = false,
    String? language,
    bool? isLoading,
    bool? isSending,
    String? error,
    String? sendError,
    bool clearError = false,
    bool clearSendError = false,
  }) {
    return SupportChatState(
      messages: messages ?? this.messages,
      activeTicket: clearActiveTicket
          ? null
          : (activeTicket ?? this.activeTicket),
      language: language ?? this.language,
      isLoading: isLoading ?? this.isLoading,
      isSending: isSending ?? this.isSending,
      error: clearError ? null : (error ?? this.error),
      sendError: clearSendError ? null : (sendError ?? this.sendError),
    );
  }
}

class SupportChatNotifier extends StateNotifier<SupportChatState> {
  SupportChatNotifier(this.ref) : super(const SupportChatState()) {
    SocketService().addSupportListener(_onIncoming);
    load();
  }

  final Ref ref;

  @override
  void dispose() {
    SocketService().removeSupportListener(_onIncoming);
    super.dispose();
  }

  Future<void> load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) state = state.copyWith(isLoading: true, clearError: true);
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.get('support/chat');
      if (!mounted || response is! Map) return;
      final rows = (response['messages'] as List?) ?? const [];
      final rawTicket = response['active_ticket'];
      state = state.copyWith(
        isLoading: false,
        language: (response['language'] ?? 'ru').toString(),
        messages: [
          for (final row in rows)
            if (row is Map) SupportMessage.fromJson(row),
        ],
        activeTicket: rawTicket is Map
            ? SupportTicket.fromJson(rawTicket)
            : null,
        clearActiveTicket: rawTicket is! Map,
        clearError: true,
      );
    } catch (e, s) {
      CrashLogService.log('support: диалог не загрузился', error: e, stack: s);
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: _friendly(e));
    }
  }

  Future<bool> send(
    String body, {
    List<DmAttachment> attachments = const [],
  }) async {
    final text = body.trim();
    if ((text.isEmpty && attachments.isEmpty) || state.isSending) return false;
    state = state.copyWith(isSending: true, clearSendError: true);
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post(
        'support/messages',
        body: {
          'body': text,
          if (attachments.isNotEmpty)
            'attachments': [
              for (final attachment in attachments)
                {
                  'url': attachment.url,
                  'width': attachment.width,
                  'height': attachment.height,
                  'size': attachment.size,
                },
            ],
        },
      );
      if (!mounted) return true;
      final map = response is Map ? response : const {};
      final echo = map['message'];
      final bots = (map['bot_messages'] as List?) ?? const [];
      final ticket = map['ticket'];
      state = state.copyWith(
        isSending: false,
        messages: [
          ...state.messages,
          if (echo is Map) SupportMessage.fromJson(echo),
          for (final row in bots)
            if (row is Map) SupportMessage.fromJson(row),
        ],
        activeTicket: ticket is Map
            ? SupportTicket.fromJson(ticket)
            : state.activeTicket,
      );
      return true;
    } catch (e, s) {
      CrashLogService.log('support: сообщение не отправлено', error: e, stack: s);
      if (!mounted) return false;
      state = state.copyWith(isSending: false, sendError: _friendly(e));
      return false;
    }
  }

  /// Нажатие на кнопку под сообщением бота.
  Future<void> pressButton(SupportButton button) async {
    if (state.isSending) return;
    state = state.copyWith(isSending: true, clearSendError: true);
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post(
        'support/callback',
        body: {'button_id': button.id},
      );
      if (!mounted) return;
      final map = response is Map ? response : const {};
      final bots = (map['bot_messages'] as List?) ?? const [];
      state = state.copyWith(
        isSending: false,
        language: (map['language'] ?? state.language).toString(),
        messages: [
          ...state.messages,
          for (final row in bots)
            if (row is Map) SupportMessage.fromJson(row),
        ],
      );
    } catch (e, s) {
      CrashLogService.log('support: кнопка не сработала', error: e, stack: s);
      if (!mounted) return;
      state = state.copyWith(isSending: false, sendError: _friendly(e));
    }
  }

  /// Кнопки старого меню остаются в истории. Если человек уже ушёл дальше,
  /// жать их бессмысленно — прячем у всех, кроме последнего сообщения бота.
  Set<String> get liveButtonMessageIds {
    final botMessages = state.messages.where((m) => m.buttons.isNotEmpty);
    if (botMessages.isEmpty) return const {};
    return {botMessages.last.id};
  }

  void _onIncoming(Map<String, dynamic> payload) {
    final raw = payload['message'];
    if (raw is! Map) return;
    final message = SupportMessage.fromJson(raw);
    if (state.messages.any((m) => m.id == message.id)) return;
    state = state.copyWith(
      messages: [...state.messages, message],
      activeTicket: message.ticketId == null
          ? state.activeTicket
          : SupportTicket(
              id: message.ticketId!,
              subject: state.activeTicket?.subject ?? tr('Обращение'),
              status: message.role == 'staff' ? 'answered' : 'open',
              category: state.activeTicket?.category ?? 'other',
              lastMessageAt: message.createdAt,
            ),
    );
  }

  void clearSendError() {
    state = state.copyWith(clearSendError: true);
  }

  static String _friendly(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.isEmpty ? tr('Не получилось — попробуй ещё раз') : text;
  }
}

final supportChatProvider =
    StateNotifierProvider<SupportChatNotifier, SupportChatState>(
      (ref) => SupportChatNotifier(ref),
    );

/// Инбокс команды: список обращений и выбранное.
class SupportInboxState {
  const SupportInboxState({
    this.tickets = const [],
    this.filter = 'open',
    this.isLoading = false,
    this.error,
  });

  final List<SupportTicket> tickets;
  final String filter;
  final bool isLoading;
  final String? error;

  int get unreadTotal => tickets.fold<int>(0, (sum, t) => sum + t.unread);

  SupportInboxState copyWith({
    List<SupportTicket>? tickets,
    String? filter,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return SupportInboxState(
      tickets: tickets ?? this.tickets,
      filter: filter ?? this.filter,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SupportInboxNotifier extends StateNotifier<SupportInboxState> {
  SupportInboxNotifier(this.ref) : super(const SupportInboxState()) {
    SocketService().addSupportTicketListener(_onTicketEvent);
    load();
  }

  final Ref ref;

  @override
  void dispose() {
    SocketService().removeSupportTicketListener(_onTicketEvent);
    super.dispose();
  }

  Future<void> load({String? filter}) async {
    final next = filter ?? state.filter;
    if (!mounted) return;
    state = state.copyWith(isLoading: true, filter: next, clearError: true);
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.get(
        'support/tickets',
        queryParams: {'status': next},
      );
      final rows = (response is Map ? response['tickets'] : null) ?? const [];
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        tickets: [
          for (final row in rows)
            if (row is Map) SupportTicket.fromJson(row),
        ],
      );
    } catch (e, s) {
      CrashLogService.log('support inbox: не загрузился', error: e, stack: s);
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// Новое сообщение в тикете: перечитываем список, чтобы поднялся порядок и
  /// счётчик. Полная перезагрузка здесь дешевле точечной правки: тикетов
  /// десятки, а не тысячи.
  void _onTicketEvent(Map<String, dynamic> payload) {
    if (!mounted) return;
    unawaited(load());
  }
}

final supportInboxProvider =
    StateNotifierProvider<SupportInboxNotifier, SupportInboxState>(
      (ref) => SupportInboxNotifier(ref),
    );