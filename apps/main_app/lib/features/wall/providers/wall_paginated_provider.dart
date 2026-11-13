import 'dart:async';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/socket_service.dart';
import 'package:canvas_app/models/wall_post_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WallPaginatedState {
  final List<WallPost> posts;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? error;
  final int offset;

  const WallPaginatedState({
    this.posts = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
    this.offset = 0,
  });

  WallPaginatedState copyWith({
    List<WallPost>? posts,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? error,
    bool clearError = false,
    int? offset,
  }) {
    return WallPaginatedState(
      posts: posts ?? this.posts,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      // `error: null` сюда не доходит ( ?? оставляет старое), поэтому сброс
      // ошибки — отдельным флагом.
      error: clearError ? null : (error ?? this.error),
      offset: offset ?? this.offset,
    );
  }

  WallPaginatedState clear() {
    return WallPaginatedState();
  }
}

class WallPaginatedNotifier extends StateNotifier<WallPaginatedState> {
  final Ref ref;
  final String authorId;
  static const int _limit = 20;

  /// Накопитель статистики: глобальные `post_stats_updated` приходят на каждый
  /// лайк платформы, а не только в эту стену. Применяем пачкой, одним
  /// изменением состояния, вместо копии списка на каждое событие.
  final Map<String, ({int? likes, int? comments})> _pendingStats = {};
  Timer? _statsFlush;

  WallPaginatedNotifier(this.ref, this.authorId)
    : super(WallPaginatedState()) {
      SocketService().addFeedGlobalListeners(
        onStats: _onStatsUpdated,
        onNewPost: _onNewPostArrived,
      );
    }

  @override
  void dispose() {
    _statsFlush?.cancel();
    _pendingStats.clear();
    SocketService().removeFeedGlobalListeners(
      onStats: _onStatsUpdated,
      onNewPost: _onNewPostArrived,
    );
    super.dispose();
  }

  void _onStatsUpdated(Map<String, dynamic> data) {
    final postId = data['postId'] as String?;
    if (postId == null) return;
    _pendingStats[postId] = (
      likes: data['likes_count'] as int?,
      comments: data['comments_count'] as int?,
    );
    _statsFlush ??= Timer(const Duration(milliseconds: 250), _flushStats);
  }

  void _flushStats() {
    _statsFlush = null;
    if (!mounted || _pendingStats.isEmpty) return;

    var changed = false;
    final newPosts = List<WallPost>.from(state.posts);
    for (var i = 0; i < newPosts.length; i++) {
      final pending = _pendingStats[newPosts[i].id];
      if (pending == null) continue;
      final post = newPosts[i];
      final likes = pending.likes ?? post.likesCount;
      final comments = pending.comments ?? post.commentsCount;
      if (likes == post.likesCount && comments == post.commentsCount) continue;
      newPosts[i] = post.copyWith(likesCount: likes, commentsCount: comments);
      changed = true;
    }
    _pendingStats.clear();
    if (changed) state = state.copyWith(posts: newPosts);
  }

  void _onNewPostArrived(dynamic data) {
    // Чужую стену не дополняем чужими постами: там проще pull-to-refresh.
  }

  Future<void> loadPosts() async {
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      posts: [],
      offset: 0,
    );

    try {
      final api = ref.read(apiServiceProvider);
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';

      final response = await api.get(
        'api/author-walls/$authorId/posts',
        queryParams: {
          'limit': _limit.toString(),
          'offset': '0',
          'viewer_id': userId,
        },
      );

      if (response is! List) {
        state = state.copyWith(
          isLoading: false,
          posts: [],
          hasMore: false,
          offset: 0,
          clearError: true,
        );
        return;
      }

      final posts = response.map((json) => WallPost.fromJson(json)).toList();
      state = state.copyWith(
        posts: posts,
        isLoading: false,
        hasMore: posts.length >= _limit,
        offset: posts.length,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString()),
      );
    }
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore || state.isLoading) return;

    state = state.copyWith(isLoadingMore: true, clearError: true);

    try {
      final api = ref.read(apiServiceProvider);
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';

      final response = await api.get(
        'api/author-walls/$authorId/posts',
        queryParams: {
          'limit': _limit.toString(),
          'offset': state.offset.toString(),
          'viewer_id': userId,
        },
      );

      if (response is! List) {
        state = state.copyWith(isLoadingMore: false, hasMore: false);
        return;
      }

      final newPosts = response.map((json) => WallPost.fromJson(json)).toList();
      state = state.copyWith(
        posts: [...state.posts, ...newPosts],
        isLoadingMore: false,
        hasMore: newPosts.length >= _limit,
        offset: state.offset + newPosts.length,
      );
    } catch (e) {
      // Молча остановиться на 20-м посте нельзя: пользователь не отличит
      // сетевую ошибку от «больше ничего нет».
      state = state.copyWith(
        isLoadingMore: false,
        error: _friendlyError(e.toString()),
      );
    }
  }

  void removePostLocally(String postId) {
    state = state.copyWith(
      posts: state.posts.where((p) => p.id != postId).toList(),
    );
  }

  void updatePostLocally(WallPost updatedPost) {
    state = state.copyWith(
      posts: state.posts.map((p) => p.id == updatedPost.id ? updatedPost : p).toList(),
    );
  }

  String _friendlyError(String raw) {
    if (raw.contains('SERVER_MAINTENANCE')) return tr('Сервер на обслуживании');
    if (raw.contains('404')) return tr('Страница не найдена');
    if (raw.contains('403')) return tr('Доступ запрещён');
    if (raw.contains('500')) return tr('Ошибка сервера');
    if (raw.contains('SocketException') || raw.contains('ClientException')) {
      return tr('Нет соединения с сервером');
    }
    final lines = raw.split('\n');
    final msg = lines.first;
    return msg.length > 120 ? '${msg.substring(0, 120)}...' : msg;
  }
}

final wallPaginatedProvider = StateNotifierProvider.family<
  WallPaginatedNotifier,
  WallPaginatedState,
  String
>((ref, authorId) => WallPaginatedNotifier(ref, authorId));
