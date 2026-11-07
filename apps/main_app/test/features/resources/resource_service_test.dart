import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';

import 'package:canvas_app/features/resources/models/resource_file.dart';
import 'package:canvas_app/features/resources/services/quest_storage.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';

/// In-memory реализация [StorageAdapter] для unit-тестов (без path_provider).
class InMemoryStorageAdapter implements StorageAdapter {
  final Map<String, dynamic> jsonFiles = {};
  final Map<String, String> textFiles = {};
  final Set<String> deleted = {};

  @override
  Future<Map<String, dynamic>> readJsonFile(String relativePath) async {
    final data = jsonFiles[relativePath];
    if (data == null) throw Exception('Файл $relativePath не существует');
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Future<void> writeJsonFile(
    String relativePath,
    Map<String, dynamic> data,
  ) async {
    jsonFiles[relativePath] = Map<String, dynamic>.from(data);
  }

  @override
  Future<List<String>> listFiles(
    String relativePath, {
    String? extension,
  }) async {
    final prefix = relativePath.endsWith('/') ? relativePath : '$relativePath/';
    final result = <String>[];
    for (final path in [...jsonFiles.keys, ...textFiles.keys]) {
      if (!path.startsWith(prefix)) continue;
      final name = path.substring(prefix.length);
      if (name.contains('/')) continue;
      if (extension != null && !name.endsWith(extension)) continue;
      result.add(name);
    }
    return result;
  }

  @override
  Future<List<String>> listFolders(String relativePath) async {
    final prefix = relativePath.endsWith('/') ? relativePath : '$relativePath/';
    final folders = <String>{};
    for (final path in [...jsonFiles.keys, ...textFiles.keys]) {
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash > 0) folders.add(rest.substring(0, slash));
    }
    return folders.toList();
  }

  @override
  Future<bool> exists(String relativePath) async =>
      jsonFiles.containsKey(relativePath) ||
      textFiles.containsKey(relativePath);

  @override
  Future<void> delete(String relativePath) async {
    jsonFiles.remove(relativePath);
    textFiles.remove(relativePath);
    deleted.add(relativePath);
  }

  @override
  Future<String> getFilePath(String relativePath) async =>
      '/in-memory/$relativePath';

  @override
  Future<String> readText(String relativePath) async {
    final data = textFiles[relativePath];
    if (data == null) throw Exception('Файл $relativePath не существует');
    return data;
  }

  @override
  Future<void> writeText(String relativePath, String content) async {
    textFiles[relativePath] = content;
  }

  // Тест-адаптер без массового снимка: сервис идёт пофайловым путём.
  @override
  Future<List<ResourceFileFacts>?> scanFiles(
    String relativePath, {
    String? extension,
    bool parseJson = false,
  }) async => null;
}

/// Адаптер с массовым снимком ядра: сервис не должен трогать файлы
/// пофайлово, когда снимок есть.
class ScanFactsStorageAdapter extends InMemoryStorageAdapter {
  ScanFactsStorageAdapter(this.facts);

  final Map<String, List<ResourceFileFacts>> facts;

  @override
  Future<List<ResourceFileFacts>?> scanFiles(
    String relativePath, {
    String? extension,
    bool parseJson = false,
  }) async => facts[relativePath] ?? const [];

  @override
  Future<Map<String, dynamic>> readJsonFile(String relativePath) async {
    if (relativePath.contains('/scripts/')) {
      throw StateError('снимок ядра должен отменить чтение $relativePath');
    }
    return super.readJsonFile(relativePath);
  }

  @override
  Future<String> getFilePath(String relativePath) async {
    throw StateError('снимок ядра должен отменить stat $relativePath');
  }
}

({ResourceService service, InMemoryStorageAdapter adapter}) makeService({
  String questId = 'q1',
}) {
  final adapter = InMemoryStorageAdapter();
  final service = ResourceService(
    storage: QuestStorage(questId: questId, adapter: adapter),
  );
  return (service: service, adapter: adapter);
}

void main() {
  group('QuestStorage.normalizeFolderPath', () {
    test('нормализует варианты', () {
      expect(QuestStorage.normalizeFolderPath(''), '/');
      expect(QuestStorage.normalizeFolderPath('/'), '/');
      expect(QuestStorage.normalizeFolderPath('a/b'), '/a/b');
      expect(QuestStorage.normalizeFolderPath('/a//b/'), '/a/b');
      expect(QuestStorage.normalizeFolderPath('\\a\\b'), '/a/b');
    });

    test('isSameOrDescendantFolder', () {
      expect(QuestStorage.isSameOrDescendantFolder('/', '/anything'), true);
      expect(
        QuestStorage.isSameOrDescendantFolder('/a', '/a/b'),
        true,
      );
      expect(QuestStorage.isSameOrDescendantFolder('/a', '/a'), true);
      expect(QuestStorage.isSameOrDescendantFolder('/a', '/ab'), false);
    });
  });

  group('ResourceService.autoScriptName', () {
    test('первое имя — «Скрипт 1»', () async {
      final s = makeService();
      expect(await s.service.autoScriptName(), 'Скрипт 1');
    });

    test('продолжает с максимума из metadata и имён в скриптах', () async {
      final s = makeService();
      final adapter = s.adapter;
      adapter.jsonFiles['quests/q1/res/metadata.json'] = {
        'a.png': {'name': 'Скрипт 3', 'folder': '/'},
        'b.json': {'name': 'Игровой', 'folder': '/'},
      };
      adapter.jsonFiles['quests/q1/scripts/deadbeef.json'] = {
        'id': 'deadbeef',
        'name': 'Скрипт 7',
        'blocks': [],
      };
      expect(await s.service.autoScriptName(), 'Скрипт 8');
    });

    test('учитывает уже созданные в текущей сессии', () async {
      final s = makeService();
      final first = await s.service.createScript();
      expect(first.name, 'Скрипт 1');
      final second = await s.service.createScript();
      expect(second.name, 'Скрипт 2');
    });
  });

  group('ResourceService.createScript', () {
    test('создаёт файл и metadata', () async {
      final s = makeService();
      final created = await s.service.createScript(
        name: 'Триггер кнопки',
        initialBlocks: [
          {'type': 'event', 'eventType': 'onPress', 'children': []},
        ],
      );

      expect(created.fileName, '${created.id}.json');
      expect(created.questRelativePath, 'scripts/${created.fileName}');

      final file = await s.adapter.readJsonFile(created.filePath);
      expect(file['id'], created.id);
      expect(file['name'], 'Триггер кнопки');
      expect((file['blocks'] as List), hasLength(1));

      final meta = await s.adapter.readJsonFile('quests/q1/res/metadata.json');
      expect(meta[created.fileName]['name'], 'Триггер кнопки');
      expect(meta[created.fileName]['folder'], '/');
    });

    test('имя-авто при пустом name', () async {
      final s = makeService();
      final created = await s.service.createScript(name: '   ');
      expect(created.name, 'Скрипт 1');
    });
  });

  group('ResourceService.createLuaScript', () {
    test('создаёт .lua и metadata', () async {
      final s = makeService();
      final created = await s.service.createLuaScript(name: 'гоблин');

      expect(created.fileName, 'гоблин.lua');
      final text = await s.adapter.readText(created.filePath);
      expect(text, contains('function start()'));

      final meta = await s.adapter.readJsonFile('quests/q1/res/metadata.json');
      expect(meta['гоблин.lua']['name'], 'гоблин');
      expect(meta['гоблин.lua']['resourceId'], created.stableId);
      expect(created.stableId, isNotEmpty);
    });

    test('уникальное имя при конфликте', () async {
      final s = makeService();
      await s.service.createLuaScript(name: 'гоблин');
      final second = await s.service.createLuaScript(name: 'гоблин');
      expect(second.fileName, 'гоблин (2).lua');
    });

    test('кастомный шаблон (событие onPress)', () async {
      final s = makeService();
      final created = await s.service.createLuaScript(
        name: 'клик',
        template: 'function onPress(item_id)\nend\n',
      );
      final text = await s.adapter.readText(created.filePath);
      expect(text, contains('function onPress(item_id)'));
    });
  });

  group('ResourceService.resolveScriptDisplayName', () {
    test('JSON: имя из файла — первоисточник', () async {
      final s = makeService();
      s.adapter.jsonFiles['quests/q1/res/metadata.json'] = {
        'abc.json': {'name': 'Старое имя', 'folder': '/'},
      };
      s.adapter.jsonFiles['quests/q1/scripts/abc.json'] = {
        'id': 'abc',
        'name': 'Новое имя',
        'blocks': [],
      };
      expect(
        await s.service.resolveScriptDisplayName('scripts/abc.json'),
        'Новое имя',
      );
    });

    test('#fn= добавляет суффикс функции', () async {
      final s = makeService();
      s.adapter.jsonFiles['quests/q1/scripts/abc.json'] = {
        'id': 'abc',
        'name': 'Боевой',
        'blocks': [],
      };
      expect(
        await s.service.resolveScriptDisplayName('scripts/abc.json#fn=main'),
        'Боевой :: main',
      );
    });

    test('.lua: имя из metadata', () async {
      final s = makeService();
      s.adapter.jsonFiles['quests/q1/res/metadata.json'] = {
        'гоблин.lua': {'name': 'гоблин', 'folder': '/'},
      };
      expect(
        await s.service.resolveScriptDisplayName('scripts/гоблин.lua'),
        'гоблин',
      );
    });

    test('фолбэк на имя файла', () async {
      final s = makeService();
      expect(
        await s.service.resolveScriptDisplayName('scripts/нет-такого.lua'),
        'нет-такого.lua',
      );
    });
  });

  group('ResourceService папки', () {
    test('createFolder + loadFolders', () async {
      final s = makeService();
      await s.service.createFolder('/Глава 1');
      await s.service.createFolder('/Глава 1'); // дедупликация
      expect(await s.service.loadFolders(), ['/Глава 1']);
    });

    test('deleteFolder переносит файлы в корень', () async {
      final s = makeService();
      final created = await s.service.createScript(
        name: 'x',
        folder: '/Глава 1',
      );
      await s.service.createFolder('/Глава 1');

      final data = await s.service.loadResources();
      final res = data.resources.firstWhere((r) => r.name == created.fileName);
      await s.service.deleteFolder('/Глава 1', [res], deleteFiles: false);

      final meta = await s.adapter.readJsonFile('quests/q1/res/metadata.json');
      expect(meta[created.fileName]['folder'], '/');
      expect(
        List<String>.from(meta['__folders__'] ?? []),
        isNot(contains('/Глава 1')),
      );
    });

    test('renameFolder переписывает папки файлов', () async {
      final s = makeService();
      await s.service.createFolder('/Глава 1');
      final created = await s.service.createScript(
        name: 'x',
        folder: '/Глава 1',
      );
      await s.service.renameFolder('/Глава 1', '/Глава 2');

      final meta = await s.adapter.readJsonFile('quests/q1/res/metadata.json');
      expect(meta[created.fileName]['folder'], '/Глава 2');
    });
  });

  group('ResourceService массовые операции', () {
    test('moveItems переносит файл', () async {
      final s = makeService();
      final created = await s.service.createScript(name: 'x');
      final data = await s.service.loadResources();
      final res = data.resources.firstWhere((r) => r.name == created.fileName);
      await s.service.moveItems({res.id}, data.resources, '/Скрипты');

      final meta = await s.adapter.readJsonFile('quests/q1/res/metadata.json');
      expect(meta[created.fileName]['folder'], '/Скрипты');
    });

    test('deleteItems удаляет файл и metadata', () async {
      final s = makeService();
      final created = await s.service.createScript(name: 'x');
      final data = await s.service.loadResources();
      final res = data.resources.firstWhere((r) => r.name == created.fileName);
      await s.service.deleteItems({res.id}, data.resources);

      expect(await s.adapter.exists(created.filePath), false);
      final meta = await s.adapter.readJsonFile('quests/q1/res/metadata.json');
      expect(meta.containsKey(created.fileName), false);
    });

    test('copyScripts копирует в другой квест', () async {
      final s = makeService();
      final created = await s.service.createScript(name: 'Исходный');
      final data = await s.service.loadResources();
      final res = data.resources.firstWhere((r) => r.name == created.fileName);

      final result = await s.service.copyScripts([res], 'q2');
      expect(result.copied, 1);
      expect(result.failed, 0);

      final targetMeta = await s.adapter.readJsonFile(
        'quests/q2/res/metadata.json',
      );
      final entries = targetMeta.entries
          .where((e) => e.key != '__folders__')
          .toList();
      expect(entries, hasLength(1));
      expect(entries.first.value['name'], 'Исходный (копия)');
    });
  });

  group('ResourceService.loadResources', () {
    test('смешанные типы и виртуальные папки', () async {
      final s = makeService();
      s.adapter.jsonFiles['quests/q1/res/metadata.json'] = {
        '__folders__': ['/Глава 1'],
        'a.png': {'name': 'Фон', 'folder': '/Глава 1'},
        'b.json': {'name': 'Сценарий', 'folder': '/'},
        'c.lua': {'name': 'Луа', 'folder': '/'},
      };
      s.adapter.jsonFiles['quests/q1/scripts/b.json'] = {
        'id': 'b',
        'name': 'Сценарий',
        'blocks': [
          {'type': 'event', 'eventType': 'onPress', 'children': [
            {'type': 'show_text', 'text': 'hi'},
            {'type': 'set_var'},
          ]},
        ],
      };
      s.adapter.textFiles['quests/q1/scripts/c.lua'] = 'return 1';
      // Картинка как «текстовый файл» — адаптер ин-мемори, достаточно exists.
      s.adapter.textFiles['quests/q1/res/images/a.png'] = 'png';

      final data = await s.service.loadResources();
      expect(data.explicitFolders, ['/Глава 1']);
      expect(data.resources.length, 3);

      final img = data.resources.firstWhere((r) => r.name == 'a.png');
      expect(img.friendlyName, 'Фон');
      expect(img.folder, '/Глава 1');

      final script = data.resources.firstWhere((r) => r.name == 'b.json');
      // event-обёртка не считается — только 2 вложенных блока-действия.
      expect(script.blockCount, 2);
      expect(script.type, 'script');

      final lua = data.resources.firstWhere((r) => r.name == 'c.lua');
      expect(lua.type, 'lua');
      expect(lua.stableId, isNotEmpty);
      final migratedMeta = await s.adapter.readJsonFile(
        'quests/q1/res/metadata.json',
      );
      expect(migratedMeta['c.lua']['resourceId'], lua.stableId);
    });

    test('снимок ядра: метаданные + имя и блоки из содержимого', () async {
      final adapter = ScanFactsStorageAdapter({
        QuestPaths.scriptsDir('q1'): const [
          ResourceFileFacts(
            fileName: 'a.json',
            sizeBytes: 1234,
            modifiedAt: null,
            jsonName: 'Из JSON',
            blockCount: 7,
          ),
          ResourceFileFacts(
            fileName: 'b.json',
            sizeBytes: 42,
            modifiedAt: null,
            jsonName: 'Имя из файла',
            blockCount: 2,
          ),
        ],
      });
      adapter.jsonFiles[QuestPaths.metadata('q1')] = {
        '__folders__': ['/Глава 1'],
        'a.json': {
          'name': 'Из metadata',
          'folder': '/Глава 1',
          'scriptType': 'condition',
        },
      };

      final data = await ResourceService(
        storage: QuestStorage(questId: 'q1', adapter: adapter),
      ).loadResources();

      final a = data.resources.firstWhere((r) => r.name == 'a.json');
      expect(a.friendlyName, 'Из metadata', reason: 'metadata приоритетнее');
      expect(a.folder, '/Глава 1');
      expect(a.scriptType, ScriptType.condition);
      expect(a.blockCount, 7);
      expect(a.sizeBytes, 1234);
      expect(a.stableId, 'a.json');

      final b = data.resources.firstWhere((r) => r.name == 'b.json');
      expect(b.friendlyName, 'Имя из файла', reason: 'имя из содержимого');
      expect(b.blockCount, 2);
      expect(b.sizeBytes, 42);
    });

    test('имя скрипта берётся из JSON, если metadata пустое', () async {
      final s = makeService();
      s.adapter.jsonFiles['quests/q1/scripts/b.json'] = {
        'id': 'b',
        'name': 'Имя из файла',
        'blocks': [],
      };
      final data = await s.service.loadResources();
      final script = data.resources.firstWhere((r) => r.name == 'b.json');
      expect(script.friendlyName, 'Имя из файла');
    });
  });
}
