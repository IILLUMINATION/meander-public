import 'dart:io';

import 'package:canvas_app/core/utils/quest_folder_swap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Подмена папки квеста: старая копия должна оставаться на месте, пока новая
/// не встала под её именем. Раньше импорт удалял папку до переименования.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mnd_swap_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('цель отсутствует — новое имя занимает место', () async {
    final staging = Directory(p.join(root.path, '.staging'));
    await staging.create(recursive: true);
    await File(p.join(staging.path, 'config.json')).writeAsString('{"new":1}');
    final target = Directory(p.join(root.path, 'q1'));

    await replaceDirectoryAtomically(staging: staging, target: target);

    expect(target.existsSync(), isTrue);
    expect(
      File(p.join(target.path, 'config.json')).readAsStringSync(),
      '{"new":1}',
    );
    expect(staging.existsSync(), isFalse);
  });

  test('цель есть — заменяется целиком, временных папок не остаётся', () async {
    final staging = Directory(p.join(root.path, '.staging'));
    await staging.create(recursive: true);
    await File(p.join(staging.path, 'config.json')).writeAsString('{"new":1}');

    final target = Directory(p.join(root.path, 'q1'));
    await target.create(recursive: true);
    await File(p.join(target.path, 'config.json')).writeAsString('{"old":1}');
    await File(p.join(target.path, 'stale.json')).writeAsString('{}');

    await replaceDirectoryAtomically(staging: staging, target: target);

    expect(
      File(p.join(target.path, 'config.json')).readAsStringSync(),
      '{"new":1}',
    );
    expect(File(p.join(target.path, 'stale.json')).existsSync(), isFalse);
    final leftovers = root
        .listSync()
        .map((entity) => p.basename(entity.path))
        .where((name) => name != 'q1')
        .toList();
    expect(leftovers, isEmpty);
  });

  test('сбой подмены возвращает старую папку', () async {
    final target = Directory(p.join(root.path, 'q1'));
    await target.create(recursive: true);
    await File(p.join(target.path, 'config.json')).writeAsString('{"old":1}');

    // staging не существует → rename упадёт уже после того, как старая
    // папка ушла в сторону.
    final missingStaging = Directory(p.join(root.path, '.staging'));

    await expectLater(
      replaceDirectoryAtomically(staging: missingStaging, target: target),
      throwsA(isA<FileSystemException>()),
    );

    expect(target.existsSync(), isTrue);
    expect(
      File(p.join(target.path, 'config.json')).readAsStringSync(),
      '{"old":1}',
    );
    final leftovers = root
        .listSync()
        .map((entity) => p.basename(entity.path))
        .where((name) => name != 'q1')
        .toList();
    expect(leftovers, isEmpty);
  });
}