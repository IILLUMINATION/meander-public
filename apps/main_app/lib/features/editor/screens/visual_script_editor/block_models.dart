import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/script_contracts.dart';
import 'package:mnd_core/contracts/script_runtime.dart';
export 'package:mnd_core/contracts/script_runtime.dart' show EventType;

enum BlockCategory { event, control, variable, action, script, comment }

enum TableOperation { get, set, add, remove, removeValue, clear, contains }

/// Операции блока «Сохранения». Имена уходят в JSON как есть и совпадают с
/// `save_operation.rs`; клиент превращает их во внешние команды.
enum SaveOperation { save, open, load, delete }

/// Как операция записывается в JSON скрипта. Имена — контракт движка
/// (`execute_table_operation` в `crates/mnd-core/src/executor.rs`), поэтому
/// `removeValue` уходит на диск как `remove_value`, а не как `removeValue`.
String tableOperationWireName(TableOperation op) => switch (op) {
  TableOperation.removeValue => 'remove_value',
  _ => op.name,
};

/// Обратный разбор: имя операции могло прийти и как идентификатор Dart
/// (`removeValue`), и как alias из старых редакторов. `null` — если операции
/// в движке нет, чтобы блок сохранился как UnknownBlock, а не молча
/// превратился в «Получить».
TableOperation? tableOperationFromWire(String? raw) {
  final key = (raw ?? '').trim();
  if (key.isEmpty) return null;
  for (final op in TableOperation.values) {
    if (op.name == key || tableOperationWireName(op) == key) return op;
  }
  return switch (key) {
    'delete' || 'unset' => TableOperation.remove,
    _ => null,
  };
}

/// Подсказки для блока «Данные»: чем операция отличается от соседних и какие
/// поля ей нужны. Держим рядом с моделью, чтобы список операций в редакторе
/// скриптов и подсказка в редакторе таблиц не разъехались с движком.
extension TableOperationHelp on TableOperation {
  String get label => switch (this) {
    TableOperation.get => tr('Получить'),
    TableOperation.set => tr('Записать'),
    TableOperation.add => tr('Добавить'),
    TableOperation.remove => tr('Удалить'),
    TableOperation.removeValue => tr('Удалить значение'),
    TableOperation.clear => tr('Очистить'),
    TableOperation.contains => tr('Содержит?'),
  };

  /// Строка в списке операций: чем отличается от похожей. Ключ перевода обязан
  /// быть одним литералом, поэтому строки не разрезаются склейкой.
  String get description => switch (this) {
    TableOperation.get => tr(
      'Прочитать значение по пути в переменную. Пустой путь читает не таблицу, а запасное значение из поля «Значение».',
    ),
    TableOperation.set => tr(
      'Заменить значение по пути (ключ, элемент списка items[1] или items[0].name). Корень таблицы не перезаписывается.',
    ),
    TableOperation.add => tr(
      'Дописать элемент в конец списка по пути. Если списка там нет — он создастся.',
    ),
    TableOperation.remove => tr(
      'Убрать ключ словаря (Путь = bread) или элемент по номеру с нуля (items[1] — второй). По значению — см. «Удалить значение».',
    ),
    TableOperation.removeValue => tr(
      'Убрать из списка первое совпадение со значением: Путь = items, Значение = «меч». Для ключей словаря берите «Удалить».',
    ),
    TableOperation.clear => tr(
      'Очистить всю таблицу, а по пути — только список или словарь по нему.',
    ),
    TableOperation.contains => tr(
      'Есть ли значение в списке или словаре; Путь пустой — ищем по всей таблице. Результат (да/нет) кладём в переменную.',
    ),
  };

  /// Подпись под полем: что туда писать.
  String hintFor(String field) => switch ((this, field)) {
    (_, 'path') when this == TableOperation.clear => tr('пусто — вся таблица'),
    (TableOperation.get, 'path') => tr('имя ключа, например gold'),
    (TableOperation.set, 'path') => tr('куда пишем: gold или items[0]'),
    (TableOperation.add, 'path') => tr('какой список пополняем: items'),
    (TableOperation.remove, 'path') => tr(
      'ключ (bread) или элемент с нуля: items[1] — второй',
    ),
    (TableOperation.removeValue, 'path') => tr('какой список: items'),
    (TableOperation.contains, 'path') => tr('где искать; пусто — вся таблица'),
    (_, 'value') when this == TableOperation.get => tr(
      'кладётся в переменную, если ключа нет',
    ),
    (TableOperation.contains, 'value') => tr('что ищем'),
    (_, 'value') => tr('формула или литерал в кавычках'),
    (_, 'target') => tr('переменная получит результат'),
    _ => '',
  };

  /// Поле «Значение»: есть у всех операций, кроме «Удалить» и «Очистить»
  /// (им не нужно значение). У «Получить» это запасное значение.
  bool get needsValue =>
      this != TableOperation.remove && this != TableOperation.clear;

  bool get needsTarget =>
      this == TableOperation.get || this == TableOperation.contains;

  /// «Очистить» работает без пути: пустой путь = вся таблица.
  bool get pathIsOptional => this == TableOperation.clear;
}

abstract class VisualScriptBlock {
  final String id;
  final BlockCategory category;

  VisualScriptBlock({String? id, required this.category})
    : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson();

  /// Списки-владельцы вложенных блоков — единый источник правды для обхода
  /// дерева. Обход «если событие — его дети, если условие — then/else» терял
  /// цикл, for-each и кроссфейд: блок, вытащенный из цикла, оставался в нём
  /// копией.
  List<List<VisualScriptBlock>> get nestedBlockLists => switch (this) {
    final EventBlock b => [b.children],
    final ConditionBlock b => [b.thenBlocks, b.elseBlocks],
    final WhileBlock b => [b.children],
    final ForEachBlock b => [b.children],
    final CrossfadeBlock b => [b.children],
    _ => const [],
  };

  static VisualScriptBlock fromJson(Map<String, dynamic> json) {
    try {
      switch (json['type']) {
        case BlockTypes.event:
          return EventBlock.fromJson(json);
        case BlockTypes.condition:
          return ConditionBlock.fromJson(json);
        case BlockTypes.assignVariable:
          return AssignVariableBlock.fromJson(json);
        case BlockTypes.setVolume:
          return SetVolumeBlock.fromJson(json);
        case BlockTypes.setBlur:
          return SetBlurBlock.fromJson(json);
        case BlockTypes.goToNode:
          return GoToNodeBlock.fromJson(json);
        case BlockTypes.wait:
          return DelayBlock.fromJson(json);
        case BlockTypes.callScript:
          return CallScriptBlock.fromJson(json);
        case BlockTypes.callFunction:
          return CallFunctionBlock.fromJson(json);
        case BlockTypes.callLua:
          return CallLuaBlock.fromJson(json);
        case BlockTypes.tableOperation:
          return TableOperationBlock.fromJson(json);
        case BlockTypes.setImage:
          return SetImageBlock.fromJson(json);
        case BlockTypes.setVisible:
          return SetVisibleBlock.fromJson(json);
        case BlockTypes.playSound:
          return PlaySoundBlock.fromJson(json);
        case BlockTypes.stopSound:
          return StopSoundBlock.fromJson(json);
        case BlockTypes.playMusic:
          return PlayMusicBlock.fromJson(json);
        case BlockTypes.stopMusic:
          return StopMusicBlock.fromJson(json);
        case BlockTypes.pauseResume:
          return PauseResumeBlock.fromJson(json);
        case BlockTypes.crossfade:
          return CrossfadeBlock.fromJson(json);
        case BlockTypes.openLink:
          return OpenLinkBlock.fromJson(json);
        case BlockTypes.httpRequest:
          return HttpRequestBlock.fromJson(json);
        case BlockTypes.saveOperation:
          return SaveOperationBlock.fromJson(json);
        case BlockTypes.forEach:
          return ForEachBlock.fromJson(json);
        case BlockTypes.comment:
          return CommentBlock.fromJson(json);
        case BlockTypes.whileLoop:
          return WhileBlock.fromJson(json);
        default:
          // НЕ выбрасываем и не подменяем: исходный JSON сохраняется
          // в UnknownBlock и переживёт load→save без потерь.
          return UnknownBlock(json);
      }
    } catch (e) {
      print('❌ [Block] Ошибка парсинга блока: $e');
      // Ошибка разбора конкретного блока тоже не должна уничтожать
      // данные — храним сырьё как есть.
      return UnknownBlock(json);
    }
  }
}

/// Обходит дерево блоков и возвращает список-владелец блока [blockId] вместе
/// с его индексом. null — если блока в дереве нет.
({List<VisualScriptBlock> list, int index})? locateBlockInTree(
  String blockId,
  List<VisualScriptBlock> list,
) {
  for (int i = 0; i < list.length; i++) {
    final block = list[i];
    if (block.id == blockId) return (list: list, index: i);
    for (final nested in block.nestedBlockLists) {
      final found = locateBlockInTree(blockId, nested);
      if (found != null) return found;
    }
  }
  return null;
}

/// Удаляет блок [blockId] из любого места дерева [list] и говорит, нашёлся ли
/// он: drop в чужой список обязан вычеркнуть блок из старого владельца, иначе
/// перетаскивание плодит копию.
bool removeBlockFromTree(String blockId, List<VisualScriptBlock> list) {
  for (int i = 0; i < list.length; i++) {
    final block = list[i];
    if (block.id == blockId) {
      list.removeAt(i);
      return true;
    }
    for (final nested in block.nestedBlockLists) {
      if (removeBlockFromTree(blockId, nested)) return true;
    }
  }
  return false;
}

class EventBlock extends VisualScriptBlock {
  EventType? eventType;
  String functionName;

  /// Подписки события «При изменении данных»: `Золото`, `лавка.цена`,
  /// `лавка.цена.3`, `лавка.*` или `*` (всё сразу). Движок читает ключ
  /// `watchPaths` — массив или строку через запятую.
  List<String> watchPaths;

  List<VisualScriptBlock> children;
  bool collapsed;

  String? targetNodeId;
  String? targetContentItemId;

  String targetNodeName;
  String targetContentPreview;

  EventBlock({
    String? id,
    this.eventType,
    this.functionName = 'main',
    List<String>? watchPaths,
    List<VisualScriptBlock>? children,
    this.targetNodeId,
    this.targetContentItemId,
    this.targetNodeName = 'Не выбрана',
    this.targetContentPreview = 'Не выбран',
    this.collapsed = false,
  }) : children = children ?? [],
       watchPaths = watchPaths ?? [],
       super(id: id, category: BlockCategory.event);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'event',
    'id': id,
    'eventType': (eventType ?? EventType.onNodeEnter).name,
    if (targetNodeId != null) 'targetNodeId': targetNodeId,
    if (targetContentItemId != null) 'targetContentItemId': targetContentItemId,
    if ((eventType ?? EventType.onNodeEnter) == EventType.function)
      'functionName': functionName,
    // Пишем только когда подписки есть: пустой список в файле квеста — шум.
    if (watchPaths.isNotEmpty) 'watchPaths': watchPaths,
    'children': children.map((b) => b.toJson()).toList(),
    'collapsed': collapsed,
  };

  /// Подписки из файла: движок принимает и массив, и строку через запятую;
  /// старый черновик мог лежать в `watchVariables`.
  static List<String> _readWatchPaths(Map<String, dynamic> json) {
    final out = <String>[];
    for (final key in ['watchPaths', 'watchVariables']) {
      final raw = json[key];
      final parts = raw is List
          ? raw.map((e) => e.toString())
          : raw is String
          ? raw.split(',')
          : const <String>[];
      for (final part in parts) {
        final path = part.trim();
        if (path.isNotEmpty && !out.contains(path)) out.add(path);
      }
    }
    return out;
  }

  static EventBlock fromJson(Map<String, dynamic> json) {
    try {
      final childrenJson = json['children'] as List<dynamic>? ?? [];
      final children = childrenJson
          .whereType<Map<String, dynamic>>()
          .map((item) => VisualScriptBlock.fromJson(item))
          .toList();

      EventType? parsedEventType;
      try {
        final eventTypeStr = json['eventType'] as String?;
        if (eventTypeStr != null) {
          parsedEventType = EventType.values.byName(eventTypeStr);
        }
      } catch (e) {
        print('⚠️ [EventBlock] Ошибка парсинга eventType: $e');
      }

      return EventBlock(
        id: json['id'] as String?,
        eventType: parsedEventType,
        functionName: json['functionName'] as String? ?? 'main',
        watchPaths: _readWatchPaths(json),
        children: children,
        targetNodeId: json['targetNodeId'] as String?,
        targetContentItemId: json['targetContentItemId'] as String?,
        targetNodeName: json['targetNodeName'] as String? ?? 'Не выбрана',
        targetContentPreview:
            json['targetContentPreview'] as String? ?? 'Не выбран',
        collapsed: json['collapsed'] as bool? ?? false,
      );
    } catch (e) {
      print('❌ [EventBlock] Ошибка парсинга блока: $e');
      // Возвращаем пустой блок при ошибке
      return EventBlock(
        id: json['id'] as String?,
        eventType: EventType.onNodeEnter,
      );
    }
  }
}

class ConditionBlock extends VisualScriptBlock {
  String expression;
  List<VisualScriptBlock> thenBlocks;
  List<VisualScriptBlock> elseBlocks;
  bool collapsed;

  ConditionBlock({
    String? id,
    this.expression = '1 == 1',
    List<VisualScriptBlock>? thenBlocks,
    List<VisualScriptBlock>? elseBlocks,
    this.collapsed = false,
  }) : thenBlocks = thenBlocks ?? [],
       elseBlocks = elseBlocks ?? [],
       super(id: id, category: BlockCategory.control);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'condition',
    'id': id,
    'expression': expression,
    'then_blocks': thenBlocks.map((b) => b.toJson()).toList(),
    'else_blocks': elseBlocks.map((b) => b.toJson()).toList(),
    'collapsed': collapsed,
  };

  static ConditionBlock fromJson(Map<String, dynamic> json) {
    try {
      final thenBlocksJson = json['then_blocks'] as List<dynamic>? ?? [];
      final elseBlocksJson = json['else_blocks'] as List<dynamic>? ?? [];
      final thenBlocks = thenBlocksJson
          .whereType<Map<String, dynamic>>()
          .map((item) => VisualScriptBlock.fromJson(item))
          .toList();
      final elseBlocks = elseBlocksJson
          .whereType<Map<String, dynamic>>()
          .map((item) => VisualScriptBlock.fromJson(item))
          .toList();

      return ConditionBlock(
        id: json['id'] as String?,
        expression: json['expression'] as String? ?? '1 == 1',
        thenBlocks: thenBlocks,
        elseBlocks: elseBlocks,
        collapsed: json['collapsed'] as bool? ?? false,
      );
    } catch (e) {
      print('❌ [ConditionBlock] Ошибка парсинга блока: $e');
      // Возвращаем пустой блок при ошибке
      return ConditionBlock(id: json['id'] as String?, expression: '1 == 1');
    }
  }
}

class AssignVariableBlock extends VisualScriptBlock {
  String variableName;
  String value;

  AssignVariableBlock({
    String? id,
    this.variableName = 'имя_переменной',
    this.value = '0',
  }) : super(id: id, category: BlockCategory.variable);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'assign_variable',
    'id': id,
    'variable': variableName,
    'value': value,
  };

  static AssignVariableBlock fromJson(Map<String, dynamic> json) {
    return AssignVariableBlock(
      id: json['id'] as String?,
      variableName: (json['variable'] ?? json['переменная'] ?? 'имя_переменной')
          .toString(),
      value: (json['value'] ?? json['значение'] ?? '0').toString(),
    );
  }
}

/// Блок `set_image`: сменить картинку у айтема (или у слоя внутри стека).
/// `item_name` — только для подписи на канвасе, движок читает `item_id`.
class SetImageBlock extends VisualScriptBlock {
  String? itemId;
  String itemName;
  String source;

  SetImageBlock({
    super.id,
    this.itemId,
    this.itemName = 'Выберите объект',
    this.source = '',
  }) : super(category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': BlockTypes.setImage,
    'id': id,
    'item_id': itemId,
    'item_name': itemName,
    'source': source,
  };

  static SetImageBlock fromJson(Map<String, dynamic> json) {
    return SetImageBlock(
      id: json['id'] as String?,
      itemId: (json['item_id'] ?? json['айтем']) as String?,
      itemName: json['item_name'] as String? ?? 'Выберите объект',
      source: (json['source'] ?? json['источник'] ?? '').toString(),
    );
  }
}

/// Блок `set_visible`: спрятать или показать элемент контента по команде
/// скрипта. Работает на любом типе айтема — триггеры видимости описывают
/// условие, а тут нужен императивный жест в конкретный момент сцены.
/// `item_name` — только для подписи на канвасе, движок читает `item_id`.
class SetVisibleBlock extends VisualScriptBlock {
  String? itemId;
  String itemName;

  /// `show` / `hide` / `remove` / `toggle` — ядро понимает и русскую запись.
  /// `hide` оставляет айтему его место, `remove` выводит из раскладки.
  String mode;

  SetVisibleBlock({
    super.id,
    this.itemId,
    this.itemName = 'Выберите объект',
    this.mode = 'hide',
  }) : super(category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': BlockTypes.setVisible,
    'id': id,
    'item_id': itemId,
    'item_name': itemName,
    'mode': mode,
  };

  static SetVisibleBlock fromJson(Map<String, dynamic> json) {
    // Автор квеста мог написать блок от руки как `visible: true|false` —
    // движок такое принимает, и редактору нельзя терять смысл. `false`
    // сжимал ряд, то есть по-новому именно «убрать», а не «скрыть».
    final legacyVisible = (json['visible'] ?? json['видим']) as bool?;
    return SetVisibleBlock(
      id: json['id'] as String?,
      itemId: (json['item_id'] ?? json['айтем']) as String?,
      itemName: json['item_name'] as String? ?? 'Выберите объект',
      mode:
          (json['mode'] ?? json['режим'])?.toString() ??
          (legacyVisible == null
              ? 'hide'
              : (legacyVisible ? 'show' : 'remove')),
    );
  }
}

class SetVolumeBlock extends VisualScriptBlock {
  String target;
  double volume;

  SetVolumeBlock({String? id, this.target = 'tagAudio', this.volume = 1.0})
    : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'set_volume',
    'id': id,
    'target': target,
    'volume': volume,
  };

  static SetVolumeBlock fromJson(Map<String, dynamic> json) {
    return SetVolumeBlock(
      id: json['id'] as String?,
      target: json['target'] as String? ?? 'tagAudio',
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

class SetBlurBlock extends VisualScriptBlock {
  String target;
  double blurValue;

  SetBlurBlock({String? id, this.target = 'node', this.blurValue = 10.0})
    : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'set_blur',
    'id': id,
    'target': target,
    'blur': blurValue,
  };

  static SetBlurBlock fromJson(Map<String, dynamic> json) {
    return SetBlurBlock(
      id: json['id'] as String?,
      target: json['target'] as String? ?? 'node',
      blurValue: (json['blur'] as num?)?.toDouble() ?? 10.0,
    );
  }
}

class GoToNodeBlock extends VisualScriptBlock {
  String? targetNodeId;
  String targetNodeName;

  GoToNodeBlock({
    String? id,
    this.targetNodeId,
    this.targetNodeName = 'Выберите ноду',
  }) : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'go_to_node',
    'id': id,
    'node_id': targetNodeId,
    'node_name': targetNodeName,
  };

  static GoToNodeBlock fromJson(Map<String, dynamic> json) {
    return GoToNodeBlock(
      id: json['id'] as String?,
      targetNodeId: json['node_id'] as String?,
      targetNodeName: json['node_name'] as String? ?? 'Выберите ноду',
    );
  }
}

class CallScriptBlock extends VisualScriptBlock {
  String? scriptId;
  String scriptName;

  CallScriptBlock({
    String? id,
    this.scriptId,
    this.scriptName = 'Выберите скрипт',
  }) : super(id: id, category: BlockCategory.script);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'call_script',
    'id': id,
    'script_id': scriptId,
    'script_name': scriptName,
  };

  static CallScriptBlock fromJson(Map<String, dynamic> json) {
    return CallScriptBlock(
      id: json['id'] as String?,
      scriptId: json['script_id'] as String?,
      scriptName: json['script_name'] as String? ?? 'Выберите скрипт',
    );
  }
}

class CallFunctionBlock extends VisualScriptBlock {
  String? functionId;
  String functionName;
  String functionEntry;

  CallFunctionBlock({
    String? id,
    this.functionId,
    this.functionName = 'Выберите функцию',
    this.functionEntry = 'main',
  }) : super(id: id, category: BlockCategory.script);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'call_function',
    'id': id,
    'function_id': functionId,
    'function_name': functionName,
    'function_entry': functionEntry,
  };

  static CallFunctionBlock fromJson(Map<String, dynamic> json) {
    return CallFunctionBlock(
      id: json['id'] as String?,
      functionId: json['function_id'] as String?,
      functionName: json['function_name'] as String? ?? 'Выберите функцию',
      functionEntry: json['function_entry'] as String? ?? 'main',
    );
  }
}

class CallLuaBlock extends VisualScriptBlock {
  String? scriptId;
  String scriptName;
  String function;
  String script;

  /// Аргументы вызова Lua-функции: список выражений или произвольный JSON.
  /// Ядро принимает строку-JSON, массив или любой Value — сохраняем
  /// verbatim, чтобы load→save не терял данные.
  dynamic args;

  CallLuaBlock({
    String? id,
    this.scriptId,
    this.scriptName = 'Выберите .lua',
    this.function = 'start',
    this.script = '',
    this.args,
  }) : super(id: id, category: BlockCategory.script);

  @override
  Map<String, dynamic> toJson() => {
    'type': BlockTypes.callLua,
    'id': id,
    if (scriptId != null) 'script_id': scriptId,
    'function': function,
    if (script.isNotEmpty) 'script': script,
    if (args != null) 'args': args,
  };

  static CallLuaBlock fromJson(Map<String, dynamic> json) {
    return CallLuaBlock(
      id: json['id'] as String?,
      scriptId: json['script_id'] as String?,
      scriptName: json['script_name'] as String? ?? 'Выберите .lua',
      function: json['function'] as String? ?? 'start',
      script: json['script'] as String? ?? '',
      args: json['args'],
    );
  }
}

class DelayBlock extends VisualScriptBlock {
  String expression;

  DelayBlock({String? id, this.expression = '1000'})
    : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'wait',
    'id': id,
    'expression': expression,
  };

  static DelayBlock fromJson(Map<String, dynamic> json) {
    return DelayBlock(
      id: json['id'] as String?,
      expression: json['expression'] as String? ?? '1000',
    );
  }
}

class TableOperationBlock extends VisualScriptBlock {
  TableOperation operation;
  String tableName;
  String path;
  String value;
  String targetVariable;

  TableOperationBlock({
    String? id,
    this.operation = TableOperation.get,
    this.tableName = 'storage',
    this.path = '',
    this.value = '0',
    this.targetVariable = 'result',
  }) : super(id: id, category: BlockCategory.variable);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'table_operation',
    'id': id,
    'operation': tableOperationWireName(operation),
    'tableName': tableName,
    'path': path,
    'value': value,
    'targetVariable': targetVariable,
  };

  static TableOperationBlock fromJson(Map<String, dynamic> json) {
    return TableOperationBlock(
      id: json['id'] as String?,
      operation: json['operation'] == null
          ? TableOperation.get
          : tableOperationFromWire(json['operation'] as String?) ??
                (throw FormatException(
                  'неизвестная операция таблицы: ${json['operation']}',
                )),
      tableName: json['tableName'] as String? ?? 'storage',
      path: json['path'] as String? ?? '',
      value: json['value'] as String? ?? '0',
      targetVariable: json['targetVariable'] as String? ?? 'result',
    );
  }
}

class PlaySoundBlock extends VisualScriptBlock {
  String? audioId;
  String audioName;
  double volume;

  PlaySoundBlock({
    String? id,
    this.audioId,
    this.audioName = 'Выберите аудио',
    this.volume = 1.0,
  }) : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'play_sound',
    'id': id,
    'audio_id': audioId,
    'audio_name': audioName,
    'volume': volume,
  };

  static PlaySoundBlock fromJson(Map<String, dynamic> json) {
    return PlaySoundBlock(
      id: json['id'] as String?,
      audioId: (json['audio_id'] ?? json['audioId']) as String?,
      audioName: json['audio_name'] as String? ?? 'Выберите аудио',
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

class StopSoundBlock extends VisualScriptBlock {
  String target;
  String? audioId;
  String audioName;

  StopSoundBlock({
    String? id,
    this.target = 'all',
    this.audioId,
    this.audioName = 'Все звуки',
  }) : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'stop_sound',
    'id': id,
    'target': target,
    'audio_id': audioId,
    'audio_name': audioName,
  };

  static StopSoundBlock fromJson(Map<String, dynamic> json) {
    return StopSoundBlock(
      id: json['id'] as String?,
      target: json['target'] as String? ?? 'all',
      audioId: json['audio_id'] as String?,
      audioName: json['audio_name'] as String? ?? 'Все звуки',
    );
  }
}

class PlayMusicBlock extends VisualScriptBlock {
  String? audioId;
  String audioName;
  double volume;
  bool loop;
  bool global;

  PlayMusicBlock({
    String? id,
    this.audioId,
    this.audioName = 'Выберите музыку',
    this.volume = 1.0,
    this.loop = true,
    this.global = false,
  }) : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'play_music',
    'id': id,
    'audio_id': audioId,
    'audio_name': audioName,
    'volume': volume,
    'loop': loop,
    'global': global,
  };

  static PlayMusicBlock fromJson(Map<String, dynamic> json) {
    return PlayMusicBlock(
      id: json['id'] as String?,
      audioId: (json['audio_id'] ?? json['audioId']) as String?,
      audioName: json['audio_name'] as String? ?? 'Выберите музыку',
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      loop: json['loop'] as bool? ?? true,
      global: json['global'] as bool? ?? false,
    );
  }
}

class StopMusicBlock extends VisualScriptBlock {
  StopMusicBlock({String? id}) : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {'type': 'stop_music', 'id': id};

  static StopMusicBlock fromJson(Map<String, dynamic> json) {
    return StopMusicBlock(id: json['id'] as String?);
  }
}

class PauseResumeBlock extends VisualScriptBlock {
  String target;
  String action;

  PauseResumeBlock({String? id, this.target = 'all', this.action = 'toggle'})
    : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'pause_resume',
    'id': id,
    'target': target,
    'action': action,
  };

  static PauseResumeBlock fromJson(Map<String, dynamic> json) {
    return PauseResumeBlock(
      id: json['id'] as String?,
      target: json['target'] as String? ?? 'all',
      action: json['action'] as String? ?? 'toggle',
    );
  }
}

class CrossfadeBlock extends VisualScriptBlock {
  String durationExpression;
  List<VisualScriptBlock> children;
  bool collapsed;

  CrossfadeBlock({
    String? id,
    this.durationExpression = '2',
    List<VisualScriptBlock>? children,
    this.collapsed = false,
  }) : children = children ?? [],
       super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'crossfade',
    'id': id,
    'duration': durationExpression,
    'children': children.map((b) => b.toJson()).toList(),
    'collapsed': collapsed,
  };

  static CrossfadeBlock fromJson(Map<String, dynamic> json) {
    try {
      final childrenJson = json['children'] as List<dynamic>? ?? [];
      final children = childrenJson
          .whereType<Map<String, dynamic>>()
          .map((item) => VisualScriptBlock.fromJson(item))
          .toList();

      return CrossfadeBlock(
        id: json['id'] as String?,
        durationExpression: json['duration'] as String? ?? '2',
        children: children,
        collapsed: json['collapsed'] as bool? ?? false,
      );
    } catch (e) {
      print('❌ [CrossfadeBlock] Ошибка парсинга: $e');
      return CrossfadeBlock(id: json['id'] as String?);
    }
  }
}

class OpenLinkBlock extends VisualScriptBlock {
  String url;

  OpenLinkBlock({String? id, this.url = 'https://'})
    : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {'type': 'open_link', 'id': id, 'url': url};

  static OpenLinkBlock fromJson(Map<String, dynamic> json) {
    return OpenLinkBlock(
      id: json['id'] as String?,
      url: json['url'] as String? ?? 'https://',
    );
  }
}

class ForEachBlock extends VisualScriptBlock {
  String tableName;
  String varPrefix;
  String indexVariable;
  List<VisualScriptBlock> children;
  bool collapsed;

  ForEachBlock({
    String? id,
    this.tableName = '',
    this.varPrefix = '',
    this.indexVariable = '',
    List<VisualScriptBlock>? children,
    this.collapsed = false,
  }) : children = children ?? [],
       super(id: id, category: BlockCategory.control);

  @override
  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'type': 'for_each',
      'id': id,
      'table': tableName,
      'children': children.map((c) => c.toJson()).toList(),
      'collapsed': collapsed,
    };
    if (varPrefix.isNotEmpty) map['var_prefix'] = varPrefix;
    if (indexVariable.isNotEmpty) map['index_variable'] = indexVariable;
    return map;
  }

  static ForEachBlock fromJson(Map<String, dynamic> json) {
    return ForEachBlock(
      id: json['id'] as String?,
      tableName: (json['table'] ?? json['таблица'] ?? '').toString(),
      varPrefix: (json['var_prefix'] ?? json['префикс'] ?? '').toString(),
      indexVariable: (json['index_variable'] ?? json['индекс'] ?? '')
          .toString(),
      children:
          (json['children'] as List<dynamic>?)
              ?.map(
                (c) => VisualScriptBlock.fromJson(c as Map<String, dynamic>),
              )
              .toList() ??
          [],
      collapsed: json['collapsed'] as bool? ?? false,
    );
  }
}

class CommentBlock extends VisualScriptBlock {
  String text;

  CommentBlock({String? id, this.text = ''})
    : super(id: id, category: BlockCategory.control);

  @override
  Map<String, dynamic> toJson() => {'type': 'comment', 'id': id, 'text': text};

  static CommentBlock fromJson(Map<String, dynamic> json) {
    return CommentBlock(
      id: json['id'] as String?,
      text: (json['text'] ?? json['текст'] ?? '').toString(),
    );
  }
}

class WhileBlock extends VisualScriptBlock {
  /// Экспертный режим: свободное булево выражение. Пустое = не используется.
  String expression;
  List<VisualScriptBlock> children;
  bool collapsed;
  int maxIterations;

  /// Простой режим: «повторить N раз» (ядро: count).
  String count;

  /// Необязательная переменная-счётчик ({имя} доступна детям).
  String loopVar;

  /// Диапазонный режим: от / до / шаг.
  String from;
  String to;
  String step;

  WhileBlock({
    String? id,
    this.expression = '',
    this.count = '3',
    this.loopVar = '',
    this.from = '1',
    this.to = '',
    this.step = '1',
    List<VisualScriptBlock>? children,
    this.collapsed = false,
    this.maxIterations = 10000,
  }) : children = children ?? [],
       super(id: id, category: BlockCategory.control);

  bool get hasExpression => expression.trim().isNotEmpty;
  bool get hasRange => to.trim().isNotEmpty;
  bool get hasCount => count.trim().isNotEmpty;

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'while',
      'id': id,
      // Ядро трактует отсутствующие поля как «режим не задан»; пишем только
      // заполненное, чтобы JSON читался как в Scratch-подобных редакторах.
      if (hasExpression) 'expression': expression,
      if (hasCount) 'count': count,
      if (loopVar.trim().isNotEmpty) 'loop_var': loopVar,
      if (hasRange) ...{'from': from, 'to': to, 'step': step},
      'children': children.map((b) => b.toJson()).toList(),
      'collapsed': collapsed,
      'max_iterations': maxIterations,
    };
    return json;
  }

  static WhileBlock fromJson(Map<String, dynamic> json) {
    // Числовые count/from/to/step (из старых квестов и из ядра) приводим
    // к строке: модель хранит формулы строками.
    String asFormula(dynamic v, String fallback) =>
        v == null ? fallback : v.toString();
    return WhileBlock(
      id: json['id'] as String?,
      expression: json['expression']?.toString() ?? '',
      count: asFormula(json['count'], ''),
      loopVar: json['loop_var'] as String? ?? '',
      from: asFormula(json['from'], '1'),
      to: asFormula(json['to'], ''),
      step: asFormula(json['step'], '1'),
      children:
          (json['children'] as List<dynamic>?)
              ?.map(
                (c) => VisualScriptBlock.fromJson(c as Map<String, dynamic>),
              )
              .toList() ??
          [],
      collapsed: json['collapsed'] as bool? ?? false,
      maxIterations: (json['max_iterations'] as num?)?.toInt() ?? 10000,
    );
  }
}

class HttpRequestBlock extends VisualScriptBlock {
  String method;
  String url;

  /// Заголовки в виде JSON-строки (`{"Content-Type":"application/json"}`).
  /// В движок сериализуется как объект (если строка парсится), иначе — как
  /// есть (движок проигнорирует не-объект).
  String headers;
  String body;
  String targetVariable;
  String statusVariable;

  HttpRequestBlock({
    String? id,
    this.method = 'GET',
    this.url = 'https://',
    this.headers = '',
    this.body = '',
    this.targetVariable = 'response',
    this.statusVariable = 'response_status',
  }) : super(id: id, category: BlockCategory.action);

  Map<String, dynamic>? _tryParseHeaders() {
    final raw = headers.trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  @override
  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'type': 'http_request',
      'id': id,
      'method': method,
      'url': url,
      'targetVariable': targetVariable,
      'statusVariable': statusVariable,
    };
    if (body.isNotEmpty) map['body'] = body;
    final parsedHeaders = _tryParseHeaders();
    if (parsedHeaders != null) {
      map['headers'] = parsedHeaders;
    } else if (headers.trim().isNotEmpty) {
      map['headers'] = headers;
    }
    return map;
  }

  static HttpRequestBlock fromJson(Map<String, dynamic> json) {
    final headersRaw = json['headers'];
    String headers = '';
    if (headersRaw is Map) {
      headers = jsonEncode(headersRaw);
    } else if (headersRaw is String) {
      headers = headersRaw;
    }

    final bodyRaw = json['body'];
    String body = '';
    if (bodyRaw is String) {
      body = bodyRaw;
    } else if (bodyRaw != null) {
      body = jsonEncode(bodyRaw);
    }

    return HttpRequestBlock(
      id: json['id'] as String?,
      method: (json['method'] as String? ?? 'GET').toUpperCase(),
      url: json['url'] as String? ?? '',
      headers: headers,
      body: body,
      targetVariable: json['targetVariable'] as String? ?? 'response',
      statusVariable: json['statusVariable'] as String? ?? 'response_status',
    );
  }
}

/// Блок неизвестного типа (создан более новой версией приложения, битый
/// JSON и т.п.). Хранит исходный JSON и сериализуется обратно 1-в-1:
/// load→save НЕ теряет данные. В редакторе показывается карточкой
/// «Неизвестный блок»; пользователь может только удалить его.
/// Блок «Сохранения»: создать слот, открыть список, загрузить или удалить.
/// Сами файлы пишет клиент через `SaveGameService`, движок только ставит
/// команду в очередь — это оставляет ядро без ФС и работает на всех плеерах.
class SaveOperationBlock extends VisualScriptBlock {
  SaveOperation operation;
  String slotName;

  SaveOperationBlock({
    String? id,
    this.operation = SaveOperation.save,
    this.slotName = '',
  }) : super(id: id, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => {
    'type': BlockTypes.saveOperation,
    'id': id,
    'operation': operation.name,
    'slotName': slotName,
  };

  static SaveOperationBlock fromJson(Map<String, dynamic> json) {
    final raw = (json['operation'] ?? 'save').toString();
    final op = SaveOperation.values.firstWhere(
      (o) => o.name == raw,
      orElse: () => SaveOperation.save,
    );
    return SaveOperationBlock(
      id: json['id'] as String?,
      operation: op,
      slotName: (json['slotName'] ?? json['slot'] ?? '').toString(),
    );
  }
}

class UnknownBlock extends VisualScriptBlock {
  /// Исходный JSON блока — возвращается из toJson() без изменений.
  final Map<String, dynamic> raw;

  String? get rawType => raw['type']?.toString();

  UnknownBlock(Map<String, dynamic> json)
    : raw = Map<String, dynamic>.of(json),
      super(id: json['id'] as String?, category: BlockCategory.action);

  @override
  Map<String, dynamic> toJson() => Map<String, dynamic>.of(raw);
}

/// Кем блок является для подписи операций: `[noun]` — существительное в
/// именительном падеже, `[neuter]` — средний род (для причастий в
/// уведомлениях), `[container]` — внутри блока лежат другие блоки.
///
/// Операция над контейнером захватывает всё его содержимое, поэтому «Блок
/// продублирован» за целое событие читалось как «продублирован один блок».
({bool container, bool neuter, String noun}) blockScope(
  VisualScriptBlock block,
) {
  return switch (block) {
    EventBlock() => (noun: 'событие', neuter: true, container: true),
    ConditionBlock() => (noun: 'условие', neuter: true, container: true),
    ForEachBlock() => (noun: 'цикл', neuter: false, container: true),
    WhileBlock() => (noun: 'цикл', neuter: false, container: true),
    CrossfadeBlock() => (noun: 'кроссфейд', neuter: false, container: true),
    _ => (noun: 'блок', neuter: false, container: false),
  };
}
