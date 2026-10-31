import 'dart:ui';
import 'dart:async'; // Для ImageFilter

import 'package:canvas_app/core/services/template_asset_installer.dart';
import 'package:canvas_app/models/canvas_lod.dart';
import 'package:canvas_app/models/canvas_models.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/features/editor/services/script_providers.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/providers/template_provider.dart';
import 'package:canvas_app/features/editor/workspace/editor_back_handler.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/editor/utils/template_applier.dart';
import 'package:canvas_app/features/editor/screens/canvas/widgets/canvas_tool_picker.dart';
import 'package:canvas_app/features/editor/widgets/template_picker_sheet.dart';
import 'package:canvas_app/features/editor/widgets/template_save_dialog.dart';
import 'package:canvas_app/features/editor/widgets/quest_validation_panel.dart';
import 'package:canvas_app/features/onboarding/controllers/tutorial_controller.dart';
import 'package:canvas_app/shared/widgets/canvas_painter.dart';
import 'package:canvas_app/shared/widgets/color_palette_picker.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:collection/collection.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

class CanvasScreen extends ConsumerStatefulWidget {
  final String questId;
  final String tagId;

  const CanvasScreen({super.key, required this.questId, required this.tagId});

  @override
  ConsumerState<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends ConsumerState<CanvasScreen> {
  // === Управление жестами и состоянием UI ===
  Offset? _lastFocalPoint;
  double _baseScale = 1.0;
  bool _isSearchVisible = false;
  bool _isToolPickerVisible = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // === Ключи для интерактивного обучения ===
  final GlobalKey _addNodeBtnKey = GlobalKey();
  final GlobalKey _connectBtnKey = GlobalKey();
  final GlobalKey _playBtnKey = GlobalKey();

  /// Сколько раз пользователь нажал на «+» во время шага обучения
  /// `addNodeHighlight`. После 3-го нажатия (создан стартовый узел и
  /// две развилки) — продвигаем тур дальше.
  int _tutorialAddNodeClicks = 0;

  // === Навигация по поиску ===
  List<String> _searchResults = [];
  int _currentSearchResultIndex = 0;
  Set<String> _problemNodeIds = <String>{};
  Map<String, int> _problemNodeIssueCounts = <String, int>{};

  /// Цена кадра канваса — переживает перестройку виджета, поэтому живёт в State.
  final CanvasFrameCost _canvasFrameCost = CanvasFrameCost();
  bool _showOnlyProblematic = false;
  Set<ConnectionKind> _visibleConnectionKinds = ConnectionKind.values.toSet();
  List<String> _problemSearchResults = <String>[];
  int _currentProblemResultIndex = 0;
  String _lastProblemScanSignature = '';
  bool _isProblemScanRunning = false;

  // === Desktop Mouse Pan ===
  bool _isMiddleMousePanning = false;
  static const double _kZoomSpeed = 0.05;

  // === ЛОКАЛЬНОЕ СОСТОЯНИЕ (LAG FIX) ===
  String? _resizingGroupId;
  Rect? _tempGroupRect;

  String? _resizingCommentId;
  Size? _tempCommentSize;

  String? _movingItemId;
  Offset? _tempItemPosition;
  Offset? _moveStartOffset;

  bool _isDraggingSelection = false;
  bool _isResizing = false;
  bool _backgroundTapped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctrl = ref.read(tutorialControllerProvider.notifier);
      ctrl.registerTarget(TutorialTargets.canvasAddNodeButton, _addNodeBtnKey);
      ctrl.registerTarget(TutorialTargets.canvasConnectButton, _connectBtnKey);
      ctrl.registerTarget(TutorialTargets.canvasPlayButton, _playBtnKey);

      // Если обучение всё ещё на шаге «открой главу» — продвигаем
      // на «добавить узел» (мы уже в редакторе).
      final state = ref.read(tutorialControllerProvider);
      if (state.step == TutorialStep.openChapterModal ||
          state.step == TutorialStep.highlightCreateChapter) {
        ctrl.goTo(TutorialStep.addNodeHighlight);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _refreshProblemNodes() async {
    // Вызывающий ждал `refreshNodeData`, и за это время экран мог закрыться:
    // первый же `ref.read` после dispose бросает «Cannot use "ref" after the
    // widget was disposed» — четыре таких записи в crash_log за одну ночь.
    if (!mounted) return;
    if (_isProblemScanRunning) return;
    _isProblemScanRunning = true;
    final sw = Stopwatch()..start();
    try {
      final allSavedNodes = await ref.read(
        allQuestNodesProvider(widget.questId).future,
      );
      if (!mounted) return;
      final chapterNodes = allSavedNodes
          .where((n) => n.chapterId == widget.tagId)
          .toList();
      final validator = ref.read(
        triggerValidationServiceProvider(widget.questId),
      );
      final problemCounts = <String, int>{};

      Future<void> walkItems(String nodeId, List<dynamic> items) async {
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final itemId = raw['id']?.toString();
          final triggers = raw['scriptTriggers'];
          final onAppearPath = triggers is Map
              ? triggers['onAppear']?.toString()
              : null;

          if (itemId != null && onAppearPath != null) {
            final issue = await validator.validateOnAppear(
              itemId: itemId,
              rawTrigger: onAppearPath,
            );
            if (issue != null) {
              problemCounts.update(nodeId, (v) => v + 1, ifAbsent: () => 1);
            }
          }

          final children = raw['children'];
          if (children is List && children.isNotEmpty) {
            await walkItems(nodeId, children);
          }
        }
      }

      for (final node in chapterNodes) {
        final content = node.content;
        final items = content['items'];
        if (items is List && items.isNotEmpty) {
          await walkItems(node.id, items);
        }
      }

      if (!mounted) return;
      final nodeOrder = chapterNodes.map((n) => n.id).toList();
      final problemIdsOrdered = nodeOrder
          .where((id) => problemCounts.containsKey(id))
          .toList();
      setState(() {
        _problemNodeIssueCounts = problemCounts;
        _problemNodeIds = problemCounts.keys.toSet();
        _problemSearchResults = problemIdsOrdered;
        if (_problemSearchResults.isEmpty) {
          _currentProblemResultIndex = 0;
          _showOnlyProblematic = false;
        } else if (_currentProblemResultIndex >= _problemSearchResults.length) {
          _currentProblemResultIndex = 0;
        }
      });
      sw.stop();
      print(
        '[Perf][Canvas] Problem scan completed for quest=${widget.questId} '
        'tag=${widget.tagId}: ${chapterNodes.length} nodes, '
        '${problemCounts.length} problematic in ${sw.elapsedMilliseconds}ms',
      );
    } finally {
      sw.stop();
      _isProblemScanRunning = false;
    }
  }

  void _nextProblemResult() {
    if (_problemSearchResults.isEmpty) return;
    setState(() {
      _currentProblemResultIndex =
          (_currentProblemResultIndex + 1) % _problemSearchResults.length;
    });
    _jumpToNode(_problemSearchResults[_currentProblemResultIndex]);
  }

  void _previousProblemResult() {
    if (_problemSearchResults.isEmpty) return;
    setState(() {
      _currentProblemResultIndex =
          (_currentProblemResultIndex - 1 + _problemSearchResults.length) %
          _problemSearchResults.length;
    });
    _jumpToNode(_problemSearchResults[_currentProblemResultIndex]);
  }

  // --- ЛОГИКА ПОИСКА ---
  void _toggleSearch() {
    setState(() {
      _isSearchVisible = !_isSearchVisible;
      if (_isSearchVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocusNode.requestFocus();
        });
      } else {
        _clearSearch();
      }
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    final notifier = ref.read(
      canvasProvider((widget.questId, widget.tagId)).notifier,
    );
    notifier.searchNodes('');
    _searchResults = [];
    _currentSearchResultIndex = 0;
  }

  void _updateSearchResults(String query, List<Node> allNodes) {
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _currentSearchResultIndex = 0;
      });
    } else {
      final results = allNodes
          .where((node) {
            final titleMatch = node.label.toLowerCase().contains(
              query.toLowerCase(),
            );
            final contentMatch = node.content.toString().toLowerCase().contains(
              query.toLowerCase(),
            );
            return titleMatch || contentMatch;
          })
          .map((node) => node.id)
          .toList();
      setState(() {
        _searchResults = results;
        _currentSearchResultIndex = 0;
      });
      if (results.isNotEmpty) {
        _jumpToNode(results.first);
      }
    }
  }

  void _jumpToNode(String nodeId) {
    final notifier = ref.read(
      canvasProvider((widget.questId, widget.tagId)).notifier,
    );
    final state = ref.read(canvasProvider((widget.questId, widget.tagId)));
    final node = state.nodes.firstWhereOrNull((n) => n.id == nodeId);

    if (node != null) {
      final screenSize = MediaQuery.of(context).size;
      final curScale = notifier.cameraScale.value;
      final curOffset = notifier.cameraOffset.value;
      final newOffsetX = -node.position.dx * curScale + screenSize.width / 2;
      final newOffsetY = -node.position.dy * curScale + screenSize.height / 2;
      notifier.panCamera(Offset(newOffsetX, newOffsetY) - curOffset);
      notifier.selectNode(nodeId);
    }
  }

  Future<void> _openQuestValidation() async {
    await showQuestValidationPanel(
      context,
      questId: widget.questId,
      onJumpToNode: _jumpToNode,
    );
  }

  void _nextResult() {
    if (_searchResults.isEmpty) return;
    setState(() {
      _currentSearchResultIndex =
          (_currentSearchResultIndex + 1) % _searchResults.length;
    });
    _jumpToNode(_searchResults[_currentSearchResultIndex]);
  }

  void _previousResult() {
    if (_searchResults.isEmpty) return;
    setState(() {
      _currentSearchResultIndex =
          (_currentSearchResultIndex - 1 + _searchResults.length) %
          _searchResults.length;
    });
    _jumpToNode(_searchResults[_currentSearchResultIndex]);
  }

  // ============================================================
  // Templates (для нод)
  // ============================================================

  /// Создать шаблон из существующей ноды.
  Future<void> _saveNodeAsTemplate(Node node) async {
    // Подтягиваем актуальный SavedNode по id (там полный content)
    final all = await ref.read(allQuestNodesProvider(widget.questId).future);
    if (!mounted) return;
    final savedNode = all.firstWhereOrNull((n) => n.id == node.id);
    if (savedNode == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Нода не найдена'))));
      }
      return;
    }

    final result = await TemplateSaveDialog.show(
      context,
      title: tr('Сохранить ноду как шаблон'),
      kind: TemplateKind.node,
      initialName: savedNode.title,
    );
    if (result == null || !mounted) return;

    final tpl = TemplateApplier.makeFromNode(
      name: result.name,
      node: savedNode,
      description: result.description,
      category: result.category,
    );

    final actions = ref.read(templateActionsProvider);
    if (result.scope == TemplateScope.global) {
      await actions.saveAsGlobal(tpl, sourceQuestId: widget.questId);
    } else {
      await actions.saveToQuest(widget.questId, tpl);
    }

    // Помечаем исходную ноду как мастер-шаблон. После этого при
    // каждом сохранении этой ноды (через node_content_screen._saveNode)
    // её content будет синхронизироваться обратно в TemplateRepository,
    // что автоматически обновит все linked-ноды по квесту.
    try {
      final masterNode = savedNode.copyWith(
        templateRef: tpl.id,
        templateVersion: tpl.contentVersion,
        isTemplateMaster: true,
      );
      await updateNode(widget.questId, masterNode);
      ref.invalidate(allQuestNodesProvider(widget.questId));
    } catch (e) {
      // ignore: avoid_print
      print('[Templates] failed to mark node as master: $e');
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Шаблон ноды сохранён. Нода помечена как мастер.')),
        backgroundColor: Colors.green,
      ),
    );
  }

  /// Вставить ноду на канвас из шаблона.
  Future<void> _insertNodeFromTemplate(CanvasNotifier notifier) async {
    final pickedResult = await TemplatePickerSheet.showWithMode(
      context,
      questId: widget.questId,
      allowedKinds: const {TemplateKind.node},
      title: tr('Вставить ноду из шаблона'),
      allowLinked: true,
    );
    if (pickedResult == null || !mounted) return;
    final picked = pickedResult.template;

    // --- Linked-режим для нод ---
    if (pickedResult.mode == TemplatePickMode.linked) {
      TemplateItem masterInQuest = picked;
      try {
        if (pickedResult.wasGlobal) {
          masterInQuest = await ref
              .read(templateActionsProvider)
              .pinToQuest(picked, widget.questId);
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Не удалось закрепить шаблон в квесте: {p0}', {
                'p0': friendlyError(e),
              }),
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (!mounted) return;
      final size = MediaQuery.of(context).size;
      final world = notifier.screenToWorld(size.center(Offset.zero));
      final linkedNode = TemplateApplier.buildLinkedNode(
        masterInQuest,
        chapterId: widget.tagId,
        x: world.dx,
        y: world.dy,
      );
      if (linkedNode == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Не удалось создать связанную ноду')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final ok = await saveNodes(widget.questId, [linkedNode]);
      if (!mounted) return;
      if (ok) {
        ref.invalidate(allQuestNodesProvider(widget.questId));
        await notifier.reloadData();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Связанная нода вставлена: {p0}', {'p0': masterInQuest.name}),
            ),
            backgroundColor: Colors.cyan,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Не удалось сохранить ноду')),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // --- Snapshot-режим (старое поведение) ---
    // Предупреждение про плагины
    final pluginIds = TemplateApplier.collectPluginIds(picked);
    if (pluginIds.isNotEmpty) {
      final scheme = Theme.of(context).colorScheme;
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: scheme.surfaceContainerHigh,
          title: Text(
            tr('Шаблон использует плагины'),
            style: TextStyle(color: scheme.onSurface),
          ),
          content: Text(
            trf(
              'Этот шаблон ссылается на плагины: {p0}. Если они не установлены в текущем квесте, нода может работать некорректно. Продолжить вставку?',
              {'p0': pluginIds.join(", ")},
            ),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Вставить')),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }

    // Сначала устанавливаем ассеты шаблона в квест (если есть).
    final installed = await TemplateAssetInstaller.installToQuest(
      template: picked,
      questId: widget.questId,
    );
    final effectiveTemplate = installed.template;

    if (!mounted) return;
    // Размещаем ноду в центре экрана (мировые координаты).
    final size = MediaQuery.of(context).size;
    final world = notifier.screenToWorld(size.center(Offset.zero));
    final newNode = TemplateApplier.buildNode(
      effectiveTemplate,
      chapterId: widget.tagId,
      x: world.dx,
      y: world.dy,
      titleSuffix: tr(' (шаблон)'),
    );
    if (newNode == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Не удалось построить ноду из шаблона')),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final ok = await saveNodes(widget.questId, [newNode]);
    if (!mounted) return;
    if (ok) {
      ref.invalidate(allQuestNodesProvider(widget.questId));
      await notifier.reloadData();
      if (!mounted) return;
      final report = installed.assetsReport;
      final msg = report.copied > 0
          ? trf('Нода «{p0}» вставлена (ресурсов: {p1}, пропущено: {p2})', {
              'p0': newNode.title,
              'p1': report.copied,
              'p2': report.skippedExisting,
            })
          : trf('Нода «{p0}» вставлена', {'p0': newNode.title});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.blue),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Не удалось сохранить ноду')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Открыть менеджер шаблонов из канваса.
  void _openTemplateManager() {
    EditorDocumentLauncher.openTemplates(context, widget.questId);
  }

  // --- ЛОГИКА ДЕЙСТВИЙ ---
  Future<void> _handleDuplicateNode(
    CanvasNotifier notifier,
    String? nodeId,
  ) async {
    if (nodeId == null) return;
    final success = await duplicateNode(widget.questId, nodeId);
    if (success) {
      await notifier.reloadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Нода дублирована')),
            backgroundColor: Colors.green,
            duration: Duration(milliseconds: 800),
          ),
        );
      }
    }
  }

  Future<void> _showTidyUpConfirmationDialog(CanvasNotifier notifier) async {
    final scheme = Theme.of(context).colorScheme;
    final result = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: scheme.surfaceContainerHigh,
        title: Text(
          tr('Выровнять все ноды?'),
          style: TextStyle(color: scheme.onSurface),
        ),
        content: Text(
          tr(
            'Это действие автоматически расставит все ноды на холсте. Ручное расположение будет утеряно.',
          ),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: scheme.tertiary),
            child: Text(tr('Выровнять')),
          ),
        ],
      ),
    );
    if (result == true) {
      notifier.tidyUpLayout();
    }
  }

  Future<void> _showDeleteNodeDialog(
    BuildContext context,
    CanvasNotifier notifier,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final statsFuture = nodeDeletionStats(widget.questId);
    final selectedCount = notifier.selectedNodeCount;
    final result = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: scheme.surfaceContainerHigh,
        title: Text(tr('Удалить?'), style: TextStyle(color: scheme.onSurface)),
        content: FutureBuilder<(int, int)>(
          future: statsFuture,
          builder: (context, snapshot) {
            final stats = snapshot.data;
            final dangerous =
                stats != null && stats.$1 > 0 && selectedCount * 2 > stats.$1;
            return Text(
              dangerous
                  ? '${tr('Это действие нельзя отменить.')}\n\n'
                        '${trf('{p0} / {p1} нод', {'p0': selectedCount, 'p1': stats.$1})}'
                  : tr('Это действие нельзя отменить.'),
              style: TextStyle(color: scheme.onSurfaceVariant),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );
    if (result == true) {
      notifier.deleteSelectedNode();
    }
  }

  String _connectionKindLabel(ConnectionKind kind) {
    switch (kind) {
      case ConnectionKind.content:
        return tr('Обычные');
      case ConnectionKind.timer:
        return tr('Таймер');
      case ConnectionKind.script:
        return tr('Скрипты');
    }
  }

  Color _connectionKindColor(ConnectionKind kind) {
    switch (kind) {
      // Цвета связей — фиксированная M3 tonal-палитра (tone ~70),
      // гармонирует с любой схемой и читается на тёмном холсте.
      case ConnectionKind.content:
        return const Color(0xFF7FCFB6); // teal 70 — обычные переходы
      case ConnectionKind.timer:
        return const Color(0xFFE0C46C); // amber 70 — таймеры
      case ConnectionKind.script:
        return const Color(0xFFB39DDB); // violet 70 — скриптовые
    }
  }

  Future<void> _showConnectionFilterDialog() async {
    final scheme = Theme.of(context).colorScheme;
    final draftSelection = Set<ConnectionKind>.from(_visibleConnectionKinds);
    final result = await showAppDialog<Set<ConnectionKind>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setLocalState) {
          return AlertDialog(
            backgroundColor: scheme.surfaceContainerHigh,
            title: Text(
              tr('Фильтр стрелок'),
              style: TextStyle(color: scheme.onSurface),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: ConnectionKind.values
                  .map(
                    (kind) => CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: _connectionKindColor(kind),
                      checkColor: scheme.surface,
                      value: draftSelection.contains(kind),
                      title: Text(
                        _connectionKindLabel(kind),
                        style: TextStyle(color: _connectionKindColor(kind)),
                      ),
                      onChanged: (isChecked) {
                        setLocalState(() {
                          if (isChecked == true) {
                            draftSelection.add(kind);
                          } else {
                            draftSelection.remove(kind);
                          }
                        });
                      },
                    ),
                  )
                  .toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => setLocalState(() {
                  draftSelection
                    ..clear()
                    ..addAll(ConnectionKind.values);
                }),
                child: Text(tr('Все')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Отмена')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, draftSelection),
                child: Text(tr('Применить')),
              ),
            ],
          );
        },
      ),
    );

    if (result != null) {
      setState(() {
        _visibleConnectionKinds = result;
      });
    }
  }

  // --- ДИАЛОГИ ---
  Future<void> _showGroupDialog(
    CanvasNotifier notifier, {
    CanvasGroup? group,
  }) async {
    final nameController = TextEditingController(
      text: group?.label ?? tr('Новая группа'),
    );
    final scheme = Theme.of(context).colorScheme;
    // Гармоничная M3 tonal-палитра (tone ~60) для меток групп —
    // приглушённые, но различимые тона, дружелюбные к тёмному холсту.
    const List<Color> colors = [
      Color(0xFF7C9CD6), // blue
      Color(0xFFD68585), // red
      Color(0xFF7FBE8F), // green
      Color(0xFFD6B86A), // amber
      Color(0xFFA98FD1), // purple
      Color(0xFF6FC0BC), // teal
      Color(0xFF9AA0A6), // grey
    ];
    Color selectedColor = group?.color.withOpacity(1.0) ?? colors.first;

    final result = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: scheme.surfaceContainerHigh,
            title: Text(
              group == null ? tr('Создать группу') : tr('Редактировать группу'),
              style: TextStyle(color: scheme.onSurface),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  style: TextStyle(color: scheme.onSurface),
                  decoration: InputDecoration(labelText: tr('Название')),
                ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: colors
                        .map(
                          (c) => GestureDetector(
                            onTap: () => setState(() => selectedColor = c),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: selectedColor == c
                                    ? Border.all(
                                        color: scheme.onSurface,
                                        width: 2,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Отмена')),
              ),
              if (group != null)
                TextButton(
                  onPressed: () {
                    notifier.deleteGroup(group.id);
                    Navigator.pop(ctx);
                  },
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: Text(tr('Удалить')),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, {
                  'label': nameController.text,
                  'color': selectedColor,
                }),
                child: Text(tr('ОК')),
              ),
            ],
          );
        },
      ),
    );

    if (result != null) {
      if (!mounted) return;
      if (group != null) {
        notifier.updateGroup(
          group.id,
          label: result['label'],
          color: result['color'],
        );
      } else {
        final screenSize = MediaQuery.of(context).size;
        final centerWorld = notifier.screenToWorld(
          screenSize.center(Offset.zero),
        );

        notifier.addGroup(
          label: result['label'],
          color: result['color'],
          position: centerWorld,
        );
      }
    }
  }

  /// Клавиши графа. Появляются только когда что-то выделено: пустая карта
  /// пропускает нажатие наверх, к шеллу вкладок и к обёртке навигации,
  /// иначе Escape перестал бы закрывать экран.
  Map<ShortcutActivator, VoidCallback> _canvasShortcuts(
    CanvasState state,
    CanvasNotifier notifier,
  ) {
    final selectedId = state.selectedNodeId;
    if (selectedId == null) return const {};
    final selected = state.nodes.firstWhereOrNull((n) => n.id == selectedId);
    return {
      // Enter — то же, что двойной клик по ноде.
      if (selected != null)
        const SingleActivator(LogicalKeyboardKey.enter): () =>
            unawaited(_openNodeDocument(notifier, selected)),
      const SingleActivator(LogicalKeyboardKey.delete): () =>
          _showDeleteNodeDialog(context, notifier),
      const SingleActivator(LogicalKeyboardKey.backspace): () =>
          _showDeleteNodeDialog(context, notifier),
      const SingleActivator(LogicalKeyboardKey.keyD, control: true): () =>
          unawaited(_handleDuplicateNode(notifier, selectedId)),
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          _handleEscape(notifier),
    };
  }

  void _handleEscape(CanvasNotifier notifier) {
    if (_searchFocusNode.hasFocus) {
      _searchFocusNode.unfocus();
      return;
    }
    notifier.selectNode(null);
    _clearLocalInteractionState();
  }

  /// Открыть документ ноды: двойной клик по графу и Enter на клавиатуре.
  Future<void> _openNodeDocument(CanvasNotifier notifier, Node node) async {
    await notifier.saveCamera();
    notifier.selectNode(null);
    if (!mounted) return;
    await EditorDocumentLauncher.openNode(
      context,
      widget.questId,
      node.id,
      title: node.label,
    );
    if (mounted) {
      await notifier.refreshNodeData(node.id);
      await _refreshProblemNodes();
    }
  }

  /// Меню ноды графа: долгий тап на телефоне и правая кнопка мыши на ПК
  /// открывают одно и то же меню — на широком экране оно всплывает у курсора,
  /// а не уезжает на BOTTOM экрана.
  void _openNodeMenuAt(
    CanvasNotifier notifier,
    CanvasState state,
    Offset globalPosition,
    Offset localPosition,
  ) {
    final worldPos = notifier.screenToWorld(localPosition);
    final node = state.spatialHash.queryPoint(worldPos);
    if (node != null) _showNodeMenu(node, notifier, anchor: globalPosition);
  }

  void _showNodeMenu(Node node, CanvasNotifier notifier, {Offset? anchor}) {
    final scheme = Theme.of(context).colorScheme;
    showAdaptiveSheet<void>(
      context: context,
      anchor: anchor,
      backgroundColor: scheme.surfaceContainerHigh,
      useSafeArea: true,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.account_tree_rounded, color: scheme.onSurface),
            title: Text(
              tr('Выделить всю ветку'),
              style: TextStyle(color: scheme.onSurface),
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              notifier.selectSubtree(node.id);
            },
          ),
          ListTile(
            leading: Icon(Icons.palette_rounded, color: scheme.onSurface),
            title: Text(
              tr('Цвет ноды'),
              style: TextStyle(color: scheme.onSurface),
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _showColorPickerForNode(context, notifier, node.color);
            },
          ),
          ListTile(
            leading: Icon(Icons.bookmark_add_outlined, color: scheme.tertiary),
            title: Text(
              tr('Сохранить как шаблон'),
              style: TextStyle(color: scheme.onSurface),
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _saveNodeAsTemplate(node);
            },
          ),
        ],
      ),
    );
  }

  /// Показать палитру цветов для ноды
  Future<void> _showColorPickerForNode(
    BuildContext context,
    CanvasNotifier notifier,
    Color currentColor,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final selectedColor = await showAppDialog<Color>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ColorPalettePicker(
          currentColor: currentColor,
          onColorSelected: (color) {
            Navigator.of(ctx).pop(color);
          },
        ),
      ),
    );

    if (selectedColor != null && context.mounted) {
      notifier.updateNodeColor(selectedColor);
    }
  }

  Future<void> _editComment(
    CanvasComment comment,
    CanvasNotifier notifier,
  ) async {
    final textController = TextEditingController(text: comment.text);
    final scheme = Theme.of(context).colorScheme;
    final result = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.tertiaryContainer,
        title: Text(
          tr('Заметка'),
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLines: 5,
          style: TextStyle(color: scheme.onTertiaryContainer),
          cursorColor: scheme.onTertiaryContainer,
          decoration: const InputDecoration(border: InputBorder.none),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(
              foregroundColor: scheme.onTertiaryContainer,
            ),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () {
              notifier.deleteComment(comment.id);
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: Text(tr('Удалить')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, textController.text),
            style: TextButton.styleFrom(
              foregroundColor: scheme.onTertiaryContainer,
            ),
            child: Text(tr('ОК')),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      notifier.updateComment(comment.id, result);
    }
  }

  Future<void> _closeCanvas(CanvasNotifier notifier) async {
    await notifier.saveCamera();
    if (!mounted) return;
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);
    if (document != null && workspace != null) {
      await workspace.closeDocument(document.id);
    } else {
      Navigator.pop(context);
    }
  }

  void _clearLocalInteractionState() {
    setState(() {
      _isResizing = false;
      _isDraggingSelection = false;
      _resizingGroupId = null;
      _tempGroupRect = null;
      _resizingCommentId = null;
      _tempCommentSize = null;
      _movingItemId = null;
      _tempItemPosition = null;
      _moveStartOffset = null;
      _backgroundTapped = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = canvasProvider((widget.questId, widget.tagId));
    final state = ref.watch(provider);
    // Синхронизируем токены цветов холста с текущей темой, чтобы
    // CustomPainter рисовал ноды/фон в едином стиле с остальным UI.
    CanvasTheme.update(Theme.of(context).colorScheme);
    final notifier = ref.read(provider.notifier);
    // O(1) сигнатура — join по N узлам каждый build лагал
    final scanSignature = state.nodes.length.toString();
    if (scanSignature != _lastProblemScanSignature && !_isProblemScanRunning) {
      _lastProblemScanSignature = scanSignature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_refreshProblemNodes());
      });
    }

    if (state.isLoading) {
      final scheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: scheme.surfaceDim,
        body: Center(child: CircularProgressIndicator(color: scheme.primary)),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return EditorDocumentBackScope(
      onBackPressed: () async {
        await _closeCanvas(notifier);
        return true;
      },
      child: CallbackShortcuts(
        // На ПК граф без клавиатур не редактор: мышь держат на узлах, а
        // типовые действия (открыть, удалить, снять выделение) — на клавишах.
        bindings: _canvasShortcuts(state, notifier),
        // Клавиши доходят только до поддерева с фокусом, поэтому у графа есть
        // свой Focus: без него нажатия ушли бы к шеллу, а граф остался глухим.
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: scheme.surfaceDim,
            resizeToAvoidBottomInset: false,
            extendBodyBehindAppBar: true,
            body: Stack(
              children: [
                Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      final curScale = notifier.cameraScale.value;
                      final newScale = event.scrollDelta.dy < 0
                          ? curScale * (1 + _kZoomSpeed)
                          : curScale / (1 + _kZoomSpeed);
                      notifier.scaleCamera(newScale, event.localPosition);
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: (details) {
                      _searchFocusNode.unfocus();
                    },
                    onTapUp: (details) {
                      if (state.selectionMode) {
                        notifier.selectNode(null);
                        _clearLocalInteractionState();
                        return;
                      }
                      if (_isResizing || _movingItemId != null) {
                        _clearLocalInteractionState();
                        return;
                      }

                      final worldPos = notifier.screenToWorld(
                        details.localPosition,
                      );
                      final tappedNode = state.spatialHash.queryPoint(worldPos);

                      if (tappedNode != null && !state.connectionMode) {
                        notifier.selectNode(tappedNode.id);
                      } else if (tappedNode == null) {
                        notifier.selectNode(null);
                      }

                      _clearLocalInteractionState();
                    },
                    onTapCancel: () {
                      if (_isResizing || _movingItemId != null) return;
                      _clearLocalInteractionState();
                    },
                    onDoubleTapDown: (details) async {
                      final worldPos = notifier.screenToWorld(
                        details.localPosition,
                      );

                      // 1. Сначала проверяем Ноды (самый верхний слой по смыслу)
                      final node = state.spatialHash.queryPoint(worldPos);
                      if (node != null) {
                        await _openNodeDocument(notifier, node);
                        return;
                      }

                      // 2. Потом Комментарии
                      for (final comment in state.comments) {
                        if (comment.rect.contains(worldPos)) {
                          _editComment(comment, notifier);
                          return;
                        }
                      }

                      // 3. И только потом Группы (фоновый слой)
                      for (final group in state.groups) {
                        if (group.rect.contains(worldPos)) {
                          _showGroupDialog(notifier, group: group);
                          return;
                        }
                      }
                    },
                    onLongPressStart: (details) => _openNodeMenuAt(
                      notifier,
                      state,
                      details.globalPosition,
                      details.localPosition,
                    ),
                    // Правая кнопка мыши — тот же жест, что долгий тап на таче:
                    // на ПК долгий тап это буквально зажать кнопку мыши, и
                    // альтернативы контекстному меню у графа не было.
                    onSecondaryTapUp: (details) => _openNodeMenuAt(
                      notifier,
                      state,
                      details.globalPosition,
                      details.localPosition,
                    ),
                    onScaleStart: (details) {
                      if (state.selectionMode) {
                        notifier.startBoxSelection(details.localFocalPoint);
                        return;
                      }
                      if (_isMiddleMousePanning) return;
                      if (_isResizing || _movingItemId != null) return;

                      _baseScale = notifier.cameraScale.value;
                      _lastFocalPoint = details.focalPoint;

                      if (details.pointerCount == 1) {
                        final worldPos = notifier.screenToWorld(
                          details.localFocalPoint,
                        );

                        // 1. RESIZE HANDLES
                        bool hitHandle = false;
                        for (final group in state.groups) {
                          final handleRect = Rect.fromCenter(
                            center:
                                group.rect.bottomRight + const Offset(-10, -10),
                            width: 50,
                            height: 50,
                          );
                          if (handleRect.contains(worldPos)) {
                            setState(() {
                              _resizingGroupId = group.id;
                              _tempGroupRect = group.rect;
                              _isResizing = true;
                              _backgroundTapped = false;
                            });
                            hitHandle = true;
                            break;
                          }
                        }
                        if (!hitHandle) {
                          for (final comment in state.comments) {
                            final handleRect = Rect.fromCenter(
                              center:
                                  comment.rect.bottomRight +
                                  const Offset(-10, -10),
                              width: 50,
                              height: 50,
                            );
                            if (handleRect.contains(worldPos)) {
                              setState(() {
                                _resizingCommentId = comment.id;
                                _tempCommentSize = comment.size;
                                _isResizing = true;
                                _backgroundTapped = false;
                              });
                              hitHandle = true;
                              break;
                            }
                          }
                        }
                        if (hitHandle) return;

                        // 2. DRAGGING
                        bool hitItem = false;
                        for (final group in state.groups) {
                          final headerRect = Rect.fromLTWH(
                            group.rect.left,
                            group.rect.top,
                            group.rect.width,
                            40,
                          );
                          if (headerRect.contains(worldPos)) {
                            setState(() {
                              _movingItemId = group.id;
                              _tempItemPosition = group.rect.topLeft;
                              _moveStartOffset = worldPos - group.rect.topLeft;
                              _backgroundTapped = false;
                            });
                            hitItem = true;
                            break;
                          }
                        }
                        if (!hitItem) {
                          for (final comment in state.comments) {
                            if (comment.rect.contains(worldPos)) {
                              setState(() {
                                _movingItemId = comment.id;
                                _tempItemPosition = comment.position;
                                _moveStartOffset = worldPos - comment.position;
                                _backgroundTapped = false;
                              });
                              hitItem = true;
                              break;
                            }
                          }
                        }
                        if (hitItem) return;

                        // 3. NODES
                        final tappedNode = state.spatialHash.queryPoint(
                          worldPos,
                        );

                        if (tappedNode != null) {
                          if (state.connectionMode) {
                            notifier.startConnection(tappedNode.id);
                            _backgroundTapped = false;
                            return;
                          }

                          if (!state.selectedNodeIds.contains(tappedNode.id)) {
                            notifier.selectNode(tappedNode.id);
                          }

                          _isDraggingSelection = true;
                          _backgroundTapped = false;
                          return;
                        }

                        // 4. BACKGROUND TAP
                        _backgroundTapped = true;
                      }
                    },
                    onScaleUpdate: (details) {
                      if (_isMiddleMousePanning) return;
                      if (state.selectionMode) {
                        notifier.updateBoxSelection(details.localFocalPoint);
                        return;
                      }
                      if (_backgroundTapped &&
                          details.focalPointDelta.distance > 2.0) {
                        _backgroundTapped = false;
                      }

                      final worldDelta =
                          details.focalPointDelta / notifier.cameraScale.value;

                      if (_isResizing) {
                        if (_resizingGroupId != null &&
                            _tempGroupRect != null) {
                          final newRect = Rect.fromPoints(
                            _tempGroupRect!.topLeft,
                            _tempGroupRect!.bottomRight + worldDelta,
                          );
                          if (newRect.width > 50 && newRect.height > 50) {
                            setState(() => _tempGroupRect = newRect);
                          }
                        } else if (_resizingCommentId != null &&
                            _tempCommentSize != null) {
                          final newSize = Size(
                            _tempCommentSize!.width + worldDelta.dx,
                            _tempCommentSize!.height + worldDelta.dy,
                          );
                          if (newSize.width > 50 && newSize.height > 50) {
                            setState(() => _tempCommentSize = newSize);
                          }
                        }
                        return;
                      }

                      if (_movingItemId != null && _moveStartOffset != null) {
                        final currentWorldPos = notifier.screenToWorld(
                          details.localFocalPoint,
                        );
                        setState(() {
                          _tempItemPosition =
                              currentWorldPos - _moveStartOffset!;
                        });
                        return;
                      }

                      if (_isDraggingSelection) {
                        notifier.moveSelectedNodes(worldDelta);
                        return;
                      }

                      if (details.pointerCount > 1) {
                        notifier.scaleCamera(
                          _baseScale * details.scale,
                          details.focalPoint,
                        );
                      } else {
                        if (state.connectionStartNodeId != null) {
                          final worldPos = notifier.screenToWorld(
                            details.localFocalPoint,
                          );
                          notifier.updateConnectionPreview(worldPos);
                          final hoverNode = state.spatialHash.queryPoint(
                            worldPos,
                          );
                          notifier.hoverNode(hoverNode?.id);
                        } else {
                          notifier.panCamera(
                            details.focalPoint - _lastFocalPoint!,
                          );
                        }
                      }
                      _lastFocalPoint = details.focalPoint;
                    },
                    onScaleEnd: (details) {
                      if (_isResizing) {
                        if (_resizingGroupId != null &&
                            _tempGroupRect != null) {
                          notifier.resizeGroup(
                            _resizingGroupId!,
                            _tempGroupRect!,
                          );
                        } else if (_resizingCommentId != null &&
                            _tempCommentSize != null) {
                          notifier.resizeComment(
                            _resizingCommentId!,
                            _tempCommentSize!,
                          );
                        }
                      } else if (_movingItemId != null &&
                          _tempItemPosition != null) {
                        final isGroup = state.groups.any(
                          (g) => g.id == _movingItemId,
                        );
                        if (isGroup) {
                          final group = state.groups.firstWhere(
                            (g) => g.id == _movingItemId,
                          );
                          final delta = _tempItemPosition! - group.rect.topLeft;
                          notifier.moveGroup(_movingItemId!, delta);
                        } else {
                          final comment = state.comments.firstWhere(
                            (c) => c.id == _movingItemId,
                          );
                          final delta = _tempItemPosition! - comment.position;
                          notifier.moveComment(_movingItemId!, delta);
                        }
                      }

                      if (state.selectionMode) {
                        notifier.endBoxSelection();
                      }

                      if (state.connectionStartNodeId != null &&
                          _lastFocalPoint != null) {
                        final worldPos = notifier.screenToWorld(
                          _lastFocalPoint!,
                        );
                        final targetNode = state.spatialHash.queryPoint(
                          worldPos,
                        );
                        notifier.endConnection(targetNode?.id);
                      }
                      _lastFocalPoint = null;
                      _clearLocalInteractionState();
                    },
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<Offset>(
                        valueListenable: notifier.cameraOffset,
                        builder: (ctx, camOffset, _) =>
                            ValueListenableBuilder<double>(
                              valueListenable: notifier.cameraScale,
                              builder: (ctx2, camScale, __) {
                                final displayState =
                                    (state.offset == camOffset &&
                                        state.scale == camScale)
                                    ? state
                                    : state.copyWith(
                                        offset: camOffset,
                                        scale: camScale,
                                      );
                                return CustomPaint(
                                  painter: InfiniteCanvasPainter(
                                    displayState,
                                    frameCost: _canvasFrameCost,
                                    problematicNodeIds: _problemNodeIds,
                                    showOnlyProblematic: _showOnlyProblematic,
                                    visibleConnectionKinds:
                                        _visibleConnectionKinds,
                                    resizingGroupId: _resizingGroupId,
                                    temporaryGroupRect: _tempGroupRect,
                                    resizingCommentId: _resizingCommentId,
                                    temporaryCommentSize: _tempCommentSize,
                                    movingItemId: _movingItemId,
                                    temporaryItemPosition: _tempItemPosition,
                                  ),
                                  size: Size.infinite,
                                );
                              },
                            ),
                      ),
                    ),
                  ),
                ),

                _buildTopSearchBar(context, notifier, state.nodes),
                if (_isSearchVisible && _searchResults.isNotEmpty)
                  _buildSearchNavigation(),
                if (_problemSearchResults.isNotEmpty) _buildProblemNavigation(),

                // Невидимый барьер: тап вне пикера закрывает его.
                if (_isToolPickerVisible)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => setState(() => _isToolPickerVisible = false),
                    ),
                  ),

                // Выезжающая панель-пикер инструментов (над нижней панелью).
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 96,
                  child: SafeArea(
                    top: false,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: SizeTransition(
                              sizeFactor: anim,
                              axisAlignment: 1.0,
                              child: child,
                            ),
                          ),
                          child: _isToolPickerVisible
                              ? CanvasToolPicker(
                                  key: const ValueKey('tool_picker'),
                                  onDismiss: () => setState(
                                    () => _isToolPickerVisible = false,
                                  ),
                                  groups: _buildToolGroups(
                                    context,
                                    state,
                                    notifier,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),

                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack,
                  bottom: state.selectedNodeIds.isNotEmpty ? 96 : -80,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _buildSelectionContextBar(context, notifier, state),
                  ),
                ),

                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  bottom: state.selectedNodeIds.isNotEmpty ? -100 : 24,
                  left: 16,
                  right: 16,
                  child: SafeArea(
                    top: false,
                    child: Center(
                      child: _buildMainBottomBar(context, ref, state, notifier),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // === UI COMPONENTS ===

  Widget _buildTopSearchBar(
    BuildContext context,
    CanvasNotifier notifier,
    List<Node> allNodes,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          height: _isSearchVisible ? 80 : 0,
          curve: Curves.easeInOut,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 0, sigmaY: 0),
                  child: Container(
                    height: 56,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: scheme.outlineVariant.withOpacity(0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
                        Icon(Icons.search_rounded, color: scheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            style: TextStyle(color: scheme.onSurface),
                            decoration: InputDecoration(
                              hintText: tr('Найти ноду...'),
                              hintStyle: TextStyle(
                                color: scheme.onSurfaceVariant,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            onChanged: (query) {
                              notifier.searchNodes(query);
                              _updateSearchResults(query, allNodes);
                            },
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.close_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                          onPressed: _toggleSearch,
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

  Widget _buildSearchNavigation() {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 100,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withOpacity(0.95),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: scheme.outlineVariant.withOpacity(0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  Icons.keyboard_arrow_left_rounded,
                  color: scheme.onSurface,
                ),
                onPressed: _previousResult,
                visualDensity: VisualDensity.compact,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '${_currentSearchResultIndex + 1} / ${_searchResults.length}',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.keyboard_arrow_right_rounded,
                  color: scheme.onSurface,
                ),
                onPressed: _nextResult,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProblemNavigation() {
    final scheme = Theme.of(context).colorScheme;
    final totalIssues = _problemNodeIssueCounts.values.fold<int>(
      0,
      (sum, v) => sum + v,
    );
    return Positioned(
      top: _isSearchVisible ? 154 : 92,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withOpacity(0.95),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.error.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_rounded, color: scheme.error, size: 16),
            const SizedBox(width: 6),
            Text(
              '${_currentProblemResultIndex + 1}/${_problemSearchResults.length}',
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '• $totalIssues',
              style: TextStyle(
                color: scheme.error,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 2),
            IconButton(
              icon: Icon(
                Icons.keyboard_arrow_left_rounded,
                color: scheme.onErrorContainer,
              ),
              onPressed: _previousProblemResult,
              visualDensity: VisualDensity.compact,
              tooltip: tr('Предыдущая проблемная нода'),
            ),
            IconButton(
              icon: Icon(
                Icons.keyboard_arrow_right_rounded,
                color: scheme.onErrorContainer,
              ),
              onPressed: _nextProblemResult,
              visualDensity: VisualDensity.compact,
              tooltip: tr('Следующая проблемная нода'),
            ),
          ],
        ),
      ),
    );
  }

  /// КОНТЕКСТНАЯ ПАНЕЛЬ
  Widget _buildSelectionContextBar(
    BuildContext context,
    CanvasNotifier notifier,
    CanvasState state,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 0, sigmaY: 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withOpacity(0.92),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: scheme.outlineVariant.withOpacity(0.4)),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withOpacity(0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                trf('Выбрано: {p0}', {'p0': state.selectedNodeIds.length}),
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 1,
                height: 20,
                color: scheme.outlineVariant.withOpacity(0.6),
              ),
              const SizedBox(width: 4),
              _buildIconButton(
                icon: Icons.palette_rounded,
                tooltip: tr('Цвет ноды'),
                color: scheme.primary,
                onTap: () {
                  final node = state.nodes.firstWhere(
                    (n) => n.id == state.selectedNodeId,
                  );
                  _showColorPickerForNode(context, notifier, node.color);
                },
              ),
              _buildIconButton(
                icon: Icons.copy_rounded,
                tooltip: tr('Дублировать'),
                color: scheme.onSurfaceVariant,
                onTap: () =>
                    _handleDuplicateNode(notifier, state.selectedNodeId),
              ),
              _buildIconButton(
                icon: Icons.delete_rounded,
                tooltip: tr('Удалить'),
                color: scheme.error,
                onTap: () => _showDeleteNodeDialog(context, notifier),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// ОСНОВНАЯ ПАНЕЛЬ — компактная, частые действия видны сразу,
  /// остальное вынесено в выезжающую панель-пикер «Ещё» для лучшего UX.
  Widget _buildMainBottomBar(
    BuildContext context,
    WidgetRef ref,
    CanvasState state,
    CanvasNotifier notifier,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 0, sigmaY: 0),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withOpacity(0.92),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: scheme.outlineVariant.withOpacity(0.4)),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withOpacity(0.28),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          // На узких экранах кнопок может быть больше, чем помещается
          // по ширине — даём горизонтальный скролл вместо overflow.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Новая нода — основное действие (акцент)
                KeyedSubtree(
                  key: _addNodeBtnKey,
                  child: _buildToolbarButton(
                    icon: Icons.add_rounded,
                    tooltip: tr('Новая нода'),
                    color: scheme.onPrimaryContainer,
                    bgColor: scheme.primaryContainer,
                    isHighEmphasis: true,
                    onPressed: () {
                      final tutorial = ref.read(tutorialControllerProvider);
                      if (tutorial.step == TutorialStep.addNodeHighlight) {
                        final idx = _tutorialAddNodeClicks.clamp(0, 2);
                        notifier.addTutorialNode(
                          idx,
                          MediaQuery.of(context).size,
                        );
                        _tutorialAddNodeClicks++;
                        if (_tutorialAddNodeClicks >= 3) {
                          ref.read(tutorialControllerProvider.notifier).next();
                        }
                      } else {
                        notifier.addNode(MediaQuery.of(context).size);
                      }
                    },
                  ),
                ),
                // Играть — основное действие (акцент)
                KeyedSubtree(
                  key: _playBtnKey,
                  child: _buildToolbarButton(
                    icon: Icons.play_arrow_rounded,
                    tooltip: tr('Играть'),
                    color: scheme.onTertiaryContainer,
                    bgColor: scheme.tertiaryContainer,
                    isHighEmphasis: true,
                    onPressed: () async {
                      final tutorial = ref.read(tutorialControllerProvider);
                      if (tutorial.step == TutorialStep.runQuestHighlight) {
                        ref.read(tutorialControllerProvider.notifier).next();
                      }
                      final quest = await ref.read(
                        questProvider(widget.questId).future,
                      );
                      if (context.mounted) {
                        EditorDocumentLauncher.openGameSimulation(
                          context,
                          widget.questId,
                          startNodeId: quest?.startNodeId,
                        );
                      }
                    },
                  ),
                ),
                // Играть из сохранения
                _buildToolbarButton(
                  icon: Icons.history_rounded,
                  tooltip: tr('Играть из сохранения'),
                  color: scheme.onSurfaceVariant,
                  onPressed: () {
                    EditorDocumentLauncher.openGameFromSave(
                      context,
                      widget.questId,
                    );
                  },
                ),
                _buildDivider(),
                // Связи (toggle)
                KeyedSubtree(
                  key: _connectBtnKey,
                  child: _buildToolbarButton(
                    icon: Icons.gesture_rounded,
                    tooltip: tr('Связи'),
                    color: state.connectionMode
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                    isActive: state.connectionMode,
                    onPressed: () {
                      final tutorial = ref.read(tutorialControllerProvider);
                      if (tutorial.step == TutorialStep.connectModeHighlight) {
                        ref.read(tutorialControllerProvider.notifier).next();
                      }
                      notifier.toggleConnectionMode();
                    },
                  ),
                ),
                // Поиск (toggle)
                _buildToolbarButton(
                  icon: Icons.search_rounded,
                  tooltip: tr('Поиск'),
                  color: _isSearchVisible
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  isActive: _isSearchVisible,
                  onPressed: _toggleSearch,
                ),
                // Ещё — выезжающая панель-пикер инструментов
                _buildToolbarButton(
                  icon: _isToolPickerVisible
                      ? Icons.close_rounded
                      : Icons.more_horiz_rounded,
                  tooltip: tr('Ещё'),
                  color: _isToolPickerVisible
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  isActive: _isToolPickerVisible,
                  onPressed: () => setState(
                    () => _isToolPickerVisible = !_isToolPickerVisible,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Группы инструментов для выезжающей панели-пикера.
  /// Каждый инструмент: иконка + название + описание (для long-press).
  List<CanvasToolGroup> _buildToolGroups(
    BuildContext context,
    CanvasState state,
    CanvasNotifier notifier,
  ) {
    final allArrows =
        _visibleConnectionKinds.length == ConnectionKind.values.length;
    return [
      CanvasToolGroup(
        title: tr('Разметка'),
        tools: [
          CanvasTool(
            icon: Icons.crop_square_rounded,
            label: tr('Создать группу'),
            description: tr(
              'Объединить ноды в визуальную группу с названием и цветом.',
            ),
            onTap: () => _showGroupDialog(notifier),
          ),
          CanvasTool(
            icon: Icons.sticky_note_2_outlined,
            label: tr('Добавить заметку'),
            description: tr('Разместить текстовый стикер на холсте.'),
            onTap: () {
              notifier.addComment(
                notifier.screenToWorld(
                  MediaQuery.of(context).size.center(Offset.zero),
                ),
              );
            },
          ),
        ],
      ),
      CanvasToolGroup(
        title: tr('Шаблоны'),
        tools: [
          CanvasTool(
            icon: Icons.bookmark_added_rounded,
            label: tr('Вставить из шаблона'),
            description: tr('Создать ноду на основе сохранённого шаблона.'),
            onTap: () => _insertNodeFromTemplate(notifier),
          ),
          CanvasTool(
            icon: Icons.collections_bookmark_rounded,
            label: tr('Менеджер шаблонов'),
            description: tr(
              'Управление шаблонами нод этого квеста и глобальной библиотекой.',
            ),
            onTap: _openTemplateManager,
          ),
        ],
      ),
      CanvasToolGroup(
        title: tr('Вид и связи'),
        tools: [
          CanvasTool(
            icon: Icons.filter_alt_rounded,
            label: tr('Фильтр стрелок'),
            description: tr(
              'Показывать только нужные типы связей между нодами.',
            ),
            isActive: !allArrows,
            badge: allArrows
                ? null
                : '${_visibleConnectionKinds.length}'
                      '/${ConnectionKind.values.length}',
            onTap: _showConnectionFilterDialog,
          ),
          CanvasTool(
            icon: Icons.select_all_rounded,
            label: tr('Мульти-выделение'),
            description: tr(
              'Выделять несколько нод рамкой для групповых операций.',
            ),
            isActive: state.selectionMode,
            onTap: notifier.toggleSelectionMode,
          ),
          CanvasTool(
            icon: state.isSnapToGridEnabled
                ? Icons.grid_on_rounded
                : Icons.grid_off_rounded,
            label: tr('Привязка к сетке'),
            description: tr(
              'Ноды автоматически выравниваются по сетке при перемещении.',
            ),
            isActive: state.isSnapToGridEnabled,
            onTap: notifier.toggleSnapToGrid,
          ),
          CanvasTool(
            icon: Icons.auto_fix_high_rounded,
            label: tr('Выровнять ноды'),
            description: tr(
              'Автоматически расставить все ноды на холсте по структуре.',
            ),
            onTap: () => _showTidyUpConfirmationDialog(notifier),
          ),
          CanvasTool(
            icon: Icons.center_focus_strong_rounded,
            label: tr('Сбросить камеру'),
            description: tr(
              'Вернуть масштаб и положение холста к начальному виду.',
            ),
            onTap: notifier.resetCamera,
          ),
        ],
      ),
      CanvasToolGroup(
        title: tr('Проблемы'),
        tools: [
          CanvasTool(
            icon: Icons.error_outline_rounded,
            label: _showOnlyProblematic
                ? tr('Скрыть проблемные')
                : tr('Показать проблемные'),
            description: tr(
              'Подсветить на холсте только ноды с битыми ссылками и ошибками.',
            ),
            isActive: _showOnlyProblematic,
            badge: _problemNodeIds.isEmpty ? null : '${_problemNodeIds.length}',
            onTap: () {
              setState(() {
                _showOnlyProblematic = !_showOnlyProblematic;
              });
              if (_showOnlyProblematic && _problemSearchResults.isNotEmpty) {
                _jumpToNode(_problemSearchResults[_currentProblemResultIndex]);
              }
            },
          ),
          CanvasTool(
            icon: Icons.fact_check_rounded,
            label: tr('Проверить квест'),
            description: tr(
              'Полный статический анализ квеста: битые ссылки, недостижимые ноды, конфликты видимости.',
            ),
            onTap: () => unawaited(_openQuestValidation()),
          ),
          CanvasTool(
            icon: Icons.refresh_rounded,
            label: tr('Пересканировать'),
            description: tr(
              'Заново проверить все ноды на битые ссылки и ошибки.',
            ),
            onTap: () => unawaited(_refreshProblemNodes()),
          ),
        ],
      ),
    ];
  }

  Widget _buildDivider() {
    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return Container(
          width: 1,
          height: 24,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          color: scheme.outlineVariant.withOpacity(0.5),
        );
      },
    );
  }

  Widget _buildToolbarButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    Color? bgColor,
    VoidCallback? onPressed,
    bool isActive = false,
    bool isHighEmphasis = false,
  }) {
    final double size = isHighEmphasis ? 48 : 44;
    final double radius = isHighEmphasis ? 16 : 12;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: Colors.transparent,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(radius),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: isActive
                    ? color.withOpacity(0.16)
                    : (bgColor ?? Colors.transparent),
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Icon(icon, color: color, size: isHighEmphasis ? 26 : 22),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(icon, color: color, size: 20),
          ),
        ),
      ),
    );
  }
}
