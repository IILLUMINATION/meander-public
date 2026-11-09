/// Загрузка квеста в браузер: один HTTP-запрос → распаковка `.mnd` → данные,
/// которые движок умеет есть из памяти.
///
/// `.mnd` = 8-байт магия + zip (`MND_ZIP_` — открытый) или голый zip, как в
/// каталоге маркета; `MND_SEC_`/`MND_ENC2` — шифрованные, их веб-плеер не
/// открывает. Внутри — ровно та же раскладка, что у каталога квеста на диске:
/// `config.json`, `nodes.json`, `res/templates.json`, `scripts/<uuid>.json`,
/// `res/images|audio|fonts|...`.
///
/// Движку не нужны байты ресурсов: он просит только JSON (ноды, шаблоны,
/// скрипты по `resourcePath`), а картинки и звук читает клиент — поэтому
/// скрипты уходят в `embeddedScripts`, а ресурсы остаются здесь.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:mnd_core/engine/quest_resource_index.dart';

import 'quest_source.dart';

/// Квест целиком в памяти браузера.
class QuestBundle extends QuestAssets {
  QuestBundle({
    required this.questId,
    required this.config,
    required this.nodesJson,
    required this.templates,
    required this.embeddedScripts,
    required this.assets,
    QuestResourceIndex? resourceIndex,
  }) : _index = resourceIndex ?? QuestResourceIndex.empty();

  @override
  final String questId;
  @override
  final Map<String, dynamic> config;

  /// Сырой `nodes.json` — движок сам вытаскивает поле `nodes`.
  @override
  final Map<String, dynamic> nodesJson;
  @override
  final List<dynamic> templates;

  /// `scripts/<uuid>.json` → JSON-строка (то, что читает движок с диска).
  @override
  final Map<String, String> embeddedScripts;

  /// Относительный путь внутри архива → байты (ресурсы: картинки, звук, шрифты).
  @override
  final Map<String, Uint8List> assets;

  /// Индекс `res/metadata.json`: имя/uuid ресурса → файлы.
  final QuestResourceIndex _index;

  String get title => config['title'] as String? ?? questId;
  String get author => config['author'] as String? ?? '';
  String? get startNodeId => config['startNodeId'] as String?;

  /// Пути-кандидаты записи для «источника», который написал автор квеста: путь
  /// в каталоге (`res/images/<uuid>.png`), имя из библиотеки («закат») или
  /// uuid. Тот же порядок кандидатов, что у нативного `QuestImageSource.resolve`
  /// — иначе квест показывал бы в браузере другую картинку, чем в приложении.
  ///
  /// Существование кандидата проверяет вызывающий: у потокового источника
  /// файла в памяти ещё нет, но путь уже известен.
  List<String> assetPathCandidates(String? source) {
    final trimmed = _withoutSlips(source ?? '');
    if (trimmed.isEmpty) return const [];
    final direct = directResourceCandidates(trimmed);
    if (direct.isNotEmpty) return direct;
    // Путь есть, но файла нет — библиотека тут не поможет.
    if (trimmed.contains('/')) return const [];
    return _index.pathCandidates(trimmed);
  }

  @override
  Uint8List? assetBytes(String? source) {
    for (final candidate in assetPathCandidates(source)) {
      final bytes = assets[candidate];
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Нормализация источника: обратные слеши, ведущий `/`, префикс
  /// `quests/<id>/` — часть мест хранит путь относительно корня документов.
  static String _withoutSlips(String source) {
    var path = source.trim().replaceAll('\\', '/');
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    var changed = true;
    while (changed) {
      changed = false;
      if (path.startsWith('./')) {
        path = path.substring(2);
        changed = true;
      }
    }
    return path;
  }

  @override
  bool get hasScripts => embeddedScripts.isNotEmpty;

  /// Пути шрифтов квеста (`res/fonts/…`) — их клиент регистрирует своим
  /// `FontLoader` под теми же family-именами, что у нативного `FontService`.
  @override
  List<String> get fontPaths =>
      assets.keys.where((path) => path.startsWith('res/fonts/')).toList()..sort();
}

class QuestLoadException implements Exception {
  final String message;
  const QuestLoadException(this.message);
  @override
  String toString() => message;
}

/// Открыть `.mnd` по URL (та же схема, что у загрузки из маркета).
Future<QuestBundle> loadQuestBundle(String url, {http.Client? client}) async {
  final parsed = Uri.parse(url);
  final response =
      client == null ? await http.get(parsed) : await client.get(parsed);
  if (response.statusCode != 200) {
    throw QuestLoadException(
      'Квест не скачался: HTTP ${response.statusCode} ($url)',
    );
  }
  return decodeMnd(response.bodyBytes, url);
}

/// Разобрать архив по байтам. Вынесено из сети, чтобы это можно было тестировать.
QuestBundle decodeMnd(Uint8List bytes, String origin) {
  if (bytes.length < 8) {
    throw const QuestLoadException('Файл слишком маленький, чтобы быть архивом квеста');
  }
  final magic = String.fromCharCodes(bytes.sublist(0, 8));

  // Два формата, как в нативном импорте (`import_service.dart`): свойство с
  // магией `MND_ZIP_` и голый zip — именно так лежат архивы каталога на проде.
  final Uint8List zipBytes;
  if (magic == 'MND_ZIP_') {
    zipBytes = bytes.sublist(8);
  } else if (magic.startsWith('PK')) {
    zipBytes = bytes;
  } else {
    throw QuestLoadException(
      'Веб-плеер открывает незащищённые архивы (`MND_ZIP_` или zip), '
      'а тут «$magic» — квест защищён паролем.',
    );
  }

  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (e) {
    throw QuestLoadException('Не удалось распаковать архив квеста: $e');
  }

  final files = <String, Uint8List>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final raw = entry.readBytes();
    if (raw == null) continue;
    files[entry.name.replaceAll(r'\', '/')] = raw;
  }

  Map<String, dynamic> readJson(String path) {
    final bytes = files[path];
    if (bytes == null) return const {};
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  Map<String, dynamic>? readMetadata() {
    final bytes = files['res/metadata.json'];
    if (bytes == null) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  final config = readJson('config.json');
  if (config.isEmpty) {
    throw const QuestLoadException('В архиве нет config.json — это не квест Meander.');
  }
  final nodes = readJson('nodes.json');

  // Нативный `load_json_array` понимает и голый массив, и `{templates: […]}` —
  // редактор пишет вторую форму. Без этого узла браузер получал пустой список,
  // и все инстансы шаблонов (в квесте «Против воли богов» — 104 ноды из 124)
  // разворачивались заглушками: ни текста, ни триггеров, мёртвые нажатия.
  final templatesBytes = files['res/templates.json'];
  List<dynamic> templates = const [];
  if (templatesBytes != null) {
    final decoded = jsonDecode(utf8.decode(templatesBytes));
    if (decoded is List) {
      templates = decoded;
    } else if (decoded is Map) {
      final nested = decoded['templates'];
      if (nested is List) templates = nested;
    }
  }

  final scripts = <String, String>{};
  final assets = <String, Uint8List>{};
  for (final entry in files.entries) {
    final path = entry.key;
    if (path.startsWith('scripts/') || path.startsWith('_internal_scripts/')) {
      scripts[path] = utf8.decode(entry.value, allowMalformed: true);
      continue;
    }
    if (path == 'config.json' || path == 'nodes.json' || path == 'editor_session.json') {
      continue;
    }
    assets[path] = entry.value;
  }

  final questId = config['id'] as String? ?? Uri.parse(origin).pathSegments
      .where((s) => s.endsWith('.mnd'))
      .map((s) => s.substring(0, s.length - 4))
      .firstOrNull;

  return QuestBundle(
    questId: questId ?? 'web',
    config: config,
    nodesJson: nodes,
    templates: templates,
    embeddedScripts: scripts,
    assets: assets,
    resourceIndex: QuestResourceIndex.fromMetadata(readMetadata()),
  );
}
