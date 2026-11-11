import 'package:canvas_app/core/services/import_service.dart';
import 'package:canvas_app/core/utils/archive_entry_paths.dart';
import 'package:flutter_test/flutter_test.dart';

// Zip Slip в Dart-распаковке: имя записи архива подставлялось в путь
// `p.join(tempDir, entryName)` без проверки, и запись `../../…` писала файлы
// вне временного каталога.
void main() {
  group('ImportService.sanitizeArchiveEntryPath', () {
    test('пропускает обычные и вложенные пути', () {
      expect(ImportService.sanitizeArchiveEntryPath('config.json'), 'config.json');
      expect(
        ImportService.sanitizeArchiveEntryPath('nodes/nodes.json'),
        'nodes/nodes.json',
      );
      expect(
        ImportService.sanitizeArchiveEntryPath(r'nodes\nodes.json'),
        'nodes/nodes.json',
      );
      expect(
        ImportService.sanitizeArchiveEntryPath('dir/'),
        'dir',
      );
    });

    test('нормализует точки сегментов', () {
      expect(ImportService.sanitizeArchiveEntryPath('./config.json'), 'config.json');
      expect(ImportService.sanitizeArchiveEntryPath('a/./b'), 'a/b');
    });

    test('отвергает выход за пределы каталога', () {
      expect(ImportService.sanitizeArchiveEntryPath('../evil'), isNull);
      expect(ImportService.sanitizeArchiveEntryPath('../../etc/passwd'), isNull);
      expect(ImportService.sanitizeArchiveEntryPath('a/../b'), isNull);
      expect(ImportService.sanitizeArchiveEntryPath('..'), isNull);
    });

    test('отвергает абсолютные пути и Windows-диски', () {
      expect(ImportService.sanitizeArchiveEntryPath('/etc/passwd'), isNull);
      expect(ImportService.sanitizeArchiveEntryPath(r'C:\evil'), isNull);
      expect(ImportService.sanitizeArchiveEntryPath('C:/evil'), isNull);
    });

    test('отвергает пустые имена', () {
      expect(ImportService.sanitizeArchiveEntryPath(''), isNull);
      expect(ImportService.sanitizeArchiveEntryPath('/'), isNull);
      expect(ImportService.sanitizeArchiveEntryPath('.'), isNull);
    });
  });

  group('resolveArchiveTarget', () {
    test('собирает путь внутри корня', () {
      expect(
        resolveArchiveTarget('/tmp/app/quests', 'q1/config.json'),
        '/tmp/app/quests/q1/config.json',
      );
    });

    test('не выпускает наружу и не принимает сам корень', () {
      expect(resolveArchiveTarget('/tmp/app/quests', '../escape.txt'), isNull);
      expect(
        resolveArchiveTarget('/tmp/app/quests', 'q1/../../escape.txt'),
        isNull,
      );
      expect(resolveArchiveTarget('/tmp/app/quests', '/abs.txt'), isNull);
      expect(resolveArchiveTarget('/tmp/app/quests', 'C:/evil.txt'), isNull);
      expect(resolveArchiveTarget('/tmp/app/quests', '..'), isNull);
    });

    test('двойная проверка ловит имя, прошедшее нормализацию', () {
      // После санитайзера путь уже относительный — проверка isWithin
      // остаётся страховкой от платформенных сюрпризов.
      expect(
        resolveArchiveTarget('/tmp/app', './a/./b.txt'),
        '/tmp/app/a/b.txt',
      );
    });
  });
}