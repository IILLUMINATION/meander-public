import 'dart:convert';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';

/// Сигнатура скрипта для сравнения «грязный/чистый» в автосейве.
///
/// Имя + содержимое блоков в порядке обхода дерева. Содержимое берём хэшем
/// `toJson()`: правка значения (`значение` у присвоения, `source` у смены
/// картинки, номер перехода) не меняет ни id, ни структуру дерева, поэтому
/// сигнатура только по id считала скрипт чистым — автосейв не срабатывал, и
/// правка терялась при выходе с экрана.
///
/// Хэш, а не полный JSON: аллокация ограничена размером одного блока, а не
/// всего сценария (раньше здесь экономили именно на `jsonEncode` целиком).
String scriptSignatureOf({
  required String name,
  required List<VisualScriptBlock> blocks,
}) {
  final buf = StringBuffer(name);
  void walk(List<VisualScriptBlock> list) {
    for (final block in list) {
      buf
        ..write('|')
        ..write(block.id)
        ..write(':')
        ..write(jsonEncode(block.toJson()).hashCode);
      for (final nested in block.nestedBlockLists) {
        walk(nested);
      }
    }
  }

  walk(blocks);
  return buf.toString();
}