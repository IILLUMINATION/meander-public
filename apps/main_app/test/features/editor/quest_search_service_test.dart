import 'package:canvas_app/features/editor/services/quest_search_service.dart';
import 'package:canvas_app/features/resources/services/quest_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Мини-хранилище квеста в памяти: поиск читает файлы, значит проверять его
/// нужно на файлах, а не на моках сервисов.
class _MemoryAdapter implements StorageAdapter {
  final Map<String, dynamic> json = {};
  final Map<String, String> text = {};

  @override
  Future<Map<String, dynamic>> readJsonFile(String path) async {
    final data = json[path];
    if (data is! Map) throw Exception('нет файла $path');
    return Map<String, dynamic>.from(data);
  }

  @override
  Future<List<String>> listFiles(String path, {String? extension}) async {
    final prefix = '$path/';
    return [
      ...json.keys,
      ...text.keys,
    ].where((p) {
      if (!p.startsWith(prefix)) return false;
      final name = p.substring(prefix.length);
      if (name.contains('/')) return false;
      return extension == null || name.endsWith(extension);
    }).map((p) => p.substring(prefix.length)).toList();
  }

  @override
  Future<bool> exists(String path) async =>
      json.containsKey(path) || text.containsKey(path);

  @override
  Future<List<String>> listFolders(String path) async => const [];

  @override
  Future<void> writeJsonFile(String path, Map<String, dynamic> data) async =>
      json[path] = data;

  @override
  Future<void> delete(String path) async {
    json.remove(path);
    text.remove(path);
  }

  @override
  Future<String> getFilePath(String path) async => path;

  @override
  Future<String> readText(String path) async => text[path] ?? '';

  @override
  Future<void> writeText(String path, String content) async =>
      text[path] = content;
}

void main() {
  late _MemoryAdapter adapter;
  late QuestSearchService service;

  setUp(() {
    adapter = _MemoryAdapter();
    adapter.json['quests/q1/config.json'] = {
      'variables': [
        {'name': 'золото', 'type': 'number'},
        {'name': 'флаг_моста', 'type': 'bool'},
      ],
      'tables': [
        {
          'name': 'склад',
          'columns': ['предмет'],
          'rows': [
            ['лампа'],
          ],
        },
      ],
    };
    adapter.json['quests/q1/nodes/index.json'] = {
      'nodes': [
        {'id': 'n1', 'title': 'Берег'},
        {'id': 'n2', 'title': 'Мост'},
      ],
    };
    adapter.json['quests/q1/nodes/n1.json'] = {
      'id': 'n1',
      'title': 'Берег',
      'content': {
        'items': [
          {'type': 'text', 'text': 'Туман стоит над водой'},
        ],
      },
    };
    adapter.json['quests/q1/nodes/n2.json'] = {
      'id': 'n2',
      'title': 'Мост',
      'content': {
        'items': [
          {'type': 'text', 'text': 'Доски скрипят'},
        ],
      },
    };
    adapter.json['quests/q1/scripts/aaa.json'] = {
      'name': 'Зажечь маяк',
      'blocks': [
        {
          'type': 'event',
          'eventType': 'onPress',
          'children': [
            {'type': 'assign_variable', 'variable': 'флаг_моста', 'value': '1'},
          ],
        },
      ],
    };
    adapter.json['quests/q1/_internal_scripts/bbb.json'] = {
      'name': 'Служебный',
      'blocks': [
        {'type': 'comment', 'text': 'временный обход'},
      ],
    };
    adapter.text['quests/q1/scripts/ccc.lua'] = 'local x = 1\nprint("маяк")\n';
    adapter.json['quests/q1/res/metadata.json'] = {
      '__folders__': ['misc'],
      'bridge.png': {'name': 'Мост в тумане', 'folder': '/'},
      'sound.mp3': {'name': 'Ветер', 'folder': 'misc'},
    };
    service = QuestSearchService(questId: 'q1', adapter: adapter);
  });

  test('пустой запрос ничего не ищет', () async {
    expect(await service.search('   '), isEmpty);
  });

  test('находит ноду по названию и по тексту', () async {
    final byTitle = await service.search('берег');
    expect(byTitle.first.kind, QuestSearchKind.node);
    expect(byTitle.first.id, 'n1');

    final byText = await service.search('доски');
    expect(byText.map((h) => h.id), contains('n2'));
    expect(byText.first.snippet, contains('Доски'));
  });

  test('находит визуальный скрипт по имени и по переменной внутри', () async {
    final hits = await service.search('маяк');
    final script = hits.firstWhere(
      (h) => h.kind == QuestSearchKind.script,
    );
    expect(script.id, 'aaa.json');
    expect(script.title, 'Зажечь маяк');

    final byVariable = await service.search('флаг_моста');
    final hit = byVariable.firstWhere((h) => h.kind == QuestSearchKind.script);
    expect(hit.id, 'aaa.json');
    expect(hit.snippet, 'флаг_моста');
  });

  test('ищет по внутренним скриптам и lua', () async {
    final internal = await service.search('обход');
    expect(internal.single.kind, QuestSearchKind.script);
    expect(internal.single.id, 'bbb.json');

    final lua = await service.search('print');
    expect(lua.single.kind, QuestSearchKind.lua);
    expect(lua.single.id, 'ccc.lua');
    expect(lua.single.snippet, contains('print'));
  });

  test('находит таблицу по строке и переменную по имени', () async {
    final table = await service.search('лампа').then(
      (hits) => hits.firstWhere((h) => h.kind == QuestSearchKind.table),
    );
    expect(table.id, 'склад');

    final variable = (await service.search('золото')).single;
    expect(variable.kind, QuestSearchKind.variable);
    expect(variable.id, 'золото');
  });

  test('находит ресурс по человеческому имени', () async {
    final hit = (await service.search('ветер')).single;
    expect(hit.kind, QuestSearchKind.resource);
    expect(hit.id, 'sound.mp3');
    expect(hit.context, 'misc');
  });
}