import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/gestures.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/editor/providers/visual_script_clipboard_provider.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/action_picker_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_factory.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_signature.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_validator.dart';
import 'package:canvas_app/features/editor/workspace/editor_back_handler.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_lifecycle.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/editor/workspace/script_document_store.dart';
import 'package:canvas_app/core/services/session_recorder.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';

import '../visual_script_editor/block_creation.dart';
import 'scratch_block_view.dart';
import 'scratch_camera.dart';
import 'scratch_layout.dart';
import 'scratch_move.dart';
import 'scratch_script_painter.dart';

/// Редактор визуальных скриптов на бесконечном канвасе.
///
/// Правит те же файлы, что и классический [VisualScriptEditorScreen]: формат
/// JSON, поиск пути и `metadata.json` общие ([ScriptDocumentStore]). Выбор
/// редактора — настройка устройства ([ScriptEditorModeStore]).
///
/// Дерево блоков рисуется одним painter'ом, а не виджетами: на 1000 блоков
/// Flutter не тянет тысячу карточек с тенями и текст-стилями, а canvas с
/// отсечением по видимой области тянет.
class ScratchScriptEditorScreen extends ConsumerStatefulWidget {
  const ScratchScriptEditorScreen({
    super.key,
    required this.questId,
    required this.scriptId,
  });

  final String questId;
  final String scriptId;

  @override
  ConsumerState<ScratchScriptEditorScreen> createState() =>
      _ScratchScriptEditorScreenState();
}

class _ScratchScriptEditorScreenState
    extends ConsumerState<ScratchScriptEditorScreen>
    with WidgetsBindingObserver {
  late final ScriptDocumentStore _document = ScriptDocumentStore(
    questId: widget.questId,
    scriptId: widget.scriptId,
  );

  final ScratchCameraController _camera = ScratchCameraController();
  final ScratchLayoutEngine _engine = ScratchLayoutEngine();
  final ScratchPaintCache _paintCache = ScratchPaintCache();

  List<VisualScriptBlock> _blocks = [];
  ScratchLayout _layout = ScratchLayout.empty;
  Size _viewport = Size.zero;

  String _scriptName = '';
  bool _isLoading = true;

  /// Скрипт-условие: единственный корень — `ConditionBlock`. Его нельзя
  /// дополнять событиями, новые блоки идут в ветки условия.
  bool get _isConditionalScript =>
      _blocks.length == 1 && _blocks.first is ConditionBlock;

  /// Контент прочитан (или это заведомо новый скрипт). Пока false — любое
  /// сохранение запрещено: иначе недогруженный редактор затёр бы файл.
  bool _canSave = false;
  String _lastSavedSignature = '';

  /// Очередь записей: автосейв, «Выйти», закрытие вкладки и вытеснение из
  /// кэша поверхностей могут прийти одновременно. Раньше второй вызов
  /// молча отбрасывался флагом `_isSaving` — правка, сделанная во время
  /// записи, до диска не доезжала вовсе.
  Future<void> _saveQueue = Future<void>.value();
  Timer? _autoSaveTimer;
  EditorDocumentHandle? _handle;

  String? _selectedId;

  /// Свободные позиции корневых блоков (как в Scratch): каждый стек стоит
  /// там, куда его положили. Хранится в файле скрипта ключом `layout`.
  final Map<String, Offset> _origins = {};

  // Перетаскивание блока по канвасу.
  VisualScriptBlock? _dragBlock;
  bool _dragging = false;
  Offset _gestureStart = Offset.zero;

  /// Точка касания до того, как распознаватель прошёл slop: `onScaleStart`
  /// приходит уже сдвинутым на slop, и брать оттуда точку захвата — значит
  /// терять первые ~20 px пути (блок уезжал бы не туда).
  Offset? _pressLocal;
  Offset _grab = Offset.zero;
  ScratchListSlot? _dropSlot;
  int _dropIndex = 0;
  Rect? _dropLine;

  /// Куда встанет блок, если бросить его мимо стека (свободная расстановка).
  Offset _ghostTopLeft = Offset.zero;
  Set<String> _hiddenIds = const {};

  // Пинч/панорама.
  double _gestureStartScale = 1.0;
  bool _panning = false;

  Offset? _doubleTapPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _handle ??= EditorDocumentLifecycle.capture(context);
    final active = EditorDocumentContext.maybeOf(context)?.isActive ?? true;
    final wasActive = _lastActiveState;
    _lastActiveState = active;
    // Вкладку убрали с экрана — сбрасываем буфер, иначе пересоздание
    // вкладки покажет устаревшее содержимое.
    if (wasActive == true && !active && _canSave) {
      unawaited(_saveScript());
    }
    _handle?.registerRuntime(
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
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    // Размонтирование (закрытие вкладки, вытеснение из LRU-кэша, уход
    // маршрута) не проходит ни `onBeforeClose`, ни lifecycle: флешим буфер
    // здесь. Запись стартует СИНХРОННО — её регистрацию в хранилище должен
    // увидеть экземпляр, который сейчас читает этот же файл.
    if (_canSave) unawaited(_saveScript());
    _handle?.unregisterRuntime();
    WidgetsBinding.instance.removeObserver(this);
    _camera.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _saveScript();
    }
  }

  // ── Загрузка и сохранение ────────────────────────────────────────

  Future<void> _load() async {
    try {
      final doc = await _document.load();
      if (!mounted) return;
      setState(() {
        _blocks = doc.blocks;
        _scriptName = doc.name.trim().isEmpty ? tr('Скрипт') : doc.name;
        _origins
          ..clear()
          ..addAll(doc.layout);
        _isLoading = false;
        _canSave = true;
        _lastSavedSignature = _signature();
        _relayout();
      });
      SessionRecorder.instance.record('script', {
        'action': 'load',
        'scriptId': widget.scriptId,
        'blocks': _blocks.length,
        'ok': true,
        'editor': 'canvas',
      });
      // Первый кадр ещё не знает размера вьюпорта — вписываем после него.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
    } catch (e) {
      SessionRecorder.instance.record('script', {
        'action': 'load',
        'scriptId': widget.scriptId,
        'ok': false,
        'editor': 'canvas',
        'error': friendlyError(e),
      });
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(
        trf('Не удалось загрузить скрипт: {p0}', {'p0': friendlyError(e)}),
        error: true,
      );
    }
  }

  void _relayout() {
    _layout = _engine.layout(_blocks, origins: _origins);
  }

  /// Позиции только для блоков, которые реально лежат в корне: иначе карта
  /// копит мусор от удалённых и вложенных блоков и уезжает в файл.
  Map<String, Offset> _rootLayout() {
    final ids = _blocks.map((block) => block.id).toSet();
    return {
      for (final entry in _origins.entries)
        if (ids.contains(entry.key)) entry.key: entry.value,
    };
  }

  String _signature() {
    final base = scriptSignatureOf(name: _scriptName, blocks: _blocks);
    final layout = _rootLayout();
    final keys = layout.keys.toList()..sort();
    final positions = [
      for (final key in keys)
        '$key:${layout[key]!.dx.round()},${layout[key]!.dy.round()}',
    ].join(';');
    return '$base|$positions';
  }

  void _markDirty() {
    _handle?.markDirty(true);
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 1), _saveScript);
  }

  /// Держим последнее известное `isActive`: по переходу true→false буфер
  /// сбрасывается на диск (как в классическом редакторе).
  bool? _lastActiveState;

  /// Публичная точка записи: строго последовательно, без потери вызовов.
  Future<void> _saveScript() {
    final task = _saveQueue.then((_) => _saveNow());
    _saveQueue = task.then((_) {}, onError: (Object _) {});
    return task;
  }

  Future<void> _saveNow() async {
    if (!_canSave) return;
    final signature = _signature();
    if (signature == _lastSavedSignature) {
      _handle?.markDirty(false);
      return;
    }
    final savedLayout = _rootLayout();
    try {
      await _document.save(
        name: _scriptName,
        blocks: _blocks,
        layout: savedLayout,
      );
      _lastSavedSignature = signature;
      _handle?.markDirty(false);
      SessionRecorder.instance.record('script', {
        'action': 'save',
        'scriptId': widget.scriptId,
        'blocks': _blocks.length,
        'ok': true,
        'editor': 'canvas',
      });
    } catch (e) {
      SessionRecorder.instance.record('script', {
        'action': 'save',
        'scriptId': widget.scriptId,
        'blocks': _blocks.length,
        'ok': false,
        'editor': 'canvas',
        'error': friendlyError(e),
      });
      if (mounted) {
        _showSnack(trf('Ошибка: {p0}', {'p0': friendlyError(e)}), error: true);
      }
    }
  }

  Future<void> _closeDocument() async {
    if (!await _confirmLeaveWithIssues()) return;
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

  Future<bool> _confirmLeaveWithIssues() async {
    final issues = validateScriptBlocks(
      _blocks,
      tables: await _document.tableNames(),
    );
    if (issues.isEmpty || !mounted) return true;

    const shown = 6;
    final leave = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('В скрипте есть проблемы')),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final issue in issues.take(shown))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• ${issue.message}'),
                ),
              if (issues.length > shown)
                Text(trf('…и ещё {p0}', {'p0': issues.length - shown})),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Исправить')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Выйти как есть')),
          ),
        ],
      ),
    );
    return leave == true;
  }

  // ── Камера ───────────────────────────────────────────────────────

  void _fit() {
    if (_viewport.isEmpty) return;
    _camera.fit(_layout.bounds.inflate(40), _viewport);
  }

  void _zoomBy(double factor) {
    if (_viewport.isEmpty) return;
    _camera.zoomAtCenter(factor, _viewport);
  }

  void _scrollTo(VisualScriptBlock block) {
    if (_viewport.isEmpty) return;
    for (final row in _layout.rows) {
      if (row.kind == ScratchRowKind.head && row.block.id == block.id) {
        final target =
            _viewport.center(Offset.zero) - Offset(0, _viewport.height * 0.2);
        _camera.panBy(target - _camera.worldToScreen(row.rect.center));
        return;
      }
    }
  }

  // ── Жесты ────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    final start = _pressLocal ?? details.localFocalPoint;
    _gestureStart = start;
    _gestureStartScale = _camera.scale;
    _dragBlock = null;
    _dragging = false;
    _hiddenIds = const {};
    _dropSlot = null;
    _dropLine = null;

    final world = _camera.screenToWorld(start);
    final block = _layout.blockAt(world);
    if (block != null && details.pointerCount == 1) {
      _dragBlock = block;
      _grab = world - (_layout.headRectOf(block.id)?.topLeft ?? world);
      _ghostTopLeft = world - _grab;
      _panning = false;
    } else {
      _panning = details.pointerCount == 1;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      // Пинч: зум вокруг фокуса, панорама — из смещения фокуса.
      _camera.panBy(details.focalPointDelta);
      _camera.zoomAt(
        _gestureStartScale * details.scale,
        details.localFocalPoint,
      );
      setState(() {
        _dragBlock = null;
        _dragging = false;
        _dropSlot = null;
        _dropLine = null;
      });
      return;
    }

    final block = _dragBlock;
    if (block == null) {
      if (_panning) _camera.panBy(details.focalPointDelta);
      return;
    }

    final world = _camera.screenToWorld(details.localFocalPoint);
    if (!_dragging && (details.localFocalPoint - _gestureStart).distance > 6) {
      _dragging = true;
      _selectedId = block.id;
      _hiddenIds = _subtreeIds(block);
    }
    if (!_dragging) return;

    _ghostTopLeft = world - _grab;

    // 1. Ветка контейнера — вставка по вертикали внутри тела.
    final branch = _layout.slotAt(world);
    if (branch != null && !blockOwnsList(block, branch.list)) {
      final index = _layout.insertIndexIn(branch, world.dy);
      setState(() {
        _dropSlot = branch;
        _dropIndex = index;
        _dropLine = _dropLineFor(branch, index);
      });
      return;
    }

    // 2. Прилипание к блоку/стеку — как SNAP_RADIUS в Blockly: бросок рядом
    // с низом стека прикрепляет блок к нему, а не оставляет висеть.
    final snap = _snapBlockAt(world, block);
    if (snap != null) {
      final list = snap.row.ownerList!;
      final index = snap.row.index + 1;
      setState(() {
        _dropSlot = ScratchListSlot(
          key: 'snap:${snap.row.block.id}',
          list: list,
          rect: snap.row.rect,
        )..rows.add(snap.row);
        _dropIndex = index;
        _dropLine = _dropLineFor(_dropSlot!, index);
      });
      return;
    }

    // 3. Свободный сброс: блок останется там, где его отпустили.
    setState(() {
      _dropSlot = null;
      _dropLine = null;
    });
  }

  /// Жест отменили (система забрала указатель): возвращаем блок на место,
  /// не записывая позицию.
  void _abortDrag() {
    _pressLocal = null;
    setState(() {
      _dragBlock = null;
      _dragging = false;
      _panning = false;
      _dropSlot = null;
      _dropLine = null;
      _hiddenIds = const {};
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final block = _dragBlock;
    final slot = _dropSlot;
    final wasDragging = _dragging;
    final ghost = _ghostTopLeft;
    _pressLocal = null;
    setState(() {
      _dragBlock = null;
      _dragging = false;
      _panning = false;
      _dropSlot = null;
      _dropLine = null;
      _hiddenIds = const {};
    });
    if (!wasDragging || block == null) return;
    if (slot != null) {
      _moveBlock(block, slot, _dropIndex, ghost);
    } else {
      _dropFree(block, ghost);
    }
  }

  /// Все id блока вместе с вложенными: оригинал целиком прячется, пока
  /// «летит» призрак.
  Set<String> _subtreeIds(VisualScriptBlock block) {
    final ids = <String>{block.id};
    void walk(VisualScriptBlock node) {
      for (final nested in node.nestedBlockLists) {
        for (final child in nested) {
          ids.add(child.id);
          walk(child);
        }
      }
    }

    walk(block);
    return ids;
  }

  /// Ближайший блок в радиусе прилипания (любая строка, не только корень).
  _SnapRow? _snapBlockAt(Offset world, VisualScriptBlock dragged) {
    _SnapRow? best;
    // Радиус задан в экранных пикселях: при сильном зуме прилипание не должно
    // растягиваться на пол-канваса.
    var bestDistance =
        ScratchMetrics.snapRadius / math.max(_camera.scale, 0.05);
    for (final row in _layout.rows) {
      if (row.kind != ScratchRowKind.head) continue;
      if (row.ownerList == null) continue;
      // Свой собственный блок не притягивает, а внутрь себя бросать нельзя.
      if (row.block.id == dragged.id) continue;
      if (blockOwnsList(dragged, row.ownerList!)) continue;
      final distance = _distanceToRect(row.rect, world);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = _SnapRow(row);
      }
    }
    return best;
  }

  double _distanceToRect(Rect rect, Offset point) {
    final dx = point.dx < rect.left
        ? rect.left - point.dx
        : point.dx > rect.right
        ? point.dx - rect.right
        : 0.0;
    final dy = point.dy < rect.top
        ? rect.top - point.dy
        : point.dy > rect.bottom
        ? point.dy - rect.bottom
        : 0.0;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Свободный сброс: блок становится отдельным стеком в точке [topLeft].
  void _dropFree(VisualScriptBlock block, Offset topLeft) {
    final loc = locateBlockInTree(block.id, _blocks);
    if (loc == null) return;
    setState(() {
      if (!identical(loc.list, _blocks)) {
        loc.list.removeAt(loc.index);
        _blocks.add(block);
      }
      _origins[block.id] = topLeft;
      _relayout();
    });
    _markDirty();
  }

  Rect _dropLineFor(ScratchListSlot slot, int index) {
    const width = 200.0;
    final left = slot.rect.left;
    final double y;
    if (slot.rows.isEmpty) {
      y = slot.rect.top + 2;
    } else if (index <= 0) {
      y = slot.rows.first.rect.top - 2;
    } else if (index >= slot.rows.length) {
      y = slot.rows.last.rect.bottom + 2;
    } else {
      y = (slot.rows[index - 1].rect.bottom + slot.rows[index].rect.top) / 2;
    }
    return Rect.fromLTWH(left, y - 2, width, 4);
  }

  void _moveBlock(
    VisualScriptBlock block,
    ScratchListSlot slot,
    int index,
    Offset ghostTopLeft,
  ) {
    final moved = moveBlockToSlot(
      block: block,
      roots: _blocks,
      slot: slot,
      index: index,
    );
    if (!moved) return;
    setState(() {
      if (identical(slot.list, _blocks)) {
        // Корень не «прилипает» геометрией: у каждого стека своя позиция.
        // Поэтому прилипание к корню — это позиция сразу под целевым стеком,
        // а не точка под пальцем (иначе блок вставал бы поверх соседа).
        final at = _blocks.indexOf(block);
        final above = at > 0 ? _blockRect(_blocks[at - 1]) : null;
        _origins[block.id] = above == null
            ? ghostTopLeft
            : Offset(above.left, above.bottom + ScratchMetrics.rootGap);
      } else {
        _origins.remove(block.id);
      }
      _relayout();
    });
    _markDirty();
  }

  void _handleTap(TapUpDetails details) {
    final world = _camera.screenToWorld(details.localPosition);
    final row = _layout.rowAt(world);
    final id = row?.kind == ScratchRowKind.head ? row!.block.id : null;
    if (id != _selectedId) setState(() => _selectedId = id);
  }

  void _handleDoubleTap() {
    final position = _doubleTapPosition;
    if (position == null) return;
    final row = _layout.rowAt(_camera.screenToWorld(position));
    if (row == null || row.kind != ScratchRowKind.head) return;
    _editBlock(row.block);
  }

  void _handleSecondaryTap(TapUpDetails details) {
    final row = _layout.rowAt(_camera.screenToWorld(details.localPosition));
    if (row == null || row.kind != ScratchRowKind.head) return;
    setState(() => _selectedId = row.block.id);
    _showBlockMenu(row.block, details.globalPosition);
  }

  // ── Операции над блоками ─────────────────────────────────────────

  VisualScriptBlock? get _selectedBlock {
    final id = _selectedId;
    if (id == null) return null;
    return _findBlock(id);
  }

  VisualScriptBlock? _findBlock(String id) {
    VisualScriptBlock? walk(List<VisualScriptBlock> list) {
      for (final block in list) {
        if (block.id == id) return block;
        for (final nested in block.nestedBlockLists) {
          final hit = walk(nested);
          if (hit != null) return hit;
        }
      }
      return null;
    }

    return walk(_blocks);
  }

  /// Куда добавить новый блок: в конец внутренностей выбранного контейнера,
  /// иначе сразу после выбранного, иначе в конец корня.
  ({List<VisualScriptBlock> list, int index}) _insertionTarget() {
    final selected = _selectedBlock;
    if (selected != null && selected.nestedBlockLists.isNotEmpty) {
      final list = selected.nestedBlockLists.first;
      return (list: list, index: list.length);
    }
    if (selected != null) {
      final loc = locateBlockInTree(selected.id, _blocks);
      if (loc != null) return (list: loc.list, index: loc.index + 1);
    }
    if (_isConditionalScript) {
      final condition = _blocks.first as ConditionBlock;
      return (list: condition.thenBlocks, index: condition.thenBlocks.length);
    }
    return (list: _blocks, index: _blocks.length);
  }

  /// Точка для нового корня: центр экрана (с небольшим сдвигом), чтобы блок
  /// появился там, куда смотрит автор, а не в начале координат.
  /// Полный прямоугольник блока вместе с детьми: шапка плюс измеренная
  /// высота дерева. У события фрейма нет (это шляпа со стеком), поэтому
  /// искать только по кадрам нельзя.
  Rect? _blockRect(VisualScriptBlock block) {
    final head = _layout.headRectOf(block.id);
    if (head == null) return null;
    return Rect.fromLTWH(
      head.left,
      head.top,
      _engine.blockWidth(block),
      _engine.blockHeight(block),
    );
  }

  /// Свободная точка под [above] (или в центре экрана, если ставить не под кем).
  Offset _nextRootSpot(VisualScriptBlock? above) {
    final rect = above == null ? null : _blockRect(above);
    if (rect == null) return _freeSpot();
    return Offset(rect.left, rect.bottom + ScratchMetrics.rootGap);
  }

  Offset _freeSpot() {
    if (_viewport.isEmpty) return Offset.zero;
    final center = _camera.screenToWorld(_viewport.center(Offset.zero));
    return Offset(center.dx - 100, center.dy - 60);
  }

  Future<void> _addBlock() async {
    final entry = await showBlockPicker(context);
    if (entry == null || !mounted) return;
    final block = createBlockOfType(entry.name);
    final target = _insertionTarget();
    setState(() {
      final index = target.index.clamp(0, target.list.length);
      target.list.insert(index, block);
      if (identical(target.list, _blocks)) {
        // Новый корень встаёт под тем блоком, после которого его вставили:
        // бросок в центр экрана выглядел бы как «блок улетел».
        _origins[block.id] = _nextRootSpot(
          index > 0 ? _blocks[index - 1] : null,
        );
      }
      _selectedId = block.id;
      _relayout();
    });
    _markDirty();
    _scrollTo(block);
  }

  void _addEvent() {
    final block = EventBlock(eventType: EventType.onNodeEnter);
    setState(() {
      _blocks.add(block);
      _origins[block.id] = _nextRootSpot(
        _blocks.length > 1 ? _blocks[_blocks.length - 2] : null,
      );
      _selectedId = block.id;
      _relayout();
    });
    _markDirty();
    _scrollTo(block);
  }

  Future<void> _editBlock(VisualScriptBlock block) async {
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            BlockFactory(
              block: block,
              questId: widget.questId,
              onBlockDrop: (dropped, targetList) {
                setState(() {
                  removeBlockFromTree(dropped.id, _blocks);
                  _relayout();
                });
                _markDirty();
              },
              onMenuAction: (action) => _handleMenuAction(action, block),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(_relayout);
    _markDirty();
  }

  void _handleMenuAction(
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
          setState(() {
            loc.list.removeAt(loc.index);
            _origins.remove(block.id);
            _relayout();
          });
          _markDirty();
        }
        _showSnack(blockOperationToast(action, block), warning: true);
      case ScriptBlockMenuAction.duplicate:
        if (loc != null) {
          final copy = block.clone();
          setState(() {
            loc.list.insert(loc.index + 1, copy);
            if (identical(loc.list, _blocks)) {
              final rect = _blockRect(block);
              final origin = _origins[block.id];
              _origins[copy.id] = origin != null
                  ? origin + const Offset(24, 24)
                  : rect == null
                  ? _freeSpot()
                  : Offset(rect.left, rect.bottom + ScratchMetrics.rootGap);
            }
            _relayout();
          });
          _markDirty();
        }
      case ScriptBlockMenuAction.paste:
        _pasteAfter(block);
      case ScriptBlockMenuAction.delete:
        if (loc != null) {
          setState(() {
            loc.list.removeAt(loc.index);
            _origins.remove(block.id);
            if (_selectedId == block.id) _selectedId = null;
            _relayout();
          });
          _markDirty();
        }
    }
  }

  void _pasteAfter(VisualScriptBlock block) {
    final item = ref.read(visualScriptClipboardProvider);
    if (item == null) {
      _showSnack(tr('Буфер обмена пуст'), error: true);
      return;
    }
    final cloned = cloneBlocks(item.blocks);
    final loc = locateBlockInTree(block.id, _blocks);
    setState(() {
      if (loc != null) {
        loc.list.insertAll(loc.index + 1, cloned);
      } else {
        _blocks.addAll(cloned);
      }
      // Вставленные в корень блоки не должны валиться друг на друга в (0,0).
      if (loc == null || identical(loc.list, _blocks)) {
        final rect = _blockRect(block);
        var top = rect == null
            ? _freeSpot().dy
            : rect.bottom + ScratchMetrics.rootGap;
        final left = rect == null ? _freeSpot().dx : rect.left;
        for (final copy in cloned) {
          _origins[copy.id] = Offset(left, top);
          top += _engine.blockHeight(copy) + ScratchMetrics.rootGap;
        }
      }
      _relayout();
    });
    if (item.operation == 'cut') {
      ref.read(visualScriptClipboardProvider.notifier).state = null;
    }
    _markDirty();
  }

  void _toggleCollapsed(VisualScriptBlock block) {
    setState(() {
      scratchToggleCollapsed(block);
      _relayout();
    });
    _markDirty();
  }

  Future<void> _showBlockMenu(
    VisualScriptBlock block,
    Offset globalPosition,
  ) async {
    final action = await _showMenuAt(block, globalPosition);
    if (action != null) _handleMenuAction(action, block);
  }

  Future<ScriptBlockMenuAction?> _showMenuAt(
    VisualScriptBlock block,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return null;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    );
    return showMenu<ScriptBlockMenuAction>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: ScriptBlockMenuAction.copy,
          child: Text(tr('Копировать')),
        ),
        PopupMenuItem(
          value: ScriptBlockMenuAction.cut,
          child: Text(tr('Вырезать')),
        ),
        PopupMenuItem(
          value: ScriptBlockMenuAction.duplicate,
          child: Text(tr('Дублировать')),
        ),
        PopupMenuItem(
          value: ScriptBlockMenuAction.paste,
          child: Text(tr('Вставить после')),
        ),
        PopupMenuItem(
          value: ScriptBlockMenuAction.delete,
          child: Text(tr('Удалить')),
        ),
      ],
    );
  }

  Future<void> _renameScript() async {
    final controller = TextEditingController(text: _scriptName);
    final newName = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Переименовать скрипт')),
        content: TextField(
          controller: controller,
          autofocus: true,
          enableInteractiveSelection: true,
          decoration: InputDecoration(
            labelText: tr('Название'),
            border: const OutlineInputBorder(),
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
    if (newName == null || newName.isEmpty || !mounted) return;
    setState(() => _scriptName = newName);
    _markDirty();
  }

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

  // ── Сборка ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return EditorDocumentBackScope(
      onBackPressed: () async {
        await _closeDocument();
        return true;
      },
      child: Scaffold(
        backgroundColor: scheme.surfaceDim,
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
                  _scriptName.isEmpty ? tr('Скрипт') : _scriptName,
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
                onPressed: _isLoading ? null : _renameScript,
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: tr('Вписать в экран'),
              onPressed: _isLoading ? null : _fit,
              icon: const Icon(Icons.fit_screen_rounded),
            ),
            IconButton(
              tooltip: tr('Сохранить'),
              onPressed: _isLoading
                  ? null
                  : () async {
                      await _saveScript();
                      _showSnack(tr('Сохранено'), success: true);
                    },
              icon: const Icon(Icons.save_rounded),
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  Positioned.fill(child: _buildCanvas()),
                  if (_blocks.isEmpty) _buildEmptyState(),
                  Positioned(right: 12, top: 12, child: _buildZoomControls()),
                  Positioned(left: 12, top: 12, child: _buildHint()),
                  if (_selectedBlock != null)
                    Positioned(
                      left: 16,
                      bottom: 16,
                      right: 140,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: _buildSelectionBar(_selectedBlock!),
                      ),
                    ),
                ],
              ),
        floatingActionButton: _isLoading
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!_isConditionalScript)
                    FloatingActionButton.small(
                      heroTag: 'scratch-add-event',
                      onPressed: _addEvent,
                      tooltip: tr('Добавить событие'),
                      child: const Icon(Icons.flag_rounded),
                    ),
                  const SizedBox(height: 10),
                  FloatingActionButton.extended(
                    heroTag: 'scratch-add-block',
                    onPressed: _addBlock,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(tr('Блок')),
                    tooltip: tr('Добавить блок'),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            final factor = math.exp(-event.scrollDelta.dy / 420);
            _camera.zoomAt(_camera.scale * factor, event.localPosition);
          },
          onPointerDown: (event) => _pressLocal = event.localPosition,
          onPointerCancel: (_) {
            _pressLocal = null;
            if (_dragging) _abortDrag();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _handleTap,
            onDoubleTapDown: (details) {
              _doubleTapPosition = details.localPosition;
            },
            onDoubleTap: _handleDoubleTap,
            onSecondaryTapUp: _handleSecondaryTap,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: CustomPaint(
              painter: ScratchScriptPainter(
                layout: _layout,
                camera: _camera,
                cache: _paintCache,
                colorScheme: Theme.of(context).colorScheme,
                brightness: Theme.of(context).brightness,
                selectedId: _dragging ? null : _selectedId,
                dropLine: _dropLine,
                hiddenIds: _hiddenIds,
                ghostBlock: _dragging ? _dragBlock : null,
                ghostRect: _dragging && _dragBlock != null
                    ? Rect.fromLTWH(
                        _ghostTopLeft.dx,
                        _ghostTopLeft.dy,
                        _engine.blockWidth(_dragBlock!),
                        _engine.blockHeight(_dragBlock!),
                      )
                    : null,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_tree_rounded, size: 40, color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              tr('Скрипт пуст'),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              tr('Добавьте событие или блок, чтобы начать'),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _addEvent,
              icon: const Icon(Icons.flag_rounded),
              label: Text(tr('Добавить событие')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildZoomControls() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _roundButton(
          icon: Icons.add_rounded,
          tooltip: tr('Приблизить'),
          onPressed: () => _zoomBy(1.25),
        ),
        const SizedBox(height: 8),
        AnimatedBuilder(
          animation: _camera,
          builder: (context, _) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              '${(_camera.scale * 100).round()}%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _roundButton(
          icon: Icons.remove_rounded,
          tooltip: tr('Отдалить'),
          onPressed: () => _zoomBy(0.8),
        ),
      ],
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildHint() {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          tr(
            'Тяните блоки свободно · двойной тап — изменить · правый клик — меню',
          ),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildSelectionBar(VisualScriptBlock block) {
    final scheme = Theme.of(context).colorScheme;
    final collapsible = scratchIsCollapsible(block);
    return Card(
      elevation: 3,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: tr('Изменить'),
              onPressed: () => _editBlock(block),
              icon: const Icon(Icons.edit_rounded),
            ),
            if (collapsible)
              IconButton(
                tooltip: scratchIsCollapsed(block)
                    ? tr('Развернуть')
                    : tr('Свернуть'),
                onPressed: () => _toggleCollapsed(block),
                icon: Icon(
                  scratchIsCollapsed(block)
                      ? Icons.unfold_more_rounded
                      : Icons.unfold_less_rounded,
                ),
              ),
            IconButton(
              tooltip: tr('Дублировать'),
              onPressed: () =>
                  _handleMenuAction(ScriptBlockMenuAction.duplicate, block),
              icon: const Icon(Icons.copy_all_rounded),
            ),
            IconButton(
              tooltip: tr('Копировать'),
              onPressed: () =>
                  _handleMenuAction(ScriptBlockMenuAction.copy, block),
              icon: const Icon(Icons.copy_rounded),
            ),
            IconButton(
              tooltip: tr('Вырезать'),
              onPressed: () =>
                  _handleMenuAction(ScriptBlockMenuAction.cut, block),
              icon: const Icon(Icons.content_cut_rounded),
            ),
            IconButton(
              tooltip: tr('Вставить после'),
              onPressed: () =>
                  _handleMenuAction(ScriptBlockMenuAction.paste, block),
              icon: const Icon(Icons.content_paste_rounded),
            ),
            IconButton(
              tooltip: tr('Удалить'),
              onPressed: () =>
                  _handleMenuAction(ScriptBlockMenuAction.delete, block),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка, к которой прилипает перетаскиваемый блок.
class _SnapRow {
  const _SnapRow(this.row);
  final ScratchRow row;
}
