import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/utils/count_format.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/services/playtime_service.dart';
import 'package:canvas_app/core/utils/playtime_formatter.dart';
import 'package:canvas_app/core/utils/quest_genres.dart';
import 'package:canvas_app/features/analytics/screens/quest_analytics_screen.dart';
import 'package:canvas_app/features/forums/providers/forum_provider.dart';
import 'package:canvas_app/features/forums/screens/forum_lobby_screen.dart';
import 'package:canvas_app/features/market/providers/market_download_provider.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_repository.dart'
    show serverErrorMessage;
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:canvas_app/models/review_model.dart';
import 'package:canvas_app/models/vote_model.dart';
import 'package:canvas_app/features/market/providers/market_provider.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/features/market/providers/review_provider.dart';
import 'package:canvas_app/features/game/screens/load_game_screen.dart';
import 'package:canvas_app/features/shell/screens/menu_screen.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/catalog_shell.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

Widget _buildSafeCircleAvatar({
  required String? avatarUrl,
  required double radius,
  required Widget fallback,
  Color? backgroundColor,
  CosmeticDef? frame,
}) {
  return CosmeticAvatar(
    frame: frame,
    radius: radius,
    avatarUrl: avatarUrl,
    placeholderColor: backgroundColor,
    fallback: fallback,
  );
}

String _avatarInitial(String? name) {
  final trimmed = name?.trim();
  if (trimmed == null || trimmed.isEmpty) return '?';
  return trimmed.substring(0, 1);
}

// ... (MarketQuestLoaderScreen без изменений) ...
class MarketQuestLoaderScreen extends ConsumerWidget {
  final String questId;
  const MarketQuestLoaderScreen({super.key, required this.questId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final questAsync = ref.watch(marketQuestProvider(questId));
    return questAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (err, stack) => Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              trf('Ошибка: {p0}', {'p0': friendlyError(err)}),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      ),
      data: (quest) => QuestMarketDetailsScreen(quest: quest),
    );
  }
}

class QuestMarketDetailsScreen extends ConsumerStatefulWidget {
  final MarketQuest quest;
  const QuestMarketDetailsScreen({super.key, required this.quest});
  @override
  ConsumerState<QuestMarketDetailsScreen> createState() =>
      _QuestMarketDetailsScreenState();
}

class _QuestMarketDetailsScreenState
    extends ConsumerState<QuestMarketDetailsScreen> {
  late MarketQuest _currentQuest;

  bool _isQuestLocal = false;
  String? _localQuestId;
  String? _localQuestVersion;

  bool _isVoteProcessing = false;
  bool _isDeleting = false;
  String? _currentUserId;
  bool _isCurrentUserAdminFlag = false;
  bool _isAdminActionProcessing = false;

  @override
  void initState() {
    super.initState();
    _currentQuest = widget.quest;
    _loadCurrentUser();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findAndSetLocalQuest();
      _updateCurrentQuestData();
      _countView();
    });
  }

  /// «Страницу открыли». Без этого авторидиет только скачивания, а между
  /// «никто не видел» и «видели сто раз, но не скачали» — разница, которую
  /// хочется видеть. Ошибку глушим: счётчик не стоит красной заглушки.
  Future<void> _countView() async {
    try {
      await ref.read(apiServiceProvider).post('quests/${widget.quest.id}/view');
    } catch (_) {}
  }

  // ... (методы _loadCurrentUser, _findAndSetLocalQuest, _updateCurrentQuestData, _showReportDialog, _shareQuest без изменений) ...
  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final localId = prefs.getString('user_id');

    bool isAdmin = false;
    if (localId != null && localId.isNotEmpty) {
      try {
        final profile = await ref.read(userProfileProvider(localId).future);
        isAdmin = profile.role == 'admin';
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _currentUserId = localId;
        _isCurrentUserAdminFlag = isAdmin;
      });
    }
  }

  Future<void> _findAndSetLocalQuest() async {
    final localQuests = await ref.read(questsProvider.future);
    final existingQuest = localQuests.firstWhereOrNull(
      (q) => q.id == widget.quest.id || q.marketQuestId == widget.quest.id,
    );
    if (mounted) {
      setState(() {
        _isQuestLocal = existingQuest != null;
        _localQuestId = existingQuest?.id;
        _localQuestVersion = existingQuest?.version;
      });
    }
  }

  Future<void> _updateCurrentQuestData() async {
    try {
      final updatedQuest = await ref.refresh(
        marketQuestProvider(widget.quest.id).future,
      );

      ref.invalidate(userVoteProvider(widget.quest.id));
      ref.invalidate(userReviewProvider(widget.quest.id));

      if (mounted) {
        setState(() {
          _currentQuest = updatedQuest;
        });
      }
    } catch (e) {
      print("Update error: $e");
    }
  }

  void _showReportDialog(
    BuildContext context,
    String type,
    String id,
    String? title,
  ) {
    showAppDialog(
      context: context,
      builder: (context) => ReportDialog(
        reportedType: type,
        reportedId: id,
        reportedTitle: title,
      ),
    );
  }

  void _shareQuest() {
    final baseUrl = AppConfig.vpsApiBaseUrl;
    final webUrl = '$baseUrl/share/quest/${widget.quest.id}';
    final shareText = '${widget.quest.title}\n$webUrl';

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      Clipboard.setData(ClipboardData(text: shareText));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Ссылка скопирована в буфер обмена')),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      Share.share(shareText);
    }
  }

  /// Обсуждение квеста заводится первым обращением: карточка не должна знать,
  /// создан форум или нет, и не должна предлагать «создать» лишнюю кнопку.
  /// Непубликованный квест бэк объясняет сам — показываем его строку.
  Future<void> _openQuestForum() async {
    try {
      final forum = await openQuestForum(
        ref.read(apiServiceProvider),
        widget.quest.id,
      );
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ForumLobbyScreen(slug: forum.slug),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            serverErrorMessage(e, fallback: tr('Обсуждение пока недоступно')),
          ),
        ),
      );
    }
  }

  Future<void> _downloadAndImport() async {
    final dl = ref.read(marketDownloadProvider)[widget.quest.id];
    if (dl?.isRunning == true) return;

    // Скачивание свободное, в том числе для гостя: токен нужен только чтобы
    // сервер записал загрузку в статистику автора.
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token') ?? '';

    await ref
        .read(marketDownloadProvider.notifier)
        .startDownload(
          quest: widget.quest,
          token: token,
        );
  }

  void _showAuthRequiredDialog() {
    showAppDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Войдите в аккаунт')),
        content: Text(
          tr('Лайки, оценки и отзывы привязаны к аккаунту — так статистика авторов остаётся честной. Просмотр и скачивание доступны и без входа.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              // Контекст экрана, а не диалога: после pop маршрут окна уже не
              // жив, и `Navigator.of` по нему в debug бросает assertion.
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => MenuScreen()),
              );
            },
            child: Text(tr('Войти')),
          ),
        ],
      ),
    );
  }

  Future<void> _handleVote(bool isLikeVote) async {
    if (_isVoteProcessing) return;
    if (_currentUserId == null) {
      _showAuthRequiredDialog();
      return;
    }

    setState(() => _isVoteProcessing = true);
    try {
      final apiService = ref.read(apiServiceProvider);

      final currentVote = await ref.read(
        userVoteProvider(widget.quest.id).future,
      );
      final targetVoteType = isLikeVote ? VoteType.like : VoteType.dislike;

      if (currentVote.voteType == targetVoteType) {
        await apiService.post(
          'quests/${widget.quest.id}/vote',
          body: {'action': 'remove'},
        );
      } else {
        await apiService.post(
          'quests/${widget.quest.id}/vote',
          body: {'action': 'set', 'is_like': isLikeVote},
        );
      }

      ref.invalidate(userVoteProvider(widget.quest.id));
      ref.invalidate(marketQuestsProviderNew);
      ref.invalidate(marketQuestsProviderPopular);
      ref.invalidate(meanderRecommendsProvider);
      ref.invalidate(verifiedAuthorsQuestsProvider);

      await _updateCurrentQuestData();
    } catch (e) {
      print("Vote Error: $e");
    } finally {
      if (mounted) setState(() => _isVoteProcessing = false);
    }
  }

  Future<void> _deleteQuestFromServer({
    bool requireDoubleConfirm = false,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Удалить?')),
        content: Text(tr('Квест будет удален из магазина навсегда.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    if (!mounted) return;
    if (requireDoubleConfirm) {
      final secondConfirm = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Точно удалить?')),
          content: Text(
            tr('Это действие необратимо. Квест и связанные данные будут удалены.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              child: Text(tr('Удалить навсегда')),
            ),
          ],
        ),
      );
      if (secondConfirm != true) return;
    }

    setState(() => _isDeleting = true);
    try {
      await ref.read(apiServiceProvider).delete('quests/${widget.quest.id}');

      _invalidateMarketFeeds();

      if (_currentUserId != null) {
        ref.invalidate(userPublicationsProvider(_currentUserId!));
      }
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Квест удален')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trf('Ошибка удаления: {p0}', {'p0': friendlyError(e)}))),
        );
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  void _invalidateMarketFeeds() {
    ref.invalidate(marketQuestsProviderNew);
    ref.invalidate(marketQuestsProviderPopular);
    ref.invalidate(meanderRecommendsProvider);
    ref.invalidate(verifiedAuthorsQuestsProvider);
    ref.invalidate(demoQuestsProvider);
    ref.invalidate(marketRecentActivityProvider);
  }

  Future<void> _setAdminAction({
    required String action,
    required dynamic value,
    required String successText,
  }) async {
    if (_isAdminActionProcessing) return;
    setState(() => _isAdminActionProcessing = true);
    try {
      final api = ref.read(apiServiceProvider);
      // Единственный путь: quests/:id/admin/action — на проде маршрут есть
      // (401 без токена). Фоллбэки вели в несуществующие api/admin/… (404) и
      // в admin/quest/:id/review: тот же самый статус из другого места, так
      // что при настоящей ошибке админ получал бы ещё два запроса вдогонку.
      await api.post(
        'quests/${widget.quest.id}/admin/action',
        body: {'action': action, 'value': value},
      );
      _invalidateMarketFeeds();
      await _updateCurrentQuestData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(successText),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(trf('Админ-действие не выполнено: {p0}', {'p0': friendlyError(e)})),
        ),
      );
    } finally {
      if (mounted) setState(() => _isAdminActionProcessing = false);
    }
  }

  Future<void> _showAdminActionsSheet() async {
    final quest = _currentQuest;
    final scheme = Theme.of(context).colorScheme;
    final selected = await showAdaptiveSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.admin_panel_settings_rounded,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    tr('Админ-действия'),
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_rounded, color: scheme.error),
              title: Text(tr('Удалить квест')),
              subtitle: Text(tr('С двойным подтверждением')),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ListTile(
              leading: Icon(
                quest.isDemo ? Icons.unarchive_rounded : Icons.flaky_rounded,
                color: scheme.tertiary,
              ),
              title: Text(quest.isDemo ? tr('Убрать из демо') : tr('Перенести в демо')),
              onTap: () => Navigator.pop(ctx, 'toggle_demo'),
            ),
            ListTile(
              leading: Icon(
                quest.isBest
                    ? Icons.workspace_premium_outlined
                    : Icons.workspace_premium_rounded,
                color: const Color(0xFFFFB300),
              ),
              title: Text(
                quest.isBest
                    ? tr('Вернуть в общий каталог')
                    : tr('Сделать лучшим'),
              ),
              subtitle: Text(
                tr('Лучшие идут первыми и попадают в отдельную полку'),
              ),
              onTap: () => Navigator.pop(ctx, 'toggle_best'),
            ),
            ListTile(
              leading: Icon(
                quest.isNsfw ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                color: scheme.error,
              ),
              title: Text(quest.isNsfw ? tr('Убрать метку 18+') : tr('Пометить как 18+')),
              onTap: () => Navigator.pop(ctx, 'toggle_nsfw'),
            ),
            ListTile(
              leading: Icon(
                (quest.isFeatured ?? false)
                    ? Icons.star_border_rounded
                    : Icons.star_rounded,
                color: Colors.amber,
              ),
              title: Text(
                (quest.isFeatured ?? false)
                    ? tr('Убрать из рекомендаций')
                    : tr('Добавить в рекомендации'),
              ),
              onTap: () => Navigator.pop(ctx, 'toggle_featured'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.publish_rounded, color: scheme.primary),
              title: Text(tr('Статус: published')),
              onTap: () => Navigator.pop(ctx, 'status_published'),
            ),
            ListTile(
              leading: Icon(
                Icons.hourglass_top_rounded,
                color: scheme.secondary,
              ),
              title: Text(tr('Статус: in_review')),
              onTap: () => Navigator.pop(ctx, 'status_in_review'),
            ),
            ListTile(
              leading: Icon(Icons.block_rounded, color: scheme.error),
              title: Text(tr('Статус: rejected')),
              onTap: () => Navigator.pop(ctx, 'status_rejected'),
            ),
            const SizedBox(height: 8),
          ],
        ),
        ),
      ),
    );

    if (!mounted || selected == null) return;
    switch (selected) {
      case 'delete':
        await _deleteQuestFromServer(requireDoubleConfirm: true);
        return;
      case 'toggle_demo':
        await _setAdminAction(
          action: 'set_demo',
          value: !quest.isDemo,
          successText: !quest.isDemo
              ? tr('Квест перенесён в демо')
              : tr('Квест убран из демо'),
        );
        return;
      case 'toggle_best':
        await _setAdminAction(
          action: 'set_market_tier',
          value: quest.isBest ? kMarketTierModerated : kMarketTierBest,
          successText: quest.isBest
              ? tr('Квест вернулся в общий каталог')
              : tr('Квест стал лучшим'),
        );
        return;
      case 'toggle_nsfw':
        await _setAdminAction(
          action: 'set_nsfw',
          value: !quest.isNsfw,
          successText: !quest.isNsfw
              ? tr('Квест помечен как 18+')
              : tr('Метка 18+ снята'),
        );
        return;
      case 'toggle_featured':
        await _setAdminAction(
          action: 'set_featured',
          value: !(quest.isFeatured ?? false),
          successText: !(quest.isFeatured ?? false)
              ? tr('Квест добавлен в рекомендации')
              : tr('Квест убран из рекомендаций'),
        );
        return;
      case 'status_published':
        await _setAdminAction(
          action: 'set_status',
          value: 'published',
          successText: tr('Квест опубликован'),
        );
        return;
      case 'status_in_review':
        await _setAdminAction(
          action: 'set_status',
          value: 'in_review',
          successText: tr('Квест отправлен на модерацию'),
        );
        return;
      case 'status_rejected':
        await _setAdminAction(
          action: 'set_status',
          value: 'rejected',
          successText: tr('Квест отклонён'),
        );
        return;
    }
  }

  void _showReviewDialog() async {
    if (_currentUserId == null) {
      _showAuthRequiredDialog();
      return;
    }
    final userReviewData = await ref.read(
      userReviewProvider(widget.quest.id).future,
    );
    if (!mounted) return;
    showAdaptiveSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ReviewDialog(
        questId: widget.quest.id,
        initialRating: userReviewData.$1,
        initialText: userReviewData.$2,
        onSubmitted: () {
          ref.invalidate(reviewsProvider(widget.quest.id));
          ref.invalidate(userReviewProvider(widget.quest.id));
          _updateCurrentQuestData();
        },
      ),
    );
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '-';
    if (bytes < 1024 * 1024) {
      return trf('{p0} КБ', {'p0': (bytes / 1024).toStringAsFixed(1)});
    } else if (bytes < 1024 * 1024 * 1024) {
      return trf('{p0} МБ', {'p0': (bytes / (1024 * 1024)).toStringAsFixed(1)});
    } else {
      return trf('{p0} ГБ', {'p0': (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)});
    }
  }

  String _formatPlaytime(int? minutes) {
    if (minutes == null || minutes <= 0) return '-';
    if (minutes < 60) return trf('{p0} мин', {'p0': minutes});
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return trf('{p0}ч {p1}м', {'p0': h, 'p1': m});
  }

  String _normalizeVersionValue(String? value) => value?.trim() ?? '';

  List<int> _parseVersionSegments(String? value) {
    final normalized = _normalizeVersionValue(value);
    if (normalized.isEmpty) return const [];
    final matches = RegExp(r'\d+').allMatches(normalized);
    if (matches.isEmpty) return const [];
    return matches
        .map((match) => int.tryParse(match.group(0) ?? '') ?? 0)
        .toList();
  }

  int? _compareParsedVersions(String? localVersion, String? remoteVersion) {
    final localParts = _parseVersionSegments(localVersion);
    final remoteParts = _parseVersionSegments(remoteVersion);
    if (localParts.isEmpty || remoteParts.isEmpty) return null;

    final maxLen = localParts.length > remoteParts.length
        ? localParts.length
        : remoteParts.length;
    for (var i = 0; i < maxLen; i++) {
      final localValue = i < localParts.length ? localParts[i] : 0;
      final remoteValue = i < remoteParts.length ? remoteParts[i] : 0;
      if (localValue != remoteValue) {
        return localValue.compareTo(remoteValue);
      }
    }
    return 0;
  }

  bool _isVersionUpdateAvailable(String? localVersion, String? remoteVersion) {
    final localValue = _normalizeVersionValue(localVersion);
    final remoteValue = _normalizeVersionValue(remoteVersion);
    if (remoteValue.isEmpty) return false;
    if (localValue.isEmpty) return true;
    final parsedComparison = _compareParsedVersions(localValue, remoteValue);
    if (parsedComparison != null) {
      if (parsedComparison != 0) return parsedComparison < 0;
      return localValue != remoteValue;
    }
    return localValue != remoteValue;
  }

  // ---------------------------------------------------------------------------
  //  BUILD — Material 3
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final quest = _currentQuest;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isAuthor = _currentUserId != null && _currentUserId == quest.authorId;
    final userReviewAsync = ref.watch(userReviewProvider(quest.id));
    final userVoteAsync = ref.watch(userVoteProvider(quest.id));

    // Состояние загрузки из глобального провайдера
    final dlState = ref.watch(marketDownloadProvider)[widget.quest.id];
    final bool isDownloading = dlState?.isRunning ?? false;
    final double? downloadProgress = isDownloading ? dlState?.progress : null;
    final String dlStatus = dlState?.status ?? '';

    // Реагируем на завершение и ошибку загрузки
    ref.listen<Map<String, QuestDownloadState>>(marketDownloadProvider, (
      prev,
      next,
    ) {
      final prevDl = prev?[widget.quest.id];
      final nextDl = next[widget.quest.id];
      if (nextDl == null) return;

      // Завершение
      if (nextDl.isCompleted && prevDl?.isCompleted != true) {
        _findAndSetLocalQuest();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('Квест успешно установлен!')),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        ref
            .read(marketDownloadProvider.notifier)
            .clearDownload(widget.quest.id);
      }

      // Ошибка
      if (nextDl.hasFailed && prevDl?.hasFailed != true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(trf('Ошибка: {p0}', {'p0': nextDl.error})),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        ref
            .read(marketDownloadProvider.notifier)
            .clearDownload(widget.quest.id);
      }
    });

    final bool isUpdateAvailable =
        _isQuestLocal &&
        _isVersionUpdateAvailable(_localQuestVersion, quest.version);

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ────────────────────────────────────────────────────────────────
          //  HERO HEADER
          // ────────────────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            stretch: true,
            backgroundColor: scheme.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: CatalogGlassIconButton(
              icon: Icons.arrow_back_rounded,
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              CatalogGlassIconButton(
                icon: Icons.forum_outlined,
                tooltip: tr('Обсуждение квеста'),
                onPressed: _openQuestForum,
              ),
              CatalogGlassIconButton(
                icon: Icons.share_rounded,
                tooltip: tr('Поделиться'),
                onPressed: _shareQuest,
              ),
              if (isAuthor)
                CatalogGlassIconButton(
                  icon: Icons.insights_rounded,
                  tooltip: tr('Статистика квеста'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => QuestAnalyticsScreen(
                        questId: quest.id,
                        title: quest.title,
                      ),
                    ),
                  ),
                )
              else
                CatalogGlassIconButton(
                  icon: Icons.flag_outlined,
                  tooltip: tr('Пожаловаться'),
                  color: Colors.redAccent,
                  onPressed: () => _showReportDialog(
                    context,
                    'quest',
                    quest.id,
                    quest.title,
                  ),
                ),
              if (isAuthor)
                CatalogGlassIconButton(
                  icon: Icons.delete_forever_rounded,
                  tooltip: tr('Удалить квест'),
                  color: Colors.redAccent,
                  loading: _isDeleting,
                  onPressed: _isDeleting
                      ? null
                      : () => _deleteQuestFromServer(
                          requireDoubleConfirm: _isCurrentUserAdminFlag,
                        ),
                ),
              if (_isCurrentUserAdminFlag)
                CatalogGlassIconButton(
                  icon: Icons.admin_panel_settings_rounded,
                  tooltip: tr('Админ-действия'),
                  color: Colors.greenAccent,
                  loading: _isAdminActionProcessing,
                  onPressed: _isAdminActionProcessing
                      ? null
                      : _showAdminActionsSheet,
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [
                StretchMode.zoomBackground,
                StretchMode.blurBackground,
              ],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (quest.previewImageUrl != null &&
                      quest.previewImageUrl!.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: quest.previewImageUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: scheme.surfaceContainerHigh,
                        child: Icon(
                          Icons.broken_image_rounded,
                          color: scheme.onSurfaceVariant.withOpacity(0.4),
                          size: 64,
                        ),
                      ),
                    )
                  else
                    Container(
                      color: scheme.surfaceContainerHigh,
                      child: Icon(
                        Icons.broken_image_rounded,
                        color: scheme.onSurfaceVariant.withOpacity(0.4),
                        size: 64,
                      ),
                    ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          scheme.surface.withOpacity(0.6),
                          scheme.surface,
                        ],
                        stops: const [0.4, 0.8, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (quest.genres.isNotEmpty)
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: quest.genres
                                .map((g) => CatalogGenreChip(
                                      label: genreLabel(normalizeGenreId(g)),
                                    ))
                                .toList(),
                          )
                        else if (quest.category != null)
                          CatalogGenreChip(
                            label: genreLabel(normalizeGenreId(quest.category)),
                          ),
                        const SizedBox(height: 10),
                        Text(
                          quest.title,
                          style: textTheme.headlineMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            shadows: const [
                              Shadow(blurRadius: 12, color: Colors.black54),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        InkWell(
                          onTap: quest.authorId != null
                              ? () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ProfileScreen(userId: quest.authorId!),
                                  ),
                                )
                              : null,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.person_rounded,
                                size: 18,
                                color: quest.authorIsVerified
                                    ? Colors.lightBlueAccent
                                    : Colors.white70,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  quest.authorName ?? tr('Автор неизвестен'),
                                  style: textTheme.titleSmall?.copyWith(
                                    color: quest.authorIsVerified
                                        ? Colors.lightBlueAccent
                                        : Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (quest.authorIsVerified) ...[
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.verified_rounded,
                                  color: Colors.lightBlueAccent,
                                  size: 16,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.visibility_rounded,
                              size: 18,
                              color: Colors.white70,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${formatCount(quest.viewsCount)} '
                              '${trpMany(['просмотр', 'просмотра', 'просмотров'])}',
                              style: textTheme.labelLarge?.copyWith(
                                color: Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ────────────────────────────────────────────────────────────────
          //  BODY
          // ────────────────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),

                  // STAT BAR — 4 цветных плитки
                  Row(
                    children: [
                      Expanded(
                        child: CatalogStatTile(
                          value: quest.averageRating > 0
                              ? quest.averageRating.toStringAsFixed(1)
                              : '—',
                          label: tr('Рейтинг'),
                          icon: Icons.star_rounded,
                          container: Colors.amber.withOpacity(0.18),
                          onContainer: Colors.amber.shade700,
                          accent: Colors.amber,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CatalogStatTile(
                          value: _formatPlaytime(quest.estimatedPlaytime),
                          label: tr('Время'),
                          icon: Icons.timer_rounded,
                          container: scheme.secondaryContainer,
                          onContainer: scheme.onSecondaryContainer,
                          accent: scheme.secondary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CatalogStatTile(
                          value: _formatBytes(quest.questSizeBytes),
                          label: tr('Размер'),
                          icon: Icons.sd_storage_rounded,
                          container: scheme.tertiaryContainer,
                          onContainer: scheme.onTertiaryContainer,
                          accent: scheme.tertiary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CatalogStatTile(
                          value: '${quest.downloadsCount}',
                          label: tr('Загрузок'),
                          icon: Icons.download_rounded,
                          container: scheme.primaryContainer,
                          onContainer: scheme.onPrimaryContainer,
                          accent: scheme.primary,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // ── ACTION PANEL ─────────────────────────────────────
                  _ActionPanel(
                    quest: quest,
                    isDownloading: isDownloading,
                    downloadProgress: downloadProgress,
                    status: dlStatus,
                    isQuestLocal: _isQuestLocal,
                    isUpdateAvailable: isUpdateAvailable,
                    sizeBytes: quest.questSizeBytes,
                    onPrimaryAction: isDownloading
                        ? null
                        : (isUpdateAvailable
                              ? _downloadAndImport
                              : (_isQuestLocal
                                    ? () {
                                        if (_localQuestId != null) {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => LoadGameScreen(
                                                questId: _localQuestId!,
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    : _downloadAndImport)),
                    userVoteAsync: userVoteAsync,
                    onLike: () => _handleVote(true),
                    onDislike: () => _handleVote(false),
                  ),

                  Consumer(
                    builder: (context, childRef, _) {
                      return FutureBuilder<int>(
                        future: childRef.read(playtimeServiceProvider).getQuestPlaytime(quest.id),
                        builder: (context, snapshot) {
                          final playtime = snapshot.data ?? 0;
                          return Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: scheme.outlineVariant),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.timer_outlined, color: scheme.primary, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    tr('Ваше время в игре:'),
                                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                                  ),
                                  const Spacer(),
                                  Text(
                                    PlaytimeFormatter.format(playtime),
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),

                  // Вход в обсуждение квеста. Иконка в шапке теряется среди
                  // трёх таких же, а сообщество — единственное место, где
                  // человек может спросить автора и других игроков.
                  const SizedBox(height: 16),
                  Material(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _openQuestForum,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer.withValues(
                                  alpha: 0.5,
                                ),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                Icons.forum_rounded,
                                color: scheme.primary,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    tr('Сообщество квеста'),
                                    style: textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    tr('Вопросы автору, подсказки и идеи'),
                                    style: textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),
                  CatalogSectionLabel(text: tr('Об игре')),
                  const SizedBox(height: 10),
                  MeanderEntityText(
                    data: quest.description ?? tr('Описание отсутствует.'),
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      height: 1.6,
                    ),
                  ),

                  const SizedBox(height: 28),

                  _buildScreenshotsSection(quest.id),

                  const SizedBox(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      CatalogSectionLabel(
                        text:
                            trf('Оценки ({p0})', {'p0': quest.dislikeCount + quest.likeCount}),
                      ),
                      userReviewAsync.when(
                        data: (data) {
                          final hasReview = data.$1 > 0 || data.$2.isNotEmpty;
                          return TextButton.icon(
                            onPressed: _showReviewDialog,
                            icon: Icon(
                              hasReview
                                  ? Icons.edit_rounded
                                  : Icons.rate_review_outlined,
                              size: 18,
                            ),
                            label: Text(hasReview ? tr('Изменить') : tr('Написать')),
                          );
                        },
                        loading: () => const SizedBox.shrink(),
                        error: (_, __) => const SizedBox.shrink(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildReviewsList(quest.id),

                  const SizedBox(height: 60),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScreenshotsSection(String questId) {
    final scheme = Theme.of(context).colorScheme;
    final screenshotsAsync = ref.watch(screenshotsProvider(questId));
    return screenshotsAsync.when(
      data: (screens) {
        final visibleScreens = screens
            .where((s) => s.imageUrl.trim().isNotEmpty)
            .toList();
        if (visibleScreens.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CatalogSectionLabel(text: tr('Галерея')),
            const SizedBox(height: 10),
            SizedBox(
              height: 200,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: visibleScreens.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (ctx, i) => GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FullScreenImageViewer(
                        imageUrls: visibleScreens
                            .map((e) => e.imageUrl)
                            .toList(),
                        initialIndex: i,
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: CachedNetworkImage(
                      imageUrl: visibleScreens[i].imageUrl,
                      fit: BoxFit.cover,
                      width: 140,
                      placeholder: (_, __) =>
                          Container(color: scheme.surfaceContainerHigh),
                      errorWidget: (_, __, ___) => Container(
                        color: scheme.surfaceContainerHigh,
                        child: Icon(
                          Icons.broken_image_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const SizedBox(),
    );
  }

  Widget _buildReviewsList(String questId) {
    final scheme = Theme.of(context).colorScheme;
    final reviewsAsync = ref.watch(reviewsProvider(questId));
    return reviewsAsync.when(
      data: (reviews) {
        if (reviews.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                tr('Отзывов пока нет. Будьте первым!'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: reviews.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            return _ExpandableReviewCard(
              review: reviews[index],
              canReply:
                  _currentUserId != null &&
                  _currentUserId == widget.quest.authorId,
              onReplySubmitted: () {
                ref.invalidate(reviewsProvider(questId));
              },
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => Text(
        tr('Ошибка загрузки отзывов'),
        style: TextStyle(color: scheme.error),
      ),
    );
  }
}

// ============================================================================
//  ACTION PANEL — премиум-блок с CTA, лайками и прогрессом загрузки
// ============================================================================

class _ActionPanel extends StatelessWidget {
  final MarketQuest quest;
  final bool isDownloading;
  final double? downloadProgress;
  final String status;
  final bool isQuestLocal;
  final bool isUpdateAvailable;
  final int? sizeBytes;
  final VoidCallback? onPrimaryAction;
  final AsyncValue<UserVote> userVoteAsync;
  final VoidCallback onLike;
  final VoidCallback onDislike;

  const _ActionPanel({
    required this.quest,
    required this.isDownloading,
    required this.downloadProgress,
    required this.status,
    required this.isQuestLocal,
    required this.isUpdateAvailable,
    required this.sizeBytes,
    required this.onPrimaryAction,
    required this.userVoteAsync,
    required this.onLike,
    required this.onDislike,
  });

  static String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024 * 1024) {
      return trf('{p0} КБ', {'p0': (bytes / 1024).toStringAsFixed(1)});
    } else if (bytes < 1024 * 1024 * 1024) {
      return trf('{p0} МБ', {'p0': (bytes / (1024 * 1024)).toStringAsFixed(1)});
    } else {
      return trf('{p0} ГБ', {'p0': (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SizeTransition(
                sizeFactor: anim,
                axisAlignment: -1,
                child: child,
              ),
            ),
            child: isDownloading
                ? _DownloadingState(
                    key: const ValueKey('downloading'),
                    progress: downloadProgress,
                    status: status,
                    title: quest.title,
                    sizeBytes: sizeBytes,
                  )
                : _IdleState(
                    key: const ValueKey('idle'),
                    isUpdateAvailable: isUpdateAvailable,
                    isQuestLocal: isQuestLocal,
                    sizeBytes: sizeBytes,
                    version: quest.version,
                    onPressed: onPrimaryAction,
                  ),
          ),

          const SizedBox(height: 10),

          // лайк / дизлайк ряд
          Row(
            children: [
              Expanded(
                child: userVoteAsync.when(
                  data: (uv) => _VoteChip(
                    icon: Icons.thumb_up_rounded,
                    count: quest.likeCount,
                    active: uv.voteType == VoteType.like,
                    activeColor: scheme.primary,
                    activeOnColor: scheme.onPrimaryContainer,
                    activeContainer: scheme.primaryContainer,
                    onTap: onLike,
                  ),
                  loading: () => _VoteChipPlaceholder(scheme: scheme),
                  error: (_, __) => _VoteChipPlaceholder(scheme: scheme),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: userVoteAsync.when(
                  data: (uv) => _VoteChip(
                    icon: Icons.thumb_down_rounded,
                    count: quest.dislikeCount,
                    active: uv.voteType == VoteType.dislike,
                    activeColor: scheme.error,
                    activeOnColor: scheme.onErrorContainer,
                    activeContainer: scheme.errorContainer,
                    onTap: onDislike,
                  ),
                  loading: () => _VoteChipPlaceholder(scheme: scheme),
                  error: (_, __) => _VoteChipPlaceholder(scheme: scheme),
                ),
              ),
            ],
          ),

          if (isUpdateAvailable && !isDownloading) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: scheme.tertiary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    trf('Доступна новая версия: {p0}', {'p0': quest.version}),
                    style: textTheme.labelMedium?.copyWith(
                      color: scheme.tertiary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─ IDLE — основная кнопка действия ─────────────────────────────────────────

class _IdleState extends StatelessWidget {
  final bool isUpdateAvailable;
  final bool isQuestLocal;
  final int? sizeBytes;
  final String? version;
  final VoidCallback? onPressed;

  const _IdleState({
    super.key,
    required this.isUpdateAvailable,
    required this.isQuestLocal,
    required this.sizeBytes,
    required this.version,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final IconData icon;
    final String label;
    final String? sub;
    final Color bg;
    final Color fg;

    if (isUpdateAvailable) {
      icon = Icons.system_update_alt_rounded;
      label = tr('Обновить');
      sub = version != null ? 'v$version' : null;
      bg = scheme.tertiary;
      fg = scheme.onTertiary;
    } else if (isQuestLocal) {
      icon = Icons.play_arrow_rounded;
      label = tr('Играть');
      sub = tr('Установлено');
      bg = scheme.secondary;
      fg = scheme.onSecondary;
    } else {
      icon = Icons.download_rounded;
      label = tr('Скачать');
      sub = _ActionPanel._formatBytes(sizeBytes).isEmpty
          ? null
          : _ActionPanel._formatBytes(sizeBytes);
      bg = scheme.primary;
      fg = scheme.onPrimary;
    }

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 24),
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: textTheme.titleMedium?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                  if (sub != null)
                    Text(
                      sub,
                      style: textTheme.labelSmall?.copyWith(
                        color: fg.withOpacity(0.82),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─ DOWNLOADING — баннер с прогрессом ────────────────────────────────────────

class _DownloadingState extends StatelessWidget {
  final double? progress;
  final String status;
  final String title;
  final int? sizeBytes;

  const _DownloadingState({
    super.key,
    required this.progress,
    required this.status,
    required this.title,
    required this.sizeBytes,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final pct = progress;
    final pctLabel = (pct == null)
        ? '…'
        : '${(pct * 100).clamp(0, 100).toInt()} %';
    final sub = sizeBytes != null && sizeBytes! > 0 && pct != null
        ? _formatProgressBytes(pct, sizeBytes!)
        : status;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  value: pct,
                  strokeWidth: 2.4,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  trf('Загружаем «{title}»', {'title': title}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                pctLabel,
                style: textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatProgressBytes(double progress, int total) {
    final done = (progress * total).toInt();
    return '${_ActionPanel._formatBytes(done)} / ${_ActionPanel._formatBytes(total)}';
  }
}

// ─ VOTE CHIP ───────────────────────────────────────────────────────────────

class _VoteChip extends StatelessWidget {
  final IconData icon;
  final int count;
  final bool active;
  final Color activeColor;
  final Color activeOnColor;
  final Color activeContainer;
  final VoidCallback onTap;

  const _VoteChip({
    required this.icon,
    required this.count,
    required this.active,
    required this.activeColor,
    required this.activeOnColor,
    required this.activeContainer,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final bg = active ? activeContainer : scheme.surfaceContainerHighest;
    final fg = active ? activeOnColor : scheme.onSurfaceVariant;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 18),
              const SizedBox(width: 8),
              Text(
                count.toString(),
                style: textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoteChipPlaceholder extends StatelessWidget {
  final ColorScheme scheme;
  const _VoteChipPlaceholder({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
    );
  }
}

// ... (_ExpandableReviewCard, _ReviewDialog, FullScreenImageViewer без изменений) ...
class _ExpandableReviewCard extends StatefulWidget {
  final Review review;
  final bool canReply;
  final VoidCallback? onReplySubmitted;

  const _ExpandableReviewCard({
    required this.review,
    this.canReply = false,
    this.onReplySubmitted,
  });

  @override
  State<_ExpandableReviewCard> createState() => _ExpandableReviewCardState();
}

class _ExpandableReviewCardState extends State<_ExpandableReviewCard> {
  bool _isExpanded = false;
  static const int _maxLinesCollapsed = 4;
  final TextEditingController _replyController = TextEditingController();
  bool _showReplyField = false;
  bool _isSubmittingReply = false;

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _submitReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || widget.review.id.isEmpty) return;

    setState(() => _isSubmittingReply = true);

    try {
      final api = ApiService();
      await api.post(
        'api/author-walls/quests/${widget.review.questId}/reviews/${widget.review.id}/reply',
        body: {'text': text},
      );
      if (mounted) {
        _replyController.clear();
        setState(() {
          _showReplyField = false;
        });
        widget.onReplySubmitted?.call();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Ответ сохранён')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmittingReply = false);
      }
    }
  }

  void _openReplyComposer({required bool editing}) {
    final currentReply = widget.review.authorReply?.trim() ?? '';
    setState(() {
      _showReplyField = true;
      _replyController.text = editing ? currentReply : '';
      _replyController.selection = TextSelection.fromPosition(
        TextPosition(offset: _replyController.text.length),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasReply =
        widget.review.authorReply != null &&
        widget.review.authorReply!.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(userId: widget.review.authorId),
                ),
              );
            },
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                _buildSafeCircleAvatar(
                  avatarUrl: widget.review.authorAvatarUrl,
                  radius: 16,
                  backgroundColor: scheme.primaryContainer,
                  frame: cosmeticById(widget.review.authorCosmetics.avatarFrame),
                  fallback: Text(
                    _avatarInitial(widget.review.authorName),
                    style: textTheme.labelMedium?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: CosmeticNameText(
                    name: widget.review.authorName ?? tr('Пользователь'),
                    def: cosmeticById(widget.review.authorNameStyle),
                    style: textTheme.titleSmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (widget.review.rating != null && widget.review.rating! > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: Colors.amber,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          widget.review.rating.toString(),
                          style: textTheme.labelMedium?.copyWith(
                            color: Colors.amber.shade800,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: Icon(
                    Icons.flag_outlined,
                    color: scheme.error.withOpacity(0.8),
                  ),
                  tooltip: tr('Пожаловаться'),
                  onPressed: () {
                    showAppDialog(
                      context: context,
                      builder: (context) => ReportDialog(
                        reportedType: 'review',
                        reportedId: widget.review.id,
                        reportedTitle: widget.review.textContent.isNotEmpty
                            ? widget.review.textContent.substring(
                                0,
                                widget.review.textContent.length > 50
                                    ? 50
                                    : widget.review.textContent.length,
                              )
                            : null,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          if (widget.review.textContent.isNotEmpty) ...[
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                final textStyle = textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  height: 1.45,
                );
                final tp = TextPainter(
                  text: TextSpan(
                    text: widget.review.textContent,
                    style: textStyle,
                  ),
                  textDirection: TextDirection.ltr,
                  maxLines: _maxLinesCollapsed,
                )..layout(maxWidth: constraints.maxWidth);
                final isOverflowing = tp.didExceedMaxLines;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MeanderEntityText(
                      data: widget.review.textContent,
                      style: textStyle,
                      maxLines: _isExpanded ? null : _maxLinesCollapsed,
                      overflow: _isExpanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                    ),
                    if (isOverflowing)
                      TextButton(
                        onPressed: () =>
                            setState(() => _isExpanded = !_isExpanded),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          _isExpanded ? tr('Свернуть') : tr('Читать полностью'),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],

          if (hasReply) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.reply_rounded,
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        tr('Ответ автора'),
                        style: textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (widget.review.authorReplyAt != null) ...[
                        const Spacer(),
                        Text(
                          widget.review.authorReplyAt!,
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.review.authorReply!,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (widget.canReply) ...[
            const SizedBox(height: 8),
            if (_showReplyField)
              TextField(
                controller: _replyController,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: tr('Ваш ответ…'),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => setState(() {
                          _showReplyField = false;
                          _replyController.clear();
                        }),
                      ),
                      IconButton(
                        icon: _isSubmittingReply
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.primary,
                                ),
                              )
                            : Icon(Icons.send_rounded, color: scheme.primary),
                        onPressed: _isSubmittingReply ? null : _submitReply,
                      ),
                    ],
                  ),
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _openReplyComposer(editing: hasReply),
                  icon: Icon(
                    hasReply ? Icons.edit_rounded : Icons.reply_rounded,
                    size: 16,
                  ),
                  label: Text(hasReply ? tr('Изменить ответ') : tr('Ответить')),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ReviewDialog extends StatefulWidget {
  final String questId;
  final int initialRating;
  final String initialText;
  final VoidCallback onSubmitted;
  const _ReviewDialog({
    required this.questId,
    required this.initialRating,
    required this.initialText,
    required this.onSubmitted,
  });
  @override
  State<_ReviewDialog> createState() => __ReviewDialogState();
}

class __ReviewDialogState extends State<_ReviewDialog> {
  late int _rating;
  late TextEditingController _controller;
  bool _sending = false;

  String _progressText = tr('Отправка...');
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _rating = widget.initialRating;
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    _progressTimer?.cancel();
    super.dispose();
  }

  void _startFakeProgress() {
    setState(() {
      _sending = true;
      _progressText = tr('Подключение...');
    });

    int step = 0;
    final steps = [
      tr('Проверка токсичности...'),
      tr('Проверка на спам...'),
      tr('Проверка контента...'),
      tr('Публикация отзыва...'),
    ];

    _progressTimer = Timer.periodic(const Duration(milliseconds: 800), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (step < steps.length) {
        setState(() {
          _progressText = steps[step];
        });
        step++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Написать отзыв'),
            style: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              5,
              (i) => IconButton(
                icon: Icon(
                  i < _rating ? Icons.star_rounded : Icons.star_border_rounded,
                  color: i < _rating ? Colors.amber : scheme.outline,
                  size: 40,
                ),
                onPressed: _sending
                    ? null
                    : () => setState(() => _rating = i + 1),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            enabled: !_sending,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: tr('Опишите свои впечатления…'),
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 24),

          if (_sending)
            Center(
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _progressText,
                      key: ValueKey(_progressText),
                      style: textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: Consumer(
                builder: (ctx, ref, _) => FilledButton.icon(
                  onPressed: _rating == 0
                      ? null
                      : () async {
                          _startFakeProgress();
                          try {
                            final api = ref.read(apiServiceProvider);
                            await api.post(
                              'quests/${widget.questId}/rate',
                              body: {'rating': _rating},
                            );
                            if (_controller.text.isNotEmpty) {
                              await api.post(
                                'quests/${widget.questId}/review',
                                body: {'text_content': _controller.text},
                              );
                            }
                            await Future.delayed(
                              const Duration(milliseconds: 2000),
                            );
                            widget.onSubmitted();
                            if (context.mounted) Navigator.pop(context);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                              setState(() => _sending = false);
                              _progressTimer?.cancel();
                            }
                          }
                        },
                  icon: const Icon(Icons.send_rounded),
                  label: Text(tr('Опубликовать')),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class FullScreenImageViewer extends StatelessWidget {
  final List<String> imageUrls;
  final int initialIndex;
  const FullScreenImageViewer({
    super.key,
    required this.imageUrls,
    this.initialIndex = 0,
  });
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      body: PhotoViewGallery.builder(
        itemCount: imageUrls.length,
        pageController: PageController(initialPage: initialIndex),
        builder: (context, index) => PhotoViewGalleryPageOptions(
          imageProvider: CachedNetworkImageProvider(imageUrls[index]),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 2,
        ),
      ),
    );
  }
}
