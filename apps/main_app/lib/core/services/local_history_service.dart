import 'dart:io';
import 'package:archive/archive.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';

class SnapshotInfo {
  final String fileName;
  final DateTime timestamp;
  final int sizeBytes;

  SnapshotInfo({
    required this.fileName,
    required this.timestamp,
    required this.sizeBytes,
  });
}

class LocalHistoryService {
  static const String _historyFolder = '_history';

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

  static Future<void> createSnapshot(String questId) async {
    // 1. Force wait for file locks to ensure previous writes are done
    await FileStorage.synchronized('nodes_$questId', () async {
      await FileStorage.synchronized('config_$questId', () async {
        try {
          print('📦 [History] === CREATING BACKUP ===');

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
            return;
          }

          final zipData = ZipEncoder().encode(archive);

          final historyDirPath = await FileStorage.getFilePath(
            QuestPaths.questFile(questId, _historyFolder),
          );
          await Directory(historyDirPath).create(recursive: true);

          final now = DateTime.now();
          final formatter = DateFormat('yyyyMMdd_HHmmss');
          final fileName = 'backup_${formatter.format(now)}.zip';
          final backupFile = File(p.join(historyDirPath, fileName));

          await backupFile.writeAsBytes(zipData, flush: true);

          print(
            '✅ [History] Backup created: $fileName (${zipData.length} bytes)',
          );
        } catch (e, stack) {
          print('❌ [History] Backup failed: $e');
          print(stack);
          rethrow;
        }
      });
    });
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
        DateTime timestamp = await file.lastModified();
        try {
          final datePart = name
              .replaceAll('backup_', '')
              .replaceAll('.zip', '');
          timestamp = DateFormat('yyyyMMdd_HHmmss').parse(datePart);
        } catch (_) {}

        snapshots.add(
          SnapshotInfo(
            fileName: name,
            timestamp: timestamp,
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
            final filename = file.name;
            if (filename.contains('..')) continue;

            final output = p.join(questRootPath, filename);

            if (file.isFile) {
              final data = file.content as List<int>;
              final outFile = File(output);
              await outFile.parent.create(recursive: true);
              await outFile.writeAsBytes(data, flush: true);
            } else {
              await Directory(output).create(recursive: true);
            }
          }

          // 3. Diagnostic post-restore
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
