/// Единая точка записей в `quests/<id>/…` (план 020-C).
///
/// Бэкенд: Rust-ядро (`FsQuestStore` через FFI) — атомарные записи,
/// per-path локи, многофайловые транзакции. Fallback на [FileStorage]
/// (когда мост не инициализирован) — ТОЛЬКО для unit-тестов без `.so`:
/// в продакшене мост всегда доступен. Транзакция в fallback выполняется
/// последовательно (слабая гарантия — задокументировано).
library;

import 'dart:convert';

import 'package:mnd_core/src/gen/api/quest_store.dart' as gen;

import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_core/utils/quest_paths.dart';

class QuestStoreException implements Exception {
  final String code;
  final String message;

  QuestStoreException(this.code, this.message);

  @override
  String toString() => 'QuestStoreException($code): $message';
}

/// Операция транзакции.
class QuestOp {
  final String op; // write_json | write_text | remove
  final String path;
  final Map<String, dynamic>? value;
  final String? text;

  const QuestOp.writeJson(this.path, this.value)
    : op = 'write_json',
      text = null;
  const QuestOp.writeText(this.path, this.text)
    : op = 'write_text',
      value = null;
  const QuestOp.remove(this.path) : op = 'remove', value = null, text = null;

  Map<String, dynamic> toJson() => switch (op) {
    'write_json' => {'op': op, 'path': path, 'value': value},
    'write_text' => {'op': op, 'path': path, 'text': text},
    _ => {'op': op, 'path': path},
  };
}

/// Мутация metadata.json.
class MetaMut {
  final bool isRemove;
  final String key; // литеральное имя файла ("abc.json")
  final Map<String, dynamic>? value;

  const MetaMut.set(this.key, this.value) : isRemove = false;
  const MetaMut.remove(this.key) : isRemove = true, value = null;

  Map<String, dynamic> toJson() => isRemove
      ? {'op': 'remove', 'key': key}
      : {'op': 'set', 'key': key, 'value': value};
}

class QuestStore {
  /// Корень документов приложения.
  final String root;

  /// false = мост недоступен, работаем через FileStorage.
  final bool rustBackend;

  const QuestStore._(this.root, this.rustBackend);

  static final Map<String, Future<void>> _sectionLocks = {};

  /// Секционный лок приложения (read-modify-write из нескольких вызовов).
  /// Ядро атомарит одиночные записи; это сериализует СЕКЦИИ на Dart-стороне
  /// (паритет FileStorage.synchronized).
  static Future<T> synchronized<T>(String key, Future<T> Function() action) {
    final previous = _sectionLocks.remove(key) ?? Future<void>.value();
    final task = previous.then((_) => action());
    _sectionLocks[key] = task.then((_) {}, onError: (Object _) {});
    return task;
  }

  static bool? _rustProbeResult;

  /// Фабрика по умолчанию: корень из FileStorage + автодетект бэкенда.
  static Future<QuestStore> create() async {
    final dir = await FileStorage.getAppDirectory();
    return forRoot(dir.path);
  }

  static Future<QuestStore>? _defaultInstance;

  /// Кэшированный инстанс для горячих путей (провайдеры/экраны).
  static Future<QuestStore> defaultInstance() => _defaultInstance ??= create();

  static Future<QuestStore> forRoot(String root) async {
    final rust = await _probeRust();
    return QuestStore._(root, rust);
  }

  static Future<bool> _probeRust() async {
    if (_rustProbeResult != null) return _rustProbeResult!;
    try {
      // Дешёвый sync-вызов: уходит в ядро только если мост инициализирован.
      gen.questStoreExists(root: '__probe__', relPath: 'x');
      _rustProbeResult = true;
    } catch (_) {
      _rustProbeResult = false;
    }
    return _rustProbeResult!;
  }

  // ── Чтение ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> readJson(String relPath) async {
    if (rustBackend) {
      final raw = await gen.questStoreReadJson(root: root, relPath: relPath);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    }
    if (!await FileStorage.exists(relPath)) return null;
    return FileStorage.readJsonFile(relPath);
  }

  Future<String?> readText(String relPath) async {
    if (rustBackend) {
      return gen.questStoreReadText(root: root, relPath: relPath);
    }
    if (!await FileStorage.exists(relPath)) return null;
    try {
      return await FileStorage.readTextFile(relPath);
    } catch (_) {
      return null;
    }
  }

  Future<bool> exists(String relPath) async {
    if (rustBackend) {
      return gen.questStoreExists(root: root, relPath: relPath);
    }
    return FileStorage.exists(relPath);
  }

  Future<List<String>> listFiles(String relDir, {String? extension}) async {
    if (rustBackend) {
      return gen.questStoreListFiles(
        root: root,
        relDir: relDir,
        extension_: extension,
      );
    }
    return FileStorage.listFiles(relDir, extension: extension);
  }

  /// Массовый снимок каталога одним вызовом ядра: JSON-массив
  /// `[{file,size,mtimeMs,name,blocks}]` или `null`, если моста нет
  /// (тогда вызывающий идёт пофайлово через [FileStorage]).
  Future<String?> scanFiles(
    String relDir, {
    String? extension,
    bool parseJson = false,
  }) async {
    if (!rustBackend) return null;
    return gen.questStoreScanFiles(
      root: root,
      relDir: relDir,
      extension_: extension,
      parseJson: parseJson,
    );
  }

  // ── Запись ─────────────────────────────────────────────────────────────

  Future<void> writeJson(String relPath, Map<String, dynamic> data) async {
    if (rustBackend) {
      await _unwrap(
        gen.questStoreWriteJson(
          root: root,
          relPath: relPath,
          json: jsonEncode(data),
        ),
      );
      FileStorage.invalidateJsonCache([relPath]);
      return;
    }
    await FileStorage.writeJsonFile(relPath, data);
  }

  Future<void> writeText(String relPath, String text) async {
    if (rustBackend) {
      await _unwrap(
        gen.questStoreWriteText(root: root, relPath: relPath, text: text),
      );
      return;
    }
    await FileStorage.writeTextFile(relPath, text);
  }

  Future<void> delete(String relPath) async {
    if (rustBackend) {
      await _unwrap(gen.questStoreDelete(root: root, relPath: relPath));
      FileStorage.invalidateJsonCache([relPath]);
      return;
    }
    await FileStorage.delete(relPath);
  }

  /// Многофайловая транзакция. В fallback-режиме выполняется
  /// последовательно (без all-or-nothing гарантии ядра).
  Future<void> transact(List<QuestOp> ops) async {
    if (rustBackend) {
      await _unwrap(
        gen.questStoreTransact(
          root: root,
          opsJson: jsonEncode([for (final op in ops) op.toJson()]),
        ),
      );
      // Ядро записало файлы мимо FileStorage — его кэш обязан устареть,
      // иначе редактор вернёт снимок до переименования и затирает правку.
      FileStorage.invalidateJsonCache([for (final op in ops) op.path]);
      return;
    }
    for (final op in ops) {
      switch (op.op) {
        case 'write_json':
          await FileStorage.writeJsonFile(op.path, op.value ?? {});
        case 'write_text':
          await FileStorage.writeTextFile(op.path, op.text ?? '');
        case 'remove':
          await FileStorage.delete(op.path);
      }
    }
  }

  /// Атомарный read-modify-write metadata.json квеста.
  Future<void> metadataMutate(String questId, List<MetaMut> mutations) async {
    if (rustBackend) {
      await _unwrap(
        gen.questStoreMetadataMutate(
          root: root,
          questId: questId,
          mutationsJson: jsonEncode([for (final m in mutations) m.toJson()]),
        ),
      );
      FileStorage.invalidateJsonCache([QuestPaths.metadata(questId)]);
      return;
    }
    // Fallback: RMW под пер-путевым локом FileStorage (writeJsonFile).
    final rel = QuestPaths.metadata(questId);
    final meta = await readJson(rel) ?? <String, dynamic>{};
    for (final m in mutations) {
      if (m.isRemove) {
        meta.remove(m.key);
      } else {
        meta[m.key] = m.value ?? <String, dynamic>{};
      }
    }
    await FileStorage.writeJsonFile(rel, meta);
  }

  // ── Внутреннее ─────────────────────────────────────────────────────────

  Future<void> _unwrap(Future<String> resultFuture) async {
    final raw = await resultFuture;
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['ok'] == true) return;
    throw QuestStoreException(
      decoded?['error']?.toString() ?? 'unknown',
      decoded?['message']?.toString() ?? 'unknown error',
    );
  }
}
