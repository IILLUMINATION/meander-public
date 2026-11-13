import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/formula_syntax.dart';

/// Проблема, найденная в скрипте перед выходом из редактора.
class ScriptIssue {
  /// Блок, к которому относится замечание: по нему редактор может
  /// прокрутить к месту правки.
  final String blockId;

  /// Готовый текст для диалога.
  final String message;

  const ScriptIssue(this.blockId, this.message);
}

/// Проверка скрипта перед закрытием редактора.
///
/// Правила сознательно узкие: только то, что движок не сможет выполнить
/// (пустой обязательный параметр, не выбранная переменная/нода/ассет).
/// Семантику значений и существование ресурсов проверяет ядро при запуске
/// квеста, а здесь нужен быстрый ответ до выхода с экрана.
///
/// [tables] — имена таблиц квеста. Нужны, чтобы поймать коллизию имён:
/// переменная с именем таблицы ломает адресацию `table_cell(имя, …)` —
/// первый аргумент резолвится в переменную, а не в таблицу. Пустое
/// множество отключает проверку (конфиг не прочитался).
List<ScriptIssue> validateScriptBlocks(
  List<VisualScriptBlock> blocks, {
  Set<String> tables = const {},
}) {
  final issues = <ScriptIssue>[];

  void visit(List<VisualScriptBlock> list) {
    for (final block in list) {
      _checkBlock(block, issues, tables: tables);
      for (final nested in block.nestedBlockLists) {
        visit(nested);
      }
    }
  }

  visit(blocks);
  return issues;
}

/// Синтаксис формулы как отдельное замечание: пустые поля уже отсеяны
/// выше, здесь интересует только баланс скобок и кавычек.
void _checkSyntax(
  String? formula,
  List<ScriptIssue> issues,
  String blockId,
  String field,
) {
  final error = formulaSyntaxError(formula ?? '');
  if (error == null) return;
  issues.add(
    ScriptIssue(blockId, trf('{p0}: {p1}', {'p0': field, 'p1': error})),
  );
}

void _checkBlock(
  VisualScriptBlock block,
  List<ScriptIssue> issues, {
  required Set<String> tables,
}) {
  void add(String message) => issues.add(ScriptIssue(block.id, message));

  if (block is EventBlock) {
    if (block.eventType == null) {
      add(tr('Не выбрано событие'));
    }
    return;
  }

  if (block is AssignVariableBlock) {
    final name = block.variableName.trim();
    if (name.isEmpty || name == 'имя_переменной') {
      add(tr('Не выбрана переменная'));
    } else if (tables.contains(name)) {
      add(
        trf(
          'Переменная «{p0}» называется как таблица: адресация table_cell(…, «{p0}», …) не сработает',
          {'p0': name},
        ),
      );
    }
    if (block.value.trim().isEmpty) {
      add(tr('Пустое значение присвоения'));
    } else {
      _checkSyntax(
        block.value,
        issues,
        block.id,
        tr('Значение присвоения'),
      );
    }
    return;
  }

  if (block is SetImageBlock) {
    if (block.itemId == null || block.itemId!.trim().isEmpty) {
      add(tr('Не выбран объект для смены картинки'));
    }
    if (block.source.trim().isEmpty) {
      add(tr('Не задан источник картинки'));
    } else {
      _checkSyntax(
        block.source,
        issues,
        block.id,
        tr('Источник картинки'),
      );
    }
    return;
  }

  if (block is SetVisibleBlock) {
    if (block.itemId == null || block.itemId!.trim().isEmpty) {
      add(tr('Не выбран объект для показа/скрытия'));
    }
    return;
  }

  if (block is GoToNodeBlock) {
    if (block.targetNodeId == null || block.targetNodeId!.trim().isEmpty) {
      add(tr('Не выбрана нода перехода'));
    }
    return;
  }

  if (block is ConditionBlock) {
    if (block.expression.trim().isEmpty) {
      add(tr('Пустое условие'));
    } else {
      _checkSyntax(block.expression, issues, block.id, tr('Условие'));
    }
    return;
  }

  if (block is WhileBlock) {
    if (block.expression.trim().isEmpty) {
      add(tr('Пустое условие цикла'));
    } else {
      _checkSyntax(block.expression, issues, block.id, tr('Условие цикла'));
    }
    return;
  }

  if (block is DelayBlock) {
    if (block.expression.trim().isEmpty) {
      add(tr('Не задано время задержки'));
    } else {
      _checkSyntax(block.expression, issues, block.id, tr('Время задержки'));
    }
    return;
  }

  if (block is TableOperationBlock) {
    if (block.tableName.trim().isEmpty) {
      add(tr('Не выбрана таблица'));
    } else if (tables.isNotEmpty && !tables.contains(block.tableName.trim())) {
      add(trf('Таблица «{p0}» не объявлена', {'p0': block.tableName.trim()}));
    }
    return;
  }

  if (block is CallScriptBlock) {
    if (block.scriptId == null || block.scriptId!.trim().isEmpty) {
      add(tr('Не выбран вызываемый скрипт'));
    }
    return;
  }

  if (block is CallLuaBlock) {
    // Исходник может лежать прямо в блоке (`script`), без файла.
    final hasInline = block.script.trim().isNotEmpty;
    final hasFile = block.scriptId != null && block.scriptId!.trim().isNotEmpty;
    if (!hasInline && !hasFile) {
      add(tr('Не выбран Lua-скрипт'));
    }
    return;
  }

  if (block is HttpRequestBlock) {
    if (block.url.trim().isEmpty) {
      add(tr('Не задан URL запроса'));
    }
    return;
  }
}