import 'dart:convert'; // Для jsonDecode/jsonEncode (Deep Copy)
import 'dart:ui' show Offset;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/quest_content_change_bus.dart';
import 'package:mnd_core/models/saved_node.dart';
import 'package:canvas_app/models/canvas_models.dart'; // Для моделей Group/Comment
import 'package:uuid/uuid.dart';
import 'package:mnd_core/utils/quest_paths.dart';

export 'package:mnd_core/models/saved_node.dart';

// План 020-C4.3: чтение/запись квеста — через ядро.
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};
Future<T> _qsync<T>(String key, Future<T> Function() action) =>
    QuestStore.synchronized<T>(key, action);

/// (всего нод в квесте, нод в главе) — для safety-check удаления.
Future<(int, int)> nodeDeletionStats(
  String questId, {
  String? chapterId,
}) async {
  try {
    final index = await QuestNodesStore.readIndex(questId);
    final nodes = (index['nodes'] as List<dynamic>? ?? []).whereType<Map>();
    final total = nodes.length;
    final chapter = chapterId == null
        ? total
        : nodes.where((n) => n['chapterId']?.toString() == chapterId).length;
    return (total, chapter);
  } catch (_) {
    return (0, 0);
  }
}

Map<String, dynamic> _summaryAsNodeJson(Map<dynamic, dynamic> raw) {
  final json = Map<String, dynamic>.from(raw);
  final description = json['description'];
  if (description is String && description.isNotEmpty) {
    json['content'] = {'items': <dynamic>[], 'description': description};
  }
  return json;
}

class TagNodesInfo {
  final String questId;
  final String tagId;
  TagNodesInfo({required this.questId, required this.tagId});
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TagNodesInfo &&
          runtimeType == other.runtimeType &&
          questId == other.questId &&
          tagId == other.tagId;
  @override
  int get hashCode => questId.hashCode ^ tagId.hashCode;
}

// --- PROVIDERS ---

final allQuestNodesProvider = FutureProvider.autoDispose
    .family<List<SavedNode>, String>((ref, questId) async {
      return _qsync('nodes_$questId', () async {
        try {
          final nodesData = await QuestNodesStore.read(questId);
          final nodesJson = nodesData['nodes'] as List<dynamic>? ?? [];

          final validNodes = <SavedNode>[];

          for (final jsonItem in nodesJson) {
            try {
              if (jsonItem is Map<String, dynamic>) {
                validNodes.add(SavedNode.fromJson(jsonItem));
              }
            } catch (e) {
              // ignore error
            }
          }

          return validNodes;
        } catch (e) {
          return [];
        }
      });
    });

/// Лёгкий индекс квеста для канваса: без тел нод и без их content.
final canvasIndexProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, questId) async {
      return _qsync('nodes_$questId', () async {
        try {
          return await QuestNodesStore.readIndex(questId);
        } catch (e) {
          return <String, dynamic>{
            'nodes': <dynamic>[],
            'groups': <dynamic>[],
            'comments': <dynamic>[],
            'edges': <dynamic>[],
          };
        }
      });
    });

final tagNodesProvider = FutureProvider.autoDispose
    .family<List<SavedNode>, TagNodesInfo>((ref, tagInfo) async {
      try {
        final index = await ref.watch(
          canvasIndexProvider(tagInfo.questId).future,
        );
        final nodes = (index['nodes'] as List<dynamic>? ?? []);
        return [
          for (final raw in nodes)
            if (raw is Map && raw['chapterId']?.toString() == tagInfo.tagId)
              SavedNode.fromJson(_summaryAsNodeJson(raw)),
        ];
      } catch (e) {
        return [];
      }
    });

final canvasExtraDataProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, questId) async {
      try {
        final index = await ref.watch(canvasIndexProvider(questId).future);
        return {
          'groups': index['groups'] ?? <dynamic>[],
          'comments': index['comments'] ?? <dynamic>[],
        };
      } catch (e) {
        return {'groups': <dynamic>[], 'comments': <dynamic>[]};
      }
    });

final tagCameraStateProvider = FutureProvider.autoDispose
    .family<CameraState, TagNodesInfo>((ref, tagInfo) async {
      return _qsync('config_${tagInfo.questId}', () async {
        try {
          final configPath = QuestPaths.config(tagInfo.questId);
          if (!await (await _qs()).exists(configPath)) return CameraState();
          final config = await _readMap(configPath);
          final tagsJson = config['tags'] as List<dynamic>? ?? [];
          final tagJson = tagsJson.firstWhere(
            (tag) => (tag as Map<String, dynamic>)['id'] == tagInfo.tagId,
            orElse: () => null,
          );
          if (tagJson != null) {
            final tagMap = tagJson as Map<String, dynamic>;
            if (tagMap['cameraState'] != null) {
              return CameraState.fromJson(tagMap['cameraState']);
            }
          }
          return CameraState();
        } catch (e) {
          return CameraState();
        }
      });
    });

// --- FUNCTIONS ---

Future<bool> saveCanvasData(
  String questId, {
  required List<SavedNode> nodes,
  required String chapterId,
  List<CanvasGroup>? groups,
  List<CanvasComment>? comments,
}) async {
  return _qsync('nodes_$questId', () async {
    try {
      if (await QuestNodesStore.hasPerNodeIndex(questId)) {
        final index = await QuestNodesStore.readIndex(questId);
        final existingChapterCount = (index['nodes'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .where((n) => n['chapterId']?.toString() == chapterId)
            .length;
        if (nodes.isEmpty && existingChapterCount > 0) {
          print('⚠️ saveCanvasData: пустая глава, запись отменена');
          return false;
        }
        await QuestNodesStore.writeCanvasLayout(
          questId,
          chapterId: chapterId,
          nodes: [for (final node in nodes) node.toJson()],
          groups: groups?.map((g) => g.toJson()).toList(),
          comments: comments?.map((c) => c.toJson()).toList(),
        );
        await _updateQuestPluginDependencies(questId, [
          for (final node in nodes) node.toJson(),
        ]);
        QuestContentChangeBus.instance.markChanged(questId);
        return true;
      }

      final existingData = await QuestNodesStore.read(questId);

      final allNodesJson = (existingData['nodes'] as List<dynamic>? ?? [])
          .toList();
      if (nodes.isEmpty && allNodesJson.isNotEmpty) {
        // Загрузка нод не удалась/пришла пустой — не затираем главу.
        print('⚠️ saveCanvasData: пустой список нод, запись отменена');
        return false;
      }
      final existingChapterNodesById = <String, Map<String, dynamic>>{};
      for (final rawNode in allNodesJson) {
        if (rawNode is! Map) continue;
        final nodeMap = <String, dynamic>{};
        rawNode.forEach((key, value) {
          nodeMap[key.toString()] = value;
        });
        if (nodeMap['chapterId']?.toString() != chapterId) continue;
        final id = nodeMap['id']?.toString();
        if (id == null || id.isEmpty) continue;
        existingChapterNodesById[id] = nodeMap;
      }

      allNodesJson.removeWhere((nodeJson) {
        if (nodeJson is! Map) return false;
        return nodeJson['chapterId']?.toString() == chapterId;
      });
      for (final node in nodes) {
        final previous = existingChapterNodesById[node.id] ?? const {};
        allNodesJson.add(_mergeNodeJson(previous, node.toJson()));
      }

      List<dynamic> allGroupsJson =
          (existingData['groups'] as List<dynamic>? ?? []).toList();
      allGroupsJson.removeWhere((g) => g['chapterId'] == chapterId);
      if (groups != null) {
        allGroupsJson.addAll(groups.map((g) => g.toJson()).toList());
      }

      List<dynamic> allCommentsJson =
          (existingData['comments'] as List<dynamic>? ?? []).toList();
      allCommentsJson.removeWhere((c) => c['chapterId'] == chapterId);
      if (comments != null) {
        allCommentsJson.addAll(comments.map((c) => c.toJson()).toList());
      }

      final Map<String, dynamic> newData = {
        'nodes': allNodesJson,
        'groups': allGroupsJson,
        'comments': allCommentsJson,
      };

      await QuestNodesStore.write(questId, newData);
      await _updateQuestPluginDependencies(questId, allNodesJson);
      QuestContentChangeBus.instance.markChanged(questId);
      return true;
    } catch (e) {
      print('❌ Error saving canvas data: $e');
      return false;
    }
  });
}

/// Старая запись ноды из файла + свежая сериализация. Ключи модели,
/// которые `toJson()` не вернул, удаляются: значение вернулось к дефолту,
/// и старая копия в файле воскресила бы снятую настройку. Чужие ключи
/// бережём — кроме [SavedNode.legacyKeys]: их модель больше не читает, и
/// без этой строчки снятая HUD-панель осталась бы в квесте навсегда.
Map<String, dynamic> _mergeNodeJson(
  Map<String, dynamic> previous,
  Map<String, dynamic> serialized,
) {
  final next = {...previous, ...serialized};
  for (final key in SavedNode.modelKeys) {
    if (!serialized.containsKey(key)) next.remove(key);
  }
  for (final key in SavedNode.legacyKeys) {
    next.remove(key);
  }
  return next;
}

Future<bool> saveNodes(String questId, List<SavedNode> nodesToSave) async {
  return _qsync('nodes_$questId', () async {
    try {
      if (await QuestNodesStore.hasPerNodeIndex(questId)) {
        for (final node in nodesToSave) {
          final previous = await QuestNodesStore.readNode(questId, node.id);
          await QuestNodesStore.writeNode(
            questId,
            _mergeNodeJson(previous ?? const {}, node.toJson()),
          );
        }
        await _updateQuestPluginDependencies(questId, [
          for (final node in nodesToSave) node.toJson(),
        ]);
        QuestContentChangeBus.instance.markChanged(questId);
        return true;
      }

      final nodesData = await QuestNodesStore.read(questId);

      final currentNodesJson = (nodesData['nodes'] as List<dynamic>? ?? []);
      final nodeMap = <String, Map<String, dynamic>>{};

      for (var item in currentNodesJson) {
        if (item is Map<String, dynamic>) {
          final id = item['id']?.toString();
          if (id == null || id.isEmpty) continue;
          nodeMap[id] = item;
        }
      }

      for (var node in nodesToSave) {
        final previous = nodeMap[node.id] ?? const <String, dynamic>{};
        nodeMap[node.id] = _mergeNodeJson(previous, node.toJson());
      }

      nodesData['nodes'] = nodeMap.values.toList();

      await QuestNodesStore.write(questId, nodesData);
      await _updateQuestPluginDependencies(
        questId,
        nodesData['nodes'] as List<dynamic>? ?? const [],
      );
      QuestContentChangeBus.instance.markChanged(questId);
      return true;
    } catch (e) {
      return false;
    }
  });
}

Future<bool> deleteNode(String questId, String nodeId) async {
  return _qsync('nodes_$questId', () async {
    try {
      if (await QuestNodesStore.hasPerNodeIndex(questId)) {
        await QuestNodesStore.deleteNode(questId, nodeId);
        await _removeNodeReferences(questId, nodeId);
        QuestContentChangeBus.instance.markChanged(questId);
        return true;
      }

      final nodesData = await QuestNodesStore.read(questId);
      final allNodesJson = (nodesData['nodes'] as List<dynamic>? ?? [])
          .toList();
      allNodesJson.removeWhere(
        (node) => (node as Map<String, dynamic>)['id'] == nodeId,
      );
      nodesData['nodes'] = allNodesJson;
      await QuestNodesStore.write(questId, nodesData);
      await _updateQuestPluginDependencies(questId, allNodesJson);
      QuestContentChangeBus.instance.markChanged(questId);
      return true;
    } catch (e) {
      return false;
    }
  });
}

Future<void> _removeNodeReferences(String questId, String nodeId) async {
  try {
    final configPath = QuestPaths.config(questId);
    final qs = await _qs();
    if (!await qs.exists(configPath)) return;
    final config = await _readMap(configPath);
    final connections = (config['connections'] as List<dynamic>? ?? []).where((
      conn,
    ) {
      if (conn is! Map) return false;
      return conn['fromId']?.toString() != nodeId &&
          conn['toId']?.toString() != nodeId;
    }).toList();
    final next = <String, dynamic>{...config, 'connections': connections};
    if (config['startNodeId']?.toString() == nodeId) {
      next['startNodeId'] = '';
    }
    await qs.writeJson(configPath, next);
  } catch (_) {}
}

Future<void> _updateQuestPluginDependencies(
  String questId,
  List<dynamic> nodesJson,
) async {
  try {
    final deps = _collectPluginDependencies(nodesJson).toList()..sort();
    final configPath = QuestPaths.config(questId);
    if (!await (await _qs()).exists(configPath)) return;
    final config = await _readMap(configPath);
    final existing = (config['pluginDependencies'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toSet();
    final merged = {...existing, ...deps}.toList()..sort();
    config['pluginDependencies'] = merged;
    await (await _qs()).writeJson(configPath, config);
  } catch (_) {}
}

Set<String> _collectPluginDependencies(List<dynamic> nodesJson) {
  final deps = <String>{};
  for (final raw in nodesJson) {
    if (raw is! Map) continue;
    final content = raw['content'];
    if (content is! Map) continue;
    final items = content['items'];
    if (items is! List) continue;
    for (final item in items) {
      _collectPluginDependenciesFromItem(item, deps);
    }
  }
  return deps;
}

void _collectPluginDependenciesFromItem(dynamic raw, Set<String> deps) {
  if (raw is! Map) return;
  final type = raw['type']?.toString();
  if (type == 'plugin') {
    final pluginId = raw['pluginId']?.toString().trim();
    if (pluginId != null && pluginId.isNotEmpty) {
      deps.add(pluginId);
    }
  }
  final children = raw['children'];
  if (children is List) {
    for (final child in children) {
      _collectPluginDependenciesFromItem(child, deps);
    }
  }
}

Future<bool> saveTagCameraState(
  String questId,
  String tagId,
  CameraState cameraState,
) async {
  return _qsync('config_$questId', () async {
    try {
      final configPath = QuestPaths.config(questId);
      final config = await _readMap(configPath);
      final tagsJson = (config['tags'] as List<dynamic>? ?? []).toList();
      final tagIndex = tagsJson.indexWhere(
        (tag) => (tag as Map<String, dynamic>)['id'] == tagId,
      );
      if (tagIndex == -1) return false;
      final tagMap = tagsJson[tagIndex] as Map<String, dynamic>;
      tagMap['cameraState'] = cameraState.toJson();
      tagsJson[tagIndex] = tagMap;
      await (await _qs()).writeJson(configPath, {...config, 'tags': tagsJson});
      return true;
    } catch (e) {
      return false;
    }
  });
}

Future<bool> saveConnection(String questId, String fromId, String toId) async {
  return _qsync('config_$questId', () async {
    try {
      final configPath = QuestPaths.config(questId);
      final config = await _readMap(configPath);
      final connectionsJson = (config['connections'] as List<dynamic>? ?? [])
          .toList();
      final exists = connectionsJson.any((conn) {
        final connMap = conn as Map<String, dynamic>;
        return connMap['fromId'] == fromId && connMap['toId'] == toId;
      });
      if (!exists) {
        connectionsJson.add({
          'id': const Uuid().v4(),
          'fromId': fromId,
          'toId': toId,
        });
        await (await _qs()).writeJson(configPath, {
          ...config,
          'connections': connectionsJson,
        });
        QuestContentChangeBus.instance.markChanged(questId);
      }
      return true;
    } catch (e) {
      return false;
    }
  });
}

Future<bool> deleteConnection(
  String questId,
  String fromId,
  String toId,
) async {
  return _qsync('config_$questId', () async {
    try {
      final configPath = QuestPaths.config(questId);
      final config = await _readMap(configPath);
      final connectionsJson = (config['connections'] as List<dynamic>? ?? [])
          .toList();
      connectionsJson.removeWhere((conn) {
        final connMap = conn as Map<String, dynamic>;
        return connMap['fromId'] == fromId && connMap['toId'] == toId;
      });
      await (await _qs()).writeJson(configPath, {
        ...config,
        'connections': connectionsJson,
      });
      QuestContentChangeBus.instance.markChanged(questId);
      return true;
    } catch (e) {
      return false;
    }
  });
}

Future<bool> syncOutgoingConnections(
  String questId,
  String fromId,
  Set<String> desiredToIds,
) async {
  return _qsync('config_$questId', () async {
    try {
      final configPath = QuestPaths.config(questId);
      final config = await _readMap(configPath);
      final connectionsJson = (config['connections'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final outgoing = connectionsJson
          .where((conn) => conn['fromId'] == fromId)
          .toList();
      final existingToIds = outgoing
          .map((conn) => conn['toId']?.toString())
          .whereType<String>()
          .toSet();

      connectionsJson.removeWhere(
        (conn) =>
            conn['fromId'] == fromId &&
            !desiredToIds.contains(conn['toId']?.toString()),
      );

      for (final toId in desiredToIds) {
        if (!existingToIds.contains(toId)) {
          connectionsJson.add({
            'id': const Uuid().v4(),
            'fromId': fromId,
            'toId': toId,
          });
        }
      }

      await (await _qs()).writeJson(configPath, {
        ...config,
        'connections': connectionsJson,
      });
      QuestContentChangeBus.instance.markChanged(questId);
      return true;
    } catch (_) {
      return false;
    }
  });
}

SavedNode createNewNode({
  required String chapterId,
  String? title,
  Map<String, dynamic>? content,
  double x = 0.0,
  double y = 0.0,
  String? backgroundAssetId,
}) {
  return SavedNode(
    id: const Uuid().v4(),
    chapterId: chapterId,
    title: title ?? tr('Новая нода'),
    content: content ?? {'items': []},
    x: x,
    y: y,
    backgroundAssetId: backgroundAssetId,
  );
}

/// Возвращает свободную позицию рядом с (baseX, baseY), смещая по Y, пока
/// в "зоне столкновения" не окажется других нод.
///
/// Используется, когда мы создаём новую ноду как дочернюю для существующей:
/// базовая позиция — снизу от исходной (baseX = currentNode.x,
/// baseY = currentNode.y + stepY). Если такая точка уже занята другим
/// потомком — сдвигаем по Y (вниз/вверх по очереди) шагом [stepY], пока
/// не найдём свободный слот. X не меняем — канвас растёт вертикально.
///
/// [collisionRadiusX] и [collisionRadiusY] задают размеры прямоугольной
/// зоны, в пределах которой считается, что нода "сталкивается" с другой.
Offset findFreePositionNear(
  Iterable<SavedNode> existingNodes,
  double baseX,
  double baseY, {
  double collisionRadiusX = 150,
  double collisionRadiusY = 100,
  double stepY = 220,
  int maxSteps = 50,
}) {
  double x = baseX;
  double y = baseY;

  bool isOccupied(double cx, double cy) {
    for (final n in existingNodes) {
      if ((n.x - cx).abs() < collisionRadiusX &&
          (n.y - cy).abs() < collisionRadiusY) {
        return true;
      }
    }
    return false;
  }

  int step = 0;
  while (isOccupied(x, y) && step < maxSteps) {
    // Чередуем смещение вниз и вверх, начиная с "вниз", чтобы дерево
    // строилось преимущественно сверху-вниз.
    final direction = step.isEven ? 1 : -1;
    final magnitude = (step ~/ 2) + 1;
    y = baseY + direction * magnitude * stepY;
    step++;
  }

  return Offset(x, y);
}

Future<void> updateNode(String questId, SavedNode nodeToSave) async {
  final isSaved = await saveNodes(questId, [nodeToSave]);
  if (!isSaved) {
    throw Exception(
      trf('Не удалось сохранить ноду {p0}', {'p0': nodeToSave.id}),
    );
  }
}

Future<bool> duplicateNode(String questId, String originalNodeId) async {
  return _qsync('nodes_$questId', () async {
    try {
      final nodesData = await QuestNodesStore.read(questId);
      final allNodesJson = (nodesData['nodes'] as List<dynamic>? ?? [])
          .toList();

      final originalNodeMap = allNodesJson.firstWhere(
        (n) => n['id'] == originalNodeId,
        orElse: () => null,
      );

      if (originalNodeMap == null) return false;

      final deepCopy =
          jsonDecode(jsonEncode(originalNodeMap)) as Map<String, dynamic>;

      deepCopy['id'] = const Uuid().v4();
      deepCopy['title'] = trf('{p0} (Копия)', {'p0': deepCopy['title']});
      deepCopy['x'] = (deepCopy['x'] as num).toDouble() + 30.0;
      deepCopy['y'] = (deepCopy['y'] as num).toDouble() + 30.0;

      allNodesJson.add(deepCopy);
      nodesData['nodes'] = allNodesJson;

      await QuestNodesStore.write(questId, nodesData);
      QuestContentChangeBus.instance.markChanged(questId);
      return true;
    } catch (e) {
      print("Ошибка дублирования: $e");
      return false;
    }
  });
}

Future<bool> copyNodeToChapter(
  String questId,
  String nodeId,
  String targetChapterId,
) async {
  return _qsync('nodes_$questId', () async {
    try {
      final nodesData = await QuestNodesStore.read(questId);
      final allNodesJson = (nodesData['nodes'] as List<dynamic>? ?? [])
          .toList();

      final nodeToCopy = allNodesJson.firstWhere(
        (n) => (n as Map<String, dynamic>)['id'] == nodeId,
        orElse: () => null,
      );

      if (nodeToCopy == null) return false;

      final copiedNode =
          jsonDecode(jsonEncode(nodeToCopy)) as Map<String, dynamic>;

      copiedNode['id'] = const Uuid().v4();
      copiedNode['chapterId'] = targetChapterId;
      copiedNode['title'] = trf('{p0} (Копия)', {'p0': copiedNode['title']});

      allNodesJson.add(copiedNode);
      nodesData['nodes'] = allNodesJson;

      await QuestNodesStore.write(questId, nodesData);
      QuestContentChangeBus.instance.markChanged(questId);
      return true;
    } catch (e) {
      print("Ошибка копирования ноды: $e");
      return false;
    }
  });
}

Future<bool> moveNodeToChapter(
  String questId,
  String nodeId,
  String targetChapterId,
) async {
  return _qsync('nodes_$questId', () async {
    try {
      final nodesData = await QuestNodesStore.read(questId);
      final allNodesJson = (nodesData['nodes'] as List<dynamic>? ?? [])
          .toList();

      final nodeIndex = allNodesJson.indexWhere(
        (n) => (n as Map<String, dynamic>)['id'] == nodeId,
      );

      if (nodeIndex == -1) return false;

      final nodeToMove = allNodesJson[nodeIndex] as Map<String, dynamic>;
      nodeToMove['chapterId'] = targetChapterId;

      allNodesJson[nodeIndex] = nodeToMove;
      nodesData['nodes'] = allNodesJson;

      await QuestNodesStore.write(questId, nodesData);
      QuestContentChangeBus.instance.markChanged(questId);
      return true;
    } catch (e) {
      print("Ошибка перемещения ноды: $e");
      return false;
    }
  });
}
