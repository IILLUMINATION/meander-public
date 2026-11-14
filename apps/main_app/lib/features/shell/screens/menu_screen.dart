import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/oauth_config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/onboarding_service.dart';
import 'package:canvas_app/core/services/session_service.dart';
import 'package:canvas_app/core/utils/apple_nonce.dart';
import 'package:canvas_app/features/app/screens/eula_screen.dart';
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
import 'package:canvas_app/core/services/google_browser_auth.dart';
import 'package:canvas_app/core/services/mirror_registry.dart';
import 'package:canvas_app/core/services/session_store.dart';
import 'package:telegram_login/telegram_login.dart';
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

  /// Вкладки, которые пользователь уже открывал. Остальные не монтируются:
  /// `IndexedStack` строит всех детей сразу, а каждый ребёнок в `initState`/
  /// `build` тянет свои данные (каталог, ленту, чаты, профиль, настройки с
  /// зондами зеркал). На старте это шесть деревьев и десяток запросов до
  /// первого кадра — при том что пользователь смотрит одну вкладку.
  final Set<int> _mountedTabs = <int>{};

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
      // Набор экранов между гостем и залогиненным разный — привязанные к
      // индексам вкладки пересобираем с нуля.
      _mountedTabs.clear();
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
    // Плитка «Чаты» нужна бейджу непрочитанных: индекс ищется по той же
    // ссылке, а не по числу, иначе при смене порядка вкладок бейдж уедет на
    // соседнюю кнопку.
    NavBarItem? chatsItem;

    if (isLoggedIn) {
      // Бейдж «Чатов» живёт в самой нижней панели (_ShellNavBar) и не
      // перестраивает отсюда все шесть вкладок: любое входящее сообщение
      // меняло счётчик и пересобирало весь shell целиком.
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
        chatsItem = NavBarItem(
          icon: Icons.forum_outlined,
          selectedIcon: Icons.forum_rounded,
          label: tr('Чаты'),
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

    // Индекс «Чатов» в узкой панели: у гостя плитки нет, а при сворачивании
    // она может уехать под «Ещё» — тогда бейджу там не место.
    final chats = chatsItem;
    final chatsRailIndex = chats == null ? null : items.indexOf(chats);
    final int? chatsTileIndex = chats == null
        ? null
        : () {
            final i = fold.visible.indexOf(chats);
            return i >= 0 ? i : null;
          }();

    // Открытая вкладка монтируется всегда; остальные — только после первого
    // визита (и дальше живут, чтобы не терять состояние и позицию скролла).
    _mountedTabs.add(safeIndex);

    final pages = IndexedStack(
      index: safeIndex,
      children: [
        for (var i = 0; i < screens.length; i++)
          // TickerMode гасит анимации скрытых вкладок: `IndexedStack` их не
          // останавливает, и шиммеры/спиннеры продолжают жечь кадры.
          TickerMode(
            enabled: i == safeIndex,
            child: _mountedTabs.contains(i)
                ? screens[i]
                : const SizedBox.shrink(),
          ),
      ],
    );
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
                  _ShellNavRail(
                    items: items,
                    unreadIndex: chatsRailIndex,
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
            : _ShellNavBar(
                items: barItems,
                unreadIndex: chatsTileIndex,
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

/// Нижняя панель, которая единственная подписана на счётчик непрочитанных.
///
/// Раньше `dmUnreadCountProvider` читался в `MenuScreen.build` — и каждое
/// входящее сообщение (сокет) пересобирало все шесть вкладок `IndexedStack`.
class _ShellNavBar extends ConsumerWidget {
  const _ShellNavBar({
    required this.items,
    required this.unreadIndex,
    required this.currentIndex,
    required this.onTap,
  });

  final List<NavBarItem> items;
  final int? unreadIndex;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AnimatedNavBar(
      items: withUnreadBadge(ref, items, unreadIndex),
      currentIndex: currentIndex,
      onTap: onTap,
    );
  }
}

/// Рельса десктопа: тот же бейдж, та же изоляция от `MenuScreen`.
class _ShellNavRail extends ConsumerWidget {
  const _ShellNavRail({
    required this.items,
    required this.unreadIndex,
    required this.currentIndex,
    required this.onTap,
  });

  final List<NavBarItem> items;
  final int? unreadIndex;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DesktopNavRail(
      items: withUnreadBadge(ref, items, unreadIndex),
      currentIndex: currentIndex,
      onTap: onTap,
    );
  }
}

/// Подставляет бейдж непрочитанных в плитку `index`.
///
/// `ref.watch` здесь — и только здесь: перестраивается панель, а не shell.
List<NavBarItem> withUnreadBadge(
  WidgetRef ref,
  List<NavBarItem> items,
  int? index,
) {
  if (index == null || index < 0 || index >= items.length) return items;
  final unread = ref.watch(dmUnreadCountProvider);
  if (unread <= 0) return items;
  final out = List<NavBarItem>.of(items);
  final item = out[index];
  out[index] = NavBarItem(
    icon: item.icon,
    selectedIcon: item.selectedIcon,
    label: item.label,
    badge: unread,
  );
  return out;
}

class _SignInAgreement extends StatelessWidget {
  final VoidCallback onOpenEula;

  const _SignInAgreement({required this.onOpenEula});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          tr('Регистрируясь или входя, вы принимаете'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: onOpenEula,
          child: Text(
            tr('Условия использования (EULA)'),
            style: TextStyle(
              color: scheme.primary,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary,
            ),
          ),
        ),
      ],
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
    final bool isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    // На телефоне браузерный фолбэк тоже считается рабочим входом: без него
    // устройства без Google Play Services остались бы без кнопки вовсе.
    final bool googleConfigured = isDesktop
        ? OAuthConfig.googleDesktopClientId.isNotEmpty
        : OAuthConfig.googleMobileServerClientId.isNotEmpty ||
              OAuthConfig.googleDesktopClientId.isNotEmpty;
    if (!googleConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Google-вход недоступен в этой сборке.')),
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
        await _signInWithGoogleBrowser();
      } else {
        await _signInWithGoogleMobileWithFallback();
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
              tr(
                'Вход через Яндекс на компьютере пока не поддержан. Используйте Google.',
              ),
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
              tr(
                'Yandex Login ещё не настроен (нужен clientId из oauth.yandex.ru).',
              ),
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
            content: Text(tr('Telegram-вход не настроен')),
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
        return trf('Ошибка сервера Telegram ({p0})', {
          'p0': e.statusCode ?? '',
        });
      default:
        return trf('Ошибка Telegram-входа: {p0}', {
          'p0': e.message ?? e.code.name,
        });
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
            content: Text(
              tr('Sign in with Apple не поддержан на этом устройстве.'),
            ),
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
    if (error is TimeoutException) {
      // Текст таймаута уже человеческий (натив окно не дал или вкладку
      // закрыли) — оборачивать его в «Ошибка входа» незачем.
      return error.message ?? tr('Вход не завершён');
    }
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
      return trf('Ошибка входа: {p0}', {'p0': error.description ?? error.code});
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

  /// Вход на телефоне: сначала нативный Google-вход, а если он невозможен —
  /// браузерный.
  ///
  /// На Huawei и других устройствах без Google Play Services нативного пути
  /// нет вообще: Credential Manager отвечает `providerConfigurationError`
  /// (или `unknownError` с developer_error/10). Раньше пользователь получал
  /// «обновите Play Services» и оставался без входа; браузерный флоу работает
  /// везде, где есть браузер и сеть.
  Future<void> _signInWithGoogleMobileWithFallback() async {
    try {
      await _signInWithGoogleMobile();
    } on GoogleSignInException catch (error) {
      if (!_isGoogleNativeUnavailable(error)) rethrow;
      await _signInWithGoogleBrowserFallback();
    } on TimeoutException {
      // Таймаут нативного окна — тот же случай: система не дала окно входа.
      await _signInWithGoogleBrowserFallback();
    } on MissingPluginException {
      await _signInWithGoogleBrowserFallback();
    } on UnsupportedError {
      await _signInWithGoogleBrowserFallback();
    }
  }

  Future<void> _signInWithGoogleBrowserFallback() async {
    if (_desktopClientId.isEmpty) {
      throw Exception(
        tr(
          'Сервис Google входа недоступен, а браузерный вход не настроен в этой сборке.',
        ),
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Google Play Services недоступны — входим через браузер.'),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
    await _signInWithGoogleBrowser();
  }

  /// Отказ именно из-за отсутствия/поломки сервиса Google, а не из-за
  /// действий пользователя и не из-за сети.
  static bool _isGoogleNativeUnavailable(GoogleSignInException error) {
    switch (error.code) {
      case GoogleSignInExceptionCode.canceled:
      case GoogleSignInExceptionCode.interrupted:
        return false;
      case GoogleSignInExceptionCode.providerConfigurationError:
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.uiUnavailable:
      case GoogleSignInExceptionCode.userMismatch:
        return true;
      case GoogleSignInExceptionCode.unknownError:
        final details =
            '${error.description ?? ''} ${error.details ?? ''}'.toLowerCase();
        return details.contains('developer_error') ||
            details.contains('no provider') ||
            details.contains('no credential') ||
            details.contains('10');
    }
  }

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

  /// Браузерный OAuth: loopback-сервер + PKCE + системный браузер.
  ///
  /// Работает и на телефоне: Chrome ходит на `localhost` того же устройства,
  /// а код меняет наш сервер (секрета в сборке нет). Это единственный путь
  /// входа на устройствах без Google Play Services.
  Future<void> _signInWithGoogleBrowser() async {
    final auth = GoogleBrowserAuth(
      clientId: _desktopClientId,
      exchangeCode: _desktopClientSecret.isNotEmpty
          // Секрет вшит в сборку — код меняем напрямую в Google.
          ? GoogleBrowserAuth.exchangeWithGoogle(
              clientId: _desktopClientId,
              clientSecret: _desktopClientSecret,
            )
          : GoogleBrowserAuth.exchangeWithBackend(
              apiUrl: AppConfig.apiUrl,
              clientId: _desktopClientId,
            ),
    );
    final idToken = await auth.signIn();
    await _authenticateWithBackend(idToken);
  }

  /// Сохранить сессию сервера, который её выдал.
  ///
  /// Токен приложения подписан `JWT_SECRET` этого бэкенда и на чужом
  /// сервере невалиден, поэтому кладётся в область доверия сервера
  /// ([MirrorRegistry.domainFor]): основной домен и встроенные зеркала —
  /// одна сессия, любой добавленный пользователем сервер — своя.
  Future<void> _saveSession(
    String baseUrl,
    String appToken,
    String userId,
  ) => SessionStore.save(
    domain: MirrorRegistry.domainFor(baseUrl),
    token: appToken,
    userId: userId,
  );

  Future<void> _authenticateWithBackend(String idToken) async {
    // Вход может быть первым сетевым действием сессии: проверяем зеркала
    // до запроса, чтобы не падать на заблокированном домене.
    await MirrorRegistry.instance.ensureReachable();
    final baseUrl = AppConfig.apiUrl;
    final response = await http.post(
      Uri.parse('$baseUrl/auth/google/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'idToken': idToken}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final String appToken = data['token'];
      final String userId = data['user']['id'];

      await _saveSession(baseUrl, appToken, userId);

      // Синхронизируем возрастное согласие с профилем (18+ контент).
      await _syncAdultConsent(appToken);

      SocketService().init(appToken);

      widget.onLoginSuccess();
    } else {
      throw Exception(trf('Ошибка сервера: {p0}', {'p0': response.statusCode}));
    }
  }

  Future<void> _authenticateWithBackendYandex(String yandexToken) async {
    await MirrorRegistry.instance.ensureReachable();
    final baseUrl = AppConfig.apiUrl;
    final response = await http.post(
      Uri.parse('$baseUrl/auth/yandex/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'yandexToken': yandexToken}),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final String appToken = data['token'];
      final String userId = data['user']['id'];
      await _saveSession(baseUrl, appToken, userId);
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
    await MirrorRegistry.instance.ensureReachable();
    final baseUrl = AppConfig.apiUrl;
    final response = await http.post(
      Uri.parse('$baseUrl/auth/telegram/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'telegramIdToken': idToken}),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final String appToken = data['token'];
      final String userId = data['user']['id'];
      await _saveSession(baseUrl, appToken, userId);
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
    await MirrorRegistry.instance.ensureReachable();
    final baseUrl = AppConfig.apiUrl;
    final response = await http.post(
      Uri.parse('$baseUrl/auth/apple/token'),
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
      await _saveSession(baseUrl, appToken, userId);
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
                          tr(
                            'Каталог квестов, публикации, облачные сохранения и социальные функции.',
                          ),
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _SignInAgreement(
                          onOpenEula: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => EulaScreen()),
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (showApple) ...[
                          SizedBox(
                            width: double.infinity,
                            child: SignInWithAppleButton(
                              onPressed: _isSigningIn
                                  ? null
                                  : _handleAppleSignIn,
                              text: tr('Войти через Apple'),
                              height: 56,
                              style:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
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
                              onPressed: _isSigningIn
                                  ? null
                                  : _handleYandexSignIn,
                              icon:
                                  _isSigningIn && _signingInProvider == 'yandex'
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
                              onPressed: _isSigningIn
                                  ? null
                                  : _handleTelegramSignIn,
                              icon:
                                  _isSigningIn &&
                                      _signingInProvider == 'telegram'
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
                          tr(
                            'Без аккаунта вы можете пользоваться библиотекой и академией.',
                          ),
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
