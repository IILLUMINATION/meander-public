import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/services/export_service.dart';
import 'package:canvas_app/features/quests/widgets/quest_export_format_dialog.dart';
import 'package:canvas_app/core/services/offline_apk_builder.dart';
import 'package:canvas_app/core/services/quest_document_exporter.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/services/save_game_service.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_session.dart';
import 'package:canvas_app/features/editor/workspace/quest_editor_shell.dart';
import 'package:canvas_app/features/game/screens/load_game_screen.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:canvas_app/features/onboarding/controllers/tutorial_controller.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/features/quests/screens/apk_build_options_screen.dart';
import 'package:canvas_app/features/quests/screens/quest_history_screen.dart';
import 'package:canvas_app/features/quests/screens/quest_publish_screen.dart';
import 'package:canvas_app/features/quests/widgets/pdf_export_options_sheet.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/shared/widgets/catalog_shell.dart';

// План 020-C4.5: операции над квестом — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};

// ============================================================================
//  ДЕТАЛИ КВЕСТА — Material 3 редизайн
// ============================================================================
//
//  Концепция:
//   • Hero-обложка как карточка с rounded corners, не fullscreen.
//   • Sticky CTA «Играть» внизу — всегда видим.
//   • Действия разделены на 3 раздела: «Контент», «Управление», «Опасная зона».
//   • Цвета — только из ColorScheme (нет хардкода).
//   • Подтверждения — стандартные M3 AlertDialog без backgroundColor-оверрайдов.
//
// ============================================================================

class QuestDetailsScreen extends ConsumerStatefulWidget {
  final String questId;

  const QuestDetailsScreen({super.key, required this.questId});

  @override
  ConsumerState<QuestDetailsScreen> createState() => _QuestDetailsScreenState();
}

class _QuestDetailsScreenState extends ConsumerState<QuestDetailsScreen> {
  bool _isExporting = false;
  bool _isExportingTxt = false;
  bool _isExportingPdf = false;
  bool _isBuildingApk = false;

  /// Собирать APK офлайн умеет только Android — и только если в сборку
  /// приложения вшит шаблон плеера (это делает CI, см. build_android.yml).
  bool _canBuildApk = false;

  /// Ключ кнопки «Сценарий и Главы» — на неё указывает обучение.
  final GlobalKey _openEditorKey = GlobalKey();

  static const double _heroExpandedHeight = 300;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      unawaited(
        OfflineApkBuilder.isAvailable().then((available) {
          if (mounted) setState(() => _canBuildApk = available);
        }),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(tutorialControllerProvider.notifier)
          .registerTarget(TutorialTargets.openEditorTile, _openEditorKey);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  //  Действия
  // ---------------------------------------------------------------------------

  Future<void> _exportQuest(
    Quest quest, {
    bool includeSaves = false,
    bool isProtected = false,
  }) async {
    if (_isExporting) return;
    final nodesFormat = await showQuestExportFormatDialog(context);
    if (nodesFormat == null || !mounted) return;
    setState(() => _isExporting = true);

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
        isProtected: isProtected,
        nodesFormat: nodesFormat,
      );
      if (!mounted) return;
      if (success) {
        _showSnack(
          isProtected
              ? tr('Защищённый квест экспортирован')
              : tr('Квест успешно экспортирован'),
          success: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        trf('Ошибка экспорта: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportQuestTxt(Quest quest) async {
    if (_isExportingTxt) return;
    setState(() => _isExportingTxt = true);

    try {
      final success = await ExportService.exportQuestAsTxt(
        quest.id,
        quest.title,
      );
      if (!mounted) return;
      if (success) _showSnack(tr('Квест экспортирован в .txt'), success: true);
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        trf('Ошибка экспорта: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isExportingTxt = false);
    }
  }

  Future<void> _exportQuestPdf(Quest quest) async {
    if (_isExportingPdf) return;
    final options = await showPdfExportOptionsSheet(context);
    if (options == null || !mounted) return;

    setState(() => _isExportingPdf = true);
    try {
      final success = await QuestDocumentExporter.exportQuestAsPdf(
        quest.id,
        quest.title,
        options: options,
      );
      if (!mounted) return;
      if (success) {
        _showSnack(tr('PDF-файл сохранён'), success: true);
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        trf('Ошибка экспорта в PDF: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isExportingPdf = false);
    }
  }

  Future<void> _buildApk(Quest quest) async {
    if (_isBuildingApk) return;
    final initial = await OfflineApkBuilder.loadOptions(
      questId: quest.id,
      questTitle: quest.title,
      questVersion: quest.version,
    );
    if (!mounted) return;
    final options = await showApkBuildOptionsScreen(context, initial);
    if (options == null || !mounted) return;

    setState(() => _isBuildingApk = true);
    try {
      final result = await OfflineApkBuilder.buildAndSave(quest.id, options);
      if (!mounted) return;
      if (result != null) {
        _showSnack(
          trf('APK собран: {p0}', {'p0': result.packageName}),
          success: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        trf('Ошибка сборки APK: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _isBuildingApk = false);
    }
  }

  Future<void> _submitQuestForModeration(Quest quest) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');

    if (!mounted) return;
    if (userId == null) {
      _showSnack(tr('Для публикации нужно войти в аккаунт'), warning: true);
      return;
    }

    final result = await Navigator.of(context).push<PublishResult>(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: false,
        pageBuilder: (context, _, __) => QuestPublishScreen(quest: quest),
      ),
    );

    if (result == PublishResult.success && mounted) {
      ref.invalidate(questProvider(widget.questId));
    }
  }

  Future<void> _resetProgress(Quest quest) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(tr('Сбросить прогресс?')),
          content: Text(tr('Все сохранения будут удалены безвозвратно.')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              child: Text(tr('Сбросить')),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      await ref.read(saveGameServiceProvider).deleteAllSaves(quest.id);
      ref.invalidate(saveSlotsProvider(quest.id));
      if (mounted) {
        _showSnack(tr('Сохранения удалены'), success: true);
      }
    }
  }

  Future<void> _selectStartNode(Quest quest) async {
    final selectedNodeId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => NodeSelectionScreen(
          questId: quest.id,
          selectedNodeId: quest.startNodeId,
          allowCreate: true,
        ),
      ),
    );

    if (selectedNodeId != null && mounted) {
      try {
        final configPath = QuestPaths.config(quest.id);
        final config = await _readMap(configPath);
        await (await _qs()).writeJson(configPath, {
          ...config,
          'startNodeId': selectedNodeId,
        });
        ref.invalidate(questProvider(quest.id));
        _showSnack(tr('Стартовая нода обновлена'), success: true);
      } catch (e) {
        if (!mounted) return;
        _showSnack(trf('Ошибка: {p0}', {'p0': friendlyError(e)}), error: true);
      }
    }
  }

  Future<void> _confirmDelete(Quest quest) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text(tr('Удалить квест?')),
          content: Text(
            tr(
              'Это действие нельзя отменить. Все ресурсы, ноды и сохранения будут удалены с устройства.',
            ),
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
              child: Text(tr('Удалить')),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      await FileStorage.delete(QuestPaths.questRoot(quest.id));
      ref.invalidate(questsProvider);
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }

  void _openWorkspace(
    String questId,
    EditorDocumentDescriptor initialDocument,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QuestEditorShell(
          questId: questId,
          initialDocument: initialDocument,
        ),
      ),
    );
  }

  void _openEditor(Quest quest) {
    final tutorial = ref.read(tutorialControllerProvider);
    if (tutorial.step == TutorialStep.openEditor) {
      ref.read(tutorialControllerProvider.notifier).next();
    }
    _openWorkspace(quest.id, EditorDocumentDescriptor.chapters(quest.id));
  }

  Future<void> _openSettings(Quest quest) async {
    _openWorkspace(quest.id, EditorDocumentDescriptor.questSettings(quest.id));
  }

  void _openResources(Quest quest) {
    _openWorkspace(quest.id, EditorDocumentDescriptor.resources(quest.id));
  }

  Future<void> _openHistory(Quest quest) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => QuestHistoryScreen(questId: quest.id)),
    );
    if (result == true) {
      ref.invalidate(questProvider(quest.id));
    }
  }

  void _play(Quest quest) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LoadGameScreen(questId: quest.id)),
    );
  }

  void _shareSheet(Quest quest) {
    if (quest.isReadOnly || _isBuildingApk) return;
    showAdaptiveSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(tr('Экспорт в .mnd')),
                subtitle: Text(tr('Копия квеста (без сохранений)')),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportQuest(quest);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.lock_outline_rounded,
                  color: Colors.orangeAccent,
                ),
                title: Text(tr('Экспорт защищённого квеста')),
                subtitle: Text(tr('Только для игры, контент будет зашифрован')),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportQuest(quest, isProtected: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.save_outlined),
                title: Text(tr('Бэкап квеста (с сохранениями)')),
                subtitle: Text(tr('Копия квеста вместе с прогрессом')),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportQuest(quest, includeSaves: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(tr('Экспорт в .txt')),
                subtitle: Text(tr('Текстовый дамп квеста')),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportQuestTxt(quest);
                },
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_rounded),
                title: Text(tr('Экспорт в PDF')),
                subtitle: Text(tr('Книга с содержанием и якорями')),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportQuestPdf(quest);
                },
              ),
              if (_canBuildApk)
                ListTile(
                  leading: const Icon(Icons.android_rounded),
                  title: Text(tr('Собрать APK')),
                  subtitle: Text(tr('Приложение с квестом для Android')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _buildApk(quest);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ), // SingleChildScrollView
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Уведомления
  // ---------------------------------------------------------------------------

  void _showSnack(
    String text, {
    bool success = false,
    bool error = false,
    bool warning = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    Color? bg;
    Color? fg;
    if (success) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
    } else if (error) {
      bg = scheme.error;
      fg = scheme.onError;
    } else if (warning) {
      bg = scheme.tertiaryContainer;
      fg = scheme.onTertiaryContainer;
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
    final questAsync = ref.watch(questProvider(widget.questId));
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: questAsync.when(
        loading: () =>
            Center(child: CircularProgressIndicator(color: scheme.primary)),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              trf('Ошибка: {p0}', {'p0': friendlyError(err)}),
              style: TextStyle(color: scheme.error),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (quest) {
          if (quest == null) {
            return Center(
              child: Text(
                tr('Квест не найден'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            );
          }
          return _buildContent(quest);
        },
      ),
    );
  }

  Widget _buildContent(Quest quest) {
    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      slivers: [
        _buildAppBar(quest),
        SliverToBoxAdapter(
          child: _LocalActionPanel(
            onPlay: () => _play(quest),
            onOpenMarket: quest.marketQuestId == null
                ? null
                : () => _openMarketPage(quest),
          ),
        ),
        SliverToBoxAdapter(child: _MetaChipsRow(quest: quest)),
        SliverToBoxAdapter(child: _StartNodeCard(quest: quest)),
        SliverToBoxAdapter(
          child: _BuilderSection(
            quest: quest,
            openEditorKey: _openEditorKey,
            onSettings: () => _openSettings(quest),
            onEditor: () => _openEditor(quest),
            onResources: () => _openResources(quest),
            onStartNode: () => _selectStartNode(quest),
          ),
        ),
        SliverToBoxAdapter(
          child: _ManagementSection(
            quest: quest,
            isExporting: _isExporting,
            isExportingTxt: _isExportingTxt,
            isExportingPdf: _isExportingPdf,
            onHistory: () => _openHistory(quest),
            onShareSheet: () => _shareSheet(quest),
            onPublish: () => _submitQuestForModeration(quest),
          ),
        ),
        SliverToBoxAdapter(
          child: _DangerZone(
            onReset: () => _resetProgress(quest),
            onDelete: () => _confirmDelete(quest),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
      ],
    );
  }

  void _openMarketPage(Quest quest) {
    final id = quest.marketQuestId;
    if (id == null || id.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MarketQuestLoaderScreen(questId: id)),
    );
  }

  SliverAppBar _buildAppBar(Quest quest) {
    final scheme = Theme.of(context).colorScheme;
    return SliverAppBar(
      expandedHeight: _heroExpandedHeight,
      pinned: true,
      stretch: true,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      title: _CollapsedTitle(
        title: quest.title,
        controller: _scrollController,
        expandedHeight: _heroExpandedHeight,
      ),
      leading: CatalogGlassIconButton(
        icon: Icons.arrow_back_rounded,
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        if (!quest.isReadOnly)
          CatalogGlassIconButton(
            icon: Icons.ios_share_rounded,
            tooltip: tr('Поделиться'),
            onPressed: () => _shareSheet(quest),
          ),
      ],
      flexibleSpace: Stack(
        fit: StackFit.expand,
        children: [
          FlexibleSpaceBar(
            stretchModes: const [StretchMode.zoomBackground],
            background: Stack(
              fit: StackFit.expand,
              children: [_QuestCover(quest: quest)],
            ),
          ),
          _LocalHeroOverlay(
            quest: quest,
            scheme: scheme,
            controller: _scrollController,
            expandedHeight: _heroExpandedHeight,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  HERO: обложка, затемнение и название как на странице маркета
// ============================================================================

class _LocalHeroOverlay extends StatelessWidget {
  final Quest quest;
  final ColorScheme scheme;
  final ScrollController controller;
  final double expandedHeight;

  const _LocalHeroOverlay({
    required this.quest,
    required this.scheme,
    required this.controller,
    required this.expandedHeight,
  });

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    final collapseStart = expandedHeight - kToolbarHeight - topPadding;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final offset = controller.hasClients ? controller.offset : 0.0;
        final fade = collapseStart <= 0
            ? 0.0
            : (1 - offset / collapseStart).clamp(0.0, 1.0);
        final gradientFade = collapseStart <= 0
            ? 1.0
            : ((collapseStart - offset) / 48).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 180,
              child: IgnorePointer(
                child: Opacity(
                  opacity: gradientFade,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          scheme.surface.withOpacity(0.6),
                          scheme.surface,
                        ],
                        stops: const [0.0, 0.7, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: IgnorePointer(
                ignoring: fade <= 0.05,
                child: Opacity(
                  opacity: fade,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        quest.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              shadows: const [
                                Shadow(blurRadius: 12, color: Colors.black54),
                              ],
                            ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person_rounded,
                            size: 18,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              quest.author ?? tr('Локальный проект'),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LocalActionPanel extends StatelessWidget {
  final VoidCallback onPlay;
  final VoidCallback? onOpenMarket;

  const _LocalActionPanel({required this.onPlay, required this.onOpenMarket});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: scheme.secondary,
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPlay,
              child: SizedBox(
                height: 60,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.play_arrow_rounded,
                      color: scheme.onSecondary,
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      tr('Играть'),
                      style: textTheme.titleMedium?.copyWith(
                        color: scheme.onSecondary,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onOpenMarket != null) ...[
            const SizedBox(height: 10),
            Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onOpenMarket,
                child: SizedBox(
                  height: 58,
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      Icon(
                        Icons.storefront_rounded,
                        color: scheme.primary,
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr('Открыть страницу квеста'),
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurface,
                              ),
                            ),
                            Text(
                              tr('Страница в маркете'),
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.open_in_new_rounded,
                        color: scheme.onSurfaceVariant,
                        size: 18,
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CollapsedTitle extends StatelessWidget {
  final String title;
  final ScrollController controller;
  final double expandedHeight;

  const _CollapsedTitle({
    required this.title,
    required this.controller,
    required this.expandedHeight,
  });

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    final collapseStart = expandedHeight - kToolbarHeight - topPadding;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final offset = controller.hasClients ? controller.offset : 0.0;
        final progress = collapseStart <= 0
            ? 1.0
            : ((offset - collapseStart + 40) / 40).clamp(0.0, 1.0);
        return Opacity(
          opacity: progress,
          child: IgnorePointer(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
        );
      },
    );
  }
}

class _QuestCover extends StatelessWidget {
  final Quest quest;
  const _QuestCover({required this.quest});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (quest.localPreviewPath != null) {
      return Image.file(
        File(quest.localPreviewPath!),
        key: ValueKey(quest.localPreviewPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _coverPlaceholder(scheme),
      );
    }
    return _coverPlaceholder(scheme);
  }

  Widget _coverPlaceholder(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.primaryContainer.withOpacity(0.6),
            scheme.tertiaryContainer.withOpacity(0.5),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.auto_stories_rounded,
          size: 72,
          color: scheme.onPrimaryContainer.withOpacity(0.6),
        ),
      ),
    );
  }
}

// ============================================================================
//  META: чипы с версией, датой, статусом
// ============================================================================

class _MetaChipsRow extends StatelessWidget {
  final Quest quest;
  const _MetaChipsRow({required this.quest});

  String _formatDate(DateTime? date) {
    if (date == null) return '-';
    return '${date.day.toString().padLeft(2, '0')}.'
        '${date.month.toString().padLeft(2, '0')}.${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _MetaChip(
            icon: Icons.tag_rounded,
            label: 'v${quest.version ?? '1.0.0'}',
          ),
          _MetaChip(
            icon: Icons.calendar_today_rounded,
            label: _formatDate(quest.created),
          ),
          if (quest.isReadOnly)
            _MetaChip(
              icon: Icons.lock_outline_rounded,
              label: tr('Только чтение'),
              tone: _ChipTone.warning,
            ),
          if (quest.isMarketDownloaded)
            _MetaChip(
              icon: Icons.shop_rounded,
              label: tr('Из маркета'),
              tone: _ChipTone.info,
            ),
          if (quest.isCorrupted)
            _MetaChip(
              icon: Icons.error_outline_rounded,
              label: tr('Повреждён'),
              tone: _ChipTone.danger,
            ),
        ],
      ),
    );
  }
}

enum _ChipTone { neutral, info, warning, danger }

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final _ChipTone tone;

  const _MetaChip({
    required this.icon,
    required this.label,
    this.tone = _ChipTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    late final Color bg;
    late final Color fg;
    switch (tone) {
      case _ChipTone.neutral:
        bg = scheme.surfaceContainerHigh;
        fg = scheme.onSurfaceVariant;
        break;
      case _ChipTone.info:
        bg = scheme.secondaryContainer;
        fg = scheme.onSecondaryContainer;
        break;
      case _ChipTone.warning:
        bg = scheme.tertiaryContainer;
        fg = scheme.onTertiaryContainer;
        break;
      case _ChipTone.danger:
        bg = scheme.errorContainer;
        fg = scheme.onErrorContainer;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  DESCRIPTION
// ============================================================================

// ============================================================================
//  START NODE CARD
// ============================================================================

class _StartNodeCard extends StatelessWidget {
  final Quest quest;
  const _StartNodeCard({required this.quest});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasStart = quest.startNodeId != null;
    if (hasStart) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.tertiary.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              color: scheme.onTertiaryContainer,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr(
                  'Стартовая нода не выбрана. Без неё игроки увидят первую попавшуюся ноду.',
                ),
                style: TextStyle(
                  color: scheme.onTertiaryContainer,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  BUILDER SECTION
// ============================================================================

class _BuilderSection extends StatelessWidget {
  final Quest quest;
  final GlobalKey openEditorKey;
  final VoidCallback onSettings;
  final VoidCallback onEditor;
  final VoidCallback onResources;
  final VoidCallback onStartNode;

  const _BuilderSection({
    required this.quest,
    required this.openEditorKey,
    required this.onSettings,
    required this.onEditor,
    required this.onResources,
    required this.onStartNode,
  });

  @override
  Widget build(BuildContext context) {
    if (quest.isReadOnly) return const SizedBox.shrink();
    return _Section(
      icon: Icons.build_circle_outlined,
      title: tr('Конструктор'),
      subtitle: tr('Создание и редактирование контента'),
      children: [
        _ActionTile(
          icon: Icons.account_tree_outlined,
          title: tr('Сценарий и главы'),
          subtitle: tr('Граф нод, связи, скрипты'),
          tone: _TileTone.primary,
          keyRef: openEditorKey,
          onTap: onEditor,
        ),
        _ActionTile(
          icon: Icons.perm_media_outlined,
          title: tr('Ресурсы'),
          subtitle: tr('Картинки, аудио, скрипты'),
          tone: _TileTone.neutral,
          onTap: onResources,
        ),
        _ActionTile(
          icon: Icons.start_rounded,
          title: tr('Стартовая точка'),
          subtitle: quest.startNodeId != null
              ? tr('Установлена')
              : tr('Не выбрана'),
          tone: quest.startNodeId != null
              ? _TileTone.neutral
              : _TileTone.warning,
          onTap: onStartNode,
        ),
        _ActionTile(
          icon: Icons.settings_outlined,
          title: tr('Основные настройки'),
          subtitle: tr('Название, обложка, описание, теги'),
          tone: _TileTone.neutral,
          onTap: onSettings,
        ),
      ],
    );
  }
}

// ============================================================================
//  MANAGEMENT SECTION
// ============================================================================

class _ManagementSection extends StatelessWidget {
  final Quest quest;
  final bool isExporting;
  final bool isExportingTxt;
  final bool isExportingPdf;
  final VoidCallback onHistory;
  final VoidCallback onShareSheet;
  final VoidCallback onPublish;

  const _ManagementSection({
    required this.quest,
    required this.isExporting,
    required this.isExportingTxt,
    required this.isExportingPdf,
    required this.onHistory,
    required this.onShareSheet,
    required this.onPublish,
  });

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];
    final busy = isExporting || isExportingTxt || isExportingPdf;

    if (!quest.isReadOnly) {
      tiles.add(
        _ActionTile(
          icon: Icons.history_rounded,
          title: tr('История версий'),
          subtitle: tr('Бэкапы и восстановление'),
          tone: _TileTone.neutral,
          onTap: onHistory,
        ),
      );
      tiles.add(
        _ActionTile(
          icon: busy ? Icons.hourglass_top_rounded : Icons.ios_share_rounded,
          title: tr('Экспорт'),
          subtitle: tr('.mnd архив, .txt или PDF'),
          tone: _TileTone.neutral,
          onTap: busy ? null : onShareSheet,
        ),
      );
      tiles.add(
        _ActionTile(
          icon: Icons.cloud_upload_outlined,
          title: tr('Опубликовать в маркет'),
          subtitle: tr('Отправить на модерацию'),
          tone: _TileTone.primary,
          onTap: onPublish,
        ),
      );
    }

    if (tiles.isEmpty) return const SizedBox.shrink();

    return _Section(
      icon: Icons.tune_rounded,
      title: tr('Управление'),
      children: tiles,
    );
  }
}

// ============================================================================
//  DANGER ZONE
// ============================================================================

class _DangerZone extends StatelessWidget {
  final VoidCallback onReset;
  final VoidCallback onDelete;

  const _DangerZone({required this.onReset, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return _Section(
      icon: Icons.warning_amber_rounded,
      title: tr('Опасная зона'),
      subtitle: tr('Необратимые действия'),
      tone: _SectionTone.danger,
      children: [
        _ActionTile(
          icon: Icons.cleaning_services_outlined,
          title: tr('Сбросить прогресс'),
          subtitle: tr('Удалить все сохранения игры'),
          tone: _TileTone.warning,
          onTap: onReset,
        ),
        _ActionTile(
          icon: Icons.delete_forever_rounded,
          title: tr('Удалить квест'),
          subtitle: tr('Безвозвратно стереть с устройства'),
          tone: _TileTone.danger,
          onTap: onDelete,
        ),
      ],
    );
  }
}

// ============================================================================
//  PRIMITIVES
// ============================================================================

enum _SectionTone { normal, danger }

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final _SectionTone tone;

  const _Section({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
    this.tone = _SectionTone.normal,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final isDanger = tone == _SectionTone.danger;
    final iconBg = isDanger ? scheme.errorContainer : scheme.primaryContainer;
    final iconFg = isDanger
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: iconFg, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface,
                            ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

enum _TileTone { neutral, primary, warning, danger }

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final _TileTone tone;
  final VoidCallback? onTap;
  final Key? keyRef;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tone,
    required this.onTap,
    this.keyRef,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Color iconBg;
    Color iconFg;
    Color titleColor = scheme.onSurface;
    switch (tone) {
      case _TileTone.neutral:
        iconBg = scheme.surfaceContainerHighest;
        iconFg = scheme.onSurfaceVariant;
        break;
      case _TileTone.primary:
        iconBg = scheme.primaryContainer;
        iconFg = scheme.onPrimaryContainer;
        break;
      case _TileTone.warning:
        iconBg = scheme.tertiaryContainer;
        iconFg = scheme.onTertiaryContainer;
        break;
      case _TileTone.danger:
        iconBg = scheme.errorContainer;
        iconFg = scheme.onErrorContainer;
        titleColor = scheme.error;
        break;
    }

    return Padding(
      key: keyRef,
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: iconFg, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant.withOpacity(0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
