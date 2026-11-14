import 'package:flutter/material.dart';

import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:canvas_app/features/channels/screens/channel_screen.dart';
import 'package:canvas_app/features/support/screens/support_screen.dart';
import 'package:canvas_app/features/forums/screens/forum_lobby_screen.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/screens/chat_screen.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';

/// Единый маршрут тапа по уведомлению — по тем типам, которые бэкенд реально
/// высылает пушем (см. `buildPushFromNotification` в services/fcm.ts).
///
/// Входов три: FCM-пуш, локальная плашка Android, когда приложение открыто,
/// и десктопная плашка из сокета. Раньше у каждого была копия этого кода, и
/// копии успели разъехаться: `system_news` понимал только десктоп, а баны и
/// снятые топики форумов — ни один.
void routeNotificationTap(Map<String, dynamic> data) {
  final type = data['type'] as String?;
  if (type == null) return;

  final nav = navigatorKey.currentState;
  if (nav == null) {
    debugPrint('❌ [Notification] navigatorKey is null, cannot navigate');
    return;
  }

  final questId = data['questId'] as String?;
  final channelId = data['channelId'] as String?;
  final postId = data['postId'] as String?;
  final actorId = data['actorId'] as String?;
  final forumSlug = data['forumSlug'] as String?;

  void open(Widget screen) =>
      nav.push(MaterialPageRoute(builder: (_) => screen));

  if (type == 'dm_message') {
    // id отправителя и есть собеседник.
    if (actorId != null && actorId.isNotEmpty) {
      open(ChatScreen(peerId: actorId));
    }
    return;
  }

  if (type == 'system_news') {
    open(ChatScreen(peerId: kSystemUserId));
    return;
  }

  if (type == 'support_message' || type == 'support_reply') {
    // Обращение открывается в том же окне, что и диалог с ботом: отдельного
    // экрана у тикета для автора нет.
    open(SupportScreen());
    return;
  }

  if (type == 'channel_post') {
    if (channelId != null && channelId.isNotEmpty) {
      open(ChannelScreen(channelId: channelId));
    }
    return;
  }

  if (type == 'forum_ban' || type == 'forum_topic_removed') {
    // Ограничение и снятый топик живут внутри сообщества: без слага тап по
    // плашке не вёл никуда.
    if (forumSlug != null && forumSlug.isNotEmpty) {
      open(ForumLobbyScreen(slug: forumSlug));
    }
    return;
  }

  if (type == 'quest_like' ||
      type == 'quest_review' ||
      type == 'review_reply' ||
      type == 'quest_published' ||
      type == 'quest_updated' ||
      type == 'quest_approved' ||
      type == 'quest_rejected') {
    if (questId != null && questId.isNotEmpty) {
      open(MarketQuestLoaderScreen(questId: questId));
    }
    return;
  }

  if (type == 'wall_post_new' ||
      type == 'wall_post_like' ||
      type == 'wall_post_comment') {
    if (postId != null && postId.isNotEmpty) {
      open(PostLinkLoaderScreen(postId: postId));
    }
    return;
  }

  if (type == 'user_follow') {
    if (actorId != null && actorId.isNotEmpty) {
      open(ProfileScreen(userId: actorId));
    }
  }
}
