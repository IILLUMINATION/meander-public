import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/session_store.dart';
import 'package:canvas_app/core/services/socket_service.dart';
import 'package:canvas_app/features/community/providers/community_feed_provider.dart';
import 'package:canvas_app/features/community/providers/community_users_provider.dart';
import 'package:canvas_app/features/forums/providers/forum_provider.dart';
import 'package:canvas_app/features/market/providers/recommendations_provider.dart';
import 'package:canvas_app/features/messages/providers/dm_provider.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_repository.dart';
import 'package:canvas_app/features/profile/providers/author_notifs_provider.dart';
import 'package:canvas_app/features/quests/providers/cloud_sync_provider.dart';
import 'package:canvas_app/features/wall/providers/wall_paginated_provider.dart';

/// Провайдеры, в которых лежит то, что видит именно этот аккаунт. Все они
/// живут до конца работы приложения (не autoDispose), поэтому без явной
/// инвалидации следующий вошедший человек первым делом получает чужие
/// переписки, чужие сообщества и чужую стену.
final List<ProviderOrFamily> _accountScopedProviders = [
  communityFeedProvider,
  communityTopProvider,
  communityOnlineProvider,
  wallPaginatedProvider,
  forumsCatalogProvider,
  forumLobbyProvider,
  forumHotTopicsProvider,
  dmThreadsProvider,
  dmChatProvider,
  dmPrivacyProvider,
  dmBlocksProvider,
  myCosmeticsProvider,
  authorNotifsSettingsProvider,
  userGenrePrefsProvider,
  recentlyViewedQuestsProvider,
  cloudSyncProvider,
  cloudSyncRemoteListProvider,
];

/// Ключи SharedPreferences: два — сессия, остальные — слепок аккаунта на
/// устройстве. `fcm_token` нужен, чтобы после входа другим человеком токен
/// устройства уехал на сервер заново, а не сверился с прошлым владельцем.
const List<String> _accountPrefsKeys = [
  'jwt_token',
  'user_id',
  'fcm_token',
  'recently_viewed_quests_v1',
];

/// Вход и выход меняют владельца кэшей. Всё перечисленное живёт в
/// не-autoDispose провайдерах, поэтому без инвалидации и после входа человек
/// держит гостевые заглушки (или чужой список mute) до перезапуска
/// приложения.
void reloadAccountScopedProviders(void Function(ProviderOrFamily) invalidate) {
  for (final provider in _accountScopedProviders) {
    invalidate(provider);
  }
}

/// Единственный выход из аккаунта — его вызывают кнопка «Выйти» в
/// настройках, кнопка в чужом профиле и принудительный logout на 401.
///
/// [notifyServer] выключается на 401: просить сервер снять push-привязку
/// мёртвым токеном бессмысленно, а ответ снова уронил бы нас в этот путь.
Future<void> endSession({
  required BuildContext context,
  bool notifyServer = true,
}) async {
  // Контейнер берётся до первого await — дальше context не нужен вовсе.
  final container = ProviderScope.containerOf(context, listen: false);
  final prefs = await SharedPreferences.getInstance();

  if (notifyServer && prefs.getString('jwt_token') != null) {
    try {
      // На сервере fcm_token — одна колонка профиля, поэтому «ничего»
      // означает отписку: без этого шага пуши прежнего аккаунта продолжают
      // приходить на это устройство.
      await container
          .read(apiServiceProvider)
          .post('profiles/fcm-token', body: {'token': null});
    } catch (_) {
      // выход важнее отписки
    }
  }

  // Сессия активного сервера: убираем и раскладку по областям, иначе при
  // следующем переключении на этот сервер мёртвый токен вернулся бы в
  // `jwt_token` из `session_token@…`. Сессии других серверов не трогаем.
  await SessionStore.clearActive();

  for (final key in _accountPrefsKeys) {
    await prefs.remove(key);
  }

  SocketService().disconnect();

  reloadAccountScopedProviders(container.invalidate);
}
