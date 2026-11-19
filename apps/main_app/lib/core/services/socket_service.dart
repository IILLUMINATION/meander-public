import 'dart:io';

import 'package:canvas_app/core/services/server_registry.dart';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/net/blind_tunnel.dart';
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

  /// Токен, с которым подключён сокет. Сервер проверяет
  /// `socket.handshake.auth.token` (backend/src/services/socket.ts), поэтому
  /// токен уходит в `auth` рукопожатия, а не в query.
  String? _token;
  final Set<String> _joinedPosts = {};
  Function(dynamic)? _onNewCommentCallback;

  /// Приём входящих сообщений.
  ///
  /// Комната не подписывается на диалог: сервер шлёт `dm_message` обоим
  /// участникам в их личные `user_<id>`-комнаты, которых хватает, чтобы
  /// обновить и ленту переписок, и открытое окно чата.
  final Set<void Function(Map<String, dynamic>)> _dmListeners = {};

  Future<void> init(String token) async {
    // Вход другим аккаунтом: сокет держит авторизацию прежним токеном, а
    // `_initialized` не давал переинициализироваться — следующий человек
    // оставался в чужих личных комнатах.
    if (_initialized && _token == token) return;
    if (_initialized) {
      _socket?.dispose();
      _socket = null;
      _initialized = false;
    }
    _token = token;

    if (Platform.isWindows || Platform.isLinux) {
      await localNotifier.setup(
        appName: 'Meander',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    }

    // Socket.io долгоживущий: подключаемся к живому пути сразу, чтобы не
    // гонять reconnect-цикл по заблокированному домену — путь ServerRegistry
    // уже проверен последним REST-запросом или проверяется здесь.
    await ServerRegistry.instance.ensureReachable();

    // Configure socket.io
    _socket = io.io(
      AppConfig.apiUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          // Без `auth.token` сервер отвечает «Authentication error: No token
          // provided» и не подписывает на `user_<id>`: реальное время
          // (личные сообщения, уведомления) не доходило до залогиненных.
          .setAuth({'token': token})
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
      // Socket.IO сам переподключается, но его websocket-клиент не проходит
      // через ApiService. Считаем сетевой отказ тем же способом, чтобы
      // мёртвый ретранслятор не держал realtime на одном адресе бесконечно.
      // Отказ авторизации — не сетевой: переключать путь из-за просроченного
      // токена нельзя, иначе приложение будет бесконечно менять ретрансляторы.
      final text = err.toString();
      if (!text.contains('Authentication') && !text.contains('No token')) {
        BlindTunnel.reportFailure();
      }
    });

    _socket?.onDisconnect((_) {
      debugPrint('⚠️ [Socket] Disconnected');
    });

    // Listen to personal notifications for desktop
    _socket?.on('new_notification', _handleNewNotification);
    _socket?.on('dm_message', _handleDmMessage);
    _socket?.on('post_stats_updated', _handlePostStatsUpdated);
    _socket?.on('new_wall_post', _handleNewWallPost);
    _socket?.on('support_message', _handleSupportMessage);
    _socket?.on('support_ticket_message', _handleSupportTicketMessage);

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
  /// Поддержка и инбокс команды: события раздельные (реплика в окне юзера и
  /// новый тикет в инбоксе), слушателей у каждого может быть несколько.
  final Set<void Function(Map<String, dynamic>)> _supportListeners = {};
  final Set<void Function(Map<String, dynamic>)> _ticketListeners = {};

  void _handleSupportMessage(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    for (final listener in _supportListeners.toList()) {
      listener(payload);
    }
  }

  void _handleSupportTicketMessage(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    for (final listener in _ticketListeners.toList()) {
      listener(payload);
    }
  }

  void addSupportListener(void Function(Map<String, dynamic>) listener) {
    _supportListeners.add(listener);
  }

  void removeSupportListener(void Function(Map<String, dynamic>) listener) {
    _supportListeners.remove(listener);
  }

  void addSupportTicketListener(void Function(Map<String, dynamic>) listener) {
    _ticketListeners.add(listener);
  }

  void removeSupportTicketListener(
    void Function(Map<String, dynamic>) listener,
  ) {
    _ticketListeners.remove(listener);
  }

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
    _token = null;
    _joinedPosts.clear();
    _onNewCommentCallback = null;
    _dmListeners.clear();
    _postStatsListeners.clear();
    _newPostListeners.clear();
  }
}
