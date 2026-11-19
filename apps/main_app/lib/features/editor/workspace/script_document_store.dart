import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/quest_store.dart';

import '../screens/visual_script_editor/block_models.dart';
import '../screens/visual_script_editor/parser.dart';

/// Прочитанный скрипт: имя, дерево блоков и признак «файла ещё нет».
class ScriptDocument {
  const ScriptDocument({
    required this.name,
    required this.blocks,
    required this.exists,
    this.layout = const {},
  });

  final String name;
  final List<VisualScriptBlock> blocks;

  /// Свободные позиции корневых блоков на канвасе (`id → левый верхний угол`).
  /// Необязательный ключ `layout` файла: классический редактор его не пишет и
  /// не читает, движок квеста — тоже.
  final Map<String, Offset> layout;

  /// `false` — файла на диске не было (новый скрипт). Сохранять такой можно:
  /// это сценарий создания, а не недогруженный редактор.
  final bool exists;

  /// Скрипт-условие: единственный корневой блок — `ConditionBlock`. У него
  /// своя раскладка (условие и две ветки), его нельзя дополнять событиями.
  bool get isConditional =>
      blocks.length == 1 && blocks.first is ConditionBlock;
}

/// Чтение и запись файла скрипта — одна точка на оба редактора.
///
/// Раньше эту логику знал только классический экран. Новый (канвас) правит
/// те же файлы, поэтому формат, поиск пути и запись `metadata.json` обязаны
/// жить в одном месте: иначе два редактора начнут писать разные структуры
/// в один и тот же документ.
class ScriptDocumentStore {
  ScriptDocumentStore({required this.questId, required this.scriptId});

  final String questId;
  final String scriptId;

  Future<QuestStore>? _storeF;
  Future<QuestStore> store() => _storeF ??= QuestStore.create();

  /// Позиции, прочитанные из файла: сохранение без явного `layout`
  /// (классический редактор) не должно стирать расстановку канваса.
  Map<String, Offset> _layout = const {};

  String get fileName => '$scriptId.json';
  String get path => QuestPaths.scriptFile(questId, fileName);
  String get internalPath => QuestPaths.internalScriptFile(questId, fileName);

  /// Найти файл скрипта: публичный каталог, затем внутренний.
  ///
  /// Для только что созданного скрипта файла может ещё не быть — даём записи
  /// догнать и перепроверяем один раз, иначе редактор открывался на пустом
  /// скрипте и автосейв мог затереть уже существующий файл.
  Future<String?> _resolvePath(QuestStore s) async {
    if (await s.exists(path)) return path;
    if (await s.exists(internalPath)) return internalPath;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (await s.exists(path)) return path;
    if (await s.exists(internalPath)) return internalPath;
    return null;
  }

  /// Ключ сериализации операций над файлом скрипта.
  ///
  /// Один и тот же скрипт могут держать ДВА экземпляра редактора: вкладка
  /// воркспейса и экран-маршрут, открытый из модалки/стека, либо вкладка,
  /// пересозданная вытеснением из кэша поверхностей, пока прежний экземпляр
  /// ещё дописывает буфер в `dispose`. Без общего лока «прочитать → показать
  /// → сохранить» новый экземпляр читал диск до записи старого, показывал
  /// устаревшее содержимое и следующим автосейвом затирал свежую правку.
  static String _lockKey(String questId, String scriptId) =>
      'script-file:$questId/$scriptId';

  /// Очередь операций над ОДНИМ файлом скрипта.
  ///
  /// Своя, а не `QuestStore.synchronized`, потому что очередь под этим ключом
  /// обязана пережить сломанную операцию: зависшая запись (или запись,
  /// начатая экраном, который уже снят) не имеет права заблокировать чтение
  /// навсегда — иначе редактор вечно показывает спиннер вместо скрипта.
  static Future<T> _serialize<T>(String key, Future<T> Function() action) {
    final previous = _queue[key] ?? Future<void>.value();
    final started = previous
        .timeout(queueWait, onTimeout: () {})
        .then((_) => action());
    _queue[key] = started.then((_) {}, onError: (Object _) {});
    return started;
  }

  /// Хвост очереди по ключу.
  static final Map<String, Future<void>> _queue = {};

  /// Сброс очередей между тестами.
  ///
  /// Хвост очереди — future из зоны конкретного теста. `testWidgets` создаёт
  /// свою fake-async зону на каждый кейс: запись, начатая экраном предыдущего
  /// кейса, в новой зоне никогда не завершится, и следующий тест уйдёт в
  /// ожидание. В приложении зона одна на процесс, поэтому здесь только шов
  /// для тестов.
  @visibleForTesting
  static void resetQueuesForTest() => _queue.clear();

  /// Сколько ждём предыдущую операцию над файлом. Зависший диск не имеет
  /// права оставить редактор на спиннере навсегда: по истечении срока
  /// очередь идёт дальше (чтение берёт то, что успело лечь).
  static const Duration queueWait = Duration(seconds: 5);

  Future<ScriptDocument> load() =>
      _serialize(_lockKey(questId, scriptId), _read);

  Future<ScriptDocument> _read() async {
    final s = await store();
    final found = await _resolvePath(s);
    if (found == null) {
      return const ScriptDocument(name: '', blocks: [], exists: false);
    }
    final data = await s.readJson(found) ?? <String, dynamic>{};
    final blocksJson = data['blocks'] as List<dynamic>? ?? const [];
    _layout = _readLayout(data['layout']);
    return ScriptDocument(
      name: data['name'] as String? ?? '',
      blocks: ScriptParser.parseBlocks(blocksJson),
      exists: true,
      layout: _layout,
    );
  }

  /// Записать скрипт и обновить `metadata.json` (имя файла в дереве).
  ///
  /// Исключения не глотаем: вызывающий экран показывает их человеку.
  Future<void> save({
    required String name,
    required List<VisualScriptBlock> blocks,
    Map<String, Offset>? layout,
  }) {
    final key = _lockKey(questId, scriptId);
    return _serialize(
      key,
      () => _write(name: name, blocks: blocks, layout: layout),
    );
  }

  Future<void> _write({
    required String name,
    required List<VisualScriptBlock> blocks,
    Map<String, Offset>? layout,
  }) async {
    final s = await store();
    // Существующий файл правим там, где он лежит (включая легаси-каталог);
    // для нового — канонический `scripts/`. Раньше при отсутствии обоих
    // путей новый скрипт создавался в `_internal_scripts`, хотя контракт
    // `QuestPaths` — «новые скрипты туда не пишем»: библиотека ресурсов его
    // не находила, а `metadata.json` оставался с чужим именем.
    final finalPath = await s.exists(path)
        ? path
        : (await s.exists(internalPath) ? internalPath : path);
    final positions = layout ?? _layout;
    await s.writeJson(finalPath, {
      'id': scriptId,
      'name': name,
      'blocks': blocks.map((b) => b.toJson()).toList(),
      if (positions.isNotEmpty)
        'layout': {
          for (final entry in positions.entries)
            entry.key: {'x': entry.value.dx, 'y': entry.value.dy},
        },
    });
    _layout = positions;

    // Имя в дереве библиотеки живёт в `metadata.json` независимо от того,
    // лежит файл в `scripts/` или в легаси-каталоге: пропуск обновления для
    // легаси-скрипта оставлял в дереве старое имя после переименования.
    final metaPath = QuestPaths.metadata(questId);
    if (!await s.exists(metaPath)) return;
    final meta = await s.readJson(metaPath);
    if (meta == null || !meta.containsKey(fileName)) return;
    final folder = (meta[fileName] as Map?)?['folder']?.toString() ?? '/';
    await s.metadataMutate(questId, [
      MetaMut.set(fileName, {'name': name, 'folder': folder}),
    ]);
  }

  /// `layout` из файла: `{id: {x, y}}`. Мусорные записи (старые версии,
  /// ручная правка) пропускаются — расстановка не должна ронять редактор.
  static Map<String, Offset> _readLayout(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, Offset>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final x = value['x'];
      final y = value['y'];
      if (x is num && y is num) {
        out[entry.key.toString()] = Offset(x.toDouble(), y.toDouble());
      }
    }
    return out;
  }

  /// Имена таблиц квеста — для проверки ссылок на таблицы перед выходом.
  /// Ошибка чтения не мешает закрыть документ: пустой набор отключает
  /// проверку, но не блокирует выход.
  Future<Set<String>> tableNames() async {
    try {
      final s = await store();
      final config = await s.readJson(QuestPaths.config(questId));
      final tables = config?['tables'] as List<dynamic>? ?? const [];
      return {
        for (final table in tables)
          if (table is Map && table['name'] != null) table['name'].toString(),
      };
    } catch (_) {
      return const {};
    }
  }
}
