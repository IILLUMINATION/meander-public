import 'dart:io';
import 'dart:typed_data';

import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

// ============================================================================
//  Скриншоты квеста из игры
//
//  Снимок делает плеер (кадр сцены без верхней панели), а кладёт его квест —
//  здесь: файл в `res/screenshots` и запись в `config.screenshot_files`, чтобы
//  карточка квеста и маркет увидели его без ручного выбора из галереи.
// ============================================================================

/// Сохранить готовый PNG в скриншоты квеста и вернуть имя файла.
Future<String> saveQuestShot(String questId, Uint8List png) async {
  final dir = QuestPaths.resScreenshotsDir(questId);
  await FileStorage.createFolder(dir);
  // Имя по времени, а не uuid: автору проще найти снимок в каталоге, а
  // коллизия возможна только при двух снимках в одну миллисекунду.
  final fileName = 'shot_${DateTime.now().millisecondsSinceEpoch}.png';
  final path = await FileStorage.getFilePath('$dir/$fileName');
  await File(path).writeAsBytes(png, flush: true);

  final configPath = QuestPaths.config(questId);
  final config = await FileStorage.readJsonFile(configPath);
  final screenshots = <String>{
    ...?(config['screenshot_files'] as List?)?.map((e) => e.toString()),
  };
  screenshots.add(fileName);
  config['screenshot_files'] = screenshots.toList();
  await FileStorage.writeJsonFile(configPath, config);
  return fileName;
}