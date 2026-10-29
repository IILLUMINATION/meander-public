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
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

// ============================================================================
//  БИБЛИОТЕКА — Material You / Material 3 редизайн
// ============================================================================

const double _kCompactBreakpoint = 600;
const double _kMediumBreakpoint = 900;

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
    final theme = Theme.of(context);
    _m3eTheme = theme.brightness == Brightness.dark
        ? M3EThemeData.dark(seedColor: theme.colorScheme.primary)
        : M3EThemeData.light(seedColor: theme.colorScheme.primary);
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
            builder: (ctx) => AlertDialog(
              title: Text(tr('Обнаружен конфликт')),
              content: Text(
                trf(
                  'Квест «{questTitle}» уже существует. Заменить его версией из бэкапа?',
                  {'questTitle': questTitle},
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('Пропустить')),
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(tr('Заменить')),
                ),
              ],
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
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            _refreshProgressDialog = setDialogState;
            final scheme = Theme.of(ctx).colorScheme;
            final progress = _operationProgress;
            return Dialog(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 28,
                  horizontal: 28,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (progress == null)
                      CircularProgressIndicator(color: scheme.primary)
                    else ...[
                      LinearProgressIndicator(
                        value: progress,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${(progress * 100).round()}%',
                        style: Theme.of(ctx).textTheme.labelMedium,
                      ),
                    ],
                    const SizedBox(height: 20),
                    Text(
                      _operationStatus,
                      textAlign: TextAlign.center,
                      style: Theme.of(ctx).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            );
          },
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
    final scheme = Theme.of(context).colorScheme;
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!quest.isReadOnly || quest.isCorrupted)
              ListTile(
                leading: Icon(Icons.share_rounded, color: scheme.onSurface),
                title: Text(tr('Экспортировать (.mnd)')),
                subtitle: Text(tr('Копия квеста без сохранений')),
                onTap: () {
                  Navigator.pop(context);
                  _exportQuest(quest);
                },
              ),
            if (!quest.isReadOnly || quest.isCorrupted)
              ListTile(
                leading: Icon(Icons.save_rounded, color: scheme.onSurface),
                title: Text(tr('Бэкап (с сохранениями)')),
                subtitle: Text(tr('Включая игровой прогресс')),
                onTap: () {
                  Navigator.pop(context);
                  _exportQuest(quest, includeSaves: true);
                },
              ),
            if (!quest.isCorrupted)
              ListTile(
                leading: Icon(
                  Icons.picture_as_pdf_rounded,
                  color: scheme.onSurface,
                ),
                title: Text(tr('Экспортировать в PDF')),
                subtitle: Text(tr('Книга с содержанием и якорями')),
                onTap: () {
                  Navigator.pop(context);
                  _exportQuestAsPdf(quest);
                },
              ),
            if (!quest.isReadOnly &&
                !quest.isMarketDownloaded &&
                !quest.isCorrupted)
              ListTile(
                leading: Icon(Icons.edit_rounded, color: scheme.onSurface),
                title: Text(tr('Редактировать')),
                onTap: () {
                  Navigator.pop(context);
                  _editQuest(quest);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
              title: Text(
                tr('Удалить квест'),
                style: TextStyle(color: scheme.error),
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
    );
  }

  Future<void> _confirmDeleteQuest(Quest quest) async {
    final scheme = Theme.of(context).colorScheme;
    bool alsoDeleteRemote = true;
    final result = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('Удалить квест?')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                trf(
                  'Квест «{p0}» будет удалён с устройства. Это действие необратимо.',
                  {'p0': quest.title},
                ),
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: alsoDeleteRemote,
                onChanged: (v) => setLocal(() => alsoDeleteRemote = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  tr('Также удалить из облака'),
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  tr('Если выключить — в облаке останется бэкап'),
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
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
              child: Text(tr('Удалить')),
            ),
          ],
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
    final scheme = Theme.of(context).colorScheme;
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      builder: (_) {
        return StatefulBuilder(
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
                        Icon(Icons.tune_rounded, color: scheme.primary),
                        const SizedBox(width: 10),
                        Text(
                          tr('Сортировка'),
                          style: Theme.of(ctx).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            tr('Порядок'),
                            style: Theme.of(ctx).textTheme.titleSmall,
                          ),
                          SegmentedButton<bool>(
                            segments: [
                              ButtonSegment(
                                value: true,
                                label: Text(tr('Сначала новые')),
                                icon: Icon(Icons.arrow_downward_rounded),
                              ),
                              ButtonSegment(
                                value: false,
                                label: Text(tr('Сначала старые')),
                                icon: Icon(Icons.arrow_upward_rounded),
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
                      child: FilledButton.icon(
                        onPressed: () {
                          setState(() {});
                          Navigator.pop(ctx);
                        },
                        icon: const Icon(Icons.check_rounded),
                        label: Text(tr('Применить')),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSnack(String text, {bool success = false, bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    Color? bg;
    Color? fg;
    if (success) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
    } else if (error) {
      bg = scheme.error;
      fg = scheme.onError;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        closeIconColor: fg,
      ),
    );
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

    final scheme = Theme.of(context).colorScheme;

    return M3ETheme(
      data: _m3eTheme,
      child: PopScope(
        canPop: !_isFiltering,
        onPopInvoked: (didPop) {
          if (didPop) return;
          _clearFilters();
        },
        child: Scaffold(
          backgroundColor: scheme.surface,
          body: SafeArea(
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final isCompact = width < _kCompactBreakpoint;
                final isMedium = width >= _kMediumBreakpoint;
                final hPad = isCompact ? 16.0 : 24.0;

                return RefreshIndicator(
                  onRefresh: _refreshAll,
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    slivers: [
                      _buildAppBar(),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 16),
                          child: _LibraryHero(
                            stats: libraryStats,
                            isSyncing: syncState.isSyncing,
                            syncEnabled: syncState.settings.enabled,
                            isOperationInProgress: _isOperationInProgress,
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
                      _buildQuestsSliver(
                        questsAsync,
                        isMedium: isMedium,
                        hPad: hPad,
                      ),
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

  SliverAppBar _buildAppBar() {
    return SliverAppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      pinned: false,
      floating: true,
      snap: true,
      toolbarHeight: 56,
      automaticallyImplyLeading: !widget.isRoot && !_isFiltering,
      actions: [
        M3EIconButton(
          icon: const Icon(Icons.collections_bookmark_rounded),
          tooltip: tr('Моя библиотека'),
          variant: M3EIconButtonVariant.standard,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => MyLibraryScreen()),
          ),
        ),
        M3EIconButton(
          icon: const Icon(Icons.smart_button_rounded),
          tooltip: tr('Локальные пресеты'),
          variant: M3EIconButtonVariant.standard,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => LocalPresetsScreen()),
          ),
        ),
      ],
      leading: _isFiltering
          ? M3EIconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: tr('Сбросить фильтр'),
              variant: M3EIconButtonVariant.standard,
              onPressed: _clearFilters,
            )
          : (widget.isRoot
                ? null
                : M3EIconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    variant: M3EIconButtonVariant.standard,
                    onPressed: () => Navigator.pop(context),
                  )),
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
    required bool isMedium,
    required double hPad,
  }) {
    return async.when(
      loading: () => SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: hPad),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, __) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: _QuestCardShimmer(),
            ),
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

        if (isMedium) {
          return SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 420,
                mainAxisExtent: 110,
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
        }

        return SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          sliver: SliverList.separated(
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final quest = filtered[index];
              return _QuestListCard(
                key: keyForQuest(quest),
                quest: quest,
                onTap: () => _openQuest(quest),
                onMoreTap: () => _showQuestOptions(quest),
              );
            },
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

class _LibraryHero extends StatelessWidget {
  final _LibraryStats stats;
  final bool isSyncing;
  final bool syncEnabled;
  final bool isOperationInProgress;
  final VoidCallback onSync;
  final VoidCallback? onSyncLongPress;
  final VoidCallback? onImport;
  final VoidCallback? onBackup;
  final VoidCallback? onRestore;

  const _LibraryHero({
    required this.stats,
    required this.isSyncing,
    required this.syncEnabled,
    required this.isOperationInProgress,
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
    // Высота — по содержимому, но не меньше привычных 160. Раньше рамка была
    // строго 160 px, и на телефоне шириной 360 px подзаголовок переносился на
    // вторую строку: кнопки упираться было некуда, RenderFlex переполнялся
    // ровно на первом экране, который видит новичок.
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: EdgeInsets.zero,
      child: Container(
        constraints: const BoxConstraints(minHeight: 160),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer,
              Color.alphaBlend(
                scheme.secondaryContainer.withOpacity(0.6),
                scheme.primaryContainer,
              ),
            ],
          ),
        ),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              right: -22,
              bottom: -30,
              child: Icon(
                Icons.auto_stories_rounded,
                size: 180,
                color: scheme.onPrimaryContainer.withOpacity(0.10),
              ),
            ),

            // Заголовок и счётчики
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Моя библиотека'),
                    style: m3e.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _buildSubtitle(),
                    style: TextStyle(
                      color: scheme.onPrimaryContainer.withOpacity(0.78),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  // Не Spacer, а фиксированный зазор: колонка теперь минимальной
                  // высоты и не знает, сколько рамка доберёт до 160 px.
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      // Пилюли занимают весь остаток строки: внутри Expanded они
                      // сжимаются на узком экране, но не делят свободное место
                      // со Spacer — иначе неиспанная доля уезжала в конец, и
                      // «3 точки» стояли не у правого края.
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: _HeroActionButton(
                                icon: isSyncing
                                    ? Icons.sync
                                    : (syncEnabled
                                          ? Icons.cloud_done_rounded
                                          : Icons.cloud_off_rounded),
                                label: tr('Синк'),
                                onTap: onSync,
                                onLongPress: onSyncLongPress,
                                busy: isSyncing,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: _HeroActionButton(
                                icon: Icons.file_upload_outlined,
                                label: tr('Импорт'),
                                onTap: onImport,
                                busy: isOperationInProgress,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Симметричный правый зазор: у «Синк» слева есть врезка
                      // от края рамки, а круглая кнопка прилипала к скруглению.
                      Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: _HeroMenuButton(
                          onBackup: onBackup,
                          onRestore: onRestore,
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
    );
  }

  String _buildSubtitle() {
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
}

class _HeroActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool busy;

  const _HeroActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return M3EButton(
      label: Text(label, overflow: TextOverflow.ellipsis),
      icon: busy
          ? const M3EProgressIndicator.circularWavy(size: 16)
          : Icon(icon),
      style: M3EButtonStyle.tonal,
      size: M3EButtonSize.xs,
      onPressed: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
    );
  }
}

class _HeroMenuButton extends StatelessWidget {
  final VoidCallback? onBackup;
  final VoidCallback? onRestore;
  const _HeroMenuButton({required this.onBackup, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    return Material(
      color: scheme.onPrimaryContainer.withOpacity(0.12),
      shape: const CircleBorder(),
      child: PopupMenuButton<String>(
        tooltip: tr('Резервные копии'),
        icon: Icon(Icons.more_horiz_rounded, color: scheme.onPrimaryContainer),
        onSelected: (v) {
          if (v == 'backup') onBackup?.call();
          if (v == 'restore') onRestore?.call();
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'backup',
            enabled: onBackup != null,
            child: ListTile(
              leading: Icon(Icons.archive_outlined),
              title: Text(tr('Бэкап всех квестов')),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: 'restore',
            enabled: onRestore != null,
            child: ListTile(
              leading: Icon(Icons.unarchive_outlined),
              title: Text(tr('Восстановить из бэкапа')),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
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
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: scheme.onSecondaryContainer,
                ),
            ],
          ),
        ),
      ),
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
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: _LocalQuestPreviewImage(
                quest: quest,
                width: 76,
                height: 76,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          quest.title,
                          style: m3e.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _QuestBadges(quest: quest),
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
                  if (quest.lastOpened != null && !isCorrupted) ...[
                    const SizedBox(height: 2),
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
                  ],
                  Consumer(
                    builder: (context, childRef, _) {
                      return FutureBuilder<int>(
                        future: childRef
                            .read(playtimeServiceProvider)
                            .getQuestPlaytime(quest.id),
                        builder: (context, snapshot) {
                          final playtime = snapshot.data ?? 0;
                          return Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
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
                            ),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
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
    return Tooltip(
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 100,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 14,
                  width: 160,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 11,
                  width: 100,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
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
