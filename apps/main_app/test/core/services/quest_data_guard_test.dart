import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:canvas_app/core/services/local_history_service.dart';
import 'package:canvas_app/core/services/quest_data_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:path/path.dart' as p;

/// Страховка данных квеста: детект битого JSON, откат на последний целый
/// снимок, авто-снимки при открытии и их ретеншен.
///
/// Корень приложения подменяется на временный каталог — приложение здесь
/// не запускается и `path_provider` недоступен.
void main() {
  late Directory appDir;

  setUp(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_guard_');
    FileStorage.overrideAppDirectory(appDir);
    QuestDataGuard.resetSessionCache();
  });

  tearDown(() async {
    FileStorage.overrideAppDirectory(null);
    QuestDataGuard.resetSessionCache();
    if (await appDir.exists()) await appDir.delete(recursive: true);
  });

  Future<Directory> createQuest(
    String questId, {
    String nodes = '{"nodes":[]}',
    String config = '{"title":"Тест"}',
  }) async {
    final dir = Directory(p.join(appDir.path, 'quests', questId));
    await dir.create(recursive: true);
    await File(
      p.join(dir.path, 'config.json'),
    ).writeAsString(config);
    await File(p.join(dir.path, 'nodes.json')).writeAsString(nodes);
    return dir;
  }

  String readFile(Directory questDir, String name) =>
      File(p.join(questDir.path, name)).readAsStringSync();

  List<String> historyFiles(String questId) {
    final dir = Directory(p.join(appDir.path, 'quests', questId, '_history'));
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .map((file) => p.basename(file.path))
        .toList()
      ..sort();
  }

  group('QuestDataGuard', () {
    test('целый квест остаётся как есть', () async {
      final dir = await createQuest('q-healthy');

      final result = await QuestDataGuard.protect('q-healthy', snapshot: false);

      expect(result.health, QuestDataHealth.healthy);
      expect(result.changed, isFalse);
      expect(result.brokenFiles, isEmpty);
      expect(historyFiles('q-healthy'), isEmpty);
      expect(jsonDecode(readFile(dir, 'nodes.json')), isA<Map>());
    });

    test('поиск битых файлов идёт по вложенным папкам и не лезет в _history',
        () async {
      final dir = await createQuest('q-scan');
      await File(p.join(dir.path, 'nodes', 'n1', 'body.json'))
          .create(recursive: true)
          .then((file) => file.writeAsString('{"ok":true}'));
      await File(p.join(dir.path, 'nodes', 'n2', 'body.json'))
          .create(recursive: true)
          .then((file) => file.writeAsString('{"broken'));
      // Внутри `_history` битый JSON не должен попадать в отчёт.
      await File(p.join(dir.path, '_history', 'state.json'))
          .create(recursive: true)
          .then((file) => file.writeAsString('{"broken'));
      await File(p.join(dir.path, 'nodes.json')).writeAsString('');

      final broken = await QuestDataGuard.findBrokenJsonFiles(dir);

      expect(broken, ['nodes/n2/body.json']);
    });

    test('пустой config.json — порча, пустой nodes.json — норма', () async {
      final dir = await createQuest('q-empty', config: '', nodes: '');

      final broken = await QuestDataGuard.findBrokenJsonFiles(dir);

      expect(broken, ['config.json']);
    });

    test('битый nodes.json откатывается на последний целый снимок', () async {
      final dir = await createQuest('q-repair');
      final goodNodes = readFile(dir, 'nodes.json');

      await LocalHistoryService.createSnapshot('q-repair');
      final snapshotsAfterGood = historyFiles('q-repair');
      expect(snapshotsAfterGood, hasLength(1));
      expect(snapshotsAfterGood.single, startsWith('backup_'));

      // Оборванная запись: файл обрезан посередине.
      await File(p.join(dir.path, 'nodes.json')).writeAsString('{"nodes":[{"i');
      await File(p.join(dir.path, 'nodes', 'body.json'))
          .create(recursive: true)
          .then((file) => file.writeAsString('не json'));

      final result = await QuestDataGuard.protect('q-repair', snapshot: false);

      expect(result.health, QuestDataHealth.repaired);
      expect(result.changed, isTrue);
      expect(result.restoredSnapshot?.fileName, startsWith('backup_'));
      expect(result.brokenSnapshot, startsWith('broken_'));
      expect(result.brokenFiles, containsAll(['nodes.json', 'nodes/body.json']));
      expect(readFile(dir, 'nodes.json'), goodNodes);

      // Повреждённое состояние не потеряно, а лежит в снимке.
      final brokenZip = File(
        p.join(dir.path, '_history', result.brokenSnapshot!),
      );
      final archive = ZipDecoder().decodeBytes(await brokenZip.readAsBytes());
      final brokenEntry = archive.files.firstWhere(
        (entry) => entry.name == 'nodes.json',
      );
      expect(
        utf8.decode(brokenEntry.content as List<int>),
        startsWith('{"nodes":[{"i'),
      );
    });

    test('битые файлы без снимков — corrupt, ничего не теряется', () async {
      final dir = await createQuest(
        'q-corrupt',
        config: '{"title":',
      );

      final result = await QuestDataGuard.protect('q-corrupt', snapshot: false);

      expect(result.health, QuestDataHealth.corrupt);
      expect(result.changed, isFalse);
      expect(result.brokenFiles, contains('config.json'));
      expect(result.restoredSnapshot, isNull);
      // Копия повреждённого состояния снята, но откатывать не на что.
      expect(result.brokenSnapshot, startsWith('broken_'));
      expect(historyFiles('q-corrupt'), contains(result.brokenSnapshot));
      expect(readFile(dir, 'config.json'), '{"title":');
    });

    test('снимок с битым содержимым не используется для отката', () async {
      final dir = await createQuest('q-bad-snapshot');

      // Снимок сделан уже после порчи — откатывать на него нельзя.
      await File(p.join(dir.path, 'config.json')).writeAsString('{"title":');
      await LocalHistoryService.createSnapshot('q-bad-snapshot');

      final result = await QuestDataGuard.protect(
        'q-bad-snapshot',
        snapshot: false,
      );

      expect(result.health, QuestDataHealth.corrupt);
      expect(result.restoredSnapshot, isNull);
    });

    test('откат отключён — только диагностика', () async {
      final dir = await createQuest('q-no-rollback');
      await LocalHistoryService.createSnapshot('q-no-rollback');
      await File(p.join(dir.path, 'nodes.json')).writeAsString('{oops');

      final result = await QuestDataGuard.protect(
        'q-no-rollback',
        allowRollback: false,
        snapshot: false,
      );

      expect(result.health, QuestDataHealth.corrupt);
      expect(result.brokenFiles, ['nodes.json']);
      expect(readFile(dir, 'nodes.json'), '{oops');
      expect(result.brokenSnapshot, isNull);
    });

    test('повторная проверка в сессии не читает диск заново', () async {
      await createQuest('q-memo');

      final first = await QuestDataGuard.protect('q-memo', snapshot: false);
      expect(first.health, QuestDataHealth.healthy);

      // Файл испорчен после проверки — сессионный кэш уже «здоров».
      final dir = Directory(p.join(appDir.path, 'quests', 'q-memo'));
      await File(p.join(dir.path, 'nodes.json')).writeAsString('{oops');

      final second = await QuestDataGuard.protect('q-memo', snapshot: false);
      expect(second.health, QuestDataHealth.healthy);
    });
  });

  group('время снимка', () {
    test('берётся из имени файла, а не из mtime', () async {
      final dir = await createQuest('q-stamp');
      final history = Directory(p.join(dir.path, '_history'));
      await history.create(recursive: true);
      final file = File(p.join(history.path, 'auto_20200102_030405.zip'));
      await file.writeAsBytes([1, 2, 3]);
      await file.setLastModified(DateTime(2026, 5, 5, 10));

      final snapshots = await LocalHistoryService.listSnapshots('q-stamp');

      expect(snapshots, hasLength(1));
      expect(snapshots.single.timestamp, DateTime(2020, 1, 2, 3, 4, 5));
      expect(snapshots.single.isAuto, isTrue);
      expect(snapshots.single.isBroken, isFalse);
    });

    test('неразборчивое имя — запасной вариант по mtime', () async {
      final dir = await createQuest('q-stamp-legacy');
      final history = Directory(p.join(dir.path, '_history'));
      await history.create(recursive: true);
      final file = File(p.join(history.path, 'backup_manual.zip'));
      await file.writeAsBytes([1, 2, 3]);
      final mtime = DateTime(2024, 7, 1, 12, 30);
      await file.setLastModified(mtime);

      final snapshots = await LocalHistoryService.listSnapshots(
        'q-stamp-legacy',
      );

      expect(snapshots.single.timestamp, mtime);
    });
  });

  group('авто-снимки при открытии', () {
    test('создаётся один снимок и повторяется не чаще интервала', () async {
      final dir = await createQuest('q-auto');

      final first = await LocalHistoryService.autoSnapshotOnOpen('q-auto');
      expect(first, startsWith('auto_'));
      expect(historyFiles('q-auto'), [first]);

      final second = await LocalHistoryService.autoSnapshotOnOpen('q-auto');
      expect(second, isNull, reason: 'второй вызов в пределах 10 минут');
      expect(historyFiles('q-auto'), [first]);

      // Снимок содержит данные квеста.
      final zip = File(p.join(dir.path, '_history', first!));
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      expect(archive.files.map((entry) => entry.name), contains('config.json'));
    });

    test('снимок включает вложенные файлы и не тащит _history', () async {
      final dir = await createQuest('q-nested');
      await File(p.join(dir.path, 'assets', 'img', 'a.png'))
          .create(recursive: true)
          .then((file) => file.writeAsBytes(List<int>.filled(64, 7)));

      final name = await LocalHistoryService.autoSnapshotOnOpen('q-nested');
      expect(name, isNotNull);

      final zip = File(p.join(dir.path, '_history', name!));
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      final entries = archive.files.map((entry) => entry.name).toList();
      expect(entries, containsAll(['config.json', 'nodes.json']));
      expect(entries, contains(allOf(startsWith('assets/'), endsWith('a.png'))));
      expect(
        entries.where((entry) => entry.startsWith('_history')),
        isEmpty,
      );
    });

    test('старые авто-снимки чистятся, ручные остаются', () async {
      final dir = await createQuest('q-retention');
      final history = Directory(p.join(dir.path, '_history'));
      await history.create(recursive: true);

      await LocalHistoryService.createSnapshot('q-retention');
      // 12 авто-снимков из прошлого (содержимое не важно — важны имена).
      for (var day = 1; day <= 12; day++) {
        final name = 'auto_202001${day.toString().padLeft(2, '0')}_120000.zip';
        await File(p.join(history.path, name)).writeAsBytes([1, 2, 3]);
      }

      final created = await LocalHistoryService.autoSnapshotOnOpen('q-retention');
      expect(created, isNotNull, reason: 'свежих авто-снимков не было');

      final autos = historyFiles(
        'q-retention',
      ).where((name) => name.startsWith('auto_')).toList();
      final manuals = historyFiles(
        'q-retention',
      ).where((name) => name.startsWith('backup_')).toList();
      expect(autos, hasLength(LocalHistoryService.autoSnapshotsToKeep));
      expect(manuals, hasLength(1));
    });
  });
}