import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

import 'package:canvas_app/firebase_options.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/notification_routing.dart';

/// Background message handler - must be a top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await _initializeFirebase();
  debugPrint('🔔 [FCM Background] Message ID: ${message.messageId}');
  debugPrint('🔔 [FCM Background] Title: ${message.notification?.title}');
  debugPrint('🔔 [FCM Background] Body: ${message.notification?.body}');
}

/// iOS uses the native GoogleService-Info.plist bundled with Runner. This
/// avoids mixing a stale Dart-generated API key with the native Firebase app.
Future<void> _initializeFirebase() async {
  if (Platform.isIOS) {
    await Firebase.initializeApp();
    return;
  }
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
}

/// Android notification channel for high-priority notifications
const AndroidNotificationChannel highImportanceChannel =
    AndroidNotificationChannel(
      'meander_notifications',
      'Уведомления Meander',
      importance: Importance.max,
      enableVibration: true,
      playSound: true,
    );

class FirebaseMessagingService {
  static final FirebaseMessagingService _instance =
      FirebaseMessagingService._internal();

  factory FirebaseMessagingService() => _instance;

  FirebaseMessagingService._internal();

  late final FirebaseMessaging _firebaseMessaging;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Единый future инициализации: сколько бы раз его ни спросили (в том числе
  /// из `fcmTokenProvider`), работа выполняется один раз.
  Future<void>? _initFuture;

  /// Дождаться инициализации. Если она ещё не начата — начать.
  ///
  /// Раньше геттер отвечал «готово», когда инициализация ещё не стартовала:
  /// `bootstrap` вызывал FCM после первого кадра, а `fcmTokenProvider` успевал
  /// спросить токен раньше и получал `null` без единой попытки.
  Future<void> get initializationFuture => initialize();

  /// Initialize Firebase Messaging and local notifications
  Future<void> initialize() {
    if (_initialized) return Future<void>.value();

    // iOS временно отключён (free-аккаунт): не запрашиваем разрешение и не
    // отправляем токен, чтобы не трогать APNs без нужных entitlements.
    if (Platform.isIOS) {
      debugPrint('⚠️ [FCM] iOS notifications disabled for free-account testing');
      return Future<void>.value();
    }

    return _initFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      // Initialize Firebase
      debugPrint('📱 [FCM] Initializing Firebase...');
      await _initializeFirebase();
      _firebaseMessaging = FirebaseMessaging.instance;

      // Set background message handler
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // Initialize local notifications for Android
      if (Platform.isAndroid) {
        await _initializeLocalNotifications();
      }

      // Request permissions for iOS and Android 13+
      await _requestNotificationPermissions();

      // Set up foreground message handler
      _setupForegroundMessageHandler();

      // Handle notification taps
      _setupNotificationTapHandler();
      
      // Handle app opened from terminated state via notification tap
      _checkInitialMessage();

      _initialized = true;
      debugPrint('✅ [FCM] Firebase Messaging initialized successfully');
    } catch (e) {
      // Повторная попытка разрешена: следующий вызов `initialize()` начнёт
      // заново, а не вернёт закэшированный отказ.
      _initFuture = null;
      debugPrint('❌ [FCM] Initialization error: $e');
    }
  }

  /// Initialize Flutter Local Notifications plugin
  Future<void> _initializeLocalNotifications() async {
    try {
      // Create notification channel
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(highImportanceChannel);

      // Initialize the plugin
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
      );

      // Тап по плашке, показанной самим приложением (сообщение пришло, когда
      // оно открыто), — это NOT FCM-тап: onMessageOpenedApp на него не
      // срабатывает. Без колбэка такая плашка была мёртвой.
      await _localNotifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _onLocalNotificationResponse,
      );
      debugPrint('✅ [LocalNotifications] Initialized');
    } catch (e) {
      debugPrint('❌ [LocalNotifications] Initialization error: $e');
    }
  }

  /// Request notification permissions
  Future<void> _requestNotificationPermissions() async {
    try {
      final NotificationSettings settings = await _firebaseMessaging
          .requestPermission(
            alert: true,
            badge: true,
            sound: true,
            provisional: false,
            announcement: false,
            carPlay: false,
            criticalAlert: false,
          );

      debugPrint(
        '📋 [FCM] Notification permission status: ${settings.authorizationStatus}',
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        debugPrint('✅ [FCM] Notifications authorized');
      } else if (settings.authorizationStatus ==
          AuthorizationStatus.provisional) {
        debugPrint('⚠️ [FCM] Provisional notification permission');
      } else {
        debugPrint('❌ [FCM] Notifications denied by user');
      }
    } catch (e) {
      debugPrint('❌ [FCM] Permission request error: $e');
    }
  }

  /// Set up foreground message handler
  void _setupForegroundMessageHandler() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('🔔 [FCM Foreground] Message received');
      debugPrint('   - ID: ${message.messageId}');
      debugPrint('   - Title: ${message.notification?.title}');
      debugPrint('   - Body: ${message.notification?.body}');

      final RemoteNotification? notification = message.notification;
      final AndroidNotification? android = message.notification?.android;

      // Show local notification when app is in foreground
      if (notification != null && android != null) {
        _showLocalNotification(
          id: notification.hashCode,
          title: notification.title ?? 'Meander',
          body: notification.body ?? '',
          payload: jsonEncode(message.data),
        );
      }
    });
  }

  /// Set up notification tap handler
  void _setupNotificationTapHandler() {
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('👆 [FCM] Notification tapped (foreground/background) - ID: ${message.messageId}');
      _handleNotificationTap(message);
    });
  }

  /// Check if app was opened from terminated state
  Future<void> _checkInitialMessage() async {
    try {
      final RemoteMessage? initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('👆 [FCM] Notification tapped (terminated) - ID: ${initialMessage.messageId}');
        // Add a small delay to ensure app navigation is fully initialized before routing
        Future.delayed(const Duration(milliseconds: 500), () {
          _handleNotificationTap(initialMessage);
        });
      }
    } catch (e) {
      debugPrint('❌ [FCM] Error checking initial message: $e');
    }
  }

  /// Show local notification
  Future<void> _showLocalNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    try {
      await _localNotifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            highImportanceChannel.id,
            highImportanceChannel.name,
            channelDescription: tr('Важные уведомления приложения'),
            importance: Importance.max,
            priority: Priority.high,
            enableVibration: true,
            playSound: true,
            icon: '@mipmap/ic_launcher',
          ),
        ),
        payload: payload,
      );
      debugPrint('✅ [LocalNotifications] Notification shown: $title');
    } catch (e) {
      debugPrint('❌ [LocalNotifications] Error showing notification: $e');
    }
  }

  /// Handle notification tap
  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('📊 [FCM] Notification data: ${message.data}');
    routeNotificationTap(message.data);
  }

  /// Тап по плашке, которую показало приложение (сообщение пришло при
  /// открытом приложении): FCM про такую ничего не знает, ответ приходит
  /// сюда, и payload — JSON, который мы сами положили в `_showLocalNotification`.
  void _onLocalNotificationResponse(NotificationResponse response) {
    final raw = response.payload;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      routeNotificationTap(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('❌ [LocalNotifications] Bad payload: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    // Clean up if needed
  }
}
