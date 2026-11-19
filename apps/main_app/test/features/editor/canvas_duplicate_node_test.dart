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
    expect(
      copy['id'],
      isNotEmpty,
      reason: 'у копии свой id, а не id оригинала',
    );
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

  group('копия не делит id контента с оригиналом', () {
    // Скрипт адресует картинку по id айтема: движок пишет переопределение в
    // `_internal_item_sources` под этим id, и клиент находит его в любой ноде.
    // Пока копия носила те же id, «экипировать оружие» в копии меняло картинку
    // и в оригинале — сцена показывала одно оружие на две ноды.
    const weaponId = 'img';
    const rowId = 'row-1';

    Future<void> seedRichNode() async {
      await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
        'nodes': [
          {
            'id': _nodeId,
            'chapterId': _chapterId,
            'title': 'Оружие',
            'x': 0.0,
            'y': 0.0,
            'content': {
              'items': [
                {
                  'id': rowId,
                  'type': 'row',
                  'children': [
                    {
                      'id': weaponId,
                      'type': 'image',
                      'resourcePath': 'res/images/gun.png',
                    },
                    {
                      'id': 'btn-equip',
                      'type': 'button',
                      'text': 'Экипировать',
                    },
                  ],
                },
                {
                  'id': 'modal-1',
                  'type': 'modal',
                  'modalButtons': [
                    {'id': 'modal-btn-1', 'text': 'Ок'},
                  ],
                },
                {
                  'id': 'inst-1',
                  'type': 'text',
                  'templateRef': 'tpl-linked',
                  'templateVersion': 3,
                },
                {
                  'id': 'master-1',
                  'type': 'text',
                  'content': 'мастер шаблона',
                  'templateRef': 'tpl-master',
                  'templateVersion': 5,
                  'isTemplateMaster': true,
                },
              ],
            },
          },
        ],
        'groups': [],
        'comments': [],
      });
    }

    Set<String> idsOf(Map<String, dynamic> node) {
      final out = <String>{};
      void walk(List<dynamic> items) {
        for (final raw in items) {
          if (raw is! Map) continue;
          if (raw['id'] != null) out.add(raw['id']!.toString());
          final buttons = raw['modalButtons'];
          if (buttons is List) {
            for (final b in buttons) {
              if (b is Map && b['id'] != null) out.add(b['id']!.toString());
            }
          }
          final children = raw['children'];
          if (children is List) walk(children);
        }
      }

      final content = node['content'];
      if (content is Map && content['items'] is List) {
        walk(content['items'] as List);
      }
      return out;
    }

    Future<(Map<String, dynamic>, Map<String, dynamic>)>
    originalAndCopy() async {
      final before = await _nodesOnDisk();
      final original = before.firstWhere((n) => n['id'] == _nodeId);
      expect(await duplicateNode(_questId, _nodeId), isNotNull);
      final after = await _nodesOnDisk();
      final copy = after.firstWhere((n) => n['id'] != _nodeId);
      return (original, copy);
    }

    test('у копии свои id у всех вложенных айтемов', () async {
      await seedRichNode();
      final (original, copy) = await originalAndCopy();

      final originalIds = idsOf(original);
      final copyIds = idsOf(copy);
      expect(
        originalIds,
        hasLength(7),
        reason: '5 айтемов + вложенная и кнопка модалки',
      );
      expect(
        copyIds.intersection(originalIds),
        isEmpty,
        reason: 'общий id = общее переопределение картинки в движке',
      );
      expect(copyIds, hasLength(7), reason: 'ни один айтем не потерян');
    });

    test('структура и ссылки копии сохраняются', () async {
      await seedRichNode();
      final (_, copy) = await originalAndCopy();
      final items = ((copy['content'] as Map)['items'] as List)
          .cast<Map<String, dynamic>>();
      final row = items.firstWhere((i) => i['type'] == 'row');
      final children = (row['children'] as List).cast<Map<String, dynamic>>();
      expect(children, hasLength(2));
      final image = children.firstWhere((i) => i['type'] == 'image');
      expect(image['resourcePath'], 'res/images/gun.png');

      // Linked-инстанс остаётся linked: копия тянет шаблон, а не снимок.
      final linked = items.firstWhere((i) => i['templateRef'] == 'tpl-linked');
      expect(linked['templateVersion'], 3);

      // А мастер отвязывается — иначе у шаблона появляется второй мастер.
      final detached = items.firstWhere(
        (i) => i['content'] == 'мастер шаблона',
      );
      expect(detached.containsKey('templateRef'), isFalse);
      expect(detached.containsKey('isTemplateMaster'), isFalse);
    });

    test('копия в другую главу тоже получает свои id', () async {
      await seedRichNode();
      final original = (await _nodesOnDisk()).first;
      expect(await copyNodeToChapter(_questId, _nodeId, 'chapter-2'), isTrue);

      final copy = (await _nodesOnDisk()).firstWhere((n) => n['id'] != _nodeId);
      expect(copy['chapterId'], 'chapter-2');
      expect(idsOf(copy).intersection(idsOf(original)), isEmpty);
    });

    test('per-node хранилище тоже получает копию со своими id', () async {
      // Реальный формат у экспортированных квестов: индекс в nodes.json,
      // тело ноды отдельным файлом. Копирование идёт через тот же путь, но
      // проверяем его отдельно — здесь расходятся read/write хранилища.
      await seedRichNode();
      await QuestNodesStore.migrateToPerNode(_questId);

      final original = (await _nodesOnDisk()).first;
      expect(await duplicateNode(_questId, _nodeId), isNotNull);
      final copy = (await _nodesOnDisk()).firstWhere((n) => n['id'] != _nodeId);
      expect(idsOf(copy), hasLength(7));
      expect(idsOf(copy).intersection(idsOf(original)), isEmpty);
    });

    test('копия мастер-ноды шаблона не становится вторым мастером', () async {
      await seedRichNode();
      final data = await QuestNodesStore.read(_questId);
      final nodes = (data['nodes'] as List).cast<Map>();
      final node = nodes.firstWhere((n) => n['id'] == _nodeId);
      node['templateRef'] = 'tpl-node';
      node['templateVersion'] = 2;
      node['isTemplateMaster'] = true;
      await QuestNodesStore.write(_questId, data);

      expect(await duplicateNode(_questId, _nodeId), isNotNull);
      final copy = (await _nodesOnDisk()).firstWhere((n) => n['id'] != _nodeId);
      expect(copy.containsKey('templateRef'), isFalse);
      expect(copy.containsKey('isTemplateMaster'), isFalse);
    });
  });
}
