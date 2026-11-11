import 'package:path/path.dart' as p;

/// Проверка пути записи из zip-архива.
///
/// Архивы в приложении собирают не только мы: `.mnd`/бэкап приходит от
/// другого пользователя или правится вручную, а имена записей zip — обычные
/// строки. `..` в начале или `/`/`C:\` внутри пишут файлы вне каталога
/// назначения (zip-slip). Хуже того, в восстановлении бэкапа первый сегмент
/// имени становится id квеста, а папку такого квеста перед заменой удаляют
/// рекурсивно: запись `../x` превратилась бы в `Directory(<appDir>/..)` и
/// стёрла весь каталог приложения.
///
/// Возвращает относительный путь с разделителями `/` или `null`, если
/// запись недопустима (абсолютный путь, буква диска, `..`).
String? sanitizeArchiveEntryPath(String rawName) {
  final normalized = rawName.replaceAll('\\', '/');
  if (normalized.startsWith('/')) return null;
  if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return null;
  final clean = <String>[];
  for (final segment in normalized.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    clean.add(segment);
  }
  if (clean.isEmpty) return null;
  return clean.join('/');
}

/// Полный путь для записи файла из архива внутри [rootPath].
///
/// `null` — запись недопустима или ведёт наружу. Проверка двойная: сначала
/// имя (см. [sanitizeArchiveEntryPath]), затем уже собранный путь — так
/// ловится платформенная нормализация (`C:/`, `\\?\`, ведущие пробелы).
String? resolveArchiveTarget(String rootPath, String entryName) {
  final relative = sanitizeArchiveEntryPath(entryName);
  if (relative == null) return null;
  final root = p.normalize(rootPath);
  final target = p.normalize(p.join(root, relative));
  if (target == root || !p.isWithin(root, target)) return null;
  return target;
}