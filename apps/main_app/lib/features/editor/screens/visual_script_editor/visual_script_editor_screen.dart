import 'dart:async';
import 'dart:convert';
import 'package:canvas_app/core/services/refactoring_service.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:canvas_app/features/editor/providers/visual_script_clipboard_provider.dart';
import 'package:canvas_app/features/editor/services/script_providers.dart';
import 'package:canvas_app/features/editor/workspace/editor_back_handler.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_lifecycle.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_factory.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_insertion.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/action_picker_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/parser.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/event_block_widget.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/script_contracts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

// ============================================================================
//  ВИЗУАЛЬНЫЙ РЕДАКТОР СКРИПТОВ — M3 chrome (логика блоков нетронута)
// ============================================================================
//
//  Здесь применён лёгкий M3-редизайн «оболочки»: AppBar, диалоги,
//  SnackBar, FAB, empty state — всё через ColorScheme. Сама внутренняя
//  логика блоков, парсинг, refactoring и т.д. сохранена без изменений.
//
//  Helper для семантических snackbar'ов вынесен в _showSnack — все
//  Colors.red/green/orange/blue заменены на scheme.error/primary/
//  tertiaryContainer/secondaryContainer.
//
//  Адаптив для ПК: список блоков ограничивается по ширине (maxWidth 900),
//  чтобы блоки не растягивались на full HD мониторах.
//
// ============================================================================

class VisualScriptEditorScreen extends ConsumerStatefulWidget {
  final String questId;
  final String scriptId;

  const VisualScriptEditorScreen({
    super.key,
    required this.questId,
    required this.scriptId,
  });

  @override
  ConsumerState<VisualScriptEditorScreen> createState() =>
      _VisualScriptEditorScreenState();
}

class _VisualScriptEditorScreenState
    extends ConsumerState<VisualScriptEditorScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  List<VisualScriptBlock> _blocks = [];
  bool _isLoading = true;
  String _scriptName = tr('Скрипт');
  bool _isConditionalScript = false;

  final ScrollController _scrollController = ScrollController();
  Ticker? _autoScrollTicker;
  Timer? _autoSaveTimer;
  double _scrollSpeed = 0.0;
  String _lastSavedSignature = '';

  /// Контент загружен с диска (или это заведомо новый пустой скрипт).
  /// Пока false — ЛЮБОЕ сохранение запрещено: иначе недозагруженный
  /// редактор (пустой список блоков) затирает файл на диске.
  bool _loadCompleted = false;
  StreamSubscription<RefactorRenameEvent>? _renameSub;
  StreamSubscription<ResourceRenameEvent>? _resourceRenameSub;

  /// Реестр GlobalKey по id блока. Нужен, чтобы измерить экранные позиции
  /// блоков и определить ближайшее к центру viewport место вставки нового
  /// блока (пользователь хочет, чтобы блок добавлялся туда, куда он смотрит,
  /// а не в начало/конец списка).
  final Map<String, GlobalKey> _blockKeys = {};

  GlobalKey _blockKeyFor(String id) =>
      _blockKeys.putIfAbsent(id, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    _renameSub = RefactoringService.renameEvents.listen(_onRenameEvent);
    _resourceRenameSub = RefactoringService.resourceRenameEvents.listen(
      _onResourceRenamed,
    );
    WidgetsBinding.instance.addObserver(this);
    _loadScript();
    // Автосейв — единственный способ сохранить: кнопка «Сохранить» убрана,
    // поэтому интервал короткий, а выход/деактивация/закрытие вкладки
    // дописывают буфер безусловно (см. onBeforeClose и _closeDocument).
    _autoSaveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _isLoading) return;
      final dirty = _scriptSignature != _lastSavedSignature;
      // Хэндл вместо контекстного lookup: таймер переживает деактивацию
      // элемента, а lookup предков в этом окне запрещён фреймворком.
      _docHandle?.markDirty(dirty);
      if (dirty) unawaited(_saveScript());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _docHandle?.registerRuntime(
        EditorDocumentRuntime(
          onSave: () async {
            await _saveScript();
            return true;
          },
          onBeforeClose: () async {
            await _saveScript();
            return true;
          },
        ),
      );
    });
  }

  @override
  void dispose() {
    _renameSub?.cancel();
    _resourceRenameSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _autoSaveTimer?.cancel();
    // Закрытие как маршрута (Navigator.pop) не проходит ни onBeforeClose
    // вкладки, ни деактивацию: флешим буфер здесь, иначе правка, сделанная
    // в последнюю секунду перед выходом, не доживает до записи.
    if (_scriptSignature != _lastSavedSignature) {
      unawaited(_saveScript());
    }
    _autoScrollTicker?.dispose();
    _autoScrollTicker = null;
    _docHandle?.invalidated = true;
    _scrollController.dispose();
    super.dispose();
  }

  /// Захваченная ссылка на документ воркспейса (без context-lookup'ов
  /// из таймеров и колбэков после деактивации).
  EditorDocumentHandle? _docHandle;

  /// Последнее известное значение EditorDocumentContext.isActive.
  bool? _lastActiveState;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final doc = EditorDocumentContext.maybeOf(context);
    final active = doc?.isActive ?? true;
    final wasActive = _lastActiveState;
    _lastActiveState = active;

    // Перезахват хэндла: при смене id или первом появлении.
    final captured = EditorDocumentLifecycle.capture(context);
    if (captured?.id != _docHandle?.id) {
      _docHandle?.invalidated = true;
      _docHandle = captured;
    }

    // Вкладку убрали с экрана (переключение, сессия, панель) — сбрасываем
    // буфер на диск, чтобы пересоздание вкладки не потеряло правки.
    if (wasActive == true && !active && !_isLoading) {
      if (_scriptSignature != _lastSavedSignature) {
        unawaited(_saveScript());
      }
    }
  }

  /// Библиотека переименовала этот скрипт, пока вкладка открыта: берём
  /// новое имя в буфер, иначе автосейв вернёт старое и в файл, и в metadata.
  void _onResourceRenamed(ResourceRenameEvent event) {
    if (!mounted) return;
    if (event.questId != widget.questId) return;
    if (event.fileName != '${widget.scriptId}.json') return;
    if (event.newName == _scriptName) return;
    setState(() => _scriptName = event.newName);
    unawaited(_saveScript());
  }

  void _onRenameEvent(RefactorRenameEvent event) {
    if (!mounted) return;
    if (event.questId != widget.questId) return;
    unawaited(_applyRenameEventInMemory(event.oldName, event.newName));
  }

  Future<void> _applyRenameEventInMemory(String oldName, String newName) async {
    final blocksJson = _blocks.map((block) => block.toJson()).toList();
    final changed = _walkAndReplaceRename(blocksJson, oldName, newName);
    if (!changed) {
      print(
        '[Refactor][VisualEditor] No in-memory changes for "$oldName" -> "$newName"',
      );
      return;
    }

    try {
      final reparsed = ScriptParser.parseBlocks(blocksJson);
      if (!mounted) return;
      setState(() => _blocks = reparsed);
      await _saveScript();
      print('[Refactor][VisualEditor] In-memory script updated and saved');
    } catch (e) {
      print('[Refactor][VisualEditor] Failed to reparse/save after rename: $e');
    }
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
      'fileName',
      'path',
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

  void _checkAutoScroll(Offset position, double screenHeight) {
    const double edgeSize = 100.0;
    const double maxSpeed = 20.0;

    if (position.dy < edgeSize + kToolbarHeight) {
      _scrollSpeed =
          -maxSpeed * ((edgeSize + kToolbarHeight - position.dy) / edgeSize);
      _startScrollTimer();
    } else if (position.dy > screenHeight - edgeSize) {
      _scrollSpeed =
          maxSpeed * ((position.dy - (screenHeight - edgeSize)) / edgeSize);
      _startScrollTimer();
    } else {
      _scrollSpeed = 0.0;
      _stopScrollTimer();
    }
  }

  void _startScrollTimer() {
    if (_autoScrollTicker != null && _autoScrollTicker!.isActive) return;
    _autoScrollTicker ??= createTicker(_onAutoScrollTick);
    _autoScrollTicker!.start();
  }

  void _onAutoScrollTick(Duration elapsed) {
    if (!mounted) return;
    if (_scrollSpeed == 0.0) return;
    if (_scrollController.hasClients) {
      final min = _scrollController.position.minScrollExtent;
      final max = _scrollController.position.maxScrollExtent;
      final raw = _scrollController.offset + _scrollSpeed;
      final next = raw.clamp(min, max).toDouble();
      if ((next - _scrollController.offset).abs() > 0.1) {
        _scrollController.jumpTo(next);
      }
    }
  }

  void _stopScrollTimer() {
    _autoScrollTicker?.stop();
  }

  void _handleBlockDragUpdate(Offset globalPosition) {
    if (!mounted) return;
    final screenHeight = MediaQuery.of(context).size.height;
    _checkAutoScroll(globalPosition, screenHeight);
  }

  String get _scriptSignature => jsonEncode({
    'name': _scriptName,
    'blocks': _blocks.map((b) => b.toJson()).toList(),
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_saveScript());
    }
  }

  Future<void> _loadScript() async {
    setState(() => _isLoading = true);
    final loadStopwatch = Stopwatch()..start();
    try {
      final scriptPath = QuestPaths.scriptFile(
        widget.questId,
        '${widget.scriptId}.json',
      );
      final internalScriptPath = QuestPaths.internalScriptFile(
        widget.questId,
        '${widget.scriptId}.json',
      );

      final store = await _store();
      String finalPath;
      if (await store.exists(scriptPath)) {
        finalPath = scriptPath;
      } else if (await store.exists(internalScriptPath)) {
        finalPath = internalScriptPath;
      } else {
        // Файла ещё нет. Это нормально для только что созданного скрипта,
        // когда редактор открылся раньше завершения записи — даём записи
        // догнать и перепроверяем один раз.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (await store.exists(scriptPath)) {
          finalPath = scriptPath;
        } else if (await store.exists(internalScriptPath)) {
          finalPath = internalScriptPath;
        } else {
          _blocks = [];
          _scriptName = tr('Новый скрипт');
          // Заведомо новый скрипт: сохранять можно (это сценарий создания).
          _loadCompleted = true;
          _lastSavedSignature = _scriptSignature;
          setState(() {
            _isLoading = false;
            _isConditionalScript = false;
          });
          return;
        }
      }

      final scriptData = await store.readJson(finalPath) ?? <String, dynamic>{};
      _scriptName = scriptData['name'] as String? ?? _scriptName;
      final blocksJson = scriptData['blocks'] as List<dynamic>? ?? [];
      _blocks = ScriptParser.parseBlocks(blocksJson);

      if (_blocks.length == 1 && _blocks.first is ConditionBlock) {
        _isConditionalScript = true;
      } else {
        _isConditionalScript = false;
      }
      // Загрузка успешна: фиксируем сигнатуру, чтобы первый тик автосейва
      // не считал только что прочитанное «грязью».
      _loadCompleted = true;
      _lastSavedSignature = _scriptSignature;
    } catch (e) {
      // Не глотаем ошибку молча: пустой редактор при живом файле на диске
      // выглядит как «скрипт пропал». Показываем проблему пользователю.
      // Сохранение при этом ЗАПРЕЩЕНО (_loadCompleted=false) — иначе
      // автосейв затрёт файл пустотой.
      print('Ошибка: $e');
      _blocks = [];
      _loadCompleted = false;
      if (mounted) {
        _showSnack(
          trf('Не удалось загрузить скрипт: {p0}', {'p0': friendlyError(e)}),
          error: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      loadStopwatch.stop();
      if (kDebugMode) {
        print(
          '⚡ [VisualScriptEditor] Initial open ${widget.scriptId}: '
          '${loadStopwatch.elapsedMilliseconds}ms',
        );
      }
    }

    // Тяжёлую проверку ссылок запускаем фоном, чтобы не блокировать первый экран.
    unawaited(() async {
      final verifyStopwatch = Stopwatch()..start();
      try {
        final wasFixed = await _verifyAndRefreshBlockReferences();
        if (wasFixed) {
          if (mounted) {
            setState(() {});
          }
          await _saveScript();
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ [VisualScriptEditor] Reference refresh failed: $e');
        }
      } finally {
        verifyStopwatch.stop();
        if (kDebugMode) {
          print(
            '⚡ [VisualScriptEditor] Background reference refresh ${widget.scriptId}: '
            '${verifyStopwatch.elapsedMilliseconds}ms',
          );
        }
      }
    }());
  }

  String _extractDisplayNameFromMetaValue(dynamic value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? '' : trimmed;
    }
    if (value is Map) {
      final name = value['name']?.toString().trim() ?? '';
      return name;
    }
    return '';
  }

  /// Хранилище квеста (план 020-C4.2): атомарные записи через ядро.
  Future<QuestStore>? _storeF;
  Future<QuestStore> _store() => _storeF ??= QuestStore.create().then((s) => s);

  /// Очередь сохранений: автосейв-таймер, lifecycle-flush, save-on-deactivate
  /// и закрытие вкладки могут сработать одновременно — без очереди их
  /// записи в один файл перекрывались и портили JSON на диске.
  Future<void> _saveQueue = Future<void>.value();

  /// Публичная точка сохранения: строго последовательно.
  ///
  /// Гард `_loadCompleted` закрывает гонку «сохранили до загрузки»:
  /// onSave/onBeforeClose/lifecycle-inactive могут прийти, пока
  /// `_loadScript` ещё читает файл — тогда на диск ушла бы пустота.
  Future<void> _saveScript() {
    if (!_loadCompleted) return Future<void>.value();
    final task = _saveQueue.then((_) => _doSaveScript());
    // Цепочка переживает ошибку конкретного сохранения.
    _saveQueue = task.then((_) {}, onError: (Object _) {});
    return task;
  }

  Future<void> _doSaveScript() async {
    final scriptPath = QuestPaths.scriptFile(
      widget.questId,
      '${widget.scriptId}.json',
    );
    final internalScriptPath = QuestPaths.internalScriptFile(
      widget.questId,
      '${widget.scriptId}.json',
    );
    final store = await _store();
    final finalPath = await store.exists(scriptPath)
        ? scriptPath
        : internalScriptPath;

    try {
      // Снимок буфера: между сборкой payload и end записи пользователь
      // может добавить блок. Если после записи сверять сигнатуру с живым
      // `_blocks`, новая правка будет помечена сохранённой, хотя на диске
      // остался предыдущий кадр, — и при выходе её сотрёт.
      final savedName = _scriptName;
      final savedBlocks = _blocks.map((block) => block.toJson()).toList();
      final savedSignature = jsonEncode({
        'name': savedName,
        'blocks': savedBlocks,
      });
      final scriptData = {
        'id': widget.scriptId,
        'name': savedName,
        'blocks': savedBlocks,
      };
      await store.writeJson(finalPath, scriptData);
      _lastSavedSignature = savedSignature;
      _docHandle?.markDirty(false);

      if (finalPath.contains('/scripts/')) {
        // metadata.json — атомарный read-modify-write в ядре.
        final metaPath = QuestPaths.metadata(widget.questId);
        final fileName = '${widget.scriptId}.json';
        if (await store.exists(metaPath)) {
          final meta = await store.readJson(metaPath);
          if (meta != null && meta.containsKey(fileName)) {
            final folder =
                (meta[fileName] as Map?)?['folder']?.toString() ?? '/';
            await store.metadataMutate(widget.questId, [
              MetaMut.set(fileName, {'name': savedName, 'folder': folder}),
            ]);
          }
        }
      }
    } catch (e) {
      if (mounted)
        _showSnack(trf('Ошибка: {p0}', {'p0': friendlyError(e)}), error: true);
    }
  }

  // ---------------------------------------------------------------------------
  //  Helper: семантические SnackBar'ы (success / error / warning / info)
  // ---------------------------------------------------------------------------

  void _showSnack(
    String text, {
    bool success = false,
    bool error = false,
    bool warning = false,
    bool info = false,
  }) {
    if (!mounted) return;
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
    } else if (info) {
      bg = scheme.secondaryContainer;
      fg = scheme.onSecondaryContainer;
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

  Future<void> _closeDocument() async {
    await _saveScript();
    if (!mounted) return;
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);
    if (document != null && workspace != null) {
      await workspace.closeDocument(document.id);
    } else {
      Navigator.of(context).pop(true);
    }
  }

  /// Кнопка «Назад» в AppBar: внутри воркспейса — браузерная история
  /// (вкладка остаётся открытой, буфер уже автосейвится), в отдельном
  /// маршруте — выход с сохранением.
  Future<void> _handleBackButton() async {
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);
    if (document != null && workspace != null) {
      await workspace.requestBack();
      return;
    }
    await _closeDocument();
  }

  Future<void> _showSaveLocation() async {
    final scripts = ref.watch(scriptServiceProvider(widget.questId));
    try {
      final changed = await scripts.showSaveLocationSheet(
        context,
        '${widget.scriptId}.json',
      );
      if (changed && mounted) {
        final updated = await scripts.resources.findResourceByFileName(
          '${widget.scriptId}.json',
        );
        if (updated != null && updated.friendlyName.trim().isNotEmpty) {
          setState(() => _scriptName = updated.friendlyName);
        }
        _showSnack(tr('Сохранено'), success: true);
      }
    } catch (e) {
      if (mounted)
        _showSnack(trf('Ошибка: {p0}', {'p0': friendlyError(e)}), error: true);
    }
  }

  Future<void> _renameScript() async {
    final controller = TextEditingController(text: _scriptName);
    final newName = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Переименовать скрипт')),
        content: TextField(
          controller: controller,
          autofocus: true,
          enableInteractiveSelection: true,
          contextMenuBuilder: (context, editableTextState) {
            return AdaptiveTextSelectionToolbar.editableText(
              editableTextState: editableTextState,
            );
          },
          decoration: InputDecoration(
            labelText: tr('Название'),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty) {
      setState(() => _scriptName = newName);
      await _saveScript();
    }
  }

  Future<void> _copyScriptAsTextToClipboard() async {
    final payload = {
      'id': widget.scriptId,
      'name': _scriptName,
      'blocks': _blocks.map((block) => block.toJson()).toList(),
    };
    final prettyJson = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: prettyJson));
    if (mounted) {
      _showSnack(tr('Скрипт скопирован в буфер как текст'), success: true);
    }
  }

  Future<void> _importScriptFromClipboardText() async {
    final data = await Clipboard.getData('text/plain');
    final raw = data?.text?.trim();
    if (raw == null || raw.isEmpty) {
      if (mounted) _showSnack(tr('Буфер обмена пуст'), error: true);
      return;
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      if (mounted) _showSnack(tr('В буфере невалидный JSON'), error: true);
      return;
    }

    List<dynamic>? blocksJson;
    String? importedName;
    if (decoded is Map) {
      final map = Map<String, dynamic>.from(decoded);
      final blocks = map['blocks'];
      if (blocks is List) {
        blocksJson = blocks;
      }
      final name = map['name']?.toString().trim();
      if (name != null && name.isNotEmpty) {
        importedName = name;
      }
    } else if (decoded is List) {
      blocksJson = decoded;
    }

    if (blocksJson == null) {
      if (mounted) {
        _showSnack(
          tr('JSON должен содержать поле "blocks" или быть списком блоков'),
          error: true,
        );
      }
      return;
    }

    List<VisualScriptBlock> parsedBlocks;
    try {
      parsedBlocks = ScriptParser.parseBlocks(blocksJson);
    } catch (e) {
      if (mounted) {
        _showSnack(
          trf('Не удалось импортировать блоки: {p0}', {'p0': friendlyError(e)}),
          error: true,
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }

    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text(tr('Импорт из буфера')),
          content: Text(tr('Заменить текущий скрипт содержимым из буфера?')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.tertiaryContainer,
                foregroundColor: scheme.onTertiaryContainer,
              ),
              child: Text(tr('Заменить')),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _blocks = parsedBlocks;
      if (importedName != null) {
        _scriptName = importedName;
      }
      _isConditionalScript =
          _blocks.length == 1 && _blocks.first is ConditionBlock;
    });

    final wasFixed = await _verifyAndRefreshBlockReferences();
    if (wasFixed && mounted) {
      setState(() {});
    }
    await _saveScript();

    if (mounted) _showSnack(tr('Скрипт импортирован из буфера'), success: true);
  }

  String _normalizeScriptId(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;
    final slashIndex = value.lastIndexOf('/');
    if (slashIndex != -1) {
      value = value.substring(slashIndex + 1);
    }
    if (value.endsWith('.json')) {
      value = value.substring(0, value.length - 5);
    }
    return value;
  }

  Future<Map<String, String>> _loadNodeNamesById() async {
    final nodesData = await QuestNodesStore.read(widget.questId);
    final nodes = (nodesData['nodes'] as List<dynamic>? ?? []);
    final result = <String, String>{};
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      final id = node['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final title = (node['title']?.toString().trim().isNotEmpty ?? false)
          ? node['title'].toString()
          : tr('Нода');
      result[id] = title;
    }
    return result;
  }

  Future<Map<String, String>> _loadScriptNamesById() async {
    final result = <String, String>{};
    final folders = [
      QuestPaths.scriptsDir(widget.questId),
      QuestPaths.internalScriptsDir(widget.questId),
    ];
    final metadataPath = QuestPaths.metadata(widget.questId);
    Map<String, dynamic> metadata = const {};
    if (await FileStorage.exists(metadataPath)) {
      try {
        metadata = await FileStorage.readJsonFile(metadataPath);
      } catch (_) {}
    }

    for (final folder in folders) {
      if (!await FileStorage.exists(folder)) continue;
      final files = await FileStorage.listFiles(folder, extension: '.json');
      for (final fileName in files) {
        final dotIndex = fileName.lastIndexOf('.');
        final id = dotIndex == -1 ? fileName : fileName.substring(0, dotIndex);
        if (id.isEmpty) continue;

        // Для обычных скриптов берём имя из metadata, чтобы не читать каждый файл с диска.
        if (folder.endsWith('/scripts')) {
          final metaName = _extractDisplayNameFromMetaValue(metadata[fileName]);
          if (metaName.isNotEmpty) {
            result[id] = metaName;
            continue;
          }
        }

        // Fallback без дискового чтения: используем id/текущее имя.
        if (id == widget.scriptId && _scriptName.trim().isNotEmpty) {
          result[id] = _scriptName.trim();
        } else {
          result[id] = fileName;
        }
      }
    }

    return result;
  }

  bool _refreshReferenceNamesInList(
    List<VisualScriptBlock> blocks, {
    required Map<String, String> nodeNames,
    required Map<String, String> scriptNames,
  }) {
    var changed = false;

    for (final block in blocks) {
      if (block is GoToNodeBlock) {
        final target = block.targetNodeId?.trim();
        if (target != null &&
            target.isNotEmpty &&
            !target.startsWith('=') &&
            !target.startsWith('{')) {
          final actualNodeName = nodeNames[target];
          if (actualNodeName != null) {
            if (block.targetNodeName != actualNodeName) {
              block.targetNodeName = actualNodeName;
              changed = true;
            }
          } else {
            final shortId = target.length > 8 ? target.substring(0, 8) : target;
            final fallback = 'ID: $shortId...';
            if (block.targetNodeName != fallback) {
              block.targetNodeName = fallback;
              changed = true;
            }
          }
        }
      } else if (block is CallScriptBlock) {
        final rawScriptId = block.scriptId?.trim();
        if (rawScriptId != null && rawScriptId.isNotEmpty) {
          final normalized = _normalizeScriptId(rawScriptId);
          if (normalized != rawScriptId) {
            block.scriptId = normalized;
            changed = true;
          }
          final actualScriptName = scriptNames[normalized];
          if (actualScriptName != null) {
            if (block.scriptName != actualScriptName) {
              block.scriptName = actualScriptName;
              changed = true;
            }
          } else if (block.scriptName != 'Скрипт не найден') {
            block.scriptName = 'Скрипт не найден';
            changed = true;
          }
        }
      } else if (block is CallFunctionBlock) {
        final rawFunctionId = block.functionId?.trim();
        if (rawFunctionId != null && rawFunctionId.isNotEmpty) {
          final normalized = _normalizeScriptId(rawFunctionId);
          if (normalized != rawFunctionId) {
            block.functionId = normalized;
            changed = true;
          }
          final entry = block.functionEntry.trim().isEmpty
              ? 'main'
              : block.functionEntry.trim();
          if (entry != block.functionEntry) {
            block.functionEntry = entry;
            changed = true;
          }
          final actualFunctionName = scriptNames[normalized];
          if (actualFunctionName != null) {
            final displayName = '$actualFunctionName :: ${block.functionEntry}';
            if (block.functionName != displayName) {
              block.functionName = displayName;
              changed = true;
            }
          } else if (block.functionName != 'Функция не найдена :: $entry') {
            block.functionName = 'Функция не найдена :: $entry';
            changed = true;
          }
        }
      }

      for (final nested in block.nestedBlockLists) {
        if (_refreshReferenceNamesInList(
          nested,
          nodeNames: nodeNames,
          scriptNames: scriptNames,
        )) {
          changed = true;
        }
      }
    }

    return changed;
  }

  Future<bool> _verifyAndRefreshBlockReferences() async {
    final nodeNames = await _loadNodeNamesById();
    final scriptNames = await _loadScriptNamesById();
    return _refreshReferenceNamesInList(
      _blocks,
      nodeNames: nodeNames,
      scriptNames: scriptNames,
    );
  }

  List<String> _collectFunctionNames() {
    final names = <String>{'main'};
    for (final block in _blocks) {
      if (block is! EventBlock) continue;
      if (block.eventType != EventType.function) continue;
      final name = block.functionName.trim();
      if (name.isNotEmpty) {
        names.add(name);
      }
    }
    final list = names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  void _addEventBlock() {
    setState(() {
      _blocks.add(EventBlock(eventType: EventType.onNodeEnter, children: []));
    });
  }

  Future<void> _addActionBlock() async {
    // Действию нужен контейнер: без события список показал бы «Неверный блок».
    if (!_blocks.any((b) => b is EventBlock)) _addEventBlock();

    final entry = await showBlockPicker(context);
    if (entry == null || !mounted) return;

    final newBlock = _createBlockFromType(entry.name);
    // Тап по палитре = готовый результат: блок сразу встаёт в разрыв,
    // ближайший к центру экрана, а не «зависает» карточкой, которую надо
    // ещё и притащить пальцем.
    final target = _insertionTarget();
    setState(() => target.list.insert(target.index, newBlock));
    _revealBlock(newBlock.id);
  }

  /// Список-владелец и позиция, куда вставить новый блок.
  ///
  /// Приоритет — разрыв ближе всего к центру видимой области (см.
  /// [pickBlockInsertion]). Считаются только дочерние списки событий: в
  /// корневом списке лежат сами события, а вложенные ветки условия экран не
  /// измеряет. Если измерить нечего (скрипт пустой, все блоки свёрнуты или
  /// ещё не построены), блок уходит в конец последнего события.
  ({List<VisualScriptBlock> list, int index}) _insertionTarget() {
    final viewport = _viewportRect();
    if (viewport != null) {
      final measured = <List<VisualScriptBlock>>[];
      final rects = <List<Rect>>[];
      for (final block in _blocks) {
        if (block is! EventBlock || block.children.isEmpty) continue;
        final positions = block.children
            .map((child) => _blockRect(child.id))
            .toList();
        // Список участвует в выборе только целиком: частичный замер сдвинул бы
        // разрывы относительно соседних событий.
        if (positions.any((r) => r == null)) continue;
        measured.add(block.children);
        rects.add(positions.cast<Rect>());
      }
      final picked = pickBlockInsertion(lists: rects, viewport: viewport);
      if (picked != null) {
        return (list: measured[picked.listIndex], index: picked.insertIndex);
      }
    }
    for (int i = _blocks.length - 1; i >= 0; i--) {
      final block = _blocks[i];
      if (block is EventBlock) {
        return (list: block.children, index: block.children.length);
      }
    }
    // События нет (или его удалили, пока была открыта палитра): действию
    // нужен контейнер, иначе список покажет «Неверный блок».
    _addEventBlock();
    final event = _blocks.last as EventBlock;
    return (list: event.children, index: 0);
  }

  Rect? _viewportRect() {
    if (!_scrollController.hasClients) return null;
    final box = _scrollController.position.context.storageContext
        .findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect? _blockRect(String blockId) {
    final state = _blockKeys[blockId]?.currentContext;
    if (state == null) return null;
    final box = state.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Подтянуть прокрутку к новому блоку, если он оказался за краем экрана.
  void _revealBlock(String blockId) {
    final state = _blockKeys[blockId]?.currentContext;
    if (state == null) return;
    Scrollable.ensureVisible(
      state,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  VisualScriptBlock _createBlockFromType(String blockType) {
    switch (blockType) {
      case 'assign_variable':
        return AssignVariableBlock();
      case 'condition':
        return ConditionBlock();
      case 'go_to_node':
        return GoToNodeBlock();
      case 'set_volume':
        return SetVolumeBlock();
      case 'set_blur':
        return SetBlurBlock();
      case 'wait':
        return DelayBlock();
      case 'call_script':
        return CallScriptBlock();
      case 'call_function':
        return CallFunctionBlock();
      case 'call_lua':
        return CallLuaBlock();
      // --- ДОБАВЛЕНО ---
      case 'table_operation':
        return TableOperationBlock();
      case 'set_image':
        return SetImageBlock();
      case BlockTypes.setVisible:
        return SetVisibleBlock();
      case 'play_sound':
        return PlaySoundBlock();
      case 'stop_sound':
        return StopSoundBlock();
      case 'play_music':
        return PlayMusicBlock();
      case 'stop_music':
        return StopMusicBlock();
      case 'pause_resume':
        return PauseResumeBlock();
      case 'crossfade':
        return CrossfadeBlock();
      case 'open_link':
        return OpenLinkBlock();
      case 'http_request':
        return HttpRequestBlock();
      case 'comment':
        return CommentBlock();
      case 'for_each':
        return ForEachBlock();
      case 'while':
        return WhileBlock();
      // -----------------
      default:
        return AssignVariableBlock(variableName: 'unknown');
    }
  }

  void _handleBlockDrop(
    VisualScriptBlock droppedBlock,
    List<VisualScriptBlock> targetList,
  ) {
    // При перетаскивании между списками, блок должен быть удален из старого места
    // и добавлен в новое. ReorderableBlockList управляет вставкой, но мы должны
    // удалить блок из глобального списка, если он там был
    setState(() {
      // Удаляем блок из основного списка, если он там есть
      removeBlockFromTree(droppedBlock.id, _blocks);
    });
    _stopScrollTimer();
  }

  /// Меню корневого блока в редакторе условного скрипта. Та же логика, что в
  /// [ReorderableBlockList] для вложенных списков: операции применяются к
  /// этому блоку и вставка идёт рядом с ним, а не в конец списка.
  void _handleBlockMenuAction(
    ScriptBlockMenuAction action,
    VisualScriptBlock block,
  ) {
    final loc = locateBlockInTree(block.id, _blocks);
    switch (action) {
      case ScriptBlockMenuAction.copy:
        ref
            .read(visualScriptClipboardProvider.notifier)
            .state = VisualScriptClipboardItem(
          blocks: [block.clone()],
          operation: 'copy',
        );
        _showSnack(blockOperationToast(action, block), success: true);
      case ScriptBlockMenuAction.cut:
        ref
            .read(visualScriptClipboardProvider.notifier)
            .state = VisualScriptClipboardItem(
          blocks: [block.clone()],
          operation: 'cut',
        );
        if (loc != null) {
          loc.list.removeAt(loc.index);
          setState(() {});
        }
        _showSnack(blockOperationToast(action, block), warning: true);
      case ScriptBlockMenuAction.duplicate:
        if (loc != null) {
          loc.list.insert(loc.index + 1, block.clone());
          setState(() {});
          _showSnack(blockOperationToast(action, block), info: true);
        }
      case ScriptBlockMenuAction.paste:
        _pasteClipboardAfter(block);
      case ScriptBlockMenuAction.delete:
        if (loc != null) {
          loc.list.removeAt(loc.index);
          setState(() {});
        }
    }
  }

  void _pasteClipboardAfter(VisualScriptBlock block) {
    final clipboardItem = ref.read(visualScriptClipboardProvider);
    if (clipboardItem == null) {
      _showSnack(tr('Буфер обмена пуст'), error: true);
      return;
    }
    final clonedBlocks = cloneBlocks(clipboardItem.blocks);
    // Вставляем сразу после блока, по которому открыли меню, а не в конец.
    final pasteLoc = locateBlockInTree(block.id, _blocks);
    if (pasteLoc != null) {
      pasteLoc.list.insertAll(pasteLoc.index + 1, clonedBlocks);
    } else {
      _blocks.addAll(clonedBlocks);
    }
    setState(() {});
    if (clipboardItem.operation == 'cut') {
      ref.read(visualScriptClipboardProvider.notifier).state = null;
    }
    _showSnack(
      trf('Блоки вставлены ({p0})', {'p0': clonedBlocks.length}),
      info: true,
    );
  }

  void _deleteEventBlock(int index) {
    setState(() {
      _blocks.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return EditorDocumentBackScope(
      onBackPressed: () async {
        await _closeDocument();
        return true;
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _scriptName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.edit_rounded, size: 18),
                tooltip: tr('Переименовать'),
                onPressed: _renameScript,
              ),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
            onPressed: _handleBackButton,
          ),
          actions: [
            // Кнопки «Сохранить» здесь нет намеренно: скрипт пишется на диск
            // автосейвом (тик ниже) и на любом выходе/деактивации вкладки.
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              tooltip: tr('Ещё'),
              onSelected: (value) {
                if (value == 'copy_script_text') {
                  _copyScriptAsTextToClipboard();
                } else if (value == 'paste_script_text') {
                  _importScriptFromClipboardText();
                } else if (value == 'save_location') {
                  _showSaveLocation();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'save_location',
                  child: Row(
                    children: [
                      Icon(Icons.folder_rounded, size: 18),
                      SizedBox(width: 12),
                      Text(tr('Сохранить в папку…')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'copy_script_text',
                  child: Row(
                    children: [
                      Icon(Icons.copy_all_rounded, size: 18),
                      SizedBox(width: 12),
                      Text(tr('Скопировать скрипт как JSON')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'paste_script_text',
                  child: Row(
                    children: [
                      Icon(Icons.content_paste_rounded, size: 18),
                      SizedBox(width: 12),
                      Text(tr('Импортировать JSON из буфера')),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: _isLoading
            ? Center(child: CircularProgressIndicator(color: scheme.primary))
            : _isConditionalScript
            ? _buildConditionalEditorBody()
            : _blocks.isEmpty
            ? _buildEmptyState()
            : _buildActionEditorBody(),
        floatingActionButton: _isConditionalScript
            ? null
            // Круглая кнопка вместо подписанной пилюли: «Добавить действие» на
            // всю ширину лежала поверх последнего блока и нижней строки, а на
            // телефоне ещё и закрывала палитру. Подпись осталась в подсказке.
            : FloatingActionButton(
                heroTag:
                    'add_action_block_fab_${widget.questId}_${widget.scriptId}',
                onPressed: _addActionBlock,
                tooltip: tr('Добавить действие'),
                child: const Icon(Icons.add_rounded),
              ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Helper: ограничивает ширину контента на ПК (большие мониторы), чтобы
  //  блоки не растягивались на 2000+px и оставались читаемыми.
  // ---------------------------------------------------------------------------

  Widget _constrainForDesktop(Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: child,
      ),
    );
  }

  Widget _buildConditionalEditorBody() {
    if (_blocks.isEmpty || _blocks.first is! ConditionBlock) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Text(
          tr('Ошибка: ожидался блок условия.'),
          style: TextStyle(color: scheme.error),
        ),
      );
    }
    return _constrainForDesktop(
      ListView(
        controller: _scrollController,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          BlockFactory(
            block: _blocks.first,
            questId: widget.questId,
            // Тот же обработчик, что в редакторе действий: он вычищает блок из
            // дерева ДО вставки в целевой список. Без него перетаскивание
            // блока из «тогда» в «иначе» оставляло копию в исходной ветке.
            onBlockDrop: _handleBlockDrop,
            onDragUpdate: _handleBlockDragUpdate,
            onDragEnd: _stopScrollTimer,
          ),
        ],
      ),
    );
  }

  Widget _buildActionEditorBody() {
    final scheme = Theme.of(context).colorScheme;
    final availableFunctionNames = _collectFunctionNames();
    return _constrainForDesktop(
      Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scrollController,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: _blocks.asMap().entries.map((entry) {
                final index = entry.key;
                final block = entry.value;

                if (block is EventBlock) {
                  return EventBlockWidget(
                    key: ValueKey(block.id),
                    block: block,
                    questId: widget.questId,
                    availableFunctionNames: availableFunctionNames,
                    onDelete: () => _deleteEventBlock(index),
                    onMenuAction: (action) =>
                        _handleBlockMenuAction(action, block),
                    onBlockDrop: _handleBlockDrop,
                    onDragUpdate: _handleBlockDragUpdate,
                    onDragEnd: _stopScrollTimer,
                    blockKeyResolver: _blockKeyFor,
                  );
                }
                return Container(
                  key: ValueKey(block.id),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    trf('Неверный блок: {p0}', {'p0': block.runtimeType}),
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('add_event_button'),
                  icon: const Icon(Icons.event_note_rounded),
                  label: Text(
                    tr('Добавить событие'),
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  onPressed: _addEventBlock,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.code_off_rounded,
                size: 44,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              tr('Скрипт пуст'),
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tr('Добавьте первое событие, чтобы начать'),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.event_note_rounded),
              label: Text(
                tr('Добавить событие'),
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              onPressed: _addEventBlock,
            ),
          ],
        ),
      ),
    );
  }
}
