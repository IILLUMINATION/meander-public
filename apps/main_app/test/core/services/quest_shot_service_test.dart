// Снимок из игры кладётся в скриншоты квеста: файл в res/screenshots и запись
// в config.screenshot_files. Проверяем именно связку «файл + конфиг», а не
// отрисовку карточки — её покрывает mnd_player (quest_shot_test).
import 'dart:io';

import 'package:canvas_app/core/services/quest_shot_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/file_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('quest_shot_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return docs.path;
          }
          return null;
        });
  });

  tearDown(() async {
    try {
      await docs.delete(recursive: true);
    } catch (_) {}
  });

  test('снимок сохраняется в квест и попадает в config', () async {
    const questId = 'shot-quest';
    await FileStorage.writeJsonFile('quests/$questId/config.json', {
      'id': questId,
      'title': 'Снимки',
      'screenshot_files': ['старый.png'],
    });

    final bytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
    final name = await saveQuestShot(questId, bytes);

    expect(name, startsWith('shot_'));
    final file = File(await FileStorage.getFilePath(
      'quests/$questId/res/screenshots/$name',
    ));
    expect(await file.readAsBytes(), bytes);

    final config = await FileStorage.readJsonFile(
      'quests/$questId/config.json',
    );
    // Прежние снимки не теряются: автор мог добавлять их из галереи.
    expect(config['screenshot_files'], ['старый.png', name]);
  });
}