import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:canvas_app/core/services/local_history_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:path/path.dart' as p;

/// Zip-slip в восстановлении снимка истории: снимок можно подменить или
/// собрать руками, а распаковка писала файлы туда, куда указывало имя
/// записи (`../`, `/abs`, `C:/`). Каталог квеста при этом уже вычищен —
/// значит чужая запись остаётся единственным свидетельством отката.
void main() {
  late Directory appDir;

  setUp(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_restore_');
    FileStorage.overrideAppDirectory(appDir);
  });

  tearDown(() async {
    FileStorage.overrideAppDirectory(null);
    if (await appDir.exists()) await appDir.delete(recursive: true);
  });

  test('восстановление не пишет за пределы папки квеста', () async {
    final questDir = Directory(p.join(appDir.path, 'quests', 'q1'));
    await questDir.create(recursive: true);
    await File(p.join(questDir.path, 'config.json')).writeAsString('{"old":1}');

    final archive = Archive();
    void add(String name, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('config.json', '{"title":"restored"}');
    add('nodes.json', '{"nodes":[]}');
    // Ни одна из этих записей не должна попасть на диск.
    add('../escape.txt', 'evil');
    add('../../escape2.txt', 'evil');
    add('nodes/../../escape3.txt', 'evil');
    add('/abs.txt', 'evil');

    final historyDir = Directory(p.join(questDir.path, '_history'));
    await historyDir.create(recursive: true);
    const snapshotName = 'broken_20200101_000000.zip';
    await File(
      p.join(historyDir.path, snapshotName),
    ).writeAsBytes(ZipEncoder().encode(archive), flush: true);

    await LocalHistoryService.restoreSnapshot('q1', snapshotName);

    expect(
      File(p.join(questDir.path, 'config.json')).readAsStringSync(),
      '{"title":"restored"}',
    );
    expect(File(p.join(questDir.path, 'nodes.json')).existsSync(), isTrue);

    expect(File(p.join(appDir.path, 'quests', 'escape.txt')).existsSync(), isFalse);
    expect(File(p.join(appDir.path, 'escape2.txt')).existsSync(), isFalse);
    expect(File(p.join(appDir.path, 'escape3.txt')).existsSync(), isFalse);
    expect(File(p.join(appDir.path, 'abs.txt')).existsSync(), isFalse);
    expect(File(p.join(appDir.path, 'quests', 'q1', 'nodes', 'escape3.txt')).existsSync(), isFalse);

    final files = questDir
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => p.relative(file.path, from: questDir.path))
        .where((name) => !name.startsWith('_history'))
        .toList()
      ..sort();
    expect(files, ['config.json', 'nodes.json']);
  });
}