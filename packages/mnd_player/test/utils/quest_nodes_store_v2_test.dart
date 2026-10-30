import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('mnd_nodes_v2_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => temp.path);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  setUp(() {
    FileStorage.invalidateJsonCache(const []);
  });

  Map<String, dynamic> doc() => {
    'nodes': [
      {
        'id': 'n1',
        'title': 'A',
        'chapterId': 'ch',
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
        'title': 'B',
        'chapterId': 'ch',
        'x': 30.0,
        'y': 40.0,
        'content': {
          'items': [
            {'type': 'text', 'text': 'Привет'},
          ],
        },
      },
    ],
    'groups': [
      {'id': 'g1', 'chapterId': 'ch'},
    ],
    'comments': [
      {'id': 'c1', 'chapterId': 'ch'},
    ],
  };

  File file(String rel) => File('${temp.path}/$rel');

  Future<void> seedLegacy(String questId) async {
    await QuestNodesStore.write(questId, doc());
    FileStorage.invalidateJsonCache([
      QuestPaths.nodesLegacy(questId),
      QuestPaths.nodesCanonical(questId),
    ]);
  }

  test('readIndex на монолите не создаёт индекс', () async {
    const q = 'v1-readonly';
    await seedLegacy(q);

    final index = await QuestNodesStore.readIndex(q);

    expect(index[QuestNodesStore.formatVersionKey], 2);
    expect(index['nodes'], hasLength(2));
    expect(file(QuestPaths.nodesIndex(q)).existsSync(), isFalse);
  });

  test('миграция раскладывает ноды и оставляет legacy', () async {
    const q = 'migrate';
    await seedLegacy(q);

    expect(await QuestNodesStore.migrateToPerNode(q), isTrue);

    final legacy = file(QuestPaths.nodesLegacy(q));
    final canonical = file(QuestPaths.nodesCanonical(q));
    final indexFile = file(QuestPaths.nodesIndex(q));
    expect(legacy.existsSync(), isTrue);
    expect(canonical.existsSync(), isTrue);
    expect(indexFile.existsSync(), isTrue);
    expect(file(QuestPaths.nodesMigrationBackup(q)).existsSync(), isTrue);
    expect(file(QuestPaths.nodeBody(q, 'n1')).existsSync(), isTrue);
    expect(file(QuestPaths.nodeBody(q, 'n2')).existsSync(), isTrue);

    final index = jsonDecode(indexFile.readAsStringSync()) as Map;
    final n1 = (index['nodes'] as List).first as Map;
    expect(n1['title'], 'A');
    expect(n1['x'], 10.0);
    expect(n1.containsKey('content'), isFalse);
    expect(n1['type'], 'node');
    expect(
      (index['edges'] as List).any(
        (e) => e['from'] == 'n1' && e['to'] == 'n2' && e['kind'] == 'content',
      ),
      isTrue,
    );
    expect(index['groups'], hasLength(1));
    expect(index['comments'], hasLength(1));

    final body =
        jsonDecode(file(QuestPaths.nodeBody(q, 'n1')).readAsStringSync())
            as Map;
    expect(body['content']['items'], hasLength(1));
    expect(
      await QuestNodesStore.migrateToPerNode(q),
      isFalse,
      reason: 'повторная миграция не должна перезаписывать',
    );
  });

  test('readNode отдаёт тело, readAll собирает документ', () async {
    const q = 'read';
    await seedLegacy(q);
    await QuestNodesStore.migrateToPerNode(q);

    final node = await QuestNodesStore.readNode(q, 'n2');
    expect(node!['content']['items'].first['text'], 'Привет');

    final viaRead = await QuestNodesStore.read(q);
    expect(viaRead['nodes'], hasLength(2));

    final all = await QuestNodesStore.readAll(q);
    expect(all['nodes'], hasLength(2));
    expect(all['groups'], hasLength(1));
    expect(all['comments'], hasLength(1));
    expect(
      (all['nodes'] as List).firstWhere((n) => n['id'] == 'n2')['content'],
      isNotNull,
    );
  });

  test('writeNode обновляет только свою ноду и её рёбра', () async {
    const q = 'write-node';
    await seedLegacy(q);
    await QuestNodesStore.migrateToPerNode(q);

    final changed = {
      'id': 'n2',
      'title': 'B2',
      'chapterId': 'ch',
      'x': 99.0,
      'y': 88.0,
      'content': {
        'items': [
          {'type': 'go_to_node', 'targetNodeId': 'n1'},
        ],
      },
    };
    await QuestNodesStore.writeNode(q, changed);

    final index = await QuestNodesStore.readIndex(q);
    final n2 = (index['nodes'] as List).firstWhere((n) => n['id'] == 'n2');
    expect(n2['title'], 'B2');
    expect(n2['x'], 99.0);
    expect(n2.containsKey('content'), isFalse);
    expect(
      (index['edges'] as List).any((e) => e['from'] == 'n2' && e['to'] == 'n1'),
      isTrue,
    );
    expect(
      (index['edges'] as List).any((e) => e['from'] == 'n2' && e['to'] == 'n2'),
      isFalse,
    );

    final body = await QuestNodesStore.readNode(q, 'n2');
    expect(body!['content']['items'].first['targetNodeId'], 'n1');
  });

  test('deleteNode убирает тело и рёбра', () async {
    const q = 'delete';
    await seedLegacy(q);
    await QuestNodesStore.migrateToPerNode(q);

    await QuestNodesStore.deleteNode(q, 'n2');

    expect(file(QuestPaths.nodeBody(q, 'n2')).existsSync(), isFalse);
    final index = await QuestNodesStore.readIndex(q);
    expect((index['nodes'] as List), hasLength(1));
    expect(
      (index['edges'] as List).any((e) => e['from'] == 'n2' || e['to'] == 'n2'),
      isFalse,
    );
  });

  test('полная запись синхронизирует per-node индекс и тела', () async {
    const q = 'full-write-after-migrate';
    await seedLegacy(q);
    await QuestNodesStore.migrateToPerNode(q);

    final next = doc();
    (next['nodes'] as List).removeLast();
    ((next['nodes'] as List).first as Map)['title'] = 'A2';
    await QuestNodesStore.write(q, next);

    final index = await QuestNodesStore.readIndex(q);
    expect((index['nodes'] as List), hasLength(1));
    expect((index['nodes'] as List).first['title'], 'A2');
    expect(file(QuestPaths.nodeBody(q, 'n2')).existsSync(), isFalse);
    final n1 = await QuestNodesStore.readNode(q, 'n1');
    expect(n1!['title'], 'A2');
  });

  test('readAll добирает отсутствующее тело из legacy', () async {
    const q = 'missing-body';
    await seedLegacy(q);
    await QuestNodesStore.migrateToPerNode(q);
    file(QuestPaths.nodeBody(q, 'n1')).deleteSync();

    final all = await QuestNodesStore.readAll(q);
    final n1 = (all['nodes'] as List).firstWhere((n) => n['id'] == 'n1');
    expect(n1['content']['items'], hasLength(1));
  });
}
