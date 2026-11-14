import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';

/// Канал — вещание, а не общий чат: владелец и его админы пишут, подписчики
/// читают. Роль `my_role` приходит с сервера только для подписчиков.
class Channel {
  const Channel({
    required this.id,
    required this.title,
    this.description = '',
    this.avatarUrl,
    this.isPublic = true,
    this.subscribersCount = 0,
    this.postsCount = 0,
    this.myRole,
    this.lastPostAt,
    this.ownerId,
    this.commentsEnabled = true,
  });

  final String id;
  final String title;
  final String description;
  final String? avatarUrl;
  final bool isPublic;
  final int subscribersCount;
  final int postsCount;

  /// 'owner', 'admin', 'subscriber' или null — не подписан.
  final String? myRole;
  final DateTime? lastPostAt;
  final String? ownerId;
  final bool commentsEnabled;

  bool get isOwner => myRole == 'owner';
  bool get canPost => myRole == 'owner' || myRole == 'admin';
  bool get isSubscribed => myRole != null;

  factory Channel.fromJson(Map<dynamic, dynamic> json) {
    return Channel(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      avatarUrl: json['avatar_url']?.toString(),
      isPublic: json['is_public'] != false,
      subscribersCount: _int(json['subscribers_count']),
      postsCount: _int(json['posts_count']),
      myRole: json['my_role']?.toString(),
      lastPostAt: _local(json['last_post_at']),
      ownerId: json['owner_id']?.toString(),
      commentsEnabled: json['comments_enabled'] != false,
    );
  }

  Channel copyWith({String? myRole, bool clearRole = false, int? subscribersCount}) {
    return Channel(
      id: id,
      title: title,
      description: description,
      avatarUrl: avatarUrl,
      isPublic: isPublic,
      subscribersCount: subscribersCount ?? this.subscribersCount,
      postsCount: postsCount,
      myRole: clearRole ? null : (myRole ?? this.myRole),
      lastPostAt: lastPostAt,
      ownerId: ownerId,
      commentsEnabled: commentsEnabled,
    );
  }
}

class ChannelPost {
  const ChannelPost({
    required this.id,
    required this.channelId,
    required this.body,
    required this.createdAt,
    this.attachments = const [],
    this.viewsCount = 0,
    this.commentsCount = 0,
    this.editedAt,
  });

  final String id;
  final String channelId;
  final String body;
  final DateTime createdAt;
  final List<DmAttachment> attachments;
  final int viewsCount;
  final int commentsCount;
  final DateTime? editedAt;

  factory ChannelPost.fromJson(Map<dynamic, dynamic> json) {
    return ChannelPost(
      id: (json['id'] ?? '').toString(),
      channelId: (json['channel_id'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      createdAt: _local(json['created_at']) ?? DateTime.now(),
      attachments: DmAttachment.listFrom(json['attachments']),
      viewsCount: _int(json['views_count']),
      commentsCount: _int(json['comments_count']),
      editedAt: _local(json['edited_at']),
    );
  }
}

class ChannelComment {
  const ChannelComment({
    required this.id,
    required this.body,
    required this.createdAt,
    this.authorName,
    this.authorAvatarUrl,
  });

  final String id;
  final String body;
  final DateTime createdAt;
  final String? authorName;
  final String? authorAvatarUrl;

  factory ChannelComment.fromJson(Map<dynamic, dynamic> json) {
    return ChannelComment(
      id: (json['id'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      createdAt: _local(json['created_at']) ?? DateTime.now(),
      authorName: json['author_name']?.toString() ?? json['full_name']?.toString(),
      authorAvatarUrl: json['author_avatar_url']?.toString() ??
          json['avatar_url']?.toString(),
    );
  }
}

/// Строка под названием канала: «1,2 тыс. подписчиков · 14 постов».
String channelMetaLine(Channel channel) {
  final subs = channel.subscribersCount == 1
      ? tr('1 подписчик')
      : trf('{p0} подписчиков', {'p0': _compact(channel.subscribersCount)});
  final posts = channel.postsCount == 1
      ? tr('1 пост')
      : trf('{p0} постов', {'p0': _compact(channel.postsCount)});
  return '$subs · $posts';
}

String _compact(int value) {
  if (value < 1000) return '$value';
  final thousands = value / 1000;
  return '${thousands.toStringAsFixed(thousands >= 10 ? 0 : 1)}K';
}

int _int(Object? raw) =>
    raw is int ? raw : int.tryParse('${raw ?? 0}') ?? 0;

DateTime? _local(Object? raw) => DateTime.tryParse('${raw ?? ''}')?.toLocal();