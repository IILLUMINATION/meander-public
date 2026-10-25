import 'dart:async';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/crash_log_service.dart';
import 'package:canvas_app/core/services/socket_service.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Лента переписок.
///
/// Отдельная сущность, а не `FutureProvider`, потому что её живьят сокет и
/// собственные действия (заглушить, скрыть): перечитывать всё с сервера ради
/// одной строки — значит терять скролл и подсветку непрочитанного.
class DmThreadsState {
  const DmThreadsState({
    this.threads = const [],
    this.isLoading = false,
    this.error,
  });

  final List<DmThread> threads;
  final bool isLoading;
  final String? error;

  int get unreadTotal =>
      threads.where((t) => !t.muted).fold<int>(0, (sum, t) => sum + t.unread);

  DmThreadsState copyWith({
    List<DmThread>? threads,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return DmThreadsState(
      threads: threads ?? this.threads,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class DmThreadsNotifier extends StateNotifier<DmThreadsState> {
  DmThreadsNotifier(this.ref) : super(const DmThreadsState()) {
    SocketService().addDmListener(_onIncoming);
    load();
  }

  final Ref ref;
  String _viewerId = '';

  @override
  void dispose() {
    SocketService().removeDmListener(_onIncoming);
    super.dispose();
  }

  Future<void> load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) state = state.copyWith(isLoading: true);
    try {
      final api = ref.read(apiServiceProvider);
      final prefs = await SharedPreferences.getInstance();
      _viewerId = prefs.getString('user_id') ?? '';

      // Системный чат — «чат по умолчанию»: просим бэк создать диалог с
      // командой до загрузки ленты, иначе у нового аккаунта вкладка пустая.
      try {
        await api.get('api/messages/system');
      } catch (_) {
        // Лента без него всё равно загрузится, а создавать диалог повторной
        // попыткой — значит блокировать экран чужой ошибкой.
      }

      final response = await api.get('api/messages/threads');
      final rows = (response is Map ? response['threads'] : null) ?? const [];
      if (!mounted) return;
      state = state.copyWith(
        threads: [
          for (final row in rows)
            if (row is Map) DmThread.fromJson(row),
        ],
        isLoading: false,
        clearError: true,
      );
    } catch (e, s) {
      // Экран показывает только заголовок, и на скриншоте тестера причина
      // не читается. В логе она теперь есть — туда же, откуда «Отправить логи».
      CrashLogService.log('dm: лента переписок не загрузилась', error: e, stack: s);
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: _friendly(e));
    }
  }

  Future<void> mute(String threadId, bool muted) async {
    _patch(threadId, (t) => t.copyWith(muted: muted));
    try {
      final api = ref.read(apiServiceProvider);
      await api.post(
        'api/messages/threads/$threadId/mute',
        body: {'muted': muted},
      );
    } catch (e) {
      await load(silent: true);
    }
  }

  /// Диалог уходит из ленты только у того, кто нажал, — у собеседника он остаётся.
  Future<void> hide(String threadId) async {
    _patch(threadId, (t) => null);
    final api = ref.read(apiServiceProvider);
    await api.delete('api/messages/threads/$threadId');
  }

  void _patch(String threadId, DmThread? Function(DmThread) transform) {
    final next = <DmThread>[];
    for (final thread in state.threads) {
      if (thread.threadId != threadId) {
        next.add(thread);
        continue;
      }
      final updated = transform(thread);
      if (updated != null) next.add(updated);
    }
    state = state.copyWith(threads: next);
  }

  void _onIncoming(Map<String, dynamic> payload) {
    final threadId = payload['thread_id']?.toString();
    if (threadId == null || threadId.isEmpty) return;

    final raw = payload['message'];
    final message = raw is Map ? DmMessage.fromJson(raw) : null;
    final mine = message != null && message.senderId == _viewerId;

    var found = false;
    final next = <DmThread>[];
    for (final thread in state.threads) {
      if (thread.threadId != threadId) {
        next.add(thread);
        continue;
      }
      found = true;
      next.insert(
        0,
        thread.copyWith(
          lastBody: message?.body,
          lastSenderId: message?.senderId,
          lastKind: message?.kind,
          lastMessageAt: message?.createdAt,
          unread: mine || thread.muted ? 0 : thread.unread + 1,
        ),
      );
    }
    // Новый диалог: ленты без него не хватает, чтобы он появился на экране.
    if (!found && !mine) {
      load(silent: true);
      return;
    }
    state = state.copyWith(threads: next);
  }

  /// Открытое окно чата само отмечает прочитанное — ленте надо обновиться.
  void markThreadRead(String threadId) {
    _patch(threadId, (t) => t.copyWith(unread: 0));
  }
}

String _friendly(Object error) {
  final raw = error.toString();
  if (raw.contains('SERVER_MAINTENANCE')) return tr('Сервер на обслуживании');
  if (raw.contains('SocketException') || raw.contains('ClientException')) {
    return tr('Нет соединения с сервером');
  }
  // Таймаут — не «не удалось», а «сервер молчит»: без этой строки тестер
  // видит ровно тот же текст, что при любом неизвестном исключении.
  if (error is TimeoutException) return tr('Сервер не ответил вовремя');
  return serverErrorMessage(error, fallback: tr('Не удалось загрузить переписки'));
}

final dmThreadsProvider =
    StateNotifierProvider<DmThreadsNotifier, DmThreadsState>(
      (ref) => DmThreadsNotifier(ref),
    );

/// Бейдж на вкладке «Чаты»: столько строк ещё не прочитано.
final dmUnreadCountProvider = Provider<int>(
  (ref) => ref.watch(dmThreadsProvider).unreadTotal,
);

/// Одно окно переписки. Ключ — id собеседника, а не диалога: пара «я ↔ он»
/// на сервере одна, а тред появляется только после первого сообщения.
class DmChatState {
  const DmChatState({
    this.peer,
    this.threadId,
    this.messages = const [],
    this.isLoading = true,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.isSending = false,
    this.error,
    this.sendError,
    this.olderError,
    this.viewerId = '',
  });

  final DmPeer? peer;
  final String? threadId;
  final List<DmMessage> messages;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final bool isSending;
  final String? error;
  final String? sendError;

  /// Мой id: нужон, чтобы понять, какой стороной рисовать сообщение.
  final String viewerId;

  /// Ошибка догрузки старых реплик. Держим её отдельно от `error`: та в чате
  /// перекрывает всю переписку и гасит композер, а здесь достаточно баннера
  /// над списком — то, что человек уже читает, никуда не девается.
  final String? olderError;

  bool get isSystem => peer?.isSystem ?? false;

  DmChatState copyWith({
    DmPeer? peer,
    String? threadId,
    List<DmMessage>? messages,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    bool? isSending,
    String? error,
    String? sendError,
    String? olderError,
    String? viewerId,
    bool clearError = false,
    bool clearOlderError = false,
  }) {
    return DmChatState(
      peer: peer ?? this.peer,
      threadId: threadId ?? this.threadId,
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      isSending: isSending ?? this.isSending,
      error: clearError ? null : (error ?? this.error),
      sendError: clearError ? null : (sendError ?? this.sendError),
      olderError: clearOlderError ? null : (olderError ?? this.olderError),
      viewerId: viewerId ?? this.viewerId,
    );
  }
}

class DmChatNotifier extends StateNotifier<DmChatState> {
  DmChatNotifier(this.ref, this.peerId) : super(const DmChatState()) {
    SocketService().addDmListener(_onIncoming);
    _load();
  }

  final Ref ref;
  final String peerId;
  static const int _pageSize = 50;

  /// Волна сообщений за пару секунд не должна высылать пару десятков POST-ов.
  static const Duration _readDebounce = Duration(milliseconds: 400);

  bool _viewed = false;
  Timer? _readFlush;
  String? _pendingReadThreadId;

  @override
  void dispose() {
    _readFlush?.cancel();
    SocketService().removeDmListener(_onIncoming);
    super.dispose();
  }

  /// Открыто ли окно прямо сейчас. Провайдер живёт до выхода из аккаунта,
  /// поэтому без флага пришедшее в фоне сообщение молча сожрало бы счётчик,
  /// которого человек не видел.
  void setViewed(bool viewed) {
    if (_viewed == viewed) return;
    _viewed = viewed;
    // Ушли из диалога с неотправленной отметкой — дошлём сейчас, иначе штамп
    // на сервере отстанет от того, что человек реально прочитал.
    if (!viewed) _flushPendingRead();
  }

  void _flushPendingRead() {
    _readFlush?.cancel();
    _readFlush = null;
    final threadId = _pendingReadThreadId;
    if (threadId == null) return;
    unawaited(_postRead(threadId));
  }

  Future<void> _postRead(String threadId) async {
    if (_pendingReadThreadId == threadId) _pendingReadThreadId = null;
    try {
      final api = ref.read(apiServiceProvider);
      await api.post('api/messages/threads/$threadId/read');
    } catch (e, s) {
      CrashLogService.log('dm: прочтение не отмечено', error: e, stack: s);
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final api = ref.read(apiServiceProvider);
      final prefs = await SharedPreferences.getInstance();

      final head = await api.get('api/messages/threads/peer/$peerId');
      if (!mounted) return;
      if (head is! Map) {
        state = state.copyWith(isLoading: false, error: tr('Переписка недоступна'));
        return;
      }
      final threadId = head['thread_id']?.toString();
      state = state.copyWith(
        peer: DmPeer.fromJson(head),
        threadId: threadId,
        viewerId: prefs.getString('user_id') ?? '',
        isLoading: false,
        clearError: true,
      );
      if (threadId == null || threadId.isEmpty) return;
      await _fetchHistory(threadId);
    } catch (e, s) {
      CrashLogService.log('dm: переписка не загрузилась', error: e, stack: s);
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: _friendly(e));
    }
  }

  Future<void> _fetchHistory(String threadId, {DateTime? before}) async {
    final api = ref.read(apiServiceProvider);
    final response = await api.get(
      'api/messages/threads/$threadId',
      queryParams: {
        'limit': '$_pageSize',
        if (before != null) 'before': before.toIso8601String(),
      },
    );
    final rows = (response is Map ? response['messages'] : null) ?? const [];
    final page = [
      for (final row in rows)
        if (row is Map) DmMessage.fromJson(row),
    ];
    if (!mounted) return;
    state = state.copyWith(
      messages: before == null ? page : [...page, ...state.messages],
      hasMore: response is Map && response['has_more'] == true,
      isLoadingMore: false,
      clearOlderError: true,
    );
    // GET историей сервер уже отмечает прочитанное; счётчик в ленте обязан
    // погаснуть здесь, а не ждать, пока пользователь вернётся к списку.
    if (before == null) {
      ref.read(dmThreadsProvider.notifier).markThreadRead(threadId);
    }
  }

  Future<void> loadOlder() async {
    final threadId = state.threadId;
    if (threadId == null || state.isLoadingMore || !state.hasMore) return;
    final first = state.messages.isEmpty
        ? null
        : state.messages.first.createdAt;
    if (first == null) return;
    state = state.copyWith(isLoadingMore: true, clearOlderError: true);
    try {
      await _fetchHistory(threadId, before: first);
    } catch (e, s) {
      // Прямой `error` здесь запретил бы и писать: он перекрывает всю
      // переписку. Баннер над списком — свой ход.
      CrashLogService.log('dm: старые сообщения не догрузились', error: e, stack: s);
      if (!mounted) return;
      state = state.copyWith(
        isLoadingMore: false,
        olderError: _friendly(e),
      );
    }
  }

  Future<bool> send(String body) async {
    final text = body.trim();
    if (text.isEmpty || state.isSending || state.isSystem) return false;

    // Сообщения, которые не влезли в один экран, сервер всё равно принял бы —
    // порог одна сторона, и клиенту о нём напоминает отказ, а не счётчик.
    state = state.copyWith(isSending: true, clearError: true);
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post(
        'api/messages/threads/$peerId',
        body: {'body': text},
      );
      final raw = response is Map ? response['message'] : null;
      if (raw is! Map) {
        // Пустое/непонятное тело (api.post возвращает null на 204). Раньше
        // отсюда выходили без сброса isSending, и кнопка «отправить» умирала
        // до перезахода в диалог.
        if (!mounted) return false;
        state = state.copyWith(
          isSending: false,
          sendError: tr('Сервер не подтвердил сообщение'),
        );
        return false;
      }
      final message = DmMessage.fromJson(raw);
      if (!mounted) return true;
      state = state.copyWith(
        isSending: false,
        threadId: message.threadId,
        messages: _appended(state.messages, message),
        hasMore: state.hasMore,
      );
      ref.read(dmThreadsProvider.notifier).load(silent: true);
      return true;
    } catch (e, s) {
      CrashLogService.log('dm: сообщение не отправлено', error: e, stack: s);
      if (!mounted) return false;
      state = state.copyWith(isSending: false, sendError: _friendly(e));
      return false;
    }
  }

  void clearSendError() {
    state = state.copyWith(sendError: null);
  }

  void _onIncoming(Map<String, dynamic> payload) {
    final threadId = payload['thread_id']?.toString();
    if (threadId == null || threadId != state.threadId) return;
    final raw = payload['message'];
    if (raw is! Map) return;
    final message = DmMessage.fromJson(raw);
    state = state.copyWith(
      messages: _appended(state.messages, message),
    );
    if (_viewed && message.senderId != state.viewerId) {
      _markIncomingRead(threadId);
    }
  }

  /// Открытое окно = прочитанное. Сервер ставит `last_read_at` только по
  /// запросу, а без него штамп ждал следующего входа в диалог: собеседник
  /// считал реплику непрочитанной, хотя человек её уже видел.
  void _markIncomingRead(String threadId) {
    ref.read(dmThreadsProvider.notifier).markThreadRead(threadId);
    _pendingReadThreadId = threadId;
    _readFlush?.cancel();
    _readFlush = Timer(_readDebounce, () {
      _readFlush = null;
      unawaited(_postRead(threadId));
    });
  }

  /// Сервер приносит отправленное двумя дорогами: ответом на POST и событием в
  /// комнату самого отправителя. Какая быстрее — зависит от сети, поэтому обе
  /// сверяются по id, иначе реплика стоит в окне дважды.
  static List<DmMessage> _appended(
    List<DmMessage> current,
    DmMessage message,
  ) {
    if (current.any((m) => m.id == message.id)) return current;
    return [...current, message];
  }
}

final dmChatProvider =
    StateNotifierProvider.family<DmChatNotifier, DmChatState, String>(
      (ref, peerId) => DmChatNotifier(ref, peerId),
    );

/// Кто может писать мне.
class DmPrivacyNotifier extends StateNotifier<DmPrivacy?> {
  DmPrivacyNotifier(this.ref) : super(null) {
    _load();
  }

  final Ref ref;
  bool _saving = false;

  Future<void> _load() async {
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.get('api/messages/privacy');
      if (!mounted) return;
      if (response is Map) state = DmPrivacy.fromJson(response);
    } catch (_) {
      // Настроек может и не быть на старом беке — форма тогда стартует с «Все».
      if (!mounted) return;
      state = const DmPrivacy();
    }
  }

  Future<String?> save(DmPrivacy privacy) async {
    if (_saving) return tr('Уже сохраняю');
    _saving = true;
    try {
      final api = ref.read(apiServiceProvider);
      await api.put(
        'api/messages/privacy',
        body: {
          'mode': privacy.mode,
          'min_playtime_hours': privacy.minPlaytimeHours,
          'min_account_age_days': privacy.minAccountAgeDays,
        },
      );
      if (!mounted) return null;
      state = privacy;
      return null;
    } catch (e) {
      return _friendly(e);
    } finally {
      _saving = false;
    }
  }
}

final dmPrivacyProvider = StateNotifierProvider<DmPrivacyNotifier, DmPrivacy?>(
  (ref) => DmPrivacyNotifier(ref),
);

/// Список заблокированных. Без него «заблокировать» было бы кнопкой без
/// отмены: человек не мог бы вернуть переписку, не вспоминая id.
class DmBlocksNotifier extends StateNotifier<List<DmPeer>> {
  DmBlocksNotifier(this.ref) : super(const []) {
    load();
  }

  final Ref ref;

  Future<void> load() async {
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.get('api/messages/blocks');
      final rows = (response is Map ? response['blocked'] : null) ?? const [];
      if (!mounted) return;
      state = [
        for (final row in rows)
          if (row is Map) DmPeer.fromJson(row),
      ];
    } catch (_) {
      // Пустой список хуже честной ошибки, но не хуже заглушки на старом беке.
      if (!mounted) return;
      state = const [];
    }
  }

  /// Блокируют из окна переписки, где человек уже есть под рукой, — тащить
  /// его профиль отдельным запросом не зачем.
  Future<String?> block(DmPeer peer) async {
    if (state.any((p) => p.id == peer.id)) return null;
    final api = ref.read(apiServiceProvider);
    try {
      await api.post('api/messages/blocks/${peer.id}');
      if (!mounted) return null;
      state = [peer, ...state];
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  /// Блокировка прямо из ленты/профиля: переписки с человеком может и не быть,
  /// поэтому здесь только id, а не готовый [DmPeer].
  Future<String?> blockUser(String userId, {String? name}) async {
    if (state.any((p) => p.id == userId)) return null;
    final api = ref.read(apiServiceProvider);
    try {
      await api.post('api/messages/blocks/$userId');
      if (!mounted) return null;
      state = [DmPeer(id: userId, name: name ?? ''), ...state];
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  Future<String?> unblock(String userId) async {
    final api = ref.read(apiServiceProvider);
    try {
      await api.delete('api/messages/blocks/$userId');
      if (mounted) state = state.where((p) => p.id != userId).toList();
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }
}

final dmBlocksProvider = StateNotifierProvider<DmBlocksNotifier, List<DmPeer>>(
  (ref) => DmBlocksNotifier(ref),
);
