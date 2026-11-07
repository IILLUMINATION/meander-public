import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_core/utils/quest_paths.dart';

/// Факты о файле для библиотеки ресурсов: то, что экран показывает на
/// карточке, — без чтения самого файла в Dart.
class ResourceFileFacts {
  final String fileName;
  final int sizeBytes;
  final DateTime? modifiedAt;

  /// `name` из JSON-скрипта (null — нет или не просили разбирать).
  final String? jsonName;

  /// Число блоков-действий (только для скриптов при `parseJson`).
  final int blockCount;

  const ResourceFileFacts({
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedAt,
    this.jsonName,
    this.blockCount = 0,
  });
}

/// Абстракция файлового хранилища: все операции, через которые редактор
/// читает и пишет файлы квеста. В приложении используется
/// [QuestStoreAdapter] (Rust-ядро, план 020-C), в тестах — in-memory.
abstract class StorageAdapter {
  Future<Map<String, dynamic>> readJsonFile(String relativePath);

  Future<void> writeJsonFile(String relativePath, Map<String, dynamic> data);

  Future<List<String>> listFiles(String relativePath, {String? extension});

  Future<List<String>> listFolders(String relativePath);

  Future<bool> exists(String relativePath);

  Future<void> delete(String relativePath);

  /// Абсолютный путь файла (для прямого File API там, где он необходим).
  Future<String> getFilePath(String relativePath);

  /// Массовый снимок каталога: имя файла, размер, mtime и — при
  /// `parseJson` — имя из содержимого и число блоков-действий. Один обход
  /// каталога вместо N вызовов на файл.
  ///
  /// `null` — адаптер так не умеет (тесты, веб); вызывающий идёт пофайлово.
  Future<List<ResourceFileFacts>?> scanFiles(
    String relativePath, {
    String? extension,
    bool parseJson = false,
  }) async => null;

  /// Читает произвольный текстовый файл (Lua и т.п.).
  Future<String> readText(String relativePath) async {
    final absolute = await getFilePath(relativePath);
    return File(absolute).readAsString();
  }

  /// Пишет произвольный текстовый файл (создаёт родительские папки).
  Future<void> writeText(String relativePath, String content) async {
    final absolute = await getFilePath(relativePath);
    final file = File(absolute);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }
}

/// Продакшен-адаптер: всё через QuestStore (Rust-ядро; без моста —
/// fallback на FileStorage внутри фасада). План 020-C4.1.
class QuestStoreAdapter implements StorageAdapter {
  const QuestStoreAdapter();

  Future<QuestStore> _store() => _future ??= QuestStore.create();
  static Future<QuestStore>? _future;

  /// Сброс кэша фасада — для тестов и смены корня документов.
  static void resetBackendCache() => _future = null;

  @override
  Future<Map<String, dynamic>> readJsonFile(String relativePath) async =>
      await (await _store()).readJson(relativePath) ?? <String, dynamic>{};

  @override
  Future<List<ResourceFileFacts>?> scanFiles(
    String relativePath, {
    String? extension,
    bool parseJson = false,
  }) async {
    final raw = await (await _store()).scanFiles(
      relativePath,
      extension: extension,
      parseJson: parseJson,
    );
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return [
      for (final item in decoded.whereType<Map>())
        ResourceFileFacts(
          fileName: item['file']?.toString() ?? '',
          sizeBytes: (item['size'] as num?)?.toInt() ?? 0,
          modifiedAt: switch (item['mtimeMs']) {
            final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
            _ => null,
          },
          jsonName: item['name']?.toString(),
          blockCount: (item['blocks'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<void> writeJsonFile(
    String relativePath,
    Map<String, dynamic> data,
  ) async => (await _store()).writeJson(relativePath, data);

  @override
  Future<List<String>> listFiles(
    String relativePath, {
    String? extension,
  }) async => (await _store()).listFiles(relativePath, extension: extension);

  @override
  Future<List<String>> listFolders(String relativePath) async {
    // Каталоги не входят в MVP-поверхность QuestStore — как и раньше,
    // резолвим абсолютный путь через FileStorage.
    final dir = Directory(await FileStorage.getFilePath(relativePath));
    if (!await dir.exists()) return const [];
    return dir
        .listSync()
        .whereType<Directory>()
        .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList(growable: false);
  }

  @override
  Future<bool> exists(String relativePath) async =>
      (await _store()).exists(relativePath);

  @override
  Future<void> delete(String relativePath) async =>
      (await _store()).delete(relativePath);

  @override
  Future<String> getFilePath(String relativePath) =>
      FileStorage.getFilePath(relativePath);

  @override
  Future<String> readText(String relativePath) async =>
      await (await _store()).readText(relativePath) ?? '';

  @override
  Future<void> writeText(String relativePath, String content) async =>
      (await _store()).writeText(relativePath, content);
}

/// Конвенции путей квеста и единственный владелец `metadata.json`
/// (виртуальные папки и человекочитаемые имена файлов).
///
/// Никакой другой код не должен читать/писать `metadata.json` напрямую —
/// только через этот класс (или `ResourceService`, который его оборачивает).
class QuestStorage {
  final String questId;
  final StorageAdapter adapter;

  QuestStorage({required this.questId, StorageAdapter? adapter})
    : adapter = adapter ?? const QuestStoreAdapter();

  static const String foldersKey = '__folders__';

  // --- Пути (все через единый реестр QuestPaths, план 020-C6) ---

  String get rootPath => QuestPaths.questRoot(questId);
  String get configPath => QuestPaths.config(questId);
  String get nodesPath => QuestPaths.nodesLegacy(questId);
  String get scriptsDir => QuestPaths.scriptsDir(questId);
  String get internalScriptsDir => QuestPaths.internalScriptsDir(questId);
  String get resDir => QuestPaths.resDir(questId);
  String get metadataPath => QuestPaths.metadata(questId);

  String scriptFilePath(String fileName) =>
      QuestPaths.scriptFile(questId, fileName);

  String typeDir(String type) {
    switch (type) {
      case 'image':
        return QuestPaths.resImagesDir(questId);
      case 'audio':
        return QuestPaths.resAudioDir(questId);
      case 'video':
        return QuestPaths.resVideosDir(questId);
      case 'font':
        return QuestPaths.resFontsDir(questId);
      case 'script':
      case 'lua':
        return scriptsDir;
      default:
        return resDir;
    }
  }

  // --- Общие файлы ---

  Future<Map<String, dynamic>> readJson(String relativePath) =>
      adapter.readJsonFile(relativePath);

  Future<void> writeJson(String relativePath, Map<String, dynamic> data) =>
      adapter.writeJsonFile(relativePath, data);

  Future<bool> exists(String relativePath) async =>
      adapter.exists(relativePath);

  Future<void> delete(String relativePath) async =>
      adapter.delete(relativePath);

  Future<String> absolutePath(String relativePath) =>
      adapter.getFilePath(relativePath);

  /// Читает произвольный текстовый файл квеста (Lua и т.п.).
  Future<String> readText(String relativePath) =>
      adapter.readText(relativePath);

  /// Пишет произвольный текстовый файл (создаёт родительские папки).
  Future<void> writeText(String relativePath, String content) async =>
      adapter.writeText(relativePath, content);

  Future<List<String>> listFiles(
    String relativePath, {
    String? extension,
  }) async => adapter.listFiles(relativePath, extension: extension);

  Future<List<ResourceFileFacts>?> scanFiles(
    String relativePath, {
    String? extension,
    bool parseJson = false,
  }) async => adapter.scanFiles(
    relativePath,
    extension: extension,
    parseJson: parseJson,
  );

  Future<List<String>> listFolders(String relativePath) =>
      adapter.listFolders(relativePath);

  // --- metadata.json ---

  Future<Map<String, dynamic>> readMetadata() async {
    if (await adapter.exists(metadataPath)) {
      return Map<String, dynamic>.from(
        await adapter.readJsonFile(metadataPath),
      );
    }
    return {};
  }

  Future<void> writeMetadata(Map<String, dynamic> metadata) =>
      adapter.writeJsonFile(metadataPath, metadata);

  /// Атомарное чтение-изменение-запись metadata.json.
  Future<T> mutateMetadata<T>(
    FutureOr<T> Function(Map<String, dynamic> metadata) mutate,
  ) async {
    final metadata = await readMetadata();
    final result = await mutate(metadata);
    await writeMetadata(metadata);
    return result;
  }

  /// Человекочитаемое имя файла из metadata (или фолбэк на сам файл).
  Future<String> resolveFileName(String fileName) async {
    return fileNameFromMetadata(await readMetadata(), fileName);
  }

  /// Имя файла из уже загруженной карты metadata.
  static String fileNameFromMetadata(
    Map<String, dynamic> metadata,
    String fileName,
  ) {
    final val = metadata[fileName];
    if (val is String && val.trim().isNotEmpty) return val;
    if (val is Map) {
      final name = val['name']?.toString().trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return fileName;
  }

  /// Запись/обновление имени и папки файла в metadata.
  Future<void> setFileMeta(
    String fileName, {
    required String friendlyName,
    required String folder,
    String? scriptType,
    String? stableId,
  }) {
    return mutateMetadata((metadata) {
      final entry = <String, dynamic>{'name': friendlyName, 'folder': folder};
      if (scriptType != null) entry['scriptType'] = scriptType;
      if (stableId != null && stableId.isNotEmpty) {
        entry['resourceId'] = stableId;
      }
      metadata[fileName] = entry;
    });
  }

  Future<void> removeFileMeta(String fileName) {
    return mutateMetadata((metadata) {
      metadata.remove(fileName);
    });
  }

  // --- Папки (виртуальные, в metadata.json) ---

  static String normalizeFolderPath(String path) {
    var value = path.trim().replaceAll('\\', '/');
    if (value.isEmpty || value == '/') return '/';
    if (!value.startsWith('/')) value = '/$value';
    while (value.contains('//')) {
      value = value.replaceAll('//', '/');
    }
    if (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static bool isSameOrDescendantFolder(String parent, String candidate) {
    final np = normalizeFolderPath(parent);
    final nc = normalizeFolderPath(candidate);
    if (np == '/') return true;
    return nc == np || nc.startsWith('$np/');
  }

  static List<String> foldersOf(Map<String, dynamic> metadata) =>
      List<String>.from(
        metadata[foldersKey] ?? [],
      ).map(normalizeFolderPath).toSet().toList();
}
