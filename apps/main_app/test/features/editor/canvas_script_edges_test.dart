// Скриптовые связи (пунктир) обязаны появляться на канвасе.
//
// Регрессия: скан скриптов запускался только при непустом `scriptAssetId`, а
// ссылки на скрипт в реальных квестах живут в `content` (`type: script`,
// `scriptTriggers` на кнопках). В итоге скриптовые рёбра не считались вовсе и
// граф выглядел так, будто связей нет. Этот тест держит оба слабых места:
// запуск скана без `scriptAssetId` и чтение тел нод вместо summary индекса.

import 'dart:io';

import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/models/canvas_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

const String _questId = '55555555-5555-4555-8555-555555555555';
const String _chapterId = 'chapter-1';

Future<void> _seed() async {
  await FileStorage.writeJsonFile(QuestPaths.config(_questId), {
    'id': _questId,
    'title': 'Scripts',
    'startNodeId': 'n1',
    'tags': [
      {'id': _chapterId, 'name': 'Глава 1'},
    ],
    'connections': <dynamic>[],
  });
  // Индекс: только summary, без content — как его пишет per-node формат.
  await FileStorage.writeJsonFile(QuestPaths.nodesIndex(_questId), {
    'format_version': 2,
    'nodes': [
      {'id': 'n1', 'chapterId': _chapterId, 'title': 'A', 'x': 0.0, 'y': 0.0},
      {'id': 'n2', 'chapterId': _chapterId, 'title': 'B', 'x': 300.0, 'y': 0.0},
    ],
    'groups': <dynamic>[],
    'comments': <dynamic>[],
    'edges': <dynamic>[],
  });
  await FileStorage.writeJsonFile(QuestPaths.nodeBody(_questId, 'n1'), {
    'id': 'n1',
    'chapterId': _chapterId,
    'title': 'A',
    'x': 0.0,
    'y': 0.0,
    'content': {
      'items': [
        {
          'id': 'b1',
          'type': 'button',
          'text': 'Дальше',
          'scriptTriggers': {'onPress': 'scripts/s1.json'},
        },
      ],
    },
  });
  await FileStorage.writeJsonFile(QuestPaths.nodeBody(_questId, 'n2'), {
    'id': 'n2',
    'chapterId': _chapterId,
    'title': 'B',
    'x': 300.0,
    'y': 0.0,
    'content': {'items': <dynamic>[]},
  });
  await FileStorage.writeJsonFile(QuestPaths.scriptFile(_questId, 's1'), {
    'blocks': [
      {'type': 'go_to_node', 'node_id': 'n2'},
    ],
  });
  FileStorage.invalidateJsonCache([
    QuestPaths.config(_questId),
    QuestPaths.nodesIndex(_questId),
    QuestPaths.nodeBody(_questId, 'n1'),
    QuestPaths.nodeBody(_questId, 'n2'),
    QuestPaths.scriptFile(_questId, 's1'),
  ]);
}

void main() {
  late Directory appDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_canvas_scripts');
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
    try {
      if (appDir.existsSync()) await appDir.delete(recursive: true);
    } catch (_) {}
  });

  test('summary индекса знает, есть ли у ноды скрипты', () {
    bool? flag(Map<String, dynamic> content) =>
        QuestNodesStore.buildNodeSummary({
              'id': 'n',
              'content': content,
            })['hasScripts']
            as bool?;

    expect(
      flag({
        'items': [
          {
            'type': 'row',
            'children': [
              {
                'type': 'button',
                'scriptTriggers': {'onPress': 'scripts/a.json'},
              },
            ],
          },
        ],
      }),
      isTrue,
      reason: 'триггер во вложенном элементе тоже скрипт',
    );
    expect(
      flag({
        'items': [
          {'type': 'text', 'text': 'без скриптов'},
        ],
      }),
      isFalse,
    );
    expect(
      QuestNodesStore.buildNodeSummary({
        'id': 'n',
        'scriptAssetId': 'scripts/b.json',
      })['hasScripts'],
      isTrue,
    );
  });

  test('скрипт из scriptTriggers даёт пунктирную связь', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(
      canvasProvider((_questId, _chapterId)).notifier,
    );

    for (var i = 0; i < 200 && notifier.state.isLoading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (var i = 0; i < 300; i++) {
      if (notifier.state.connections.any(
        (c) => c.kind == ConnectionKind.script,
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final scripts = notifier.state.connections
        .where((c) => c.kind == ConnectionKind.script)
        .toList();
    expect(scripts, hasLength(1));
    expect(scripts.single.fromNode.id, 'n1');
    expect(scripts.single.toNode.id, 'n2');
    expect(scripts.single.isVirtual, isTrue);
    expect(
      notifier.state.connectionGeometries.containsKey(scripts.single.id),
      isTrue,
      reason: 'без геометрии связь не рисуется',
    );
  });
}
