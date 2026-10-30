import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/file_storage.dart';

void main() {
  late Directory appDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    appDir = await Directory.systemTemp.createTemp('mnd_filestorage_test');
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
    if (appDir.existsSync()) {
      await appDir.delete(recursive: true);
    }
  });

  group('FileStorage.writeTextFile', () {
    test('ascii round-trip', () async {
      const content = 'print("hello")\n-- plain comment\n';
      await FileStorage.writeTextFile('t1.lua', content);
      expect(await FileStorage.readTextFile('t1.lua'), content);
    });

    test('кириллица и эмодзи не роняют верификацию temp-файла', () async {
      // String.length (UTF-16) != File.length (байты UTF-8) на не-ASCII:
      // старая проверка кидала «Верификация temp-файла не пройдена».
      const content =
          '-- Комментарий по-русски: привет, мир! 🎮\n'
          'print("квест: начало — конец…")\n'
          '-- ещё строка: ёЁ №\n';
      await FileStorage.writeTextFile('t2.lua', content);
      expect(await FileStorage.readTextFile('t2.lua'), content);
    });

    test('writeJsonFile с кириллицей round-trip', () async {
      final data = {
        'title': 'Тестовый квест 🎲',
        'nodes': [
          {'id': 'n1', 'text': 'Привет, путник!'},
        ],
      };
      await FileStorage.writeJsonFile('q.json', data);
      final read = await FileStorage.readJsonFile('q.json');
      expect(read['title'], data['title']);
      expect((read['nodes'] as List).first['text'], 'Привет, путник!');
    });

    test('кэш отдаёт независимые вложенные структуры', () async {
      await FileStorage.writeJsonFile('clone.json', {
        'nodes': [
          {'id': 'n1', 'text': 'Привет, путник!'},
        ],
      });

      final first = await FileStorage.readJsonFile('clone.json');
      ((first['nodes'] as List).first as Map)['text'] = 'изменено';
      (first['nodes'] as List).add({'id': 'n2'});

      final second = await FileStorage.readJsonFile('clone.json');
      expect((second['nodes'] as List), hasLength(1));
      expect(
        ((second['nodes'] as List).first as Map)['text'],
        'Привет, путник!',
      );
    });
  });
}
