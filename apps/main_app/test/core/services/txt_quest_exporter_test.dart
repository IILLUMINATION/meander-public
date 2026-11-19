import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'package:canvas_app/core/services/export_service.dart';
import 'package:canvas_app/core/services/txt_quest_exporter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

const _questId = '77777777-7777-4777-8777-777777777777';
const _startNode = '11111111-1111-4111-8111-111111111111';
const _targetNode = '22222222-2222-4222-8222-222222222222';

void main() {
  late Directory appDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_txt_export');
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
      'title': 'Текстовый квест',
      'author': 'Автор',
      'description': 'Проверка экспорта',
      'startNodeId': _startNode,
      'variables': [
        {'name': 'золото', 'defaultValue': 10},
      ],
      'tables': [
        {
          'name': 'товары',
          'columns': ['название', 'цена'],
          'rows': [
            {'название': 'меч', 'цена': 100},
          ],
        },
      ],
      'connections': <dynamic>[],
    });
    await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
      'nodes': [
        {
          'id': _startNode,
          'title': 'Начало',
          'x': 10.0,
          'y': 20.0,
          'content': {
            'items': [
              {'type': 'text', 'text': 'У тебя {золото} золота.'},
              {'type': 'button', 'text': 'Дальше', 'targetNodeId': _targetNode},
            ],
          },
        },
        {
          'id': _targetNode,
          'title': 'Финал',
          'content': {'items': <dynamic>[]},
        },
      ],
      'groups': [
        {
          'id': 'g1',
          'title': 'Глава 1',
          'nodes': [
            {'id': _startNode},
          ],
        },
      ],
      'comments': [
        {'id': 'c1', 'text': 'Проверить баланс'},
      ],
    });
    await FileStorage.writeJsonFile('quests/$_questId/scripts/hello.json', {
      'id': '33333333-3333-4333-8333-333333333333',
      'name': 'hello',
      'blocks': [
        {
          'type': 'event',
          'eventType': 'onPress',
          'children': [
            {'type': 'assign_variable', 'variable': 'золото', 'value': 5},
            {'type': 'go_to_node', 'targetNodeId': _targetNode},
          ],
        },
      ],
    });
    FileStorage.invalidateJsonCache(const []);
    await QuestNodesStore.ensurePerNode(_questId);
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('читаемый экспорт содержит справку, ноды, таблицу и связи', () async {
    final text = await TxtQuestExporter.build(
      _questId,
      'Текстовый квест',
      const TxtExportOptions(),
    );

    expect(text, contains('Meander — движок интерактивных квестов'));
    expect(text, contains('{золото}'));
    expect(text, contains('Начало'));
    expect(
      text,
      contains('«меч | 100»'.replaceAll('«', '').replaceAll('»', '')),
    );
    expect(text, contains('кнопка «Дальше»'));
    expect(text, isNot(contains('"items"')));
    expect(text, isNot(contains('"blocks"')));
  });

  test('UUID сокращаются одинаково в нодах и ссылках', () async {
    final text = await TxtQuestExporter.build(
      _questId,
      'Текстовый квест',
      const TxtExportOptions(includeCoordinates: true),
    );

    expect(text, contains('ID_1'));
    expect(text, contains('ID_2'));
    expect(text, contains('(ID_1)'));
    expect(text, contains('(ID_2)'));
    expect(text, isNot(contains(_startNode)));
    expect(text, isNot(contains(_targetNode)));
    expect(text, contains('Координаты: 10.0, 20.0'));
  });

  test('настройки отключают разделы и координаты', () async {
    final text = await TxtQuestExporter.build(
      _questId,
      'Текстовый квест',
      const TxtExportOptions(
        aiGuide: false,
        includeConfig: false,
        includeNodes: false,
        includeScripts: false,
        includeConnections: false,
        includeGroups: false,
        includeComments: true,
      ),
    );

    expect(text, isNot(contains('КАК ЧИТАТЬ ЭТОТ ФАЙЛ')));
    expect(text, isNot(contains('КОНФИГУРАЦИЯ')));
    expect(text, isNot(contains('НОДЫ')));
    expect(text, isNot(contains('СВЯЗИ')));
    expect(text, isNot(contains('СКРИПТЫ')));
    expect(text, isNot(contains('Координаты')));
    expect(text, contains('Проверить баланс'));
  });

  test('скрипты рендерятся блоками без JSON', () async {
    final text = await TxtQuestExporter.build(
      _questId,
      'Текстовый квест',
      const TxtExportOptions(),
    );

    expect(text, contains('### scripts/hello.json'));
    expect(text, contains('Событие onPress'));
    expect(text, contains('Присвоить «золото» = 5'));
    expect(text, contains('Перейти к ноде «Финал»'));
  });

  test('технический дамп остаётся доступен переключателем', () async {
    final text = await ExportService.buildTxtContent(
      _questId,
      'Текстовый квест',
      options: const TxtExportOptions(readable: false),
    );

    expect(text, contains('РАЗДЕЛ 1: КОНФИГУРАЦИЯ'));
    expect(text, contains('"nodes"'));
    expect(text, contains('ID_1'));
    expect(text, isNot(contains('КАК ЧИТАТЬ ЭТОТ ФАЙЛ')));
  });

  test('туториал 04_scripts разбирается без JSON-мусора', () async {
    const fixtureId = '88888888-8888-4888-8888-888888888888';
    final bytes = await File(
      '../../quests/tutorials/04_scripts.mnd',
    ).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes.sublist(8));
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      await FileStorage.writeTextFile(
        'quests/$fixtureId/${entry.name}',
        utf8.decode(entry.content as List<int>),
      );
    }
    FileStorage.invalidateJsonCache(const []);

    final text = await TxtQuestExporter.build(
      fixtureId,
      '04_scripts',
      const TxtExportOptions(includeSystemScripts: true),
    );

    expect(text, contains('таблица'));
    expect(text, contains('товары'));
    expect(text, contains('Событие'));
    expect(text, contains('Присвоить'));
    expect(text, isNot(contains('"type": "event"')));
    expect(text, isNot(contains('"children"')));
  });
}
