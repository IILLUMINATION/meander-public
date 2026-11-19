// Тренажёр по таблицам: ассет должен быть настоящим архивом MND_ZIP_, а его
// содержимое — покрывать все возможности таблиц. Тест разбирает те же байты,
// что получает `TableExamples.importAll`, поэтому забытая операция, битая
// картинка или пустой раздел ловятся до ручного прогона в приложении.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:canvas_app/features/resources/screens/data/table_examples.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/file_storage.dart';

void main() {
  late Directory appDir;

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_table_examples');
    FileStorage.overrideAppDirectory(appDir);
  });

  tearDownAll(() async {
    FileStorage.overrideAppDirectory(null);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  Archive openAsset(String fileName, List<int> bytes) {
    expect(
      bytes.take(8).toList(),
      utf8.encode('MND_ZIP_'),
      reason: '$fileName: потерян заголовок архива',
    );
    return ZipDecoder().decodeBytes(bytes.sublist(8));
  }

  test('тренажёр импортируется и покрывает все возможности таблиц', () async {
    final seen = <String>[];
    final imported = await TableExamples.importAll(
      loadAsset: (asset) async {
        final bytes = await File(asset).readAsBytes();
        return ByteData.sublistView(bytes);
      },
      importFile: (path) async {
        seen.add(path);
        final bytes = await File(path).readAsBytes();
        final archive = openAsset(path.split('/').last, bytes);
        final configFile = archive.findFile('config.json');
        expect(configFile, isNotNull, reason: '$path: нет config.json');
        final config =
            jsonDecode(utf8.decode(configFile!.content as List<int>))
                as Map<String, dynamic>;
        final id = config['id'] as String;

        // Те же байты раскладываем в квест-директорию, чтобы проверить
        // содержимое, а не только факт вызова импортёра.
        final target = Directory('${appDir.path}/quests/$id');
        await target.create(recursive: true);
        for (final file in archive.files.where((f) => f.isFile)) {
          final out = File('${target.path}/${file.name}');
          await out.parent.create(recursive: true);
          await out.writeAsBytes(file.content as List<int>);
        }
        return id;
      },
    );

    expect(imported, [TableExamples.tutorialQuestId]);
    expect(seen, hasLength(1));
    expect(seen.single, endsWith('table_tutorial.mnd'));

    // Временная папка не остаётся мусором в документах приложения.
    expect(
      Directory('${appDir.path}/temp/table_examples').existsSync(),
      isFalse,
    );

    final questDir = '${appDir.path}/quests/${TableExamples.tutorialQuestId}';
    final config =
        jsonDecode(await File('$questDir/config.json').readAsString())
            as Map<String, dynamic>;
    expect(config['title'], 'Таблицы: большой интерактивный тренажёр');
    expect(config['startNodeId'], 't-start');

    final tables = {
      for (final table in config['tables'] as List)
        (table as Map)['name'] as String: table,
    };
    expect(
      tables.keys,
      containsAll(['Гид', 'Инвентарь', 'Мир', 'Корзина', 'Черновик']),
    );

    final inventory = tables['Инвентарь']! as Map;
    expect(inventory['columns'], ['Предмет', 'Цена', 'Вес', 'Редкость']);
    expect(inventory['rowNames'], ['меч', 'щит', 'зелье']);
    expect((inventory['rows'] as List).first, {
      'Предмет': 'Меч «Гроза»',
      'Цена': 120,
      'Вес': 3.5,
      'Редкость': 'редкий',
    });

    final world = tables['Мир']! as Map;
    final worldData = world['data'] as Map;
    expect(worldData['золото'], 250);
    expect(worldData['персонаж']['характеристики']['сила'], 7);
    expect(worldData['персонаж']['инвентарь'], ['меч', 'зелье']);

    final nodesDir = Directory('$questDir/nodes');
    final nodeFiles = nodesDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .where((f) => !f.path.endsWith('index.json'))
        .toList();
    expect(nodeFiles.length, greaterThanOrEqualTo(40));
    final nodes = <Map<String, dynamic>>[];
    for (final file in nodeFiles) {
      nodes.add(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    }
    expect(
      nodes.map((n) => n['id']),
      containsAll([
        't-start',
        't-keys',
        't-paths',
        't-lists',
        't-grid',
        't-formulas',
        't-ops',
        't-errors',
        't-exam',
        't-cheatsheet',
      ]),
    );

    // Все картинки, на которые ссылаются ноды, лежат в архиве и не пустые.
    final imageRefs = <String>{};
    final text = StringBuffer();
    for (final node in nodes) {
      text.write(jsonEncode(node));
    }
    for (final match in RegExp(
      r'res/images/[0-9a-f-]+\.png',
    ).allMatches(text.toString())) {
      imageRefs.add(match.group(0)!);
    }
    expect(imageRefs.length, greaterThanOrEqualTo(10));
    for (final ref in imageRefs) {
      final file = File('$questDir/$ref');
      expect(file.existsSync(), isTrue, reason: 'нет картинки $ref');
      expect(
        file.lengthSync(),
        greaterThan(1000),
        reason: 'пустая картинка $ref',
      );
    }

    // Каждая операция блока «Данные» встречается в готовых скриптах.
    final operations = <String>{};
    final scripts = Directory('$questDir/scripts')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    expect(scripts.length, greaterThanOrEqualTo(50));
    for (final file in scripts) {
      _collectTableOperations(
        jsonDecode(await file.readAsString()),
        operations,
      );
    }
    expect(
      operations,
      containsAll(<String>[
        'get',
        'set',
        'add',
        'remove',
        'remove_value',
        'contains',
        'clear',
      ]),
    );

    // Формулы таблиц демонстрируются в текстах нод.
    expect(text.toString(), contains('table_sum('));
    expect(text.toString(), contains('table_text('));
    expect(text.toString(), contains('table_where('));
    expect(text.toString(), contains('table_find('));
  });
}

void _collectTableOperations(Object? value, Set<String> out) {
  if (value is Map) {
    if (value['type'] == 'table_operation') {
      final operation = value['operation'];
      if (operation is String) out.add(operation);
    }
    for (final child in value.values) {
      _collectTableOperations(child, out);
    }
  } else if (value is List) {
    for (final child in value) {
      _collectTableOperations(child, out);
    }
  }
}
