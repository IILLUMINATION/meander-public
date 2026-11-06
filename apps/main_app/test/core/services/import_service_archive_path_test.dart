import 'package:canvas_app/core/services/import_service.dart';
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
}