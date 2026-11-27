// ============================================================================
//  Файл ресурса по «источнику», который написал автор квеста.
//
//  Источник — это либо путь в каталоге квеста (`res/images/<uuid>.png`, как
//  сохраняет редактор), либо то, что удобнее назовать в скрипте: имя ресурса из
//  библиотеки («закат») или его uuid. Правила поиска — в mnd_core
//  (`QuestResourceIndex`), здесь только I/O и порядок пробуемых кандидатов.
//
//  Работает не только с картинками: `res/audio|videos|fonts` узнаются по
//  расширению, поэтому аудио, видео, шрифт и аватар резолвятся этим же
//  методом — иначе один и тот же источник показывал бы картинку в редакторе и
//  молча исчезал в плеере.
//
//  Используется сценой, слоем стека, HUD, фоном ноды и экспортом в HTML/PDF,
//  чтобы опубликованный квест открывал ровно то же, что видит автор.
// ============================================================================

import 'dart:io';

import 'package:mnd_core/engine/quest_resource_index.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:path/path.dart' as p;

class QuestImageSource {
  QuestImageSource._();

  /// Кэш резолва «источник → относительный путь». Не растёт: ключей ровно
  /// столько, сколько уникальных источников встретилось в квесте, а null
  /// хранится через отдельное множество, чтобы отсутствие файла тоже не
  /// перечитывалось с диска на каждой пересборке.
  ///
  /// Раньше каждый резолв (каждая карточка в сетке ресурсов, каждый айтем
  /// в редакторе) заново читал metadata.json и стучался в ФС — на сотне
  /// картинок это сотни чтений JSON на один скролл.
  static final Map<String, String?> _resolvedCache = {};
  static final Set<String> _resolvedNegative = {};
  static final Map<String, ({File file, int generation, String root})>
  _lastResolved = {};
  static int _generation = 0;

  static int get generation => _generation;

  /// Сбросить кэш: контент квеста изменился (файл переименован/удалён).
  static void invalidate() {
    _generation++;
    _resolvedCache.clear();
    _resolvedNegative.clear();
  }

  /// Последний безопасно разрешённый файл переживает [invalidate], чтобы
  /// пересозданный виджет не показывал пустой кадр до повторного резолва.
  static ({File file, int generation})? cachedFile(
    String questId,
    String source,
  ) {
    final trimmed = _withoutQuestPrefix(questId, source);
    if (trimmed.isEmpty) return null;
    final key = '$questId|$trimmed';
    final cached = _lastResolved[key];
    if (cached == null) return null;
    try {
      final root = Directory(cached.root).resolveSymbolicLinksSync();
      final path = cached.file.resolveSymbolicLinksSync();
      if (!p.isWithin(root, path)) {
        _lastResolved.remove(key);
        return null;
      }
      return (file: File(path), generation: cached.generation);
    } on FileSystemException {
      _lastResolved.remove(key);
      return null;
    }
  }

  /// Файл ресурса для [source] или null, если ничего не нашлось.
  static Future<File?> resolve(String questId, String? source) async {
    final generation = _generation;
    final relative = await resolveRelative(questId, source);
    final found = relative == null ? null : await _existing(questId, relative);
    final trimmed = _withoutQuestPrefix(questId, source);
    final key = '$questId|$trimmed';
    if (found == null) {
      _lastResolved.remove(key);
      return null;
    }
    _lastResolved[key] = (
      file: found.file,
      generation: generation,
      root: found.root,
    );
    return found.file;
  }

  /// Абсолютный путь найденного файла; '' — если файла нет. Для тех, кому нужен
  /// путь, а не [File]: just_audio, видеоплеер, загрузка шрифта.
  static Future<String> resolveOnDisk(String questId, String? source) async {
    final relative = await resolveRelative(questId, source);
    if (relative == null) return '';
    return FileStorage.getFilePath(QuestPaths.questFile(questId, relative));
  }

  /// Относительный путь (от корня квеста) найденного файла — то, чем источник
  /// оказался на самом деле. Нужен экспорту: HTML/PDF подписывают ресурс тем
  /// путём, который реально прочитали, а не тем, что автор накатал в поле.
  /// null — файла нет ни по одному из кандидатов.
  static Future<String?> resolveRelative(String questId, String? source) async {
    final trimmed = _withoutQuestPrefix(questId, source);
    if (trimmed.isEmpty) return null;

    final cacheKey = '$questId|$trimmed';
    if (_resolvedNegative.contains(cacheKey)) return null;
    final cached = _resolvedCache[cacheKey];
    if (cached != null) return cached;

    final resolved = await _resolveUncached(questId, trimmed);
    if (resolved == null) {
      _resolvedNegative.add(cacheKey);
    } else {
      _resolvedCache[cacheKey] = resolved;
    }
    return resolved;
  }

  static Future<String?> _resolveUncached(String questId, String trimmed) async {
    // То, что не требует метаданных: путь или голое имя файла с расширением.
    for (final candidate in directResourceCandidates(trimmed)) {
      if (await _existing(questId, candidate) != null) return candidate;
    }
    // Путь есть, но файла нет — библиотека тут не поможет, и лишний раз
    // читать метаданные на каждую битую картинку не нужно.
    if (trimmed.contains('/')) return null;

    for (final candidate in (await _index(questId)).pathCandidates(trimmed)) {
      if (await _existing(questId, candidate) != null) return candidate;
    }
    return null;
  }

  /// Часть мест хранит путь уже относительно корня документов
  /// (`quests/<id>/res/images/x.png`), а не относительно квеста. Без среза
  /// префикса такие значения давали двойной путь и «файл не найден».
  static String _withoutQuestPrefix(String questId, String? source) {
    var path = (source ?? '').trim().replaceAll('\\', '/');
    final root = '${QuestPaths.questRoot(questId)}/';
    var changed = true;
    while (changed) {
      changed = false;
      for (final prefix in [root, '/']) {
        if (path.startsWith(prefix)) {
          path = path.substring(prefix.length);
          changed = true;
        }
      }
    }
    return path;
  }

  static Future<({File file, String root})?> _existing(
    String questId,
    String relative,
  ) async {
    final path = await FileStorage.getFilePath(
      QuestPaths.questFile(questId, relative),
    );
    if (path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final root = await Directory(
        await FileStorage.getFilePath(QuestPaths.questRoot(questId)),
      ).resolveSymbolicLinks();
      final resolved = await file.resolveSymbolicLinks();
      if (!p.isWithin(root, resolved)) return null;
      return (file: File(resolved), root: root);
    } on FileSystemException {
      return null;
    }
  }

  /// `FileStorage.readJsonFile` бросается на отсутствующем файле, а отсутствие
  /// `res/metadata.json` — норма для квеста без библиотеки.
  static Future<QuestResourceIndex> _index(String questId) async {
    final relative = QuestPaths.metadata(questId);
    if (!await FileStorage.exists(relative)) return QuestResourceIndex.empty();
    try {
      return QuestResourceIndex.fromMetadata(
        await FileStorage.readJsonFile(relative),
      );
    } catch (_) {
      return QuestResourceIndex.empty();
    }
  }
}
