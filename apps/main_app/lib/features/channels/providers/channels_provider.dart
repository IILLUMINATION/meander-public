import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/crash_log_service.dart';
import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Список каналов и поиск.
class ChannelsState {
  const ChannelsState({
    this.channels = const [],
    this.isLoading = true,
    this.error,
    this.query = '',
    this.mineOnly = false,
  });

  final List<Channel> channels;
  final bool isLoading;
  final String? error;
  final String query;
  final bool mineOnly;

  ChannelsState copyWith({
    List<Channel>? channels,
    bool? isLoading,
    String? error,
    String? query,
    bool? mineOnly,
  }) {
    return ChannelsState(
      channels: channels ?? this.channels,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      query: query ?? this.query,
      mineOnly: mineOnly ?? this.mineOnly,
    );
  }
}

class ChannelsNotifier extends StateNotifier<ChannelsState> {
  ChannelsNotifier(this.ref) : super(const ChannelsState()) {
    load();
  }

  final Ref ref;

  Future<void> load({String? query, bool? mineOnly, bool silent = false}) async {
    final nextQuery = query ?? state.query;
    final nextMine = mineOnly ?? state.mineOnly;
    if (!silent) {
      state = state.copyWith(
        isLoading: true,
        query: nextQuery,
        mineOnly: nextMine,
      );
    }
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.get(
        'channels',
        queryParams: {
          if (nextQuery.trim().isNotEmpty) 'q': nextQuery.trim(),
          if (nextMine) 'mine': 'true',
        },
      );
      if (!mounted) return;
      final rows = (response is Map ? response['channels'] : null) ?? const [];
      state = ChannelsState(
        isLoading: false,
        query: nextQuery,
        mineOnly: nextMine,
        channels: [
          for (final row in rows)
            if (row is Map) Channel.fromJson(row),
        ],
      );
    } catch (e, s) {
      CrashLogService.log('channels: список не загрузился', error: e, stack: s);
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }
}

final channelsProvider = StateNotifierProvider<ChannelsNotifier, ChannelsState>(
  (ref) => ChannelsNotifier(ref),
);

/// Состояние одного канала: шапка, посты, подписка.
class ChannelState {
  const ChannelState({
    this.channel,
    this.posts = const [],
    this.isLoading = true,
    this.isSending = false,
    this.hasMore = false,
    this.error,
  });

  final Channel? channel;
  final List<ChannelPost> posts;
  final bool isLoading;
  final bool isSending;
  final bool hasMore;
  final String? error;

  ChannelState copyWith({
    Channel? channel,
    List<ChannelPost>? posts,
    bool? isLoading,
    bool? isSending,
    bool? hasMore,
    String? error,
    bool clearError = false,
  }) {
    return ChannelState(
      channel: channel ?? this.channel,
      posts: posts ?? this.posts,
      isLoading: isLoading ?? this.isLoading,
      isSending: isSending ?? this.isSending,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ChannelNotifier extends StateNotifier<ChannelState> {
  ChannelNotifier(this.ref, this.channelId) : super(const ChannelState()) {
    load();
  }

  final Ref ref;
  final String channelId;

  Future<void> load() async {
    try {
      final api = ref.read(apiServiceProvider);
      final [head, feed] = await Future.wait([
        api.get('channels/$channelId'),
        api.get('channels/$channelId/posts', queryParams: {'limit': '20'}),
      ]);
      if (!mounted) return;
      final channel = head is Map && head['channel'] is Map
          ? Channel.fromJson(head['channel'] as Map)
          : null;
      final posts = (feed is Map ? feed['posts'] : null) ?? const [];
      state = state.copyWith(
        isLoading: false,
        channel: channel,
        posts: [
          for (final row in posts)
            if (row is Map) ChannelPost.fromJson(row),
        ],
        hasMore: feed is Map && feed['has_more'] == true,
        clearError: true,
      );
    } catch (e, s) {
      CrashLogService.log('channel: не открылся', error: e, stack: s);
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  Future<void> loadOlder() async {
    if (!state.hasMore || state.posts.isEmpty) return;
    final oldest = state.posts.last.createdAt.toUtc().toIso8601String();
    try {
      final api = ref.read(apiServiceProvider);
      final feed = await api.get(
        'channels/$channelId/posts',
        queryParams: {'limit': '20', 'before': oldest},
      );
      if (!mounted) return;
      final rows = (feed is Map ? feed['posts'] : null) ?? const [];
      state = state.copyWith(
        posts: [
          ...state.posts,
          for (final row in rows)
            if (row is Map) ChannelPost.fromJson(row),
        ],
        hasMore: feed is Map && feed['has_more'] == true,
      );
    } catch (e, s) {
      CrashLogService.log('channel: лента не догрузилась', error: e, stack: s);
    }
  }

  Future<String?> toggleSubscription() async {
    final channel = state.channel;
    if (channel == null) return tr('Канал не загружен');
    try {
      final api = ref.read(apiServiceProvider);
      if (channel.isSubscribed) {
        await api.delete('channels/$channelId/subscribe');
        state = state.copyWith(
          channel: channel.copyWith(
            clearRole: true,
            subscribersCount: (channel.subscribersCount - 1).clamp(0, 1 << 31),
          ),
        );
      } else {
        await api.post('channels/$channelId/subscribe');
        state = state.copyWith(
          channel: channel.copyWith(
            myRole: 'subscriber',
            subscribersCount: channel.subscribersCount + 1,
          ),
        );
      }
      return null;
    } catch (e, s) {
      CrashLogService.log('channel: подписка не переключилась', error: e, stack: s);
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  Future<String?> publish(
    String body, {
    List<DmAttachment> attachments = const [],
  }) async {
    if (!(state.channel?.canPost ?? false)) return tr('Писать может только владелец');
    final text = body.trim();
    if (text.isEmpty && attachments.isEmpty) return null;
    state = state.copyWith(isSending: true);
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post(
        'channels/$channelId/posts',
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
      if (!mounted) return null;
      final raw = response is Map ? response['post'] : null;
      state = state.copyWith(
        isSending: false,
        posts: [
          if (raw is Map) ChannelPost.fromJson(raw),
          ...state.posts,
        ],
        channel: state.channel?.copyWith(
          subscribersCount: state.channel?.subscribersCount,
        ),
      );
      return null;
    } catch (e, s) {
      CrashLogService.log('channel: пост не опубликован', error: e, stack: s);
      if (!mounted) return tr('Не удалось опубликовать');
      state = state.copyWith(isSending: false);
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  Future<String?> deletePost(String postId) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.delete('channels/$channelId/posts/$postId');
      if (!mounted) return null;
      state = state.copyWith(
        posts: state.posts.where((post) => post.id != postId).toList(),
      );
      return null;
    } catch (e, s) {
      CrashLogService.log('channel: пост не удалился', error: e, stack: s);
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  /// Отметка просмотра: один раз на человека, поэтому ошибку молча глотаем.
  Future<void> markViewed(String postId) async {
    try {
      await ref.read(apiServiceProvider).post('channels/posts/$postId/view');
    } catch (_) {
      // Счётчик просмотров не стоит показа человеку.
    }
  }
}

final channelProvider =
    StateNotifierProvider.family<ChannelNotifier, ChannelState, String>(
      (ref, channelId) => ChannelNotifier(ref, channelId),
    );

/// Комментарии под постом.
class ChannelCommentsState {
  const ChannelCommentsState({
    this.comments = const [],
    this.isLoading = true,
    this.isSending = false,
  });

  final List<ChannelComment> comments;
  final bool isLoading;
  final bool isSending;

  ChannelCommentsState copyWith({
    List<ChannelComment>? comments,
    bool? isLoading,
    bool? isSending,
  }) {
    return ChannelCommentsState(
      comments: comments ?? this.comments,
      isLoading: isLoading ?? this.isLoading,
      isSending: isSending ?? this.isSending,
    );
  }
}

class ChannelCommentsNotifier extends StateNotifier<ChannelCommentsState> {
  ChannelCommentsNotifier(this.ref, this.postId) : super(const ChannelCommentsState()) {
    load();
  }

  final Ref ref;
  final String postId;

  Future<void> load() async {
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.get('channels/posts/$postId/comments');
      if (!mounted) return;
      final rows = (response is Map ? response['comments'] : null) ?? const [];
      state = ChannelCommentsState(
        isLoading: false,
        comments: [
          for (final row in rows)
            if (row is Map) ChannelComment.fromJson(row),
        ],
      );
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false);
    }
  }

  Future<bool> send(String body) async {
    final text = body.trim();
    if (text.isEmpty || state.isSending) return false;
    state = state.copyWith(isSending: true);
    try {
      final api = ref.read(apiServiceProvider);
      final response = await api.post(
        'channels/posts/$postId/comments',
        body: {'body': text},
      );
      if (!mounted) return true;
      final raw = response is Map ? response['comment'] : null;
      state = state.copyWith(
        isSending: false,
        comments: [
          ...state.comments,
          if (raw is Map) ChannelComment.fromJson(raw),
        ],
      );
      return true;
    } catch (e, s) {
      CrashLogService.log('channel: комментарий не ушёл', error: e, stack: s);
      if (!mounted) return false;
      state = state.copyWith(isSending: false);
      return false;
    }
  }
}

final channelCommentsProvider = StateNotifierProvider.family<
  ChannelCommentsNotifier,
  ChannelCommentsState,
  String
>((ref, postId) => ChannelCommentsNotifier(ref, postId));