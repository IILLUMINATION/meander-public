import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_core/src/gen/api/quest_archive.dart' as rust_archive;
import 'package:canvas_app/core/l10n/l10n.dart';

/// Формат нод внутри экспортного `.mnd`.
enum QuestArchiveNodesFormat {
  /// `nodes/index.json` + `nodes/<id>.json` — новый плеер.
  perNode,

  /// Единый `nodes.json` / `nodes/nodes.json` — старые плееры и веб.
  legacy,
}

class ExportService {
  static final _zipHeader = utf8.encode('MND_ZIP_');

  /// Гарантирует v2-индекс перед экспортом нового формата.
  static Future<void> _ensureV2Index(String questId) async {
    if (await QuestNodesStore.hasPerNodeIndex(questId)) return;
    await QuestNodesStore.ensurePerNode(questId);
    if (await QuestNodesStore.hasPerNodeIndex(questId)) return;

    // Старые файлы есть, но миграция не сработала — молча экспортировать
    // пустой индекс нельзя, иначе в архиве не будет нод.
    if (await FileStorage.exists(QuestPaths.nodesLegacy(questId)) ||
        await FileStorage.exists(QuestPaths.nodesCanonical(questId))) {
      throw Exception(
        'Не удалось перевести ноды в новый формат перед экспортом',
      );
    }

    // Пустой квест: ensure ничего не пишет, но для нового формата нужен индекс.
    final qs = await QuestStore.defaultInstance();
    await qs.writeJson(QuestPaths.nodesIndex(questId), {
      QuestNodesStore.formatVersionKey: QuestNodesStore.perNodeFormatVersion,
      'nodes': <dynamic>[],
      'groups': <dynamic>[],
      'comments': <dynamic>[],
      'edges': <dynamic>[],
    });
  }

  /// Экспорт квеста в один .txt файл для чтения и разбора
  /// Содержит: конфиг, ноды, все скрипты с заменой UUID на короткие ID
  static Future<bool> exportQuestAsTxt(
    String questId,
    String questTitle,
  ) async {
    try {
      final questPath = QuestPaths.questRoot(questId);
      if (!await FileStorage.exists(questPath)) {
        throw Exception(tr('Квест не найден для экспорта'));
      }

      final txtContent = await _buildTxtContent(questId, questTitle);
      final success = await _saveTxtFile(txtContent, questTitle);
      return success;
    } catch (e) {
      print('❌ Ошибка экспорта в TXT: $e');
      rethrow;
    }
  }

  /// Построение содержимого TXT файла
  static Future<String> _buildTxtContent(
    String questId,
    String questTitle,
  ) async {
    final buffer = StringBuffer();
    final questBasePath = QuestPaths.questRoot(questId);

    // === ЗАГОЛОВОК ===
    buffer.writeln('═' * 80);
    buffer.writeln('ЭКСПОРТ КВЕСТА: $questTitle');
    buffer.writeln('ID: $questId');
    buffer.writeln('Дата экспорта: ${DateTime.now().toIso8601String()}');
    buffer.writeln('═' * 80);
    buffer.writeln();

    // === CONFIG ===
    buffer.writeln('═' * 80);
    buffer.writeln('РАЗДЕЛ 1: КОНФИГУРАЦИЯ (config.json)');
    buffer.writeln('═' * 80);
    final configPath = p.join(questBasePath, 'config.json');
    if (await FileStorage.exists(configPath)) {
      final configData = await FileStorage.readJsonFile(configPath);
      final configWithShortIds = _replaceUuidsWithShortIds(configData);
      final encoder = JsonEncoder.withIndent('  ');
      buffer.writeln(encoder.convert(configWithShortIds));
    } else {
      buffer.writeln('❌ config.json не найден');
    }
    buffer.writeln();

    // === NODES ===
    buffer.writeln('═' * 80);
    buffer.writeln('РАЗДЕЛ 2: НОДЫ (nodes.json)');
    buffer.writeln('═' * 80);
    bool hasNodes = false;
    Map<String, dynamic>? nodesData;
    if (await QuestNodesStore.hasPerNodeIndex(questId)) {
      nodesData = await QuestNodesStore.readAll(questId);
    } else {
      const nodeCandidates = ['nodes.json', 'nodes/nodes.json'];
      for (final nodeRelPath in nodeCandidates) {
        final filePath = p.join(questBasePath, nodeRelPath);
        if (await FileStorage.exists(filePath)) {
          nodesData = await FileStorage.readJsonFile(filePath);
          break;
        }
      }
    }
    if (nodesData != null) {
      final nodesWithShortIds = _replaceUuidsWithShortIds(nodesData);
      final encoder = JsonEncoder.withIndent('  ');
      buffer.writeln(encoder.convert(nodesWithShortIds));
      hasNodes = true;
    }
    if (!hasNodes) {
      buffer.writeln('⚠️ nodes.json не найден');
    }
    buffer.writeln();

    // === SCRIPTS ===
    buffer.writeln('═' * 80);
    buffer.writeln('РАЗДЕЛ 3: СКРИПТЫ');
    buffer.writeln('═' * 80);

    const scriptFolders = ['scripts', '_internal_scripts'];
    int scriptCount = 0;

    for (final folderName in scriptFolders) {
      final dirPath = await FileStorage.getFilePath(
        p.join(questBasePath, folderName),
      );
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        buffer.writeln();
        buffer.writeln('--- Папка: $folderName ---');
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File && entity.path.endsWith('.json')) {
            final fileName = p.basename(entity.path);
            final scriptData = jsonDecode(await entity.readAsString());
            final scriptWithShortIds = _replaceUuidsWithShortIds(scriptData);
            final encoder = JsonEncoder.withIndent('  ');

            buffer.writeln();
            buffer.writeln('📄 Скрипт: $folderName/$fileName');
            buffer.writeln('-' * 60);
            buffer.writeln(encoder.convert(scriptWithShortIds));
            scriptCount++;
          }
        }
      }
    }

    if (scriptCount == 0) {
      buffer.writeln();
      buffer.writeln('⚠️ Скрипты не найдены');
    }

    buffer.writeln();
    buffer.writeln('═' * 80);
    buffer.writeln('КОНЕЦ ЭКСПОРТА');
    buffer.writeln('Всего скриптов: $scriptCount');
    buffer.writeln('═' * 80);

    return buffer.toString();
  }

  /// Заменяет длинные UUID на короткие идентификаторы для краткости
  /// UUID формат: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 символов)
  /// Заменяем на: ID_1, ID_2, и т.д.
  static Map<String, dynamic> _replaceUuidsWithShortIds(
    Map<String, dynamic> data,
  ) {
    final uuidMap = <String, String>{};
    int counter = 0;

    String getShortId(String uuid) {
      if (!uuidMap.containsKey(uuid)) {
        uuidMap[uuid] = 'ID_${++counter}';
      }
      return uuidMap[uuid]!;
    }

    return _processMap(data, getShortId);
  }

  static Map<String, dynamic> _processMap(
    Map<String, dynamic> map,
    String Function(String) getShortId,
  ) {
    final result = <String, dynamic>{};
    for (final entry in map.entries) {
      final value = entry.value;
      if (value is String &&
          value.length >= 20 &&
          RegExp(r'^[0-9a-f-]+$', caseSensitive: false).hasMatch(value)) {
        result[entry.key] = getShortId(value);
      } else if (value is Map<String, dynamic>) {
        result[entry.key] = _processMap(value, getShortId);
      } else if (value is List) {
        result[entry.key] = value.map((e) {
          if (e is String &&
              e.length >= 20 &&
              RegExp(r'^[0-9a-f-]+$', caseSensitive: false).hasMatch(e)) {
            return getShortId(e);
          } else if (e is Map<String, dynamic>) {
            return _processMap(e, getShortId);
          }
          return e;
        }).toList();
      } else {
        result[entry.key] = value;
      }
    }
    return result;
  }

  static Future<bool> _saveTxtFile(String content, String questTitle) async {
    try {
      final safeTitle = questTitle.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_');
      final fileName = '$safeTitle.txt';

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final result = await FilePicker.saveFile(
          dialogTitle: tr('Сохранить экспорт квеста'),
          fileName: fileName,
          bytes: Uint8List.fromList(utf8.encode(content)),
          type: FileType.custom,
          allowedExtensions: ['txt'],
        );

        if (result != null) {
          print('✅ [Export TXT] Файл сохранен: $result');
          return true;
        }
        return false;
      } else {
        final tempDir = await getTemporaryDirectory();
        final tempFilePath = p.join(tempDir.path, fileName);
        final tempFile = File(tempFilePath);
        await tempFile.writeAsString(content);

        final params = SaveFileDialogParams(
          sourceFilePath: tempFile.path,
          fileName: fileName,
        );
        final result = await FlutterFileDialog.saveFile(params: params);
        await tempFile.delete();

        return result != null;
      }
    } catch (e) {
      print('❌ Ошибка сохранения .txt файла: $e');
      rethrow;
    }
  }

  static Future<bool> exportQuestAsMnd(
    String questId,
    String questTitle, {
    bool includeSaves = false,
    bool isProtected = false,
    QuestArchiveNodesFormat nodesFormat = QuestArchiveNodesFormat.perNode,
  }) async {
    try {
      final questPath = QuestPaths.questRoot(questId);
      if (!await FileStorage.exists(questPath)) {
        throw Exception(tr('Квест не найден для экспорта'));
      }

      final tempFile = await createMndTempFile(
        questId,
        includeSaves: includeSaves,
        isProtected: isProtected,
        nodesFormat: nodesFormat,
      );
      final success = await _saveMndFileFromTemp(tempFile, questTitle);

      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}

      return success;
    } catch (e) {
      print('❌ CRITICAL EXPORT ERROR: $e');
      rethrow;
    }
  }

  /// Собирает `.mnd` напрямую во временный файл, не держа архив целиком в RAM.
  ///
  /// На слабых устройствах сборка через [createMndFile] (весь zip + копии в
  /// памяти) приводит к OutOfMemory. Этот вариант пишет zip потоково через
  /// [OutputFileStream], добавляя файлы по одному, и возвращает путь к готовому
  /// временному `.mnd`. Вызывающий обязан удалить файл после использования.
  ///
  /// В отличие от [createMndFile], НЕ требует валидного `config.json` —
  /// упаковывает его «как есть» (важно для восстановления повреждённых квестов).
  static Future<File> createMndTempFile(
    String questId, {
    bool includeSaves = false,
    bool isProtected = false,
    QuestArchiveNodesFormat nodesFormat = QuestArchiveNodesFormat.perNode,
  }) async {
    print(
      '⚙️ [Export] Rust streaming .mnd file to disk... isProtected=$isProtected includeSaves=$includeSaves',
    );
    final questBasePath = QuestPaths.questRoot(questId);
    final questDir = await FileStorage.getFilePath(questBasePath);

    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final outFile = File(p.join(tempDir.path, 'export_${questId}_$stamp.mnd'));

    // Делегируем в Rust: стрим 64КБ, Argon2+ChaCha для ENC2, plain для ZIP.
    // Rust сам ставит isReadOnly+signature для защищённых.
    try {
      final perNode = nodesFormat == QuestArchiveNodesFormat.perNode;
      if (perNode) await _ensureV2Index(questId);
      await rust_archive.questArchiveExportFull(
        questDir: questDir,
        mndPath: outFile.path,
        password: isProtected ? 'protected' : null,
        includeSaves: includeSaves,
        isProtected: isProtected,
        perNodeNodes: perNode,
      );
    } catch (e) {
      // Fallback на Dart-стрим если Rust по какой-то причине не справился
      print('⚠️ [Export] Rust export failed ($e), fallback to Dart stream');
      return await _createMndTempFileDart(
        questId,
        includeSaves: includeSaves,
        isProtected: isProtected,
        nodesFormat: nodesFormat,
      );
    }

    print(
      '📦 [Export] .mnd via Rust. Size: ${await outFile.length()} bytes -> '
      '${outFile.path}',
    );
    return outFile;
  }

  // Dart fallback (старый стрим) — на случай если Rust недоступен
  static Future<File> _createMndTempFileDart(
    String questId, {
    bool includeSaves = false,
    bool isProtected = false,
    QuestArchiveNodesFormat nodesFormat = QuestArchiveNodesFormat.perNode,
  }) async {
    print('⚙️ [Export] Dart fallback streaming .mnd file to disk...');
    final questBasePath = QuestPaths.questRoot(questId);

    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final zipFile = File(p.join(tempDir.path, 'export_${questId}_$stamp.zip'));
    final outFile = File(p.join(tempDir.path, 'export_${questId}_$stamp.mnd'));
    File? tempConfigForProtect;
    final zipEncoder = ZipFileEncoder();
    zipEncoder.createWithStream(OutputFileStream(zipFile.path));
    try {
      Future<void> addFile(String archivePath, String fsPath) async {
        await zipEncoder.addFile(File(fsPath), archivePath);
      }

      final configPath = p.join(questBasePath, 'config.json');
      final hasConfig = await FileStorage.exists(configPath);
      if (hasConfig) {
        if (isProtected) {
          final configData = await FileStorage.readJsonFile(configPath);
          configData['isReadOnly'] = true;
          // подпись теперь делает Rust, тут оставляем совместимость
          tempConfigForProtect = File(
            p.join(tempDir.path, 'config_prot_${questId}_$stamp.json'),
          );
          await tempConfigForProtect.writeAsString(jsonEncode(configData));
          await addFile('config.json', tempConfigForProtect.path);
        } else {
          await addFile(
            'config.json',
            await FileStorage.getFilePath(configPath),
          );
        }
      }
      if (nodesFormat == QuestArchiveNodesFormat.perNode) {
        await _ensureV2Index(questId);
        for (final name in await FileStorage.listFiles(
          QuestPaths.nodesDir(questId),
          extension: '.json',
        )) {
          if (name == 'nodes.json') continue;
          await addFile(
            'nodes/$name',
            await FileStorage.getFilePath(
              '${QuestPaths.nodesDir(questId)}/$name',
            ),
          );
        }
      } else if (await QuestNodesStore.hasPerNodeIndex(questId)) {
        final nodesPath = p.join(
          tempDir.path,
          'v2_nodes_${questId}_$stamp.json',
        );
        final nodesFile = File(nodesPath);
        await nodesFile.writeAsString(
          jsonEncode(await QuestNodesStore.readAll(questId)),
        );
        await addFile('nodes.json', nodesPath);
        await addFile('nodes/nodes.json', nodesPath);
        await nodesFile.delete();
      } else {
        const nodeCandidates = ['nodes.json', 'nodes/nodes.json'];
        for (final nodeRelPath in nodeCandidates) {
          final filePath = p.join(questBasePath, nodeRelPath);
          if (await FileStorage.exists(filePath)) {
            await addFile(
              'nodes.json',
              await FileStorage.getFilePath(filePath),
            );
            break;
          }
        }
      }
      String? previewFileName;
      if (hasConfig) {
        try {
          final configFile = File(await FileStorage.getFilePath(configPath));
          final decoded = jsonDecode(await configFile.readAsString());
          if (decoded is Map)
            previewFileName = decoded['previewFileName']?.toString();
        } catch (_) {}
      }
      if (previewFileName != null && previewFileName.isNotEmpty) {
        final previewPath = p.join(questBasePath, previewFileName);
        if (await FileStorage.exists(previewPath)) {
          await addFile(
            previewFileName,
            await FileStorage.getFilePath(previewPath),
          );
        }
      } else {
        final fallbackPreviewPath = p.join(questBasePath, 'preview.png');
        if (await FileStorage.exists(fallbackPreviewPath)) {
          await addFile(
            'preview.png',
            await FileStorage.getFilePath(fallbackPreviewPath),
          );
        }
      }
      const foldersToInclude = ['res', 'scripts', '_internal_scripts'];
      for (final folderName in foldersToInclude) {
        final dirPath = await FileStorage.getFilePath(
          p.join(questBasePath, folderName),
        );
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          await _addDirectoryToEncoder(zipEncoder, dir, folderName, addFile);
        }
      }
      if (includeSaves) {
        final savesDirPath = await FileStorage.getFilePath(
          p.join(questBasePath, 'saves'),
        );
        final savesDir = Directory(savesDirPath);
        if (await savesDir.exists()) {
          await _addDirectoryToEncoder(zipEncoder, savesDir, 'saves', addFile);
        }
      }
      await zipEncoder.close();
    } catch (e) {
      try {
        await zipEncoder.close();
      } catch (_) {}
      try {
        await zipFile.delete();
      } catch (_) {}
      rethrow;
    }
    final sink = outFile.openWrite();
    try {
      sink.add(_zipHeader);
      await sink.addStream(zipFile.openRead());
    } finally {
      await sink.close();
    }
    try {
      await zipFile.delete();
      if (tempConfigForProtect != null && await tempConfigForProtect.exists())
        await tempConfigForProtect.delete();
    } catch (_) {}
    print(
      '📦 [Export] .mnd Dart fallback. Size: ${await outFile.length()} bytes -> ${outFile.path}',
    );
    return outFile;
  }

  /// Рекурсивно добавляет файлы директории в потоковый [ZipFileEncoder].
  static Future<void> _addDirectoryToEncoder(
    ZipFileEncoder encoder,
    Directory dir,
    String parentPath,
    Future<void> Function(String archivePath, String fsPath) addFile,
  ) async {
    await for (final entity in dir.list(recursive: false)) {
      final entityName = p.basename(entity.path);
      final archivePath = p.join(parentPath, entityName).replaceAll('\\', '/');
      if (entity is File) {
        await addFile(archivePath, entity.path);
      } else if (entity is Directory) {
        await _addDirectoryToEncoder(encoder, entity, archivePath, addFile);
      }
    }
  }

  static Future<Uint8List> createMndFile(
    String questId, {
    QuestArchiveNodesFormat nodesFormat = QuestArchiveNodesFormat.perNode,
  }) async {
    print('⚙️ [Export] Assembling .mnd file...');
    final archive = Archive();
    final questBasePath = QuestPaths.questRoot(questId);

    // config.json is required
    final configPath = p.join(questBasePath, 'config.json');
    if (await FileStorage.exists(configPath)) {
      final configFile = File(await FileStorage.getFilePath(configPath));
      final configBytes = await configFile.readAsBytes();
      archive.addFile(
        ArchiveFile('config.json', configBytes.length, configBytes),
      );
    } else {
      throw Exception(tr('Критический файл config.json не найден.'));
    }

    // nodes can live in either path depending on quest origin/version.
    bool hasNodes = false;
    if (nodesFormat == QuestArchiveNodesFormat.perNode) {
      await _ensureV2Index(questId);
      for (final name in await FileStorage.listFiles(
        QuestPaths.nodesDir(questId),
        extension: '.json',
      )) {
        if (name == 'nodes.json') continue;
        final file = File(
          await FileStorage.getFilePath(
            '${QuestPaths.nodesDir(questId)}/$name',
          ),
        );
        final bytes = await file.readAsBytes();
        archive.addFile(ArchiveFile('nodes/$name', bytes.length, bytes));
        hasNodes = true;
      }
    } else if (await QuestNodesStore.hasPerNodeIndex(questId)) {
      final bytes = utf8.encode(
        jsonEncode(await QuestNodesStore.readAll(questId)),
      );
      archive.addFile(ArchiveFile('nodes.json', bytes.length, bytes));
      archive.addFile(ArchiveFile('nodes/nodes.json', bytes.length, bytes));
      hasNodes = true;
    } else {
      const nodeCandidates = ['nodes.json', 'nodes/nodes.json'];
      for (final nodeRelPath in nodeCandidates) {
        final filePath = p.join(questBasePath, nodeRelPath);
        if (await FileStorage.exists(filePath)) {
          final file = File(await FileStorage.getFilePath(filePath));
          final bytes = await file.readAsBytes();
          archive.addFile(ArchiveFile('nodes.json', bytes.length, bytes));
          hasNodes = true;
          break;
        }
      }
    }
    if (!hasNodes) {
      print(
        '⚠️ [Export] nodes.json not found, exporting without nodes payload.',
      );
    }

    // Preview (best effort, never fail export)
    String? previewFileName;
    try {
      final configFile = File(await FileStorage.getFilePath(configPath));
      final configContent = await configFile.readAsString();
      final decoded = jsonDecode(configContent);
      if (decoded is Map) {
        previewFileName = decoded['previewFileName']?.toString();
      }
    } catch (e) {
      print('⚠️ [Export] Failed to parse previewFileName from config.json: $e');
    }

    if (previewFileName != null && previewFileName.isNotEmpty) {
      final previewPath = p.join(questBasePath, previewFileName);
      if (await FileStorage.exists(previewPath)) {
        final file = File(await FileStorage.getFilePath(previewPath));
        final bytes = await file.readAsBytes();
        archive.addFile(ArchiveFile(previewFileName, bytes.length, bytes));
      }
    } else {
      final fallbackPreviewPath = p.join(questBasePath, 'preview.png');
      if (await FileStorage.exists(fallbackPreviewPath)) {
        final file = File(await FileStorage.getFilePath(fallbackPreviewPath));
        final bytes = await file.readAsBytes();
        archive.addFile(ArchiveFile('preview.png', bytes.length, bytes));
      }
    }

    // Resources
    const foldersToInclude = ['res', 'scripts', '_internal_scripts'];
    for (final folderName in foldersToInclude) {
      final dirPath = await FileStorage.getFilePath(
        p.join(questBasePath, folderName),
      );
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await _addDirectoryToArchive(archive, dir, folderName);
      }
    }

    final unencryptedZipBytes = ZipEncoder().encode(archive);
    final zipAsUint8List = Uint8List.fromList(unencryptedZipBytes);

    final builder = BytesBuilder();
    builder.add(_zipHeader);
    builder.add(zipAsUint8List);
    print('📦 [Export] .mnd assembled. Size: ${builder.length} bytes.');
    return builder.toBytes();
  }

  static Future<void> _addDirectoryToArchive(
    Archive archive,
    Directory dir,
    String parentPath,
  ) async {
    await for (final entity in dir.list(recursive: false)) {
      final entityName = p.basename(entity.path);
      // Important: replace backslashes for ZIP compatibility
      final archivePath = p.join(parentPath, entityName).replaceAll('\\', '/');

      if (entity is File) {
        final bytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
      } else if (entity is Directory) {
        await _addDirectoryToArchive(archive, entity, archivePath);
      }
    }
  }

  static Future<bool> _saveMndFileFromTemp(
    File tempFile,
    String questTitle,
  ) async {
    try {
      final safeTitle = questTitle.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_');
      final fileName = '$safeTitle.mnd';

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        // Десктоп: не грузим весь файл в RAM (было readAsBytes 200МБ).
        // file_picker saveFile требует bytes, поэтому спрашиваем директорию и копируем стримом.
        final dir = await FilePicker.getDirectoryPath(
          dialogTitle: tr('Сохранить квест'),
        );
        if (dir != null) {
          final dest = p.join(dir, fileName);
          final src = tempFile.openRead();
          final dst = File(dest).openWrite();
          await dst.addStream(src);
          await dst.close();
          print('✅ [Export] File saved (Desktop stream): $dest');
          return true;
        }
        // Fallback на старый saveFile с bytes если директорию не выбрали (малые файлы)
        final result = await FilePicker.saveFile(
          dialogTitle: 'Save Quest',
          fileName: fileName,
          bytes: await tempFile.readAsBytes(),
          type: FileType.custom,
          allowedExtensions: ['mnd'],
        );
        if (result != null) {
          print('✅ [Export] File saved (Desktop): $result');
          return true;
        }
        return false;
      } else {
        final params = SaveFileDialogParams(
          sourceFilePath: tempFile.path,
          fileName: fileName,
        );
        final result = await FlutterFileDialog.saveFile(params: params);
        return result != null;
      }
    } catch (e) {
      print('❌ Error saving .mnd file: $e');
      rethrow;
    }
  }
}
