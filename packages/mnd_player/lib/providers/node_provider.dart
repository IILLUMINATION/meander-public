import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

final allQuestNodesProvider = FutureProvider.autoDispose
    .family<List<SavedNode>, String>((ref, questId) async {
      return FileStorage.synchronized('nodes_$questId', () async {
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
