import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:uuid/uuid.dart';
import 'package:mnd_core/utils/quest_paths.dart';

// План 020-C4.3: чтение/запись квеста — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};
Future<T> _qsync<T>(String key, Future<T> Function() action) =>
    QuestStore.synchronized<T>(key, action);

// Модель Тега
class Tag {
  final String id;
  final String name;
  final String questId;
  final String? backgroundAssetId;
  final String? backgroundAudioId;
  final String folderPath;

  Tag({
    required this.id,
    required this.name,
    required this.questId,
    this.backgroundAssetId,
    this.backgroundAudioId,
    this.folderPath = '/',
  });

  static String normalizeFolderPath(String? raw) {
    final value = (raw ?? '').trim().replaceAll('\\', '/');
    if (value.isEmpty || value == '/') return '/';
    var path = value.startsWith('/') ? value : '/$value';
    path = path.replaceAll(RegExp(r'/+'), '/');
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  factory Tag.fromJson(Map<String, dynamic> json) => Tag(
    id: json['id'] as String,
    name: json['name'] as String,
    questId: json['questId'] as String? ?? '',
    backgroundAssetId: json['backgroundAssetId'] as String?,
    backgroundAudioId: json['backgroundAudioId'] as String?,
    folderPath: normalizeFolderPath(json['folderPath'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (backgroundAssetId != null) 'backgroundAssetId': backgroundAssetId,
    if (backgroundAudioId != null) 'backgroundAudioId': backgroundAudioId,
    if (folderPath != '/') 'folderPath': folderPath,
  };
}

final questTagsProvider = FutureProvider.autoDispose.family<List<Tag>, String>((
  ref,
  questId,
) async {
  // Читаем под блокировкой конфига
  return _qsync('config_$questId', () async {
    try {
      final configPath = QuestPaths.config(questId);
      if (!await (await _qs()).exists(configPath)) {
        return [];
      }

      final config = await _readMap(configPath);
      final tagsJson = config['tags'] as List<dynamic>? ?? [];
      final tags = tagsJson.map((json) {
        final tag = Tag.fromJson(json as Map<String, dynamic>);
        return Tag(
          id: tag.id,
          name: tag.name,
          questId: questId,
          backgroundAssetId: tag.backgroundAssetId,
          backgroundAudioId: tag.backgroundAudioId,
          folderPath: tag.folderPath,
        );
      }).toList();

      tags.sort((a, b) => a.name.compareTo(b.name));
      return tags;
    } catch (e) {
      print('❌ Ошибка загрузки тегов: $e');
      return [];
    }
  });
});

final tagStatsProvider = FutureProvider.autoDispose.family<TagStats, TagInfo>((
  ref,
  tagInfo,
) async {
  try {
    final allNodes = await ref.watch(
      allQuestNodesProvider(tagInfo.questId).future,
    );
    final tagNodeIds = allNodes
        .where((node) => node.chapterId == tagInfo.tagId)
        .map((n) => n.id)
        .toSet();
    final nodesCount = tagNodeIds.length;

    final configPath = QuestPaths.config(tagInfo.questId);
    int forksCount = 0;
    if (await (await _qs()).exists(configPath)) {
      final config = await _readMap(configPath);
      final connectionsJson = config['connections'] as List<dynamic>? ?? [];

      for (final connJson in connectionsJson) {
        final conn = connJson as Map<String, dynamic>;
        final fromId = conn['fromId'] as String?;
        final toId = conn['toId'] as String?;
        if (fromId != null &&
            toId != null &&
            tagNodeIds.contains(fromId) &&
            tagNodeIds.contains(toId)) {
          forksCount++;
        }
      }
    }

    return TagStats(nodesCount: nodesCount, forksCount: forksCount);
  } catch (e) {
    print('❌ Ошибка загрузки статистики тега: $e');
    return TagStats(nodesCount: 0, forksCount: 0);
  }
});

class TagInfo {
  final String questId;
  final String tagId;

  TagInfo({required this.questId, required this.tagId});
}

class TagStats {
  final int nodesCount;
  final int forksCount;

  TagStats({required this.nodesCount, required this.forksCount});
}

// Функция для создания нового тега
Future<Tag?> createTag(
  String questId,
  String name, {
  String? backgroundAudioId,
  String? backgroundAssetId,
  String? folderPath,
}) async {
  return _qsync('config_$questId', () async {
    try {
      final configPath = QuestPaths.config(questId);
      final config = await _readMap(configPath);
      final tagsJson = (config['tags'] as List<dynamic>? ?? []).toList();

      final newTag = Tag(
        id: const Uuid().v4(),
        name: name,
        questId: questId,
        backgroundAudioId: backgroundAudioId,
        backgroundAssetId: backgroundAssetId,
        folderPath: Tag.normalizeFolderPath(folderPath),
      );

      tagsJson.add(newTag.toJson());

      await (await _qs()).writeJson(configPath, {...config, 'tags': tagsJson});
      return newTag;
    } catch (e) {
      print('❌ Ошибка создания тега: $e');
      return null;
    }
  });
}

// Функция для удаления тега (блокируем оба файла, т.к. меняем оба)
Future<bool> deleteTag(String questId, String tagId) async {
  // Сначала блокируем ноды, потом конфиг (порядок важен для избежания Deadlock, если бы блокировка была рекурсивной)
  // В нашем случае используем последовательный вызов.

  return _qsync('nodes_$questId', () async {
    return _qsync('config_$questId', () async {
      try {
        List<dynamic> allNodesJson = [];
        List<dynamic> allGroupsJson = [];
        List<dynamic> allCommentsJson = [];
        Set<String> nodesToDeleteIds = {};

        {
          final nodesData = await QuestNodesStore.read(questId);
          allNodesJson = (nodesData['nodes'] as List<dynamic>? ?? []).toList();
          allGroupsJson = (nodesData['groups'] as List<dynamic>? ?? [])
              .toList();
          allCommentsJson = (nodesData['comments'] as List<dynamic>? ?? [])
              .toList();

          nodesToDeleteIds = allNodesJson
              .where(
                (node) => (node as Map<String, dynamic>)['chapterId'] == tagId,
              )
              .map((node) => (node as Map<String, dynamic>)['id'] as String)
              .toSet();
          allNodesJson.removeWhere(
            (node) =>
                nodesToDeleteIds.contains((node as Map<String, dynamic>)['id']),
          );
          allGroupsJson.removeWhere(
            (group) => (group as Map<String, dynamic>)['chapterId'] == tagId,
          );
          allCommentsJson.removeWhere(
            (comment) =>
                (comment as Map<String, dynamic>)['chapterId'] == tagId,
          );

          await QuestNodesStore.write(questId, {
            'nodes': allNodesJson,
            'groups': allGroupsJson,
            'comments': allCommentsJson,
          });
        }

        final configPath = QuestPaths.config(questId);
        final config = await _readMap(configPath);

        final tagsJson = (config['tags'] as List<dynamic>? ?? []).toList();
        tagsJson.removeWhere(
          (tag) => (tag as Map<String, dynamic>)['id'] == tagId,
        );

        final connectionsJson = (config['connections'] as List<dynamic>? ?? [])
            .toList();
        if (nodesToDeleteIds.isNotEmpty) {
          connectionsJson.removeWhere((conn) {
            final connMap = conn as Map<String, dynamic>;
            return nodesToDeleteIds.contains(connMap['fromId']) ||
                nodesToDeleteIds.contains(connMap['toId']);
          });
        }

        await (await _qs()).writeJson(configPath, {
          ...config,
          'tags': tagsJson,
          'connections': connectionsJson,
        });

        return true;
      } catch (e) {
        print('❌ Ошибка удаления тега: $e');
        return false;
      }
    });
  });
}

dynamic _remapCopiedNodeRefs(dynamic value, Map<String, String> nodeIdRemap) {
  if (value is Map) {
    final map = Map<String, dynamic>.from(value);
    map.updateAll((key, currentValue) {
      if ((key == 'targetNodeId' || key == 'defaultActionNodeId') &&
          currentValue is String &&
          nodeIdRemap.containsKey(currentValue)) {
        return nodeIdRemap[currentValue]!;
      }
      return _remapCopiedNodeRefs(currentValue, nodeIdRemap);
    });
    return map;
  }

  if (value is List) {
    return value
        .map((item) => _remapCopiedNodeRefs(item, nodeIdRemap))
        .toList();
  }

  return value;
}

// Функция для обновления данных тега
Future<bool> updateTagName(
  String questId,
  String tagId,
  String newName, {
  String? backgroundAudioId,
  String? backgroundAssetId,
  String? folderPath,
}) async {
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
      tagMap['name'] = newName;

      if (backgroundAudioId != null) {
        tagMap['backgroundAudioId'] = backgroundAudioId;
      } else {
        tagMap.remove('backgroundAudioId');
      }

      if (backgroundAssetId != null) {
        tagMap['backgroundAssetId'] = backgroundAssetId;
      } else {
        tagMap.remove('backgroundAssetId');
      }

      if (folderPath != null) {
        final normalized = Tag.normalizeFolderPath(folderPath);
        if (normalized == '/') {
          tagMap.remove('folderPath');
        } else {
          tagMap['folderPath'] = normalized;
        }
      }

      tagsJson[tagIndex] = tagMap;

      await (await _qs()).writeJson(configPath, {...config, 'tags': tagsJson});
      return true;
    } catch (e) {
      print('❌ Ошибка обновления тега: $e');
      return false;
    }
  });
}

// Дублирование тега
Future<bool> duplicateTag(String questId, String originalTagId) async {
  return _qsync('nodes_$questId', () async {
    return _qsync('config_$questId', () async {
      try {
        // 1. Читаем конфиг
        final configPath = QuestPaths.config(questId);
        final config = await _readMap(configPath);
        final tagsJson = (config['tags'] as List<dynamic>? ?? []).toList();

        // 2. Находим исходный тег
        final originalTagMap = tagsJson.firstWhere(
          (t) => t['id'] == originalTagId,
          orElse: () => null,
        );
        if (originalTagMap == null) return false;

        // 3. Создаем новый тег
        final newTagId = const Uuid().v4();
        final newTagName = trf('{p0} (Копия)', {'p0': originalTagMap['name']});

        final newTagMap = Map<String, dynamic>.from(originalTagMap as Map);
        newTagMap['id'] = newTagId;
        newTagMap['name'] = newTagName;

        tagsJson.add(newTagMap);
        final connectionsJson = (config['connections'] as List<dynamic>? ?? [])
            .toList();
        final nodeIdRemap = <String, String>{};
        final copiedNodeMaps = <Map<String, dynamic>>[];

        // 4. Дублируем ноды
        {
          final nodesData = await QuestNodesStore.read(questId);
          final nodesList = (nodesData['nodes'] as List<dynamic>? ?? [])
              .toList();

          final nodesToCopy = nodesList.where((n) {
            final nodeChapterId = (n as Map<String, dynamic>)['chapterId'];
            // Используем toString() для безопасного сравнения
            return nodeChapterId?.toString() == originalTagId;
          }).toList();

          for (final nodeMap in nodesToCopy) {
            final newNodeMap = Map<String, dynamic>.from(nodeMap as Map);
            final oldNodeId = newNodeMap['id']?.toString();
            newNodeMap['id'] = const Uuid().v4();
            newNodeMap['chapterId'] = newTagId;
            if (oldNodeId != null && oldNodeId.isNotEmpty) {
              nodeIdRemap[oldNodeId] = newNodeMap['id'].toString();
            }
            copiedNodeMaps.add(newNodeMap);
            nodesList.add(newNodeMap);
          }

          for (final copiedNode in copiedNodeMaps) {
            final remapped = _remapCopiedNodeRefs(copiedNode, nodeIdRemap);
            copiedNode
              ..clear()
              ..addAll(Map<String, dynamic>.from(remapped as Map));
          }

          final groupsList = (nodesData['groups'] as List<dynamic>? ?? [])
              .toList();
          final groupsToCopy = groupsList.where((g) {
            final groupChapterId = (g as Map<String, dynamic>)['chapterId'];
            return groupChapterId?.toString() == originalTagId;
          }).toList();
          for (final groupMap in groupsToCopy) {
            final newGroupMap = Map<String, dynamic>.from(groupMap as Map);
            newGroupMap['id'] = const Uuid().v4();
            newGroupMap['chapterId'] = newTagId;
            groupsList.add(newGroupMap);
          }

          final commentsList = (nodesData['comments'] as List<dynamic>? ?? [])
              .toList();
          final commentsToCopy = commentsList.where((c) {
            final commentChapterId = (c as Map<String, dynamic>)['chapterId'];
            return commentChapterId?.toString() == originalTagId;
          }).toList();
          for (final commentMap in commentsToCopy) {
            final newCommentMap = Map<String, dynamic>.from(commentMap as Map);
            newCommentMap['id'] = const Uuid().v4();
            newCommentMap['chapterId'] = newTagId;
            commentsList.add(newCommentMap);
          }

          await QuestNodesStore.write(questId, {
            'nodes': nodesList,
            'groups': groupsList,
            'comments': commentsList,
          });
        }

        if (nodeIdRemap.isNotEmpty) {
          final copiedConnections = <Map<String, dynamic>>[];
          for (final rawConn in connectionsJson) {
            if (rawConn is! Map) continue;
            final conn = Map<String, dynamic>.from(rawConn);
            final fromId = conn['fromId']?.toString();
            final toId = conn['toId']?.toString();
            if (fromId == null || toId == null) continue;

            final mappedFromId = nodeIdRemap[fromId];
            final mappedToId = nodeIdRemap[toId];
            if (mappedFromId == null || mappedToId == null) continue;

            copiedConnections.add({
              ...conn,
              'id': const Uuid().v4(),
              'fromId': mappedFromId,
              'toId': mappedToId,
            });
          }
          if (copiedConnections.isNotEmpty) {
            connectionsJson.addAll(copiedConnections);
          }
        }

        // 5. Сохраняем конфиг
        await (await _qs()).writeJson(configPath, {
          ...config,
          'tags': tagsJson,
          'connections': connectionsJson,
        });
        return true;
      } catch (e) {
        print('❌ Ошибка дублирования тега: $e');
        return false;
      }
    });
  });
}

/// Очистка нод без chapterId (исправление бага после копирования главы)
/// Возвращает количество удалённых нод
Future<int> cleanupNodesWithoutChapter(String questId) async {
  return _qsync('nodes_$questId', () async {
    try {
      final nodesData = await QuestNodesStore.read(questId);
      final nodesList = (nodesData['nodes'] as List<dynamic>? ?? []).toList();

      // Находим ноды без chapterId или с пустым chapterId
      final invalidNodes = nodesList.where((n) {
        final nodeMap = n as Map<String, dynamic>;
        final chapterId = nodeMap['chapterId'];
        return chapterId == null || chapterId.toString().trim().isEmpty;
      }).toList();

      if (invalidNodes.isEmpty) {
        return 0;
      }

      // Удаляем ноды без chapterId
      final validNodes = nodesList.where((n) {
        final nodeMap = n as Map<String, dynamic>;
        final chapterId = nodeMap['chapterId'];
        return chapterId != null && chapterId.toString().trim().isNotEmpty;
      }).toList();

      // Перезаписываем файл целиком, поэтому сохраняем все секции, а не только
      // nodes: группы и комментарии живут в том же nodes.json.
      await QuestNodesStore.write(questId, {...nodesData, 'nodes': validNodes});

      // Также нужно удалить связи (connections) с удалёнными нодами
      final configPath = QuestPaths.config(questId);
      if (await (await _qs()).exists(configPath)) {
        final config = await _readMap(configPath);
        final connectionsJson = (config['connections'] as List<dynamic>? ?? [])
            .toList();

        final invalidNodeIds = invalidNodes
            .map((n) => (n as Map<String, dynamic>)['id']?.toString())
            .whereType<String>()
            .toSet();

        if (invalidNodeIds.isNotEmpty) {
          connectionsJson.removeWhere((conn) {
            final connMap = conn as Map<String, dynamic>;
            return invalidNodeIds.contains(connMap['fromId']) ||
                invalidNodeIds.contains(connMap['toId']);
          });

          await (await _qs()).writeJson(configPath, {
            ...config,
            'connections': connectionsJson,
          });
        }
      }

      print('✅ [Cleanup] Удалено ${invalidNodes.length} нод без chapterId');
      return invalidNodes.length;
    } catch (e) {
      print('❌ [Cleanup] Ошибка очистки нод: $e');
      return 0;
    }
  });
}
