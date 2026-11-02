// Экспорт квеста в самодостаточный HTML всегда отдавал плееру только legacy
// `scriptTriggers`: ссылка, записанная новым массивом `behaviours`, пропадала,
// и кнопка в браузере не запускала скрипт, который в приложении работал.
// Проверяем собранный `quest-data` — оба формата и правило затенения.
import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/core/services/quest_book_models.dart';
import 'package:canvas_app/core/services/quest_html_builder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

const String _questId = '22222222-2222-4222-8222-222222222222';

Future<Map<String, dynamic>> _questData(String html) async {
  final start = html.indexOf(
    '<script id="quest-data" type="application/json">',
  );
  expect(
    start,
    greaterThan(-1),
    reason: 'в экспорте нет блока с данными квеста',
  );
  const open = '<script id="quest-data" type="application/json">'.length;
  final end = html.indexOf('</script>', start + open);
  return jsonDecode(html.substring(start + open, end)) as Map<String, dynamic>;
}

Map<String, dynamic> _itemById(
  Map<String, dynamic> quest,
  String nodeId,
  String itemId,
) {
  final items = (quest['nodes']![nodeId]!['items'] as List).cast<Map>();
  return items.firstWhere((m) => m['id'] == itemId).cast<String, dynamic>();
}

void main() {
  late Directory appDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_html_export_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return appDir.path;
          }
          return null;
        });
  });

  tearDownAll(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('экспорт пробрасывает скрипты из обоих форматов триггеров', () async {
    final nodes = <Map<String, dynamic>>[
      {
        'id': 'n1',
        'chapterId': 'ch1',
        'title': 'Нода 1',
        'content': {
          'items': [
            {
              'id': 'b-legacy',
              'type': 'button',
              'text': 'Легаси',
              'targetNodeId': 'n2',
              'scriptTriggers': {'onPress': 'scripts/legacy.json'},
            },
            {
              'id': 'b-new',
              'type': 'button',
              'text': 'Новый',
              'targetNodeId': 'n2',
              'behaviours': [
                {
                  'event': 'onPress',
                  'kind': 'action',
                  'script': 'scripts/new.json',
                },
              ],
            },
            {
              'id': 'b-shadow',
              'type': 'button',
              'text': 'Затенение',
              'targetNodeId': 'n2',
              'behaviours': [
                {
                  'event': 'onAppear',
                  'kind': 'visibility',
                  'script': 'scripts/vis.json',
                },
              ],
              'scriptTriggers': {'onPress': 'scripts/dead.json'},
            },
          ],
        },
      },
      {
        'id': 'n2',
        'chapterId': 'ch1',
        'title': 'Финал',
        'content': {
          'items': [
            {'id': 't1', 'type': 'text', 'text': 'Конец'},
          ],
        },
      },
    ];

    final book = QuestBook(
      id: _questId,
      title: 'Тестовый квест',
      author: null,
      description: null,
      startNodeId: 'n1',
      nodesById: {for (final n in nodes) n['id']! as String: n},
      chapters: [QuestChapter(id: 'ch1', name: 'Глава 1', nodes: nodes)],
      previewBytes: null,
      previewMime: null,
      customFontFileName: null,
      customFontBytes: null,
    );

    final quest = await _questData(await QuestHtmlBuilder.build(book));

    // Legacy-ссылка как раньше: имя скрипта без пути и расширения.
    expect(_itemById(quest, 'n1', 'b-legacy')['scriptTriggers'], {
      'onPress': 'legacy',
    });

    // Новый формат доезжает до страницы — до фикса здесь было ничего.
    expect(_itemById(quest, 'n1', 'b-new')['scriptTriggers'], {
      'onPress': 'new',
    });

    // Живой behaviours затеняет legacy целиком, как в плеере: мёртвая
    // ссылка не должна попадать в экспорт и оживать в браузере.
    expect(_itemById(quest, 'n1', 'b-shadow')['scriptTriggers'], {
      'onAppear': 'vis',
    });
  });

  test('экспорт переносит таблицы в quest-data, а не теряет их', () async {
    final configPath = QuestPaths.config(_questId);
    final old = File(configPath);
    final backup = old.existsSync() ? old.readAsStringSync() : null;
    addTearDown(() {
      if (backup == null) {
        if (old.existsSync()) old.deleteSync();
      } else {
        old.writeAsStringSync(backup);
      }
    });
    await FileStorage.writeJsonFile(configPath, {
      'id': _questId,
      'title': 'Табличный квест',
      'startNodeId': 'n1',
      'tables': [
        {
          'name': 'лавка',
          'columns': ['цена'],
          'rows': [
            {'цена': 30},
          ],
          'data': {'открыто': true},
        },
      ],
    });

    final nodes = <Map<String, dynamic>>[
      {
        'id': 'n1',
        'chapterId': 'ch1',
        'title': 'Нода 1',
        'content': {
          'items': [
            {'id': 't1', 'type': 'text', 'text': 'Таблица'},
          ],
        },
      },
    ];
    final book = QuestBook(
      id: _questId,
      title: 'Табличный квест',
      author: null,
      description: null,
      startNodeId: 'n1',
      nodesById: {'n1': nodes.first},
      chapters: [QuestChapter(id: 'ch1', name: 'Глава 1', nodes: nodes)],
      previewBytes: null,
      previewMime: null,
      customFontFileName: null,
      customFontBytes: null,
    );

    final quest = await _questData(await QuestHtmlBuilder.build(book));
    expect(quest['tables'], isA<Map>());
    expect(quest['tables']['лавка']['columns'], ['цена']);
    expect(quest['tables']['лавка']['rows'], [
      {'цена': 30},
    ]);
    expect(quest['tables']['лавка']['data'], {'открыто': true});
  });

  /// Реестра «Глобальные скрипты» в конфиге больше нет: движок (и этот
  /// экспорт вместе с ним) находит скрипты запуска по объявленному событию.
  /// Плоский скрипт без event-обёртки в запуске квеста не участвует — иначе
  /// любой файл в `scripts/` выполнялся бы на старте.
  test('экспорт сам находит скрипты запуска квеста', () async {
    final dir = QuestPaths.questFile(_questId, 'scripts');
    await FileStorage.writeJsonFile('$dir/boot.json', {
      'blocks': [
        {
          'type': 'event',
          'eventType': 'onQuestStart',
          'children': [
            {'type': 'assign_variable', 'variable': 'gold', 'value': 0},
          ],
        },
      ],
    });
    await FileStorage.writeJsonFile('$dir/legacy.json', {
      'blocks': [
        {
          'type': 'event',
          'title': 'При запуске квеста',
          'children': <Map<String, dynamic>>[],
        },
      ],
    });
    await FileStorage.writeJsonFile('$dir/on-enter.json', {
      'blocks': [
        {
          'type': 'event',
          'eventType': 'onNodeEnter',
          'children': <Map<String, dynamic>>[],
        },
      ],
    });
    await FileStorage.writeJsonFile('$dir/flat.json', {
      'blocks': [
        {'type': 'assign_variable', 'variable': 'x', 'value': 1},
      ],
    });

    final node = <String, dynamic>{
      'id': 'n1',
      'chapterId': 'ch1',
      'title': 'Нода 1',
      'content': {
        'items': [
          {'id': 't1', 'type': 'text', 'text': 'Привет'},
        ],
      },
    };
    final book = QuestBook(
      id: _questId,
      title: 'Тестовый квест',
      author: null,
      description: null,
      startNodeId: 'n1',
      nodesById: {'n1': node},
      chapters: [QuestChapter(id: 'ch1', name: 'Глава 1', nodes: [node])],
      previewBytes: null,
      previewMime: null,
      customFontFileName: null,
      customFontBytes: null,
    );

    final quest = await _questData(await QuestHtmlBuilder.build(book));

    // Сортировка по имени — тот же порядок, что у движка.
    expect(quest['startScripts'], ['boot', 'legacy']);
  });
}
