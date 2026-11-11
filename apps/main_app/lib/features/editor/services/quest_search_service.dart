import 'package:mnd_core/utils/quest_paths.dart';

import '../../resources/services/quest_storage.dart';

/// Что нашлось.
enum QuestSearchKind { node, script, lua, table, variable, resource }

/// Один результат поиска по квесту.
///
/// `id` — то, чем результат открывается: id ноды, имя файла скрипта,
/// имя таблицы/переменной. `snippet` — кусок текста, где встретилось
/// совпадение: по нему автор понимает, то ли это место.
class QuestSearchHit {
  const QuestSearchHit({
    required this.kind,
    required this.id,
    required this.title,
    this.context = '',
    this.snippet = '',
  });

  final QuestSearchKind kind;
  final String id;
  final String title;
  final String context;
  final String snippet;
}

/// Поиск по всему квесту: ноды, скрипты (визуальные и Lua), таблицы,
/// переменные, ресурсы.
///
/// Поиск читает диск напрямую, а не провайдеры экрана: канвас грузит только
/// одну главу и сводки нод без содержимого, поэтому по провайдерам искалось бы
/// «где-то рядом», а не везде. Один проход по файлам — это единицы
/// миллисекунд на нормальном квесте, зато результат полный.
class QuestSearchService {
  QuestSearchService({required this.questId, StorageAdapter? adapter})
    : _storage = QuestStorage(questId: questId, adapter: adapter);

  final String questId;
  final QuestStorage _storage;

  /// Сколько результатов показывать в каждой группе.
  static const int limitPerKind = 12;

  Future<List<QuestSearchHit>> search(String rawQuery) async {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return const [];

    final hits = <QuestSearchHit>[];
    await _searchNodes(query, hits);
    await _searchScripts(query, hits);
    await _searchTablesAndVariables(query, hits);
    await _searchResources(query, hits);
    return hits;
  }

  Future<void> _searchNodes(String query, List<QuestSearchHit> hits) async {
    final found = <QuestSearchHit>[];
    for (final raw in await _readNodes()) {
      final node = raw;
      final id = node['id']?.toString() ?? '';
      final title = node['title']?.toString() ?? '';
      if (id.isEmpty) continue;

      if (title.toLowerCase().contains(query)) {
        found.add(
          QuestSearchHit(
            kind: QuestSearchKind.node,
            id: id,
            title: title.isEmpty ? id : title,
            context: 'название ноды',
          ),
        );
        continue;
      }
      final match = _firstStringMatch(node['content'], query);
      if (match != null) {
        found.add(
          QuestSearchHit(
            kind: QuestSearchKind.node,
            id: id,
            title: title.isEmpty ? id : title,
            context: match.$1,
            snippet: match.$2,
          ),
        );
      }
    }
    hits.addAll(found.take(limitPerKind));
  }

  Future<void> _searchScripts(String query, List<QuestSearchHit> hits) async {
    final found = <QuestSearchHit>[];

    // Внутренние скрипты (`_internal_scripts`) — тоже скрипты квеста, но
    // в списке ресурсов их не видно: без второго прохода поиск по ним молчит.
    for (final folder in [
      QuestPaths.scriptsDir(questId),
      QuestPaths.internalScriptsDir(questId),
    ]) {
      final files = await _safeList(folder, '.json');
      for (final file in files) {
        final path = '$folder/$file';
        final data = await _safeReadJson(path);
        if (data.isEmpty) continue;
        final name = (data['name']?.toString().trim().isNotEmpty ?? false)
            ? data['name'].toString().trim()
            : file;
        if (name.toLowerCase().contains(query)) {
          found.add(
            QuestSearchHit(
              kind: QuestSearchKind.script,
              id: file,
              title: name,
              context: folder,
            ),
          );
          continue;
        }
        final match = _firstStringMatch(data['blocks'], query);
        if (match != null) {
          found.add(
            QuestSearchHit(
              kind: QuestSearchKind.script,
              id: file,
              title: name,
              context: match.$1,
              snippet: match.$2,
            ),
          );
        }
      }

      final luaFiles = await _safeList(folder, '.lua');
      for (final file in luaFiles) {
        final text = await _safeReadText('$folder/$file');
        if (text.isEmpty) continue;
        final line = _firstMatchingLine(text, query);
        if (line == null) continue;
        found.add(
          QuestSearchHit(
            kind: QuestSearchKind.lua,
            id: file,
            title: file,
            context: folder,
            snippet: line,
          ),
        );
      }
    }

    hits.addAll(found.take(limitPerKind));
  }

  Future<void> _searchTablesAndVariables(
    String query,
    List<QuestSearchHit> hits,
  ) async {
    final config = await _safeReadJson(QuestPaths.config(questId));

    var variables = 0;
    for (final raw in (config['variables'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final name = raw['name']?.toString() ?? '';
      if (!name.toLowerCase().contains(query)) continue;
      hits.add(
        QuestSearchHit(
          kind: QuestSearchKind.variable,
          id: name,
          title: name,
          context: 'переменная',
          snippet: raw['type']?.toString() ?? '',
        ),
      );
      if (++variables >= limitPerKind) break;
    }

    var tables = 0;
    for (final raw in (config['tables'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final name = raw['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      String? snippet;
      if (name.toLowerCase().contains(query)) {
        snippet = 'название таблицы';
      } else {
        snippet = _firstStringMatch(raw['rows'], query)?.$2;
      }
      if (snippet == null) continue;
      hits.add(
        QuestSearchHit(
          kind: QuestSearchKind.table,
          id: name,
          title: name,
          context: 'таблица',
          snippet: snippet,
        ),
      );
      if (++tables >= limitPerKind) break;
    }
  }

  Future<void> _searchResources(String query, List<QuestSearchHit> hits) async {
    final metadata = await _storage.readMetadata();
    var count = 0;
    for (final entry in metadata.entries) {
      final fileName = entry.key;
      // `__folders__` — служебная запись виртуальных папок.
      if (fileName == QuestStorage.foldersKey) continue;
      final value = entry.value;
      var friendlyName = fileName;
      var folder = '/';
      if (value is String) {
        friendlyName = value;
      } else if (value is Map) {
        friendlyName = (value['name'] ?? fileName).toString();
        folder = (value['folder'] ?? '/').toString();
      }
      if (fileName.endsWith('.json') && friendlyName == fileName) continue;
      final haystack = '$friendlyName $fileName'.toLowerCase();
      if (!haystack.contains(query)) continue;
      hits.add(
        QuestSearchHit(
          kind: QuestSearchKind.resource,
          id: fileName,
          title: friendlyName,
          context: folder,
          snippet: fileName,
        ),
      );
      if (++count >= limitPerKind) break;
    }
  }

  // --- Чтение ---

  /// Все ноды квеста с содержимым.
  ///
  /// v2 хранит ноды отдельными файлами, и индекс содержит только сводки без
  /// `content` — по индексу искались бы одни названия. Поэтому читаем тела;
  /// легаси-монолит поддержан тем же проходом.
  Future<List<Map<String, dynamic>>> _readNodes() async {
    final index = await _safeReadJson(QuestPaths.nodesIndex(questId));
    final entries = (index['nodes'] as List?) ?? const [];
    if (entries.isNotEmpty) {
      final nodes = <Map<String, dynamic>>[];
      for (final raw in entries) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final body = await _safeReadJson(QuestPaths.nodeBody(questId, id));
        nodes.add(body.isEmpty ? Map<String, dynamic>.from(raw) : body);
      }
      if (nodes.isNotEmpty) return nodes;
    }

    for (final path in [
      QuestPaths.nodesLegacy(questId),
      QuestPaths.nodesCanonical(questId),
    ]) {
      final document = await _safeReadJson(path);
      final nodes = (document['nodes'] as List?) ?? const [];
      if (nodes.isEmpty) continue;
      return nodes
          .whereType<Map>()
          .map((raw) => Map<String, dynamic>.from(raw))
          .toList(growable: false);
    }
    return const [];
  }

  Future<List<String>> _safeList(String folder, String extension) async {
    if (folder.isEmpty) return const [];
    try {
      // Каталога может не быть вовсе — листинг вернёт пусто, отдельная
      // проверка существования тут ничего не добавляет.
      return await _storage.listFiles(folder, extension: extension);
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>> _safeReadJson(String path) async {
    try {
      if (!await _storage.exists(path)) return const {};
      return await _storage.readJson(path);
    } catch (_) {
      return const {};
    }
  }

  Future<String> _safeReadText(String path) async {
    try {
      return await _storage.readText(path);
    } catch (_) {
      return '';
    }
  }

  // --- Сопоставление ---

  /// Первая строка JSON со значением, содержащим запрос.
  ///
  /// Возвращает (метка поля, значение): метка нужна, чтобы результат
  /// «переменная gold» не путался с «переменная score».
  (String, String)? _firstStringMatch(dynamic value, String query) {
    (String, String)? result;
    _walk(value, '', (label, text) {
      if (result != null) return;
      if (text.toLowerCase().contains(query)) {
        result = (label, text);
      }
    });
    return result;
  }

  void _walk(
    dynamic value,
    String label,
    void Function(String label, String text) visit,
  ) {
    if (value is String) {
      visit(label, value);
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        _walk(entry.value, _joinLabel(label, key), visit);
      }
      return;
    }
    if (value is List) {
      for (var i = 0; i < value.length; i++) {
        _walk(value[i], label, visit);
      }
    }
  }

  static String _joinLabel(String label, String key) {
    switch (key) {
      case 'text':
      case 'variable':
      case 'path':
      case 'value':
      case 'url':
      case 'comment':
      case 'name':
      case 'title':
        return label.isEmpty ? key : '$label → $key';
      default:
        return label;
    }
  }

  String? _firstMatchingLine(String text, String query) {
    for (final line in text.split('\n')) {
      if (line.toLowerCase().contains(query)) return line.trim();
    }
    return null;
  }
}