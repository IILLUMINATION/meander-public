import 'dart:io';

import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

const String _questId = '44444444-4444-4444-8444-444444444444';
const String _chapterId = 'chapter-1';

Future<void> _seed() async {
  await FileStorage.writeJsonFile(QuestPaths.config(_questId), {
    'id': _questId,
    'title': 'V2',
    'startNodeId': 'n1',
    'tags': [
      {'id': _chapterId, 'name': 'Глава 1'},
    ],
    'connections': <dynamic>[],
  });
  await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
    'nodes': [
      {
        'id': 'n1',
        'chapterId': _chapterId,
        'title': 'A',
        'x': 10.0,
        'y': 20.0,
        'content': {
          'items': [
            {'type': 'go_to_node', 'targetNodeId': 'n2'},
          ],
        },
      },
      {
        'id': 'n2',
        'chapterId': _chapterId,
        'title': 'B',
        'x': 30.0,
        'y': 40.0,
        'content': {
          'items': [
            {'type': 'text', 'text': 'старое'},
          ],
        },
      },
    ],
    'groups': <dynamic>[],
    'comments': <dynamic>[],
  });
  FileStorage.invalidateJsonCache([
    QuestPaths.config(_questId),
    QuestPaths.nodesLegacy(_questId),
  ]);
  await QuestNodesStore.ensurePerNode(_questId);
}

void main() {
  late Directory appDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_per_node_editor');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? appDir.path
              : null,
        );
    await _seed();
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('канвас читает index, нода сохраняется точечно', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(
      canvasProvider((_questId, _chapterId)).notifier,
    );
    for (var i = 0; i < 100 && notifier.state.isLoading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(notifier.state.nodes, hasLength(2));
    expect(notifier.state.connections, hasLength(1));
    expect(notifier.state.nodes.first.content?['items'], isEmpty);

    final body = await QuestNodesStore.readNode(_questId, 'n2');
    final updated = SavedNode.fromJson({
      ...body!,
      'title': 'B2',
      'content': {
        'items': [
          {'type': 'text', 'text': 'новое'},
        ],
      },
    });
    expect(await saveNodes(_questId, [updated]), isTrue);

    final savedBody = await QuestNodesStore.readNode(_questId, 'n2');
    expect(savedBody!['title'], 'B2');
    expect(savedBody['content']['items'].first['text'], 'новое');
    final index = await QuestNodesStore.readIndex(_questId);
    final summary = (index['nodes'] as List).firstWhere((n) => n['id'] == 'n2');
    expect(summary['title'], 'B2');
    expect(summary.containsKey('content'), isFalse);

    // Соседняя нода не перезаписана.
    final n1 = await QuestNodesStore.readNode(_questId, 'n1');
    expect(n1!['content']['items'], hasLength(1));
  });

  test('удаление ноды чистит тело, индекс и связи', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(canvasProvider((_questId, _chapterId)));

    expect(await deleteNode(_questId, 'n2'), isTrue);

    expect(
      File(
        '${appDir.path}/${QuestPaths.nodeBody(_questId, 'n2')}',
      ).existsSync(),
      isFalse,
    );
    final index = await QuestNodesStore.readIndex(_questId);
    expect((index['nodes'] as List), hasLength(1));
    expect(
      (index['edges'] as List).any((e) => e['from'] == 'n1' && e['to'] == 'n2'),
      isFalse,
    );
    final config = await FileStorage.readJsonFile(QuestPaths.config(_questId));
    expect(
      (config['connections'] as List?)?.any(
        (c) => c['fromId'] == 'n2' || c['toId'] == 'n2',
      ),
      isFalse,
    );
  });

  test('сохранение раскладки канваса не трогает content', () async {
    final body = await QuestNodesStore.readNode(_questId, 'n2');
    final moved = SavedNode.fromJson({...body!, 'x': 111.0, 'y': 222.0});

    expect(
      await saveCanvasData(
        _questId,
        nodes: [moved],
        chapterId: _chapterId,
        groups: const [],
        comments: const [],
      ),
      isTrue,
    );

    final index = await QuestNodesStore.readIndex(_questId);
    final summary = (index['nodes'] as List).firstWhere((n) => n['id'] == 'n2');
    expect(summary['x'], 111.0);
    final savedBody = await QuestNodesStore.readNode(_questId, 'n2');
    expect(savedBody!['x'], 111.0);
    expect(savedBody['content']['items'].first['text'], 'старое');
  });
}
