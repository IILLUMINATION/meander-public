import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:local_notifier/local_notifier.dart';
import 'package:canvas_app/core/services/notification_routing.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  io.Socket? _socket;
  bool _initialized = false;
  final Set<String> _joinedPosts = {};
  Function(dynamic)? _onNewCommentCallback;

  /// Приём входящих сообщений.
  ///
  /// Комната не подписывается на диалог: сервер шлёт `dm_message` обоим
  /// участникам в их личные `user_<id>`-комнаты, которых хватает, чтобы
  /// обновить и ленту переписок, и открытое окно чата.
  final Set<void Function(Map<String, dynamic>)> _dmListeners = {};

  Future<void> init(String token) async {
    if (_initialized) return;

    if (Platform.isWindows || Platform.isLinux) {
      await localNotifier.setup(
        appName: 'Meander',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    }

    // Configure socket.io
    _socket = io.io(
      AppConfig.apiUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          // Без явного backoff socket.io при недоступном сервере долбит
          // reconnect-попытками с интервалом по умолчанию (десятки секунд,
          // каждая — DNS+TCP+TLS): в логе живой сессии это бесконечные
          // «Connection Error: Failed host lookup». Ограничиваем и ставим
          // экспоненциальный рост до минуты.
          .setReconnectionDelay(2000)
          .setReconnectionDelayMax(60000)
          .build(),
    );

    _socket?.onConnect((_) {
      debugPrint('✅ [Socket] Connected');
      _rejoinRooms();
    });

    _socket?.onConnectError((err) {
      debugPrint('❌ [Socket] Connection Error: $err');
    });

    _socket?.onDisconnect((_) {
      debugPrint('⚠️ [Socket] Disconnected');
    });

    // Listen to personal notifications for desktop
    _socket?.on('new_notification', _handleNewNotification);
    _socket?.on('dm_message', _handleDmMessage);
    _socket?.on('post_stats_updated', _handlePostStatsUpdated);
    _socket?.on('new_wall_post', _handleNewWallPost);

    _socket?.connect();
    _initialized = true;
  }

  void _handleNewNotification(dynamic data) {
    debugPrint('🔔 [Socket] New Notification: $data');
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      _showDesktopNotification(data);
    }
  }

  void _showDesktopNotification(dynamic data) {
    try {
      final title = data['title']?.toString() ?? 'Meander';
      final body = data['body']?.toString() ?? '';
      final payloadData = data['data'] as Map<String, dynamic>? ?? {};

      LocalNotification notification = LocalNotification(
        title: title,
        body: body,
      );

      notification.onClick = () {
        debugPrint('👆 [Desktop Notification] Clicked');
        routeNotificationTap(payloadData);
      };

      notification.show();
    } catch (e) {
      debugPrint('❌ [Desktop Notification] Error: $e');
    }
  }

  void joinPostRoom(String postId, Function(dynamic) onNewComment) {
    if (_socket == null) return;
    _joinedPosts.add(postId);
    _socket?.emit('join_post', postId);
    _socket?.off('new_comment', _onNewCommentCallback);
    _onNewCommentCallback = onNewComment;
    _socket?.on('new_comment', _onNewCommentCallback!);
  }

  void leavePostRoom(String postId) {
    if (_socket == null) return;
    _joinedPosts.remove(postId);
    _socket?.emit('leave_post', postId);
    _socket?.off('new_comment', _onNewCommentCallback);
    _onNewCommentCallback = null;
  }

  void _rejoinRooms() {
    for (final postId in _joinedPosts) {
      _socket?.emit('join_post', postId);
    }
  }

  void _handleDmMessage(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    for (final listener in _dmListeners.toList()) {
      listener(payload);
    }
  }

  /// Лента переписок и окно открытого чата слушают одно и то же событие,
  /// поэтому здесь список, а не один колбэк как у комментариев.
  void addDmListener(void Function(Map<String, dynamic>) listener) {
    _dmListeners.add(listener);
  }

  void removeDmListener(void Function(Map<String, dynamic>) listener) {
    _dmListeners.remove(listener);
  }

  /// Сокета в тесте нет, а проверять надо путь «событие → слушатель → провайдер»
  /// целиком, поэтому гоняем payload через тех же слушателей, что и `_handleDmMessage`.
  @visibleForTesting
  void emitDmMessageForTest(Map<String, dynamic> payload) {
    _handleDmMessage(payload);
  }

  /// Счётчики лайков/комментов в лентах: список, а не один колбэк — лента
  /// сообщества и стена профиля живут одновременно, и единый слот означал бы,
  /// что последний открытый экран крадёт события у первого.
  final Set<void Function(Map<String, dynamic>)> _postStatsListeners = {};
  final Set<void Function(dynamic)> _newPostListeners = {};

  void addFeedGlobalListeners({
    required void Function(Map<String, dynamic>) onStats,
    required void Function(dynamic) onNewPost,
  }) {
    _postStatsListeners.add(onStats);
    _newPostListeners.add(onNewPost);
  }

  /// Снимать надо теми же tear-off'ами, что регистрировали: локатор-колбэк
  /// после `dispose` нотифайера падал бы на записи в `state`.
  void removeFeedGlobalListeners({
    required void Function(Map<String, dynamic>) onStats,
    required void Function(dynamic) onNewPost,
  }) {
    _postStatsListeners.remove(onStats);
    _newPostListeners.remove(onNewPost);
  }

  void _handlePostStatsUpdated(dynamic data) {
    debugPrint('📊 [Socket] Feed Stats Updated: $data');
    if (data is! Map<String, dynamic>) return;
    for (final listener in _postStatsListeners.toList()) {
      listener(data);
    }
  }

  void _handleNewWallPost(dynamic data) {
    debugPrint('📝 [Socket] New Wall Post received');
    for (final listener in _newPostListeners.toList()) {
      listener(data);
    }
  }

  /// Полный разрыв на выход из аккаунта. `dispose()`, а не только
  /// `disconnect()`: сокет держит обработчики событий и авторизацию прежним
  /// токеном, а `init()` отрабатывает один раз за запуск — без сброса
  /// следующий вошедший остался бы в чужих комнатах.
  void disconnect() {
    _socket?.dispose();
    _socket = null;
    _initialized = false;
    _joinedPosts.clear();
    _onNewCommentCallback = null;
    _dmListeners.clear();
    _postStatsListeners.clear();
    _newPostListeners.clear();
  }
}
