// Карточка ноды на канвасе обязана показывать содержимое без чтения тел.
//
// Канвас строится из `nodes/index.json`, где `content` нет — только сводка
// с готовым `preview`. Тест держит сквозной путь: монолит на диске → индекс
// → `tagNodesProvider` → `Node.textLines`. Если превью потеряется по дороге,
// карточки снова станут пустыми.

import 'dart:io';

import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

const String _questId = '33333333-3333-4333-8333-333333333333';
const String _chapterId = 'chapter-1';
const String _nodeId = 'node-a';
const String _targetNodeId = 'node-b';

const Map<String, dynamic> _content = {
  'items': [
    {
      'type': 'row',
      'children': [
        {'type': 'text', 'text': 'Улица. Возле дома'},
        {'type': 'chat', 'senderName': 'Мира', 'text': 'Ты опоздал'},
      ],
    },
    {
      'type': 'column',
      'children': [
        {'type': 'button', 'text': 'Постучать'},
        {'type': 'button', 'text': 'Уйти'},
      ],
    },
  ],
};

Future<void> _writeNodes() => FileStorage.writeJsonFile(
  QuestPaths.nodesLegacy(_questId),
  {
    'nodes': [
      {
        'id': _nodeId,
        'chapterId': _chapterId,
        'title': 'Улица',
        'x': 100.0,
        'y': 100.0,
        'content': _content,
      },
      {
        'id': _targetNodeId,
        'chapterId': _chapterId,
        'title': 'Дом',
        'x': 400.0,
        'y': 100.0,
        'content': {
          'items': [
            {'type': 'text', 'text': 'Дверь открыта'},
          ],
        },
      },
    ],
    'groups': [],
    'comments': [],
  },
);

Future<CanvasNotifier> _openCanvas(ProviderContainer container) async {
  final notifier = container.read(
    canvasProvider((_questId, _chapterId)).notifier,
  );
  for (var i = 0; i < 100 && notifier.state.isLoading; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(notifier.state.isLoading, isFalse);
  expect(notifier.state.nodes, hasLength(2));
  return notifier;
}

void main() {
  late Directory appDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_canvas_preview_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return appDir.path;
          }
          return null;
        });

    await FileStorage.writeJsonFile(QuestPaths.config(_questId), {
      'id': _questId,
      'title': 'Тестовый квест',
      'startNodeId': _nodeId,
      'tags': [
        {'id': _chapterId, 'name': 'Глава 1'},
      ],
      'connections': [],
    });
    await _writeNodes();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('карточка из индекса показывает реплики, ветки и сводку', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final canvas = await _openCanvas(container);
    final node = canvas.state.nodes.firstWhere((n) => n.id == _nodeId);

    expect(node.content?['items'], isEmpty, reason: 'тело ноды не читается');
    expect(node.textLines, ['Улица. Возле дома', 'Мира: Ты опоздал']);
    expect(node.branchLabels, ['Постучать', 'Уйти']);
    expect(node.countersLabel, '2 реплики · 2 ветки');
  });

  test('связь на канвасе сохраняет реплики ноды-источника', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final canvas = await _openCanvas(container);
    canvas.startConnection(_nodeId);
    await canvas.endConnection(_targetNodeId);

    final data = await FileStorage.readJsonFile(
      QuestPaths.nodesLegacy(_questId),
    );
    final nodes = (data['nodes'] as List? ?? []).cast<Map<String, dynamic>>();
    final source = nodes.firstWhere((n) => n['id'] == _nodeId);
    final types = <String>[];
    void walk(List<dynamic> items) {
      for (final raw in items) {
        final item = raw as Map;
        types.add(item['type'] as String);
        final children = item['children'];
        if (children is List) walk(children);
      }
    }

    walk(source['content']['items'] as List);

    expect((source['content']['items'] as List), hasLength(3));
    expect(types, contains('text'), reason: 'реплики ноды не должны исчезнуть');
    expect(types, contains('button'));
    expect(source['content']['cardPreview'], isNull);
  });

  test('служебное превью не попадает в тело ноды при сохранении', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final canvas = await _openCanvas(container);
    await canvas.addNode(const Size(900, 700));

    final data = await FileStorage.readJsonFile(
      QuestPaths.nodesLegacy(_questId),
    );
    final nodes = (data['nodes'] as List? ?? []).cast<Map<String, dynamic>>();
    for (final node in nodes) {
      expect(
        node['content']?['cardPreview'],
        isNull,
        reason: 'cardPreview — служебный ключ индекса, не контент ноды',
      );
    }
  });
}