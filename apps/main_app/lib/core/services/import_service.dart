// --- НАЧАЛО ПОЛНОГО И ИСПРАВЛЕННОГО ФАЙЛА lib/core/services/import_service.dart ---

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/key_derivation_service.dart';
import 'package:collection/collection.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';

class ImportService {
  static final _encryptedHeader = utf8.encode('MND_ENC_');
  static final _securedHeader = utf8.encode('MND_SEC_');
  static final _zipHeader = utf8.encode('MND_ZIP_');
  static const _headerLength = 8;

  /// Относительный путь записи архива, безопасный для join под корнем, или
  /// `null`, если запись пытается выйти за пределы каталога (Защита от
  /// Zip Slip). Чистая функция — доступна для unit-тестов.
  ///
  /// Отбрасывает абсолютные пути (POSIX и Windows-диски), сегменты `..` и
  /// нормализует `.`/пустые сегменты.
  static String? sanitizeArchiveEntryPath(String rawName) {
    final normalized = rawName.replaceAll('\\', '/');
    if (normalized.startsWith('/')) return null;
    if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return null;
    final clean = <String>[];
    for (final seg in normalized.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') return null;
      clean.add(seg);
    }
    if (clean.isEmpty) return null;
    return clean.join('/');
  }

  static Future<String?> pickAndImportQuest() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);

      if (files.isEmpty || files.single.path == null) {
        print('ℹ️ [Import] Пользователь отменил выбор файла.');
        return null;
      }

      final filePath = files.single.path!;

      // +++ НАЧАЛО ИЗМЕНЕНИЯ: ГИБКАЯ ПРОВЕРКА ИМЕНИ ФАЙЛА +++
      // Создаем регулярное выражение, которое ищет ".mnd" в конце,
      // за которым опционально могут идти пробелы и "(число)".
      // caseSensitive: false делает проверку нечувствительной к регистру (.mnd, .MND и т.д.)
      final mndFileRegex = RegExp(r'\.mnd(\s*\(\d+\))?$', caseSensitive: false);

      if (!mndFileRegex.hasMatch(filePath)) {
        throw Exception(
          tr(
            'Выбран неверный тип файла. Пожалуйста, выберите файл с расширением .mnd',
          ),
        );
      }
      // +++ КОНЕЦ ИЗМЕНЕНИЯ +++

      print('✅ [Import] Файл для импорта выбран: $filePath');
      return await _importQuestFromMnd(filePath);
    } catch (e) {
      print('❌ [Import] Ошибка на этапе выбора файла: $e');
      rethrow;
    }
  }

  static Future<String?> importFromFile(String filePath) async {
    print('✅ [Import] Файл для импорта предоставлен: $filePath');
    return await _importQuestFromMnd(filePath);
  }

  static Future<String?> _importQuestFromMnd(String filePath) async {
    final tempDirPath = p.join(
      await FileStorage.getFilePath('temp'),
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final tempDir = Directory(tempDirPath);
    await tempDir.create(recursive: true);

    try {
      print('⚙️ [Import] Начало импорта квеста...');
      final fileBytes = await File(filePath).readAsBytes();
      Archive archive;

      const listEquals = ListEquality<int>();
      bool hasHeader = fileBytes.length > _headerLength;
      final header = hasHeader ? fileBytes.sublist(0, _headerLength) : null;

      Uint8List payload;
      bool isPotentiallyEncrypted;

      if (hasHeader && listEquals.equals(header, _securedHeader)) {
        print("➡️ [Import] Обнаружен защищенный файл формата (MND_SEC_).");
        payload = fileBytes.sublist(_headerLength);
        isPotentiallyEncrypted = true;
      } else if (hasHeader && listEquals.equals(header, _encryptedHeader)) {
        print(
          "➡️ [Import] Обнаружен зашифрованный файл старого формата (MND_ENC_).",
        );
        throw Exception(
          tr(
            "Старый формат шифрования MND_ENC_ больше не поддерживается. Попросите автора пересохранить квест в новой версии приложения.",
          ),
        );
      } else if (hasHeader && listEquals.equals(header, _zipHeader)) {
        print(
          "➡️ [Import] Обнаружен НЕшифрованный файл нового формата (MND_ZIP_).",
        );
        payload = fileBytes.sublist(_headerLength);
        isPotentiallyEncrypted = false;
      } else {
        print(
          "⚠️ [Import] Заголовок не найден. Предполагается файл старого формата (зашифрованный).",
        );
        payload = fileBytes;
        isPotentiallyEncrypted = true;
      }

      try {
        if (isPotentiallyEncrypted) {
          print("   -> Попытка 1: Расшифровать и распаковать...");
          final decryptedData = KeyDerivationService.decryptProtectedQuestData(
            payload,
          );
          archive = ZipDecoder().decodeBytes(decryptedData);
          print("   -> ✅ УСПЕХ! Файл расшифрован.");
        } else {
          throw Exception("Пропуск расшифровки для MND_ZIP_ файла.");
        }
      } catch (e) {
        print(
          "   -> ⚠️ Ошибка на этапе 1 ($e). Попытка 2: Распаковать как простой ZIP...",
        );
        try {
          archive = ZipDecoder().decodeBytes(payload);
          print("   -> ✅ УСПЕХ! Файл оказался простым ZIP-архивом.");
        } catch (zipError) {
          print("   -> ❌ Ошибка на этапе 2 ($zipError). Импорт невозможен.");
          throw Exception(
            tr(
              "Не удалось распознать формат файла. Файл поврежден или не является квестом Meander.",
            ),
          );
        }
      }

      for (final file in archive) {
        final relative = sanitizeArchiveEntryPath(file.name);
        if (relative == null) {
          throw Exception(
            tr(
              'Архив содержит недопустимый путь файла (zip-slip). Импорт отменён.',
            ),
          );
        }
        final filename = p.join(tempDir.path, relative);
        if (file.isFile) {
          final data = file.content as List<int>;
          final outFile = File(filename);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(data);
        } else {
          await Directory(filename).create(recursive: true);
        }
      }
      print('✅ [Import] Архив успешно распакован во временную директорию.');

      final configEntry = archive.files.firstWhereOrNull(
        (file) => p.basename(file.name.replaceAll('\\', '/')) == 'config.json',
      );

      if (configEntry == null) {
        throw Exception(
          tr('Файл "config.json" не найден в архиве. Это не квест Meander.'),
        );
      }

      final tempConfigPath = p.join(
        tempDir.path,
        configEntry.name.replaceAll('\\', '/'),
      );
      final tempConfigFile = File(tempConfigPath);

      final questRootInTemp = tempConfigFile.parent;

      final configContent = await tempConfigFile.readAsString();
      final configData = jsonDecode(configContent) as Map<String, dynamic>;
      final originalQuestId = configData['id'] as String?;

      if (originalQuestId == null || originalQuestId.isEmpty) {
        throw Exception(tr('ID квеста не найден в config.json.'));
      }
      if (!QuestPaths.isSafeQuestId(originalQuestId)) {
        throw Exception(
          tr(
            'ID квеста недопустим: "$originalQuestId". Архив повреждён или опасен.',
          ),
        );
      }
      print('✨ [Import] Обнаружен ID квеста в архиве: $originalQuestId');

      final newQuestPath = await FileStorage.getFilePath(
        p.join(QuestPaths.questsDir, originalQuestId),
      );

      if (await Directory(newQuestPath).exists()) {
        print(
          '⚠️ [Import] Квест с ID $originalQuestId уже существует. Перезаписываем...',
        );
        await Directory(newQuestPath).delete(recursive: true);
      }

      await questRootInTemp.rename(newQuestPath);
      print('📁 [Import] Файлы квеста перемещены в постоянное хранилище.');

      final finalConfigPath = p.join(
        QuestPaths.questsDir,
        originalQuestId,
        'config.json',
      );
      final finalConfigData = await FileStorage.readJsonFile(finalConfigPath);
      finalConfigData['lastOpened'] = null;
      await FileStorage.writeJsonFile(finalConfigPath, finalConfigData);

      print('🎉 [Import] Квест "$originalQuestId" успешно импортирован!');
      return originalQuestId;
    } catch (e) {
      print('❌ [Import] КРИТИЧЕСКАЯ ОШИБКА во время импорта квеста: $e');
      rethrow;
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }
}
