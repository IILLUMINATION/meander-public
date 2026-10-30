import 'dart:convert';
import 'dart:io';

import 'package:mnd_core/utils/quest_paths.dart';

import 'file_storage.dart';
import 'quest_store.dart';

/// Единая точка чтения/записи `nodes.json`.
///
/// Исторически файл нод лежит в двух местах: канонический
/// `nodes/nodes.json` (импорт/движок) и legacy `nodes.json` (редактор).
/// Редактор писал только legacy, движок читал канонический первым — правки
/// могли не доходить до игры, а пустой legacy после сбоя затирал главу.
///
/// Теперь: читаем оба, выбираем непустой (канонический приоритетнее),
/// расхождение лечим записью в оба места; пишем всегда в оба одной
/// транзакцией. Запись атомарная: `QuestStore` делает temp+verify+rename.
class QuestNodesStore {
  QuestNodesStore._();

  static Future<Map<String, dynamic>> read(String questId) async {
    final qs = await QuestStore.defaultInstance();
    if (await qs.exists(QuestPaths.nodesIndex(questId))) {
      return readAll(questId);
    }
    return _readMonolith(questId);
  }

  static Future<Map<String, dynamic>> _readMonolith(String questId) async {
    final qs = await QuestStore.defaultInstance();
    final legacy = QuestPaths.nodesLegacy(questId);
    final canonical = QuestPaths.nodesCanonical(questId);

    final legacyText = await _readText(qs, legacy);
    final canonicalText = await _readText(qs, canonical);

    // Обе копии синхронизированы байт-в-байт — это штатное состояние после
    // записи. Парсим только одну: на большом nodes.json второй jsonDecode
    // стоит ещё ~15 мс.
    if (legacyText != null &&
        canonicalText != null &&
        legacyText == canonicalText) {
      return _decode(canonicalText) ?? <String, dynamic>{};
    }

    final legacyData = _decode(legacyText);
    final canonicalData = _decode(canonicalText);

    final canonicalHasData = _hasNodes(canonicalData);
    final legacyHasData = _hasNodes(legacyData);

    Map<String, dynamic> chosen;
    var chosenFromLegacy = false;
    if (canonicalHasData && !legacyHasData) {
      chosen = canonicalData!;
    } else if (legacyHasData && !canonicalHasData) {
      chosen = legacyData!;
      chosenFromLegacy = true;
    } else if (canonicalHasData && legacyHasData) {
      // Обе копии непустые: при расхождении доверяем более свежей по mtime.
      // Иначе старый импорт в canonical затирал бы правки редактора в legacy.
      final canonicalTime = await _mtime(canonical);
      final legacyTime = await _mtime(legacy);
      final useLegacy =
          legacyTime != null &&
          (canonicalTime == null || legacyTime.isAfter(canonicalTime));
      chosen = useLegacy ? legacyData! : canonicalData!;
      chosenFromLegacy = useLegacy;
    } else {
      chosen = canonicalData ?? legacyData ?? <String, dynamic>{};
    }

    // Лечим расхождение/отсутствие копии, но не создаём файлы для пустого
    // квеста и не перезаписываем уже синхронизированное.
    if (chosen.isNotEmpty) {
      if (chosenFromLegacy) {
        if (canonicalText == null || canonicalText != legacyText) {
          await qs.writeJson(canonical, chosen);
        }
      } else if (legacyText == null || legacyText != canonicalText) {
        await qs.writeJson(legacy, chosen);
      }
    }
    return chosen;
  }

  static Future<String?> _readText(QuestStore qs, String relPath) async {
    try {
      return await qs.readText(relPath);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _decode(String? text) {
    if (text == null) return null;
    if (text.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return <String, dynamic>{};
    } catch (_) {
      return null;
    }
  }

  /// Версия per-node формата. Монолит без индекса — версия 1.
  static const int perNodeFormatVersion = 2;

  /// Ключ версии в `nodes/index.json`.
  static const String formatVersionKey = 'format_version';

  /// Есть ли у квеста per-node индекс.
  static Future<bool> hasPerNodeIndex(String questId) async {
    final qs = await QuestStore.defaultInstance();
    return qs.exists(QuestPaths.nodesIndex(questId));
  }

  /// Лёгкий индекс для канваса: метаданные нод без `content`, группы,
  /// комментарии и рёбра.
  ///
  /// Если индекса нет, строит его в памяти из монолита, но ничего не пишет:
  /// миграция — отдельное явное действие [migrateToPerNode].
  static Future<Map<String, dynamic>> readIndex(String questId) async {
    final qs = await QuestStore.defaultInstance();
    final indexPath = QuestPaths.nodesIndex(questId);
    if (await qs.exists(indexPath)) {
      try {
        final data = await qs.readJson(indexPath);
        if (data != null && data.isNotEmpty) return data;
      } catch (_) {}
    }
    return buildIndex(await _readMonolith(questId));
  }

  /// Тело одной ноды. В per-node формате — отдельный файл; в legacy —
  /// поиск по полному документу.
  static Future<Map<String, dynamic>?> readNode(
    String questId,
    String nodeId,
  ) async {
    final qs = await QuestStore.defaultInstance();
    if (await qs.exists(QuestPaths.nodesIndex(questId))) {
      final bodyPath = QuestPaths.nodeBody(questId, nodeId);
      if (await qs.exists(bodyPath)) {
        try {
          final body = await qs.readJson(bodyPath);
          if (body != null) return body;
        } catch (_) {}
      }
    }
    return _findNode(await _readMonolith(questId), nodeId);
  }

  /// Собрать полный документ из индекса и тел нод.
  ///
  /// Нужен старым потребителям (игра, экспорт, поиск). Редактору канваса
  /// следует использовать [readIndex], а редактору ноды — [readNode].
  static Future<Map<String, dynamic>> readAll(String questId) async {
    final qs = await QuestStore.defaultInstance();
    if (!await qs.exists(QuestPaths.nodesIndex(questId))) {
      return _readMonolith(questId);
    }

    final index = await readIndex(questId);
    final entries = (index['nodes'] as List<dynamic>? ?? []);
    final nodes = <Map<String, dynamic>>[];
    final missingIds = <String>[];

    for (final raw in entries) {
      if (raw is! Map) continue;
      final summary = Map<String, dynamic>.from(raw);
      final id = summary['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final body = await _readNodeBody(qs, questId, id);
      if (body != null) {
        nodes.add(body);
      } else {
        nodes.add(summary);
        missingIds.add(id);
      }
    }

    if (missingIds.isNotEmpty) {
      // Частичная миграция/повреждение: недостающие тела ищем в монолите.
      final legacy = await _readMonolith(questId);
      final legacyById = <String, Map<String, dynamic>>{};
      for (final raw in (legacy['nodes'] as List<dynamic>? ?? [])) {
        if (raw is! Map) continue;
        final node = Map<String, dynamic>.from(raw);
        final id = node['id']?.toString();
        if (id != null && id.isNotEmpty) legacyById[id] = node;
      }
      for (var i = 0; i < nodes.length; i++) {
        final id = nodes[i]['id']?.toString();
        final fallback = id == null ? null : legacyById[id];
        if (fallback != null) nodes[i] = fallback;
      }
    }

    return {
      'nodes': nodes,
      'groups': index['groups'] ?? <dynamic>[],
      'comments': index['comments'] ?? <dynamic>[],
    };
  }

  /// Перевести монолит в `nodes/index.json` + `nodes/<id>.json`.
  ///
  /// Старые `nodes.json` и `nodes/nodes.json` не удаляются: это и бэкап,
  /// и совместимость со старыми клиентами. Индекс пишется последним, чтобы
  /// оборванная миграция не оставила квест без читаемых данных.
  static Future<bool> migrateToPerNode(String questId) async {
    final qs = await QuestStore.defaultInstance();
    if (await qs.exists(QuestPaths.nodesIndex(questId))) return false;

    final data = await _readMonolith(questId);
    if (data.isEmpty) return false;

    final index = buildIndex(data);
    await qs.writeJson(QuestPaths.nodesMigrationBackup(questId), data);

    for (final raw in (data['nodes'] as List<dynamic>? ?? [])) {
      if (raw is! Map) continue;
      final node = Map<String, dynamic>.from(raw);
      final id = node['id']?.toString();
      if (id == null || id.isEmpty) continue;
      await qs.writeJson(QuestPaths.nodeBody(questId, id), node);
    }

    await qs.writeJson(QuestPaths.nodesIndex(questId), index);
    return true;
  }

  /// Записать одну ноду и обновить её запись/рёбра в индексе.
  ///
  /// Полный legacy-монолит здесь не переписывается: это и есть смысл
  /// per-node сохранения. Синхронизацию монолита делает отдельный шаг
  /// (экспорт/облако/явное сохранение).
  static Future<void> writeNode(
    String questId,
    Map<String, dynamic> node,
  ) async {
    final id = node['id']?.toString();
    if (id == null || id.isEmpty) {
      throw ArgumentError('У ноды нет id');
    }

    final qs = await QuestStore.defaultInstance();
    if (!await qs.exists(QuestPaths.nodesIndex(questId))) {
      await migrateToPerNode(questId);
    }

    final index = await readIndex(questId);
    final summaries = (index['nodes'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final summary = buildNodeSummary(node);
    final existing = summaries.indexWhere((e) => e['id'] == id);
    if (existing == -1) {
      summaries.add(summary);
    } else {
      summaries[existing] = summary;
    }

    final edges =
        (index['edges'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => e['from']?.toString() != id)
            .toList()
          ..addAll(_edgesForNode(node));

    final nextIndex = <String, dynamic>{
      ...index,
      formatVersionKey: perNodeFormatVersion,
      'nodes': summaries,
      'edges': _dedupeEdges(edges),
    };

    await qs.writeJson(QuestPaths.nodeBody(questId, id), node);
    await qs.writeJson(QuestPaths.nodesIndex(questId), nextIndex);
  }

  /// Удалить ноду из индекса и её тело с диска.
  static Future<void> deleteNode(String questId, String nodeId) async {
    final qs = await QuestStore.defaultInstance();
    final bodyPath = QuestPaths.nodeBody(questId, nodeId);
    if (await qs.exists(bodyPath)) {
      await qs.delete(bodyPath);
    }
    if (!await qs.exists(QuestPaths.nodesIndex(questId))) return;

    final index = await readIndex(questId);
    final summaries = (index['nodes'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => e['id']?.toString() != nodeId)
        .toList();
    final edges = (index['edges'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where(
          (e) =>
              e['from']?.toString() != nodeId && e['to']?.toString() != nodeId,
        )
        .toList();

    await qs.writeJson(QuestPaths.nodesIndex(questId), {
      ...index,
      formatVersionKey: perNodeFormatVersion,
      'nodes': summaries,
      'edges': _dedupeEdges(edges),
    });
  }

  /// Индекс из полного документа. `content` в индекс не попадает — это
  /// тяжёлая часть, которая лежит в теле ноды.
  static Map<String, dynamic> buildIndex(Map<String, dynamic> data) {
    final summaries = <Map<String, dynamic>>[];
    final edges = <Map<String, dynamic>>[];
    for (final raw in (data['nodes'] as List<dynamic>? ?? [])) {
      if (raw is! Map) continue;
      final node = Map<String, dynamic>.from(raw);
      final id = node['id']?.toString();
      if (id == null || id.isEmpty) continue;
      summaries.add(buildNodeSummary(node));
      edges.addAll(_edgesForNode(node));
    }
    return {
      formatVersionKey: perNodeFormatVersion,
      'nodes': summaries,
      'groups': data['groups'] ?? <dynamic>[],
      'comments': data['comments'] ?? <dynamic>[],
      'edges': _dedupeEdges(edges),
    };
  }

  /// Метаданные ноды для канваса: всё, кроме содержимого реплик.
  static Map<String, dynamic> buildNodeSummary(Map<String, dynamic> node) {
    final summary = <String, dynamic>{};
    for (final entry in node.entries) {
      if (entry.key == 'content') continue;
      summary[entry.key] = entry.value;
    }
    summary.putIfAbsent('type', () => 'node');
    return summary;
  }

  static Future<Map<String, dynamic>?> _readNodeBody(
    QuestStore qs,
    String questId,
    String nodeId,
  ) async {
    final path = QuestPaths.nodeBody(questId, nodeId);
    if (!await qs.exists(path)) return null;
    try {
      return await qs.readJson(path);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _findNode(
    Map<String, dynamic> data,
    String nodeId,
  ) {
    for (final raw in (data['nodes'] as List<dynamic>? ?? [])) {
      if (raw is! Map) continue;
      if (raw['id']?.toString() == nodeId) {
        return Map<String, dynamic>.from(raw);
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> _edgesForNode(Map<String, dynamic> node) {
    final from = node['id']?.toString();
    if (from == null || from.isEmpty) return const [];

    final edges = <Map<String, dynamic>>[];
    void add(String? to, String kind) {
      if (to == null) return;
      final target = to.trim();
      if (target.isEmpty || target.startsWith('=') || target == from) return;
      edges.add({'from': from, 'to': target, 'kind': kind});
    }

    add(node['defaultActionNodeId']?.toString(), 'timer');
    _walkContentForEdges(node['content'], add);
    return edges;
  }

  static void _walkContentForEdges(
    dynamic content,
    void Function(String? to, String kind) add,
  ) {
    if (content is! Map) return;
    final items = content['items'];
    if (items is! List) return;

    void walk(dynamic raw) {
      if (raw is! Map) return;
      add(raw['targetNodeId']?.toString(), 'content');
      final children = raw['children'];
      if (children is List) {
        for (final child in children) {
          walk(child);
        }
      }
    }

    for (final item in items) {
      walk(item);
    }
  }

  static List<Map<String, dynamic>> _dedupeEdges(
    List<Map<String, dynamic>> edges,
  ) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final edge in edges) {
      final key = '${edge['from']}|${edge['to']}|${edge['kind'] ?? 'content'}';
      if (!seen.add(key)) continue;
      result.add(edge);
    }
    return result;
  }

  /// Записать документ нод в оба места. `QuestStore.transact` в Rust-режиме
  /// атомарен для всего набора; в fallback — последовательно, но каждая
  /// запись сама атомарна.
  static Future<void> write(String questId, Map<String, dynamic> data) async {
    final qs = await QuestStore.defaultInstance();
    await qs.transact([
      QuestOp.writeJson(QuestPaths.nodesLegacy(questId), data),
      QuestOp.writeJson(QuestPaths.nodesCanonical(questId), data),
    ]);
    // Если квест уже переведён на per-node, монолит не должен становиться
    // вторым источником правды: иначе следующий read увидит старый индекс.
    if (await qs.exists(QuestPaths.nodesIndex(questId))) {
      await _writePerNodeSnapshot(qs, questId, data);
    }
  }

  static Future<void> _writePerNodeSnapshot(
    QuestStore qs,
    String questId,
    Map<String, dynamic> data,
  ) async {
    final nodes = <Map<String, dynamic>>[];
    final ids = <String>{};
    for (final raw in (data['nodes'] as List<dynamic>? ?? [])) {
      if (raw is! Map) continue;
      final node = Map<String, dynamic>.from(raw);
      final id = node['id']?.toString();
      if (id == null || id.isEmpty) continue;
      ids.add(id);
      nodes.add(node);
      await qs.writeJson(QuestPaths.nodeBody(questId, id), node);
    }

    // Удаляем тела нод, которых больше нет в документе.
    try {
      for (final name in await qs.listFiles(
        QuestPaths.nodesDir(questId),
        extension: '.json',
      )) {
        if (name == 'index.json' || name == 'nodes.json') continue;
        if (name.endsWith('.json')) {
          final id = name.substring(0, name.length - 5);
          if (!ids.contains(id)) {
            await qs.delete(QuestPaths.nodeBody(questId, id));
          }
        }
      }
    } catch (_) {}

    await qs.writeJson(QuestPaths.nodesIndex(questId), buildIndex(data));
  }

  static Future<DateTime?> _mtime(String relPath) async {
    try {
      final file = File(await FileStorage.getFilePath(relPath));
      if (!await file.exists()) return null;
      return (await file.stat()).modified;
    } catch (_) {
      return null;
    }
  }

  static bool _hasNodes(Map<String, dynamic>? data) {
    if (data == null) return false;
    final nodes = data['nodes'];
    final groups = data['groups'];
    final comments = data['comments'];
    return (nodes is List && nodes.isNotEmpty) ||
        (groups is List && groups.isNotEmpty) ||
        (comments is List && comments.isNotEmpty);
  }
}
