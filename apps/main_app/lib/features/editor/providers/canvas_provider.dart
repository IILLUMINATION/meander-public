import 'dart:collection';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:canvas_app/models/canvas_models.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/quest_content_change_bus.dart';
import 'package:canvas_app/features/editor/providers/tag_provider.dart'; // <--- ДОБАВЛЕН ЭТОТ ИМПОРТ
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_core/src/gen/api/canvas.dart' as rust_canvas;

// План 020-C4.3: чтение/запись квеста — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};
// ——— геометрия связей кэш (чтобы paint не считал lane/bezier каждый кадр)
// Лейн (смещение параллельных связей) запекается прямо в start/end, наружу
// отдаём только геометрии — отдельная карта lanes никому не нужна.
Map<String, ConnectionGeometry> _computeCanvasGeometries(
  List<Connection> connections,
  List<Node> nodes,
) {
  final grouped = <String, List<Connection>>{};
  for (final c in connections) {
    final key = '${c.fromNode.id}->${c.toNode.id}';
    grouped.putIfAbsent(key, () => []).add(c);
  }
  final lanes = <String, double>{};
  for (final entry in grouped.entries) {
    final g = [...entry.value]
      ..sort((a, b) {
        int order(ConnectionKind k) => k == ConnectionKind.content
            ? 0
            : k == ConnectionKind.script
            ? 1
            : 2;
        return order(a.kind).compareTo(order(b.kind));
      });
    final center = (g.length - 1) / 2;
    for (var i = 0; i < g.length; i++) {
      lanes['${g[i].fromNode.id}->${g[i].toNode.id}|${g[i].id}|${g[i].kind.name}'] =
          i - center;
    }
  }
  final geoms = <String, ConnectionGeometry>{};
  final nodeMap = {for (final n in nodes) n.id: n};
  for (final c in connections) {
    final from = nodeMap[c.fromNode.id];
    final to = nodeMap[c.toNode.id];
    if (from == null || to == null) continue;
    var start = from.getClosestAnchor(to.position);
    var end = to.getClosestAnchor(from.position);
    var fromCenter = from.position;
    var toCenter = to.position;
    final lane =
        lanes['${c.fromNode.id}->${c.toNode.id}|${c.id}|${c.kind.name}'] ?? 0;
    if (lane != 0) {
      final d = end - start;
      final len = d.distance;
      if (len != 0) {
        const spacing = 12.0;
        final n = Offset(-d.dy / len, d.dx / len);
        final shift = n * (lane * spacing);
        start += shift;
        end += shift;
        fromCenter += shift;
        toCenter += shift;
      }
    }
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    final off = math.min(dist * 0.5, 100.0);
    late final Offset c1, c2;
    if ((start.dx - fromCenter.dx).abs() > (start.dy - fromCenter.dy).abs()) {
      c1 = Offset(start.dx + (dx > 0 ? off : -off), start.dy);
    } else {
      c1 = Offset(start.dx, start.dy + (dy > 0 ? off : -off));
    }
    if ((end.dx - toCenter.dx).abs() > (end.dy - toCenter.dy).abs()) {
      c2 = Offset(end.dx - (dx > 0 ? off : -off), end.dy);
    } else {
      c2 = Offset(end.dx, end.dy - (dy > 0 ? off : -off));
    }
    final minX =
        [start.dx, end.dx, c1.dx, c2.dx].reduce((a, b) => a < b ? a : b) - 24;
    final maxX =
        [start.dx, end.dx, c1.dx, c2.dx].reduce((a, b) => a > b ? a : b) + 24;
    final minY =
        [start.dy, end.dy, c1.dy, c2.dy].reduce((a, b) => a < b ? a : b) - 24;
    final maxY =
        [start.dy, end.dy, c1.dy, c2.dy].reduce((a, b) => a > b ? a : b) + 24;
    geoms[c.id] = ConnectionGeometry(
      start: start,
      end: end,
      cp1: c1,
      cp2: c2,
      bounds: Rect.fromLTRB(minX, minY, maxX, maxY),
      lane: lane,
    );
  }
  return geoms;
}

@immutable
class CanvasState {
  final Offset offset;
  final double scale;
  final List<Node> nodes;
  final List<Connection> connections;
  final Map<String, ConnectionGeometry> connectionGeometries;
  final List<CanvasGroup> groups;
  final List<CanvasComment> comments;
  final Set<String> selectedNodeIds;
  final String? hoveredNodeId;
  final bool connectionMode;
  final bool selectionMode;
  final Rect? selectionRect;
  final String? connectionStartNodeId;
  final Offset? connectionPreviewEnd;
  final SpatialHash spatialHash;
  final bool isLoading;
  final String searchQuery;
  final Set<String> matchingNodeIds;
  final bool isSnapToGridEnabled;

  const CanvasState({
    this.offset = Offset.zero,
    this.scale = 1.0,
    this.nodes = const [],
    this.connections = const [],
    this.connectionGeometries = const {},
    this.groups = const [],
    this.comments = const [],
    this.selectedNodeIds = const {},
    this.hoveredNodeId,
    this.connectionMode = false,
    this.selectionMode = false,
    this.selectionRect,
    this.connectionStartNodeId,
    this.connectionPreviewEnd,
    required this.spatialHash,
    this.isLoading = true,
    this.searchQuery = '',
    this.matchingNodeIds = const {},
    this.isSnapToGridEnabled = false,
  });

  String? get selectedNodeId =>
      selectedNodeIds.isNotEmpty ? selectedNodeIds.first : null;

  CanvasState copyWith({
    Offset? offset,
    double? scale,
    List<Node>? nodes,
    List<Connection>? connections,
    Map<String, ConnectionGeometry>? connectionGeometries,
    List<CanvasGroup>? groups,
    List<CanvasComment>? comments,
    Set<String>? selectedNodeIds,
    bool clearSelection = false,
    String? hoveredNodeId,
    bool dehoverNode = false,
    bool? connectionMode,
    bool? selectionMode,
    Rect? selectionRect,
    bool clearSelectionRect = false,
    String? connectionStartNodeId,
    bool clearConnectionStart = false,
    Offset? connectionPreviewEnd,
    bool clearConnectionPreview = false,
    bool? isLoading,
    String? searchQuery,
    bool? isSnapToGridEnabled,
  }) {
    final newNodes = nodes ?? this.nodes;
    if (nodes != null) {
      spatialHash.rebuild(newNodes);
    }
    final newConns = connections ?? this.connections;
    final needGeom =
        (nodes != null || connections != null) && connectionGeometries == null;
    Map<String, ConnectionGeometry>? geom = connectionGeometries;
    if (needGeom) {
      geom = _computeCanvasGeometries(newConns, newNodes);
    }

    final newSearchQuery = searchQuery ?? this.searchQuery;
    Set<String> newMatching = matchingNodeIds;
    if (searchQuery != null || nodes != null) {
      if (newSearchQuery.isEmpty) {
        newMatching = const {};
      } else {
        final q = newSearchQuery.toLowerCase();
        newMatching = {};
        for (final n in newNodes) {
          if (n.label.toLowerCase().contains(q)) {
            newMatching.add(n.id);
          } else if (n.content != null &&
              n.content.toString().toLowerCase().contains(q)) {
            newMatching.add(n.id);
          }
        }
      }
    }

    return CanvasState(
      offset: offset ?? this.offset,
      scale: scale ?? this.scale,
      nodes: newNodes,
      connections: newConns,
      connectionGeometries: geom ?? this.connectionGeometries,
      groups: groups ?? this.groups,
      comments: comments ?? this.comments,
      selectedNodeIds: clearSelection
          ? {}
          : selectedNodeIds ?? this.selectedNodeIds,
      hoveredNodeId: dehoverNode ? null : hoveredNodeId ?? this.hoveredNodeId,
      connectionMode: connectionMode ?? this.connectionMode,
      selectionMode: selectionMode ?? this.selectionMode,
      selectionRect: clearSelectionRect
          ? null
          : selectionRect ?? this.selectionRect,
      connectionStartNodeId: clearConnectionStart
          ? null
          : connectionStartNodeId ?? this.connectionStartNodeId,
      connectionPreviewEnd: clearConnectionPreview
          ? null
          : connectionPreviewEnd ?? this.connectionPreviewEnd,
      spatialHash: spatialHash,
      isLoading: isLoading ?? this.isLoading,
      searchQuery: newSearchQuery,
      matchingNodeIds: newMatching,
      isSnapToGridEnabled: isSnapToGridEnabled ?? this.isSnapToGridEnabled,
    );
  }
}

class CanvasNotifier extends StateNotifier<CanvasState> {
  final Ref _ref;
  final String _questId;
  final String _tagId;
  Timer? _autoSaveDebounce;
  Timer? _cameraCommitTimer;
  Timer? _hoverDebounce;
  int _syncRevision = 0;
  void Function()? _contentChangeUnsub;
  static const double gridSize = 20.0;

  /// Camera decoupled from Riverpod — gestures update these notifiers
  /// at 60-120Hz without triggering `RebuildStormObserver`.
  final ValueNotifier<Offset> cameraOffset = ValueNotifier(Offset.zero);
  final ValueNotifier<double> cameraScale = ValueNotifier(1.0);

  CanvasNotifier(this._ref, this._questId, this._tagId)
    : super(CanvasState(spatialHash: SpatialHash())) {
    _contentChangeUnsub = QuestContentChangeBus.instance.listen(_questId, () {
      if (!mounted) return;
      _ref.invalidate(canvasIndexProvider(_questId));
    });
    _loadInitialData();
    _subscribeToNodeUpdates();
  }

  int get selectedNodeCount => state.selectedNodeIds.length;

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    _cameraCommitTimer?.cancel();
    _hoverDebounce?.cancel();
    _contentChangeUnsub?.call();
    cameraOffset.dispose();
    cameraScale.dispose();
    super.dispose();
  }

  // --- REACTIVITY IMPLEMENTATION ---
  void _subscribeToNodeUpdates() {
    _ref.listen<AsyncValue<List<SavedNode>>>(
      tagNodesProvider(TagNodesInfo(questId: _questId, tagId: _tagId)),
      (previous, next) {
        next.whenData((savedNodes) {
          // When provider updates (e.g. via invalidate), reload internal state
          _syncNodesFromProvider(savedNodes);
        });
      },
    );
  }

  Future<void> _syncNodesFromProvider(List<SavedNode> savedNodes) async {
    final currentRevision = ++_syncRevision;
    final sw = Stopwatch()..start();

    final index = await _ref.read(canvasIndexProvider(_questId).future);
    final config = await FileStorage.readJsonFile(QuestPaths.config(_questId));
    final startNodeId = config['startNodeId'] as String?;
    final connectionsJson = (config['connections'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    final nodes = savedNodes
        .map(
          (saved) => Node(
            id: saved.id,
            chapterId: saved.chapterId,
            position: Offset(saved.x, saved.y),
            color: saved.color != null
                ? Color(saved.color!)
                : const Color(0xFF232323),
            label: saved.title,
            description: saved.content['description'] as String? ?? '',
            content: saved.content,
            backgroundAssetId: saved.backgroundAssetId,
            backgroundAudioId: saved.backgroundAudioId,
            backgroundAudioVolume: saved.backgroundAudioVolume,
            scriptAssetId: saved.scriptAssetId,
            timerDuration: saved.timerDuration,
            defaultActionNodeId: saved.defaultActionNodeId,
            timerHidden: saved.timerHidden,
            isStartNode: saved.id == startNodeId,
          ),
        )
        .toList();

    final nodeMap = {for (final n in nodes) n.id: n};
    final connections = <Connection>[];
    final existingPairs = <String>{};

    void addConnection({
      required String? fromId,
      required String? toId,
      required String kind,
      String? id,
    }) {
      if (fromId == null || toId == null) return;
      final fromNode = nodeMap[fromId];
      final toNode = nodeMap[toId];
      if (fromNode == null || toNode == null) return;
      final pair = '$fromId->$toId';
      if (!existingPairs.add(pair)) return;
      final kindEnum = kind == 'timer'
          ? ConnectionKind.timer
          : kind == 'script'
          ? ConnectionKind.script
          : ConnectionKind.content;
      connections.add(
        Connection(
          id: id ?? const Uuid().v4(),
          fromNode: fromNode,
          toNode: toNode,
          color: kindEnum == ConnectionKind.timer
              ? CanvasTheme.connectionTimer.withOpacity(0.7)
              : kindEnum == ConnectionKind.script
              ? CanvasTheme.connectionScript.withOpacity(0.85)
              : CanvasTheme.connectionContent,
          isVirtual: kindEnum != ConnectionKind.content,
          kind: kindEnum,
        ),
      );
    }

    // index.json уже содержит рёбра content/timer, посчитанные при
    // миграции/сохранении ноды. Тела нод для отрисовки не нужны.
    for (final raw in (index['edges'] as List<dynamic>? ?? [])) {
      if (raw is! Map) continue;
      addConnection(
        fromId: raw['from']?.toString(),
        toId: raw['to']?.toString(),
        kind: raw['kind']?.toString() ?? 'content',
      );
    }

    for (final connJson in connectionsJson) {
      addConnection(
        fromId: connJson['fromId']?.toString(),
        toId: connJson['toId']?.toString(),
        kind: 'content',
        id: connJson['id']?.toString(),
      );
    }

    // Страховка для старых индексов без timer-рёбер.
    for (final node in nodes) {
      final target = node.defaultActionNodeId;
      if (target == null) continue;
      addConnection(
        fromId: node.id,
        toId: target,
        kind: 'timer',
        id: 'timer_${node.id}_$target',
      );
    }

    if (mounted) {
      state = state.copyWith(nodes: nodes, connections: connections);
    }
    sw.stop();
    print(
      '[Perf][Canvas] Index sync for quest=$_questId tag=$_tagId: '
      '${nodes.length} nodes, ${connections.length} connections '
      'in ${sw.elapsedMilliseconds}ms',
    );

    // Скриптовые рёбра требуют тел нод; грузим их только фоном и только
    // если у нод вообще есть ссылки на скрипты.
    if (nodes.any((n) => (n.scriptAssetId ?? '').isNotEmpty)) {
      unawaited(
        _loadScriptConnectionsInBackground(
          revision: currentRevision,
          nodes: nodes,
          nodeMap: nodeMap,
          baseConnections: connections,
        ),
      );
    }
  }

  Future<void> _loadScriptConnectionsInBackground({
    required int revision,
    required List<Node> nodes,
    required Map<String, Node> nodeMap,
    required List<Connection> baseConnections,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final scriptConnections = await _collectScriptConnections(
        nodes: nodes,
        nodeMap: nodeMap,
      );
      if (!mounted || revision != _syncRevision) return;

      state = state.copyWith(
        connections: [...baseConnections, ...scriptConnections],
      );
      sw.stop();
      print(
        '[Perf][Canvas] Script connections for quest=$_questId tag=$_tagId: '
        '${scriptConnections.length} added in ${sw.elapsedMilliseconds}ms',
      );
    } catch (e, stack) {
      sw.stop();
      print(
        '❌ [CanvasNotifier] Script connection scan error: $e '
        '(after ${sw.elapsedMilliseconds}ms)\n$stack',
      );
    }
  }

  Future<List<Connection>> _collectScriptConnections({
    required List<Node> nodes,
    required Map<String, Node> nodeMap,
  }) async {
    final scriptTargetsCache = <String, Set<String>>{};
    final resolvedScriptCache = <String, String?>{};
    final recursionGuard = <String>{};
    final addedPairs = <String>{};
    final result = <Connection>[];

    for (final sourceNode in nodes) {
      final scriptRefs = _collectNodeScriptReferences(sourceNode.content);
      final nodeScriptRef = sourceNode.scriptAssetId?.trim();
      if (nodeScriptRef != null && nodeScriptRef.isNotEmpty) {
        scriptRefs.add(nodeScriptRef);
      }
      if (scriptRefs.isEmpty) continue;

      final targetIds = <String>{};
      for (final rawRef in scriptRefs) {
        final scriptPath = await _resolveScriptPathFromReference(
          rawRef,
          resolvedScriptCache,
        );
        if (scriptPath == null) continue;
        targetIds.addAll(
          await _collectTargetNodeIdsFromScript(
            scriptPath: scriptPath,
            scriptTargetsCache: scriptTargetsCache,
            resolvedScriptCache: resolvedScriptCache,
            recursionGuard: recursionGuard,
          ),
        );
      }

      for (final targetId in targetIds) {
        if (targetId == sourceNode.id) continue;
        final targetNode = nodeMap[targetId];
        if (targetNode == null) continue;

        final pairKey = '${sourceNode.id}->${targetNode.id}';
        if (!addedPairs.add(pairKey)) continue;

        result.add(
          Connection(
            id: 'script_${sourceNode.id}_${targetNode.id}',
            fromNode: sourceNode,
            toNode: targetNode,
            color: CanvasTheme.connectionScript.withOpacity(0.85),
            isVirtual: true,
            kind: ConnectionKind.script,
          ),
        );
      }
    }

    return result;
  }

  Set<String> _collectNodeScriptReferences(Map<String, dynamic>? content) {
    final refs = <String>{};
    final items = content?['items'];
    if (items is! List) return refs;

    void walk(dynamic rawItem) {
      if (rawItem is! Map) return;
      final item = <String, dynamic>{};
      rawItem.forEach((key, value) {
        item[key.toString()] = value;
      });

      if (item['type']?.toString() == 'script') {
        final resourcePath = item['resourcePath']?.toString().trim();
        if (resourcePath != null && resourcePath.isNotEmpty) {
          refs.add(resourcePath);
        }
      }

      final scriptTriggers = item['scriptTriggers'];
      if (scriptTriggers is Map) {
        scriptTriggers.forEach((_, value) {
          final triggerPath = value?.toString().trim();
          if (triggerPath != null && triggerPath.isNotEmpty) {
            refs.add(triggerPath);
          }
        });
      }

      final children = item['children'];
      if (children is List) {
        for (final child in children) {
          walk(child);
        }
      }
    }

    for (final item in items) {
      walk(item);
    }
    return refs;
  }

  String? _stripQuestPrefix(String value) {
    final normalized = value.replaceAll('\\', '/');
    final prefix = '${QuestPaths.questRoot(_questId)}/';
    if (!normalized.startsWith(prefix)) return null;
    return normalized.substring(prefix.length);
  }

  Future<String?> _resolveScriptPathFromReference(
    String rawReference,
    Map<String, String?> resolvedScriptCache,
  ) async {
    final cacheKey = rawReference.trim().replaceAll('\\', '/');
    if (cacheKey.isEmpty) return null;
    if (resolvedScriptCache.containsKey(cacheKey)) {
      return resolvedScriptCache[cacheKey];
    }

    final stripped = QuestPaths.isQuestPath(cacheKey)
        ? _stripQuestPrefix(cacheKey)
        : cacheKey;
    if (stripped == null || stripped.isEmpty) {
      resolvedScriptCache[cacheKey] = null;
      return null;
    }

    final normalized = stripped.replaceFirst(RegExp(r'^/+'), '');
    final candidates = <String>{};

    void addCandidate(String value) {
      final candidate = value
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^/+'), '')
          .trim();
      if (candidate.isNotEmpty) {
        candidates.add(candidate);
      }
    }

    addCandidate(normalized);
    if (normalized.startsWith('scripts/') ||
        normalized.startsWith('_internal_scripts/')) {
      if (!normalized.endsWith('.json')) {
        addCandidate('$normalized.json');
      }
    } else if (normalized.endsWith('.json')) {
      addCandidate('scripts/$normalized');
      addCandidate('_internal_scripts/$normalized');
    } else {
      addCandidate('scripts/$normalized.json');
      addCandidate('_internal_scripts/$normalized.json');
      addCandidate('scripts/$normalized');
      addCandidate('_internal_scripts/$normalized');
    }

    for (final candidate in candidates) {
      final fullPath = QuestPaths.questFile(_questId, candidate);
      if (await (await _qs()).exists(fullPath)) {
        resolvedScriptCache[cacheKey] = candidate;
        return candidate;
      }
    }

    resolvedScriptCache[cacheKey] = null;
    return null;
  }

  Future<Set<String>> _collectTargetNodeIdsFromScript({
    required String scriptPath,
    required Map<String, Set<String>> scriptTargetsCache,
    required Map<String, String?> resolvedScriptCache,
    required Set<String> recursionGuard,
  }) async {
    if (scriptTargetsCache.containsKey(scriptPath)) {
      return scriptTargetsCache[scriptPath]!;
    }
    if (recursionGuard.contains(scriptPath)) {
      return const <String>{};
    }

    recursionGuard.add(scriptPath);
    final targets = <String>{};
    try {
      final fullPath = QuestPaths.questFile(_questId, scriptPath);
      if (!await (await _qs()).exists(fullPath) || fullPath.endsWith('.lua')) {
        scriptTargetsCache[scriptPath] = targets;
        return targets;
      }

      final scriptData = await _readMap(fullPath);
      final blocks = scriptData['blocks'];
      if (blocks is List) {
        targets.addAll(
          await _collectTargetNodeIdsFromBlocks(
            blocks: blocks,
            scriptTargetsCache: scriptTargetsCache,
            resolvedScriptCache: resolvedScriptCache,
            recursionGuard: recursionGuard,
          ),
        );
      }
      scriptTargetsCache[scriptPath] = targets;
      return targets;
    } catch (_) {
      scriptTargetsCache[scriptPath] = targets;
      return targets;
    } finally {
      recursionGuard.remove(scriptPath);
    }
  }

  Future<Set<String>> _collectTargetNodeIdsFromBlocks({
    required List<dynamic> blocks,
    required Map<String, Set<String>> scriptTargetsCache,
    required Map<String, String?> resolvedScriptCache,
    required Set<String> recursionGuard,
  }) async {
    final targets = <String>{};

    for (final rawBlock in blocks) {
      if (rawBlock is! Map) continue;

      final block = <String, dynamic>{};
      rawBlock.forEach((key, value) {
        block[key.toString()] = value;
      });

      final type = block['type']?.toString();
      if (type == 'go_to_node') {
        final targetNodeId = block['node_id']?.toString().trim();
        if (_isStaticNodeReference(targetNodeId)) {
          targets.add(targetNodeId!);
        }
      } else if (type == 'call_script') {
        final nestedScriptRef = block['script_id']?.toString().trim();
        if (nestedScriptRef != null && nestedScriptRef.isNotEmpty) {
          final nestedScriptPath = await _resolveScriptPathFromReference(
            nestedScriptRef,
            resolvedScriptCache,
          );
          if (nestedScriptPath != null) {
            targets.addAll(
              await _collectTargetNodeIdsFromScript(
                scriptPath: nestedScriptPath,
                scriptTargetsCache: scriptTargetsCache,
                resolvedScriptCache: resolvedScriptCache,
                recursionGuard: recursionGuard,
              ),
            );
          }
        }
      }

      for (final key in const ['children', 'then_blocks', 'else_blocks']) {
        final nested = block[key];
        if (nested is! List) continue;
        targets.addAll(
          await _collectTargetNodeIdsFromBlocks(
            blocks: nested,
            scriptTargetsCache: scriptTargetsCache,
            resolvedScriptCache: resolvedScriptCache,
            recursionGuard: recursionGuard,
          ),
        );
      }
    }

    return targets;
  }

  bool _isStaticNodeReference(String? value) {
    if (value == null) return false;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('=')) return false;
    if (trimmed.contains('{') || trimmed.contains('}')) return false;
    return true;
  }

  Future<void> _loadInitialData() async {
    if (mounted) state = state.copyWith(isLoading: true);
    await _loadCanvasData();
  }

  Future<void> _loadCanvasData() async {
    final sw = Stopwatch()..start();
    try {
      final savedNodes = await _ref.read(
        tagNodesProvider(TagNodesInfo(questId: _questId, tagId: _tagId)).future,
      );

      final extraData = await _ref.read(
        canvasExtraDataProvider(_questId).future,
      );

      final groupsList = (extraData['groups'] as List)
          .map((g) => CanvasGroup.fromJson(g))
          .where((g) => g.chapterId == _tagId)
          .toList();

      final commentsList = (extraData['comments'] as List)
          .map((c) => CanvasComment.fromJson(c))
          .where((c) => c.chapterId == _tagId)
          .toList();

      // Use common sync method
      await _syncNodesFromProvider(savedNodes);

      final cameraState = await _ref.read(
        tagCameraStateProvider(
          TagNodesInfo(questId: _questId, tagId: _tagId),
        ).future,
      );

      if (mounted) {
        final camOffset = Offset(cameraState.offsetX, cameraState.offsetY);
        final camScale = cameraState.scale;
        cameraOffset.value = camOffset;
        cameraScale.value = camScale;
        state = state.copyWith(
          groups: groupsList,
          comments: commentsList,
          offset: camOffset,
          scale: camScale,
          isLoading: false,
        );
      }
      sw.stop();
      print(
        '[Perf][Canvas] _loadCanvasData completed for quest=$_questId tag=$_tagId '
        'in ${sw.elapsedMilliseconds}ms',
      );
    } catch (e, stack) {
      print('❌ [CanvasNotifier] Error: $e\n$stack');
      if (mounted) {
        state = state.copyWith(isLoading: false);
      }
      sw.stop();
      print(
        '❌ [CanvasNotifier] _loadCanvasData failed after '
        '${sw.elapsedMilliseconds}ms',
      );
    }
  }

  void selectNode(String? nodeId) {
    if (nodeId == null) {
      state = state.copyWith(clearSelection: true);
    } else {
      state = state.copyWith(selectedNodeIds: {nodeId});
    }
  }

  void startBoxSelection(Offset startPos) {
    state = state.copyWith(
      selectionMode: true,
      selectionRect: Rect.fromPoints(startPos, startPos),
      clearSelection: true,
    );
  }

  void updateBoxSelection(Offset currentPos) {
    if (state.selectionRect != null) {
      final start = state.selectionRect!.topLeft;
      state = state.copyWith(selectionRect: Rect.fromPoints(start, currentPos));
    }
  }

  void endBoxSelection() {
    if (state.selectionRect != null) {
      final worldRect = Rect.fromPoints(
        screenToWorld(state.selectionRect!.topLeft),
        screenToWorld(state.selectionRect!.bottomRight),
      );

      final selectedIds = <String>{};
      for (final node in state.nodes) {
        if (worldRect.overlaps(node.rect)) {
          selectedIds.add(node.id);
        }
      }
      state = state.copyWith(
        selectedNodeIds: selectedIds,
        clearSelectionRect: true,
        selectionMode: false,
      );
    }
  }

  void toggleSelectionMode() {
    state = state.copyWith(selectionMode: !state.selectionMode);
  }

  void selectSubtree(String rootNodeId) {
    final visited = <String>{};
    final queue = Queue<String>()..add(rootNodeId);
    final selectedIds = <String>{};
    final adjacency = <String, List<String>>{};
    for (final conn in state.connections) {
      adjacency.putIfAbsent(conn.fromNode.id, () => []).add(conn.toNode.id);
    }
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      if (visited.contains(current)) continue;
      visited.add(current);
      selectedIds.add(current);
      final neighbors = adjacency[current];
      if (neighbors != null) {
        for (final neighbor in neighbors) {
          if (!visited.contains(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
    }
    state = state.copyWith(selectedNodeIds: selectedIds);
  }

  void addGroup({String? label, Color color = Colors.blue, Offset? position}) {
    Rect groupRect;
    if (state.selectedNodeIds.isNotEmpty) {
      double minX = double.infinity, minY = double.infinity;
      double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

      for (final id in state.selectedNodeIds) {
        final node = state.nodes.firstWhereOrNull((n) => n.id == id);
        if (node != null) {
          if (node.rect.left < minX) minX = node.rect.left;
          if (node.rect.top < minY) minY = node.rect.top;
          if (node.rect.right > maxX) maxX = node.rect.right;
          if (node.rect.bottom > maxY) maxY = node.rect.bottom;
        }
      }
      groupRect = Rect.fromLTRB(minX - 50, minY - 80, maxX + 50, maxY + 50);
    } else {
      final center = position ?? screenToWorld(const Offset(200, 300));
      groupRect = Rect.fromCenter(center: center, width: 400, height: 300);
    }

    final newGroup = CanvasGroup(
      id: const Uuid().v4(),
      chapterId: _tagId,
      label: label ?? tr('Новая группа'),
      rect: groupRect,
      color: color.withOpacity(0.2),
    );

    state = state.copyWith(groups: [...state.groups, newGroup]);
    _debounceAndSave();
  }

  void updateGroup(String id, {String? label, Color? color}) {
    final newGroups = state.groups.map((g) {
      if (g.id == id) {
        return g.copyWith(label: label, color: color?.withOpacity(0.2));
      }
      return g;
    }).toList();
    state = state.copyWith(groups: newGroups);
    _debounceAndSave();
  }

  void resizeGroup(String id, Rect newRect) {
    final newGroups = state.groups.map((g) {
      if (g.id == id) return g.copyWith(rect: newRect);
      return g;
    }).toList();
    state = state.copyWith(groups: newGroups);
    _debounceAndSave();
  }

  void moveGroup(String groupId, Offset delta) {
    final group = state.groups.firstWhereOrNull((g) => g.id == groupId);
    if (group == null) return;

    final newGroups = state.groups.map((g) {
      if (g.id == groupId || group.rect.contains(g.rect.center)) {
        return g.copyWith(rect: g.rect.shift(delta));
      }
      return g;
    }).toList();

    final newNodes = state.nodes.map((node) {
      if (group.rect.contains(node.rect.center)) {
        return node.copyWith(position: node.position + delta);
      }
      return node;
    }).toList();

    final newComments = state.comments.map((comment) {
      if (group.rect.contains(comment.rect.center)) {
        return comment.copyWith(position: comment.position + delta);
      }
      return comment;
    }).toList();

    final newConnections = _rebuildConnections(state.connections, newNodes);

    state = state.copyWith(
      groups: newGroups,
      nodes: newNodes,
      comments: newComments,
      connections: newConnections,
    );
    _debounceAndSave();
  }

  void deleteGroup(String id) {
    final newGroups = state.groups.where((g) => g.id != id).toList();
    state = state.copyWith(groups: newGroups);
    _debounceAndSave();
  }

  void addComment(Offset position) {
    final comment = CanvasComment(
      id: const Uuid().v4(),
      chapterId: _tagId,
      text: tr('Заметка...'),
      position: position,
    );
    state = state.copyWith(comments: [...state.comments, comment]);
    _debounceAndSave();
  }

  void updateComment(String id, String text) {
    final newComments = state.comments.map((c) {
      if (c.id == id) return c.copyWith(text: text);
      return c;
    }).toList();
    state = state.copyWith(comments: newComments);
    _debounceAndSave();
  }

  void moveComment(String id, Offset delta) {
    final newComments = state.comments.map((c) {
      if (c.id == id) return c.copyWith(position: c.position + delta);
      return c;
    }).toList();
    state = state.copyWith(comments: newComments);
    _debounceAndSave();
  }

  void resizeComment(String id, Size newSize) {
    final newComments = state.comments.map((c) {
      if (c.id == id) return c.copyWith(size: newSize);
      return c;
    }).toList();
    state = state.copyWith(comments: newComments);
    _debounceAndSave();
  }

  void deleteComment(String id) {
    final newComments = state.comments.where((c) => c.id != id).toList();
    state = state.copyWith(comments: newComments);
    _debounceAndSave();
  }

  void moveSelectedNodes(Offset delta) {
    final newNodes = state.nodes.map((node) {
      if (state.selectedNodeIds.contains(node.id)) {
        Offset newPosition = node.position + delta;
        if (state.isSnapToGridEnabled) {
          newPosition = Offset(
            (newPosition.dx / gridSize).round() * gridSize,
            (newPosition.dy / gridSize).round() * gridSize,
          );
        }
        return node.copyWith(position: newPosition);
      }
      return node;
    }).toList();

    final newConnections = _rebuildConnections(state.connections, newNodes);
    state = state.copyWith(nodes: newNodes, connections: newConnections);
    _debounceAndSave();
  }

  Future<void> saveCamera() async {
    try {
      // Prevent delayed stale snapshot from overwriting fresher node edits.
      _autoSaveDebounce?.cancel();
      // Use decoupled notifier values (fresh) instead of possibly stale state
      final camOff = cameraOffset.value;
      final camSc = cameraScale.value;
      // Keep state in sync for persistence consumers
      if (state.offset != camOff || state.scale != camSc) {
        state = state.copyWith(offset: camOff, scale: camSc);
      }
      await saveTagCameraState(
        _questId,
        _tagId,
        CameraState(offsetX: camOff.dx, offsetY: camOff.dy, scale: camSc),
      );

      // IMPORTANT: keep latest persisted node content/title to avoid overwriting
      // fresh edits done in NodeContentScreen while canvas autosave is running.
      final persistedById = await _persistedNodesById();
      final nodesToSave = _chapterSnapshotToSave(state.nodes, persistedById);

      await saveCanvasData(
        _questId,
        nodes: nodesToSave,
        chapterId: _tagId,
        groups: state.groups,
        comments: state.comments,
      );
    } catch (e) {
      // Ignore
    }
  }

  void _debounceAndSave() {
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 1500), saveCamera);
  }

  Future<Map<String, SavedNode>> _persistedNodesById() async {
    try {
      final latest = await _ref.read(allQuestNodesProvider(_questId).future);
      return {for (final node in latest) node.id: node};
    } catch (_) {
      return const {};
    }
  }

  /// Снимок нод главы для перезаписи на диск. Контент, заголовок и поля
  /// берём из свежего прочитанного состояния: кэш канваса отстаёт от
  /// редактора ноды, и без этого любое добавление ноды откатывает правки
  /// соседней. Позиция и цвет — канвасовые, их меняет только канвас.
  List<SavedNode> _chapterSnapshotToSave(
    List<Node> nodes,
    Map<String, SavedNode> persistedById,
  ) {
    return nodes.map((n) {
      final persisted = persistedById[n.id];
      if (persisted != null) {
        // Канвас владеет только геометрией и цветом — всё остальное берём
        // из записанной ноды целиком. Перечисление полей вручную теряло
        // каждое новое поле модели, а saveNodes вычищает отсутствующий ключ
        // из файла: так с экрана стирался видео-фон и прочие настройки ноды.
        return persisted.copyWith(
          chapterId: n.chapterId ?? _tagId,
          x: n.position.dx,
          y: n.position.dy,
          color: n.color.value,
        );
      }
      return _nodeFromCanvas(n);
    }).toList();
  }

  /// Нода, у которой нет записи на диске (только что создана на канвасе):
  /// собираем из канвасового объекта.
  SavedNode _nodeFromCanvas(Node n) {
    return SavedNode(
      id: n.id,
      chapterId: n.chapterId ?? _tagId,
      title: n.label,
      content: n.content ?? const {'items': []},
      x: n.position.dx,
      y: n.position.dy,
      color: n.color.value,
      backgroundAssetId: n.backgroundAssetId,
      backgroundAudioId: n.backgroundAudioId,
      backgroundAudioVolume: n.backgroundAudioVolume,
      scriptAssetId: n.scriptAssetId,
      timerDuration: n.timerDuration,
      timerHidden: n.timerHidden,
      defaultActionNodeId: n.defaultActionNodeId,
    );
  }

  List<Connection> _rebuildConnections(List<Connection> old, List<Node> newN) {
    final m = {for (var n in newN) n.id: n};
    final res = <Connection>[];
    for (var c in old) {
      final f = m[c.fromNode.id];
      final t = m[c.toNode.id];
      if (f != null && t != null) {
        res.add(
          Connection(
            id: c.id,
            fromNode: f,
            toNode: t,
            color: c.color,
            isVirtual: c.isVirtual,
            kind: c.kind,
          ),
        );
      }
    }
    return res;
  }

  Future<void> tidyUpLayout() async {
    if (state.nodes.isEmpty) return;
    try {
      final nodesJson = jsonEncode(
        state.nodes
            .map(
              (n) => {
                'id': n.id,
                'x': n.position.dx,
                'y': n.position.dy,
                'w': n.size.width,
                'h': n.size.height,
              },
            )
            .toList(),
      );
      final connsJson = jsonEncode(
        state.connections
            .where((c) => !c.isVirtual)
            .map((c) => {'fromId': c.fromNode.id, 'toId': c.toNode.id})
            .toList(),
      );
      final resJson = await rust_canvas.canvasTidyLayout(
        nodesJson: nodesJson,
        connectionsJson: connsJson,
      );
      final res = (jsonDecode(resJson) as List).cast<Map<String, dynamic>>();
      final posMap = {
        for (final e in res)
          e['id'] as String: Offset(
            (e['x'] as num).toDouble(),
            (e['y'] as num).toDouble(),
          ),
      };
      final newNodes = state.nodes
          .map(
            (n) => posMap.containsKey(n.id)
                ? n.copyWith(position: posMap[n.id]!)
                : n,
          )
          .toList();
      state = state.copyWith(
        nodes: newNodes,
        connections: _rebuildConnections(state.connections, newNodes),
      );
    } catch (_) {
      // Fallback Dart
      final nodes = state.nodes;
      final connections = state.connections;
      final graph = _buildGraph(nodes, connections);
      _removeCycles(graph);
      final layers = _assignLayers(graph, nodes);
      _reduceCrossings(layers, graph);
      final newNodes = _assignCoordinates(layers, nodes);
      state = state.copyWith(
        nodes: newNodes,
        connections: _rebuildConnections(state.connections, newNodes),
      );
    }
    _debounceAndSave();
  }

  Future<void> addNode(Size screenSize) async {
    try {
      _autoSaveDebounce?.cancel();

      Offset centerScreen = screenSize.center(Offset.zero);
      if (state.nodes.isEmpty && cameraOffset.value == Offset.zero) {
        cameraOffset.value = centerScreen;
        state = state.copyWith(offset: centerScreen);
      }
      await saveCamera();

      Offset finalPosition = screenToWorld(centerScreen);
      if (state.isSnapToGridEnabled) {
        finalPosition = Offset(
          (finalPosition.dx / gridSize).round() * gridSize,
          (finalPosition.dy / gridSize).round() * gridSize,
        );
      }
      const nodeSize = Size(150, 150);
      const offsetStep = 30.0;
      bool overlaps;
      int attempts = 0;
      do {
        overlaps = false;
        Rect newNodeRect = Rect.fromCenter(
          center: finalPosition,
          width: nodeSize.width,
          height: nodeSize.height,
        );
        for (final existingNode in state.nodes) {
          if (existingNode.rect.overlaps(newNodeRect)) {
            overlaps = true;
            finalPosition = Offset(
              finalPosition.dx + offsetStep,
              finalPosition.dy + offsetStep,
            );
            break;
          }
        }
        attempts++;
      } while (overlaps && attempts < 10);
      final baseTitle = tr('Новая нода');
      String defaultTitle = baseTitle;
      final normalizedTitles = state.nodes
          .map((n) => n.label.trim().toLowerCase())
          .toSet();
      if (normalizedTitles.contains(baseTitle.toLowerCase())) {
        int i = 2;
        String numbered(int n) => trf('Новая нода {p0}', {'p0': n});
        while (normalizedTitles.contains(numbered(i).toLowerCase())) {
          i++;
        }
        defaultTitle = numbered(i);
      }

      final newSavedNode = createNewNode(
        chapterId: _tagId,
        title: defaultTitle,
        x: finalPosition.dx,
        y: finalPosition.dy,
      );

      final configPath = QuestPaths.config(_questId);
      final config = await _readMap(configPath);
      final currentStartNode = config['startNodeId'] as String?;
      bool isNowStartNode = false;
      final allNodes = await _ref.read(allQuestNodesProvider(_questId).future);
      if (allNodes.isEmpty &&
          (currentStartNode == null || currentStartNode.isEmpty)) {
        config['startNodeId'] = newSavedNode.id;
        await (await _qs()).writeJson(configPath, config);
        isNowStartNode = true;
        _ref.invalidate(questProvider(_questId));
      }

      final newNode = Node(
        id: newSavedNode.id,
        chapterId: newSavedNode.chapterId,
        position: Offset(newSavedNode.x, newSavedNode.y),
        color: newSavedNode.color != null
            ? Color(newSavedNode.color!)
            : const Color(0xFF232323),
        label: newSavedNode.title,
        description: '',
        content: newSavedNode.content,
        backgroundAudioId: newSavedNode.backgroundAudioId,
        backgroundAudioVolume: newSavedNode.backgroundAudioVolume,
        timerDuration: newSavedNode.timerDuration,
        defaultActionNodeId: newSavedNode.defaultActionNodeId,
        timerHidden: newSavedNode.timerHidden,
        isStartNode: isNowStartNode,
      );
      final updatedNodes = [...state.nodes, newNode];
      state = state.copyWith(nodes: updatedNodes);

      final nodesToSave = _chapterSnapshotToSave(
        updatedNodes,
        await _persistedNodesById(),
      );

      await saveCanvasData(
        _questId,
        nodes: nodesToSave,
        chapterId: _tagId,
        groups: state.groups,
        comments: state.comments,
      );

      _ref.invalidate(allQuestNodesProvider(_questId));
    } catch (e, stack) {
      print('❌ [CanvasNotifier] AddNode Error: $e\n$stack');
    }
  }

  /// Добавляет одну из 3-х предзаготовленных нод обучения.
  /// [index]: 0 — стартовая (центр-вверх), 1 — «Лес» (низ-слева),
  /// 2 — «Мост» (низ-справа). Каждая нода уже содержит подготовленный
  /// текст-контент, чтобы пользователь увидел заполненную развилку.
  Future<void> addTutorialNode(int index, Size screenSize) async {
    try {
      _autoSaveDebounce?.cancel();

      Offset centerScreen = screenSize.center(Offset.zero);
      if (state.nodes.isEmpty && cameraOffset.value == Offset.zero) {
        cameraOffset.value = centerScreen;
        state = state.copyWith(offset: centerScreen);
      }
      await saveCamera();

      Offset center = screenToWorld(centerScreen);
      if (state.isSnapToGridEnabled) {
        center = Offset(
          (center.dx / gridSize).round() * gridSize,
          (center.dy / gridSize).round() * gridSize,
        );
      }

      const dx = 220.0;
      const dy = 220.0;
      late final Offset position;
      late final String title;
      late final String text;
      late final Color color;
      switch (index) {
        case 0:
          position = Offset(center.dx, center.dy - dy / 2);
          title = tr('Начало');
          text = tr(
            'Ты стоишь на перепутье. Слева — тёмный лес, справа — мост через реку. Куда пойдёшь?',
          );
          color = const Color(0xFF2D5A3D);
          break;
        case 1:
          position = Offset(center.dx - dx, center.dy + dy / 2);
          title = tr('Лес');
          text = tr('Ты идёшь в тёмный лес. Здесь продолжится история…');
          color = const Color(0xFF3D2D5A);
          break;
        case 2:
        default:
          position = Offset(center.dx + dx, center.dy + dy / 2);
          title = tr('Мост');
          text = tr('Ты идёшь к мосту через реку. Здесь продолжится история…');
          color = const Color(0xFF5A3D2D);
          break;
      }

      final content = <String, dynamic>{
        'items': [
          {
            'id': const Uuid().v4(),
            'type': 'text',
            'text': text,
            'flex': 1,
            'crossAxisAlignment': 'center',
            'isHidden': false,
          },
        ],
      };

      final saved = createNewNode(
        chapterId: _tagId,
        title: title,
        x: position.dx,
        y: position.dy,
        content: content,
      );

      // Если это первая нода в квесте — делаем её стартовой.
      final configPath = QuestPaths.config(_questId);
      final config = await _readMap(configPath);
      final currentStartNode = config['startNodeId'] as String?;
      bool isStart = false;
      final allNodes = await _ref.read(allQuestNodesProvider(_questId).future);
      if (allNodes.isEmpty &&
          (currentStartNode == null || currentStartNode.isEmpty)) {
        config['startNodeId'] = saved.id;
        await (await _qs()).writeJson(configPath, config);
        isStart = true;
        _ref.invalidate(questProvider(_questId));
      }

      final node = Node(
        id: saved.id,
        chapterId: saved.chapterId,
        position: Offset(saved.x, saved.y),
        color: color,
        label: saved.title,
        description: '',
        content: saved.content,
        backgroundAudioId: saved.backgroundAudioId,
        backgroundAudioVolume: saved.backgroundAudioVolume,
        timerDuration: saved.timerDuration,
        timerHidden: saved.timerHidden,
        defaultActionNodeId: saved.defaultActionNodeId,
        isStartNode: isStart,
      );

      final updatedNodes = [...state.nodes, node];
      state = state.copyWith(nodes: updatedNodes);

      final nodesToSave = _chapterSnapshotToSave(
        updatedNodes,
        await _persistedNodesById(),
      );

      await saveCanvasData(
        _questId,
        nodes: nodesToSave,
        chapterId: _tagId,
        groups: state.groups,
        comments: state.comments,
      );

      _ref.invalidate(allQuestNodesProvider(_questId));
    } catch (e, stack) {
      print('❌ [CanvasNotifier] AddTutorialNode Error: $e\n$stack');
    }
  }

  void toggleSnapToGrid() {
    state = state.copyWith(isSnapToGridEnabled: !state.isSnapToGridEnabled);
  }

  void updateNodeColor(Color color) {
    if (state.selectedNodeIds.isEmpty) return;

    final newNodes = state.nodes.map((node) {
      if (state.selectedNodeIds.contains(node.id)) {
        return node.copyWith(color: color);
      }
      return node;
    }).toList();

    final newConnections = _rebuildConnections(state.connections, newNodes);
    state = state.copyWith(nodes: newNodes, connections: newConnections);
    _debounceAndSave();
  }

  void startConnection(String id) {
    state = state.copyWith(connectionStartNodeId: id);
  }

  void updateConnectionPreview(Offset p) {
    state = state.copyWith(connectionPreviewEnd: p);
  }

  Future<void> endConnection(String? targetNodeId) async {
    final fromNodeId = state.connectionStartNodeId;
    state = state.copyWith(
      clearConnectionStart: true,
      clearConnectionPreview: true,
      dehoverNode: true,
    );
    if (fromNodeId == null ||
        targetNodeId == null ||
        fromNodeId == targetNodeId) {
      return;
    }
    try {
      final fromNode = state.nodes.firstWhereOrNull((n) => n.id == fromNodeId);
      final toNode = state.nodes.firstWhereOrNull((n) => n.id == targetNodeId);
      if (fromNode == null || toNode == null) return;

      final rawItems = fromNode.content?['items'];
      final currentItems = <Map<String, dynamic>>[];
      if (rawItems is List) {
        for (final raw in rawItems) {
          if (raw is ContentItem) {
            currentItems.add(raw.toJson());
          } else if (raw is Map) {
            currentItems.add(Map<String, dynamic>.from(raw));
          }
        }
      }

      final hasExistingButton = currentItems.any((raw) {
        if (raw['type'] != 'button') return false;
        final itemTarget = raw['targetNodeId']?.toString();
        final hasOnPressScript =
            (raw['scriptTriggers'] as Map?)?.containsKey('onPress') ?? false;
        return itemTarget == toNode.id && !hasOnPressScript;
      });
      if (hasExistingButton) {
        await saveConnection(_questId, fromNodeId, targetNodeId);
        return;
      }

      final newButtonJson = ContentItem(
        id: const Uuid().v4(),
        type: 'button',
        text: toNode.label,
        targetNodeId: toNode.id,
        wrapText: true, // По умолчанию текст на кнопке переносится
      ).toJson();

      final newItems = [...currentItems, newButtonJson];
      final newContent = Map<String, dynamic>.from(fromNode.content ?? {});
      newContent['items'] = newItems;

      final updatedFromNode = fromNode.copyWith(content: newContent);
      updatedFromNode.invalidateTextCache();

      final newNodesList = state.nodes.map((node) {
        return node.id == fromNodeId ? updatedFromNode : node;
      }).toList();

      final newConnection = Connection(
        id: const Uuid().v4(),
        fromNode: updatedFromNode,
        toNode: toNode,
        color: CanvasTheme.connectionContent,
      );

      state = state.copyWith(
        nodes: newNodesList,
        connections: [...state.connections, newConnection],
      );

      await saveConnection(_questId, fromNodeId, targetNodeId);

      // Кнопку кладём поверх записанной ноды, а не собираем ноду из
      // канвасового снимка: иначе сохранение связи стирало бы поля, которых
      // снимок не знает (видео-фон, размытие, отступы).
      final persistedSource = await _persistedNodesById();
      final savedNode =
          persistedSource[updatedFromNode.id]?.copyWith(
            content: updatedFromNode.content ?? {},
          ) ??
          _nodeFromCanvas(updatedFromNode);

      await saveNodes(_questId, [savedNode]);
      _ref.invalidate(allQuestNodesProvider(_questId));
    } catch (e, stack) {
      print('❌ [CanvasNotifier] Connection Error: $e\n$stack');
    }
  }

  Future<void> deleteSelectedNode() async {
    if (state.selectedNodeIds.isEmpty) return;
    try {
      final idsToDelete = Set.from(state.selectedNodeIds);
      final newNodesList = state.nodes
          .where((node) => !idsToDelete.contains(node.id))
          .toList();
      final connectionsToRemove = state.connections
          .where(
            (conn) =>
                idsToDelete.contains(conn.fromNode.id) ||
                idsToDelete.contains(conn.toNode.id),
          )
          .toList();
      final newConnectionsList = state.connections
          .where((c) => !connectionsToRemove.contains(c))
          .toList();

      state = state.copyWith(
        nodes: newNodesList,
        connections: newConnectionsList,
        clearSelection: true,
      );

      for (final id in idsToDelete) {
        unawaited(deleteNode(_questId, id));
      }
      for (final conn in connectionsToRemove) {
        if (!conn.isVirtual) {
          unawaited(
            deleteConnection(_questId, conn.fromNode.id, conn.toNode.id),
          );
        }
      }
      _debounceAndSave();
      _ref.invalidate(allQuestNodesProvider(_questId));
    } catch (e) {
      await reloadData();
    }
  }

  Future<void> resetCamera() async {
    cameraOffset.value = Offset.zero;
    cameraScale.value = 1.0;
    state = state.copyWith(offset: Offset.zero, scale: 1.0);
    _scheduleCameraCommit();
  }

  Offset screenToWorld(Offset p) =>
      (p - cameraOffset.value) / cameraScale.value;

  void _scheduleCameraCommit() {
    _cameraCommitTimer?.cancel();
    _cameraCommitTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final off = cameraOffset.value;
      final sc = cameraScale.value;
      // Sync to Riverpod state once, without triggering per-frame rebuilds
      if (state.offset != off || state.scale != sc) {
        state = state.copyWith(offset: off, scale: sc);
      }
      unawaited(saveCamera());
    });
  }

  Future<void> refreshNodeData(String id) async {
    await _loadCanvasData();
  }

  void searchNodes(String q) => state = state.copyWith(searchQuery: q);

  void moveNode(String id, Offset d) => moveSelectedNodes(d);

  void hoverNode(String? id) {
    if (id == state.hoveredNodeId) return;
    // Дебаунс 32мс — onScaleUpdate шлёт 60-120Hz, каждый copyWith ребилдит весь экран
    _hoverDebounce?.cancel();
    _hoverDebounce = Timer(const Duration(milliseconds: 32), () {
      state = state.copyWith(hoveredNodeId: id, dehoverNode: id == null);
    });
  }

  void toggleConnectionMode() {
    final newMode = !state.connectionMode;
    state = state.copyWith(
      connectionMode: newMode,
      clearConnectionStart: !newMode,
      clearConnectionPreview: !newMode,
    );
  }

  void panCamera(Offset delta) {
    cameraOffset.value += delta;
    _scheduleCameraCommit();
  }

  void scaleCamera(double newScale, Offset focalPoint) {
    final oldScale = cameraScale.value;
    final clampedScale = newScale.clamp(0.1, 5.0);
    final scaleDelta = clampedScale / oldScale;
    final newOffset =
        focalPoint - (focalPoint - cameraOffset.value) * scaleDelta;
    cameraOffset.value = newOffset;
    cameraScale.value = clampedScale;
    _scheduleCameraCommit();
  }

  Future<void> reloadData() async {
    _ref.invalidate(allQuestNodesProvider(_questId));
    _ref.invalidate(questTagsProvider(_questId)); // <-- Ошибка была здесь
    await _loadCanvasData();
  }

  Map<String, List<String>> _buildGraph(
    List<Node> nodes,
    List<Connection> connections,
  ) {
    final graph = <String, List<String>>{};
    for (var node in nodes) {
      graph[node.id] = [];
    }
    for (var conn in connections) {
      if (!conn.isVirtual) {
        graph[conn.fromNode.id]!.add(conn.toNode.id);
      }
    }
    return graph;
  }

  List<(String, String)> _removeCycles(Map<String, List<String>> graph) {
    final reversed = <(String, String)>[];
    final visited = <String>{};
    final recStack = <String>{};
    for (var node in graph.keys) {
      if (!visited.contains(node)) {
        _dfsCycle(node, graph, visited, recStack, reversed);
      }
    }
    return reversed;
  }

  void _dfsCycle(
    String node,
    Map<String, List<String>> graph,
    Set<String> visited,
    Set<String> recStack,
    List<(String, String)> reversed,
  ) {
    visited.add(node);
    recStack.add(node);
    for (var neighbor in List<String>.from(graph[node]!)) {
      if (!visited.contains(neighbor)) {
        _dfsCycle(neighbor, graph, visited, recStack, reversed);
      } else if (recStack.contains(neighbor)) {
        graph[node]!.remove(neighbor);
        graph.putIfAbsent(neighbor, () => []).add(node);
        reversed.add((neighbor, node));
      }
    }
    recStack.remove(node);
  }

  List<List<String>> _assignLayers(
    Map<String, List<String>> graph,
    List<Node> nodes,
  ) {
    final inDegree = <String, int>{};
    for (var node in nodes) {
      inDegree[node.id] = 0;
    }
    for (var adj in graph.values) {
      for (var neighbor in adj) {
        inDegree[neighbor] = (inDegree[neighbor] ?? 0) + 1;
      }
    }
    final layers = <List<String>>[];
    final queue = Queue<String>.from(
      inDegree.entries.where((e) => e.value == 0).map((e) => e.key),
    );
    final nodeIds = nodes.map((n) => n.id).toSet();
    final remainingNodes = Set<String>.from(nodeIds);

    while (queue.isNotEmpty) {
      final level = <String>[];
      final size = queue.length;
      for (int i = 0; i < size; i++) {
        final node = queue.removeFirst();
        if (remainingNodes.remove(node)) {
          level.add(node);
          if (graph.containsKey(node)) {
            for (var neighbor in graph[node]!) {
              inDegree[neighbor] = (inDegree[neighbor] ?? 1) - 1;
              if (inDegree[neighbor] == 0) {
                queue.add(neighbor);
              }
            }
          }
        }
      }
      if (level.isNotEmpty) layers.add(level);
    }
    if (remainingNodes.isNotEmpty) {
      if (layers.isEmpty) layers.add([]);
      layers.last.addAll(remainingNodes);
    }
    return layers;
  }

  void _reduceCrossings(
    List<List<String>> layers,
    Map<String, List<String>> graph,
  ) {
    for (int i = 1; i < layers.length; i++) {
      final currentLayer = layers[i];
      final barycenters = <String, double>{};
      for (var node in currentLayer) {
        final parents = graph.keys
            .where((p) => graph[p]!.contains(node))
            .toList();
        if (parents.isNotEmpty) {
          final positions = parents
              .map((p) => _findPosition(layers[i - 1], p))
              .toList();
          barycenters[node] =
              positions.reduce((a, b) => a + b) / positions.length;
        } else {
          barycenters[node] = 0.0;
        }
      }
      currentLayer.sort((a, b) => barycenters[a]!.compareTo(barycenters[b]!));
    }
  }

  double _findPosition(List<String> layer, String node) {
    final index = layer.indexOf(node);
    return index == -1 ? 0.0 : index.toDouble();
  }

  List<Node> _assignCoordinates(List<List<String>> layers, List<Node> nodes) {
    const double verticalSpacing = 200.0;
    const double horizontalSpacing = 250.0;
    final nodeMap = {for (var n in nodes) n.id: n};
    final newNodes = <Node>[];
    for (int level = 0; level < layers.length; level++) {
      final nodesInLevel = layers[level];
      final levelWidth = (nodesInLevel.length - 1) * horizontalSpacing;
      final startX = -levelWidth / 2;
      for (int i = 0; i < nodesInLevel.length; i++) {
        final nodeId = nodesInLevel[i];
        final node = nodeMap[nodeId];
        if (node != null) {
          final newX = startX + i * horizontalSpacing;
          final newY = level * verticalSpacing;
          newNodes.add(node.copyWith(position: Offset(newX, newY)));
        }
      }
    }
    return newNodes;
  }
}

final canvasProvider =
    StateNotifierProvider.family<CanvasNotifier, CanvasState, (String, String)>(
      (ref, ids) {
        final (questId, tagId) = ids;
        final notifier = CanvasNotifier(ref, questId, tagId);
        ref.onDispose(() {
          notifier._autoSaveDebounce?.cancel();
          notifier._cameraCommitTimer?.cancel();
          // Flush latest camera before dispose
          notifier.saveCamera();
        });
        return notifier;
      },
    );
