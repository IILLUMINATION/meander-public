// Резолв «источника картинки» в реальный файл: путь / имя из библиотеки /
// uuid. Это I/O-слой плеера поверх чистых правил mnd_core.
//
// У каждого теста свой questId: `FileStorage` кэширует JSON статически по
// пути, и общий каталог смешал бы метаданные разных сценариев.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/quest_image_source.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ'
    '/pLvAAAAAElFTkSuQmCC';

const _uuid = '0c958f72-92ca-4c96-a65a-c678e1548df2';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;
  var questCounter = 0;

  /// Мок path_provider ставим внутри теста: `FileStorage` кэширует каталог
  /// приложения, и первый вызов без обработчика залипает ошибкой надолго.
  void stubPathProvider() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? appDir.path
              : null,
        );
  }

  String newQuest() => 'q${++questCounter}';

  Future<void> writeImage(String questId, String fileName) async {
    final dir = Directory('${appDir.path}/quests/$questId/res/images')
      ..createSync(recursive: true);
    File('${dir.path}/$fileName').writeAsBytesSync(base64Decode(_png));
  }

  Future<void> writeMetadata(
    String questId,
    Map<String, dynamic> metadata,
  ) async {
    final file = File('${appDir.path}/quests/$questId/res/metadata.json')
      ..parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(metadata));
  }

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_image_source_test');
  });

  tearDownAll(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('путь из редактора резолвится как есть', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, '$_uuid.jpg');

    final file = await QuestImageSource.resolve(
      questId,
      'res/images/$_uuid.jpg',
    );

    expect(file?.path, endsWith('res/images/$_uuid.jpg'));
  });

  test('голое имя файла с расширением находится в res/images', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, 'a.png');

    final file = await QuestImageSource.resolve(questId, ' a.png ');

    expect(file?.path, endsWith('res/images/a.png'));
  });

  test('имя ресурса из библиотеки → его файл', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, '$_uuid.jpg');
    await writeMetadata(questId, {
      '$_uuid.jpg': {'name': 'Закат', 'folder': '/картинки'},
    });

    final file = await QuestImageSource.resolve(questId, 'Закат');

    expect(file?.path, endsWith('$_uuid.jpg'));
  });

  test('регистр имени не важен', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, '$_uuid.jpg');
    await writeMetadata(questId, {
      '$_uuid.jpg': {'name': 'Закат'},
    });

    expect(
      (await QuestImageSource.resolve(questId, 'закат'))?.path,
      endsWith('$_uuid.jpg'),
    );
  });

  test('uuid без расширения → файл по имени', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, '$_uuid.jpg');
    await writeMetadata(questId, {
      '$_uuid.jpg': {'name': 'Закат'},
    });

    expect(
      (await QuestImageSource.resolve(questId, _uuid))?.path,
      endsWith('$_uuid.jpg'),
    );
  });

  // Реальный случай (фон ноды/главы не показывался): файл ресурса сам без
  // расширения — так его импортировали из источника, где имени с точкой не
  // было. В `backgroundAssetId` лежит это же имя, каталог по расширению не
  // выбрать; файл обязан найтись в res/images.
  test('файл без расширения находится по имени из metadata', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, _uuid);
    await writeMetadata(questId, {
      _uuid: {'name': 'jpg(2)', 'folder': '/'},
    });

    final file = await QuestImageSource.resolve(questId, _uuid);

    expect(file?.path, endsWith('res/images/$_uuid'));
    expect(await QuestImageSource.resolveOnDisk(questId, _uuid), isNotEmpty);
  });

  test('одно имя на два файла — не угадываем', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, 'x1.png');
    await writeImage(questId, 'x2.png');
    await writeMetadata(questId, {
      'x1.png': {'name': 'Фон'},
      'x2.png': {'name': 'Фон'},
    });

    expect(await QuestImageSource.resolve(questId, 'Фон'), isNull);
  });

  test('битый путь не превращается в поиск по библиотеке', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeMetadata(questId, {
      'x1.png': {'name': 'закат'},
    });

    expect(
      await QuestImageSource.resolve(questId, 'res/images/nope.png'),
      isNull,
    );
  });

  test('без metadata.json имя не находится, но и не падает', () async {
    stubPathProvider();

    expect(await QuestImageSource.resolve(newQuest(), 'закат'), isNull);
  });

  test('пустой источник — null', () async {
    stubPathProvider();
    final questId = newQuest();

    expect(await QuestImageSource.resolve(questId, '   '), isNull);
    expect(await QuestImageSource.resolve(questId, null), isNull);
  });

  test('путь от корня документов не удваивается', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, 'a.png');

    // Часть мест (фон ноды, пресеты) хранит путь уже с префиксом квеста.
    final file = await QuestImageSource.resolve(
      questId,
      'quests/$questId/res/images/a.png',
    );

    expect(file?.path, endsWith('quests/$questId/res/images/a.png'));
  });

  test('резолвер отдаёт фактический путь ресурса', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, '$_uuid.jpg');
    await writeMetadata(questId, {
      '$_uuid.jpg': {'name': 'Закат'},
    });

    // Автор написал имя — экспорт должен подписать файл, а не строку «Закат».
    expect(
      await QuestImageSource.resolveRelative(questId, 'Закат'),
      'res/images/$_uuid.jpg',
    );
    expect(
      await QuestImageSource.resolveRelative(questId, 'нет такого'),
      isNull,
    );
  });

  test('resolveOnDisk: путь или пустая строка, без File-исключений', () async {
    stubPathProvider();
    final questId = newQuest();
    await writeImage(questId, 'a.png');

    final found = await QuestImageSource.resolveOnDisk(questId, 'a.png');
    expect(found, endsWith('quests/$questId/res/images/a.png'));
    expect(await QuestImageSource.resolveOnDisk(questId, 'missing.png'), '');
  });

  test('аудио и шрифт резолвятся так же, как картинка', () async {
    stubPathProvider();
    final questId = newQuest();
    void write(String dir, String fileName) {
      final d = Directory('${appDir.path}/quests/$questId/res/$dir')
        ..createSync(recursive: true);
      File('${d.path}/$fileName').writeAsBytesSync(base64Decode(_png));
    }

    write('audio', 'track.mp3');
    write('fonts', 'track.ttf');

    expect(
      (await QuestImageSource.resolve(questId, 'track.mp3'))?.path,
      endsWith('res/audio/track.mp3'),
    );
    expect(
      (await QuestImageSource.resolve(questId, 'track.ttf'))?.path,
      endsWith('res/fonts/track.ttf'),
    );
  });
}
