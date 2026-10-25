import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/playtime_service.dart';
import 'package:canvas_app/core/services/session_service.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/utils/playtime_formatter.dart';
import 'package:canvas_app/features/forums/screens/forum_lobby_screen.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:canvas_app/features/profile/providers/notifications_provider.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/profile/providers/author_notifs_provider.dart';
import 'package:canvas_app/features/profile/screens/avatar_editor_screen.dart';
import 'package:canvas_app/features/profile/screens/my_publications_screen.dart';
import 'package:canvas_app/features/profile/screens/play_history_screen.dart';
import 'package:canvas_app/features/profile/screens/rewards_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_repository.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_screen.dart';
import 'package:canvas_app/features/profile/widgets/banner_and_socials.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/features/profile/widgets/profile_widgets.dart';
import 'package:canvas_app/features/shell/screens/admin_screen.dart';
import 'package:canvas_app/features/shell/screens/menu_screen.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:canvas_app/features/community/screens/post_comments_screen.dart';
import 'package:canvas_app/providers/wall_provider.dart';
import 'package:canvas_app/features/wall/providers/wall_paginated_provider.dart';
import 'package:canvas_app/features/wall/widgets/post_composer.dart';
import 'package:canvas_app/features/wall/widgets/post_card.dart';
import 'package:canvas_app/models/user_profile_model.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/providers/dm_provider.dart';
import 'package:canvas_app/features/messages/screens/chat_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';
import 'package:canvas_app/features/asset_market/providers/asset_provider.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/shared/widgets/load_more_error_tile.dart';

// ============================================================================
//  ПРОФИЛЬ — Material 3 редизайн
//  На ПК (width >= 1000): центрированная двухколоночная раскладка —
//  колонка контента (до 780 px) + боковая панель (372 px).
// ============================================================================

const double kProfileDesktopBreakpoint = 1000;
const double kProfileSidebarWidth = 372;
const double kProfileContentMaxWidth = 780;
const double kProfileDesktopGap = 24;
const double kProfileDesktopTotalWidth =
    kProfileContentMaxWidth + kProfileDesktopGap + kProfileSidebarWidth;

/// Steam-подобная «Игровая история»: во что и сколько играл. Вход есть и в
/// своём профиле (кнопка и плитки с временем), и в чужом — по тапу на плитку
/// «Время в квестах», поэтому helper держим тут.
void _openPlayHistory(
  BuildContext context, {
  String? userId,
  String? ownerName,
}) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) =>
          PlayHistoryScreen(userId: userId, ownerName: ownerName),
    ),
  );
}

/// Награды за активность. Тот же вход, что у истории игр: только у хозяина
/// профиля есть смысл смотреть свой прогресс.
void _openRewards(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => RewardsScreen()),
  );
}

class ProfileScreen extends ConsumerStatefulWidget {
  final String userId;
  const ProfileScreen({super.key, required this.userId});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  String? _currentUserId;
  bool _isUserLoaded = false;
  bool _isFollowLoading = false;
  bool _showArchivedNotifications = false;

  /// Уведомления, которые этот просмотр уже отправил в архив: VisibilityDetector
  /// вызывается на каждую смену видимости, без множества один и тот же id
  /// улетал бы на сервер при каждом скролле.
  final Set<String> _autoArchivedIds = {};
  bool _unreadBadgeRefreshQueued = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _loadCurrentUser();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(userPublicationsProvider(widget.userId));
      ref.invalidate(userReviewsProvider(widget.userId));
      ref.invalidate(userAchievementsProvider(widget.userId));
      ref.invalidate(userProfileProvider(widget.userId));
      ref.invalidate(isFollowingProvider(widget.userId));
      ref.invalidate(authorAssetsProvider(widget.userId));
      // Настройки уведомлений об авторе: если первая попытка в приложении
      // упала (сети не было, токен ещё не поднялся), профиль не должен до
      // конца работы показывать дефолт — при открытии пробуем ещё раз.
      ref.read(authorNotifsSettingsProvider.notifier).retryIfFailed();
      // Загружаем посты стены
      ref.read(wallPaginatedProvider(widget.userId).notifier).loadPosts();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Автоархив просмотренного уведомления. После успешного POST обязательен
  /// рефетч счётчика: колокольчик считает неархивированные, и без него число
  /// висело бы старым до ручного pull-to-refresh.
  Future<void> _autoArchiveNotification(String id) async {
    if (!_autoArchivedIds.add(id)) return;
    try {
      await ref.read(apiServiceProvider).post('notifications/$id/archive');
      _scheduleUnreadBadgeRefresh();
    } catch (_) {
      // Не получилось — при следующем просмотре пробуем заново.
      _autoArchivedIds.remove(id);
    }
  }

  /// Пачка видимых уведомлений архивируется подряд; post-frame колбэк
  /// схлопывает их в одну пересборку счётчика вместо N запросов.
  void _scheduleUnreadBadgeRefresh() {
    if (_unreadBadgeRefreshQueued) return;
    _unreadBadgeRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _unreadBadgeRefreshQueued = false;
      if (!mounted) return;
      ref.invalidate(unreadNotificationsCountProvider);
    });
  }

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final localId = prefs.getString('user_id');
    if (!mounted) return;
    _currentUserId = localId;
    _isUserLoaded = true;
    _syncTabLength();
    setState(() {});
  }

  void _openAdminPanel() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AdminScreen()),
    );
  }

  void _syncTabLength() {
    final isCurrentUser =
        _currentUserId != null && _currentUserId == widget.userId;
    final targetLength = isCurrentUser ? 6 : 5;
    if (_tabController.length == targetLength) return;
    final oldIndex = _tabController.index;
    _tabController.dispose();
    _tabController = TabController(length: targetLength, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _tabController.index = oldIndex >= targetLength
        ? targetLength - 1
        : oldIndex;
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final futures = <Future<dynamic>>[
      ref.refresh(userProfileProvider(widget.userId).future),
      ref.refresh(userPublicationsProvider(widget.userId).future),
      ref.refresh(userReviewsProvider(widget.userId).future),
      ref.refresh(userAchievementsProvider(widget.userId).future),
      ref.refresh(isFollowingProvider(widget.userId).future),
      ref.refresh(authorAssetsProvider(widget.userId).future),
    ];
    if (_currentUserId == widget.userId) {
      futures.add(ref.refresh(userNotificationsProvider(false).future));
      futures.add(ref.refresh(unreadNotificationsCountProvider.future));
      if (_showArchivedNotifications) {
        futures.add(ref.refresh(userNotificationsProvider(true).future));
      }
      // обновим стену тоже
      try {
        await ref
            .read(wallPaginatedProvider(widget.userId).notifier)
            .loadPosts();
      } catch (_) {}
    }
    try {
      await Future.wait(futures, eagerError: false);
    } catch (e) {
      // Сеть недоступна или сервер на обслуживании — провайдеры сами
      // выставят hasError, UI отреагирует. Молча поглощаем, чтобы
      // RefreshIndicator корректно завершил анимацию.
      if (mounted) {
        final msg = e.toString().contains('SERVER_MAINTENANCE')
            ? tr('Сервер временно недоступен')
            : tr('Нет подключения к интернету');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // --- Действия ---

  Future<void> _toggleFollow() async {
    if (_isFollowLoading) return;
    if (_currentUserId == null) {
      // Кнопка «Подписаться» на чужом профиле выглядит живой и у гостя, а
      // раньше её тап не делал буквально ничего.
      final hasAccount = await ensureAccount(
        context,
        why:
            tr('Подписки держатся на аккаунте — без него подписываться некому. Войдите на вкладке «Вход».'),
      );
      // Сервер узнаёт автора по токену, поэтому если токен всё же есть
      // (локальный user_id затерялся), подписку не режем.
      if (!hasAccount) return;
      if (!mounted) return;
    }
    setState(() => _isFollowLoading = true);
    try {
      await ref
          .read(apiServiceProvider)
          .post('profiles/${widget.userId}/follow');
      ref.invalidate(isFollowingProvider(widget.userId));
      ref.invalidate(userProfileProvider(widget.userId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
      }
    } finally {
      if (mounted) setState(() => _isFollowLoading = false);
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(tr('Выход')),
          content: Text(tr('Вы уверены, что хотите выйти из аккаунта?')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              child: Text(tr('Выйти')),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;
    if (!mounted) return;
    try {
      await endSession(context: context);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => MenuScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trf('Ошибка выхода: {p0}', {'p0': friendlyError(e)}))),
        );
      }
    }
  }

  void _shareProfile() {
    final baseUrl = AppConfig.vpsApiBaseUrl;
    final webUrl = '$baseUrl/share/profile/${widget.userId}';
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      Clipboard.setData(ClipboardData(text: webUrl));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Ссылка скопирована'))));
    } else {
      Share.share(webUrl);
    }
  }

  void _copyProfileId() {
    Clipboard.setData(ClipboardData(text: widget.userId));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('ID скопирован'))));
  }

  Future<void> _editName(String currentName) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Изменить имя')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('Новое имя')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != currentName) {
      try {
        await ref
            .read(apiServiceProvider)
            .post('profiles/me', body: {'full_name': newName});
        ref.invalidate(userProfileProvider(widget.userId));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
        }
      }
    }
  }

  Future<void> _editBio(String? currentBio) async {
    final controller = TextEditingController(text: currentBio ?? '');
    final newBio = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('О себе')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          maxLength: 280,
          decoration: InputDecoration(
            hintText: tr('Расскажите о себе…'),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (newBio != null && newBio != currentBio) {
      try {
        await ref
            .read(apiServiceProvider)
            .post('profiles/me', body: {'bio': newBio});
        ref.invalidate(userProfileProvider(widget.userId));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
        }
      }
    }
  }

  void _openCosmetics({CosmeticSlot? slot}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CosmeticsScreen(userId: widget.userId, initialSlot: slot),
      ),
    );
  }

  Future<void> _showRedeemSheet() async {
    final controller = TextEditingController();
    bool isRedeeming = false;
    await showAdaptiveSheet(
      context: context,
      scrollable: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return StatefulBuilder(
          builder: (ctx, setSheet) => Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              20 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.redeem_rounded, color: scheme.primary, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      tr('Активация промокода'),
                      style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: tr('Промокод'),
                    hintText: 'XXXX-XXXX-XXXX',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isRedeeming
                        ? null
                        : () async {
                            final code = controller.text.trim().toUpperCase();
                            if (code.isEmpty) return;
                            setSheet(() => isRedeeming = true);
                            try {
                              final message = await redeemPromoCode(
                                ref: ref,
                                userId: widget.userId,
                                code: code,
                              );
                              if (!ctx.mounted) return;
                              // Мессенджер берём до pop: вместе с шитом умрёт и
                              // его контекст, а показывать результат надо.
                              final messenger = ScaffoldMessenger.of(ctx);
                              Navigator.pop(ctx);
                              messenger.showSnackBar(
                                SnackBar(content: Text(message)),
                              );
                            } catch (e) {
                              if (!ctx.mounted) return;
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    serverErrorMessage(
                                      e,
                                      fallback: tr('Не удалось активировать код'),
                                    ),
                                  ),
                                ),
                              );
                            } finally {
                              if (ctx.mounted) {
                                setSheet(() => isRedeeming = false);
                              }
                            }
                          },
                    icon: isRedeeming
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onPrimary,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(tr('Активировать')),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- Build ---

  /// Индекс вкладки «Стена» (зависит от того, текущий ли это пользователь).
  /// Порядок: Игры(0), Стена(1), [Уведомления(2)], Отзывы, Ачивки.
  int get _wallTabIndex => 1;

  /// Обработчик скролла для пагинации стены (работает в едином скролле).
  bool _onScrollNotification(ScrollNotification notification) {
    if (_tabController.index != _wallTabIndex) return false;
    final metrics = notification.metrics;
    if (metrics.pixels >= metrics.maxScrollExtent - 240) {
      ref.read(wallPaginatedProvider(widget.userId).notifier).loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_isUserLoaded) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator(color: scheme.primary)),
      );
    }

    final profileAsync = ref.watch(userProfileProvider(widget.userId));
    final isCurrentUser = _currentUserId == widget.userId;

    return LayoutBuilder(
      builder: (context, constraints) {
        final showSidebar = constraints.maxWidth >= kProfileDesktopBreakpoint;

        return Scaffold(
          body: profileAsync.when(
        loading: () => const _ProfileShimmer(),
        error: (err, _) => _ErrorView(error: err, onRetry: _refresh),
        data: (profile) {
          if (_tabController.length != (isCurrentUser ? 6 : 5)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _syncTabLength();
            });
          }
          final isAdmin = isCurrentUser && profile.role == 'admin';

          final content = SafeArea(
            top: true,
            bottom: false,
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverToBoxAdapter(
                      child: _ProfileHeader(
                        profile: profile,
                        isCurrentUser: isCurrentUser,
                        isFollowLoading: _isFollowLoading,
                        onToggleFollow: _toggleFollow,
                        onEditName: () => _editName(profile.fullName),
                        onEditBio: () => _editBio(profile.bio),
                        onRedeem: _showRedeemSheet,
                        onPublications: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => MyPublicationsScreen(),
                          ),
                        ),
                        onShare: _shareProfile,
                        onCopyId: _copyProfileId,
                        onReport: () => showAppDialog(
                          context: context,
                          builder: (_) => ReportDialog(
                            reportedType: 'user',
                            reportedId: widget.userId,
                            reportedTitle: profile.fullName,
                          ),
                        ),
                        onLogout: _handleLogout,
                        onOpenAdmin: isAdmin ? _openAdminPanel : null,
                        onEditBanner: () => _openCosmetics(slot: CosmeticSlot.banner),
                        onEditSocials: () => showSocialLinksEditor(
                          context: context,
                          ref: ref,
                          userId: widget.userId,
                          current: profile.socialLinks,
                        ),
                        onEditAvatar: () =>
                            pickAndUploadAvatar(context, widget.userId),
                        compact: showSidebar,
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _TabBarDelegate(
                        TabBar(
                          controller: _tabController,
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          dividerColor: Colors.transparent,
                          indicatorSize: TabBarIndicatorSize.label,
                          labelColor: scheme.primary,
                          unselectedLabelColor: scheme.onSurfaceVariant,
                          labelStyle: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                          unselectedLabelStyle: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                          tabs: [
                            Tab(text: tr('Игры')),
                            Tab(text: tr('Стена')),
                            if (isCurrentUser)
                              Tab(
                                child: Consumer(
                                  builder: (_, ref, __) {
                                    final unread = ref
                                        .watch(unreadNotificationsCountProvider)
                                        .maybeWhen(
                                          data: (c) => c,
                                          orElse: () => 0,
                                        );
                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(tr('Уведомления')),
                                        if (unread > 0) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: scheme.error,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              unread > 99 ? '99+' : '$unread',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  },
                                ),
                              ),
                            Tab(text: tr('Отзывы')),
                            Tab(text: tr('Ачивки')),
                            Tab(text: tr('Ассеты')),
                          ],
                        ),
                        // `background` — роль, которую кастомная тема задаёт
                        // отдельно от `surface`; на закреплённой полоске табов
                        // она давала чужой цвет страницы.
                        background: scheme.surface,
                      ),
                    ),
                    // Контент активной вкладки как sliver'ы того же скролла.
                    ..._buildTabSlivers(profile, isCurrentUser),
                    // Нижний отступ под навбар.
                    const SliverToBoxAdapter(child: SizedBox(height: 96)),
                  ],
                ),
              ),
            ),
          );

          if (showSidebar) {
            return _ProfileDesktopLayout(profile, isCurrentUser, isAdmin, content);
          }
          return content;
        },
      ),
    );
  });
  }

  /// Десктоп: центрированная колонка контента + боковая панель.
  // ignore: non_constant_identifier_names
  Widget _ProfileDesktopLayout(
    UserProfile profile,
    bool isCurrentUser,
    bool isAdmin,
    Widget content,
  ) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kProfileDesktopTotalWidth),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: kProfileContentMaxWidth,
                  ),
                  child: content,
                ),
              ),
            ),
            const SizedBox(width: kProfileDesktopGap),
            SizedBox(
              width: kProfileSidebarWidth,
              child: _buildDesktopSidebar(profile, isCurrentUser, isAdmin),
            ),
          ],
        ),
      ),
    );
  }

  /// Боковая панель ПК: «Информация», «Статистика», «Действия».
  Widget _buildDesktopSidebar(
    UserProfile profile,
    bool isCurrentUser,
    bool isAdmin,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 20, bottom: 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DesktopStatsCard(
            profile: profile,
            isCurrentUser: isCurrentUser,
          ),
          const SizedBox(height: 14),
          _DesktopActionsCard(
            profile: profile,
            isCurrentUser: isCurrentUser,
            isAdmin: isAdmin,
            followButton: isCurrentUser
                ? null
                : _buildDesktopFollowButton(profile),
            onPublications: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => MyPublicationsScreen()),
            ),
            onRedeem: _showRedeemSheet,
            onCosmetics: () => _openCosmetics(slot: CosmeticSlot.banner),
            onOpenAdmin: isAdmin ? _openAdminPanel : null,
            onReport: () => showAppDialog(
              context: context,
              builder: (_) => ReportDialog(
                reportedType: 'user',
                reportedId: profile.id,
                reportedTitle: profile.fullName,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopFollowButton(UserProfile profile) {
    final scheme = Theme.of(context).colorScheme;
    final isFollowing = ref.watch(isFollowingProvider(profile.id));
    return isFollowing.when(
      data: (following) => following
          ? FilledButton.tonalIcon(
              onPressed: _isFollowLoading ? null : _toggleFollow,
              icon: _isFollowLoading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onSurface,
                      ),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(tr('Вы подписаны')),
            )
          : FilledButton.icon(
              onPressed: _isFollowLoading ? null : _toggleFollow,
              icon: _isFollowLoading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onPrimary,
                      ),
                    )
                  : const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: Text(tr('Подписаться')),
            ),
      loading: () => const FilledButton(
        onPressed: null,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, __) => FilledButton.tonalIcon(
        // POST /follow — переключатель, поэтому угадывать состояние нельзя.
        // Молча выключенная кнопка означала бы «подписки нет до перезахода в
        // профиль» при любой сетевой заминке: даём перечитать.
        onPressed: () => ref.invalidate(isFollowingProvider(profile.id)),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: Text(tr('Перечитать подписку')),
      ),
    );
  }

  /// Возвращает sliver'ы контента для текущей вкладки.
  ///
  /// Порядок вкладок:
  ///  - текущий пользователь: Игры(0), Стена(1), Уведомления(2), Отзывы(3), Ачивки(4), Ассеты(5)
  ///  - чужой профиль:        Игры(0), Стена(1), Отзывы(2), Ачивки(3), Ассеты(4)
  List<Widget> _buildTabSlivers(UserProfile profile, bool isCurrentUser) {
    final index = _tabController.index;
    if (index == 0) {
      return _PublicationsTabSliver.build(context, ref, widget.userId);
    }
    if (index == 1) {
      return _WallTabSliver.build(
        context: context,
        ref: ref,
        userId: widget.userId,
        isCurrentUser: isCurrentUser,
        profile: profile,
      );
    }
    if (isCurrentUser) {
      switch (index) {
        case 2:
          return _NotificationsTabSliver.build(
            context: context,
            ref: ref,
            showArchived: _showArchivedNotifications,
            onArchivedChanged: (v) =>
                setState(() => _showArchivedNotifications = v),
            onSeen: _autoArchiveNotification,
          );
        case 3:
          return _ReviewsTabSliver.build(context, ref, widget.userId);
        case 4:
          return _AchievementsTabSliver.build(context, ref, widget.userId);
        case 5:
          return _UserAssetsTabSliver.build(context, ref, widget.userId);
      }
    } else {
      switch (index) {
        case 2:
          return _ReviewsTabSliver.build(context, ref, widget.userId);
        case 3:
          return _AchievementsTabSliver.build(context, ref, widget.userId);
        case 4:
          return _UserAssetsTabSliver.build(context, ref, widget.userId);
      }
    }
    return const [SliverToBoxAdapter(child: SizedBox.shrink())];
  }
}

// ============================================================================
//  SLIVER-БИЛДЕРЫ ВКЛАДОК (единый скролл)
//  Каждый билдер возвращает список sliver'ов для встраивания в общий
//  CustomScrollView профиля — без собственных ScrollController/ScrollView.
// ============================================================================

/// Хелпер: центрированный загрузочный/пустой блок как один sliver.
Widget _tabMessageSliver(Widget child) {
  return SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 32),
      child: Center(child: child),
    ),
  );
}

class _WallTabSliver {
  static List<Widget> build({
    required BuildContext context,
    required WidgetRef ref,
    required String userId,
    required bool isCurrentUser,
    required UserProfile profile,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(wallPaginatedProvider(userId));
    final posts = state.posts;
    final showComposer = isCurrentUser;
    final hasComposer = showComposer ? 1 : 0;

    if (state.isLoading && posts.isEmpty) {
      return [
        _tabMessageSliver(CircularProgressIndicator(color: scheme.primary)),
      ];
    }
    if (state.error != null && posts.isEmpty) {
      return [
        _tabMessageSliver(
          ProfileEmptyState(
            icon: Icons.cloud_off_rounded,
            message: state.error!,
            action: FilledButton.icon(
              onPressed: () =>
                  ref.read(wallPaginatedProvider(userId).notifier).loadPosts(),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr('Повторить')),
            ),
          ),
        ),
      ];
    }
    if (posts.isEmpty && !showComposer) {
      return [
        _tabMessageSliver(
          ProfileEmptyState(
            icon: Icons.article_outlined,
            message: tr('Пусто'),
            hint: tr('Здесь пока нет постов'),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: 8),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (showComposer && i == 0) {
                return PostComposer(
                  authorId: userId,
                  authorAvatarUrl: profile.avatarUrl,
                  authorName: profile.fullName,
                  authorCosmetics: profile.cosmetics,
                );
              }
              final idx = i - hasComposer;
              if (posts.isEmpty && showComposer && idx == 0) {
                return ProfileEmptyState(
                  icon: Icons.article_outlined,
                  message: tr('Расскажите подписчикам что-то новое'),
                  hint: tr('Делитесь новостями, идеями или ссылками'),
                );
              }
              if (idx < posts.length) {
                return PostCard(post: posts[idx], isOwn: isCurrentUser);
              }
              if (!state.isLoadingMore && state.error != null) {
                // Первая страница на экране: ошибку «ещё» показываем хвостом,
                // иначе остановившаяся стена выглядит как «постов больше нет».
                return LoadMoreErrorTile(
                  onRetry: () => ref
                      .read(wallPaginatedProvider(userId).notifier)
                      .loadMore(),
                );
              }
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: CircularProgressIndicator(color: scheme.primary),
                ),
              );
            },
            childCount:
                posts.length +
                hasComposer +
                ((state.isLoadingMore || state.error != null) ? 1 : 0) +
                (posts.isEmpty && showComposer ? 1 : 0),
          ),
        ),
      ),
    ];
  }
}

class _PublicationsTabSliver {
  static List<Widget> build(
    BuildContext context,
    WidgetRef ref,
    String userId,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(userPublicationsProvider(userId));
    return async.when(
      loading: () => [
        _tabMessageSliver(CircularProgressIndicator(color: scheme.primary)),
      ],
      error: (e, _) => [
        _tabMessageSliver(
          ProfileEmptyState(
            icon: Icons.cloud_off_rounded,
            message: tr('Не удалось загрузить'),
            hint: e.toString(),
          ),
        ),
      ],
      data: (quests) {
        if (quests.isEmpty) {
          return [
            _tabMessageSliver(
              ProfileEmptyState(
                icon: Icons.apps_rounded,
                message: tr('Нет опубликованных квестов'),
                hint: tr('Опубликуйте свой первый квест'),
              ),
            ),
          ];
        }
        // Колонки адаптируются к ширине слайвера:
        // на ПК (780 px) — 3 колонки, на телефоне — 2 как раньше.
        return [
          SliverLayoutBuilder(
            builder: (context, constraints) => SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount:
                      constraints.crossAxisExtent >= 640 ? 3 : 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 14,
                  childAspectRatio: 0.7,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => ProfileQuestCard(quest: quests[i]),
                  childCount: quests.length,
                ),
              ),
            ),
          ),
        ];
      },
    );
  }
}

class _AchievementsTabSliver {
  static List<Widget> build(
    BuildContext context,
    WidgetRef ref,
    String userId,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(userAchievementsProvider(userId));
    return async.when(
      loading: () => [
        _tabMessageSliver(CircularProgressIndicator(color: scheme.primary)),
      ],
      error: (e, _) => [
        _tabMessageSliver(
          ProfileEmptyState(
            icon: Icons.cloud_off_rounded,
            message: tr('Не удалось загрузить'),
            hint: e.toString(),
          ),
        ),
      ],
      data: (achievements) {
        if (achievements.isEmpty) {
          return [
            _tabMessageSliver(
              ProfileEmptyState(
                icon: Icons.emoji_events_rounded,
                message: tr('Пока нет достижений'),
                hint: tr('Создавайте квесты и набирайте популярность'),
              ),
            ),
          ];
        }
        final sorted = List<UserAchievement>.from(achievements)
          ..sort(
            (a, b) => b.achievement.xpReward.compareTo(a.achievement.xpReward),
          );
        return [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                  child: ProfileAchievementCard(userAchievement: sorted[i]),
                ),
                childCount: sorted.length,
              ),
            ),
          ),
        ];
      },
    );
  }
}

class _ReviewsTabSliver {
  static List<Widget> build(
    BuildContext context,
    WidgetRef ref,
    String userId,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(userReviewsProvider(userId));
    return async.when(
      loading: () => [
        _tabMessageSliver(CircularProgressIndicator(color: scheme.primary)),
      ],
      error: (e, _) => [
        _tabMessageSliver(
          ProfileEmptyState(
            icon: Icons.cloud_off_rounded,
            message: tr('Не удалось загрузить'),
            hint: e.toString(),
          ),
        ),
      ],
      data: (reviews) {
        if (reviews.isEmpty) {
          return [
            _tabMessageSliver(
              ProfileEmptyState(
                icon: Icons.rate_review_rounded,
                message: tr('Пока нет отзывов'),
                hint: tr('Отзывы появятся после прохождения ваших квестов'),
              ),
            ),
          ];
        }
        return [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                  child: ProfileReviewCard(review: reviews[i]),
                ),
                childCount: reviews.length,
              ),
            ),
          ),
        ];
      },
    );
  }
}

class _UserAssetsTabSliver {
  static List<Widget> build(BuildContext context, WidgetRef ref, String userId) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(authorAssetsProvider(userId));
    return async.when(
      loading: () => [
        _tabMessageSliver(CircularProgressIndicator(color: scheme.primary)),
      ],
      error: (e, _) => [
        _tabMessageSliver(
          ProfileEmptyState(
            icon: Icons.cloud_off_rounded,
            message: tr('Не удалось загрузить ассеты'),
            hint: e.toString(),
          ),
        ),
      ],
      data: (assets) {
        if (assets.isEmpty) {
          return [
            _tabMessageSliver(
              ProfileEmptyState(
                icon: Icons.widgets_outlined,
                message: tr('Нет ассетов'),
                hint: tr('Пользователь пока ничего не загрузил в маркет'),
              ),
            ),
          ];
        }
        return [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.85,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final a = assets[i];
                  return Material(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text(a.title),
                            content: SingleChildScrollView(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                if (a.coverUrl != null)
                                  ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(a.coverUrl!, errorBuilder: (_, __, ___) => const Icon(Icons.image))),
                                const SizedBox(height: 8),
                                Text(trf('Тип: {p0}', {'p0': assetKindLabel(a.kind)})),
                                Text(trf('Лицензия: {p0}', {'p0': licenseLabel(a.license)})),
                                if (a.description != null && a.description!.trim().isNotEmpty) ...[const SizedBox(height: 8), Text(a.description!)],
                              ]),
                            ),
                            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Закрыть')))],
                          ),
                        );
                      },
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(
                          child: Builder(builder: (_) {
                            final preview = a.coverUrl ?? ((a.kind == 'background' || a.kind == 'image') ? a.downloadUrl : null);
                            if (preview != null) return Image.network(preview, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.widgets_rounded));
                            IconData icon;
                            switch (a.kind) {
                              case 'button_preset':
                                icon = Icons.smart_button_rounded;
                                break;
                              case 'background':
                                icon = Icons.wallpaper_rounded;
                                break;
                              case 'sfx':
                                icon = Icons.music_note_rounded;
                                break;
                              case 'font':
                                icon = Icons.text_fields_rounded;
                                break;
                              default:
                                icon = Icons.widgets_rounded;
                            }
                            return Container(color: scheme.secondaryContainer, child: Center(child: Icon(icon, size: 28)));
                          }),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                            Text(assetKindLabel(a.kind), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
                            Text(trf('Лиц: {p0}', {'p0': licenseLabel(a.license)}), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant.withOpacity(0.7))),
                          ]),
                        ),
                      ]),
                    ),
                  );
                },
                childCount: assets.length,
              ),
            ),
          ),
        ];
      },
    );
  }
}

class _NotificationsTabSliver {
  static List<Widget> build({
    required BuildContext context,
    required WidgetRef ref,
    required bool showArchived,
    required ValueChanged<bool> onArchivedChanged,
    required ValueChanged<String> onSeen,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(userNotificationsProvider(showArchived));

    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: false,
              label: Text(tr('Активные')),
              icon: Icon(Icons.notifications_active_rounded, size: 18),
            ),
            ButtonSegment(
              value: true,
              label: Text(tr('Архив')),
              icon: Icon(Icons.inventory_2_outlined, size: 18),
            ),
          ],
          selected: {showArchived},
          onSelectionChanged: (s) => onArchivedChanged(s.first),
        ),
      ),
    );

    return async.when(
      loading: () => [
        header,
        _tabMessageSliver(CircularProgressIndicator(color: scheme.primary)),
      ],
      error: (e, _) => [
        header,
        _tabMessageSliver(
          ProfileEmptyState(
            icon: Icons.cloud_off_rounded,
            message: tr('Не удалось загрузить'),
            hint: e.toString(),
          ),
        ),
      ],
      data: (items) {
        if (items.isEmpty) {
          return [
            header,
            _tabMessageSliver(
              ProfileEmptyState(
                icon: showArchived
                    ? Icons.inventory_2_outlined
                    : Icons.notifications_none_rounded,
                message: showArchived ? tr('Архив пуст') : tr('Нет новых уведомлений'),
                hint: showArchived
                    ? tr('Здесь будут хранится прочитанные уведомления')
                    : tr('Будут отображаться лайки, отзывы, подписки'),
              ),
            ),
          ];
        }
        return [
          header,
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((_, i) {
                final n = items[i];
                return Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                  child: VisibilityDetector(
                    key: Key('notif_${n.id}'),
                    onVisibilityChanged: (info) {
                      if (!n.isArchived && info.visibleFraction > 0.5) {
                        onSeen(n.id);
                      }
                    },
                    child: ProfileNotificationTile(
                      notification: n,
                      onTap: () async {
                        if (n.type.startsWith('wall_post_') && n.payload != null && n.payload!['postId'] != null) {
                          try {
                            final postId = n.payload!['postId'] as String;
                            final post = await ref.read(wallNotifierProvider.notifier).getPost(postId);
                            if (context.mounted) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => PostCommentsScreen(post: post),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(tr('Пост не найден или удалён'))),
                              );
                            }
                          }
                          return;
                        }

                        // Личное сообщение — не профиль и не квест: единственное
                        // место, где его можно прочитать, это окно переписки.
                        if (n.type == 'dm_message' || n.type == 'system_news') {
                          final peerId = n.type == 'system_news'
                              ? kSystemUserId
                              : n.actorId;
                          if (peerId != null && peerId.isNotEmpty) {
                            openChat(context, peerId);
                          }
                          return;
                        }

                        // Ограничение и снятый топик живут в сообществе: без
                        // адреса форума уведомление осталось бы текстом, который
                        // некуда тапнуть.
                        if (n.type == 'forum_ban' || n.type == 'forum_topic_removed') {
                          final slug = n.payload?['forum_slug']?.toString() ?? '';
                          if (slug.isNotEmpty) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ForumLobbyScreen(slug: slug),
                              ),
                            );
                          }
                          return;
                        }

                        if (n.questId != null && n.questId!.isNotEmpty) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  MarketQuestLoaderScreen(questId: n.questId!),
                            ),
                          );
                        } else if (n.actorId != null && n.actorId!.isNotEmpty) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ProfileScreen(userId: n.actorId!),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                );
              }, childCount: items.length),
            ),
          ),
        ];
      },
    );
  }
}

// ============================================================================
//  HEADER ПРОФИЛЯ — обложка + аватар + bio + stats
// ============================================================================

class _ProfileHeader extends ConsumerWidget {
  final UserProfile profile;
  final bool isCurrentUser;
  final bool isFollowLoading;
  final VoidCallback onToggleFollow;
  final VoidCallback onEditName;
  final VoidCallback onEditBio;
  final VoidCallback onRedeem;
  final VoidCallback onPublications;
  // НОВЫЕ обработчики, перенесённые из AppBar
  final VoidCallback onShare;
  final VoidCallback onCopyId;
  final VoidCallback onReport;
  final VoidCallback onLogout;
  final VoidCallback? onOpenAdmin;
  // Кастомизация и соцсети
  final VoidCallback onEditBanner;
  final VoidCallback onEditSocials;
  final VoidCallback onEditAvatar;
  // На десктопе — компактный режим: без stats/кнопок (они в боковой панели)
  final bool compact;

  const _ProfileHeader({
    required this.profile,
    required this.isCurrentUser,
    required this.isFollowLoading,
    required this.onToggleFollow,
    required this.onEditName,
    required this.onEditBio,
    required this.onRedeem,
    required this.onPublications,
    required this.onShare,
    required this.onCopyId,
    required this.onReport,
    required this.onLogout,
    required this.onOpenAdmin,
    required this.onEditBanner,
    required this.onEditSocials,
    required this.onEditAvatar,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isFollowing = ref.watch(isFollowingProvider(profile.id));
    final pubAsync = ref.watch(userPublicationsProvider(profile.id));
    final pubCount = pubAsync.maybeWhen(data: (q) => q.length, orElse: () => 0);

    // Косметика. `banner_style` остался в модели: у пользователей, выбиравших
    // фон до появления оформления, предмет живёт только там.
    final equipped = profile.cosmetics;
    final bannerDef =
        cosmeticById(equipped.banner) ??
        cosmeticById(profile.bannerStyle?.id);
    final frameDef = cosmeticById(equipped.avatarFrame);
    final nameDef = cosmeticById(equipped.nameStyle);
    final effectDef = cosmeticById(equipped.effect);
    final accentIcon = bannerDef?.banner.accentIcon;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero-обложка с аватаром (выбранный фон или косметика из каталога)
          CosmeticBanner(
            def: bannerDef,
            height: compact ? 208 : 160,
            // Столько же, на сколько аватар свисает вниз: иначе по камере на
            // аватаре физически нельзя попасть (см. CosmeticBanner.hitReserve).
            hitReserve: compact ? 44 : 38,
            overlayEffect: effectDef,
            fallbackGradient: profileBannerDecoration(
              context,
              style: profile.bannerStyle,
            ).gradient,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  right: -10,
                  top: -10,
                  child: accentIcon != null
                      ? Icon(
                          accentIcon,
                          size: 120,
                          color: Colors.white.withOpacity(0.10),
                        )
                      : Icon(
                          Icons.auto_awesome_rounded,
                          size: 120,
                          color: scheme.onPrimaryContainer.withOpacity(0.08),
                        ),
                ),

                // Левый верх: «Проверенный» бейдж
                if (profile.isVerified)
                  Positioned(
                    top: 14,
                    left: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.92),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.verified_rounded,
                            color: Color(0xFF1976D2),
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            tr('Проверенный'),
                            style: TextStyle(
                              color: Color(0xFF1A1A1A),
                              fontWeight: FontWeight.w700,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Правый верх: share / ⋮ / ✎ (только свой профиль)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Row(
                    children: [
                      if (isCurrentUser) ...[
                        _BannerCircleIconButton(
                          icon: Icons.brush_rounded,
                          tooltip: tr('Оформление профиля'),
                          onPressed: onEditBanner,
                        ),
                        const SizedBox(width: 6),
                      ],
                      _BannerCircleIconButton(
                        icon: Icons.share_rounded,
                        tooltip: tr('Поделиться'),
                        onPressed: onShare,
                      ),
                      const SizedBox(width: 6),
                      _BannerCircleMenuButton(
                        isCurrentUser: isCurrentUser,
                        userId: profile.id,
                        peer: DmPeer(
                          id: profile.id,
                          name: profile.fullName,
                          avatarUrl: profile.avatarUrl,
                          equipped: profile.cosmetics,
                          role: profile.role,
                          lastSeenAt: profile.lastSeenAt,
                        ),
                        onCopyId: onCopyId,
                        onReport: onReport,
                        onLogout: onLogout,
                      ),
                    ],
                  ),
                ),

                // Аватар «выезжает» вниз; рамка из каталога рисуется снаружи.
                Positioned(
                  left: 20,
                  bottom: 0,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CosmeticAvatar(
                        frame: frameDef,
                        radius: (compact ? 48 : 42) + 3,
                        avatarUrl: profile.avatarUrl,
                      ),
                      // Свой аватар ставит только хозяин профиля — кнопка прямо
                      // по кружку, чтобы её не искать в меню.
                      if (isCurrentUser)
                        Positioned(
                          right: 2,
                          bottom: 2,
                          child: _AvatarEditButton(onPressed: onEditAvatar),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Прежний зазор (52/46) уже включён в бокс обложки через hitReserve.
          const SizedBox(height: 8),

          // Имя
          Row(
            children: [
              Flexible(
                child: CosmeticNameText(
                  name: profile.fullName,
                  def: nameDef,
                  hero: true,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (profile.streakCount > 0) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: tr('Дней подряд в приложении'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🔥', style: TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        Text(
                          '${profile.streakCount}',
                          style: const TextStyle(
                            color: Colors.orange,
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (isCurrentUser)
                IconButton(
                  icon: Icon(
                    Icons.edit_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  tooltip: tr('Изменить имя'),
                  onPressed: onEditName,
                ),
            ],
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: [
              Text(
                trf('С нами с {p0}', {'p0': formatDayMonthYear(profile.createdAt)}),
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text('•', style: TextStyle(color: scheme.outlineVariant, fontSize: 10)),
              Text(
                formatLastSeen(profile.lastSeenAt),
                style: TextStyle(
                  color: profile.lastSeenAt != null && DateTime.now().difference(profile.lastSeenAt!).inMinutes < 5
                    ? const Color(0xFF00C853)
                    : scheme.onSurfaceVariant,
                  fontSize: 12.5,
                  fontWeight: profile.lastSeenAt != null && DateTime.now().difference(profile.lastSeenAt!).inMinutes < 5
                    ? FontWeight.w700
                    : FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Bio
          if (profile.bio != null && profile.bio!.isNotEmpty)
            GestureDetector(
              onTap: isCurrentUser ? onEditBio : null,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: MeanderEntityText(
                  data: profile.bio!,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ),
            )
          else if (isCurrentUser)
            OutlinedButton.icon(
              onPressed: onEditBio,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('Добавить описание')),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: scheme.outlineVariant),
                foregroundColor: scheme.onSurface,
              ),
            ),
          const SizedBox(height: 12),

          // Соцсети
          if (profile.socialLinks.isNotEmpty || isCurrentUser) ...[
            Row(
              children: [
                Expanded(child: SocialLinksRow(links: profile.socialLinks)),
                if (isCurrentUser)
                  IconButton(
                    icon: Icon(
                      profile.socialLinks.isEmpty
                          ? Icons.add_link_rounded
                          : Icons.edit_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    tooltip: profile.socialLinks.isEmpty
                        ? tr('Добавить соцсети')
                        : tr('Изменить соцсети'),
                    onPressed: onEditSocials,
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Кнопки действий
          if (!compact) ...[
            if (!isCurrentUser)
              Row(
                children: [
                  Expanded(
                    child: isFollowing.when(
                      data: (following) => following
                          ? FilledButton.tonalIcon(
                              onPressed: isFollowLoading ? null : onToggleFollow,
                              icon: isFollowLoading
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: scheme.onSurface,
                                      ),
                                    )
                                  : const Icon(Icons.check_rounded, size: 18),
                              label: Text(tr('Вы подписаны')),
                            )
                          : FilledButton.icon(
                              onPressed: isFollowLoading ? null : onToggleFollow,
                              icon: isFollowLoading
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: scheme.onPrimary,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.person_add_alt_1_rounded,
                                      size: 18,
                                    ),
                              label: Text(tr('Подписаться')),
                            ),
                      loading: () => const FilledButton(
                        onPressed: null,
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      error: (_, __) => FilledButton.tonalIcon(
                        onPressed: () =>
                            ref.invalidate(isFollowingProvider(profile.id)),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(tr('Перечитать подписку')),
                      ),
                    ),
                  ),
                  // Аккаунту команды пишут только админы из рассылки, поэтому
                  // в его профиле кнопка была бы обещанием, которое не сдержится.
                  if (profile.id != kSystemUserId) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => openChat(context, profile.id),
                        icon: const Icon(Icons.mail_outline_rounded, size: 18),
                        label: Text(tr('Написать')),
                      ),
                    ),
                  ],
                ],
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onPublications,
                      icon: const Icon(Icons.list_alt_rounded, size: 18),
                      label: Text(tr('Публикации')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onRedeem,
                      icon: const Icon(Icons.redeem_rounded, size: 18),
                      label: Text(tr('Промокод')),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _openRewards(context),
                  icon: const Icon(Icons.card_giftcard_rounded, size: 18),
                  label: Text(tr('Награды')),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onEditBanner,
                  icon: const Icon(Icons.auto_awesome_motion_rounded, size: 18),
                  label: Text(tr('Оформление профиля')),
                ),
              ),
              if (onOpenAdmin != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onOpenAdmin,
                    icon: const Icon(Icons.shield_rounded, size: 18),
                    label: Text(tr('Админ-панель')),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.errorContainer,
                      foregroundColor: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 14),

            // Stats
            Row(
              children: [
                ProfileStatTile(
                  icon: Icons.apps_rounded,
                  value: formatCompactCount(pubCount),
                  label: tr('Квесты'),
                ),
                const SizedBox(width: 8),
                ProfileStatTile(
                  icon: Icons.favorite_rounded,
                  value: formatCompactCount(profile.totalLikes),
                  label: tr('Лайки'),
                ),
                const SizedBox(width: 8),
                ProfileStatTile(
                  icon: Icons.people_alt_rounded,
                  value: formatCompactCount(profile.followersCount),
                  label: tr('Подписчики'),
                ),
                const SizedBox(width: 8),
                ProfileStatTile(
                  icon: Icons.subscriptions_rounded,
                  value: formatCompactCount(profile.followingCount),
                  label: tr('Подписки'),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            Consumer(
              builder: (context, childRef, _) {
                if (isCurrentUser) {
                  final questTime = PlaytimeFormatter.serverFirst(
                    profile.totalQuestsPlaytimeSeconds,
                    childRef.watch(localQuestPlaytimeProvider).valueOrNull ?? 0,
                  );
                  final appTime = PlaytimeFormatter.serverFirst(
                    profile.totalPlaytimeSeconds,
                    childRef.watch(localAppPlaytimeProvider).valueOrNull ?? 0,
                  );
                  return Column(
                    children: [
                      Row(
                        children: [
                          ProfileStatTile(
                            icon: Icons.timer_outlined,
                            value: PlaytimeFormatter.format(appTime),
                            label: tr('Время в Meander'),
                          ),
                          const SizedBox(width: 8),
                          ProfileStatTile(
                            icon: Icons.explore_outlined,
                            value: PlaytimeFormatter.format(questTime),
                            label: tr('Время в квестах'),
                            onTap: () => _openPlayHistory(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _LibraryEntryTile(
                        appSeconds: appTime,
                        questSeconds: questTime,
                        onTap: () => _openPlayHistory(context),
                      ),
                    ],
                  );
                }
                // For other users, use backend values
                final otherTime = profile.totalQuestsPlaytimeSeconds;
                return Column(
                  children: [
                    Row(
                      children: [
                        ProfileStatTile(
                          icon: Icons.timer_outlined,
                          value: PlaytimeFormatter.format(profile.totalPlaytimeSeconds),
                          label: tr('Время в Meander'),
                        ),
                        const SizedBox(width: 8),
                        ProfileStatTile(
                          icon: Icons.explore_outlined,
                          value: PlaytimeFormatter.format(otherTime),
                          label: tr('Время в квестах'),
                          // Чужая библиотека открыта так же, как своя: тап по
                          // времени ведёт на тот же экран, только про другого
                          // человека.
                          onTap: () => _openPlayHistory(
                            context,
                            userId: profile.id,
                            ownerName: profile.fullName,
                          ),
                        ),
                      ],
                    ),
                    // Пустую чужую библиотеку не рекламируем.
                    if (otherTime > 0) ...[
                      const SizedBox(height: 8),
                      _LibraryEntryTile(
                        appSeconds: profile.totalPlaytimeSeconds,
                        questSeconds: otherTime,
                        label: profile.fullName,
                        onTap: () => _openPlayHistory(
                          context,
                          userId: profile.id,
                          ownerName: profile.fullName,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),

          ],
        ],
      ),
    );
  }
}

// --- Кнопки поверх обложки ---

class _BannerCircleIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _BannerCircleIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withOpacity(0.32),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, color: Colors.white, size: 19),
          ),
        ),
      ),
    );
  }
}

/// Кнопка «сменить аватар» — маленькая камера на краю кружка.
class _AvatarEditButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _AvatarEditButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tr('Сменить аватар'),
      child: Material(
        color: scheme.primary,
        shape: const CircleBorder(
          side: BorderSide(color: Colors.black26, width: 1.5),
        ),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 26,
            height: 26,
            child: Icon(
              Icons.photo_camera_rounded,
              size: 14,
              color: scheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _BannerCircleMenuButton extends ConsumerWidget {
  final bool isCurrentUser;
  final String userId;
  final DmPeer peer;
  final VoidCallback onCopyId;
  final VoidCallback onReport;
  final VoidCallback onLogout;

  const _BannerCircleMenuButton({
    required this.isCurrentUser,
    required this.userId,
    required this.peer,
    required this.onCopyId,
    required this.onReport,
    required this.onLogout,
  });

  /// Apple 1.2 требует, чтобы человека можно было заблокировать прямо из его
  /// профиля, а не только из уже открытой переписки. Блокировка та же, что в
  /// чате: сервер скрывает переписку в обе стороны.
  Future<void> _toggleBlock(BuildContext context, WidgetRef ref) async {
    final blocks = ref.read(dmBlocksProvider);
    final blocked = blocks.any((p) => p.id == peer.id);

    final hasAccount = await ensureAccount(
      context,
      why: tr('Блокировки хранятся на аккаунте. Войдите на вкладке «Вход».'),
    );
    if (!hasAccount || !context.mounted) return;

    if (!blocked) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Заблокировать пользователя?')),
          content: Text(
            trf(
              '{p0} не сможет писать вам, а переписка с ним скроется. Разблокировать можно в любой момент.',
              {'p0': peer.name},
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Заблокировать пользователя')),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }

    final notifier = ref.read(dmBlocksProvider.notifier);
    final error = blocked
        ? await notifier.unblock(peer.id)
        : await notifier.block(peer);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ??
              (blocked
                  ? tr('Пользователь разблокирован')
                  : tr('Пользователь заблокирован')),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Смотрим состояние, а не только нотификатор: тогда переключение
    // уведомлений перерисовывает иконку, а ошибка сети не может выброситься
    // в сборку шапки (там был серый прямоугольник вместо баннера, #289).
    final notifs =
        ref.watch(authorNotifsSettingsProvider).valueOrNull ??
        AuthorNotifsSettings.unknown;
    final isMuted = notifs.isMuted(userId);
    final isBlocked = ref.watch(dmBlocksProvider).any((p) => p.id == userId);

    return Material(
      color: Colors.black.withOpacity(0.32),
      shape: const CircleBorder(),
      child: PopupMenuButton<String>(
        tooltip: tr('Меню'),
        icon: const Icon(
          Icons.more_vert_rounded,
          color: Colors.white,
          size: 19,
        ),
        padding: EdgeInsets.zero,
        iconSize: 19,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (v) async {
          switch (v) {
            case 'copy_id':
              onCopyId();
              break;
            case 'report':
              onReport();
              break;
            case 'block':
              await _toggleBlock(context, ref);
              break;
            case 'logout':
              onLogout();
              break;
            case 'toggle_notifs':
              // Список «не уведомлять» живёт на аккаунте: гостю переключать
              // некуда, и сервер его запрос отвергнет.
              if (!context.mounted) return;
              final hasAccount = await ensureAccount(
                context,
                why:
                    tr('Список «не уведомлять об авторе» держится на аккаунте. Войдите на вкладке «Вход».'),
              );
              if (!hasAccount) return;
              final saved = await ref
                  .read(authorNotifsSettingsProvider.notifier)
                  .toggleAuthor(userId);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    saved
                        ? (isMuted
                              ? tr('Уведомления включены')
                              : tr('Уведомления отключены'))
                        : tr('Не удалось изменить: нет соединения с сервером'),
                  ),
                ),
              );
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'copy_id',
            child: _ProfileMenuItemRow(
              icon: Icons.copy_rounded,
              label: tr('Скопировать ID'),
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (!isCurrentUser) ...[
            PopupMenuItem(
              value: 'toggle_notifs',
              child: _ProfileMenuItemRow(
                icon: isMuted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                label: isMuted
                    ? tr('Включить уведомления')
                    : tr('Отключить уведомления'),
                color: scheme.onSurfaceVariant,
              ),
            ),
            PopupMenuItem(
              value: 'block',
              child: _ProfileMenuItemRow(
                icon: isBlocked
                    ? Icons.lock_open_rounded
                    : Icons.block_outlined,
                label: isBlocked
                    ? tr('Разблокировать пользователя')
                    : tr('Заблокировать пользователя'),
                color: isBlocked ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
            PopupMenuItem(
              value: 'report',
              child: _ProfileMenuItemRow(
                icon: Icons.flag_outlined,
                label: tr('Пожаловаться'),
                color: scheme.error,
              ),
            ),
          ],
          if (isCurrentUser) ...[
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'logout',
              child: _ProfileMenuItemRow(
                icon: Icons.logout_rounded,
                label: tr('Выйти'),
                color: scheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Строка пункта меню шапки. Без `Expanded` подпись «Отключить уведомления»
/// переполняла узкое меню телефона на 68 px и уезжала за край под жёлтую
/// полосатую разметку.
class _ProfileMenuItemRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _ProfileMenuItemRow({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ============================================================================
//  БОКОВАЯ ПАНЕЛЬ ПК — только то, что в компактной шапке скрыто:
//  статистика + действия. Ничего не дублируем — имя/био/соцсети живут
//  в шапке профиля и на ПК, и на телефоне.
// ============================================================================

/// M3-секция боковой панели: карточка surfaceContainerLow с заголовком.
class _SideSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _SideSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Карточка «Статистика»: те же плитки, что в шапке на телефоне
/// (Квесты/Лайки/Подписчики/Подписки) + плейтайм на всю ширину.
class _DesktopStatsCard extends ConsumerWidget {
  final UserProfile profile;
  final bool isCurrentUser;

  const _DesktopStatsCard({
    required this.profile,
    required this.isCurrentUser,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final pubAsync = ref.watch(userPublicationsProvider(profile.id));
    final pubCount = pubAsync.maybeWhen(data: (q) => q.length, orElse: () => 0);

    return _SideSection(
      title: tr('Статистика'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _SideStatTile(
                  icon: Icons.apps_rounded,
                  value: formatCompactCount(pubCount),
                  label: tr('Квесты'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SideStatTile(
                  icon: Icons.favorite_rounded,
                  value: formatCompactCount(profile.totalLikes),
                  label: tr('Лайки'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SideStatTile(
                  icon: Icons.people_alt_rounded,
                  value: formatCompactCount(profile.followersCount),
                  label: tr('Подписчики'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SideStatTile(
                  icon: Icons.subscriptions_rounded,
                  value: formatCompactCount(profile.followingCount),
                  label: tr('Подписки'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                Icons.timer_outlined,
                size: 17,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('Время в Meander'),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                  ),
                ),
              ),
              _playtimeFor(profile, isCurrentUser, ref, scheme),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.explore_outlined,
                size: 17,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('Время в квестах'),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                  ),
                ),
              ),
              _questsPlaytimeFor(profile, isCurrentUser, ref, scheme),
            ],
          ),
        ],
      ),
    );
  }
}

/// Время в приложении: для текущего пользователя — серверное значение с
/// локальной подстраховкой, для чужих — только из профиля.
Widget _playtimeFor(
  UserProfile profile,
  bool isCurrentUser,
  WidgetRef ref,
  ColorScheme scheme,
) {
  final value = isCurrentUser
      ? PlaytimeFormatter.serverFirst(
          profile.totalPlaytimeSeconds,
          ref.watch(localAppPlaytimeProvider).valueOrNull ?? 0,
        )
      : profile.totalPlaytimeSeconds;
  return Text(
    PlaytimeFormatter.format(value),
    style: TextStyle(
      color: scheme.onSurface,
      fontSize: 13,
      fontWeight: FontWeight.w800,
    ),
  );
}

/// Время в квестах: тот же порядок, что у `_playtimeFor`.
Widget _questsPlaytimeFor(
  UserProfile profile,
  bool isCurrentUser,
  WidgetRef ref,
  ColorScheme scheme,
) {
  final value = isCurrentUser
      ? PlaytimeFormatter.serverFirst(
          profile.totalQuestsPlaytimeSeconds,
          ref.watch(localQuestPlaytimeProvider).valueOrNull ?? 0,
        )
      : profile.totalQuestsPlaytimeSeconds;
  return Text(
    PlaytimeFormatter.format(value),
    style: TextStyle(
      color: scheme.onSurface,
      fontSize: 13,
      fontWeight: FontWeight.w800,
    ),
  );
}

/// Явный вход в игровую библиотеку. Тап по плитке с временем найти легко,
/// но это неочевидно: до этого экрана вообще нельзя было дойти, не зная, что
/// он открывается именно по часам.
class _LibraryEntryTile extends StatelessWidget {
  const _LibraryEntryTile({
    required this.appSeconds,
    required this.questSeconds,
    required this.onTap,
    this.label,
  });

  final int appSeconds;
  final int questSeconds;
  final VoidCallback onTap;

  /// Чей это список, если смотрим не свой.
  final String? label;

  String _subtitle() {
    final questTime = PlaytimeFormatter.format(questSeconds);
    final appTime = PlaytimeFormatter.format(appSeconds);
    if (label == null) {
      return trf(
        'Во что и сколько играл · {p0} в квестах · {p1} в Meander',
        {'p0': questTime, 'p1': appTime},
      );
    }
    return trf(
      'Во что и сколько играл этого человека · {p0} в квестах · {p1} в Meander',
      {'p0': questTime, 'p1': appTime},
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                Icons.sports_esports_rounded,
                size: 22,
                color: scheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label == null ? tr('Игровая библиотека') : trf('Библиотека · {label}', {'label': label}),
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Карточка «Действия»: те же кнопки, что в шапке на телефоне.
class _DesktopActionsCard extends ConsumerWidget {
  final UserProfile profile;
  final bool isCurrentUser;
  final bool isAdmin;
  final Widget? followButton;
  final VoidCallback onPublications;
  final VoidCallback onRedeem;
  final VoidCallback onCosmetics;
  final VoidCallback? onOpenAdmin;
  final VoidCallback onReport;

  const _DesktopActionsCard({
    required this.profile,
    required this.isCurrentUser,
    required this.isAdmin,
    required this.followButton,
    required this.onPublications,
    required this.onRedeem,
    required this.onCosmetics,
    required this.onOpenAdmin,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[
      if (!isCurrentUser) ...[
        if (followButton != null) followButton!,
        const SizedBox(height: 8),
        if (profile.id != kSystemUserId) ...[
          OutlinedButton.icon(
            onPressed: () => openChat(context, profile.id),
            icon: const Icon(Icons.mail_outline_rounded, size: 18),
            label: Text(tr('Написать')),
          ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          onPressed: onReport,
          icon: const Icon(Icons.flag_outlined, size: 18),
          label: Text(tr('Пожаловаться')),
        ),
      ] else ...[
        FilledButton.tonalIcon(
          onPressed: onPublications,
          icon: const Icon(Icons.list_alt_rounded, size: 18),
          label: Text(tr('Мои публикации')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _openRewards(context),
          icon: const Icon(Icons.card_giftcard_rounded, size: 18),
          label: Text(tr('Награды')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onRedeem,
          icon: const Icon(Icons.redeem_rounded, size: 18),
          label: Text(tr('Активировать промокод')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onCosmetics,
          icon: const Icon(Icons.auto_awesome_motion_rounded, size: 18),
          label: Text(tr('Оформление профиля')),
        ),
        if (isAdmin) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: onOpenAdmin,
            icon: const Icon(Icons.shield_rounded, size: 18),
            label: Text(tr('Админ-панель')),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
          ),
        ],
      ],
    ];

    return _SideSection(
      title: tr('Действия'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

// --- Вспомогательные виджеты ---

/// Плитка статистики — ровно как ProfileStatTile в шапке (M3).
class _SideStatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _SideStatTile({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: scheme.primary, size: 22),
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  TAB DELEGATE
// ============================================================================

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  final Color background;

  _TabBarDelegate(this.tabBar, {required this.background});

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(color: background, child: tabBar);
  }

  @override
  bool shouldRebuild(_TabBarDelegate old) => false;
}

// ============================================================================
//  СОСТОЯНИЕ ЗАГРУЗКИ / ОШИБКИ
// ============================================================================

class _ProfileShimmer extends StatelessWidget {
  const _ProfileShimmer();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 140,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            const SizedBox(height: 46),
            Container(
              width: 200,
              height: 24,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: 140,
              height: 14,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              height: 64,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: List.generate(
                4,
                (i) => Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i < 3 ? 8 : 0),
                    child: Container(
                      height: 78,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            Center(child: CircularProgressIndicator(color: scheme.primary)),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMaintenance =
        error.toString().contains('SERVER_MAINTENANCE') ||
        error.toString().contains('SocketException') ||
        error.toString().contains('ClientException');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 72,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                isMaintenance
                    ? tr('Нет подключения к серверу.\nПопробуйте позже.')
                    : trf('Ошибка: {p0}', {'p0': friendlyError(error)}),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isMaintenance ? scheme.onSurfaceVariant : scheme.error,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(tr('Попробовать снова')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
