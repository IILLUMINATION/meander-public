import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:canvas_app/core/utils/archive_entry_paths.dart'
    as archive_entry_paths;
import 'package:canvas_app/core/utils/quest_folder_swap.dart';

// Перечисление для действий при конфликте во время восстановления
enum RestoreAction { replace, skip, cancelAll }

class BackupService {
  /// Создает ZIP-архив со всеми квестами и предлагает его сохранить.
  static Future<bool> createBackup({
    required Function(String status) onProgress,
  }) async {
    try {
      onProgress(tr('Поиск локальных квестов...'));
      final questsPath = await FileStorage.getFilePath(QuestPaths.questsDir);
      final questsDir = Directory(questsPath);

      if (!await questsDir.exists() || await questsDir.list().isEmpty) {
        throw Exception(tr('Нет квестов для создания резервной копии.'));
      }

      onProgress(tr('Создание архива...'));
      final archive = Archive();
      await for (final entity in questsDir.list(recursive: false)) {
        if (entity is Directory) {
          final questId = p.basename(entity.path);
          onProgress(
            trf('Добавление квеста "{questId}"...', {'questId': questId}),
          );
          await _addDirectoryToArchive(archive, entity, questId);
        }
      }

      onProgress(tr('Сжатие данных...'));
      final zipData = ZipEncoder().encode(archive);

      onProgress(tr('Сохранение файла...'));
      final timestamp = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
      final fileName = 'meander_backup_$timestamp.zip';

      final tempDir = await getTemporaryDirectory();
      final tempFilePath = p.join(tempDir.path, fileName);
      final tempFile = File(tempFilePath);
      await tempFile.writeAsBytes(zipData);

      final params = SaveFileDialogParams(
        sourceFilePath: tempFile.path,
        fileName: fileName,
      );
      final result = await FlutterFileDialog.saveFile(params: params);

      await tempFile.delete();
      return result != null;
    } catch (e) {
      print('❌ Ошибка создания бэкапа: $e');
      rethrow;
    }
  }

  /// Восстанавливает квесты из выбранного ZIP-архива.
  static Future<bool> restoreFromBackup({
    required Function(String status) onProgress,
    required Future<RestoreAction?> Function(String questTitle) onConflict,
  }) async {
    // Шаг 1: Выбор файла
    onProgress(tr('Выберите файл бэкапа (.zip)...'));
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (files.isEmpty || files.single.path == null) {
      return false; // Пользователь отменил выбор
    }
    final filePath = files.single.path!;

    // Шаг 2: Распаковка и подготовка
    onProgress(tr('Чтение архива...'));
    final bytes = await File(filePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final questsPath = await FileStorage.getFilePath(QuestPaths.questsDir);
    final localQuestIds = await FileStorage.listFolders(QuestPaths.questsDir);

    // Шаг 3: Анализ конфликтов и восстановление
    // Группируем файлы по директориям квестов
    final Map<String, List<ArchiveFile>> questsInArchive = {};
    for (final file in archive) {
      // Имя записи становится id квеста, а папку квеста перед заменой
      // удаляют рекурсивно: `../x` стёр бы каталог приложения. Недопустимые
      // записи не разбираем вовсе.
      final clean = archive_entry_paths.sanitizeArchiveEntryPath(file.name);
      if (clean == null) {
        print('⚠️ [Backup] Пропущена запись архива с недопустимым путём: '
            '${file.name}');
        continue;
      }
      final questId = clean.split('/').first;
      questsInArchive.putIfAbsent(questId, () => []).add(file);
    }

    for (final entry in questsInArchive.entries) {
      final questId = entry.key;
      final questFiles = entry.value;

      // Ищем конфиг, чтобы узнать название
      ArchiveFile? configEntry;
      try {
        configEntry = questFiles.firstWhere(
          (f) => p.basename(f.name) == 'config.json',
        );
      } catch (_) {}

      String questTitle = questId;
      if (configEntry != null) {
        try {
          final config = jsonDecode(
            utf8.decode(configEntry.content as List<int>),
          );
          questTitle = config['title'] ?? questId;
        } catch (_) {}
      }

      var replaced = false;
      if (localQuestIds.contains(questId)) {
        // Конфликт!
        onProgress(
          trf('Обнаружен конфликт: "{questTitle}"', {'questTitle': questTitle}),
        );
        final action = await onConflict(questTitle);

        if (action == RestoreAction.cancelAll) {
          onProgress(tr('Восстановление отменено.'));
          return false;
        }
        if (action == RestoreAction.skip) {
          onProgress(
            trf('Пропуск квеста "{questTitle}"...', {'questTitle': questTitle}),
          );
          continue;
        }
        if (action == RestoreAction.replace) {
          replaced = true;
          onProgress(
            trf('Замена квеста "{questTitle}"...', {'questTitle': questTitle}),
          );
        }
      } else {
        onProgress(
          trf('Восстановление "{questTitle}"...', {'questTitle': questTitle}),
        );
      }

      final restored = await restoreQuestEntries(
        questsPath: questsPath,
        questId: questId,
        files: questFiles,
        replaceExisting: replaced,
      );
      if (!restored) {
        print('❌ [Backup] Квест $questId не восстановлен');
        onProgress(
          trf('Не удалось восстановить квест "{questTitle}"', {
            'questTitle': questTitle,
          }),
        );
        continue;
      }
    }

    onProgress(tr('Завершено!'));
    return true;
  }


  /// Восстанавливает файлы одного квеста из записей архива.
  ///
  /// Запись идёт в промежуточную папку рядом с целевой, и только после
  /// успешной распаковки она подменяет каталог квеста. Раньше старая папка
  /// удалялась до записи: сбой посреди распаковки (кончилось место, слетело
  /// приложение) оставлял квест наполовину перезаписанным — и старой копии
  /// уже не было.
  ///
  /// `false` — запись не удалась; на диске остался прежний квест.
  @visibleForTesting
  static Future<bool> restoreQuestEntries({
    required String questsPath,
    required String questId,
    required List<ArchiveFile> files,
    required bool replaceExisting,
  }) async {
    final targetDir = Directory(p.join(questsPath, questId));
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final stagingDir = Directory(
      p.join(questsPath, '.restore_${questId}_$stamp'),
    );
    try {
      await stagingDir.create(recursive: true);
      for (final file in files) {
        final clean = archive_entry_paths.sanitizeArchiveEntryPath(file.name);
        if (clean == null) {
          print('⚠️ [Backup] Пропущена запись с недопустимым путём: '
              '${file.name}');
          continue;
        }
        final segments = clean.split('/');
        if (segments.length < 2 || segments.first != questId) continue;
        final targetPath = archive_entry_paths.resolveArchiveTarget(
          stagingDir.path,
          segments.sublist(1).join('/'),
        );
        if (targetPath == null) continue;

        if (file.isFile) {
          final outFile = File(targetPath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>, flush: true);
        } else {
          await Directory(targetPath).create(recursive: true);
        }
      }

      if (await targetDir.exists() && !replaceExisting) {
        await stagingDir.delete(recursive: true);
        return false;
      }
      // Старая папка уходит в сторону целиком — до этого момента она на
      // месте, даже если распаковка упала.
      await replaceDirectoryAtomically(staging: stagingDir, target: targetDir);

      // Файлы записаны в обход кэша JSON (см. FileStorage.invalidateJsonCache).
      FileStorage.invalidateJsonCache([QuestPaths.questRoot(questId)]);
      return true;
    } catch (error) {
      print('❌ [Backup] Восстановление $questId не удалось: $error');
      try {
        if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
      } catch (_) {}
      return false;
    }
  }

  /// Вспомогательная рекурсивная функция для добавления директории в архив.
  static Future<void> _addDirectoryToArchive(
    Archive archive,
    Directory dir,
    String parentPath,
  ) async {
    await for (final entity in dir.list(recursive: false)) {
      final entityName = p.basename(entity.path);
      final archivePath = p.join(parentPath, entityName);

      if (entity is File) {
        final bytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
      } else if (entity is Directory) {
        await _addDirectoryToArchive(archive, entity, archivePath);
      }
    }
  }
}
