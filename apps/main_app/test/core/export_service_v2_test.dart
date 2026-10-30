import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

const _questId = '55555555-5555-4555-8555-555555555555';

void main() {
  late Directory appDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_export_v2');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? appDir.path
              : null,
        );

    await FileStorage.writeJsonFile(QuestPaths.config(_questId), {
      'id': _questId,
      'title': 'V2 export',
      'startNodeId': 'n1',
      'tags': <dynamic>[],
      'connections': <dynamic>[],
    });
    await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
      'nodes': [
        {
          'id': 'n1',
          'chapterId': 'c1',
          'title': 'A',
          'x': 1.0,
          'y': 2.0,
          'content': {
            'items': [
              {'type': 'text', 'text': 'привет'},
            ],
          },
        },
        {
          'id': 'n2',
          'chapterId': 'c1',
          'title': 'B',
          'x': 3.0,
          'y': 4.0,
          'content': {'items': <dynamic>[]},
        },
      ],
      'groups': [
        {'id': 'g1', 'chapterId': 'c1'},
      ],
      'comments': [
        {'id': 'cm1', 'chapterId': 'c1'},
      ],
    });
    FileStorage.invalidateJsonCache(const []);
    await QuestNodesStore.ensurePerNode(_questId);
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('createMndFile собирает legacy nodes.json из v2', () async {
    final bytes = await ExportService.createMndFile(_questId);
    expect(utf8.decode(bytes.sublist(0, 8)), 'MND_ZIP_');

    final archive = ZipDecoder().decodeBytes(bytes.sublist(8));
    final entry = archive.files.firstWhere((f) => f.name == 'nodes.json');
    final decoded = jsonDecode(utf8.decode(entry.content as List<int>)) as Map;
    final nodes = (decoded['nodes'] as List).cast<Map>();
    expect(nodes, hasLength(2));
    expect(nodes.first['title'], 'A');
    expect(nodes.first['content']['items'].first['text'], 'привет');
    expect(decoded['groups'], hasLength(1));
    expect(decoded['comments'], hasLength(1));
    expect(archive.files.any((f) => f.name == 'nodes/index.json'), isFalse);
  });
}
