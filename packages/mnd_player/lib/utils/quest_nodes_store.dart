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

  /// Записать документ нод в оба места. `QuestStore.transact` в Rust-режиме
  /// атомарен для всего набора; в fallback — последовательно, но каждая
  /// запись сама атомарна.
  static Future<void> write(String questId, Map<String, dynamic> data) async {
    final qs = await QuestStore.defaultInstance();
    await qs.transact([
      QuestOp.writeJson(QuestPaths.nodesLegacy(questId), data),
      QuestOp.writeJson(QuestPaths.nodesCanonical(questId), data),
    ]);
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
