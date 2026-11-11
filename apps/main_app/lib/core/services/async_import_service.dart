import 'dart:convert';
import 'dart:io';
import 'package:canvas_app/core/importers/qst_importer.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/quest_folder_swap.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_core/src/gen/api/quest_archive.dart' as rust_archive;

/// Сервис для асинхронного импорта квестов, поддерживающий большие файлы
class AsyncImportService {
  static Future<String?> pickAndImportQuest({
    Function(String status)? onProgress,
    Function(double progress)? onProgressUpdate,
  }) async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);

      if (files.isEmpty || files.single.path == null) {
        print('ℹ️ [Import] Пользователь отменил выбор файла.');
        return null;
      }

      final filePath = files.single.path!;

      // Проверяем расширение файла
      final mndFileRegex = RegExp(r'\.mnd(\s*\(\d+\))?$', caseSensitive: false);
      final qstFileRegex = RegExp(
        r'\.(qst|urq)(\s*\(\d+\))?$',
        caseSensitive: false,
      );

      if (qstFileRegex.hasMatch(filePath)) {
        // Импорт URQ (.qst, .urq)
        print('✅ [Import] Файл URQ выбран для импорта: $filePath');
        return await _importQuestFromQst(
          filePath,
          onProgress: onProgress,
          onProgressUpdate: onProgressUpdate,
        );
      }

      if (!mndFileRegex.hasMatch(filePath)) {
        throw Exception(
          tr(
            'Выбран неверный тип файла. Пожалуйста, выберите файл с расширением .mnd, .qst или .urq',
          ),
        );
      }

      print('✅ [Import] Файл для импорта выбран: $filePath');
      return await _importQuestFromMnd(
        filePath,
        onProgress: onProgress,
        onProgressUpdate: onProgressUpdate,
      );
    } catch (e) {
      print('❌ [Import] Ошибка на этапе выбора файла: $e');
      rethrow;
    }
  }

  static Future<String?> importFromFile(
    String filePath, {
    Function(String status)? onProgress,
    Function(double progress)? onProgressUpdate,
  }) async {
    print('✅ [Import] Файл для импорта предоставлен: $filePath');
    return await _importQuestFromMnd(
      filePath,
      onProgress: onProgress,
      onProgressUpdate: onProgressUpdate,
    );
  }

  static Future<String?> _importQuestFromMnd(
    String filePath, {
    Function(String status)? onProgress,
    Function(double progress)? onProgressUpdate,
  }) async {
    final tempDirPath = p.join(
      await FileStorage.getFilePath('temp'),
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final tempDir = Directory(tempDirPath);
    await tempDir.create(recursive: true);

    try {
      print('⚙️ [Import] Начало импорта квеста (Rust стрим)...');
      onProgress?.call(tr('Распаковка архива (Rust стрим)...'));
      onProgressUpdate?.call(0.1);

      // Делегируем распаковку в Rust: стрим 64КБ, без пика RAM, поддержка
      // MND_ZIP_ / MND_SEC_ (legacy) / MND_ENC2 (новый быстрый).
      // Rust пишет напрямую в tempDir и возвращает questId.
      final originalQuestId = await rust_archive.questArchiveImport(
        mndPath: filePath,
        destDir: tempDir.path,
      );

      print('✅ [Import] Архив распакован Rust-стримом во временную директорию.');
      print('✨ [Import] Обнаружен ID квеста в архиве: $originalQuestId');

      // Находим config.json в распакованном дереве (Rust уже извлёк все файлы).
      // Ищем questRootInTemp: директория где лежит config.json
      String? questRootInTempPath;
      // Быстрый поиск: если config в корне temp — то temp и есть корень
      if (await File(p.join(tempDir.path, 'config.json')).exists()) {
        questRootInTempPath = tempDir.path;
      } else {
        // Рекурсивный поиск первого config.json
        await for (final entity in tempDir.list(recursive: true)) {
          if (entity is File && p.basename(entity.path) == 'config.json') {
            questRootInTempPath = entity.parent.path;
            break;
          }
        }
      }
      if (questRootInTempPath == null) {
        throw Exception(
          tr(
            'Файл "config.json" не найден в архиве. Это не квест Meander.',
          ),
        );
      }
      final questRootInTemp = Directory(questRootInTempPath);
      // Проверяем что id из Rust совпадает с config (на всякий)
      final tempConfigFile = File(p.join(questRootInTemp.path, 'config.json'));
      final configContent = await tempConfigFile.readAsString();
      final configData = jsonDecode(configContent) as Map<String, dynamic>;
      final cfgId = configData['id'] as String?;
      final effectiveId = (cfgId != null && cfgId.isNotEmpty) ? cfgId : originalQuestId;
      if (effectiveId.isEmpty) {
        throw Exception(tr('ID квеста не найден в config.json.'));
      }
      if (!QuestPaths.isSafeQuestId(effectiveId)) {
        throw Exception(
          trf('ID квеста недопустим: «{p0}». Архив повреждён или опасен.', {
            'p0': effectiveId,
          }),
        );
      }
      // Дальше используем effectiveId
      final importId = effectiveId;

      onProgress?.call(tr('Сохранение квеста...'));
      onProgressUpdate?.call(0.8);

      final newQuestPath = await FileStorage.getFilePath(
        p.join(QuestPaths.questsDir, importId),
      );

      // Бэкап сейвов перед перезаписью квеста
      final Map<String, List<int>> savedFilesBackup = {};
      if (await Directory(newQuestPath).exists()) {
        print(
          '⚠️ [Import] Квест с ID $importId уже существует. Перезаписываем...',
        );
        final savesDirPath = p.join(newQuestPath, 'saves');
        final savesDir = Directory(savesDirPath);
        if (await savesDir.exists()) {
          print('💾 [Import] Создаём бэкап сохранений...');
          final saveFiles = savesDir.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.json'),
          );
          for (final saveFile in saveFiles) {
            final fileName = p.basename(saveFile.path);
            savedFilesBackup[fileName] = await saveFile.readAsBytes();
          }
          print(
            '💾 [Import] Забэкаплено сохранений: ${savedFilesBackup.length}',
          );
        }
      }

      // Подмена целиком: падение между удалением и распаковкой больше не
      // оставляет пользователя без старой версии квеста.
      await replaceDirectoryAtomically(
        staging: questRootInTemp,
        target: Directory(newQuestPath),
      );
      print('📁 [Import] Файлы квеста перемещены в постоянное хранилище.');

      // Восстанавливаем сейвы после установки новой версии
      if (savedFilesBackup.isNotEmpty) {
        print('💾 [Import] Восстанавливаем сохранения...');
        final newSavesDirPath = p.join(newQuestPath, 'saves');
        await Directory(newSavesDirPath).create(recursive: true);
        for (final entry in savedFilesBackup.entries) {
          final saveFile = File(p.join(newSavesDirPath, entry.key));
          await saveFile.writeAsBytes(entry.value);
        }
        print(
          '💾 [Import] Восстановлено сохранений: ${savedFilesBackup.length}',
        );
      }

      final finalConfigPath = p.join(
        QuestPaths.questsDir,
        importId,
        'config.json',
      );
      final finalConfigData = await FileStorage.readJsonFile(finalConfigPath);
      // Помечаем как только что открытый — чтобы импортированный квест
      // оказался в самом верху библиотеки (сортировка по openedDate desc).
      finalConfigData['lastOpened'] = DateTime.now().toIso8601String();
      await FileStorage.writeJsonFile(finalConfigPath, finalConfigData);

      onProgress?.call(tr('Завершение...'));
      onProgressUpdate?.call(0.95);

      print('🎉 [Import] Квест "$importId" успешно импортирован!');
      return importId;
    } catch (e) {
      print('❌ [Import] КРИТИЧЕСКАЯ ОШИБКА во время импорта квеста: $e');
      rethrow;
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      onProgressUpdate?.call(1.0);
    }
  }

  /// Импорт квеста из формата URQ (.qst, .urq)
  static Future<String?> _importQuestFromQst(
    String filePath, {
    Function(String status)? onProgress,
    Function(double progress)? onProgressUpdate,
  }) async {
    try {
      onProgress?.call(tr('Чтение файла URQ...'));
      onProgressUpdate?.call(0.1);

      final importer = QstImporter();
      final importResult = await importer.importFile(filePath);

      if (!importResult.success) {
        throw Exception(importResult.error ?? tr('Неизвестная ошибка импорта URQ'));
      }

      onProgress?.call(tr('Сохранение квеста...'));
      onProgressUpdate?.call(0.5);

      // Сохраняем импортированный квест
      await saveImportedQuest(
        quest: importResult.quest!,
        nodes: importResult.nodes!,
        scripts: importResult.scripts,
      );

      onProgress?.call(tr('Завершение...'));
      onProgressUpdate?.call(0.95);

      print(
        '🎉 [Import] Квест "${importResult.quest!.title}" успешно импортирован из URQ!',
      );

      if (importResult.warnings.isNotEmpty) {
        print(
          '⚠️ [Import] Предупреждения при импорте: ${importResult.warnings.length}',
        );
      }

      return importResult.quest!.id;
    } catch (e) {
      print('❌ [Import] Ошибка импорта URQ: $e');
      rethrow;
    } finally {
      onProgressUpdate?.call(1.0);
    }
  }
}
