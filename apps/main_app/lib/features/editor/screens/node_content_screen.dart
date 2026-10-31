import 'dart:async';
import 'dart:convert';
import 'package:canvas_app/core/services/refactoring_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/services/template_asset_installer.dart';
import 'package:canvas_app/core/utils/content_item_utils.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_player/utils/trigger_reference.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:canvas_app/features/editor/providers/content_clipboard_provider.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/providers/template_provider.dart';
import 'package:canvas_app/features/editor/utils/template_applier.dart';
import 'package:canvas_app/features/editor/widgets/editor_ui.dart';
import 'package:canvas_app/features/editor/widgets/content_add_menu.dart';
import 'package:canvas_app/features/editor/widgets/template_picker_sheet.dart';
import 'package:canvas_app/features/editor/widgets/template_save_dialog.dart';
import 'package:canvas_app/features/editor/services/script_providers.dart';
import 'package:canvas_app/features/editor/services/trigger_service.dart';
import 'package:canvas_app/features/editor/services/trigger_validation_service.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/features/editor/screens/node_content/content_editor_logic.dart';
import 'package:canvas_app/features/editor/logic/item_editor_helper.dart';
import 'package:canvas_app/features/editor/screens/node_content/content_item_card.dart';
import 'package:canvas_app/features/editor/screens/node_settings_screen.dart';
import 'package:canvas_app/features/editor/workspace/editor_back_handler.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_lifecycle.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/features/plugins/models/plugin_content_type.dart';
import 'package:canvas_app/features/plugins/providers/plugin_content_types_provider.dart';
import 'package:canvas_app/features/editor/widgets/plugin_content_form.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

class NodeContentScreen extends ConsumerStatefulWidget {
  final String questId;
  final String nodeId;
  final bool fromGameSession;

  const NodeContentScreen({
    super.key,
    required this.questId,
    required this.nodeId,
    this.fromGameSession = false,
  });

  @override
  ConsumerState<NodeContentScreen> createState() => _NodeContentScreenState();
}

class _NodeContentScreenState extends ConsumerState<NodeContentScreen> {
  late ContentEditorLogic _logic;

  late TextEditingController _titleController;
  late TextEditingController _timerController;
  final ScrollController _editorScrollController = ScrollController();

  List<ContentItem> _contentItems = [];
  SavedNode? _initialNode;

  final Map<String, String> _resourceNames = {};
  final Map<String, TriggerValidationIssue> _onAppearIssuesByItemId = {};

  bool _isDirty = false;
  bool _isSaving = false;
  bool _isLoading = true;
  bool _hasLoadError = false;
  Timer? _debounceTimer;
  StreamSubscription<RefactorRenameEvent>? _renameSub;

  // Background Image
  String? _selectedBackgroundId;
  String? _selectedBackgroundName;

  // Background Video
  String? _selectedBackgroundVideoId;
  String? _selectedBackgroundVideoName;
  double _videoVolume = 1.0;
  bool _videoLoop = true;
  bool _videoMuted = true;
  String _videoFit = 'cover';
  double?
  _backgroundBlur; // null = по умолчанию (10 или скрипт), 0 = без размытия

  // Background Audio
  String? _selectedAudioId;
  String? _selectedAudioName;
  double _audioVolume = 1.0;

  // Наследие HUD-панели: плеер эти флаги больше не читает, и UI для них в
  // настройках ноды убран. Значения по-прежнему читаются из ноды и пишутся
  // обратно — иначе saveNodes вычистил бы ключи из чужих квестов.
  bool _allowSave = true;
  bool _allowInventoryAccess = true;

  // Внутренний отступ между корневыми элементами ноды.
  // null → старое поведение (24 px в игре), 0 → без зазоров.
  double? _nodeItemSpacing;
  bool? _nodeImageRoundedCorners;

  // Стиль перехода В ЭТУ ноду; '' = как в квесте (глобальный режим).
  String _nodeTransitionMode = '';

  bool _timerEnabled = false;
  bool _timerHidden = false;
  String? _defaultActionNodeId;
  String _defaultActionNodeName = tr('Не выбрана');

  /// Лок сохранения: вместо busy-wait поллинга (`Future.delayed(50)`)
  /// используем Completer — ожидающий ждёт ровно до завершения активного
  /// сохранения, без лишних тиков таймера.
  Completer<void>? _saveLock;

  @override
  void initState() {
    super.initState();

    _logic = ContentEditorLogic(
      context: context,
      questId: widget.questId,
      currentNodeId: widget.nodeId,
    );

    _titleController = TextEditingController();
    _timerController = TextEditingController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _docHandle?.registerRuntime(
        EditorDocumentRuntime(
          onSave: () => _saveNode(force: true),
          onBeforeClose: () async {
            if (!_isDirty) return true;
            return _saveNode(force: true);
          },
        ),
      );
      _loadNodeData();
    });
    _renameSub = RefactoringService.renameEvents.listen(_onRenameEvent);

    _titleController.addListener(_markDirtyAndSave);
    _timerController.addListener(_markDirtyAndSave);
  }

  /// Захваченная ссылка на документ воркспейса (без context-lookup'ов
  /// из таймеров и колбэков после деактивации).
  EditorDocumentHandle? _docHandle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final captured = EditorDocumentLifecycle.capture(context);
    if (captured?.id != _docHandle?.id) {
      _docHandle?.invalidated = true;
      _docHandle = captured;
    }

    // Вкладку ноды убрали с экрана (открыли вложенный редактор, LRU, смена
    // главы): debounce в 2 с до этого может не успеть, а при обратном
    // переходе экран перечитает ноду с диска и потерянные правки сотрут.
    final active = EditorDocumentContext.maybeOf(context)?.isActive ?? true;
    if (_wasActive && !active) {
      final pending = _debounceTimer;
      if (pending != null || _isDirty) {
        pending?.cancel();
        _debounceTimer = null;
        unawaited(_saveNode(force: true));
      }
    }
    _wasActive = active;
  }

  bool _wasActive = true;

  @override
  void dispose() {
    _renameSub?.cancel();
    _debounceTimer?.cancel();
    _docHandle?.invalidated = true;
    _titleController.dispose();
    _timerController.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }

  void _onRenameEvent(RefactorRenameEvent event) {
    if (!mounted) return;
    if (event.questId != widget.questId) return;

    final oldTitle = _titleController.text;
    final newTitle = _replaceRenameText(oldTitle, event.oldName, event.newName);

    final jsonItems = _contentItems.map((item) => item.toJson()).toList();
    final contentChanged = _walkAndReplaceRename(
      jsonItems,
      event.oldName,
      event.newName,
    );
    final titleChanged = newTitle != oldTitle;

    if (!contentChanged && !titleChanged) {
      print(
        '[Refactor][NodeContent] No in-memory changes for "${event.oldName}" -> "${event.newName}"',
      );
      return;
    }

    final updatedItems = <ContentItem>[];
    for (final raw in jsonItems) {
      updatedItems.add(ContentItem.fromJson(raw));
    }

    final selection = _titleController.selection;
    setState(() {
      _contentItems = updatedItems;
      _isDirty = true;
      if (titleChanged) {
        _titleController.value = TextEditingValue(
          text: newTitle,
          selection: selection,
        );
      }
    });

    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      const Duration(milliseconds: 250),
      () => _saveNode(force: true),
    );

    print(
      '[Refactor][NodeContent] In-memory node content updated and save scheduled',
    );
  }

  bool _walkAndReplaceRename(
    dynamic target,
    String oldName,
    String newName, {
    String? currentKey,
  }) {
    const exactKeys = {
      'variableName',
      'variable',
      'переменная',
      'targetVariable',
    };
    const neverReplace = {
      'id',
      'targetNodeId',
      'scriptAssetId',
      'resourcePath',
      'path',
      'fileName',
      'questId',
      'nodeId',
      'fromId',
      'toId',
      'chapterId',
    };

    bool changed = false;

    if (target is Map) {
      final keys = target.keys.toList();
      for (final key in keys) {
        final keyStr = key.toString();
        final value = target[key];

        if (exactKeys.contains(keyStr) && value == oldName) {
          target[key] = newName;
          changed = true;
          continue;
        }

        if (value is String) {
          if (neverReplace.contains(keyStr)) continue;
          final replaced = _replaceRenameText(value, oldName, newName);
          if (replaced != value) {
            target[key] = replaced;
            changed = true;
          }
          continue;
        }

        if (_walkAndReplaceRename(
          value,
          oldName,
          newName,
          currentKey: keyStr,
        )) {
          changed = true;
        }
      }
      return changed;
    }

    if (target is List) {
      for (int i = 0; i < target.length; i++) {
        final value = target[i];
        if (value is String &&
            (currentKey == null || !neverReplace.contains(currentKey))) {
          final replaced = _replaceRenameText(value, oldName, newName);
          if (replaced != value) {
            target[i] = replaced;
            changed = true;
          }
          continue;
        }

        if (_walkAndReplaceRename(
          value,
          oldName,
          newName,
          currentKey: currentKey,
        )) {
          changed = true;
        }
      }
    }

    return changed;
  }

  String _replaceRenameText(String input, String oldName, String newName) {
    final placeholder =
        '__mnd_refactor_placeholder_${oldName.hashCode}_${newName.hashCode}__';
    String result = input.replaceAll('{$oldName}', '{$placeholder}');
    final escapedOld = RegExp.escape(oldName);
    final regExp = RegExp(
      r'(?<![a-zA-Z0-9_])' + escapedOld + r'(?![a-zA-Z0-9_])',
    );
    result = result.replaceAll(regExp, newName);
    result = result.replaceAll('{$placeholder}', '{$newName}');
    return result;
  }

  void _markDirtyAndSave() {
    if (_isLoading || _hasLoadError) return;
    _detachBoundInstance();
    if (!_isDirty) {
      setState(() => _isDirty = true);
      _docHandle?.markDirty(true);
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 2), () => _saveNode());
  }

  /// Правка linked-инстанса отвязывает ноду от шаблона. Пока связь есть,
  /// в игру идёт payload мастера и локальные изменения молча исчезали, а
  /// тестер видел кнопки, которых автор уже не добавлял (#179). Копией
  /// становится ровно то, что автор видит на экране.
  void _detachBoundInstance() {
    final node = _initialNode;
    if (node == null || !node.isTemplateInstance) return;

    final detached = TemplateApplier.detachNode(
      node.copyWith(
        content: {'items': _contentItems.map((item) => item.toJson()).toList()},
      ),
    );
    final items = detached.content['items'] as List<dynamic>? ?? const [];
    final parsed = <ContentItem>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      try {
        parsed.add(ContentItem.fromJson(Map<String, dynamic>.from(raw)));
      } catch (_) {
        // сломанный ряд из мастера не должен ронять экран
      }
    }
    setState(() {
      _initialNode = detached;
      _contentItems = parsed;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr('Нода отвязана от шаблона — дальше это самостоятельная копия'),
        ),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Set<String> _collectTargetNodeIdsFromItems(List<ContentItem> items) {
    final targets = <String>{};

    void walk(ContentItem item) {
      final target = item.targetNodeId?.trim();
      if (target != null && target.isNotEmpty && !target.startsWith('=')) {
        targets.add(target);
      }
      final children = item.children;
      if (children != null && children.isNotEmpty) {
        for (final child in children) {
          walk(child);
        }
      }
    }

    for (final item in items) {
      walk(item);
    }
    return targets;
  }

  String _resolveFriendlyResourceName(String? rawIdOrPath) {
    if (rawIdOrPath == null || rawIdOrPath.trim().isEmpty) {
      return '';
    }

    final raw = rawIdOrPath.trim();
    final base = p.basename(raw);
    final baseNoExt = p.basenameWithoutExtension(base).toLowerCase();

    final direct = _resourceNames[raw] ?? _resourceNames[base];
    if (direct != null && direct.trim().isNotEmpty) {
      return direct;
    }

    for (final entry in _resourceNames.entries) {
      final keyBase = p.basename(entry.key);
      final keyNoExt = p.basenameWithoutExtension(keyBase).toLowerCase();
      if (keyBase == base || keyNoExt == baseNoExt) {
        final val = entry.value.trim();
        if (val.isNotEmpty) return val;
      }
    }

    return base;
  }

  /// Хранилище квеста через ядро (план 020-C).
  QuestStore? _questStoreCached;
  Future<QuestStore> _questStore() async =>
      _questStoreCached ??= await QuestStore.create();

  Future<TriggerValidationIssue?> _validateOnAppearIssue(ContentItem item) {
    final validator = ref.read(
      triggerValidationServiceProvider(widget.questId),
    );
    return validator.validateOnAppear(
      itemId: item.id,
      rawTrigger: item.scriptForEvent('onAppear'),
    );
  }

  Future<void> _refreshOnAppearIssues() async {
    final snapshot = List<ContentItem>.from(_contentItems);
    final futures = snapshot.map((item) async {
      final issue = await _validateOnAppearIssue(item);
      return MapEntry(item.id, issue);
    }).toList();
    final entries = await Future.wait(futures);
    final nextMap = <String, TriggerValidationIssue>{};
    for (final e in entries) {
      if (e.value != null) nextMap[e.key] = e.value!;
    }
    if (!mounted) return;
    setState(() {
      _onAppearIssuesByItemId
        ..clear()
        ..addAll(nextMap);
    });
  }

  Future<bool> _saveNode({bool isExiting = false, bool force = false}) async {
    // Runtime-колбэк (flushDirtyDocuments) может прийти уже после dispose
    // экрана — setState на defunct State запрещён. Сохранять нечего.
    if (!mounted) return true;
    if (_isLoading || _hasLoadError || _initialNode == null) return false;
    if (_isSaving && !force && !isExiting) return false;

    setState(() => _isSaving = true);

    while (_saveLock != null) {
      await _saveLock!.future;
    }
    _saveLock = Completer<void>();

    try {
      final updatedNode = SavedNode(
        id: _initialNode!.id,
        chapterId: _initialNode!.chapterId,
        x: _initialNode!.x,
        y: _initialNode!.y,
        scriptAssetId: _initialNode!.scriptAssetId,
        title: _titleController.text.trim(),
        content: {'items': _contentItems.map((item) => item.toJson()).toList()},
        backgroundAssetId: _selectedBackgroundId,
        backgroundVideoAssetId: _selectedBackgroundVideoId,
        backgroundVideoVolume: _selectedBackgroundVideoId != null
            ? _videoVolume
            : null,
        backgroundVideoLoop: _selectedBackgroundVideoId != null
            ? _videoLoop
            : null,
        backgroundVideoMuted: _selectedBackgroundVideoId != null
            ? _videoMuted
            : null,
        backgroundVideoFit: _selectedBackgroundVideoId != null
            ? _videoFit
            : null,
        backgroundBlur: _backgroundBlur,
        backgroundAudioId: _selectedAudioId,
        backgroundAudioVolume: _audioVolume,
        allowSave: _allowSave,
        allowInventoryAccess: _allowInventoryAccess,
        itemSpacing: _nodeItemSpacing,
        imageRoundedCorners: _nodeImageRoundedCorners,
        transitionMode: _nodeTransitionMode.isEmpty
            ? null
            : _nodeTransitionMode,
        timerDuration: _timerEnabled
            ? double.tryParse(_timerController.text.trim().replaceAll(',', '.'))
            : null,
        defaultActionNodeId: _timerEnabled ? _defaultActionNodeId : null,
        timerHidden: _timerEnabled && _timerHidden ? true : null,
        // Канвас и шаблоны владеют этими полями, редактор контента их не
        // показывает и не меняет. Без переноса saveNodes вычистил бы их из
        // файла: цвет ноды пропадал после любой правки контента, а нода
        // незаметно отвязывалась от мастер-шаблона.
        color: _initialNode!.color,
        templateRef: _initialNode!.templateRef,
        templateVersion: _initialNode!.templateVersion,
        isTemplateMaster: _initialNode!.isTemplateMaster,
      );

      await updateNode(widget.questId, updatedNode);
      final desiredTargets = _collectTargetNodeIdsFromItems(_contentItems);
      await syncOutgoingConnections(
        widget.questId,
        widget.nodeId,
        desiredTargets,
      );
      ref.invalidate(allQuestNodesProvider(widget.questId));
      ref.invalidate(canvasIndexProvider(widget.questId));

      try {
        // План 020-C4.2: атомарные записи через QuestStore.
        final store = await _questStore();
        final configPath = QuestPaths.config(widget.questId);
        if (await store.exists(configPath)) {
          final config = await store.readJson(configPath);
          if (config != null) {
            final editedAt = DateTime.now().toIso8601String();
            config['lastEditedAt'] = editedAt;
            // Старый ключ оставляем для совместимости с прежними клиентами.
            config['updated'] = editedAt;
            await store.writeJson(configPath, config);
          }
        }
      } catch (e) {
        print("Ошибка обновления даты квеста: $e");
      }

      // Синхронизируем мастер-элементы в репозиторий шаблонов. Если есть
      // изменения — `contentVersion` инкрементнётся и все linked-инстансы
      // в других нодах автоматически обновятся через резолвер.
      try {
        await _syncMasterTemplates();
      } catch (e) {
        // ignore: avoid_print
        print('[Templates] sync master failed: $e');
      }

      if (mounted && !isExiting) {
        setState(() {
          _initialNode = updatedNode;
          _isDirty = false;
        });
        _docHandle?.markDirty(false);
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Ошибка сохранения: {p0}', {'p0': friendlyError(e)}),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    } finally {
      final lock = _saveLock;
      _saveLock = null;
      lock?.complete();
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _loadNodeData() async {
    setState(() {
      _isLoading = true;
      _hasLoadError = false;
      _onAppearIssuesByItemId.clear();
    });

    try {
      // Параллельно грузим кэш имён и ноды — раньше было последовательно.
      // Инвалидируем чтобы не показать протухший список после создания ноды.
      ref.invalidate(allQuestNodesProvider(widget.questId));
      ref.invalidate(canvasIndexProvider(widget.questId));
      final svc = ref.read(resourceServiceProvider(widget.questId));

      Future<(SavedNode?, List<SavedNode>)> loadEditorNode() async {
        if (await QuestNodesStore.hasPerNodeIndex(widget.questId)) {
          final body = await QuestNodesStore.readNode(
            widget.questId,
            widget.nodeId,
          );
          final index = await QuestNodesStore.readIndex(widget.questId);
          final summaries = [
            for (final raw in (index['nodes'] as List<dynamic>? ?? []))
              if (raw is Map)
                SavedNode.fromJson(Map<String, dynamic>.from(raw)),
          ];
          return (body == null ? null : SavedNode.fromJson(body), summaries);
        }
        final all = await ref.read(
          allQuestNodesProvider(widget.questId).future,
        );
        return (all.firstWhereOrNull((n) => n.id == widget.nodeId), all);
      }

      final results = await Future.wait<dynamic>([
        svc
            .loadNameCache()
            .then((_) {
              _resourceNames
                ..clear()
                ..addAll(svc.nameCache);
            })
            .catchError((_) {}),
        loadEditorNode(),
      ]);
      final loaded = results[1] as (SavedNode?, List<SavedNode>);
      final found = loaded.$1;
      final allNodes = loaded.$2;

      if (found == null) {
        if (mounted) Navigator.pop(context);
        return;
      }

      // Linked-инстанс отдаёт в игру payload мастера: его собственный `content`
      // не читает ни `resolve_node` в движке, ни резолвер на клиенте. Без
      // разрешения автор видел пустой список (или свои строки), а тестер —
      // кнопки мастера, которых «в контенте нет» (#179).
      var node = found;
      if (node.isTemplateInstance) {
        try {
          final resolver = await ref.read(
            templateInstanceResolverProvider(widget.questId).future,
          );
          node = resolver.resolveNode(node);
        } catch (e) {
          // Резолвер не поднялся: остаёмся на локальном содержимом, а первая
          // правка всё равно отвяжет ноду (`_detachBoundInstance`).
          // ignore: avoid_print
          print('[Templates] не удалось разрешить инстанс ноды: $e');
        }
      }

      _initialNode = node;
      _titleController.text = node.title;

      final items = node.content['items'] as List<dynamic>? ?? [];
      _contentItems = [];
      for (var item in items) {
        try {
          _contentItems.add(ContentItem.fromJson(item));
        } catch (e) {
          // ignore broken item
        }
      }
      // Типы контента плагинов догружаем фоном: узел не должен ждать FFI.
      unawaited(_ensurePluginIdsForContentItems());

      if (node.timerDuration != null) {
        _timerEnabled = true;
        _timerController.text = node.timerDuration.toString();
        _timerHidden = node.timerHidden ?? false;
        _defaultActionNodeId = node.defaultActionNodeId;
        if (_defaultActionNodeId != null) {
          final target = allNodes.firstWhereOrNull(
            (n) => n.id == _defaultActionNodeId,
          );
          _defaultActionNodeName = target?.title ?? tr('Нода не найдена');
        }
      } else {
        _timerHidden = false;
      }

      if (node.backgroundAssetId != null) {
        _selectedBackgroundId = node.backgroundAssetId;
        _selectedBackgroundName = _resolveFriendlyResourceName(
          node.backgroundAssetId,
        );
      }

      if (node.backgroundVideoAssetId != null) {
        _selectedBackgroundVideoId = node.backgroundVideoAssetId;
        _selectedBackgroundVideoName = _resolveFriendlyResourceName(
          node.backgroundVideoAssetId,
        );
        _videoVolume = node.backgroundVideoVolume ?? 1.0;
        _videoLoop = node.backgroundVideoLoop ?? true;
        _videoMuted = node.backgroundVideoMuted ?? true;
        _videoFit = node.backgroundVideoFit ?? 'cover';
      }
      _backgroundBlur = node.backgroundBlur;

      if (node.backgroundAudioId != null) {
        _selectedAudioId = node.backgroundAudioId;
        _selectedAudioName = _resolveFriendlyResourceName(
          node.backgroundAudioId,
        );
      }
      _audioVolume = node.backgroundAudioVolume ?? 1.0;
      _allowSave = node.allowSave;
      _allowInventoryAccess = node.allowInventoryAccess;
      _nodeItemSpacing = node.itemSpacing;
      _nodeImageRoundedCorners = node.imageRoundedCorners;
      // Санитизация: неизвестные значения (например, выключенный 'flip')
      // → «как в квесте», чтобы DropdownButton не упал на value вне items.
      final rawTransition = node.transitionMode ?? '';
      _nodeTransitionMode =
          const {
            '',
            'none',
            'fade',
            'dark',
            'page',
            'slide',
            'slideUp',
            'zoom',
            'blur',
            'wipe',
          }.contains(rawTransition)
          ? rawTransition
          : '';
      // Не блокируем первый кадр валидацией — покажем контент сразу
      if (mounted) {
        setState(() => _isLoading = false);
      }
      // Валидацию догрузим после отрисовки, параллельно
      unawaited(
        Future.microtask(() async {
          if (!mounted) return;
          await _refreshOnAppearIssues();
        }),
      );
      return;
    } catch (e) {
      setState(() => _hasLoadError = true);
    } finally {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _ensurePluginIdsForContentItems() async {
    final pluginTypes = await ref.read(pluginContentTypesProvider.future);
    if (pluginTypes.isEmpty) return;
    final map = {for (final type in pluginTypes) type.id: type.pluginId};
    var changed = false;
    final updated = <ContentItem>[];
    for (final item in _contentItems) {
      if (item.type == 'plugin' &&
          (item.pluginId == null || item.pluginId!.trim().isEmpty)) {
        final typeId = item.pluginTypeId;
        final pluginId = typeId == null ? null : map[typeId];
        if (pluginId != null && pluginId.isNotEmpty) {
          updated.add(item.copyWith(pluginId: pluginId));
          changed = true;
          continue;
        }
      }
      updated.add(item);
    }
    if (changed && mounted) {
      setState(() => _contentItems = updated);
      _isDirty = true;
    }
  }

  Future<void> _jumpToNode(String targetNodeId) async {
    _debounceTimer?.cancel();
    final saved = await _saveNode(force: true);
    if (!saved) return;
    if (!mounted) return;
    if (widget.fromGameSession) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => NodeContentScreen(
            questId: widget.questId,
            nodeId: targetNodeId,
            fromGameSession: true,
          ),
        ),
      );
      return;
    }

    await EditorDocumentLauncher.openNode(
      context,
      widget.questId,
      targetNodeId,
    );
  }

  /// Закрывает все вложенные `NodeContentScreen` и возвращает пользователя
  /// на канвас (или предыдущий корневой экран). Использует [Navigator.popUntil]
  /// — снимает экраны до тех пор, пока на верху стека не окажется экран,
  /// который НЕ является `NodeContentScreen`.
  Future<void> _returnToCanvas() async {
    final saved = await _saveNode(force: true);
    if (!saved) return;
    if (!mounted) return;
    if (widget.fromGameSession) {
      Navigator.of(context).popUntil((route) {
        if (route.isFirst) return true;
        if (route is! MaterialPageRoute) return false;
        final routeWidget = route.builder(route.navigator!.context);
        return routeWidget is! NodeContentScreen;
      });
      return;
    }

    await EditorDocumentLauncher.openCanvas(
      context,
      widget.questId,
      _initialNode!.chapterId,
    );
  }

  Future<void> _openNodeSettings() async {
    if (_initialNode == null) return;
    final result = await Navigator.push<NodeSettingsResult>(
      context,
      MaterialPageRoute(
        builder: (context) => NodeSettingsScreen(
          questId: widget.questId,
          nodeId: widget.nodeId,
          initialBackgroundId: _selectedBackgroundId,
          initialBackgroundName: _selectedBackgroundName,
          initialBackgroundVideoId: _selectedBackgroundVideoId,
          initialBackgroundVideoName: _selectedBackgroundVideoName,
          initialVideoVolume: _videoVolume,
          initialVideoLoop: _videoLoop,
          initialVideoMuted: _videoMuted,
          initialVideoFit: _videoFit,
          initialBackgroundBlur: _backgroundBlur,
          initialAudioId: _selectedAudioId,
          initialAudioName: _selectedAudioName,
          initialAudioVolume: _audioVolume,
          initialItemSpacing: _nodeItemSpacing,
          initialImageRoundedCorners: _nodeImageRoundedCorners,
          initialTransitionMode: _nodeTransitionMode,
          initialTimerEnabled: _timerEnabled,
          initialTimerHidden: _timerHidden,
          initialTimerDurationText: _timerController.text,
          initialDefaultActionNodeId: _defaultActionNodeId,
          initialDefaultActionNodeName: _defaultActionNodeName,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedBackgroundId = result.backgroundAssetId;
      _selectedBackgroundName = result.backgroundAssetName;
      _selectedBackgroundVideoId = result.backgroundVideoAssetId;
      _selectedBackgroundVideoName = result.backgroundVideoAssetName;
      _videoVolume = result.videoVolume;
      _videoLoop = result.videoLoop;
      _videoMuted = result.videoMuted;
      _videoFit = result.videoFit;
      _backgroundBlur = result.backgroundBlur;
      _selectedAudioId = result.backgroundAudioId;
      _selectedAudioName = result.backgroundAudioName;
      _audioVolume = result.audioVolume;
      _nodeItemSpacing = result.itemSpacing;
      _nodeImageRoundedCorners = result.imageRoundedCorners;
      _nodeTransitionMode = result.transitionMode;
      _timerEnabled = result.timerEnabled;
      _timerHidden = result.timerHidden;
      _timerController.text = result.timerDurationText;
      _defaultActionNodeId = result.defaultActionNodeId;
      _defaultActionNodeName = result.defaultActionNodeName;
    });
    // Автосохранение при выходе из экрана настроек — сразу форсируем
    await _saveNode(force: true);
  }

  void _copyNodeId() {
    Clipboard.setData(ClipboardData(text: widget.nodeId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('ID ноды скопирован')),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _copyNodeJson() {
    if (_initialNode == null) return;
    try {
      final currentNodeState = SavedNode(
        id: _initialNode!.id,
        chapterId: _initialNode!.chapterId,
        x: _initialNode!.x,
        y: _initialNode!.y,
        scriptAssetId: _initialNode!.scriptAssetId,
        title: _titleController.text.trim(),
        content: {'items': _contentItems.map((item) => item.toJson()).toList()},
        backgroundAssetId: _selectedBackgroundId,
        backgroundVideoAssetId: _selectedBackgroundVideoId,
        backgroundVideoVolume: _selectedBackgroundVideoId != null
            ? _videoVolume
            : null,
        backgroundVideoLoop: _selectedBackgroundVideoId != null
            ? _videoLoop
            : null,
        backgroundVideoMuted: _selectedBackgroundVideoId != null
            ? _videoMuted
            : null,
        backgroundVideoFit: _selectedBackgroundVideoId != null
            ? _videoFit
            : null,
        backgroundBlur: _backgroundBlur,
        timerDuration: _timerEnabled
            ? double.tryParse(_timerController.text)
            : null,
        defaultActionNodeId: _defaultActionNodeId,
        timerHidden: _timerEnabled && _timerHidden ? true : null,
      );
      const encoder = JsonEncoder.withIndent('  ');
      final jsonString = encoder.convert(currentNodeState.toJson());
      Clipboard.setData(ClipboardData(text: jsonString));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('JSON ноды скопирован')),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 1),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  PluginContentType? _findPluginType(String? typeId) =>
      findPluginContentType(ref, typeId);

  Future<void> _addPluginContentType(PluginContentType type) async {
    if (_hasLoadError || _isLoading) return;
    final newItem = await createPluginContentItem(
      context,
      type: type,
      questId: widget.questId,
    );
    if (newItem == null || !mounted) return;
    setState(() => _contentItems.add(newItem));
    _markDirtyAndSave();
    _scrollToEnd();
  }

  void _copyItem(ContentItem item) {
    ref.read(contentClipboardProvider.notifier).state = item;
    Clipboard.setData(
      ClipboardData(text: 'MND_CONTENT_ITEM::${jsonEncode(item.toJson())}'),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Элемент скопирован')),
        backgroundColor: Colors.blueAccent,
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<ContentItem?> _readContentItemFromClipboard() async {
    ContentItem? itemToPaste = ref.read(contentClipboardProvider);
    final clipboardData = await Clipboard.getData('text/plain');
    final raw = clipboardData?.text?.trim() ?? '';
    if (raw.startsWith('MND_CONTENT_ITEM::')) {
      final payload = raw.substring('MND_CONTENT_ITEM::'.length);
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          itemToPaste = ContentItem.fromJson(decoded);
        } else if (decoded is Map) {
          itemToPaste = ContentItem.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {}
    }
    return itemToPaste;
  }

  Future<void> _pasteItem() async {
    final itemToPaste = await _readContentItemFromClipboard();
    if (itemToPaste == null) return;

    final newItem = ContentItemUtils.duplicate(itemToPaste);

    setState(() {
      _contentItems.add(newItem);
    });
    _markDirtyAndSave();
    _scrollToEnd();
    unawaited(_refreshOnAppearIssues());

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Элемент вставлен')),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 1),
      ),
    );
  }

  // ============================================================
  // Templates
  // ============================================================

  Future<void> _saveItemAsTemplate(ContentItem item) async {
    final TemplateKind kind;
    switch (item.type) {
      case 'row':
        kind = TemplateKind.row;
        break;
      case 'column':
        kind = TemplateKind.column;
        break;
      case 'modal':
        kind = TemplateKind.modal;
        break;
      default:
        kind = TemplateKind.content;
    }

    final result = await TemplateSaveDialog.show(
      context,
      title: tr('Сохранить как шаблон'),
      kind: kind,
      initialName: (item.text != null && item.text!.trim().isNotEmpty)
          ? item.text!.trim()
          : null,
    );
    if (result == null || !mounted) return;

    final tpl = TemplateApplier.makeFromContentItem(
      name: result.name,
      item: item,
      description: result.description,
      category: result.category,
    );

    final actions = ref.read(templateActionsProvider);
    if (result.scope == TemplateScope.global) {
      await actions.saveAsGlobal(tpl, sourceQuestId: widget.questId);
    } else {
      await actions.saveToQuest(widget.questId, tpl);
    }

    // Принудительно дожидаемся, чтобы инвалидированные провайдеры
    // (questTemplatesProvider/templatesByIdProvider) успели перечитать
    // данные. Иначе после setState ниже UI может промигать состоянием
    // «битая ссылка» (loading) → «мастер» (data) с потерей золотой
    // полоски на ~100мс.
    try {
      await ref.read(templatesByIdProvider(widget.questId).future);
    } catch (_) {}

    // Превращаем исходный элемент в МАСТЕР этого шаблона: с этого момента
    // его изменения автоматически записываются в `templates.json` при
    // каждом сохранении ноды, а все linked-инстансы по квесту получают
    // актуальный контент.
    final idx = _contentItems.indexWhere((it) => it.id == item.id);
    if (idx >= 0 && mounted) {
      setState(() {
        _contentItems[idx] = _contentItems[idx].copyWith(
          templateRef: tpl.id,
          templateVersion: tpl.contentVersion,
          isTemplateMaster: true,
        );
      });
      // ignore: avoid_print
      print(
        '[Templates] Item ${item.id} marked as master of template ${tpl.id}',
      );
      _markDirtyAndSave();
    } else {
      // ignore: avoid_print
      print(
        '[Templates] WARNING: could not find item ${item.id} in _contentItems to mark as master',
      );
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          trf(
            'Шаблон «{p0}» сохранён. Этот элемент теперь мастер — правки будут применяться ко всем связанным.',
            {'p0': result.name},
          ),
        ),
        backgroundColor: Colors.amber.shade700,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Синхронизировать все мастер-элементы из `_contentItems`, а также
  /// саму мастер-ноду (если эта нода — мастер-шаблон), обратно в
  /// `TemplateRepository`. Вызывается после каждого `_saveNode` — чтобы
  /// правки мастеров автоматически распространялись на linked-инстансы.
  Future<void> _syncMasterTemplates() async {
    final masters = <ContentItem>[];
    void walk(List<ContentItem>? items) {
      if (items == null) return;
      for (final it in items) {
        if (it.isTemplateMasterItem) masters.add(it);
        walk(it.children);
      }
    }

    walk(_contentItems);

    final isMasterNode = _initialNode?.isTemplateMasterNode ?? false;
    if (masters.isEmpty && !isMasterNode) return;

    final repo = ref.read(templateRepositoryProvider);
    final allTemplates = await repo.loadCombined(widget.questId);
    final actions = ref.read(templateActionsProvider);
    final questTemplates = await repo.loadForQuest(widget.questId);
    final questTemplateIds = questTemplates.map((t) => t.id).toSet();

    // 1) Мастер-элементы внутри ноды.
    for (final master in masters) {
      final templateId = master.templateRef;
      if (templateId == null) continue;
      final existing = allTemplates.firstWhereOrNull((t) => t.id == templateId);
      if (existing == null) continue;

      // Готовим «чистый» payload: без linked-meta полей (они нужны только
      // в дереве ноды, не в самом мастер-шаблоне).
      final clean = master.copyWith(clearTemplateLink: true);
      final newPayload = clean.toJson();

      // Проверяем — есть ли реально изменения в payload (иначе зря
      // дёргать репозиторий и инкрементить contentVersion).
      final oldEncoded = jsonEncode(existing.payload);
      final newEncoded = jsonEncode(newPayload);
      if (oldEncoded == newEncoded) continue;

      final updated = existing.copyWith(payload: newPayload);

      // Определяем scope: лежит ли мастер в квесте или глобально.
      if (questTemplateIds.contains(templateId)) {
        await actions.saveToQuest(widget.questId, updated);
      } else {
        // sourceQuestId: старый глобальный шаблон мог сохраниться без
        // файлов — при первой же правке подтягиваем их из квеста.
        await actions.saveAsGlobal(updated, sourceQuestId: widget.questId);
      }
    }

    // 2) Сама нода — мастер-шаблон. Пушим её content (items + title +
    // оформление) обратно в мастер-шаблон ноды.
    if (isMasterNode) {
      final templateId = _initialNode!.templateRef;
      if (templateId == null) return;
      final existing = allTemplates.firstWhereOrNull((t) => t.id == templateId);
      if (existing == null) return;

      // Готовим payload мастер-ноды по тем же правилам, что и
      // TemplateApplier.makeFromNode: содержимое + декоративные поля.
      final newPayload = <String, dynamic>{
        'title': _titleController.text.trim(),
        'content': {
          'items': _contentItems.map((item) => item.toJson()).toList(),
        },
        if (_selectedBackgroundId != null)
          'backgroundAssetId': _selectedBackgroundId,
        if (_selectedBackgroundVideoId != null)
          'backgroundVideoAssetId': _selectedBackgroundVideoId,
        if (_selectedBackgroundVideoId != null)
          'backgroundVideoVolume': _videoVolume,
        if (_selectedBackgroundVideoId != null)
          'backgroundVideoLoop': _videoLoop,
        if (_selectedBackgroundVideoId != null)
          'backgroundVideoMuted': _videoMuted,
        if (_selectedBackgroundVideoId != null) 'backgroundVideoFit': _videoFit,
        if (_backgroundBlur != null) 'backgroundBlur': _backgroundBlur,
        if (_selectedAudioId != null) 'backgroundAudioId': _selectedAudioId,
        if (_selectedAudioId != null) 'backgroundAudioVolume': _audioVolume,
        if (_initialNode!.color != null) 'color': _initialNode!.color,
        if (_initialNode!.scriptAssetId != null)
          'scriptAssetId': _initialNode!.scriptAssetId,
        if (_timerEnabled)
          'timerDuration': double.tryParse(
            _timerController.text.trim().replaceAll(',', '.'),
          ),
        if (_timerEnabled && _defaultActionNodeId != null)
          'defaultActionNodeId': _defaultActionNodeId,
        if (_timerEnabled && _timerHidden) 'timerHidden': true,
      };

      final oldEncoded = jsonEncode(existing.payload);
      final newEncoded = jsonEncode(newPayload);
      if (oldEncoded == newEncoded) return;

      final updated = existing.copyWith(payload: newPayload);
      if (questTemplateIds.contains(templateId)) {
        await actions.saveToQuest(widget.questId, updated);
      } else {
        await actions.saveAsGlobal(updated, sourceQuestId: widget.questId);
      }
    }
  }

  Future<void> _insertFromTemplate() async {
    final picked = await TemplatePickerSheet.showWithMode(
      context,
      questId: widget.questId,
      allowedKinds: const {
        TemplateKind.content,
        TemplateKind.row,
        TemplateKind.column,
        TemplateKind.modal,
      },
      title: tr('Вставить из шаблона'),
      allowLinked: true,
    );
    if (picked == null || !mounted) return;
    final template = picked.template;

    // --- Linked-режим: тонкий инстанс, без копирования содержимого ---
    if (picked.mode == TemplatePickMode.linked) {
      TemplateItem masterInQuest = template;
      try {
        if (picked.wasGlobal) {
          masterInQuest = await ref
              .read(templateActionsProvider)
              .pinToQuest(template, widget.questId);
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

      final linked = TemplateApplier.buildLinkedContentItem(masterInQuest);
      if (linked == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Не удалось создать связанный элемент')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      setState(() => _contentItems.add(linked.copyWith(flex: 1)));
      _markDirtyAndSave();
      _scrollToEnd();
      unawaited(_refreshOnAppearIssues());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trf('Шаблон вставлен как связанный: {p0}', {
              'p0': masterInQuest.name,
            }),
          ),
          backgroundColor: Colors.cyan,
        ),
      );
      return;
    }

    // --- Snapshot-режим (старое поведение) ---
    final pluginIds = TemplateApplier.collectPluginIds(template);
    if (pluginIds.isNotEmpty) {
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(tr('Шаблон использует плагины')),
          content: Text(
            trf(
              'Этот шаблон ссылается на плагины: {p0}. Если они не установлены в текущем квесте, контент может работать некорректно. Продолжить вставку?',
              {'p0': pluginIds.join(", ")},
            ),
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
      template: template,
      questId: widget.questId,
    );
    final effectiveTemplate = installed.template;

    final newItem = TemplateApplier.buildContentItem(effectiveTemplate);
    if (newItem == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Не удалось построить элемент из шаблона')),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    setState(() => _contentItems.add(newItem.copyWith(flex: 1)));
    _markDirtyAndSave();
    _scrollToEnd();
    unawaited(_refreshOnAppearIssues());

    if (!mounted) return;
    final report = installed.assetsReport;
    final msg = report.copied > 0
        ? trf('Шаблон вставлен (ресурсов: {p0}, пропущено: {p1})', {
            'p0': report.copied,
            'p1': report.skippedExisting,
          })
        : tr('Шаблон вставлен');
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.blue));
  }

  // ============================================================
  //  Linked-templates: меню для linked/master элементов
  // ============================================================

  /// Открыть универсальное меню действий для элемента, связанного с шаблоном
  /// (linked или master). Содержимое меню зависит от роли элемента.
  Future<void> _showTemplateLinkMenu(int index) async {
    if (index < 0 || index >= _contentItems.length) return;
    final item = _contentItems[index];
    if (!item.hasTemplateLink) return;

    if (item.isTemplateMasterItem) {
      await _showMasterItemMenu(index);
    } else {
      await _showLinkedInstanceMenu(index);
    }
  }

  /// Меню для мастер-элемента: переименовать шаблон, отвязать (превратить
  /// мастер в обычный объект), удалить шаблон (с предупреждением).
  Future<void> _showMasterItemMenu(int index) async {
    if (index < 0 || index >= _contentItems.length) return;
    final item = _contentItems[index];
    if (!item.isTemplateMasterItem) return;

    final masters = ref.read(templatesByIdProvider(widget.questId)).valueOrNull;
    final master = masters?[item.templateRef];

    final scheme = Theme.of(context).colorScheme;
    await showAdaptiveSheet<void>(
      context: context,
      backgroundColor: scheme.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.workspace_premium, color: scheme.tertiary),
              title: Text(
                master != null
                    ? trf('Мастер шаблона «{p0}»', {'p0': master.name})
                    : tr('Мастер шаблона'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                tr(
                  'Этот элемент — источник правды для всех связанных вхождений. Редактируйте как обычно — изменения применятся ко всем linked-копиям после сохранения ноды.',
                ),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ),
            Divider(color: scheme.outlineVariant.withOpacity(0.5)),
            ListTile(
              leading: Icon(
                Icons.collections_bookmark_rounded,
                color: scheme.primary,
              ),
              title: Text(tr('Открыть в менеджере шаблонов')),
              onTap: () {
                Navigator.pop(ctx);
                EditorDocumentLauncher.openTemplates(context, widget.questId);
              },
            ),
            ListTile(
              leading: Icon(Icons.link_off, color: scheme.tertiary),
              title: Text(tr('Снять роль мастера')),
              subtitle: Text(
                tr(
                  'Элемент станет обычным. Шаблон останется в репозитории, но изменения этого элемента перестанут на него влиять.',
                ),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _contentItems[index] = item.copyWith(clearTemplateLink: true);
                });
                _markDirtyAndSave();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr('Роль мастера снята')),
                    backgroundColor: Colors.amberAccent,
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(tr('Удалить элемент (и шаблон)')),
              subtitle: Text(
                tr(
                  'Все linked-инстансы этого шаблона по квесту станут битыми ссылками. Действие необратимо.',
                ),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await _deleteMasterWithTemplate(index);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMasterWithTemplate(int index) async {
    if (index < 0 || index >= _contentItems.length) return;
    final item = _contentItems[index];
    if (!item.isTemplateMasterItem) return;
    final templateId = item.templateRef;
    if (templateId == null) return;

    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить шаблон полностью?')),
        content: Text(
          tr(
            'Все связанные вхождения этого шаблона по квесту превратятся в битые ссылки и перестанут отображать контент. Продолжить?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              tr('Удалить'),
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    // 1. Удаляем шаблон из обоих scope (если он есть в любом).
    final actions = ref.read(templateActionsProvider);
    final repo = ref.read(templateRepositoryProvider);
    final inQuest = await repo
        .loadForQuest(widget.questId)
        .then((list) => list.any((t) => t.id == templateId));
    final inGlobal = await repo.loadGlobal().then(
      (list) => list.any((t) => t.id == templateId),
    );
    try {
      if (inQuest) {
        await actions.delete(
          TemplateItem(
            id: templateId,
            name: '',
            kind: TemplateKind.content,
            payload: const {},
          ),
          scope: TemplateScope.quest,
          questId: widget.questId,
        );
      }
      if (inGlobal) {
        await actions.delete(
          TemplateItem(
            id: templateId,
            name: '',
            kind: TemplateKind.content,
            payload: const {},
          ),
          scope: TemplateScope.global,
        );
      }
    } catch (_) {}

    // 2. Удаляем мастер-элемент из текущей ноды.
    setState(() => _contentItems.removeAt(index));
    _markDirtyAndSave();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Шаблон удалён из репозитория. Связанные вхождения стали битыми.',
            ),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  /// Открыть меню действий для linked-инстанса: посмотреть мастер,
  /// отвязать (превратить в snapshot-копию).
  Future<void> _showLinkedInstanceMenu(int index) async {
    if (index < 0 || index >= _contentItems.length) return;
    final item = _contentItems[index];
    if (!item.isTemplateInstance) return;

    final masters = ref.read(templatesByIdProvider(widget.questId)).valueOrNull;
    final master = masters?[item.templateRef];
    final isBroken = master == null;

    final scheme = Theme.of(context).colorScheme;
    await showAdaptiveSheet<void>(
      context: context,
      backgroundColor: scheme.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(
                isBroken ? Icons.link_off : Icons.link,
                color: isBroken ? scheme.error : scheme.primary,
              ),
              title: Text(
                isBroken
                    ? tr('Связанный шаблон удалён')
                    : trf('Связан с шаблоном «{p0}»', {'p0': master.name}),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                isBroken
                    ? tr(
                        'Содержимое больше не подгружается из мастера. Можно отвязать (станет пустым snapshot) или удалить.',
                      )
                    : trf(
                        'Изменения мастера автоматически отражаются здесь. Версия v{p0}.',
                        {'p0': master.contentVersion},
                      ),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ),
            Divider(color: scheme.outlineVariant.withOpacity(0.5)),
            if (!isBroken)
              ListTile(
                leading: Icon(
                  Icons.collections_bookmark_rounded,
                  color: scheme.primary,
                ),
                title: Text(tr('Открыть в менеджере шаблонов')),
                onTap: () {
                  Navigator.pop(ctx);
                  EditorDocumentLauncher.openTemplates(context, widget.questId);
                },
              ),
            ListTile(
              leading: Icon(Icons.link_off, color: scheme.tertiary),
              title: Text(tr('Отвязать (превратить в копию)')),
              subtitle: Text(
                tr(
                  'После отвязки изменения мастера на этот элемент не повлияют.',
                ),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _detachLinkedInstance(index);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(tr('Удалить элемент')),
              onTap: () {
                Navigator.pop(ctx);
                _deleteItem(index);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// Отвязать инстанс: резолвим через [TemplateInstanceResolver], затем
  /// сохраняем как обычный snapshot со свежими id (`TemplateApplier.detachContentItem`).
  void _detachLinkedInstance(int index) {
    if (index < 0 || index >= _contentItems.length) return;
    final item = _contentItems[index];
    if (!item.isTemplateInstance) return;

    final resolver = ref
        .read(templateInstanceResolverProvider(widget.questId))
        .valueOrNull;
    if (resolver == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Резолвер шаблонов ещё не загружен, попробуйте позже'),
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final resolved = resolver.resolveTree(item);
    if (!resolved.isTemplateInstance && resolved == item) {
      // мастер не найден — отвязываем «как есть», но без содержимого
      setState(() {
        _contentItems[index] = item.copyWith(
          clearTemplateLink: true,
          children: const [],
          modalButtons: const [],
        );
      });
      _markDirtyAndSave();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Шаблон не найден — элемент отвязан и очищен')),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }

    final detached = TemplateApplier.detachContentItem(resolved);
    setState(() => _contentItems[index] = detached);
    _markDirtyAndSave();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Элемент отвязан от шаблона')),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _pasteIntoContainerItem(int index) async {
    if (index < 0 || index >= _contentItems.length) return;
    final container = _contentItems[index];
    if (container.type != 'row' && container.type != 'column') return;

    final source = await _readContentItemFromClipboard();
    if (source == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Буфер элементов пуст')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final newChild = ContentItemUtils.duplicate(source);
    final children = List<ContentItem>.from(container.children ?? const []);
    children.add(newChild);

    setState(() {
      _contentItems[index] = container.copyWith(children: children);
    });
    _markDirtyAndSave();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Элемент вставлен внутрь контейнера')),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _deleteItem(int index) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить элемент?')),
        content: Text(tr('Это действие нельзя отменить.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              tr('Удалить'),
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final itemToDelete = _contentItems[index];
    if (itemToDelete.type == 'button' && itemToDelete.targetNodeId != null) {
      await deleteConnection(
        widget.questId,
        widget.nodeId,
        itemToDelete.targetNodeId!,
      );
    }
    setState(() => _contentItems.removeAt(index));
    _markDirtyAndSave();
    unawaited(_refreshOnAppearIssues());
  }

  void _addScriptTriggerItem() {
    _showScriptSourceDialog();
  }

  void _showScriptSourceDialog() {
    final scheme = Theme.of(context).colorScheme;
    showAdaptiveSheet<String>(
      context: context,
      backgroundColor: scheme.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.add_box_rounded, color: scheme.primary),
              title: Text(tr('Новый визуальный скрипт')),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            ListTile(
              leading: const Icon(
                Icons.data_object_rounded,
                color: Colors.deepPurple,
              ),
              title: Text(tr('Новый Lua-скрипт')),
              onTap: () => Navigator.pop(ctx, 'new_lua'),
            ),
            ListTile(
              leading: const Icon(
                Icons.folder_open_rounded,
                color: Colors.blueAccent,
              ),
              title: Text(tr('Существующий')),
              onTap: () => Navigator.pop(ctx, 'existing'),
            ),
          ],
        ),
      ),
    ).then((choice) async {
      if (!mounted) return;
      if (choice == 'existing') {
        final res = await Navigator.push<SelectableResource>(
          context,
          MaterialPageRoute(
            builder: (_) => ResourceSelectionScreen(
              questId: widget.questId,
              // JSON-скрипты и .lua-файлы оба могут быть script-айтем ноды.
              allowedTypes: ['script', 'lua'],
            ),
          ),
        );
        if (res != null && mounted) {
          setState(
            () => _contentItems.add(
              ContentItem(
                id: const Uuid().v4(),
                type: 'script',
                resourcePath: res.path,
              ),
            ),
          );
          _markDirtyAndSave();
          _scrollToEnd();
        }
      } else if (choice == 'new') {
        _createNewScriptWithTemplate(lua: false);
      } else if (choice == 'new_lua') {
        _createNewScriptWithTemplate(lua: true);
      }
    });
  }

  /// Мгновенное создание script-элемента (План 014, этап A2): авто-имя,
  /// без диалогов и FolderPicker, добавление в ноду и сразу редактор.
  Future<void> _createNewScriptWithTemplate({bool lua = false}) async {
    try {
      final resources = ref.read(resourceServiceProvider(widget.questId));
      // ref.read: метод вызывается вне build, подписка тут не нужна.
      final scripts = ref.read(scriptServiceProvider(widget.questId));

      final created = lua
          ? await resources.createLuaScript()
          : await resources.createScript(
              // Не рождаем пустой файл: шаблонный event-блок сразу на диске.
              // Скрипт, прикреплённый к ноде, движок запускает на входе в
              // ноду; `function/main` не выполнится никогда — только по вызову.
              initialBlocks: TriggerService.jsonInitialBlocks('onNodeEnter'),
            );

      if (!mounted) return;
      setState(
        () => _contentItems.add(
          ContentItem(
            id: const Uuid().v4(),
            type: 'script',
            resourcePath: created.questRelativePath,
          ),
        ),
      );
      _markDirtyAndSave();
      _scrollToEnd();
      if (mounted) {
        // Вложенный редактор может вытеснить вкладку ноды (LRU, replace):
        // debounce в 2 с не успевает, и добавленный script-айтем не доезжает
        // до nodes.json — после выхода он «исчезает из списка контента».
        _debounceTimer?.cancel();
        _debounceTimer = null;
        await _saveNode(force: true);
        if (!mounted) return;
        await scripts.openEditor(context, created.questRelativePath);
      }
    } catch (_) {}
  }

  ItemEditorHelper get _itemHelper => ItemEditorHelper(
    context: context,
    questId: widget.questId,
    nodeId: widget.nodeId,
    logic: _logic,
    getItem: (i) => _contentItems[i],
    updateItem: (i, item) {
      setState(() {
        _contentItems[i] = item;
      });
      _markDirtyAndSave();
      unawaited(_refreshOnAppearIssues());
    },
    onBeforeContainerEdit: () async {
      if (_isDirty) await _saveNode(force: true);
    },
    onCustomEditItem: (index, item) async {
      if (item.type == 'plugin') {
        final pluginType = _findPluginType(item.pluginTypeId);
        if (pluginType == null) return true;
        final data = await showPluginContentForm(
          context,
          type: pluginType,
          questId: widget.questId,
          initial: item.pluginData,
        );
        if (data != null && mounted) {
          setState(
            () => _contentItems[index] = item.copyWith(
              pluginTypeId: pluginType.id,
              pluginData: data,
            ),
          );
          _markDirtyAndSave();
        }
        return true;
      }
      return false;
    },
    onJumpToNode: _jumpToNode,
    fromGameSession: widget.fromGameSession,
  );

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_editorScrollController.hasClients) {
        _editorScrollController.animateTo(
          _editorScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _launchQuest() async {
    final saved = await _saveNode(isExiting: false, force: true);
    if (!saved) return;
    if (!mounted) return;

    if (widget.fromGameSession) {
      Navigator.pop(context, true);
    } else {
      EditorDocumentLauncher.openGameSimulation(
        context,
        widget.questId,
        startNodeId: widget.nodeId,
      );
    }
  }

  Future<void> _launchQuestFromSave() async {
    final saved = await _saveNode(isExiting: false, force: true);
    if (!saved) return;
    if (!mounted) return;
    await EditorDocumentLauncher.openGameFromSave(context, widget.questId);
  }

  Future<void> _handleExit() async {
    _debounceTimer?.cancel();
    if (_isDirty || _isSaving) {
      final saved = await _saveNode(isExiting: true, force: true);
      if (!saved) return;
    }
    if (!mounted) return;
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);
    if (document != null && workspace != null) {
      await workspace.closeDocument(document.id);
    } else {
      Navigator.pop(context, true);
    }
  }

  /// Кнопка «Назад» в AppBar: внутри воркспейса — браузерная история
  /// (вкладка остаётся открытой), в отдельном маршруте — выход с сохранением.
  Future<void> _handleBackButton() async {
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);
    if (document != null && workspace != null) {
      await workspace.requestBack();
      return;
    }
    await _handleExit();
  }

  Widget _buildEmptyState() {
    if (_hasLoadError) {
      return EditorEmptyState(
        icon: Icons.error_outline_rounded,
        message: tr('Ошибка загрузки данных'),
        action: FilledButton.icon(
          onPressed: _loadNodeData,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(tr('Повторить')),
        ),
      );
    }
    return EditorEmptyState(
      icon: Icons.edit_note_rounded,
      message: tr('Пусто. Добавьте контент.'),
      hint: tr('Тексты, кнопки, изображения и другие блоки'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Хойстим watch вне itemBuilder — иначе N подписок на каждый айтем
    final templateMasters = ref
        .watch(templatesByIdProvider(widget.questId))
        .valueOrNull;
    final templateResolver = ref
        .watch(templateInstanceResolverProvider(widget.questId))
        .valueOrNull;
    // Типы контента плагинов читаются из Rust-хоста асинхронно: следим за
    // провайдером, чтобы карточки плагин-айтемов перерисовались, когда они придут.
    ref.watch(pluginContentTypesProvider);
    return EditorDocumentBackScope(
      onBackPressed: () async {
        await _handleExit();
        return true;
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          title: Text(
            tr('Контент'),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
          ),
          backgroundColor: scheme.surface,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _handleBackButton,
          ),
          actions: [
            IconButton(
              icon: Icon(Icons.account_tree_rounded, color: scheme.tertiary),
              tooltip: tr('На канвас'),
              onPressed: _returnToCanvas,
            ),
            IconButton(
              icon: Icon(
                widget.fromGameSession
                    ? Icons.check_circle_rounded
                    : Icons.play_circle_fill_rounded,
                color: scheme.primary,
                size: 30,
              ),
              tooltip: widget.fromGameSession
                  ? tr('Применить и вернуться')
                  : tr('Играть'),
              onPressed: _launchQuest,
            ),
            IconButton(
              icon: Icon(Icons.history_rounded, color: scheme.tertiary),
              tooltip: tr('Играть из сохранения'),
              onPressed: _launchQuestFromSave,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              color: scheme.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              onSelected: (value) {
                if (value == 'copy_id') _copyNodeId();
                if (value == 'copy_json') _copyNodeJson();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'copy_id',
                  child: Text(
                    tr('Копировать ID'),
                    style: TextStyle(color: scheme.onSurface),
                  ),
                ),
                PopupMenuItem(
                  value: 'copy_json',
                  child: Text(
                    tr('Копировать JSON'),
                    style: TextStyle(color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: null,
          onPressed: () {
            ContentAddMenuSheet.show(
              context,
              onItemSelected: (type, {pluginTypeId}) async {
                if (type == 'script') {
                  Future.microtask(_addScriptTriggerItem);
                } else if (type == 'plugin' && pluginTypeId != null) {
                  final pType = _findPluginType(pluginTypeId);
                  if (pType != null) _addPluginContentType(pType);
                } else {
                  final newItem = await _logic.createItemByType(type);
                  if (newItem != null) {
                    setState(() => _contentItems.add(newItem));
                    _markDirtyAndSave();
                    _scrollToEnd();
                  }
                }
              },
              onPaste: _pasteItem,
              onInsertFromTemplate: _insertFromTemplate,
            );
          },
          icon: const Icon(Icons.add_rounded),
          label: Text(
            tr('Добавить'),
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        body: _isLoading
            ? Center(child: CircularProgressIndicator(color: scheme.primary))
            // Лента контента — колонкой: на 1440 px карточка с текстом
            // растягивалась на весь экран и превращалась в бесконечную строку.
            : AdaptiveContent(
                child: CustomScrollView(
                  controller: _editorScrollController,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            TextField(
                              controller: _titleController,
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                              decoration: InputDecoration(
                                hintText: tr('Название ноды'),
                                hintStyle: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Material(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(20),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: _openNodeSettings,
                                borderRadius: BorderRadius.circular(20),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 14,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: scheme.primary.withOpacity(
                                            0.16,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.tune_rounded,
                                          color: scheme.primary,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              tr('Настройки ноды'),
                                              style: TextStyle(
                                                color: scheme.onSurface,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 16,
                                              ),
                                            ),
                                            Text(
                                              [
                                                    if (_selectedBackgroundId !=
                                                            null ||
                                                        _selectedBackgroundVideoId !=
                                                            null)
                                                      tr('Фон'),
                                                    if (_selectedAudioId !=
                                                        null)
                                                      tr('Аудио'),
                                                    if (_timerEnabled)
                                                      tr('Таймер'),
                                                    if (_nodeItemSpacing !=
                                                            null ||
                                                        _nodeImageRoundedCorners !=
                                                            null)
                                                      tr('Оформление'),
                                                  ].join(' · ').isEmpty
                                                  ? tr(
                                                      'Фон, аудио, таймер, отступ',
                                                    )
                                                  : [
                                                      if (_selectedBackgroundId !=
                                                              null ||
                                                          _selectedBackgroundVideoId !=
                                                              null)
                                                        tr('Фон'),
                                                      if (_selectedAudioId !=
                                                          null)
                                                        tr('Аудио'),
                                                      if (_timerEnabled)
                                                        tr('Таймер'),
                                                      if (_nodeItemSpacing !=
                                                              null ||
                                                          _nodeImageRoundedCorners !=
                                                              null)
                                                        tr('Оформление'),
                                                    ].join(' · '),
                                              style: TextStyle(
                                                color: scheme.onSurfaceVariant,
                                                fontSize: 12,
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
                            const SizedBox(height: 16),
                            Divider(
                              color: scheme.outlineVariant.withOpacity(0.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                    _contentItems.isEmpty
                        ? SliverFillRemaining(child: _buildEmptyState())
                        : SliverReorderableList(
                            itemCount: _contentItems.length,
                            onReorder: (oldIndex, newIndex) {
                              setState(() {
                                if (oldIndex < newIndex) newIndex -= 1;
                                final item = _contentItems.removeAt(oldIndex);
                                _contentItems.insert(newIndex, item);
                              });
                              _markDirtyAndSave();
                            },
                            itemBuilder: (ctx, index) {
                              final item = _contentItems[index];
                              String? displayScriptName;
                              final triggers = item.resolvedTriggers;
                              bool hasTrigger = triggers.isNotEmpty;

                              if (hasTrigger) {
                                final rawRef = triggers.values.firstOrNull;
                                if (rawRef != null) {
                                  final triggerRef = TriggerReference.parse(
                                    rawRef,
                                  );
                                  final fileName = p.basename(
                                    triggerRef.scriptPath,
                                  );
                                  final baseName =
                                      _resourceNames[fileName] ?? fileName;
                                  displayScriptName = triggerRef.isFunctionRef
                                      ? '$baseName :: ${triggerRef.functionEntry}'
                                      : baseName;
                                }
                              } else if (item.type == 'script' &&
                                  item.resourcePath != null) {
                                final filename = p.basename(item.resourcePath!);
                                displayScriptName =
                                    _resourceNames[filename] ?? filename;
                              }

                              final pluginType = item.type == 'plugin'
                                  ? _findPluginType(item.pluginTypeId)
                                  : null;
                              final pluginAccent = pluginType?.accentColor;

                              // --- Template link metadata for this item ---
                              String? linkedMasterName;
                              bool linkedMissing = false;
                              ContentItem displayItem = item;
                              if (item.hasTemplateLink) {
                                final master =
                                    templateMasters?[item.templateRef];
                                if (master != null) {
                                  linkedMasterName = master.name;
                                } else {
                                  linkedMissing = true;
                                }
                                if (item.isTemplateInstance &&
                                    templateResolver != null) {
                                  displayItem = templateResolver.resolveTree(
                                    item,
                                  );
                                }
                              }

                              return ContentItemCard(
                                key: ValueKey(item.id),
                                index: index,
                                item: displayItem,
                                questId: widget.questId,
                                displayScriptName: displayScriptName,
                                pluginTitle: pluginType?.name,
                                pluginAccentColor: pluginAccent,
                                hasTriggerWarning: _onAppearIssuesByItemId
                                    .containsKey(item.id),
                                triggerWarningMessage:
                                    _onAppearIssuesByItemId[item.id]?.message,
                                templateInstanceName: linkedMasterName,
                                templateInstanceMissing: linkedMissing,
                                templateInstanceIsMaster:
                                    item.isTemplateMasterItem,
                                onTemplateInstanceTap: item.hasTemplateLink
                                    ? () => _showTemplateLinkMenu(index)
                                    : null,
                                onDelete: () => _deleteItem(index),
                                // Для linked-инстансов основной редактор
                                // заменяем на меню (правка запрещена).
                                // Мастер-элементы редактируются как обычные
                                // объекты — изменения после сохранения ноды
                                // распространятся на все linked.
                                onEdit: item.isTemplateInstance
                                    ? () => _showTemplateLinkMenu(index)
                                    : () => _itemHelper.editItem(index),
                                onRename:
                                    (item.type == 'row' ||
                                        item.type == 'column')
                                    ? () => _itemHelper.renameItem(index)
                                    : null,
                                onJumpToTarget: _jumpToNode,
                                // row/column — без пункта «Переход к ноде»:
                                // контейнеры не должны быть кликабельны как
                                // самостоятельная цель навигации.
                                onTriggerSettings: () =>
                                    _itemHelper.showTriggerOptions(
                                      index,
                                      includeTargetNodeId:
                                          item.type != 'row' &&
                                          item.type != 'column',
                                    ),
                                onOnAppearTriggerTap: () => _itemHelper
                                    .onTriggerSlotTap(index, 'onAppear'),
                                onOnPressTriggerTap: () =>
                                    _itemHelper.onTriggerSlotTap(
                                      index,
                                      item.type == 'input'
                                          ? 'onSubmit'
                                          : 'onPress',
                                    ),
                                onCopy: () => _copyItem(item),
                                onSaveAsTemplate: () =>
                                    _saveItemAsTemplate(item),
                                onPasteInto:
                                    (item.type == 'row' ||
                                        item.type == 'column')
                                    ? () => _pasteIntoContainerItem(index)
                                    : null,
                              );
                            },
                          ),
                    const SliverToBoxAdapter(child: SizedBox(height: 100)),
                  ],
                ),
              ),
      ),
    );
  }
}
