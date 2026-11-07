import 'dart:io';
import 'dart:math' as math;

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:mnd_player/utils/trigger_reference.dart';
import 'package:canvas_app/core/services/refactoring_service.dart';
import 'package:canvas_app/features/resources/models/resource_file.dart';
import 'package:canvas_app/features/resources/services/quest_storage.dart';
import 'package:mnd_core/src/gen/api/image.dart' as rust_image;
import 'package:mnd_core/utils/quest_paths.dart';

/// Результат загрузки ресурсов квеста.
class ResourcesData {
  final List<ResourceFile> resources;
  final List<String> explicitFolders;
  const ResourcesData({required this.resources, required this.explicitFolders});
}

/// Описание созданного скрипта.
class CreatedScript {
  /// UUID без расширения (для визуальных скриптов — это scriptId).
  final String id;

  /// Имя файла на диске (`<uuid>.json` или `<name>.lua`).
  final String fileName;

  /// Полный относительный путь (`quests/<id>/scripts/<file>`).
  final String filePath;

  /// Путь относительно корня квеста (`scripts/<file>`) — значение для
  /// `scriptTriggers`/`resourcePath`/`scriptAssetId`.
  final String questRelativePath;

  /// Stable metadata identity used by workspace tabs.
  final String? stableId;

  /// Человекочитаемое имя.
  final String name;

  const CreatedScript({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.questRelativePath,
    this.stableId,
    required this.name,
  });
}

/// Единая точка работы с ресурсами квеста: файлы, metadata.json
/// (виртуальные папки и имена), создание/переименование/перенос скриптов,
/// резолв человекочитаемых имён (в т.ч. `TriggerReference` с `#fn=`).
///
/// Все экраны обязаны ходить сюда, а не в `metadata.json` напрямую.
class ResourceService {
  final QuestStorage storage;

  ResourceService({required this.storage});

  factory ResourceService.forQuest(String questId, {StorageAdapter? adapter}) {
    return ResourceService(
      storage: QuestStorage(questId: questId, adapter: adapter),
    );
  }

  static const _uuid = Uuid();

  String get questId => storage.questId;

  /// Кэш `имяФайла → человекочитаемое имя` по данным metadata.json.
  /// Наполняется в [loadResources] и при создании/переименовании.
  final Map<String, String> _nameCache = {};
  Map<String, String> get nameCache => Map.unmodifiable(_nameCache);

  /// Последний снимок [loadResources]. Экран библиотеки показывает его сразу
  /// при повторном открытии (возврат из скрипта, смена вкладки), не дожидаясь
  /// обхода диска; свежие данные подтягиваются фоном.
  ResourcesData? _lastData;
  ResourcesData? get lastLoaded => _lastData;

  // --- Нормализация путей (единая реализация) ---

  static String normalizeFolderPath(String path) =>
      QuestStorage.normalizeFolderPath(path);

  static bool isSameOrDescendantFolder(String parent, String candidate) =>
      QuestStorage.isSameOrDescendantFolder(parent, candidate);

  /// Рекурсивно считает реальные блоки-действия в скрипте.
  /// Event-обёртки (event/функция) не считаются за блоки — учитываются
  /// только их вложенные дочерние блоки. Контейнеры (condition/crossfade)
  /// считаются как 1 блок плюс все вложенные.
  static int countActionBlocks(List<dynamic> blocks) {
    var count = 0;
    for (final raw in blocks) {
      if (raw is! Map) continue;
      final block = Map<String, dynamic>.from(raw);
      final type = (block['type'] ?? block['действие'])?.toString();
      final isEventWrapper =
          type == 'event' || (type == null && block.containsKey('title'));

      if (!isEventWrapper) count++;

      for (final key in const [
        'children',
        'then_blocks',
        'else_blocks',
        'если_да',
        'если_нет',
      ]) {
        final nested = block[key];
        if (nested is List) count += countActionBlocks(nested);
      }
    }
    return count;
  }

  /// Абсолютный путь файла (превью, замена файлов, File API).
  Future<String> absolutePath(String relativePath) =>
      storage.absolutePath(relativePath);

  // --- Загрузка всех ресурсов ---

  Future<ResourcesData> loadResources() async {
    final metadata = await storage.readMetadata();
    var metadataChanged = false;

    final explicitFolders = QuestStorage.foldersOf(metadata);

    final resources = <ResourceFile>[];
    const types = ['image', 'audio', 'video', 'font', 'script', 'lua'];

    for (final type in types) {
      final folderPath = storage.typeDir(type);
      final extension = switch (type) {
        'script' => '.json',
        'lua' => '.lua',
        _ => null,
      };

      // Ядро отдаёт снимок каталога одним вызовом (имена, размеры, mtime,
      // для скриптов — имя и число блоков); без моста (тесты, веб) идём
      // пофайлово, как раньше.
      final scanned = await storage.scanFiles(
        folderPath,
        extension: extension,
        parseJson: type == 'script',
      );
      final List<(String, ResourceFileFacts?)> entries;
      if (scanned != null) {
        entries = [for (final facts in scanned) (facts.fileName, facts)];
      } else {
        final files = await storage.listFiles(folderPath, extension: extension);
        entries = [for (final fileName in files) (fileName, null)];
      }

      for (final (fileName, facts) in entries) {
        var friendlyName = fileName;
        var folder = '/';
        var scriptType = ScriptType.generic;
        String? stableId;
        final relativePath = '$folderPath/$fileName';

        final val = metadata[fileName];
        if (val is String) {
          friendlyName = val;
        } else if (val is Map) {
          friendlyName = (val['name'] ?? fileName).toString();
          stableId = val['resourceId']?.toString();
          folder = QuestStorage.normalizeFolderPath(
            (val['folder'] ?? '/').toString(),
          );
          switch (val['scriptType']?.toString()) {
            case 'event':
              scriptType = ScriptType.event;
              break;
            case 'condition':
              scriptType = ScriptType.condition;
              break;
          }
        }

        if (type == 'lua' && (stableId == null || stableId.isEmpty)) {
          stableId = _uuid.v4();
          final migratedMeta = val is Map
              ? Map<String, dynamic>.from(val)
              : <String, dynamic>{'name': friendlyName, 'folder': folder};
          migratedMeta['resourceId'] = stableId;
          metadata[fileName] = migratedMeta;
          metadataChanged = true;
        }

        var blockCount = 0;
        if (type == 'script') {
          if (facts != null) {
            final jsonName = facts.jsonName;
            if (friendlyName == fileName &&
                jsonName != null &&
                jsonName.isNotEmpty) {
              friendlyName = jsonName;
            }
            blockCount = facts.blockCount;
          } else {
            try {
              final content = await storage.readJson(relativePath);
              final jsonName = content['name']?.toString().trim();
              if (friendlyName == fileName &&
                  jsonName != null &&
                  jsonName.isNotEmpty) {
                friendlyName = jsonName;
              }
              final blocks = content['blocks'];
              if (blocks is List) blockCount = countActionBlocks(blocks);
            } catch (_) {}
          }
        }

        _nameCache[fileName] = friendlyName;

        var sizeBytes = facts?.sizeBytes ?? 0;
        DateTime? modifiedAt = facts?.modifiedAt;
        if (facts == null) {
          try {
            final absolute = await storage.absolutePath(relativePath);
            final stat = await File(absolute).stat();
            sizeBytes = stat.size;
            modifiedAt = stat.modified;
          } catch (_) {}
        }

        resources.add(
          ResourceFile(
            id: fileName,
            stableId: stableId ?? (type == 'script' ? fileName : null),
            name: fileName,
            path: relativePath,
            type: type,
            friendlyName: friendlyName,
            folder: folder,
            scriptType: scriptType,
            sizeBytes: sizeBytes,
            modifiedAt: modifiedAt,
            blockCount: blockCount,
          ),
        );
      }
    }

    if (metadataChanged) {
      await storage.writeMetadata(metadata);
    }

    final data = ResourcesData(
      resources: resources,
      explicitFolders: explicitFolders,
    );
    _lastData = data;
    return data;
  }

  /// Лёгкое наполнение кэша имён (без сканирования ресурсов).
  Future<void> loadNameCache() async {
    final metadata = await storage.readMetadata();
    for (final entry in metadata.entries) {
      if (entry.key == QuestStorage.foldersKey) continue;
      final val = entry.value;
      if (val is String && val.trim().isNotEmpty) {
        _nameCache[entry.key] = val;
      } else if (val is Map) {
        final name = val['name']?.toString().trim();
        if (name != null && name.isNotEmpty) _nameCache[entry.key] = name;
      }
    }
  }

  // --- Авто-имя ---

  /// «Скрипт N» — первое свободное имя в стиле Adobe/документных редакторов:
  /// без диалогов на этапе создания, переименование — потом в редакторе.
  Future<String> autoScriptName({String prefix = 'Скрипт'}) async {
    final pattern = RegExp('^${RegExp.escape(prefix)} (\\d+)\$');
    final used = <String>{};
    var maxN = 0;

    void register(String name) {
      used.add(name);
      final m = pattern.firstMatch(name.trim());
      if (m != null) {
        maxN = math.max(maxN, int.parse(m.group(1)!));
      }
    }

    final metadata = await storage.readMetadata();
    for (final entry in metadata.entries) {
      if (entry.key == QuestStorage.foldersKey) continue;
      final val = entry.value;
      if (val is String && val.trim().isNotEmpty) {
        register(val.trim());
      } else if (val is Map) {
        final name = val['name']?.toString().trim();
        if (name != null && name.isNotEmpty) register(name);
      }
    }

    // Имена внутри JSON-файлов скриптов (первоисточник после rename).
    try {
      final files = await storage.listFiles(
        storage.scriptsDir,
        extension: '.json',
      );
      for (final f in files) {
        try {
          final data = await storage.readJson(storage.scriptFilePath(f));
          final name = data['name']?.toString().trim();
          if (name != null && name.isNotEmpty) register(name);
        } catch (_) {}
      }
    } catch (_) {}

    var n = maxN + 1;
    while (used.contains('$prefix $n')) {
      n++;
    }
    return '$prefix $n';
  }

  // --- Создание скриптов ---

  /// Создаёт новый визуальный (JSON) скрипт и пишет metadata.
  ///
  /// [name] — человекочитаемое имя; если не задано — авто-имя («Скрипт N»).
  /// [initialBlocks] — стартовые блоки (шаблон события и т.п.).
  /// Возвращает [CreatedScript] (id = UUID без расширения).
  Future<CreatedScript> createScript({
    String? name,
    String folder = '/',
    List<Map<String, dynamic>> initialBlocks = const [],
  }) async {
    final scriptName = (name?.trim().isNotEmpty ?? false)
        ? name!.trim()
        : await autoScriptName();
    final id = _uuid.v4();
    final fileName = '$id.json';
    final filePath = storage.scriptFilePath(fileName);

    await storage.writeJson(filePath, {
      'id': id,
      'name': scriptName,
      'blocks': initialBlocks,
    });
    await storage.setFileMeta(
      fileName,
      friendlyName: scriptName,
      folder: QuestStorage.normalizeFolderPath(folder),
      stableId: id,
    );
    _nameCache[fileName] = scriptName;

    return CreatedScript(
      id: id,
      fileName: fileName,
      filePath: filePath,
      questRelativePath: 'scripts/$fileName',
      stableId: id,
      name: scriptName,
    );
  }

  /// Шаблон нового Lua-скрипта (общий, без привязки к событию).
  static String luaTemplate(String name) =>
      '-- $name\nfunction start()\n    core.set_var(\'x\', 42)\nend\n';

  /// Создаёт новый `.lua`-скрипт и пишет metadata.
  ///
  /// Имя файла здесь человекочитаемое (`<name>.lua`) — оно же scriptId
  /// блока call_lua. Если [name] не задано — авто-имя («Lua-скрипт N»).
  /// [template] — полное содержимое файла (по умолчанию [luaTemplate]).
  /// Возвращает имя файла (например `start.lua`).
  Future<CreatedScript> createLuaScript({
    String? name,
    String folder = '/',
    String? template,
  }) async {
    var scriptName = (name?.trim().isNotEmpty ?? false)
        ? name!.trim()
        : await autoScriptName(prefix: 'Lua-скрипт');

    var fileName = '$scriptName.lua';
    // Человекочитаемое имя файла обязано быть уникальным.
    if (await storage.exists(storage.scriptFilePath(fileName))) {
      var i = 2;
      while (await storage.exists(
        storage.scriptFilePath('$scriptName ($i).lua'),
      )) {
        i++;
      }
      scriptName = '$scriptName ($i)';
      fileName = '$scriptName.lua';
    }

    final filePath = storage.scriptFilePath(fileName);
    final stableId = _uuid.v4();
    await storage.writeText(filePath, template ?? luaTemplate(scriptName));
    await storage.setFileMeta(
      fileName,
      friendlyName: scriptName,
      folder: QuestStorage.normalizeFolderPath(folder),
      stableId: stableId,
    );
    _nameCache[fileName] = scriptName;

    return CreatedScript(
      id: scriptName,
      fileName: fileName,
      filePath: filePath,
      questRelativePath: 'scripts/$fileName',
      stableId: stableId,
      name: scriptName,
    );
  }

  // --- Резолв имён ---

  /// Человекочитаемое имя файла из metadata (с кэшем).
  Future<String> resolveDisplayName(String fileName) async {
    final cached = _nameCache[fileName];
    if (cached != null && cached.trim().isNotEmpty) return cached;
    final live = await storage.resolveFileName(fileName);
    if (live != fileName) _nameCache[fileName] = live;
    return live;
  }

  /// Имя по уже загруженному кэшу (синхронно; фолбэк — сам fileName).
  String resolveDisplayNameSync(String fileName) {
    final cached = _nameCache[fileName];
    if (cached != null && cached.trim().isNotEmpty) return cached;
    return fileName;
  }

  /// Человекочитаемое имя скрипта по сырой ссылке триггера/блока
  /// (путь вида `scripts/x.json`, `scripts/x.lua`, допускает `#fn=func`).
  ///
  /// Для JSON-скриптов первоисточник — поле `name` внутри файла;
  /// для `.lua` — metadata. Для `#fn=` добавляется суффикс ` :: функция`.
  Future<String> resolveScriptDisplayName(String rawRef) async {
    final triggerRef = TriggerReference.parse(rawRef);
    final scriptPath = triggerRef.scriptPath;
    if (scriptPath.isEmpty) return '';
    final fileName = p.basename(scriptPath);
    final isLua = fileName.toLowerCase().endsWith('.lua');

    var baseName = fileName;
    if (!isLua) {
      try {
        final fullPath = '${storage.rootPath}/$scriptPath';
        if (await storage.exists(fullPath)) {
          final data = await storage.readJson(fullPath);
          final scriptName = data['name']?.toString().trim();
          if (scriptName != null && scriptName.isNotEmpty) {
            _nameCache[fileName] = scriptName;
            baseName = scriptName;
          }
        }
      } catch (_) {}
    }

    if (baseName == fileName) {
      baseName = await resolveDisplayName(fileName);
    }

    if (triggerRef.isFunctionRef) {
      return '$baseName :: ${triggerRef.functionEntry}';
    }
    return baseName;
  }

  // --- Обновление metadata ---

  Future<void> updateMetadata(
    String fileName,
    String friendlyName,
    String folder,
  ) async {
    await storage.setFileMeta(
      fileName,
      friendlyName: friendlyName,
      folder: QuestStorage.normalizeFolderPath(folder),
    );
    _nameCache[fileName] = friendlyName;
  }

  // --- Папки ---

  Future<void> createFolder(String newPath) async {
    final normalized = QuestStorage.normalizeFolderPath(newPath);
    await storage.mutateMetadata((metadata) {
      final folders = QuestStorage.foldersOf(metadata);
      if (!folders.contains(normalized)) {
        folders.add(normalized);
        metadata[QuestStorage.foldersKey] = folders;
      }
    });
  }

  Future<List<String>> loadFolders() async {
    final metadata = await storage.readMetadata();
    return QuestStorage.foldersOf(metadata);
  }

  /// Все папки: явные (`__folders__`) + выведенные из folder-записей файлов.
  /// Используется пикерами папок, чтобы показывать и «неявные» папки.
  Future<List<String>> loadAllFolders() async {
    final metadata = await storage.readMetadata();
    final folders = <String>{'/', ...QuestStorage.foldersOf(metadata)};
    metadata.forEach((key, value) {
      if (key != QuestStorage.foldersKey &&
          value is Map &&
          value['folder'] != null) {
        folders.add(
          QuestStorage.normalizeFolderPath(value['folder'].toString()),
        );
      }
    });
    return folders.toList()..sort();
  }

  Future<void> deleteFolder(
    String folderPath,
    List<ResourceFile> filesInFolder, {
    required bool deleteFiles,
  }) async {
    final normalized = QuestStorage.normalizeFolderPath(folderPath);
    await storage.mutateMetadata((metadata) async {
      final folders = QuestStorage.foldersOf(metadata);
      folders.removeWhere(
        (f) => f == normalized || f.startsWith('$normalized/'),
      );
      metadata[QuestStorage.foldersKey] = folders;

      for (final file in filesInFolder) {
        if (deleteFiles) {
          await storage.delete(file.path);
          metadata.remove(file.name);
          _nameCache.remove(file.name);
        } else {
          final data = metadata[file.name];
          if (data is Map) {
            data['folder'] = '/';
            metadata[file.name] = data;
          }
        }
      }
    });
  }

  Future<void> renameFolder(String oldPath, String newPath) async {
    final fullOld = QuestStorage.normalizeFolderPath(oldPath);
    final fullNew = QuestStorage.normalizeFolderPath(newPath);
    await storage.mutateMetadata((metadata) {
      final folders = QuestStorage.foldersOf(metadata);
      metadata[QuestStorage.foldersKey] = folders.map((f) {
        if (f == fullOld) return fullNew;
        if (f.startsWith('$fullOld/')) return f.replaceFirst(fullOld, fullNew);
        return f;
      }).toList();

      metadata.forEach((k, v) {
        if (k != QuestStorage.foldersKey && v is Map && v['folder'] != null) {
          final f = QuestStorage.normalizeFolderPath(v['folder'].toString());
          if (f == fullOld) {
            v['folder'] = fullNew;
          } else if (f.startsWith('$fullOld/')) {
            v['folder'] = f.replaceFirst(fullOld, fullNew);
          }
        }
      });
    });
  }

  // --- Массовые операции ---

  Future<void> deleteItems(
    Set<String> selectedItems,
    List<ResourceFile> allResources,
  ) async {
    await storage.mutateMetadata((metadata) async {
      var metaFolders = List<String>.from(
        metadata[QuestStorage.foldersKey] ?? [],
      );

      for (final item in selectedItems) {
        if (item.startsWith('/')) {
          metaFolders.removeWhere((f) => f == item || f.startsWith('$item/'));
          final filesToDelete = allResources.where(
            (r) => r.folder == item || r.folder.startsWith('$item/'),
          );
          for (final f in filesToDelete) {
            await storage.delete(f.path);
            metadata.remove(f.name);
            _nameCache.remove(f.name);
          }
        } else {
          final res = allResources.firstWhere(
            (r) => r.id == item,
            orElse: () => ResourceFile.empty,
          );
          if (!res.isEmpty) {
            await storage.delete(res.path);
            metadata.remove(res.name);
            _nameCache.remove(res.name);
          }
        }
      }

      metadata[QuestStorage.foldersKey] = metaFolders;
    });
  }

  Future<void> moveItems(
    Set<String> selectedItems,
    List<ResourceFile> allResources,
    String targetFolder,
  ) async {
    await storage.mutateMetadata((metadata) {
      var metaFolders = List<String>.from(
        metadata[QuestStorage.foldersKey] ?? [],
      );

      for (final item in selectedItems) {
        if (item.startsWith('/')) {
          final oldFolderPath = item;
          final folderName = p.basename(oldFolderPath);
          final newFolderPath = targetFolder == '/'
              ? '/$folderName'
              : '$targetFolder/$folderName';

          if (oldFolderPath == newFolderPath ||
              QuestStorage.isSameOrDescendantFolder(
                oldFolderPath,
                targetFolder,
              )) {
            continue;
          }

          metaFolders = metaFolders.map((f) {
            if (f == oldFolderPath) return newFolderPath;
            if (f.startsWith('$oldFolderPath/')) {
              return f.replaceFirst(oldFolderPath, newFolderPath);
            }
            return f;
          }).toList();

          metadata.forEach((k, v) {
            if (k != QuestStorage.foldersKey &&
                v is Map &&
                v['folder'] != null) {
              final f = v['folder'].toString();
              if (f == oldFolderPath) {
                v['folder'] = newFolderPath;
              } else if (f.startsWith('$oldFolderPath/')) {
                v['folder'] = f.replaceFirst(oldFolderPath, newFolderPath);
              }
            }
          });
        } else {
          final res = allResources.firstWhere(
            (r) => r.id == item,
            orElse: () => ResourceFile.empty,
          );
          if (res.isEmpty) continue;
          if (metadata[res.name] is Map) {
            metadata[res.name]['folder'] = targetFolder;
          } else {
            metadata[res.name] = {
              'name': res.friendlyName,
              'folder': targetFolder,
            };
          }
        }
      }

      metadata[QuestStorage.foldersKey] = metaFolders;
    });
  }

  /// Копирует скрипты в указанный квест. Возвращает (скопировано, ошибок).
  Future<({int copied, int failed})> copyScripts(
    List<ResourceFile> scripts,
    String targetQuestId,
  ) async {
    final targetMetadataPath = QuestPaths.metadata(targetQuestId);
    final targetMetadata = await storage.exists(targetMetadataPath)
        ? await storage.readJson(targetMetadataPath)
        : <String, dynamic>{};
    final targetFolders = List<String>.from(
      targetMetadata[QuestStorage.foldersKey] ?? [],
    );

    var copied = 0;
    var failed = 0;
    for (final source in scripts) {
      try {
        if (!await storage.exists(source.path)) {
          failed++;
          continue;
        }

        final original = Map<String, dynamic>.from(
          await storage.readJson(source.path),
        );
        final newScriptId = _uuid.v4();
        final newFileName = '$newScriptId.json';
        final newPath = QuestPaths.scriptPath(targetQuestId, newFileName);
        final sourceName =
            (original['name'] as String?)?.trim().isNotEmpty == true
            ? original['name'] as String
            : source.friendlyName;
        final copiedName = '$sourceName (копия)';

        original['id'] = newScriptId;
        original['name'] = copiedName;
        await storage.writeJson(newPath, original);

        final targetFolder = source.folder.isEmpty ? '/' : source.folder;
        if (targetFolder != '/' && !targetFolders.contains(targetFolder)) {
          targetFolders.add(targetFolder);
        }
        targetMetadata[newFileName] = {
          'name': copiedName,
          'folder': targetFolder,
        };
        copied++;
      } catch (_) {
        failed++;
      }
    }

    targetMetadata[QuestStorage.foldersKey] = targetFolders;
    await storage.writeJson(targetMetadataPath, targetMetadata);
    return (copied: copied, failed: failed);
  }

  // --- Добавление файлов ---

  /// Копирует выбранные внешние файлы в папку ресурса данного типа.
  /// Возвращает список созданных имён файлов (для последующего refresh).
  ///
  /// [convertImages] (#148) — пережимать ввозимые PNG в WebP на лету. Квест
  /// весит в основном картинками, и без потерь выходит 60–63 % исходника.
  /// JPEG не трогаем: без потерь он только раздувается. Когда пережатие не
  /// выигрывает и по размеру, остаётся оригинал.
  Future<List<String>> importFiles(
    List<({String sourcePath, String displayName})> files,
    String type,
    String folder, {
    bool convertImages = true,
  }) async {
    final created = <String>[];
    for (final file in files) {
      final webp = convertImages && type == 'image'
          ? await _encodeWebp(file.sourcePath)
          : null;
      final ext = webp == null ? p.extension(file.sourcePath) : '.webp';
      final fileName = '${_uuid.v4()}$ext';
      final targetRelative = '${storage.typeDir(type)}/$fileName';
      final targetPath = await storage.absolutePath(targetRelative);
      final target = File(targetPath);
      await target.parent.create(recursive: true);
      if (webp == null) {
        await File(file.sourcePath).copy(targetPath);
      } else {
        await target.writeAsBytes(webp);
      }

      final originalName = p.basenameWithoutExtension(file.displayName);
      await updateMetadata(fileName, originalName, folder);
      created.add(fileName);
    }
    return created;
  }

  /// PNG → байты WebP; `null` — оставить файл как есть. Молча отказываемся
  /// и от сломанного мостика тоже: импорт картинки не должен падать из-за
  /// оптимизации размера.
  Future<List<int>?> _encodeWebp(String sourcePath) async {
    try {
      final fileName = p.basename(sourcePath);
      if (!await rust_image.imageIsConvertible(fileName: fileName)) {
        return null;
      }
      final bytes = await File(sourcePath).readAsBytes();
      return await rust_image.imageToWebp(fileName: fileName, bytes: bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> renameResource(ResourceFile resource, String newName) async {
    final trimmed = newName.trim();
    // Пробельное имя ломает отображение везде, а «без изменений» — это
    // лишняя перезапись файла скрипта поверх автосейва открытого редактора.
    if (trimmed.isEmpty || trimmed == resource.friendlyName) return;
    await updateMetadata(resource.name, trimmed, resource.folder);
    if (resource.type == 'script') {
      final content = Map<String, dynamic>.from(
        await storage.readJson(resource.path),
      );
      content['name'] = trimmed;
      await storage.writeJson(resource.path, content);
    }
    // Открытый редактор держит старое имя в буфере и своим автосейвом
    // вернул бы его на диск (и в metadata) — говорим ему о новом имени.
    RefactoringService.emitResourceRename(
      ResourceRenameEvent(
        questId: storage.questId,
        fileName: resource.name,
        newName: trimmed,
      ),
    );
  }

  /// Переименование по имени файла — для экранов, где под рукой только
  /// имя (пикиры ресурсов, редактор скриптов). false — файл не скрипт.
  Future<bool> renameByFileName(String fileName, String newName) async {
    final resource = await findResourceByFileName(fileName);
    if (resource == null) return false;
    await renameResource(resource, newName);
    return true;
  }

  /// Находит ресурс по имени файла (для редакторов скриптов: rename/move).
  Future<ResourceFile?> findResourceByFileName(String fileName) async {
    final metadata = await storage.readMetadata();
    final val = metadata[fileName];
    var friendlyName = fileName;
    var folder = '/';
    String? stableId;
    if (val is String && val.trim().isNotEmpty) {
      friendlyName = val.trim();
    } else if (val is Map) {
      final name = val['name']?.toString().trim();
      if (name != null && name.isNotEmpty) friendlyName = name;
      stableId = val['resourceId']?.toString();
      folder = QuestStorage.normalizeFolderPath(
        val['folder']?.toString() ?? '/',
      );
    }

    final lower = fileName.toLowerCase();
    final String type;
    final String path;
    if (lower.endsWith('.lua')) {
      type = 'lua';
      path = storage.scriptFilePath(fileName);
    } else if (lower.endsWith('.json')) {
      type = 'script';
      path = await storage.exists(storage.scriptFilePath(fileName))
          ? storage.scriptFilePath(fileName)
          : '${storage.internalScriptsDir}/$fileName';
    } else {
      return null;
    }

    if (type == 'lua' &&
        (stableId == null || stableId.isEmpty) &&
        await storage.exists(path)) {
      stableId = _uuid.v4();
      await storage.setFileMeta(
        fileName,
        friendlyName: friendlyName,
        folder: folder,
        stableId: stableId,
      );
    }

    return ResourceFile(
      id: fileName,
      stableId: stableId ?? fileName,
      name: fileName,
      path: path,
      type: type,
      friendlyName: friendlyName,
      folder: folder,
    );
  }

  /// Перенос одного файла в виртуальную папку (без перебора всего списка).
  Future<void> setResourceFolder(String fileName, String folder) async {
    final normalized = QuestStorage.normalizeFolderPath(folder);
    await storage.mutateMetadata((metadata) {
      final entry = metadata[fileName];
      if (entry is Map) {
        entry['folder'] = normalized;
      } else {
        final name = entry is String && entry.trim().isNotEmpty
            ? entry.trim()
            : fileName;
        metadata[fileName] = {'name': name, 'folder': normalized};
      }
      final folders = List<String>.from(
        metadata[QuestStorage.foldersKey] ?? [],
      );
      final normalizedSet = folders
          .map(QuestStorage.normalizeFolderPath)
          .toSet();
      normalizedSet.add(normalized);
      metadata[QuestStorage.foldersKey] = normalizedSet.toList();
    });
  }

  Future<void> replaceResourceFile(
    ResourceFile resource,
    String sourcePath,
  ) async {
    final destPath = await storage.absolutePath(resource.path);
    await File(sourcePath).copy(destPath);
  }

  Future<void> deleteResource(ResourceFile resource) async {
    await storage.delete(resource.path);
    await storage.removeFileMeta(resource.name);
    _nameCache.remove(resource.name);
  }

  // --- Выбор квеста для копирования ---

  Future<List<({String id, String title})>> listOtherQuests() async {
    final questIds = await storage.listFolders(QuestPaths.questsDir);
    final items = <({String id, String title})>[];

    for (final id in questIds) {
      if (id == questId) continue;

      String? rawTitle;
      final configPath = QuestPaths.config(id);
      if (await storage.exists(configPath)) {
        try {
          final cfg = await storage.readJson(configPath);
          rawTitle = (cfg['name'] as String?)?.trim().isNotEmpty == true
              ? cfg['name'] as String
              : ((cfg['title'] as String?)?.trim().isNotEmpty == true
                    ? cfg['title'] as String
                    : null);
        } catch (_) {}
      }

      items.add((id: id, title: _normalizeQuestTitle(id, rawTitle)));
    }

    items.sort((a, b) {
      final t = a.title.compareTo(b.title);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
    return items;
  }

  static bool _looksLikeUuid(String value) {
    return RegExp(
      r'^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
  }

  static String _normalizeQuestTitle(String questId, String? maybeName) {
    final title = maybeName?.trim() ?? '';
    if (title.isEmpty || title == questId || _looksLikeUuid(title)) {
      return tr('Квест без названия');
    }
    return title;
  }

  static String shortQuestId(String questId) {
    if (questId.length <= 20) return questId;
    return '${questId.substring(0, 8)}...'
        '${questId.substring(questId.length - 6)}';
  }
}
