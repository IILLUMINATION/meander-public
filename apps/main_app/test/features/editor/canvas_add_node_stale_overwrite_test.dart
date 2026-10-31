// Инвариант: канвас владеет геометрией нод, но не их контентом.
//
// Любое сохранение канваса переписывает всю главу, поэтому правку, которую
// редактор ноды только что положил на диск, откатывать нельзя. Защита с двух
// сторон: канвас подписан на tagNodesProvider (свежее состояние приезжает с
// диска) и перед записью перечитает сохранённые ноды (_persistedNodesById).
// Тест держит результат, а не механизм: падает, если убрать обе защиты.
import 'dart:io';

import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

const String _questId = '22222222-2222-4222-8222-222222222222';
const String _chapterId = 'chapter-1';
const String _nodeId = 'node-a';

const Map<String, dynamic> _oldItem = {
  'id': 'item-old',
  'type': 'text',
  'content': 'Было',
};

/// То, что пишет редактор ноды, пока канвас держит старый снимок.
const Map<String, dynamic> _newItem = {
  'id': 'item-new',
  'type': 'script',
  'resourcePath': 'scripts/open-door.json',
};

Future<void> _writeNodes({required List<Map<String, dynamic>> items}) =>
    FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
      'nodes': [
        {
          'id': _nodeId,
          'chapterId': _chapterId,
          'title': 'Нода A',
          'x': 100.0,
          'y': 100.0,
          'content': {'items': items},
        },
      ],
      'groups': [],
      'comments': [],
    });

Future<List<String>> _itemIdsOnDisk() async {
  final data = await FileStorage.readJsonFile(QuestPaths.nodesLegacy(_questId));
  final nodes = (data['nodes'] as List? ?? []).cast<Map<String, dynamic>>();
  final node = nodes.firstWhere((n) => n['id'] == _nodeId);
  final items = (node['content']?['items'] as List? ?? []).cast<Map>();
  return items.map((item) => item['id'].toString()).toList();
}

Future<CanvasNotifier> _openCanvas(ProviderContainer container) async {
  final notifier = container.read(
    canvasProvider((_questId, _chapterId)).notifier,
  );
  for (var i = 0; i < 100 && notifier.state.isLoading; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(notifier.state.isLoading, isFalse);
  expect(notifier.state.nodes, hasLength(1));
  return notifier;
}

void main() {
  late Directory appDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_canvas_stale_test');
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
    await _writeNodes(items: [_oldItem]);
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test(
    'свежая правка соседней ноды не затирается при добавлении ноды',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final canvas = await _openCanvas(container);

      // Пользователь отредактировал ноду A и вернулся на канвас: редактор ноды
      // пишет на диск и сбрасывает кэш нод (node_content_screen.dart:509).
      await _writeNodes(items: [_oldItem, _newItem]);
      container.invalidate(allQuestNodesProvider(_questId));
      expect(
        (canvas.state.nodes.single.content?['items'] as List? ?? const []),
        isEmpty,
        reason: 'канвас строится из index без тел нод',
      );

      await canvas.addNode(const Size(900, 700));

      expect(await _itemIdsOnDisk(), containsAll(['item-old', 'item-new']));
    },
  );

  test('позиция новой ноды доходит до диска', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final canvas = await _openCanvas(container);

    await canvas.addNode(const Size(900, 700));

    final data = await FileStorage.readJsonFile(
      QuestPaths.nodesLegacy(_questId),
    );
    final nodes = (data['nodes'] as List? ?? []).cast<Map<String, dynamic>>();
    expect(nodes, hasLength(2));
    final added = nodes.firstWhere((n) => n['id'] != _nodeId);
    expect(added['chapterId'], _chapterId);
    expect((added['x'] as num).toDouble(), greaterThan(0));
  });

  // Регресс на «видео на фоне сбрасывается»: канвас переписывает всю главу
  // своим снимком ноды. Если снимок перечисляет поля вручную, то новое поле
  // модели в него не попадает, а saveNodes вычищает отсутствующий ключ из
  // файла — настройка автора умирает при первом же действии на канвасе.
  test(
    'настройки фона и вёрстки ноды не стираются сохранением канваса',
    () async {
      await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
        'nodes': [
          {
            'id': _nodeId,
            'chapterId': _chapterId,
            'title': 'Нода A',
            'x': 100.0,
            'y': 100.0,
            'content': {
              'items': [_oldItem],
            },
            'backgroundAssetId': 'res/images/still.png',
            'backgroundVideoAssetId': 'res/images/intro.mp4',
            'backgroundVideoFit': 'cover',
            'backgroundVideoMuted': true,
            'backgroundBlur': 12.0,
            'itemSpacing': 8.0,
            'transitionMode': 'fade',
            'allowSave': false,
          },
        ],
        'groups': [],
        'comments': [],
      });
      FileStorage.invalidateJsonCache([QuestPaths.nodesLegacy(_questId)]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final canvas = await _openCanvas(container);

      await canvas.addNode(const Size(900, 700));

      final data = await FileStorage.readJsonFile(
        QuestPaths.nodesLegacy(_questId),
      );
      final nodes = (data['nodes'] as List? ?? []).cast<Map<String, dynamic>>();
      final saved = nodes.firstWhere((n) => n['id'] == _nodeId);
      for (final key in const [
        'backgroundAssetId',
        'backgroundVideoAssetId',
        'backgroundVideoFit',
        'backgroundVideoMuted',
        'backgroundBlur',
        'itemSpacing',
        'transitionMode',
        'allowSave',
      ]) {
        expect(saved[key], isNotNull, reason: '$key стёрт сохранением канваса');
      }
      expect(saved['backgroundVideoAssetId'], 'res/images/intro.mp4');
      expect(saved['backgroundBlur'], 12.0);
      expect(saved['transitionMode'], 'fade');
    },
  );
}
