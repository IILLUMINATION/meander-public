import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('mnd_nodes_store_');
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

  Future<File> nodesFile(String questId, {required bool canonical}) async {
    final dir = Directory(
      '${temp.path}/quests/$questId${canonical ? '/nodes' : ''}',
    )..createSync(recursive: true);
    return File('${dir.path}/nodes.json');
  }

  Future<void> writeNodes(
    String questId,
    Map<String, dynamic> data, {
    required bool canonical,
  }) async {
    final file = await nodesFile(questId, canonical: canonical);
    file.writeAsStringSync(jsonEncode(data));
    FileStorage.invalidateJsonCache([
      'quests/$questId/nodes.json',
      'quests/$questId/nodes/nodes.json',
    ]);
  }

  Map<String, dynamic> doc(List<String> ids) => {
    'nodes': [
      for (final id in ids) {'id': id, 'title': id},
    ],
    'groups': <dynamic>[],
    'comments': <dynamic>[],
  };

  test('legacy-only квест мигрирует в canonical', () async {
    const q = 'legacy-only';
    await writeNodes(q, doc(['a']), canonical: false);

    final data = await QuestNodesStore.read(q);

    expect((data['nodes'] as List).length, 1);
    expect(await nodesFile(q, canonical: true).then((f) => f.exists()), isTrue);
  });

  test('canonical-only квест мигрирует в legacy', () async {
    const q = 'canonical-only';
    await writeNodes(q, doc(['b']), canonical: true);

    final data = await QuestNodesStore.read(q);

    expect((data['nodes'] as List).length, 1);
    expect(
      await nodesFile(q, canonical: false).then((f) => f.exists()),
      isTrue,
    );
  });

  test('пустой legacy не затирает непустой canonical', () async {
    const q = 'empty-legacy';
    await writeNodes(q, doc([]), canonical: false);
    await writeNodes(q, doc(['c']), canonical: true);

    final data = await QuestNodesStore.read(q);

    expect((data['nodes'] as List).single['id'], 'c');
    final legacy = await nodesFile(q, canonical: false);
    expect(jsonDecode(legacy.readAsStringSync())['nodes'], hasLength(1));
  });

  test('при расхождении выбирается более свежий файл', () async {
    const q = 'newer-wins';
    await writeNodes(q, doc(['old']), canonical: true);
    await writeNodes(q, doc(['new']), canonical: false);
    final legacy = await nodesFile(q, canonical: false);
    legacy.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));

    final data = await QuestNodesStore.read(q);

    expect((data['nodes'] as List).single['id'], 'new');
    final canonical = await nodesFile(q, canonical: true);
    expect(
      jsonDecode(canonical.readAsStringSync())['nodes'].single['id'],
      'new',
    );
  });

  test('write пишет обе копии', () async {
    const q = 'write-both';
    await QuestNodesStore.write(q, doc(['x', 'y']));

    final legacy = await nodesFile(q, canonical: false);
    final canonical = await nodesFile(q, canonical: true);
    expect(jsonDecode(legacy.readAsStringSync())['nodes'], hasLength(2));
    expect(jsonDecode(canonical.readAsStringSync())['nodes'], hasLength(2));
  });
}
