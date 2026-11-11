import 'dart:io';
import 'package:archive/archive.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';

import '../utils/archive_entry_paths.dart';

/// Снимок состояния квеста в `_history/` — zip всех файлов квеста
/// (ресурсы включительно, иначе откат удалил бы их).
class SnapshotInfo {
  final String fileName;
  final DateTime timestamp;
  final int sizeBytes;

  SnapshotInfo({
    required this.fileName,
    required this.timestamp,
    required this.sizeBytes,
  });

  /// Авто-снимок, сделанный при открытии квеста (не вручную).
  bool get isAuto => fileName.startsWith(LocalHistoryService.autoPrefix);

  /// Снимок уже повреждённого состояния — делается перед откатом,
  /// чтобы ничего не потерять безвозвратно.
  bool get isBroken => fileName.startsWith(LocalHistoryService.brokenPrefix);
}

class LocalHistoryService {
  /// Каталог снимков внутри папки квеста.
  static const String historyFolder = '_history';

  static const String _historyFolder = historyFolder;

  /// Снимок по явной команде пользователя — не удаляется автоочисткой.
  static const String manualPrefix = 'backup_';

  /// Снимок при открытии квеста; хранится последние
  /// [autoSnapshotsToKeep] штук на квест.
  static const String autoPrefix = 'auto_';

  /// Копия повреждённого состояния перед откатом.
  static const String brokenPrefix = 'broken_';

  static const int autoSnapshotsToKeep = 10;
  static const int brokenSnapshotsToKeep = 3;

  /// Не чаще одного авто-снимка на квест: редактор открывают повторно
  /// десятки раз за сессию, полная копия на каждое открытие — лишний I/O.
  static const Duration autoSnapshotMinInterval = Duration(minutes: 10);

  /// Квест крупнее этого авто-снимком не страхуем: полная копия папки с
  /// ресурсами весит сотни мегабайт, а снимок делается при открытии.
  static const int autoSnapshotMaxPayloadBytes = 200 * 1024 * 1024;

  static const List<String> _prefixes = [manualPrefix, autoPrefix, brokenPrefix];

  // --- DIAGNOSTIC: Read node count from disk ---
  static Future<int> _debugCountNodesOnDisk(String questId) async {
    try {
      final json = await QuestNodesStore.read(questId);
      return (json['nodes'] as List? ?? const []).length;
    } catch (e) {
      print('⚠️ [History Debug] Error reading nodes.json: $e');
      return -1;
    }
  }

  /// Ручной снимок (кнопка «Создать копию» и вызовы из чистки/тегов).
  static Future<void> createSnapshot(String questId) async {
    await _writeSnapshotZip(questId, manualPrefix);
  }

  /// Авто-снимок при открытии квеста.
  ///
  /// Пропускается, если свежий авто-снимок уже есть (<
  /// [autoSnapshotMinInterval]) или квест слишком большой. Ручные снимки
  /// не мешают: интервал считается только по авто-снимкам.
  ///
  /// Возвращает имя созданного файла или `null`, если снимок не нужен.
  static Future<String?> autoSnapshotOnOpen(String questId) async {
    final questDir = Directory(
      await FileStorage.getFilePath(QuestPaths.questRoot(questId)),
    );
    if (!await questDir.exists()) return null;

    SnapshotInfo? newestAuto;
    for (final snapshot in await listSnapshots(questId)) {
      if (snapshot.isAuto) {
        newestAuto = snapshot;
        break;
      }
    }
    if (newestAuto != null &&
        DateTime.now().difference(newestAuto.timestamp) <
            autoSnapshotMinInterval) {
      return null;
    }

    if (await _payloadExceeds(questDir, autoSnapshotMaxPayloadBytes)) {
      final limitMegabytes = autoSnapshotMaxPayloadBytes ~/ (1024 * 1024);
      print('⚠️ [History] Авто-снимок пропущен: квест больше $limitMegabytes МБ');
      return null;
    }

    final name = await _writeSnapshotZip(questId, autoPrefix);
    await _prune(questId, autoPrefix, autoSnapshotsToKeep);
    return name;
  }

  /// Копия текущего (уже повреждённого) состояния перед откатом.
  static Future<String?> snapshotBroken(String questId) async {
    final name = await _writeSnapshotZip(questId, brokenPrefix);
    await _prune(questId, brokenPrefix, brokenSnapshotsToKeep);
    return name;
  }

  /// Пишет zip-снимок квеста с заданным префиксом имени.
  static Future<String?> _writeSnapshotZip(
    String questId,
    String prefix,
  ) async {
    // Force wait for file locks to ensure previous writes are done
    return FileStorage.synchronized('nodes_$questId', () async {
      return FileStorage.synchronized('config_$questId', () async {
        try {
          print('📦 [History] === CREATING BACKUP ($prefix) ===');

          // Diagnostic
          final nodeCount = await _debugCountNodesOnDisk(questId);
          print('📦 [History] Nodes on disk before archive: $nodeCount');

          final questPath = await FileStorage.getFilePath(
            QuestPaths.questRoot(questId),
          );
          final questDir = Directory(questPath);

          if (!await questDir.exists()) {
            throw Exception('Quest folder not found: $questPath');
          }

          final archive = Archive();

          await _addDirectoryToArchive(archive, questDir, questDir.path);

          if (archive.isEmpty) {
            print('⚠️ [History] Archive is empty, skipping backup.');
            return null;
          }

          final zipData = ZipEncoder().encode(archive);

          final historyDirPath = await FileStorage.getFilePath(
            QuestPaths.questFile(questId, _historyFolder),
          );
          await Directory(historyDirPath).create(recursive: true);

          final now = DateTime.now();
          final formatter = DateFormat('yyyyMMdd_HHmmss');
          final fileName = '$prefix${formatter.format(now)}.zip';
          final backupFile = File(p.join(historyDirPath, fileName));

          await backupFile.writeAsBytes(zipData, flush: true);

          print(
            '✅ [History] Backup created: $fileName (${zipData.length} bytes)',
          );
          return fileName;
        } catch (e, stack) {
          print('❌ [History] Backup failed: $e');
          print(stack);
          rethrow;
        }
      });
    });
  }

  /// Удаляет старые снимки одного вида, оставляя [keep] самых свежих.
  static Future<void> _prune(String questId, String prefix, int keep) async {
    final all = await listSnapshots(questId);
    final sameKind = all
        .where((snapshot) => snapshot.fileName.startsWith(prefix))
        .toList();
    for (var index = keep; index < sameKind.length; index++) {
      await deleteSnapshot(questId, sameKind[index].fileName);
    }
  }

  /// true, если суммарный размер файлов квеста (без `_history`) превышает
  /// [limit]. Обход прекращается досрочно — большой ресурсный каталог не
  /// должен читаться целиком ради проверки.
  static Future<bool> _payloadExceeds(Directory root, int limit) async {
    var total = 0;
    try {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: root.path);
        if (relative == _historyFolder ||
            relative.startsWith('$_historyFolder${p.separator}')) {
          continue;
        }
        total += await entity.length();
        if (total > limit) return true;
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  static Future<void> _addDirectoryToArchive(
    Archive archive,
    Directory dir,
    String rootPath,
  ) async {
    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      if (p.basename(entity.path) == _historyFolder) continue;

      if (entity is File) {
        final relativePath = p.relative(entity.path, from: rootPath);
        // CRITICAL: Force forward slashes for ZIP spec
        final zipPath = relativePath.replaceAll('\\', '/');

        final bytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile(zipPath, bytes.length, bytes));
      } else if (entity is Directory) {
        await _addDirectoryToArchive(archive, entity, rootPath);
      }
    }
  }

  static final RegExp _snapshotStampPattern = RegExp(
    r'^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$',
  );

  /// Разбор времени из имени снимка; имена старых сборок — `backup_*`.
  ///
  /// Вручную, а не `DateFormat.parse`: парсер intl читает `yyyy` жадно и
  /// спотыкается на `yyyyMMdd` («Trying to read MM at 8»), из-за чего
  /// время бралось из mtime, а оно меняется при копировании снимков.
  static DateTime? _parseSnapshotTimestamp(String fileName) {
    var base = fileName;
    for (final prefix in _prefixes) {
      if (base.startsWith(prefix)) {
        base = base.substring(prefix.length);
        break;
      }
    }
    if (!base.endsWith('.zip')) return null;
    final match = _snapshotStampPattern.firstMatch(
      base.substring(0, base.length - '.zip'.length),
    );
    if (match == null) return null;
    final parts = [
      for (var index = 1; index <= 6; index++) int.parse(match.group(index)!),
    ];
    final value = DateTime(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    // 20261340_120000 разбирается «нормализованно» в январь 2027 —
    // такой снимок лучше считать без даты, чем показать неверную.
    if (value.year != parts[0] ||
        value.month != parts[1] ||
        value.day != parts[2]) {
      return null;
    }
    return value;
  }

  static Future<List<SnapshotInfo>> listSnapshots(String questId) async {
    try {
      final historyDirPath = await FileStorage.getFilePath(
        QuestPaths.questFile(questId, _historyFolder),
      );
      final dir = Directory(historyDirPath);
      if (!await dir.exists()) return [];

      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.zip')) {
          files.add(entity);
        }
      }

      final snapshots = <SnapshotInfo>[];

      for (final file in files) {
        final name = p.basename(file.path);
        final parsed = _parseSnapshotTimestamp(name);
        snapshots.add(
          SnapshotInfo(
            fileName: name,
            timestamp: parsed ?? await file.lastModified(),
            sizeBytes: await file.length(),
          ),
        );
      }

      snapshots.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return snapshots;
    } catch (e) {
      print('Error listing snapshots: $e');
      return [];
    }
  }

  static Future<void> restoreSnapshot(String questId, String fileName) async {
    // Lock files during restore
    await FileStorage.synchronized('nodes_$questId', () async {
      await FileStorage.synchronized('config_$questId', () async {
        try {
          print('🔄 [History] === RESTORING ===');
          print('🔄 [History] File: $fileName');

          final historyDirPath = await FileStorage.getFilePath(
            QuestPaths.questFile(questId, _historyFolder),
          );
          final backupFile = File(p.join(historyDirPath, fileName));

          if (!await backupFile.exists()) {
            throw Exception('Backup file not found');
          }

          final bytes = await backupFile.readAsBytes();
          final archive = ZipDecoder().decodeBytes(bytes);

          final questRootPath = await FileStorage.getFilePath(
            QuestPaths.questRoot(questId),
          );
          final questDir = Directory(questRootPath);

          // 1. AGGRESSIVE CLEANUP: Delete all current quest files except history
          if (await questDir.exists()) {
            await for (final entity in questDir.list(followLinks: false)) {
              if (p.basename(entity.path) == _historyFolder) continue;

              if (entity is File) {
                await entity.delete();
              } else if (entity is Directory) {
                await entity.delete(recursive: true);
              }
            }
            print('🔄 [History] Old files wiped.');
          } else {
            await questDir.create(recursive: true);
          }

          // 2. Unpack
          for (final file in archive) {
            // Снимки можно подменить/собрать руками: пишем только внутрь
            // папки квеста (zip-slip).
            final output = resolveArchiveTarget(questRootPath, file.name);
            if (output == null) {
              print(
                '⚠️ [History] Пропущена запись вне папки квеста: ${file.name}',
              );
              continue;
            }

            if (file.isFile) {
              final data = file.content as List<int>;
              final outFile = File(output);
              await outFile.parent.create(recursive: true);
              await outFile.writeAsBytes(data, flush: true);
            } else {
              await Directory(output).create(recursive: true);
            }
          }

          // 3. Файлы записаны в обход кэша FileStorage: без сброса
          // читатели продолжат отдавать данные, которые только что убрали
          // (и следующий writeJsonFile затрёт откат старым снимком).
          FileStorage.invalidateJsonCache([QuestPaths.questRoot(questId)]);

          // 4. Diagnostic post-restore
          final nodeCount = await _debugCountNodesOnDisk(questId);
          print('✅ [History] Restore complete. Nodes on disk: $nodeCount');
        } catch (e, stack) {
          print('❌ [History] Restore failed: $e');
          print(stack);
          rethrow;
        }
      });
    });
  }

  static Future<void> deleteSnapshot(String questId, String fileName) async {
    final historyDirPath = await FileStorage.getFilePath(
      QuestPaths.questFile(questId, _historyFolder),
    );
    final file = File(p.join(historyDirPath, fileName));
    if (await file.exists()) {
      await file.delete();
    }
  }
}