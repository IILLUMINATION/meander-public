import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:canvas_app/core/services/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:path/path.dart' as p;

/// Восстановление квеста из бэкапа: запись идёт в промежуточную папку и
/// подменяет квест только целиком. Раньше старая папка удалялась до записи,
/// и сбой посреди распаковки оставлял квест наполовину перезаписанным.
void main() {
  late Directory appDir;
  late String questsPath;

  setUp(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_backup_restore_');
    FileStorage.overrideAppDirectory(appDir);
    questsPath = p.join(appDir.path, 'quests');
    await Directory(questsPath).create(recursive: true);
  });

  tearDown(() async {
    FileStorage.overrideAppDirectory(null);
    if (await appDir.exists()) await appDir.delete(recursive: true);
  });

  ArchiveFile entry(String name, String text) {
    final bytes = utf8.encode(text);
    return ArchiveFile(name, bytes.length, bytes);
  }

  test('новый квест создаётся', () async {
    final ok = await BackupService.restoreQuestEntries(
      questsPath: questsPath,
      questId: 'q1',
      files: [
        entry('q1/config.json', '{"title":"new"}'),
        entry('q1/nodes/nodes.json', '{"nodes":[]}'),
      ],
      replaceExisting: false,
    );

    expect(ok, isTrue);
    expect(
      File(p.join(questsPath, 'q1', 'config.json')).readAsStringSync(),
      '{"title":"new"}',
    );
    expect(
      File(p.join(questsPath, 'q1', 'nodes', 'nodes.json')).existsSync(),
      isTrue,
    );
  });

  test('существующий квест без замены не трогается', () async {
    final questDir = Directory(p.join(questsPath, 'q1'));
    await questDir.create(recursive: true);
    await File(p.join(questDir.path, 'config.json')).writeAsString('{"old":1}');

    final ok = await BackupService.restoreQuestEntries(
      questsPath: questsPath,
      questId: 'q1',
      files: [entry('q1/config.json', '{"title":"new"}')],
      replaceExisting: false,
    );

    expect(ok, isFalse);
    expect(
      File(p.join(questDir.path, 'config.json')).readAsStringSync(),
      '{"old":1}',
    );
  });

  test('замена удаляет старые файлы и не оставляет временных папок', () async {
    final questDir = Directory(p.join(questsPath, 'q1'));
    await questDir.create(recursive: true);
    await File(p.join(questDir.path, 'config.json')).writeAsString('{"old":1}');
    await File(p.join(questDir.path, 'leftover.json')).writeAsString('{}');

    final ok = await BackupService.restoreQuestEntries(
      questsPath: questsPath,
      questId: 'q1',
      files: [
        entry('q1/config.json', '{"title":"new"}'),
        entry('q1/nodes.json', '{"nodes":[]}'),
      ],
      replaceExisting: true,
    );

    expect(ok, isTrue);
    expect(
      File(p.join(questDir.path, 'config.json')).readAsStringSync(),
      '{"title":"new"}',
    );
    expect(File(p.join(questDir.path, 'leftover.json')).existsSync(), isFalse);

    final leftovers = Directory(questsPath)
        .listSync()
        .map((entity) => p.basename(entity.path))
        .where((name) => name.startsWith('.restore_') || name.startsWith('.replaced_'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('записи с путём наружу пропускаются', () async {
    final ok = await BackupService.restoreQuestEntries(
      questsPath: questsPath,
      questId: 'q1',
      files: [
        entry('q1/config.json', '{"title":"new"}'),
        entry('q1/../../escape.txt', 'evil'),
        entry('../escape2.txt', 'evil'),
        entry('q2/config.json', 'evil'),
      ],
      replaceExisting: false,
    );

    expect(ok, isTrue);
    expect(File(p.join(appDir.path, 'escape.txt')).existsSync(), isFalse);
    expect(File(p.join(appDir.path, 'escape2.txt')).existsSync(), isFalse);
    expect(File(p.join(questsPath, 'q2', 'config.json')).existsSync(), isFalse);
    expect(
      File(p.join(questsPath, 'q1', 'config.json')).readAsStringSync(),
      '{"title":"new"}',
    );
  });
}