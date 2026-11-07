import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/services/async_backup_service.dart';
import 'package:canvas_app/core/services/async_import_service.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:canvas_app/features/quests/widgets/quest_export_format_dialog.dart';
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
import 'package:canvas_app/features/quests/widgets/continue_shelf.dart';
import 'package:canvas_app/features/quests/providers/quest_sync_provider.dart';
import 'package:canvas_app/features/quests/screens/create_quest_screen.dart';
import 'package:canvas_app/features/quests/screens/edit_quest_screen.dart';
import 'package:canvas_app/features/quests/screens/quest_details_screen.dart';
import 'package:canvas_app/features/quests/screens/cloud_sync_settings_screen.dart';
import 'package:canvas_app/features/quests/screens/quest_sync_settings_screen.dart';
import 'package:canvas_app/features/onboarding/controllers/tutorial_controller.dart';
import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:canvas_app/shared/adwaita/adw.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

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
    final nodesFormat = await showQuestExportFormatDialog(context);
    if (nodesFormat == null || !mounted) return;
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
        nodesFormat: nodesFormat,
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
    // Шторка Adwaita: AdwPreferencesGroup со строками AdwActionRow, фон окна.
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      showDragHandle: true,
      backgroundColor: context.adw.window,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                quest.title,
                style: context.adw.title1,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 14),
              AdwGroup(
                children: [
                  if (!quest.isReadOnly || quest.isCorrupted)
                    AdwActionRow(
                      icon: AdwIcons.import,
                      title: tr('Экспортировать (.mnd)'),
                      subtitle: tr('Копия квеста без сохранений'),
                      onTap: () {
                        Navigator.pop(context);
                        _exportQuest(quest);
                      },
                    ),
                  if (!quest.isReadOnly || quest.isCorrupted)
                    AdwActionRow(
                      icon: AdwIcons.archive,
                      title: tr('Бэкап (с сохранениями)'),
                      subtitle: tr('Включая игровой прогресс'),
                      onTap: () {
                        Navigator.pop(context);
                        _exportQuest(quest, includeSaves: true);
                      },
                    ),
                  if (!quest.isCorrupted)
                    AdwActionRow(
                      icon: AdwIcons.print,
                      title: tr('Экспортировать в PDF'),
                      subtitle: tr('Книга с содержанием и якорями'),
                      onTap: () {
                        Navigator.pop(context);
                        _exportQuestAsPdf(quest);
                      },
                    ),
                  if (!quest.isReadOnly &&
                      !quest.isMarketDownloaded &&
                      !quest.isCorrupted)
                    AdwActionRow(
                      icon: AdwIcons.edit,
                      title: tr('Редактировать'),
                      onTap: () {
                        Navigator.pop(context);
                        _editQuest(quest);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              AdwGroup(
                children: [
                  AdwActionRow(
                    icon: AdwIcons.delete,
                    title: tr('Удалить квест'),
                    destructive: true,
                    onTap: () {
                      Navigator.pop(context);
                      _confirmDeleteQuest(quest);
                    },
                  ),
                ],
              ),
            ],
          ),
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
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.adw.window,
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
                    Text(tr('Сортировка'), style: context.adw.title1),
                    const SizedBox(height: 14),
                    // AdwPreferencesGroup: строки в одной плашке, разделители —
                    // волосяные линии, выбранная строка с галочкой.
                    AdwGroup(
                      children: [
                        _SortChoiceTile(
                          label: tr('По алфавиту А–Я'),
                          icon: AdwIcons.sort,
                          selected: _sort == LibrarySort.az,
                          onTap: () => setSheet(() => _sort = LibrarySort.az),
                        ),
                        _SortChoiceTile(
                          label: tr('По алфавиту Я–А'),
                          icon: AdwIcons.sort,
                          selected: _sort == LibrarySort.za,
                          onTap: () => setSheet(() => _sort = LibrarySort.za),
                        ),
                        _SortChoiceTile(
                          label: tr('По дате создания'),
                          icon: AdwIcons.archive,
                          selected: _sort == LibrarySort.createdDate,
                          onTap: () =>
                              setSheet(() => _sort = LibrarySort.createdDate),
                        ),
                        _SortChoiceTile(
                          label: tr('По дате последнего открытия'),
                          icon: AdwIcons.recent,
                          selected: _sort == LibrarySort.openedDate,
                          onTap: () =>
                              setSheet(() => _sort = LibrarySort.openedDate),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_sort == LibrarySort.createdDate ||
                        _sort == LibrarySort.openedDate)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('Порядок'), style: context.adw.captionStrong),
                          const SizedBox(height: 8),
                          AdwViewSwitcher(
                            items: [
                              AdwSwitcherItem(label: tr('Сначала новые')),
                              AdwSwitcherItem(label: tr('Сначала старые')),
                            ],
                            selectedIndex: _isDescending ? 0 : 1,
                            onSelected: (i) =>
                                setSheet(() => _isDescending = i == 0),
                          ),
                        ],
                      ),
                    const SizedBox(height: 20),
                    AdwButton(
                      variant: AdwButtonVariant.suggested,
                      pill: true,
                      expanded: true,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      onPressed: () {
                        setState(() {});
                        Navigator.pop(ctx);
                      },
                      child: Text(tr('Применить')),
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
    // Всплывающее уведомление Adwaita: тёмная карточка-тост, не цветная плашка
    // Material. Ошибка — единственное исключение, у неё красный акцент.
    final bg = error
        ? context.adw.destructive
        : (success ? context.adw.cardHover : context.adw.card);
    final fg = context.adw.fg;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: context.adw.body),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AdwRadius.card),
          side: error ? BorderSide.none : BorderSide(color: context.adw.border),
        ),
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
    // «Продолжить»: свежие сессии, которые ещё не потеряли смысл открывать.
    final recentQuests = questsAsync.maybeWhen(
      data: (list) {
        final recent =
            list.where((q) => q.lastOpened != null && !q.isCorrupted).toList()
              ..sort(
                (a, b) => (b.lastOpened ?? DateTime(1970)).compareTo(
                  a.lastOpened ?? DateTime(1970),
                ),
              );
        return recent.take(6).toList();
      },
      orElse: () => const <Quest>[],
    );

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

    return PopScope(
      canPop: !_isFiltering,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _clearFilters();
      },
      child: Scaffold(
        backgroundColor: context.adw.window,
        body: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final isCompact = width < _kCompactBreakpoint;
              // Читаемая колонка: на широком окне полка не растягивается,
              // иначе строки превращаются в километровые полосы.
              final hPad = width > 820
                  ? (width - 760) / 2
                  : (isCompact ? 16.0 : 24.0);

              return RefreshIndicator(
                onRefresh: _refreshAll,
                color: context.adw.accent,
                backgroundColor: context.adw.card,
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  slivers: [
                    _buildAppBar(),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 16),
                        child: _LibraryHero(
                          stats: libraryStats,
                          isSyncing: syncState.isSyncing,
                          syncEnabled: syncState.settings.enabled,
                          isOperationInProgress: _isOperationInProgress,
                          onOpenLibrary: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const MyLibraryScreen(),
                            ),
                          ),
                          onOpenPresets: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const LocalPresetsScreen(),
                            ),
                          ),
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
                    if (recentQuests.isNotEmpty && !_isFiltering)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: ContinueShelf(
                            quests: recentQuests,
                            onOpen: _openQuest,
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
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: hPad),
                        child: _LibraryFilterChipsRow(
                          active: _typeFilter,
                          stats: libraryStats,
                          onSelected: (f) => setState(() => _typeFilter = f),
                        ),
                      ),
                    ),
                    // Плашку про облако показываем только тогда, когда терять
                    // уже есть: новичок с пустой библиотекой получал
                    // «Подключите облако, чтобы не потерять прогресс» первым
                    // же экраном — и туда, где он ещё ничего не сделал.
                    if (libraryStats.total > 0)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 0),
                          child: _SyncStatusCard(
                            state: syncState,
                            onSync: () =>
                                ref.read(questSyncProvider.notifier).syncNow(),
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
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: hPad),
                        child: _SectionHeader(
                          title: _sectionTitle(),
                          subtitle: _sectionSubtitle(),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 10)),
                    _buildQuestsSliver(questsAsync, hPad: hPad),
                    const SliverPadding(padding: EdgeInsets.only(bottom: 20)),
                  ],
                ),
              );
            },
          ),
        ),
        bottomNavigationBar: _buildCreateBar(),
      ),
    );
  }

  /// «+ Создать квест» — широкая пилюля над навигацией, как suggested-action
  /// в libadwaita. Ключ обучения (`_createFabKey`) переехал сюда же.
  Widget _buildCreateBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: AdwButton(
          key: _createFabKey,
          variant: AdwButtonVariant.suggested,
          pill: true,
          expanded: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed: _isOperationInProgress ? null : _navigateToCreateQuest,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AdwIcon(AdwIcons.add, size: 16, color: context.adw.fg),
              const SizedBox(width: 8),
              Text(tr('Создать квест')),
            ],
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
      toolbarHeight: 52,
      automaticallyImplyLeading: false,
      leadingWidth: 56,
      leading: (!widget.isRoot || _isFiltering)
          ? Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Center(
                child: AdwIconButton(
                  icon: AdwIcons.back,
                  tooltip: _isFiltering
                      ? tr('Сбросить фильтр')
                      : tr('Назад'),
                  onPressed: _isFiltering
                      ? _clearFilters
                      : () => Navigator.pop(context),
                ),
              ),
            )
          : null,
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

  Widget _buildQuestsSliver(
    AsyncValue<List<Quest>> async, {
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
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenPresets;
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
    required this.onOpenLibrary,
    required this.onOpenPresets,
    required this.onSync,
    required this.onSyncLongPress,
    required this.onImport,
    required this.onBackup,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    // Adwaita-шапка: title-1, счётчики под ним, ниже строка icon-кнопок —
    // как headerbar в GNOME, только без системных кнопок окна.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Моя библиотека'), style: context.adw.title1),
        const SizedBox(height: 3),
        Text(_buildSubtitle(), style: context.adw.caption),
        const SizedBox(height: 12),
        Row(
          children: [
            AdwIconButton(
              icon: AdwIcons.library,
              tooltip: tr('Моя библиотека'),
              onPressed: onOpenLibrary,
            ),
            AdwIconButton(
              icon: AdwIcons.presets,
              tooltip: tr('Локальные пресеты'),
              onPressed: onOpenPresets,
            ),
            AdwIconButton(
              icon: AdwIcons.sync,
              tooltip: tr('Синк'),
              selected: syncEnabled,
              onPressed: isSyncing ? null : onSync,
              onLongPress: onSyncLongPress,
              overlay: isSyncing
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.adw.fgDim,
                      ),
                    )
                  : null,
            ),
            AdwIconButton(
              icon: AdwIcons.import,
              tooltip: tr('Импорт'),
              onPressed: onImport,
              overlay: isOperationInProgress
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.adw.fgDim,
                      ),
                    )
                  : null,
            ),
            _HeroMenuButton(onBackup: onBackup, onRestore: onRestore),
          ],
        ),
      ],
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

class _HeroMenuButton extends StatelessWidget {
  final VoidCallback? onBackup;
  final VoidCallback? onRestore;
  const _HeroMenuButton({required this.onBackup, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.adw.card),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AdwRadius.card),
            side: BorderSide(color: context.adw.border),
          ),
        ),
      ),
      menuChildren: [
        _AdwMenuItem(
          icon: AdwIcons.archive,
          label: tr('Бэкап всех квестов'),
          onTap: onBackup,
        ),
        _AdwMenuItem(
          icon: AdwIcons.restore,
          label: tr('Восстановить из бэкапа'),
          onTap: onRestore,
        ),
      ],
      builder: (context, controller, _) => AdwIconButton(
        icon: AdwIcons.menu,
        tooltip: tr('Резервные копии'),
        selected: controller.isOpen,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Пункт всплывающего меню Adwaita: иконка + подпись, `MenuItemButton` без
/// Material-подсветки.
class _AdwMenuItem extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback? onTap;

  const _AdwMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MenuItemButton(
      onPressed: onTap,
      style: ButtonStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: WidgetStatePropertyAll(context.adw.hover),
        foregroundColor: WidgetStatePropertyAll(context.adw.fg),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(200, 0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AdwIcon(
            icon,
            size: 15,
            color: onTap == null
                ? context.adw.fgDim.withValues(alpha: 0.4)
                : context.adw.fgDim,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: context.adw.body.copyWith(
              color: onTap == null
                  ? context.adw.fg.withValues(alpha: 0.4)
                  : context.adw.fg,
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
    final hasText = widget.controller.text.isNotEmpty;
    return AdwSearchEntry(
      controller: widget.controller,
      focusNode: widget.focusNode,
      hint: tr('Поиск по названию, автору, описанию…'),
      onChanged: widget.onChanged,
      trailing: AdwIconButton(
        icon: hasText ? AdwIcons.clear : AdwIcons.sort,
        tooltip: hasText ? tr('Очистить') : tr('Сортировка'),
        onPressed: hasText ? widget.onClear : widget.onSortTap,
        size: 32,
        iconSize: 14,
      ),
    );
  }
}

// ============================================================================
//  ЧИПЫ ФИЛЬТРОВ ТИПА
// ============================================================================

class _LibraryFilterChipsRow extends StatelessWidget {
  final LibraryTypeFilter active;
  final ValueChanged<LibraryTypeFilter> onSelected;
  final _LibraryStats stats;

  const _LibraryFilterChipsRow({
    required this.active,
    required this.onSelected,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final entries = <(LibraryTypeFilter, String, int)>[
      (LibraryTypeFilter.all, tr('Все'), stats.total),
      (LibraryTypeFilter.recent, tr('Недавние'), stats.recent),
      (LibraryTypeFilter.marketDownloaded, tr('Маркет'), stats.market),
      (LibraryTypeFilter.local, tr('Локальные'), stats.local),
      if (stats.corrupted > 0)
        (LibraryTypeFilter.corrupted, tr('Повреждённые'), stats.corrupted),
    ];
    final selectedIndex = entries.indexWhere((e) => e.$1 == active);
    // AdwViewSwitcher: капсула-подложка, выбранный сегмент — карточка с тенью.
    return AdwViewSwitcher(
      selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
      onSelected: (i) => onSelected(entries[i].$1),
      items: [
        for (final entry in entries)
          AdwSwitcherItem(label: entry.$2, count: entry.$3),
      ],
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
    final enabled = state.settings.enabled;
    final configured = state.settings.isConfigured;

    // Не настроено/выключено — мягкий баннер с переходом в настройки.
    if (!enabled || !configured) {
      return AdwBanner(
        icon: AdwIcons.cloudOff,
        title: configured
            ? tr('Облачная синхронизация выключена')
            : tr('Облачная синхронизация не настроена'),
        subtitle: configured
            ? tr('Включите, чтобы держать квесты в актуальном виде')
            : tr('Подключите облако, чтобы не потерять прогресс'),
        onTap: onConfigure,
        showChevron: true,
      );
    }

    final hasError = state.error != null && state.error!.isNotEmpty;

    return AdwBanner(
      icon: hasError ? AdwIcons.warning : AdwIcons.sync,
      tone: hasError ? AdwBannerTone.error : AdwBannerTone.neutral,
      title: state.displayStatus,
      subtitle: hasError ? state.error : null,
      progress: state.isSyncing ? state.progress : null,
      actionLabel: hasError ? null : tr('Синк'),
      onAction: state.isSyncing ? null : onSync,
      trailing: state.isSyncing
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.adw.fgDim,
              ),
            )
          : null,
    );
  }
}

// ============================================================================
//  SECTION HEADER
// ============================================================================

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _SectionHeader({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    // `.heading` Adwaita: капс, разрядка, приглушённый цвет. Иконка раздела
    // ушла — в GNOME заголовок списка её не носит.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdwSectionLabel(title: title),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(subtitle!, style: context.adw.caption),
          ),
      ],
    );
  }
}

// ============================================================================
//  SORT CHOICE TILE
// ============================================================================

class _SortChoiceTile extends StatelessWidget {
  final String label;
  final String icon;
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
    return AdwActionRow(
      icon: icon,
      title: label,
      onTap: onTap,
      trailing: selected
          ? AdwIcon(AdwIcons.check, size: 15, color: context.adw.accent)
          : const SizedBox.shrink(),
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
    final isCorrupted = quest.isCorrupted;
    // AdwActionRow в карточке: обложка 48×62, title-3, две строки подписи
    // (автор, «Открыт … · Вы играли: …») и меню действий справа.
    return AdwCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      color: isCorrupted
          ? Color.alphaBlend(
              context.adw.destructive.withValues(alpha: 0.12),
              context.adw.card,
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AdwRadius.control),
            child: _LocalQuestPreviewImage(
              quest: quest,
              width: 48,
              height: 62,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        quest.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.adw.bodyStrong.copyWith(fontSize: 15),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _QuestBadges(quest: quest),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    AdwIcon(
                      isCorrupted ? AdwIcons.warning : AdwIcons.author,
                      size: 12,
                      color: isCorrupted
                          ? context.adw.destructive
                          : context.adw.fgDim,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        isCorrupted
                            ? friendlyError(
                                quest.loadError ??
                                    tr('Ошибка чтения config.json'),
                              )
                            : (quest.author ?? tr('Локальный проект')),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.adw.caption.copyWith(
                          fontSize: 12,
                          color: isCorrupted
                              ? context.adw.destructive
                              : context.adw.fgDim,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                Consumer(
                  builder: (context, childRef, _) {
                    return FutureBuilder<int>(
                      future: childRef
                          .read(playtimeServiceProvider)
                          .getQuestPlaytime(quest.id),
                      builder: (context, snapshot) {
                        final playtime = snapshot.data ?? 0;
                        final parts = <String>[
                          if (quest.lastOpened != null && !isCorrupted)
                            trf('Открыт {p0}', {
                              'p0': formatRelativeTime(quest.lastOpened!),
                            }),
                          if (playtime > 0)
                            trf('Вы играли: {p0}', {
                              'p0': PlaytimeFormatter.format(playtime),
                            }),
                        ];
                        if (parts.isEmpty) return const SizedBox.shrink();
                        return Text(
                          parts.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.adw.caption.copyWith(fontSize: 12),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
          AdwIconButton(
            icon: AdwIcons.menu,
            tooltip: tr('Действия'),
            onPressed: onMoreTap,
            iconSize: 15,
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
    final badges = <Widget>[];

    if (quest.isMarketDownloaded) {
      badges.add(
        _Badge(
          icon: AdwIcons.market,
          tooltip: tr('Из маркета'),
          tone: _BadgeTone.accent,
        ),
      );
    }
    if (quest.isReadOnly && !quest.isMarketDownloaded) {
      badges.add(
        _Badge(
          icon: AdwIcons.lock,
          tooltip: tr('Только для чтения'),
          tone: _BadgeTone.neutral,
        ),
      );
    }
    if (quest.isCorrupted) {
      badges.add(
        _Badge(
          icon: AdwIcons.error,
          tooltip: tr('Повреждён'),
          tone: _BadgeTone.error,
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

enum _BadgeTone { neutral, accent, error }

class _Badge extends StatelessWidget {
  final String icon;
  final String tooltip;
  final _BadgeTone tone;

  const _Badge({
    required this.icon,
    required this.tooltip,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (tone) {
      _BadgeTone.neutral => (context.adw.active, context.adw.fgDim),
      _BadgeTone.accent => (
        context.adw.accent.withValues(alpha: 0.22),
        const Color(0xFF8AB8F2),
      ),
      _BadgeTone.error => (
        context.adw.destructive.withValues(alpha: 0.22),
        const Color(0xFFF66151),
      ),
    };
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: AdwIcon(icon, size: 11, color: foreground),
        ),
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
    return Container(
      width: width,
      height: height,
      color: context.adw.active,
      child: Center(
        child: AdwIcon(
          AdwIcons.image,
          size: 20,
          color: context.adw.fgDim.withValues(alpha: 0.45),
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
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: context.adw.active,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      decoration: BoxDecoration(
        color: context.adw.card,
        borderRadius: BorderRadius.circular(AdwRadius.card),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 62,
            decoration: BoxDecoration(
              color: context.adw.active,
              borderRadius: BorderRadius.circular(AdwRadius.control),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                bar(150, 13),
                const SizedBox(height: 8),
                bar(96, 11),
                const SizedBox(height: 6),
                bar(120, 11),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AdwIcon(
          isSearching ? AdwIcons.search : AdwIcons.library,
          size: 44,
          color: context.adw.fgDim.withValues(alpha: 0.45),
        ),
        const SizedBox(height: 14),
        Text(
          isSearching ? tr('Ничего не найдено') : tr('Здесь пока пусто'),
          style: context.adw.title1.copyWith(fontSize: 18),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          isSearching
              ? tr('Попробуйте изменить запрос или сбросить фильтры')
              : tr('Создайте свой первый квест или импортируйте файл .mnd'),
          textAlign: TextAlign.center,
          style: context.adw.caption.copyWith(fontSize: 13.5, height: 1.4),
        ),
        if (!isSearching) ...[
          const SizedBox(height: 18),
          AdwButton(
            variant: AdwButtonVariant.suggested,
            pill: true,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            onPressed: onCreate,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AdwIcon(AdwIcons.add, size: 14, color: context.adw.fg),
                const SizedBox(width: 6),
                Text(tr('Создать квест')),
              ],
            ),
          ),
          const SizedBox(height: 8),
          AdwButton(
            variant: AdwButtonVariant.flat,
            pill: true,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            onPressed: onImport,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AdwIcon(AdwIcons.import, size: 14, color: context.adw.fg),
                const SizedBox(width: 6),
                Text(tr('Импортировать .mnd')),
              ],
            ),
          ),
        ],
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AdwIcon(
          AdwIcons.warning,
          size: 44,
          color: context.adw.destructive,
        ),
        const SizedBox(height: 14),
        Text(
          tr('Библиотека не открылась'),
          style: context.adw.title1.copyWith(fontSize: 18),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          libraryLoadErrorText(error),
          textAlign: TextAlign.center,
          style: context.adw.caption.copyWith(fontSize: 13.5, height: 1.4),
        ),
        const SizedBox(height: 18),
        AdwButton(
          key: const Key('library-retry'),
          variant: AdwButtonVariant.regular,
          pill: true,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
          onPressed: onRetry,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AdwIcon(AdwIcons.sync, size: 14, color: context.adw.fg),
              const SizedBox(width: 6),
              Text(tr('Повторить')),
            ],
          ),
        ),
      ],
    );
  }
}
