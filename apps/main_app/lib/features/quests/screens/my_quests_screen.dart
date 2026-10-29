import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/services/async_backup_service.dart';
import 'package:canvas_app/core/services/async_import_service.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:canvas_app/core/services/onboarding_service.dart';
import 'package:canvas_app/core/services/playtime_service.dart';
import 'package:canvas_app/core/services/quest_document_exporter.dart';
import 'package:canvas_app/core/utils/playtime_formatter.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/quests/widgets/pdf_export_options_sheet.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
import 'package:canvas_app/features/hub/screens/local_presets_screen.dart';
import 'package:canvas_app/features/library/screens/my_library_screen.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_session.dart';
import 'package:canvas_app/features/quests/providers/cloud_sync_provider.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/features/quests/providers/quest_sync_provider.dart';
import 'package:canvas_app/features/quests/screens/create_quest_screen.dart';
import 'package:canvas_app/features/quests/screens/edit_quest_screen.dart';
import 'package:canvas_app/features/quests/screens/quest_details_screen.dart';
import 'package:canvas_app/features/quests/screens/cloud_sync_settings_screen.dart';
import 'package:canvas_app/features/quests/screens/quest_sync_settings_screen.dart';
import 'package:canvas_app/features/onboarding/controllers/tutorial_controller.dart';
import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:canvas_app/core/theme/m3e_theme.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';

// ============================================================================
//  БИБЛИОТЕКА — Material You / Material 3 редизайн
// ============================================================================

const double _kCompactBreakpoint = 600;

enum LibrarySort { az, za, createdDate, openedDate }

enum LibraryTypeFilter { all, recent, marketDownloaded, local, corrupted }

// ============================================================================
//  ОСНОВНОЙ ЭКРАН
// ============================================================================

class MyQuestsScreen extends ConsumerStatefulWidget {
  final bool isRoot;

  const MyQuestsScreen({super.key, this.isRoot = false});

  @override
  ConsumerState<MyQuestsScreen> createState() => _MyQuestsScreenState();
}

class _MyQuestsScreenState extends ConsumerState<MyQuestsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _debounceTimer;

  /// Ключ кнопки «Создать квест» — на неё указывает обучение.
  final GlobalKey _createFabKey = GlobalKey();

  /// Ключ карточки только что созданного квеста — для шага openQuestCard.
  GlobalKey? _newQuestCardKey;

  LibrarySort _sort = LibrarySort.openedDate;
  bool _isDescending = true;
  LibraryTypeFilter _typeFilter = LibraryTypeFilter.all;

  bool _isOperationInProgress = false;
  late M3EThemeData _m3eTheme;
  String _operationStatus = '';

  /// Диалог прогресса живёт в своём маршруте, поэтому `setState` экрана до него
  /// не доходит: без этого крючка надпись в окне зависала бы на первом слове.
  void Function(void Function())? _refreshProgressDialog;
  double? _operationProgress;
  bool _didInitialAutoSync = false;
  bool _didCheckTutorial = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Регистрируем цель «Создать квест» в контроллере обучения —
      // на случай если когда-нибудь захотим включить тур обратно.
      ref
          .read(tutorialControllerProvider.notifier)
          .registerTarget(TutorialTargets.createQuestFab, _createFabKey);
      // Автозапуск обучения отключён — фича пока сырая. Код шагов
      // и оверлея остаётся в проекте для дальнейшей доработки.
      // _maybeStartFirstRunTutorial();
    });
  }

  // Автозапуск обучения временно отключён. Метод оставлен на случай,
  // если решим включить его обратно после доработки UX.
  // ignore: unused_element
  Future<void> _maybeStartFirstRunTutorial() async {
    if (_didCheckTutorial) return;
    _didCheckTutorial = true;
    final shouldShow =
        await OnboardingService.shouldShowQuestCreationTutorial();
    if (!mounted || !shouldShow) return;
    final tutorialState = ref.read(tutorialControllerProvider);
    if (tutorialState.isActive) return;
    ref.read(tutorialControllerProvider.notifier).start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _m3eTheme = m3eThemeFrom(Theme.of(context));
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  //  Фильтрация и сортировка
  // ---------------------------------------------------------------------------

  void _onSearchChanged(String _) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {});
  }

  void _clearFilters() {
    _clearSearch();
    setState(() {
      _typeFilter = LibraryTypeFilter.all;
    });
  }

  bool get _isFiltering =>
      _searchController.text.isNotEmpty || _typeFilter != LibraryTypeFilter.all;

  List<Quest> _applyFilters(List<Quest> quests) {
    var list = List<Quest>.from(quests);

    // Тип
    switch (_typeFilter) {
      case LibraryTypeFilter.all:
        break;
      case LibraryTypeFilter.recent:
        list = list.where((q) => q.lastOpened != null).toList();
        list.sort(
          (a, b) => (b.lastOpened ?? DateTime(1970)).compareTo(
            a.lastOpened ?? DateTime(1970),
          ),
        );
        list = list.take(20).toList();
        break;
      case LibraryTypeFilter.marketDownloaded:
        list = list.where((q) => q.isMarketDownloaded).toList();
        break;
      case LibraryTypeFilter.local:
        list = list
            .where((q) => !q.isMarketDownloaded && !q.isCorrupted)
            .toList();
        break;
      case LibraryTypeFilter.corrupted:
        list = list.where((q) => q.isCorrupted).toList();
        break;
    }

    // Поиск
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      list = list.where((quest) {
        return quest.title.toLowerCase().contains(query) ||
            (quest.author?.toLowerCase().contains(query) ?? false) ||
            (quest.description?.toLowerCase().contains(query) ?? false);
      }).toList();
    }

    // Сортировка (для recent уже отсортировано выше)
    if (_typeFilter != LibraryTypeFilter.recent) {
      switch (_sort) {
        case LibrarySort.az:
          list.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
          break;
        case LibrarySort.za:
          list.sort(
            (a, b) => b.title.toLowerCase().compareTo(a.title.toLowerCase()),
          );
          break;
        case LibrarySort.createdDate:
          list.sort((a, b) {
            final da = a.created ?? DateTime(1970);
            final db = b.created ?? DateTime(1970);
            return _isDescending ? db.compareTo(da) : da.compareTo(db);
          });
          break;
        case LibrarySort.openedDate:
          list.sort((a, b) {
            final da = a.lastOpened ?? DateTime(1970);
            final db = b.lastOpened ?? DateTime(1970);
            return _isDescending ? db.compareTo(da) : da.compareTo(db);
          });
          break;
      }
    }

    return list;
  }

  // ---------------------------------------------------------------------------
  //  Действия
  // ---------------------------------------------------------------------------

  Future<void> _refreshAll() async {
    ref.invalidate(questsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _autoSyncIfEnabled();
  }

  void _navigateToCreateQuest() async {
    // Если обучение находится на шаге подсветки FAB — продвигаем его дальше.
    final tutorial = ref.read(tutorialControllerProvider);
    if (tutorial.step == TutorialStep.highlightCreateButton) {
      ref.read(tutorialControllerProvider.notifier).next();
    }

    final newQuest = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CreateQuestScreen()),
    );
    if (newQuest != null && mounted) {
      ref.invalidate(questsProvider);
      unawaited(_autoSyncIfEnabled());

      // Если обучение сейчас на шаге «нажми Создать проект» —
      // продвигаем его на «открой карточку нового квеста».
      final state = ref.read(tutorialControllerProvider);
      if (state.step == TutorialStep.pressCreate) {
        ref.read(tutorialControllerProvider.notifier).next();
      }
    }
  }

  Future<void> _importQuest() async {
    if (_isOperationInProgress) return;
    setState(() => _isOperationInProgress = true);
    try {
      final importedQuestId = await AsyncImportService.pickAndImportQuest(
        onProgress: (status) {
          if (mounted) setState(() => _operationStatus = status);
        },
        onProgressUpdate: (_) {},
      );
      if (!mounted) return;
      if (importedQuestId != null) {
        _showSnack(tr('Квест успешно импортирован'), success: true);
        ref.invalidate(questsProvider);
        unawaited(_autoSyncIfEnabled());
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        trf('Ошибка импорта: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isOperationInProgress = false);
    }
  }

  Future<void> _exportQuest(Quest quest, {bool includeSaves = false}) async {
    if (_isOperationInProgress) return;
    setState(() => _isOperationInProgress = true);
    try {
      // Сохраняем состояние вкладок перед экспортом.
      try {
        final wsState = ref.read(editorWorkspaceControllerProvider(quest.id));
        await const EditorWorkspaceSessionStore().save(quest.id, wsState);
      } catch (_) {}
      final success = await ExportService.exportQuestAsMnd(
        quest.id,
        quest.title,
        includeSaves: includeSaves,
      );
      if (!mounted) return;
      if (success) {
        _showSnack(tr('Квест успешно экспортирован'), success: true);
      } else {
        _showSnack(tr('Экспорт отменён'));
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        trf('Ошибка экспорта: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isOperationInProgress = false);
    }
  }

  Future<void> _exportQuestAsPdf(Quest quest) async {
    if (_isOperationInProgress) return;

    // Сначала показываем настройки PDF.
    final options = await showPdfExportOptionsSheet(context);
    if (options == null || !mounted) return; // отмена

    setState(() {
      _isOperationInProgress = true;
      _operationStatus = tr('Сборка PDF…');
    });
    _showProgressDialog();
    try {
      final success = await QuestDocumentExporter.exportQuestAsPdf(
        quest.id,
        quest.title,
        options: options,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      if (success) {
        _showSnack(tr('PDF-файл сохранён'), success: true);
      } else {
        _showSnack(tr('Экспорт отменён'));
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _showSnack(
        trf('Ошибка экспорта в PDF: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isOperationInProgress = false);
    }
  }

  Future<void> _backupAllQuests() async {
    if (_isOperationInProgress) return;
    setState(() {
      _isOperationInProgress = true;
      _operationStatus = tr('Подготовка…');
    });
    _showProgressDialog();
    try {
      final success = await AsyncBackupService.createBackup(
        onProgress: _setOperationStatus,
        // Сервис считает долю готовых квестов — показываем её, а не крутим
        // бесконечный спиннер «в нищую».
        onProgressUpdate: _setOperationProgress,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      if (success) {
        _showSnack(tr('Резервная копия создана'), success: true);
      } else {
        _showSnack(tr('Создание копии отменено'));
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _showSnack(
        trf('Ошибка создания копии: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isOperationInProgress = false);
    }
  }

  Future<void> _restoreFromBackup() async {
    if (_isOperationInProgress) return;
    setState(() => _isOperationInProgress = true);
    try {
      final success = await AsyncBackupService.restoreFromBackup(
        onProgress: (status) {
          if (mounted) setState(() => _operationStatus = status);
        },
        onProgressUpdate: (_) {},
        onConflict: (questTitle) async {
          if (!mounted) return false;
          final result = await showAppDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => M3ETheme(
              data: _m3eTheme,
              child: M3EDialog(
                title: tr('Обнаружен конфликт'),
                content: Text(
                  trf(
                    'Квест «{questTitle}» уже существует. Заменить его версией из бэкапа?',
                    {'questTitle': questTitle},
                  ),
                  style: _m3eTheme.textTheme.bodyMedium,
                ),
                actions: [
                  M3EButton(
                    label: Text(tr('Пропустить')),
                    style: M3EButtonStyle.text,
                    onPressed: () => Navigator.pop(ctx, false),
                  ),
                  M3EButton(
                    label: Text(tr('Заменить')),
                    style: M3EButtonStyle.filled,
                    onPressed: () => Navigator.pop(ctx, true),
                  ),
                ],
              ),
            ),
          );
          return result ?? false;
        },
      );
      if (!mounted) return;
      if (success) {
        _showSnack(tr('Восстановление завершено'), success: true);
        ref.invalidate(questsProvider);
        unawaited(_autoSyncIfEnabled());
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        trf('Ошибка восстановления: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isOperationInProgress = false);
    }
  }

  Future<void> _editQuest(Quest quest) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditQuestScreen(questId: quest.id)),
    );
    if (mounted) {
      ref.invalidate(questsProvider);
      unawaited(_autoSyncIfEnabled());
    }
  }

  Future<void> _autoSyncIfEnabled() async {
    final syncState = ref.read(questSyncProvider);
    if (!syncState.settings.enabled || !syncState.settings.isConfigured) return;
    if (syncState.isSyncing) return;
    await ref.read(questSyncProvider.notifier).syncNow();
  }

  Future<void> _openSyncSettings() async {
    // По умолчанию открываем новый Meander Cloud. Старый GitHub доступен
    // длинным тапом (см. _openGitHubLegacySettings).
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CloudSyncSettingsScreen()),
    );
  }

  Future<void> _openGitHubLegacySettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => QuestSyncSettingsScreen()),
    );
  }

  // ---------------------------------------------------------------------------
  //  Диалоги / Sheets
  // ---------------------------------------------------------------------------

  void _showProgressDialog() {
    _operationProgress = null;
    unawaited(
      showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => M3ETheme(
          data: _m3eTheme,
          child: StatefulBuilder(
            builder: (ctx, setDialogState) {
              _refreshProgressDialog = setDialogState;
              final progress = _operationProgress;
              return M3EDialog(
                title: tr('Выполняется...'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (progress == null)
                      const M3EProgressIndicator.circularWavy(size: 48)
                    else ...[
                      M3EProgressIndicator.linear(value: progress),
                      const SizedBox(height: 12),
                      Text(
                        '${(progress * 100).round()}%',
                        style: _m3eTheme.textTheme.labelMedium,
                      ),
                    ],
                    const SizedBox(height: 20),
                    Text(
                      _operationStatus,
                      textAlign: TextAlign.center,
                      style: _m3eTheme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        // Крючок пересборки окна больше не жив: вызывать его после pop —
        // assertion на мёртвом StatefulBuilder.
      ).whenComplete(() => _refreshProgressDialog = null),
    );
  }

  /// Текст операции: и в состояние экрана (на случай закрытия окна), и в само
  /// окно — маршрут диалога пересобирается только своим setState.
  void _setOperationStatus(String status) {
    if (!mounted) return;
    setState(() => _operationStatus = status);
    _refreshProgressDialog?.call(() {});
  }

  void _setOperationProgress(double value) {
    _operationProgress = value.clamp(0.0, 1.0);
    _refreshProgressDialog?.call(() {});
  }

  void _showQuestOptions(Quest quest) {
    M3EBottomSheet.showAdaptive<void>(
      context,
      title: tr('Действия'),
      showDragHandle: true,
      initialValue: M3EBottomSheetValue.expanded,
      builder: (_) => M3ETheme(
        data: _m3eTheme,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!quest.isReadOnly || quest.isCorrupted)
                M3EListItem(
                  headline: tr('Экспортировать (.mnd)'),
                  supportingText: tr('Копия квеста без сохранений'),
                  leading: const Icon(Icons.share_rounded),
                  onTap: () {
                    Navigator.pop(context);
                    _exportQuest(quest);
                  },
                ),
              if (!quest.isReadOnly || quest.isCorrupted)
                M3EListItem(
                  headline: tr('Бэкап (с сохранениями)'),
                  supportingText: tr('Включая игровой прогресс'),
                  leading: const Icon(Icons.save_rounded),
                  onTap: () {
                    Navigator.pop(context);
                    _exportQuest(quest, includeSaves: true);
                  },
                ),
              if (!quest.isCorrupted)
                M3EListItem(
                  headline: tr('Экспортировать в PDF'),
                  supportingText: tr('Книга с содержанием и якорями'),
                  leading: const Icon(Icons.picture_as_pdf_rounded),
                  onTap: () {
                    Navigator.pop(context);
                    _exportQuestAsPdf(quest);
                  },
                ),
              if (!quest.isReadOnly &&
                  !quest.isMarketDownloaded &&
                  !quest.isCorrupted)
                M3EListItem(
                  headline: tr('Редактировать'),
                  leading: const Icon(Icons.edit_rounded),
                  onTap: () {
                    Navigator.pop(context);
                    _editQuest(quest);
                  },
                ),
              M3EListItem(
                headline: tr('Удалить квест'),
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: _m3eTheme.colorScheme.error,
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDeleteQuest(quest);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteQuest(Quest quest) async {
    bool alsoDeleteRemote = true;
    final result = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => M3ETheme(
        data: _m3eTheme,
        child: StatefulBuilder(
          builder: (ctx, setLocal) => M3EDialog(
            title: tr('Удалить квест?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trf(
                    'Квест «{p0}» будет удалён с устройства. Это действие необратимо.',
                    {'p0': quest.title},
                  ),
                  style: _m3eTheme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                M3EListItem(
                  headline: tr('Также удалить из облака'),
                  supportingText: tr(
                    'Если выключить — в облаке останется бэкап',
                  ),
                  leading: M3ECheckbox(
                    value: alsoDeleteRemote,
                    onChanged: (v) =>
                        setLocal(() => alsoDeleteRemote = v ?? false),
                  ),
                  onTap: () =>
                      setLocal(() => alsoDeleteRemote = !alsoDeleteRemote),
                ),
              ],
            ),
            actions: [
              M3EButton(
                label: Text(tr('Отмена')),
                style: M3EButtonStyle.text,
                onPressed: () => Navigator.pop(ctx, false),
              ),
              M3EButton(
                label: Text(tr('Удалить')),
                style: M3EButtonStyle.filled,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != true || !mounted) return;
    await _deleteQuest(quest, alsoDeleteRemote: alsoDeleteRemote);
  }

  Future<void> _deleteQuest(
    Quest quest, {
    required bool alsoDeleteRemote,
  }) async {
    // Контейнер берётся до первого await: папка стирается не мгновенно, и за
    // это время экран можно закрыть. До правки `ref` на мёртвом state бросал,
    // бросок ловил нижний catch, а тот звал Theme.of и ScaffoldMessenger.of
    // уже на несуществующем context — и из catch наружу не ловил его никто.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      // Локальное удаление: всю папку quests/<id>
      await FileStorage.delete(QuestPaths.questRoot(quest.id));
      container.invalidate(questsProvider);

      // Удаление из облака — best-effort, не падаем если не удалось
      if (alsoDeleteRemote) {
        try {
          await container
              .read(cloudSyncProvider.notifier)
              .deleteRemoteQuest(quest.id);
          container.invalidate(cloudSyncRemoteListProvider);
        } catch (_) {
          // Не критично — на локальное удаление это не влияет
        }
      }

      if (!mounted) return;
      _showSnack(
        alsoDeleteRemote
            ? tr('Квест удалён с устройства и из облака')
            : tr('Квест удалён с устройства'),
        success: true,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        trf('Не удалось удалить: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    }
  }

  void _showSortSheet() {
    final m3e = _m3eTheme;
    M3EBottomSheet.showAdaptive<void>(
      context,
      title: tr('Сортировка'),
      showDragHandle: true,
      initialValue: M3EBottomSheetValue.expanded,
      builder: (_) {
        return M3ETheme(
          data: m3e,
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              return SafeArea(
                child: Padding(
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
                          Icon(
                            Icons.tune_rounded,
                            color: m3e.colorScheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            tr('Сортировка'),
                            style: m3e.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _SortChoiceTile(
                        label: tr('По алфавиту А–Я'),
                        icon: Icons.sort_by_alpha_rounded,
                        selected: _sort == LibrarySort.az,
                        onTap: () => setSheet(() => _sort = LibrarySort.az),
                      ),
                      _SortChoiceTile(
                        label: tr('По алфавиту Я–А'),
                        icon: Icons.sort_by_alpha_rounded,
                        selected: _sort == LibrarySort.za,
                        onTap: () => setSheet(() => _sort = LibrarySort.za),
                      ),
                      _SortChoiceTile(
                        label: tr('По дате создания'),
                        icon: Icons.event_note_rounded,
                        selected: _sort == LibrarySort.createdDate,
                        onTap: () =>
                            setSheet(() => _sort = LibrarySort.createdDate),
                      ),
                      _SortChoiceTile(
                        label: tr('По дате последнего открытия'),
                        icon: Icons.schedule_rounded,
                        selected: _sort == LibrarySort.openedDate,
                        onTap: () =>
                            setSheet(() => _sort = LibrarySort.openedDate),
                      ),
                      const SizedBox(height: 16),
                      if (_sort == LibrarySort.createdDate ||
                          _sort == LibrarySort.openedDate)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr('Порядок'),
                              style: m3e.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            M3ESegmentedButton<bool>(
                              segments: [
                                M3ESegment(
                                  value: true,
                                  label: tr('Сначала новые'),
                                  icon: const Icon(
                                    Icons.arrow_downward_rounded,
                                  ),
                                ),
                                M3ESegment(
                                  value: false,
                                  label: tr('Сначала старые'),
                                  icon: const Icon(Icons.arrow_upward_rounded),
                                ),
                              ],
                              selected: {_isDescending},
                              onSelectionChanged: (s) =>
                                  setSheet(() => _isDescending = s.first),
                            ),
                          ],
                        ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: M3EButton(
                          label: Text(tr('Применить')),
                          icon: const Icon(Icons.check_rounded),
                          style: M3EButtonStyle.filled,
                          onPressed: () {
                            setState(() {});
                            Navigator.pop(ctx);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _showSnack(String text, {bool success = false, bool error = false}) {
    M3ESnackbar.show(context, message: text, showCloseButton: true);
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    ref.listen<QuestSyncState>(questSyncProvider, (previous, next) {
      if (previous?.isSyncing == true &&
          !next.isSyncing &&
          next.noChanges &&
          mounted) {
        _showSnack(tr('Изменений для синхронизации не найдено'));
      }
    });

    final questsAsync = ref.watch(questsProvider);
    final syncState = ref.watch(questSyncProvider);
    final libraryStats = _LibraryStats.fromAsync(questsAsync);

    if (!_didInitialAutoSync &&
        syncState.settings.enabled &&
        syncState.settings.isConfigured &&
        !syncState.isSyncing) {
      _didInitialAutoSync = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(ref.read(questSyncProvider.notifier).syncNow());
      });
    }

    return M3ETheme(
      data: _m3eTheme,
      child: PopScope(
        canPop: !_isFiltering,
        onPopInvoked: (didPop) {
          if (didPop) return;
          _clearFilters();
        },
        child: Scaffold(
          backgroundColor: _m3eTheme.colorScheme.surface,
          body: SafeArea(
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final isCompact = width < _kCompactBreakpoint;
                final hPad = isCompact ? 16.0 : 24.0;

                return M3ERefreshIndicator(
                  onRefresh: _refreshAll,
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 16),
                          child: _LibraryDashboard(
                            stats: libraryStats,
                            isSyncing: syncState.isSyncing,
                            syncEnabled: syncState.settings.enabled,
                            isOperationInProgress: _isOperationInProgress,
                            activeFilter: _typeFilter,
                            leadingIcon: _isFiltering
                                ? Icons.close_rounded
                                : (widget.isRoot
                                      ? null
                                      : Icons.arrow_back_rounded),
                            leadingTooltip: _isFiltering
                                ? tr('Сбросить фильтр')
                                : tr('Назад'),
                            onLeading: _isFiltering
                                ? _clearFilters
                                : (widget.isRoot
                                      ? null
                                      : () => Navigator.pop(context)),
                            onOpenLibrary: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => MyLibraryScreen(),
                              ),
                            ),
                            onOpenPresets: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => LocalPresetsScreen(),
                              ),
                            ),
                            onFilter: (f) => setState(() => _typeFilter = f),
                            onSync: _openSyncSettings,
                            onSyncLongPress: _openGitHubLegacySettings,
                            onImport: _isOperationInProgress
                                ? null
                                : _importQuest,
                            onBackup: _isOperationInProgress
                                ? null
                                : _backupAllQuests,
                            onRestore: _isOperationInProgress
                                ? null
                                : _restoreFromBackup,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 12),
                          child: _LibrarySearchField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            onChanged: _onSearchChanged,
                            onClear: _clearSearch,
                            onSortTap: _showSortSheet,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _LibraryFilterChipsRow(
                          active: _typeFilter,
                          stats: libraryStats,
                          onSelected: (f) => setState(() => _typeFilter = f),
                        ),
                      ),
                      // Плашку про облако показываем только тогда, когда терять
                      // уже есть: новичок с пустой библиотекой получал
                      // «Подключите облако, чтобы не потерять прогресс» первым
                      // же экраном — и туда, где он ещё ничего не сделал.
                      if (libraryStats.total > 0)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 0),
                            child: _SyncStatusCard(
                              state: syncState,
                              onSync: () => ref
                                  .read(questSyncProvider.notifier)
                                  .syncNow(),
                              onConfigure: _openSyncSettings,
                            ),
                          ),
                        ),
                      // По той же причине и подсказка про пустоту: она нужна
                      // только на первом экране, дальше человек уже знает, откуда
                      // брать квесты.
                      if (libraryStats.total == 0)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 0),
                            child: SectionHintBanner(
                              hintId: SectionHints.libraryEmpty,
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 20)),
                      SliverToBoxAdapter(
                        child: _SectionHeader(
                          title: _sectionTitle(),
                          subtitle: _sectionSubtitle(),
                          icon: _sectionIcon(),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 12)),
                      _buildQuestsSliver(questsAsync, hPad: hPad),
                      const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
                    ],
                  ),
                );
              },
            ),
          ),
          floatingActionButton: M3EExtendedFab(
            key: _createFabKey,
            onPressed: _isOperationInProgress ? null : _navigateToCreateQuest,
            label: tr('Создать квест'),
            icon: const Icon(Icons.add_rounded),
            size: M3EExtendedFabSize.small,
            color: M3EFabColor.primary,
          ),
        ),
      ),
    );
  }

  String _sectionTitle() {
    if (_searchController.text.isNotEmpty) return tr('Результаты поиска');
    switch (_typeFilter) {
      case LibraryTypeFilter.all:
        return tr('Все квесты');
      case LibraryTypeFilter.recent:
        return tr('Недавно открытые');
      case LibraryTypeFilter.marketDownloaded:
        return tr('Из маркета');
      case LibraryTypeFilter.local:
        return tr('Локальные');
      case LibraryTypeFilter.corrupted:
        return tr('Повреждённые');
    }
  }

  String? _sectionSubtitle() {
    switch (_typeFilter) {
      case LibraryTypeFilter.recent:
        return tr('Самые свежие сессии — до 20 квестов');
      case LibraryTypeFilter.corrupted:
        return tr('Откройте меню и экспортируйте .mnd для восстановления');
      default:
        return null;
    }
  }

  IconData _sectionIcon() {
    if (_searchController.text.isNotEmpty) return Icons.search_rounded;
    switch (_typeFilter) {
      case LibraryTypeFilter.all:
        return Icons.auto_stories_rounded;
      case LibraryTypeFilter.recent:
        return Icons.schedule_rounded;
      case LibraryTypeFilter.marketDownloaded:
        return Icons.shop_rounded;
      case LibraryTypeFilter.local:
        return Icons.devices_other_rounded;
      case LibraryTypeFilter.corrupted:
        return Icons.error_outline_rounded;
    }
  }

  Widget _buildQuestsSliver(
    AsyncValue<List<Quest>> async, {
    required double hPad,
  }) {
    return async.when(
      loading: () => SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: hPad),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 380,
            childAspectRatio: 1,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          delegate: SliverChildBuilderDelegate(
            (_, _) => const _QuestCardShimmer(),
            childCount: 4,
          ),
        ),
      ),
      error: (err, _) => SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 24),
          child: _LibraryErrorState(error: err, onRetry: _refreshAll),
        ),
      ),
      data: (quests) {
        final filtered = _applyFilters(quests);

        if (filtered.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 24),
              child: _EmptyLibraryState(
                isSearching: _searchController.text.isNotEmpty,
                onCreate: _navigateToCreateQuest,
                onImport: _importQuest,
              ),
            ),
          );
        }

        // Идентификатор свежесозданного во время обучения квеста —
        // на его карточку повесим GlobalKey для подсветки.
        final tutorialState = ref.read(tutorialControllerProvider);
        final highlightedQuestId = tutorialState.lastCreatedQuestId;
        if (highlightedQuestId != null) {
          // Создаём/переиспользуем GlobalKey для этой карточки.
          _newQuestCardKey ??= GlobalKey();
          // Регистрируем после кадра, чтобы цель уже была в дереве.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref
                .read(tutorialControllerProvider.notifier)
                .registerTarget(
                  TutorialTargets.newQuestCard,
                  _newQuestCardKey!,
                );
          });
        }

        Key? keyForQuest(Quest q) {
          if (q.id == highlightedQuestId && _newQuestCardKey != null) {
            return _newQuestCardKey;
          }
          return null;
        }

        return SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 380,
              mainAxisExtent: 340,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final quest = filtered[index];
              return _QuestListCard(
                key: keyForQuest(quest),
                quest: quest,
                onTap: () => _openQuest(quest),
                onMoreTap: () => _showQuestOptions(quest),
              );
            }, childCount: filtered.length),
          ),
        );
      },
    );
  }

  Future<void> _openQuest(Quest quest) async {
    if (quest.isCorrupted) {
      _showSnack(
        tr('Квест повреждён: откройте меню и экспортируйте .mnd'),
        error: true,
      );
      return;
    }

    // Если обучение ждёт нажатия на карточку именно этого квеста —
    // продвигаем дальше (на шаг «открой редактор»).
    final tutorial = ref.read(tutorialControllerProvider);
    if (tutorial.step == TutorialStep.openQuestCard &&
        tutorial.lastCreatedQuestId == quest.id) {
      ref.read(tutorialControllerProvider.notifier).next();
    }

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => QuestDetailsScreen(questId: quest.id)),
    );
    if (mounted) {
      ref.invalidate(questsProvider);
      unawaited(_autoSyncIfEnabled());
    }
  }
}

// ============================================================================
//  СТАТИСТИКА БИБЛИОТЕКИ
// ============================================================================

class _LibraryStats {
  final int total;
  final int market;
  final int local;
  final int corrupted;
  final int recent;

  const _LibraryStats({
    required this.total,
    required this.market,
    required this.local,
    required this.corrupted,
    required this.recent,
  });

  factory _LibraryStats.empty() => const _LibraryStats(
    total: 0,
    market: 0,
    local: 0,
    corrupted: 0,
    recent: 0,
  );

  factory _LibraryStats.fromAsync(AsyncValue<List<Quest>> async) {
    return async.maybeWhen(
      data: (list) {
        return _LibraryStats(
          total: list.length,
          market: list.where((q) => q.isMarketDownloaded).length,
          local: list
              .where((q) => !q.isMarketDownloaded && !q.isCorrupted)
              .length,
          corrupted: list.where((q) => q.isCorrupted).length,
          recent: list.where((q) => q.lastOpened != null).length,
        );
      },
      orElse: _LibraryStats.empty,
    );
  }
}

// ============================================================================
//  HERO-СЕКЦИЯ
// ============================================================================

String _librarySubtitle(_LibraryStats stats) {
  if (stats.total == 0) return tr('Пока пусто — создайте свой первый квест');
  final parts = <String>[
    '${stats.total} ${trp(['квест', 'квеста', 'квестов'], stats.total)}',
  ];
  if (stats.market > 0) parts.add('${stats.market} ${tr('из маркета')}');
  if (stats.local > 0) parts.add('${stats.local} ${tr('локальных')}');
  if (stats.corrupted > 0) {
    parts.add('${stats.corrupted} ${tr('повреждённых')}');
  }
  return parts.join(' · ');
}

class _LibraryDashboard extends StatelessWidget {
  final _LibraryStats stats;
  final bool isSyncing;
  final bool syncEnabled;
  final bool isOperationInProgress;
  final LibraryTypeFilter activeFilter;
  final IconData? leadingIcon;
  final String? leadingTooltip;
  final VoidCallback? onLeading;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenPresets;
  final ValueChanged<LibraryTypeFilter> onFilter;
  final VoidCallback onSync;
  final VoidCallback? onSyncLongPress;
  final VoidCallback? onImport;
  final VoidCallback? onBackup;
  final VoidCallback? onRestore;

  const _LibraryDashboard({
    required this.stats,
    required this.isSyncing,
    required this.syncEnabled,
    required this.isOperationInProgress,
    required this.activeFilter,
    required this.leadingIcon,
    required this.leadingTooltip,
    required this.onLeading,
    required this.onOpenLibrary,
    required this.onOpenPresets,
    required this.onFilter,
    required this.onSync,
    required this.onSyncLongPress,
    required this.onImport,
    required this.onBackup,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (leadingIcon != null)
              M3EIconButton(
                icon: Icon(leadingIcon!),
                tooltip: leadingTooltip,
                variant: M3EIconButtonVariant.standard,
                onPressed: onLeading,
              ),
            Expanded(
              child: Text(
                tr('Мои квесты'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: m3e.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: scheme.onSurface,
                ),
              ),
            ),
            M3EIconButton(
              icon: const Icon(Icons.collections_bookmark_rounded),
              tooltip: tr('Моя библиотека'),
              variant: M3EIconButtonVariant.standard,
              onPressed: onOpenLibrary,
            ),
            M3EIconButton(
              icon: const Icon(Icons.smart_button_rounded),
              tooltip: tr('Локальные пресеты'),
              variant: M3EIconButtonVariant.standard,
              onPressed: onOpenPresets,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _librarySubtitle(stats),
          style: m3e.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _statCard(
              m3e,
              icon: Icons.auto_stories_rounded,
              value: stats.total,
              label: tr('Все'),
              selected: activeFilter == LibraryTypeFilter.all,
              onTap: () => onFilter(LibraryTypeFilter.all),
            ),
            const SizedBox(width: 8),
            _statCard(
              m3e,
              icon: Icons.shop_rounded,
              value: stats.market,
              label: tr('Маркет'),
              selected: activeFilter == LibraryTypeFilter.marketDownloaded,
              onTap: () => onFilter(LibraryTypeFilter.marketDownloaded),
            ),
            const SizedBox(width: 8),
            _statCard(
              m3e,
              icon: Icons.devices_other_rounded,
              value: stats.local,
              label: tr('Локальные'),
              selected: activeFilter == LibraryTypeFilter.local,
              onTap: () => onFilter(LibraryTypeFilter.local),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            M3EButton(
              label: Text(tr('Синк')),
              icon: isSyncing
                  ? const M3EProgressIndicator.circularWavy(size: 16)
                  : Icon(
                      syncEnabled
                          ? Icons.cloud_done_rounded
                          : Icons.cloud_off_rounded,
                    ),
              style: M3EButtonStyle.tonal,
              size: M3EButtonSize.xs,
              onPressed: onSync,
              onLongPress: onSyncLongPress,
            ),
            const SizedBox(width: 8),
            M3EButton(
              label: Text(tr('Импорт')),
              icon: isOperationInProgress
                  ? const M3EProgressIndicator.circularWavy(size: 16)
                  : const Icon(Icons.file_upload_outlined),
              style: M3EButtonStyle.outlined,
              size: M3EButtonSize.xs,
              onPressed: onImport,
            ),
            const Spacer(),
            _HeroMenuButton(onBackup: onBackup, onRestore: onRestore),
          ],
        ),
      ],
    );
  }

  Widget _statCard(
    M3EThemeData m3e, {
    required IconData icon,
    required int value,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = m3e.colorScheme;
    return Expanded(
      child: M3ECard(
        variant: selected ? M3ECardVariant.filled : M3ECardVariant.outlined,
        color: selected ? scheme.primaryContainer : null,
        onPressed: onTap,
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? scheme.onPrimaryContainer : scheme.primary,
              ),
              const SizedBox(height: 8),
              Text(
                '$value',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: m3e.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: m3e.textTheme.labelSmall?.copyWith(
                  color: selected
                      ? scheme.onPrimaryContainer.withOpacity(0.8)
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroMenuButton extends StatelessWidget {
  final VoidCallback? onBackup;
  final VoidCallback? onRestore;
  const _HeroMenuButton({required this.onBackup, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    return M3EMenu.entries(
      anchorBuilder: (context, open) => M3EIconButton(
        icon: const Icon(Icons.more_horiz_rounded),
        tooltip: tr('Резервные копии'),
        variant: M3EIconButtonVariant.tonal,
        onPressed: open,
      ),
      entries: [
        M3EMenuEntry(
          label: tr('Бэкап всех квестов'),
          leading: const Icon(Icons.archive_outlined),
          enabled: onBackup != null,
          onPressed: onBackup,
        ),
        M3EMenuEntry(
          label: tr('Восстановить из бэкапа'),
          leading: const Icon(Icons.unarchive_outlined),
          enabled: onRestore != null,
          onPressed: onRestore,
        ),
      ],
    );
  }
}

// ============================================================================
//  ПОИСКОВАЯ СТРОКА
// ============================================================================

class _LibrarySearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onSortTap;

  const _LibrarySearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    required this.onSortTap,
  });

  @override
  State<_LibrarySearchField> createState() => _LibrarySearchFieldState();
}

class _LibrarySearchFieldState extends State<_LibrarySearchField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final hasText = widget.controller.text.isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: M3ETextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            variant: M3ETextFieldVariant.filled,
            placeholder: tr('Поиск по названию, автору, описанию…'),
            leading: Icon(
              Icons.search_rounded,
              color: m3e.colorScheme.onSurfaceVariant,
            ),
            trailing: hasText
                ? M3EIconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: tr('Очистить'),
                    variant: M3EIconButtonVariant.standard,
                    size: M3EIconButtonSize.xs,
                    onPressed: widget.onClear,
                  )
                : null,
            textInputAction: TextInputAction.search,
            onChanged: widget.onChanged,
          ),
        ),
        const SizedBox(width: 8),
        M3EIconButton(
          icon: const Icon(Icons.tune_rounded),
          tooltip: tr('Сортировка'),
          variant: M3EIconButtonVariant.tonal,
          onPressed: widget.onSortTap,
        ),
      ],
    );
  }
}

// ============================================================================
//  ЧИПЫ ФИЛЬТРОВ ТИПА
// ============================================================================

class _LibraryFilterChipsRow extends StatefulWidget {
  final LibraryTypeFilter active;
  final ValueChanged<LibraryTypeFilter> onSelected;
  final _LibraryStats stats;

  const _LibraryFilterChipsRow({
    required this.active,
    required this.onSelected,
    required this.stats,
  });

  @override
  State<_LibraryFilterChipsRow> createState() => _LibraryFilterChipsRowState();
}

class _LibraryFilterChipsRowState extends State<_LibraryFilterChipsRow> {
  // Галочка-подтверждение живёт мигом: появилась при тапе и через секунду
  // сменилась обратно иконкой категории, как у фильтров Хаба.
  LibraryTypeFilter? _flash;
  Timer? _flashTimer;

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  void _select(LibraryTypeFilter f) {
    widget.onSelected(f);
    _flashTimer?.cancel();
    setState(() => _flash = f);
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final entries = <(LibraryTypeFilter, String, IconData, int)>[
      (LibraryTypeFilter.all, tr('Все'), Icons.apps_rounded, w.stats.total),
      (
        LibraryTypeFilter.recent,
        tr('Недавние'),
        Icons.schedule_rounded,
        w.stats.recent,
      ),
      (
        LibraryTypeFilter.marketDownloaded,
        tr('Маркет'),
        Icons.shop_rounded,
        w.stats.market,
      ),
      (
        LibraryTypeFilter.local,
        tr('Локальные'),
        Icons.devices_other_rounded,
        w.stats.local,
      ),
      if (w.stats.corrupted > 0)
        (
          LibraryTypeFilter.corrupted,
          tr('Повреждённые'),
          Icons.error_outline_rounded,
          w.stats.corrupted,
        ),
    ];

    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final e = entries[i];
          final isSelected = w.active == e.$1;
          return M3EChip(
            label: '${e.$2} · ${e.$4}',
            type: M3EChipType.filter,
            leading: Icon(
              _flash == e.$1 ? Icons.check_rounded : e.$3,
              size: 18,
            ),
            selected: isSelected,
            onPressed: () => _select(e.$1),
          );
        },
      ),
    );
  }
}

// ============================================================================
//  СТАТУС СИНХРОНИЗАЦИИ
// ============================================================================

class _SyncStatusCard extends StatelessWidget {
  final QuestSyncState state;
  final VoidCallback onSync;
  final VoidCallback onConfigure;

  const _SyncStatusCard({
    required this.state,
    required this.onSync,
    required this.onConfigure,
  });

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final enabled = state.settings.enabled;
    final configured = state.settings.isConfigured;

    if (!enabled || !configured) {
      return M3ECard(
        variant: M3ECardVariant.filled,
        onPressed: onConfigure,
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.cloud_off_rounded,
                  color: scheme.onSecondaryContainer,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      configured
                          ? tr('Облачная синхронизация выключена')
                          : tr('Облачная синхронизация не настроена'),
                      style: m3e.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      configured
                          ? tr(
                              'Включите, чтобы держать квесты в актуальном виде',
                            )
                          : tr('Подключите облако, чтобы не потерять прогресс'),
                      style: m3e.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      );
    }

    final hasError = state.error != null && state.error!.isNotEmpty;

    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: hasError
                        ? scheme.errorContainer
                        : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    state.isSyncing
                        ? Icons.sync_rounded
                        : (hasError
                              ? Icons.sync_problem_rounded
                              : Icons.cloud_done_rounded),
                    color: hasError
                        ? scheme.onErrorContainer
                        : scheme.onPrimaryContainer,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.displayStatus,
                    style: m3e.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                M3EButton(
                  label: Text(tr('Синк')),
                  icon: const Icon(Icons.refresh_rounded),
                  style: M3EButtonStyle.tonal,
                  size: M3EButtonSize.xs,
                  onPressed: state.isSyncing ? null : onSync,
                ),
              ],
            ),
            if (state.isSyncing) ...[
              const SizedBox(height: 8),
              M3EProgressIndicator.linear(
                value: state.progress <= 0 ? null : state.progress,
              ),
            ],
            if (hasError) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  state.error!,
                  style: m3e.textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  SECTION HEADER
// ============================================================================

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;

  const _SectionHeader({
    required this.title,
    required this.icon,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: scheme.onPrimaryContainer, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: m3e.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(left: 42, top: 2),
              child: Text(
                subtitle!,
                style: m3e.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
//  SORT CHOICE TILE
// ============================================================================

class _SortChoiceTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SortChoiceTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return M3EListItem(
      headline: label,
      leading: Icon(icon),
      trailing: selected ? const Icon(Icons.check_rounded) : null,
      selected: selected,
      onTap: onTap,
    );
  }
}

// ============================================================================
//  КАРТОЧКА КВЕСТА
// ============================================================================

class _QuestListCard extends ConsumerWidget {
  final Quest quest;
  final VoidCallback onTap;
  final VoidCallback onMoreTap;

  const _QuestListCard({
    super.key,
    required this.quest,
    required this.onTap,
    required this.onMoreTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final isCorrupted = quest.isCorrupted;

    return M3ECard(
      variant: isCorrupted ? M3ECardVariant.outlined : M3ECardVariant.filled,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      color: isCorrupted ? scheme.errorContainer.withOpacity(0.25) : null,
      border: isCorrupted
          ? BorderSide(color: scheme.error.withOpacity(0.5))
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _LocalQuestPreviewImage(
              quest: quest,
              width: 480,
              height: 270,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          quest.title,
                          style: m3e.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      _QuestBadges(quest: quest),
                      M3EIconButton(
                        icon: Icon(
                          Icons.more_vert_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                        tooltip: tr('Действия'),
                        variant: M3EIconButtonVariant.standard,
                        size: M3EIconButtonSize.xs,
                        onPressed: onMoreTap,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        isCorrupted
                            ? Icons.error_outline_rounded
                            : Icons.person_outline_rounded,
                        size: 14,
                        color: isCorrupted
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          isCorrupted
                              ? friendlyError(
                                  quest.loadError ??
                                      tr('Ошибка чтения config.json'),
                                )
                              : (quest.author ?? tr('Локальный проект')),
                          style: m3e.textTheme.bodySmall?.copyWith(
                            color: isCorrupted
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (quest.lastOpened != null && !isCorrupted)
                    Row(
                      children: [
                        Icon(
                          Icons.schedule_rounded,
                          size: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            trf('Открыт {p0}', {
                              'p0': formatRelativeTime(quest.lastOpened!),
                            }),
                            overflow: TextOverflow.ellipsis,
                            style: m3e.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  Consumer(
                    builder: (context, childRef, _) {
                      return FutureBuilder<int>(
                        future: childRef
                            .read(playtimeServiceProvider)
                            .getQuestPlaytime(quest.id),
                        builder: (context, snapshot) {
                          final playtime = snapshot.data ?? 0;
                          return Row(
                            children: [
                              Icon(
                                Icons.timer_outlined,
                                size: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  trf('Вы играли: {p0}', {
                                    'p0': PlaytimeFormatter.format(playtime),
                                  }),
                                  overflow: TextOverflow.ellipsis,
                                  style: m3e.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestBadges extends StatelessWidget {
  final Quest quest;
  const _QuestBadges({required this.quest});

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    final badges = <Widget>[];

    if (quest.isMarketDownloaded) {
      badges.add(
        _Badge(
          icon: Icons.shop_rounded,
          tooltip: tr('Из маркета'),
          color: scheme.tertiaryContainer,
          iconColor: scheme.onTertiaryContainer,
        ),
      );
    }
    if (quest.isReadOnly && !quest.isMarketDownloaded) {
      badges.add(
        _Badge(
          icon: Icons.lock_outline_rounded,
          tooltip: tr('Только для чтения'),
          color: scheme.secondaryContainer,
          iconColor: scheme.onSecondaryContainer,
        ),
      );
    }
    if (quest.isCorrupted) {
      badges.add(
        _Badge(
          icon: Icons.error_outline_rounded,
          tooltip: tr('Повреждён'),
          color: scheme.errorContainer,
          iconColor: scheme.onErrorContainer,
        ),
      );
    }

    if (badges.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < badges.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          badges[i],
        ],
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final Color iconColor;

  const _Badge({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return M3ETooltip(
      message: tooltip,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 13, color: iconColor),
      ),
    );
  }
}

// ============================================================================
//  ВИДЖЕТ ПРЕВЬЮ
// ============================================================================

class _LocalQuestPreviewImage extends StatelessWidget {
  final Quest quest;
  final double height;
  final double width;

  const _LocalQuestPreviewImage({
    required this.quest,
    this.height = 76,
    this.width = 76,
  });

  @override
  Widget build(BuildContext context) {
    if (quest.localPreviewPath != null && quest.localPreviewPath!.isNotEmpty) {
      final file = File(quest.localPreviewPath!);
      return Image.file(
        file,
        fit: BoxFit.cover,
        width: width,
        height: height,
        cacheWidth: (width * 2).toInt(),
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: child,
            ),
        errorBuilder: (_, __, ___) => _buildPlaceholder(context),
      );
    }
    return _buildPlaceholder(context);
  }

  Widget _buildPlaceholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: 28,
          color: scheme.onSurfaceVariant.withOpacity(0.4),
        ),
      ),
    );
  }
}

// ============================================================================
//  SHIMMER (плейсхолдер во время загрузки)
// ============================================================================

class _QuestCardShimmer extends StatelessWidget {
  const _QuestCardShimmer();

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(color: scheme.surfaceContainerHigh),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 18,
                    width: 160,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 12,
                    width: 100,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    height: 12,
                    width: 140,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  ПУСТОЕ СОСТОЯНИЕ
// ============================================================================

class _EmptyLibraryState extends StatelessWidget {
  final bool isSearching;
  final VoidCallback onCreate;
  final VoidCallback onImport;

  const _EmptyLibraryState({
    required this.isSearching,
    required this.onCreate,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    return Center(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isSearching
                  ? Icons.search_off_rounded
                  : Icons.auto_stories_outlined,
              size: 56,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            isSearching ? tr('Ничего не найдено') : tr('Здесь пока пусто'),
            style: m3e.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              isSearching
                  ? tr('Попробуйте изменить запрос или сбросить фильтры')
                  : tr('Создайте свой первый квест или импортируйте файл .mnd'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
          if (!isSearching) ...[
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                M3EButton(
                  label: Text(tr('Создать квест')),
                  icon: const Icon(Icons.add_rounded),
                  style: M3EButtonStyle.filled,
                  onPressed: onCreate,
                ),
                M3EButton(
                  label: Text(tr('Импортировать .mnd')),
                  icon: const Icon(Icons.file_upload_outlined),
                  style: M3EButtonStyle.outlined,
                  onPressed: onImport,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
//  ОШИБКА БИБЛИОТЕКИ
// ============================================================================

/// Почему библиотека не открылась — фразой, а не дампом.
///
/// Сеть здесь ни при чём: квесты лежат в папке приложения, поэтому в эту
/// ветку попадают `FileSystemException`, `MissingPluginException` и прочие
/// дампы `dart:io` с путём и `errno`. Экран печатал `'$err'` как есть — и
/// человек, который только что установил Meander и открыл вкладку «Мои»,
/// видел на первом же экране трейс и ни одной кнопки.
String libraryLoadErrorText(Object error) {
  if (looksLikeStorageFailure(error)) {
    return tr(
      'Приложение не может прочитать свою папку с квестами на устройстве. Проверьте свободное место и разрешите Meander хранить файлы.',
    );
  }
  return friendlyError(error);
}

class _LibraryErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _LibraryErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    return Center(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.folder_off_outlined,
              size: 56,
              color: scheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            tr('Библиотека не открылась'),
            style: m3e.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              libraryLoadErrorText(error),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 18),
          M3EButton(
            key: const Key('library-retry'),
            label: Text(tr('Повторить')),
            icon: const Icon(Icons.refresh_rounded),
            style: M3EButtonStyle.filled,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
