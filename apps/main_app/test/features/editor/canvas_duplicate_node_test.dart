// Дублирование ноды на канвасе — критичный путь редактора.
//
// Было сломано на всех квестах, переведённых на per-node хранение (а они
// переводятся сами при первом экспорте): `read` отдаёт типизированный
// `List<Map<String, dynamic>>`, а поиск по `firstWhere(orElse: () => null)`
// падал на рантайме. Ошибка глоталась в `catch` и возвращала `false`, то есть
// дублирование молча не работало. Тест держит результат: копия на диске, с
// новым id, в той же главе, со смещением, и канвас видит её после перезагрузки.

import 'dart:io';

import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

const String _questId = '44444444-4444-4444-8444-444444444444';
const String _chapterId = 'chapter-1';
const String _nodeId = 'node-a';

Future<void> _seed() async {
  await FileStorage.writeJsonFile(QuestPaths.config(_questId), {
    'id': _questId,
    'title': 'Тест дублирования',
    'startNodeId': _nodeId,
    'tags': [
      {'id': _chapterId, 'name': 'Глава 1'},
    ],
    'connections': [],
  });
  await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
    'nodes': [
      {
        'id': _nodeId,
        'chapterId': _chapterId,
        'title': 'Нода A',
        'x': 100.0,
        'y': 100.0,
        'content': {
          'items': [
            {'id': 'item-1', 'type': 'text', 'content': 'Привет'},
          ],
        },
      },
    ],
    'groups': [],
    'comments': [],
  });
}

Future<List<Map<String, dynamic>>> _nodesOnDisk() async {
  final data = await QuestNodesStore.readAll(_questId);
  return (data['nodes'] as List? ?? [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

void main() {
  late Directory appDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_dup_test');
    // Корень хранилища кэшируется статически: без сброса второй кейс читал
    // бы файлы первого.
    QuestStore.resetDefaultInstanceForTest();
    FileStorage.overrideAppDirectory(appDir);
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return appDir.path;
          }
          return null;
        });
    await _seed();
  });

  tearDown(() async {
    FileStorage.overrideAppDirectory(null);
    QuestStore.resetDefaultInstanceForTest();
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('дублирование работает в монолитном формате', () async {
    expect(await duplicateNode(_questId, _nodeId), isNotNull);
    final nodes = await _nodesOnDisk();
    expect(nodes, hasLength(2));
    final copy = nodes.firstWhere((n) => n['id'] != _nodeId);
    expect(copy['id'], isNotEmpty, reason: 'у копии свой id, а не id оригинала');
    expect(copy['chapterId'], _chapterId);
    expect(copy['title'], contains('Копия'));
    expect((copy['x'] as num).toDouble(), 130.0);
    expect((copy['y'] as num).toDouble(), 130.0);
    expect(copy['content'], isNotNull, reason: 'контент копируется целиком');
  });

  test('дублирование работает в per-node формате и видно на канвасе', () async {
    // Именно это состояние у реальных квестов: индекс и тела по нодам.
    await QuestNodesStore.migrateToPerNode(_questId);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final canvas = container.read(
      canvasProvider((_questId, _chapterId)).notifier,
    );
    for (var i = 0; i < 100 && canvas.state.isLoading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(canvas.state.isLoading, isFalse);
    expect(canvas.state.nodes, hasLength(1));

    expect(await duplicateNode(_questId, _nodeId), isNotNull);
    await canvas.reloadData();

    expect(canvas.state.nodes, hasLength(2));
    final copy = canvas.state.nodes.firstWhere((n) => n.id != _nodeId);
    expect(copy.chapterId, _chapterId);
    expect(copy.label, contains('Копия'));
    expect(copy.position.dx, 130.0);
    expect(copy.position.dy, 130.0);

    final nodes = await _nodesOnDisk();
    expect(nodes, hasLength(2));
    expect(nodes.map((n) => n['id']).toSet(), hasLength(2));
  });

  test('несуществующая нода не ломает редактор', () async {
    expect(await duplicateNode(_questId, 'нет-такой'), isNull);
    expect(await _nodesOnDisk(), hasLength(1));
  });
}