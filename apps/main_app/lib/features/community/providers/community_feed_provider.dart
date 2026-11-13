import 'dart:async';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/socket_service.dart';
import 'package:canvas_app/models/wall_post_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CommunityFeedState {
  final List<WallPost> posts;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? error;
  final int offset;

  const CommunityFeedState({
    this.posts = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
    this.offset = 0,
  });

  CommunityFeedState copyWith({
    List<WallPost>? posts,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? error,
    int? offset,
  }) {
    return CommunityFeedState(
      posts: posts ?? this.posts,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: error,
      offset: offset ?? this.offset,
    );
  }
}

class CommunityFeedNotifier extends StateNotifier<CommunityFeedState> {
  final ApiService _api;
  final String filter;
  static const int _limit = 20;

  /// Потолок ленты в памяти: `new_wall_post` приходит на каждый новый пост
  /// платформы и раньше добавлял его без предела — за долгую сессию список
  /// рос бесконечно.
  static const int _maxPostsInMemory = 200;

  /// Счётчики лайков/комментариев копятся порциями: сервер шлёт
  /// `post_stats_updated` всем клиентам на каждый лайк где угодно, и раньше
  /// каждое такое событие копировало весь список и перестраивало ленту.
  final Map<String, ({int? likes, int? comments})> _pendingStats = {};
  Timer? _statsFlush;

  CommunityFeedNotifier(this._api, this.filter) : super(const CommunityFeedState()) {
    _loadInitial();
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

  /// Применить накопленные счётчики одним изменением состояния.
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
    if (data is! Map<String, dynamic>) return;
    try {
      final newPost = WallPost.fromJson(data);

      // Only add if it matches filter ('all' or if we follow them and filter is 'following')
      final bool isFollowingAuthor = data['is_following'] == true;
      if (filter == 'all' || (filter == 'following' && isFollowingAuthor)) {
        // Prevent duplicates
        if (!state.posts.any((p) => p.id == newPost.id)) {
          final newPosts = [newPost, ...state.posts];
          if (newPosts.length > _maxPostsInMemory) {
            newPosts.removeRange(_maxPostsInMemory, newPosts.length);
          }
          state = state.copyWith(posts: newPosts, offset: state.offset + 1);
        }
      }
    } catch (e) {
      // Error parsing post
    }
  }

  Future<void> _loadInitial() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _api.get('api/community/feed?limit=$_limit&offset=0&filter=$filter');
      final List list = response as List;
      final newPosts = list.map((e) => WallPost.fromJson(e)).toList();
      state = state.copyWith(
        posts: newPosts,
        isLoading: false,
        hasMore: newPosts.length == _limit,
        offset: newPosts.length,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    
    state = state.copyWith(isLoadingMore: true, error: null);
    try {
      final response = await _api.get('api/community/feed?limit=$_limit&offset=${state.offset}&filter=$filter');
      final List list = response as List;
      final fetchedPosts = list.map((e) => WallPost.fromJson(e)).toList();
      state = state.copyWith(
        posts: [...state.posts, ...fetchedPosts],
        isLoadingMore: false,
        hasMore: fetchedPosts.length == _limit,
        offset: state.offset + fetchedPosts.length,
      );
    } catch (e) {
      state = state.copyWith(isLoadingMore: false, error: e.toString());
    }
  }

  Future<void> refresh() async {
    if (state.isLoading) return;
    await _loadInitial();
  }

  void updatePostLocally(WallPost updatedPost) {
    final newPosts = state.posts.map((p) => p.id == updatedPost.id ? updatedPost : p).toList();
    state = state.copyWith(posts: newPosts);
  }

  void removePostLocally(String postId) {
    final newPosts = state.posts.where((p) => p.id != postId).toList();
    state = state.copyWith(posts: newPosts);
  }
}

final communityFeedProvider = StateNotifierProvider.family<CommunityFeedNotifier, CommunityFeedState, String>((ref, filter) {
  return CommunityFeedNotifier(ref.read(apiServiceProvider), filter);
});
