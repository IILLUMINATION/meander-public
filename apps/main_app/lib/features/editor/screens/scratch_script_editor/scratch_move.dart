import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';

import 'scratch_layout.dart';

/// Лежит ли [list] внутри [block] (в любом из его вложенных списков).
///
/// Нужно, чтобы не позволить бросить контейнер внутрь себя: иначе узел и
/// его родитель ссылаются друг на друга, `toJson` уходит в бесконечную
/// рекурсию, и скрипт на диске теряется.
bool blockOwnsList(VisualScriptBlock block, List<VisualScriptBlock> list) {
  for (final nested in block.nestedBlockLists) {
    if (identical(nested, list)) return true;
    for (final child in nested) {
      if (blockOwnsList(child, list)) return true;
    }
  }
  return false;
}

/// Переместить блок в слот [slot] перед позицией [index].
///
/// Возвращает false, если блок нельзя перенести (нет в дереве или слот
/// лежит внутри него самого) — тогда дерево не меняется.
bool moveBlockToSlot({
  required VisualScriptBlock block,
  required List<VisualScriptBlock> roots,
  required ScratchListSlot slot,
  required int index,
}) {
  final loc = locateBlockInTree(block.id, roots);
  if (loc == null) return false;
  if (blockOwnsList(block, slot.list)) return false;

  // Индекс слота посчитан по раскладке до удаления. В том же списке блок
  // стоит выше цели — после `removeAt` цель сдвигается на один вверх.
  var target = index;
  if (identical(loc.list, slot.list) && loc.index < target) target -= 1;

  loc.list.removeAt(loc.index);
  slot.list.insert(target.clamp(0, slot.list.length), block);
  return true;
}