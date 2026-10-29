import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/oauth_config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/onboarding_service.dart';
import 'package:canvas_app/core/services/session_service.dart';
import 'package:canvas_app/core/utils/apple_nonce.dart';
import 'package:canvas_app/core/utils/pkce.dart';
import 'package:canvas_app/features/profile/providers/fcm_token_provider.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/market/screens/market_screen.dart';
import 'package:canvas_app/features/quests/screens/my_quests_screen.dart';
import 'package:canvas_app/features/community/screens/community_screen.dart';
import 'package:canvas_app/features/messages/screens/chats_screen.dart';
import 'package:canvas_app/features/messages/providers/dm_provider.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/features/settings/screens/settings_screen.dart';
import 'package:canvas_app/features/shell/widgets/animated_nav_bar.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:telegram_login/telegram_login.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yandex_login_sdk/yandex_login_sdk.dart';
import 'package:canvas_app/core/services/socket_service.dart';

import 'package:canvas_app/core/utils/error_text.dart';

Future<void> _syncAdultConsent(String token) async {
  final prefs = await SharedPreferences.getInstance();
  final adultConfirmed = prefs.getBool('adult_confirmed') ?? false;
  if (!adultConfirmed) return;
  try {
    await http.post(
      Uri.parse('${AppConfig.apiUrl}/profiles/me'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'show_nsfw': true}),
    );
  } catch (_) {
    // Не блокируем вход/старт, если синк не удался.
  }
}

class MenuScreen extends ConsumerStatefulWidget {
  const MenuScreen({super.key});

  @override
  ConsumerState<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends ConsumerState<MenuScreen> {
  /// Гостевые табы — порядок `screens` в `build()`: [Мои, Каталог, вход, Настройки].
  static const int _guestLibraryTab = 0;
  static const int _guestSignInTab = 2;

  int _currentIndex = 0;
  String? _currentUserId;
  bool _isLoadingAuth = true;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');
    final userId = prefs.getString('user_id');

    // Sync FCM token to backend when authenticated
    if (token != null && userId != null) {
      SocketService().init(token);
      // Догоняем возрастное согласие до профиля, если юзер уже был залогинен.
      unawaited(_syncAdultConsent(token));
      unawaited(
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            // refresh возвращает Future — провайдер сам ловит все ошибки
            // (fcm_token_provider.dart:23-47), поэтому результат не нужен.
            unawaited(ref.refresh(fcmTokenSyncProvider.future));
          }
        }),
      );
    }

    if (!mounted) return;

    setState(() {
      if (token != null && userId != null) {
        _currentUserId = userId;
        _currentIndex = 0; // Маркет для залогиненных
        ref.invalidate(userProfileProvider(userId));
      } else {
        _currentUserId = null;
        // Гостя сажаем по его же ответу с онбординга, а не на «Каталог»:
        // новичок, который шёл играть, должен упереться во вход, а тот, кто
        // пришёл смотреть, — в свои квесты.
        _currentIndex =
            prefs.getString(OnboardingService.kIntentKey) ==
                OnboardingService.intentPlay
            ? _guestSignInTab
            : _guestLibraryTab;
      }
      _isLoadingAuth = false;
    });
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  /// Плитка «Ещё» в нижней панели (#150): разделы, которые в неё не влезли.
  /// [firstIndex] — экран, с которого началось сворачивание, чтобы тап вернул
  /// человека на настоящий таб, а не на позицию в списке.
  void _showHiddenSections(List<NavBarItem> hidden, {required int firstIndex}) {
    showAdaptiveSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, item) in hidden.indexed)
              ListTile(
                leading: Icon(item.icon),
                title: Text(item.label),
                trailing: _currentIndex == firstIndex + i
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  _onTabTapped(firstIndex + i);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Alt+цифра переключает вкладку — как вкладки браузера. Верхний ряд цифр,
  /// не numpad: он ближе к левой руке и не конфликтует с вводом.
  static const List<LogicalKeyboardKey> _tabKeys = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  void _onLoginSuccess() {
    _checkSession();
    // Сессия сменилась — гостевые заглушки и кэши прежнего владельца должны
    // уехать целиком (тот же список, что при выходе), иначе профиль нового
    // человека до перезапуска живёт чужими данными.
    reloadAccountScopedProviders(ref.invalidate);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_isLoadingAuth) {
      return Scaffold(
        backgroundColor: scheme.surface,
        body: Center(child: CircularProgressIndicator(color: scheme.primary)),
      );
    }

    final bool isLoggedIn = _currentUserId != null;

    final List<Widget> screens;
    final List<NavBarItem> items;

    if (isLoggedIn) {
      // Бейдж «Чатов» смотрим здесь, а не внутри вкладки: лента переписок
      // должна жить, даже когда человек сидит в другом табе.
      final unreadChats = ref.watch(dmUnreadCountProvider);
      screens = [
        MarketScreen(isRoot: true),
        CommunityScreen(),
        ChatsScreen(),
        MyQuestsScreen(isRoot: true),
        ProfileScreen(userId: _currentUserId!),
        SettingsScreen(),
      ];
      items = [
        NavBarItem(
          icon: Icons.explore_outlined,
          selectedIcon: Icons.explore_rounded,
          label: tr('Каталог'),
        ),
        NavBarItem(
          icon: Icons.public_outlined,
          selectedIcon: Icons.public_rounded,
          label: tr('Сообщество'),
        ),
        NavBarItem(
          icon: Icons.forum_outlined,
          selectedIcon: Icons.forum_rounded,
          label: tr('Чаты'),
          badge: unreadChats > 0 ? unreadChats : null,
        ),
        NavBarItem(
          icon: Icons.auto_stories_outlined,
          selectedIcon: Icons.auto_stories_rounded,
          label: tr('Мои'),
        ),
        NavBarItem(
          icon: Icons.person_outline_rounded,
          selectedIcon: Icons.person_rounded,
          label: tr('Профиль'),
        ),
        NavBarItem(
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings_rounded,
          label: tr('Настройки'),
        ),
      ];
    } else {
      screens = [
        MyQuestsScreen(isRoot: true),
        MarketScreen(isRoot: true),
        AuthPlaceholderScreen(
          onLoginSuccess: _onLoginSuccess,
          onBrowseAsGuest: () => _onTabTapped(_guestLibraryTab),
        ),
        SettingsScreen(),
      ];
      // Каталог и страницы квестов открыты без аккаунта; вход нужен только
      // на действия — лайки, оценки, отзывы.
      items = [
        NavBarItem(
          icon: Icons.auto_stories_outlined,
          selectedIcon: Icons.auto_stories_rounded,
          label: tr('Мои'),
        ),
        NavBarItem(
          icon: Icons.explore_outlined,
          selectedIcon: Icons.explore_rounded,
          label: tr('Каталог'),
        ),
        // Под третьим табом у гостя не профиль, а форма входа — новичок,
        // которого развилка послала «пройти квест», читает в названии «Вход»,
        // а не «Профиль», которого у него ещё нет.
        NavBarItem(
          icon: Icons.login_rounded,
          selectedIcon: Icons.login_rounded,
          label: tr('Вход'),
        ),
        NavBarItem(
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings_rounded,
          label: tr('Настройки'),
        ),
      ];
    }

    final safeIndex = _currentIndex >= screens.length ? 0 : _currentIndex;

    // Узкая панель: семь безымянных иконок в ряд — уже не навигация, а
    // угадайка (#150). Оставляем четыре верхнеуровневых раздела, остальное
    // открывается списком по плитке «Ещё»; на десктопе рельса вмещает всё.
    final fold = foldNavBarTiles(items);
    final hiddenHere =
        fold.hidden.isNotEmpty && safeIndex >= fold.visible.length;
    final barItems = [
      ...fold.visible,
      if (fold.hidden.isNotEmpty)
        NavBarItem(
          // Пока человек сидит на скрытом разделе, плитка называется его
          // именем: «Ещё» при открытом скрытом разделе врёт.
          icon: Icons.more_horiz_rounded,
          selectedIcon: Icons.more_horiz_rounded,
          label: hiddenHere ? items[safeIndex].label : tr('Ещё'),
        ),
    ];

    final pages = IndexedStack(index: safeIndex, children: screens);
    final wide = isDesktopWidth(context);

    return CallbackShortcuts(
      // Alt+1…9 — переключение вкладок с клавиатуры, как в браузере.
      // Биндинг нужен только на десктопе, и он отдаёт ключ дальше, когда
      // индекса не существует.
      bindings: wide
          ? {
              for (var i = 0; i < items.length && i < _tabKeys.length; i++)
                SingleActivator(_tabKeys[i], alt: true): () => _onTabTapped(i),
            }
          : const {},
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: wide
            ? Row(
                children: [
                  DesktopNavRail(
                    items: items,
                    currentIndex: safeIndex,
                    onTap: _onTabTapped,
                  ),
                  VerticalDivider(
                    width: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                  Expanded(child: pages),
                ],
              )
            : pages,
        bottomNavigationBar: wide
            ? null
            : AnimatedNavBar(
                items: barItems,
                currentIndex: hiddenHere ? fold.visible.length : safeIndex,
                onTap: (i) {
                  if (i < fold.visible.length) {
                    _onTabTapped(i);
                  } else {
                    _showHiddenSections(
                      fold.hidden,
                      firstIndex: fold.visible.length,
                    );
                  }
                },
              ),
      ),
    );
  }
}

class AuthPlaceholderScreen extends StatefulWidget {
  final VoidCallback onLoginSuccess;

  /// «Продолжить без аккаунта»: гостя отправляем в его же «Мои», а не в тупик.
  final VoidCallback? onBrowseAsGuest;

  const AuthPlaceholderScreen({
    super.key,
    required this.onLoginSuccess,
    this.onBrowseAsGuest,
  });

  @override
  State<AuthPlaceholderScreen> createState() => _AuthPlaceholderScreenState();
}

class _AuthPlaceholderScreenState extends State<AuthPlaceholderScreen> {
  // Публичные client id: дефолты уже в OAuthConfig, .env нужен только для
  // переопределения. Секрет desktop-клиента необязателен: без него код
  // обменивает наш сервер.
  static String get _desktopClientId => OAuthConfig.googleDesktopClientId;
  static String get _desktopClientSecret =>
      OAuthConfig.googleDesktopClientSecret;

  static String get _yandexClientId => OAuthConfig.yandexClientId;
  // Telegram: Custom Scheme meander:// — без зависимости от App Link tg.dev
  // и без веб-редиректа.
  static String get _telegramClientId => OAuthConfig.telegramClientId;
  static const String _telegramRedirectUri = 'meander://tg-auth';

  bool _isSigningIn = false;
  String? _signingInProvider; // 'google' | 'yandex' | 'telegram'

  Future<void> _handleSignIn() async {
    final bool isDesktop = !kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final bool googleConfigured = isDesktop
        ? OAuthConfig.googleDesktopClientId.isNotEmpty
        : OAuthConfig.googleMobileServerClientId.isNotEmpty;
    if (!googleConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Google-вход недоступен в этой сборке.'),
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
      return;
    }
    setState(() {
      _isSigningIn = true;
      _signingInProvider = 'google';
    });

    try {
      if (isDesktop) {
        await _signInWithGoogleDesktop();
      } else {
        await _signInWithGoogleMobile();
      }
    } on GoogleSignInException catch (e) {
      // canceled - юзер закрыл окно, тихо выходим
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_mapSignInError(e)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_mapSignInError(error)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
          _signingInProvider = null;
        });
      }
    }
  }

  Future<void> _handleYandexSignIn() async {
    // Desktop пока не поддержан yandex_login_sdk
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Вход через Яндекс на компьютере пока не поддержан. Используйте Google.'),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    if (_yandexClientId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Yandex Login ещё не настроен (нужен clientId из oauth.yandex.ru).'),
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
      return;
    }
    setState(() {
      _isSigningIn = true;
      _signingInProvider = 'yandex';
    });
    try {
      final result = await YandexLoginSdk.signIn(clientId: _yandexClientId);
      await _authenticateWithBackendYandex(result.token);
    } on YandexAuthCancelledException {
      // тихо
      return;
    } on YandexAuthInProgressException {
      return;
    } on YandexAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_mapYandexError(e)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_mapSignInError(error)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
          _signingInProvider = null;
        });
      }
    }
  }

  String _mapYandexError(YandexAuthException e) {
    final msg = e.toString().toLowerCase();
    if (e is YandexAuthCancelledException) {
      return tr('Вход отменён');
    }
    if (msg.contains('popup_blocked')) {
      return tr(
        'Браузер заблокировал всплывающее окно. Разрешите всплывающие окна.',
      );
    }
    if (msg.contains('unsupported')) {
      return tr(
        'Яндекс-вход не поддержан на этом устройстве. Попробуйте Google.',
      );
    }
    return trf('Ошибка Яндекс-входа: {p0}', {'p0': friendlyError(e)});
  }

  Future<void> _handleTelegramSignIn() async {
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    if (isDesktop || kIsWeb) {
      return; // на ПК не показываем кнопку — сюда не попадём
    }
    if (_telegramClientId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Telegram-вход не настроен'),
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
      return;
    }
    setState(() {
      _isSigningIn = true;
      _signingInProvider = 'telegram';
    });
    try {
      final telegramLogin = TelegramLogin();
      await telegramLogin.configure(
        TelegramLoginConfiguration(
          clientId: _telegramClientId,
          redirectUri: _telegramRedirectUri,
          scopes: const ['profile'],
          fallbackScheme: 'meander',
        ),
      );
      final result = await telegramLogin.login();
      await _authenticateWithBackendTelegram(result.idToken);
    } on TelegramLoginError catch (e) {
      if (e.code == TelegramLoginErrorCode.cancelled) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_mapTelegramError(e)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_mapSignInError(error)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
          _signingInProvider = null;
        });
      }
    }
  }

  String _mapTelegramError(TelegramLoginError e) {
    switch (e.code) {
      case TelegramLoginErrorCode.cancelled:
        return tr('Вход отменён');
      case TelegramLoginErrorCode.networkError:
        return tr('Нет связи с Telegram. Проверьте интернет.');
      case TelegramLoginErrorCode.notConfigured:
        return tr('Telegram-вход не настроен');
      case TelegramLoginErrorCode.serverError:
        return trf(
          'Ошибка сервера Telegram ({p0})',
          {'p0': e.statusCode ?? ''},
        );
      default:
        return trf(
          'Ошибка Telegram-входа: {p0}',
          {'p0': e.message ?? e.code.name},
        );
    }
  }

  /// Apple отдаёт email и fullName только при первой авторизации, поэтому вместе
  /// с токеном на сервер уходит и raw-nonce: бэкенд сверяет SHA-256 от него с
  /// полем `nonce` identity токена. Без этой проверки пересланный токен дал бы
  /// вход в чужой аккаунт.
  Future<void> _handleAppleSignIn() async {
    setState(() {
      _isSigningIn = true;
      _signingInProvider = 'apple';
    });

    try {
      final rawNonce = generateAppleNonce();
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashAppleNonce(rawNonce),
      );

      final identityToken = credential.identityToken;
      if (identityToken == null) {
        throw Exception(tr('Apple не вернул identity token'));
      }
      await _authenticateWithBackendApple(
        idToken: identityToken,
        rawNonce: rawNonce,
        firstName: credential.givenName,
        lastName: credential.familyName,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка Apple-входа: {p0}', {'p0': e.message})),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } on SignInWithAppleNotSupportedException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Sign in with Apple не поддержан на этом устройстве.')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_mapSignInError(error)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
          _signingInProvider = null;
        });
      }
    }
  }

  String _mapSignInError(Object error) {
    if (error is GoogleSignInException) {
      final details =
          '${error.code} ${error.description ?? ''} ${error.details ?? ''}'
              .toLowerCase();
      if (error.code == GoogleSignInExceptionCode.canceled) {
        return tr('Вход отменён');
      }
      // MIUI/HyperOS + CredentialManager специфично: часто нет GMS,
      // устаревший GMS, или режет HiddenActivity
      if (details.contains('developer_error') ||
          details.contains('10') ||
          details.contains('providerconfigurationerror') ||
          details.contains('no provider') ||
          details.contains('no credential')) {
        return tr(
          'Сервис Google входа недоступен на этом устройстве. Обновите Google Play Services и попробуйте ещё раз.',
        );
      }
      return trf(
        'Ошибка входа: {p0}',
        {'p0': error.description ?? error.code},
      );
    }
    if (error is PlatformException && error.code == 'sign_in_failed') {
      final details = '${error.message ?? ''} ${error.details ?? ''}'
          .toLowerCase();
      if (details.contains('10') || details.contains('developer_error')) {
        return tr(
          'Google Sign-In code 10: проверь package + SHA-1/SHA-256 в OAuth Android client.',
        );
      }
    }
    final msg = error.toString().toLowerCase();
    if (msg.contains('socketexception') ||
        msg.contains('clientexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('connection')) {
      return tr('Нет связи с сервером. Проверьте интернет и попробуйте снова.');
    }
    if (msg.contains('500') || msg.contains('502') || msg.contains('503')) {
      return tr('Сервер временно недоступен. Попробуйте позже.');
    }
    return trf('Ошибка входа: {p0}', {'p0': friendlyError(error)});
  }

  static bool _googleSignInInitialized = false;

  Future<void> _signInWithGoogleMobile() async {
    final GoogleSignIn googleSignIn = GoogleSignIn.instance;
    if (!_googleSignInInitialized) {
      await googleSignIn.initialize(
        serverClientId: OAuthConfig.googleMobileServerClientId,
      );
      _googleSignInInitialized = true;
    }
    // Best-effort signOut перед входом — игнорим ошибки (MIUI/GMS может кинуть)
    try {
      await googleSignIn.signOut();
    } catch (_) {}

    // На MIUI/HyperOS HiddenActivity иногда зависает - ставим таймаут
    // чтобы UI не вис вечно, юзер получит понятную ошибку.
    final GoogleSignInAccount googleUser = await googleSignIn
        .authenticate()
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException(
            tr('Google Sign-In не ответил (MIUI может блокировать окно входа)'),
          ),
        );

    final String? idToken = googleUser.authentication.idToken;
    if (idToken == null) throw Exception(tr('Google не выдал idToken.'));

    await _authenticateWithBackend(idToken);
  }

  Future<void> _signInWithGoogleDesktop() async {
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final int port = server.port;
      final String redirectUri = 'http://localhost:$port';
      // PKCE: verifier живёт только в памяти этого запуска, в браузер уходит
      // его S256-хеш. state отсекает редирект от чужой сессии браузера.
      final String verifier = generatePkceVerifier();
      final String challenge = pkceChallenge(verifier);
      final String state = generateOAuthState();
      final String authUrl =
          'https://accounts.google.com/o/oauth2/v2/auth'
          '?response_type=code'
          '&client_id=$_desktopClientId'
          '&redirect_uri=$redirectUri'
          '&scope=openid%20email%20profile'
          '&code_challenge=$challenge'
          '&code_challenge_method=S256'
          '&state=$state';

      if (await canLaunchUrl(Uri.parse(authUrl))) {
        await launchUrl(
          Uri.parse(authUrl),
          mode: LaunchMode.externalApplication,
        );
      } else {
        throw Exception(tr('Не удалось открыть браузер.'));
      }

      String? authCode;
      await for (var request in server) {
        final query = request.uri.queryParameters;
        if (query['state'] != state) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          continue;
        }
        final code = query['code'];
        if (code == null && query['error'] == null) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        authCode = code;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(
            '<html><body style="background-color:#121212;color:white;text-align:center;font-family:sans-serif;margin-top:100px;"><h1>${tr('Вход выполнен!')}</h1><script>window.close();</script></body></html>',
          );
        await request.response.close();
        break;
      }

      if (authCode == null) throw Exception(tr('Не получен код авторизации.'));

      final String idToken;
      if (_desktopClientSecret.isNotEmpty) {
        // Секрет задан при сборке — можно обменять код напрямую, без нашего
        // бэкенда (полезно для самосборок).
        final tokenResponse = await http.post(
          Uri.parse('https://oauth2.googleapis.com/token'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'code': authCode,
            'client_id': _desktopClientId,
            'client_secret': _desktopClientSecret,
            'code_verifier': verifier,
            'redirect_uri': redirectUri,
            'grant_type': 'authorization_code',
          },
        );

        if (tokenResponse.statusCode != 200) {
          throw Exception(tr('Ошибка обмена токена.'));
        }
        final tokenData = jsonDecode(tokenResponse.body);
        idToken = tokenData['id_token'];
      } else {
        // Секрета в сборке нет: код и PKCE-verifier меняет наш сервер, у
        // которого секрет есть. Так сборка не требует локальных ключей.
        final exchangeResponse = await http.post(
          Uri.parse('${AppConfig.apiUrl}/auth/google/exchange'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'code': authCode,
            'clientId': _desktopClientId,
            'codeVerifier': verifier,
            'redirectUri': redirectUri,
          }),
        );
        if (exchangeResponse.statusCode != 200) {
          throw Exception(
            trf('Сервер не завершил вход: {p0}', {
              'p0': exchangeResponse.statusCode,
            }),
          );
        }
        final data = jsonDecode(utf8.decode(exchangeResponse.bodyBytes));
        final value = data['idToken'];
        if (value is! String || value.isEmpty) {
          throw Exception(tr('Сервер не выдал idToken.'));
        }
        idToken = value;
      }

      await _authenticateWithBackend(idToken);
    } finally {
      await server?.close();
    }
  }

  Future<void> _authenticateWithBackend(String idToken) async {
    final response = await http.post(
      Uri.parse('${AppConfig.apiUrl}/auth/google/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'idToken': idToken}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final String appToken = data['token'];
      final String userId = data['user']['id'];

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jwt_token', appToken);
      await prefs.setString('user_id', userId);

      // Синхронизируем возрастное согласие с профилем (18+ контент).
      await _syncAdultConsent(appToken);

      SocketService().init(appToken);

      widget.onLoginSuccess();
    } else {
      throw Exception(trf('Ошибка сервера: {p0}', {'p0': response.statusCode}));
    }
  }

  Future<void> _authenticateWithBackendYandex(String yandexToken) async {
    final response = await http.post(
      Uri.parse('${AppConfig.apiUrl}/auth/yandex/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'yandexToken': yandexToken}),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final String appToken = data['token'];
      final String userId = data['user']['id'];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jwt_token', appToken);
      await prefs.setString('user_id', userId);
      await _syncAdultConsent(appToken);
      SocketService().init(appToken);
      widget.onLoginSuccess();
    } else if (response.statusCode == 401) {
      throw Exception(tr('Неверный токен Яндекса'));
    } else {
      throw Exception(trf('Ошибка сервера: {p0}', {'p0': response.statusCode}));
    }
  }

  Future<void> _authenticateWithBackendTelegram(String idToken) async {
    final response = await http.post(
      Uri.parse('${AppConfig.apiUrl}/auth/telegram/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'telegramIdToken': idToken}),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final String appToken = data['token'];
      final String userId = data['user']['id'];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jwt_token', appToken);
      await prefs.setString('user_id', userId);
      await _syncAdultConsent(appToken);
      SocketService().init(appToken);
      widget.onLoginSuccess();
    } else if (response.statusCode == 401) {
      throw Exception(tr('Неверный токен Telegram'));
    } else {
      throw Exception(trf('Ошибка сервера: {p0}', {'p0': response.statusCode}));
    }
  }

  Future<void> _authenticateWithBackendApple({
    required String idToken,
    required String rawNonce,
    String? firstName,
    String? lastName,
  }) async {
    final response = await http.post(
      Uri.parse('${AppConfig.apiUrl}/auth/apple/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'idToken': idToken,
        'nonce': rawNonce,
        if (firstName != null && firstName.isNotEmpty) 'firstName': firstName,
        if (lastName != null && lastName.isNotEmpty) 'lastName': lastName,
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final String appToken = data['token'];
      final String userId = data['user']['id'];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jwt_token', appToken);
      await prefs.setString('user_id', userId);
      await _syncAdultConsent(appToken);
      SocketService().init(appToken);
      widget.onLoginSuccess();
    } else if (response.statusCode == 401) {
      throw Exception(tr('Неверный токен Apple'));
    } else {
      throw Exception(trf('Ошибка сервера: {p0}', {'p0': response.statusCode}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final showYandex = !isDesktop && !kIsWeb;
    // Guideline 4.8: раз приложение предлагает сторонние входы, вход по Apple ID
    // обязан быть доступен на iOS.
    final showApple = !kIsWeb && Platform.isIOS;
    final showTelegram =
        false; // временно скрыт — сервер остаётся, вернём позже

    return Scaffold(
      body: SafeArea(
        // Три кнопки входа вместе с текстами не влезают на маленьком телефоне
        // с крупным системным шрифтом: без прокрутки «Войти через Яндекс» и
        // выход «Продолжить без аккаунта» уезжают за нижний край.
        child: LayoutBuilder(
          builder: (context, viewport) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: viewport.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Hero-иконка в primary-pill
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                scheme.primaryContainer,
                                scheme.secondaryContainer,
                              ],
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.account_circle_rounded,
                            size: 72,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          tr('Войдите в аккаунт'),
                          textAlign: TextAlign.center,
                          style: textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          tr('Каталог квестов, публикации, облачные сохранения и социальные функции.'),
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 36),
                        if (showApple) ...[
                          SizedBox(
                            width: double.infinity,
                            child: SignInWithAppleButton(
                              onPressed: _isSigningIn ? null : _handleAppleSignIn,
                              text: tr('Войти через Apple'),
                              height: 56,
                              style: Theme.of(context).brightness == Brightness.dark
                                  ? SignInWithAppleButtonStyle.white
                                  : SignInWithAppleButtonStyle.black,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _isSigningIn ? null : _handleSignIn,
                            icon: _isSigningIn && _signingInProvider == 'google'
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.4,
                                      color: scheme.onPrimary,
                                    ),
                                  )
                                : const Icon(Icons.login_rounded),
                            label: Text(
                              _isSigningIn && _signingInProvider == 'google'
                                  ? tr('Входим…')
                                  : tr('Войти через Google'),
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                              textStyle: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        if (showYandex) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              onPressed: _isSigningIn ? null : _handleYandexSignIn,
                              icon: _isSigningIn && _signingInProvider == 'yandex'
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: scheme.onSecondaryContainer,
                                      ),
                                    )
                                  : const Icon(Icons.account_circle_rounded),
                              label: Text(
                                _isSigningIn && _signingInProvider == 'yandex'
                                    ? tr('Входим…')
                                    : tr('Войти через Яндекс'),
                              ),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(56),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                textStyle: textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (showTelegram) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              onPressed: _isSigningIn ? null : _handleTelegramSignIn,
                              icon: _isSigningIn && _signingInProvider == 'telegram'
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: scheme.onSecondaryContainer,
                                      ),
                                    )
                                  : const Icon(Icons.send_rounded),
                              label: Text(
                                _isSigningIn && _signingInProvider == 'telegram'
                                    ? tr('Входим…')
                                    : tr('Войти через Telegram'),
                              ),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(56),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                textStyle: textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          tr('Без аккаунта вы можете пользоваться библиотекой и академией.'),
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        // Развилка онбординга сажает новичка именно сюда, и без
                        // выхода это тупик: «войти или закрыть приложение».
                        if (widget.onBrowseAsGuest != null)
                          TextButton(
                            onPressed: widget.onBrowseAsGuest,
                            child: Text(tr('Продолжить без аккаунта')),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
