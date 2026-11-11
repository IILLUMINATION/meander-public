// Пикер переменной/ячейки таблицы должен вставлять ровно одну пару скобок.
// Двойная обёртка `{{…}}` ломала сырые поля вроде источника блока
// «Сменить картинку»: движок не находил адрес и оставлял текст вместо пути.

import 'package:canvas_app/features/editor/screens/visual_script_editor/variable_selection_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bracedVariableToken', () {
    test('переменная оборачивается в скобки', () {
      expect(bracedVariableToken('Картинка'), '{Картинка}');
    });

    test('ссылка на ячейку уже в скобках — не оборачиваем второй раз', () {
      const cellRef = '{Оружие["Картинка"][2]}';
      expect(bracedVariableToken(cellRef), cellRef);
      expect(bracedVariableToken('  $cellRef  '), cellRef);
    });

    test('вложенные скобки внутри адреса не мешают', () {
      const cellRef = r'{Оружие["Картинка"]["{Оружие}"]}';
      expect(bracedVariableToken(cellRef), cellRef);
    });
  });
}