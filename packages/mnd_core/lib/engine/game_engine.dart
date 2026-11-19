/// Dart-обёртка над Rust `GameEngine` (FFI).
///
/// Инкапсулирует оркестрацию геймлупа: клиент создаёт движок, передав
/// сырые JSON квеста (config/nodes/templates/scripts), и дальше гонит
/// `loadNode` / `nextItem` / `handleInteraction`. Результаты — JSON-строки,
/// которые парсятся Dart-моделями.
///
/// Движок адресуется целочисленным handle (реестр в Rust), а не opaque-типом:
/// это обходит нестабильную доставку async-результатов для opaque `&mut` в
/// FRB 2.12.0 (зависание UI). Лёгкие методы синхронны, тяжёлые — async.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:mnd_core/src/gen/api/game_engine.dart' as gen;

/// Маркеры ошибок, возвращаемые Rust-слоем при поломке/отсутствии движка.
const String _kPoisonedMarker = '{"error":"engine_poisoned"}';
const String _kNotFoundMarker = '{"error":"engine_not_found"}';

/// Движок отравлен паникой другого вызова и непригоден к работе.
class GameEnginePoisonedException implements Exception {
  final String method;

  const GameEnginePoisonedException(this.method);

  @override
  String toString() =>
      'GameEnginePoisonedException: engine state poisoned after a Rust panic '
      '(method: $method)';
}

/// Handle не найден в реестре (движок уже dispose или не был создан).
class GameEngineHandleNotFoundError implements Exception {
  final String method;

  const GameEngineHandleNotFoundError(this.method);

  @override
  String toString() =>
      'GameEngineHandleNotFoundError: engine handle is not registered '
      '(method: $method)';
}

void _throwIfEngineError(String raw, String method) {
  if (raw == _kPoisonedMarker) throw GameEnginePoisonedException(method);
  if (raw == _kNotFoundMarker) throw GameEngineHandleNotFoundError(method);
}

/// Результат шага `nextItem`.
class NextItemStep {
  final String kind; // "item" | "transition" | "done"
  final Map<String, dynamic>? item;
  final String? node;

  const NextItemStep._(this.kind, this.item, this.node);

  bool get isItem => kind == 'item';
  bool get isTransition => kind == 'transition';
  bool get isDone => kind == 'done';

  static NextItemStep parse(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    return NextItemStep._(
      data['kind'] as String,
      data['item'] as Map<String, dynamic>?,
      data['node'] as String?,
    );
  }
}

/// Обёртка Rust-движка сессии по целочисленному handle.
class MeanderGameEngine {
  final int _handle;
  bool _disposed = false;

  MeanderGameEngine._(this._handle);

  int get handle => _handle;

  /// Движок уже disposed и непригоден к работе.
  bool get isDisposed => _disposed;

  /// Создать движок из сырых JSON квеста.
  ///
  /// Если задан [questRoot] (каталог документов приложения), движок читает
  /// квест с диска сам (config/nodes/templates/скрипты по требованию) —
  /// остальные параметры не нужны и игнорируются.
  static Future<MeanderGameEngine> create({
    required String questId,
    Map<String, dynamic> config = const {},
    Map<String, dynamic> nodesJson = const {},
    List<dynamic> templates = const [],
    String platformOs = 'unknown',
    bool isWeb = false,
    Map<String, String> embeddedScripts = const {},
    String? questRoot,
  }) async {
    final handle = await gen.gameEngineNew(
      init: gen.GameEngineInit(
        questId: questId,
        configJson: jsonEncode(config),
        nodesJson: jsonEncode(nodesJson),
        templatesJson: jsonEncode(templates),
        platformOs: platformOs,
        isWeb: isWeb,
        embeddedScripts: embeddedScripts,
        questRoot: questRoot,
      ),
    );
    if (handle == 0) {
      throw const GameEnginePoisonedException('create');
    }
    return MeanderGameEngine._(handle);
  }

  /// Удалить движок из реестра (освобождает память). Идемпотентен.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    gen.gameEngineDispose(handle: _handle);
  }

  /// Запустить новую игру. Возвращает JSON `NodeView` либо null.
  Future<Map<String, dynamic>?> startNew({String? startNodeId}) async {
    final sw = Stopwatch()..start();
    final json = await gen.gameEngineStartNew(
      handle: _handle,
      startNodeId: startNodeId,
    );
    if (json == null) return null;
    _throwIfEngineError(json, 'startNew');
    final ffiMs = sw.elapsedMilliseconds;
    final result = jsonDecode(json) as Map<String, dynamic>;
    if (kDebugMode) {
      debugPrint(
        '[Engine] startNew: ffi=$ffiMs ms, json=${json.length}, '
        'decode=${sw.elapsedMilliseconds - ffiMs} ms',
      );
    }
    return result;
  }

  /// Запустить из сейва.
  Future<Map<String, dynamic>?> startFromSave(
    Map<String, dynamic> saveSlot,
  ) async {
    final sw = Stopwatch()..start();
    final json = await gen.gameEngineStartFromSave(
      handle: _handle,
      saveJson: jsonEncode(saveSlot),
    );
    if (json == null) return null;
    _throwIfEngineError(json, 'startFromSave');
    final ffiMs = sw.elapsedMilliseconds;
    final result = jsonDecode(json) as Map<String, dynamic>;
    if (kDebugMode) {
      debugPrint(
        '[Engine] startFromSave: ffi=$ffiMs ms, json=${json.length}, '
        'decode=${sw.elapsedMilliseconds - ffiMs} ms',
      );
    }
    return result;
  }

  /// Загрузить ноду напрямую.
  Future<Map<String, dynamic>?> loadNode(String nodeId) async {
    final sw = Stopwatch()..start();
    final json = await gen.gameEngineLoadNode(handle: _handle, nodeId: nodeId);
    if (json == null) return null;
    _throwIfEngineError(json, 'loadNode');
    final ffiMs = sw.elapsedMilliseconds;
    final result = jsonDecode(json) as Map<String, dynamic>;
    if (kDebugMode) {
      debugPrint(
        '[Engine] loadNode: ffi=$ffiMs ms, json=${json.length}, '
        'decode=${sw.elapsedMilliseconds - ffiMs} ms',
      );
    }
    return result;
  }

  /// Шаг назад: восстановить переменные/таблицы и показать ноду без
  /// повторного `onNodeEnter`. Возвращает `NodeView` либо null.
  Future<Map<String, dynamic>?> restoreSnapshot({
    required String nodeId,
    required Map<String, dynamic> variables,
    required Map<String, dynamic> tables,
  }) async {
    final json = await gen.gameEngineRestoreSnapshot(
      handle: _handle,
      nodeId: nodeId,
      variablesJson: jsonEncode(variables),
      tablesJson: jsonEncode(tables),
    );
    if (json == null) return null;
    _throwIfEngineError(json, 'restoreSnapshot');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Один тик таймера: выполнить запланированный re-invoke функции
  /// (`scriptPath`, `entry`). Возвращает `{"ran": bool, "transition": ...}`.
  Future<Map<String, dynamic>?> runScheduledTimer(
    String scriptPath,
    String entry,
  ) async {
    final json = await gen.gameEngineRunScheduledTimer(
      handle: _handle,
      scriptPath: scriptPath,
      entry: entry,
    );
    _throwIfEngineError(json, 'runScheduledTimer');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Раскрыть следующий контент-айтем.
  Future<NextItemStep> nextItem() async {
    final json = await gen.gameEngineNextItem(handle: _handle);
    _throwIfEngineError(json, 'nextItem');
    return NextItemStep.parse(json);
  }

  /// Обработать нажатие. Возвращает узел перехода либо null.
  Future<String?> handleInteraction(
    Map<String, dynamic> item,
    String triggerRef,
  ) async {
    final raw = await gen.gameEngineHandleInteraction(
      handle: _handle,
      itemJson: jsonEncode(item),
      triggerRef: triggerRef,
    );
    _throwIfEngineError(raw, 'handleInteraction');
    return raw.isEmpty ? null : raw;
  }

  /// Проверить видимость айтема по behaviours.
  ///
  /// - [allowMutation]=true — первый проход: разрешает `set_variable`
  ///   внутри condition-блоков (паритет `evaluateCondition(allowStateMutation: true)`).
  /// - [allowMutation]=false — реактивная переоценка без side-effects.
  /// Выполняется синхронно через FFI, не требует await.
  bool evaluateVisibility(Map<String, dynamic> item, {bool allowMutation = false}) {
    final raw = gen.gameEngineEvaluateVisibility(
      handle: _handle,
      itemJson: jsonEncode(item),
      allowMutation: allowMutation,
    );
    _throwIfEngineError(raw, 'evaluateVisibility');
    return raw == 'true';
  }

  /// Выполнить поведение айтема (action/reveal).
  /// Возвращает узел перехода либо null.
  Future<String?> executeBehaviour(
    Map<String, dynamic> item,
    String event,
  ) async {
    final raw = await gen.gameEngineExecuteBehaviour(
      handle: _handle,
      itemJson: jsonEncode(item),
      event: event,
    );
    _throwIfEngineError(raw, 'executeBehaviour');
    return raw.isEmpty ? null : raw;
  }

  /// Синхронизировать pacing-снапшот в состояние движка.
  ///
  /// Во время `_paceScriptDelays` клиент применяет промежуточные значения
  /// переменных к Dart `gameStateProvider`. Этот метод зеркалит их в движок,
  /// чтобы `evaluateVisibility` видел актуальный кадр анимации (например,
  /// `Вр_Img='ВПА'` между `wait 1500` и `Вр_Img='—'`).
  /// Выполняется синхронно через FFI.
  void applyExternalVariables(Map<String, dynamic> variables) {
    if (variables.isEmpty) return;
    gen.gameEngineApplyExternalVariables(
      handle: _handle,
      variablesJson: jsonEncode(variables),
    );
  }

  /// Восстановить переменные движка после pacing-цикла.
  /// Откатывает оверлеи, сделанные через [applyExternalVariables].
  void restoreAfterPacing() {
    gen.gameEngineRestoreAfterPacing(handle: _handle);
  }

  /// Установить переменную напрямую в состояние движка (минуя скрипты).
  ///
  /// Используется для мутаций, инициированных клиентом (например, сохранение
  /// значения input-поля). Переменная помечается dirty — попадёт в
  /// следующий [drainStateDelta].
  void setStateVariable(String name, dynamic value) {
    gen.gameEngineSetStateVariable(
      handle: _handle,
      key: name,
      valueJson: jsonEncode(value),
    );
  }

  /// Забрать переход, который диспетчер `onDataChange` выдал во время прямой
  /// мутации из клиента.
  ///
  /// [setStateVariable] не возвращает переход — подписка на введённое значение
  /// иначе ждала бы следующего шага игры, которого может и не случиться.
  String? takePendingTransition() {
    final raw = gen.gameEngineTakePendingTransition(handle: _handle);
    return raw.isEmpty ? null : raw;
  }

  /// Резолвить целевой узел (`=expression` или `{var}`).
  Future<String?> resolveTarget(String raw) async {
    final result = gen.gameEngineResolveTarget(handle: _handle, raw: raw);
    _throwIfEngineError(result, 'resolveTarget');
    return result.isEmpty ? null : result;
  }

  /// Синхронная версия [resolveTarget] (для UI-хендлеров без await).
  String? resolveTargetSync(String raw) {
    final result = gen.gameEngineResolveTarget(handle: _handle, raw: raw);
    _throwIfEngineError(result, 'resolveTarget');
    return result.isEmpty ? null : result;
  }

  /// Вычислить выражение.
  Future<dynamic> evaluate(String expr) async {
    final result = gen.gameEngineEvaluate(
      handle: _handle,
      inputJson: jsonEncode(expr),
    );
    _throwIfEngineError(result, 'evaluate');
    return jsonDecode(result);
  }

  /// Синхронная версия [evaluate] (для `build()`-перестроек текста).
  /// Выполняется через sync FFI без await.
  dynamic evaluateSync(String expr) {
    final result = gen.gameEngineEvaluate(
      handle: _handle,
      inputJson: jsonEncode(expr),
    );
    _throwIfEngineError(result, 'evaluate');
    return jsonDecode(result);
  }

  /// Снапшот текущего состояния (для автосейва).
  Future<Map<String, dynamic>> snapshot() async {
    final json = await gen.gameEngineSnapshot(handle: _handle);
    _throwIfEngineError(json, 'snapshot');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Собрать и очистить дельту изменённого состояния (только изменённые
  /// переменные/таблицы с момента прошлого вызова).
  Future<Map<String, dynamic>> drainStateDelta() async {
    final sw = Stopwatch()..start();
    final json = await gen.gameEngineDrainStateDelta(handle: _handle);
    _throwIfEngineError(json, 'drainStateDelta');
    final ffiMs = sw.elapsedMilliseconds;
    final result = jsonDecode(json) as Map<String, dynamic>;
    if (kDebugMode) {
      debugPrint(
        '[Engine] drainStateDelta: ffi=$ffiMs ms, json=${json.length}, '
        'decode=${sw.elapsedMilliseconds - ffiMs} ms',
      );
    }
    return result;
  }

  /// Собрать и очистить одноразовые аудио-команды.
  Future<Map<String, dynamic>> drainAudio() async {
    final json = await gen.gameEngineDrainAudio(handle: _handle);
    _throwIfEngineError(json, 'drainAudio');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Собрать и очистить внешние системные команды (`open_link` и т.п.).
  Future<Map<String, dynamic>> drainExternal() async {
    final json = await gen.gameEngineDrainExternal(handle: _handle);
    _throwIfEngineError(json, 'drainExternal');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Слить очередь pacing-шагов от блоков `wait` (паритет эталона: `wait`
  /// был `await Future.delayed(ms)`). Каждый шаг — checkpoint исполнения:
  /// `{"type": "delay", "ms": N, "variables": {name: jsonStr},
  /// "tables": {name: jsonStr}, "audio": [команды]}`. Клиент применяет
  /// снапшоты переменных (анимации кадров), проигрывает audio шага и ждёт
  /// `Future.delayed(ms)` перед применением финальной дельты состояния.
  Future<List<Map<String, dynamic>>> drainDelaySteps() async {
    final sw = Stopwatch()..start();
    final json = await gen.gameEngineDrainDelayQueue(handle: _handle);
    _throwIfEngineError(json, 'drainDelaySteps');
    final ffiMs = sw.elapsedMilliseconds;
    final result = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    if (kDebugMode) {
      debugPrint(
        '[Engine] drainDelaySteps: ffi=$ffiMs ms, json=${json.length}, '
        'steps=${result.length}, decode=${sw.elapsedMilliseconds - ffiMs} ms',
      );
    }
    return result;
  }

  /// Слить только длительности wait'ов (устаревший шейп; см. [drainDelaySteps]).
  Future<List<int>> drainDelayQueue() async {
    final steps = await drainDelaySteps();
    return steps
        .map((s) => ((s['ms'] ?? 0) as num).toInt())
        .toList(growable: false);
  }

  /// Сохранить текущее состояние движка в слот. Возвращает JSON слота либо null.
  Future<Map<String, dynamic>?> saveSlot(String slotName) async {
    final json = await gen.gameEngineSaveSlot(
      handle: _handle,
      slotName: slotName,
    );
    if (json == null) return null;
    _throwIfEngineError(json, 'saveSlot');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Собрать `SaveSlot` из текущего состояния движка без записи в хранилище.
  ///
  /// [currentNodeId] переопределяет текущую ноду (пустая строка — оставить
  /// текущую). Возвращает JSON слота либо null (игра не начата).
  Future<Map<String, dynamic>?> toSaveSlot(
    String slotName, {
    String currentNodeId = '',
  }) async {
    final json = await gen.gameEngineToSaveSlot(
      handle: _handle,
      slotName: slotName,
      currentNodeId: currentNodeId,
    );
    if (json == null) return null;
    _throwIfEngineError(json, 'toSaveSlot');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Автосохранение (слот `_autosave`). Возвращает JSON слота либо null.
  Future<Map<String, dynamic>?> performAutosave() async {
    final json = await gen.gameEnginePerformAutosave(handle: _handle);
    if (json == null) return null;
    _throwIfEngineError(json, 'performAutosave');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Список сейв-слотов квеста.
  Future<List<Map<String, dynamic>>> listSaves() async {
    final json = await gen.gameEngineListSaves(handle: _handle);
    _throwIfEngineError(json, 'listSaves');
    return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
  }

  /// Прочитать конкретный слот.
  Future<Map<String, dynamic>?> readSave(String slotId) async {
    final json = await gen.gameEngineReadSave(handle: _handle, slotId: slotId);
    if (json == null) return null;
    _throwIfEngineError(json, 'readSave');
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Удалить слот по id.
  Future<void> deleteSave(String slotId) async {
    gen.gameEngineDeleteSave(handle: _handle, slotId: slotId);
  }
}

/// Статический список типов блоков скриптового движка.
///
/// Не требует экземпляра движка — реестр блоков статичен.
/// Возвращает JSON-массив `[{name, displayName, aliases, category}, ...]`.
/// Используется редактором для авто-построения UI-списка без правок Dart.
String listBlockTypes() => gen.gameEngineListBlockTypes();
