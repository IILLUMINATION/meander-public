// ============================================================================
//  Библиотека ресурсов квеста как «имя → файл».
//
//  Автор картинки не обязан знать путь на диске: в `resourcePath` и в значение
//  переменной можно написать имя ресурса из библиотеки («закат»), его uuid или
//  обычный путь — движок сам найдёт файл. Здесь только чистые правила поиска по
//  `res/metadata.json`; I/O и кеш — на стороне вызывающего (mnd_player).
//
//  Неопределённость не угадывается: если имя носит больше одного файла,
//  кандидатов нет — иначе одна и та же сцена на разных квестах показывала бы
//  разное.
// ============================================================================

/// Каталог ресурса по расширению (`res/<каталог>/<файл>`).
const Map<String, String> _dirsByExtension = {
  'png': 'images',
  'jpg': 'images',
  'jpeg': 'images',
  'webp': 'images',
  'gif': 'images',
  'bmp': 'images',
  'avif': 'images',
  'heic': 'images',
  'heif': 'images',
  'mp3': 'audio',
  'wav': 'audio',
  'ogg': 'audio',
  'm4a': 'audio',
  'flac': 'audio',
  'aac': 'audio',
  'opus': 'audio',
  'mp4': 'videos',
  'webm': 'videos',
  'mkv': 'videos',
  'mov': 'videos',
  'avi': 'videos',
  'ttf': 'fonts',
  'otf': 'fonts',
  'woff': 'fonts',
  'woff2': 'fonts',
};

/// Что можно написать вместо пути, чтобы движок нашёл файл: для типов с
/// известным расширением — голое имя файла (`directResourceCandidates` сам
/// подставит `res/<каталог>/`), иначе — относительный путь целиком, потому что
/// скрипты лежат не в `res/` и по одному имени не ищутся.
///
/// Один источник правды для «Копировать id» в библиотеке и для пикера
/// ресурсов в редакторе формул: то, что они вставляют, резолвер точно принимает.
String resourceReference({required String fileName, required String path}) {
  final trimmed = fileName.trim();
  return _dirsByExtension.containsKey(_extension(trimmed)) ? trimmed : path;
}

/// Ключ-мусор метаданных (список папок), а не ресурс.
bool _isBookkeepingKey(String key) => key.startsWith('__');

String _baseName(String file) {
  final dot = file.lastIndexOf('.');
  return dot > 0 ? file.substring(0, dot) : file;
}

String _extension(String file) {
  final dot = file.lastIndexOf('.');
  if (dot < 0 || dot == file.length - 1) return '';
  return file.substring(dot + 1).toLowerCase();
}

/// Кандидаты на `res/<каталог>/<файл>` из одного лишь [source] — без чтения
/// метаданных: путь как есть, либо голое имя файла с известным расширением.
///
/// Пустой список — не «не нашли», а «надо смотреть библиотеку».
List<String> directResourceCandidates(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return const [];
  if (trimmed.contains('/')) return [trimmed];
  final dir = _dirsByExtension[_extension(trimmed)];
  return dir == null ? const [] : ['res/$dir/$trimmed'];
}

/// Индекс `res/metadata.json`: имя ресурса и его uuid → файлы-кандидаты.
class QuestResourceIndex {
  /// friendly name (без регистра и пробелов по краям) → имена файлов.
  final Map<String, List<String>> _byName;

  /// имя файла без расширения → имена файлов (uuid или имя без хвоста).
  final Map<String, List<String>> _byStem;

  /// `resourceId` → имена файлов.
  final Map<String, List<String>> _byStableId;

  QuestResourceIndex._(this._byName, this._byStem, this._byStableId);

  factory QuestResourceIndex.empty() =>
      QuestResourceIndex._(const {}, const {}, const {});

  /// [metadata] — распарсенный `res/metadata.json`. Значения бывают двух
  /// видов: карта (`name`/`folder`/`resourceId`) и легаси-строка (имя).
  factory QuestResourceIndex.fromMetadata(Map<String, dynamic>? metadata) {
    if (metadata == null || metadata.isEmpty) return QuestResourceIndex.empty();

    final byName = <String, List<String>>{};
    final byStem = <String, List<String>>{};
    final byStableId = <String, List<String>>{};

    void addTo(Map<String, List<String>> map, String key, String file) {
      if (key.isEmpty) return;
      map.putIfAbsent(key, () => <String>[]).add(file);
    }

    metadata.forEach((fileName, value) {
      if (_isBookkeepingKey(fileName)) return;
      addTo(byStem, _baseName(fileName).toLowerCase(), fileName);
      if (value is String) {
        addTo(byName, value.trim().toLowerCase(), fileName);
        return;
      }
      if (value is! Map) return;
      final name = value['name']?.toString().trim().toLowerCase();
      if (name != null) addTo(byName, name, fileName);
      final stableId = value['resourceId']?.toString().trim();
      if (stableId != null && stableId.isNotEmpty) {
        addTo(byStableId, stableId, fileName);
      }
    });

    return QuestResourceIndex._(byName, byStem, byStableId);
  }

  /// Относительные пути (от корня квеста), где может лежать ресурс под
  /// [source]: путь → как есть, иначе имя / файл без расширения / `resourceId`.
  /// У файла без расширения каталог неизвестен, поэтому кандидатов несколько
  /// (см. [_relativePaths]); существование проверяет вызывающий.
  /// Дубликаты убраны, порядок детерминированный (по алфавиту).
  List<String> pathCandidates(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return const [];
    final direct = directResourceCandidates(trimmed);
    if (direct.isNotEmpty) return direct;

    final key = trimmed.toLowerCase();
    final files = <String>{
      ..._unambiguous(_byName[key]),
      ..._unambiguous(_byStem[key]),
      ..._unambiguous(_byStableId[key]),
    };
    final paths = <String>{};
    for (final file in files) {
      paths.addAll(_relativePaths(file));
    }
    return paths.toList()..sort();
  }

  /// Дубликат — неопределённость: угадывать, какой из одноимённых файлов имел
  /// в виду автор, нельзя (одна и та же сцена на разных квестах показывала бы
  /// разное).
  static List<String> _unambiguous(List<String>? files) =>
      files == null || files.length > 1 ? const [] : files;

  /// Пути для файла [fileName] из метаданных.
  ///
  /// С известным расширением каталог однозначен. Файл **без расширения**
  /// (импортировали из источника, где его не было) в `res/<каталог>` по
  /// расширению не положить: тип ресурса известен только по каталогу, а имена
  /// файлов там уникальны. Отдаём кандидатов во всех каталогах ресурсов —
  /// существует ли файл, проверяет вызывающий (это I/O-слой).
  ///
  /// Имя с точкой, но неизвестным расширением (`.txt`, `.lua`) — не ресурс
  /// каталога: пути нет, как и раньше.
  static List<String> _relativePaths(String fileName) {
    final dir = _dirsByExtension[_extension(fileName)];
    if (dir != null) return ['res/$dir/$fileName'];
    if (fileName.contains('.')) return const [];
    return [for (final d in _resourceDirs) 'res/$d/$fileName'];
  }
}

/// Каталоги ресурсов без повторов, в порядке объявления (картинки первыми:
/// фон/сцена — самый частый случай).
final List<String> _resourceDirs = _dirsByExtension.values.toSet().toList();
