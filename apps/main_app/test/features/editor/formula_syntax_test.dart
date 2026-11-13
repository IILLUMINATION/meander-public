import 'package:canvas_app/features/editor/screens/visual_script_editor/formula_syntax.dart';
import 'package:flutter_test/flutter_test.dart';

/// Регресс с живой ошибки: `{{Оружие["Картинка"][Оружие]}` — внешняя `{{`
/// закрыта одной `}`, движок возвращает null, картинка не меняется,
/// и понять это по интерфейсу было нельзя.
void main() {
  test('незакрытая внешняя скобка ловится', () {
    expect(formulaSyntaxError('{{Оружие["Картинка"][Оружие]}'), isNotNull);
  });

  test('корректная формула с таблицей проходит', () {
    expect(formulaSyntaxError('{{Оружие["Картинка"][Оружие]}}'), isNull);
  });

  test('скобки в кавычках — данные, а не синтаксис', () {
    expect(formulaSyntaxError('{Оружие["Урон"]["{Оружие}"]}'), isNull);
    expect(formulaSyntaxError('"{{ не скобки }}"'), isNull);
  });

  test('экранированная кавычка не закрывает литерал', () {
    expect(formulaSyntaxError(r'"a\"b"'), isNull);
  });

  test('незакрытая кавычка ловится', () {
    expect(formulaSyntaxError('upper("abc)'), isNotNull);
  });

  test('лишняя закрывающая скобка ловится', () {
    expect(formulaSyntaxError('1 + 2}'), isNotNull);
  });

  test('нарушенный порядок скобок ловится', () {
    expect(formulaSyntaxError('([)]'), isNotNull);
  });

  test('обычная арифметика и текст без скобок проходят', () {
    expect(formulaSyntaxError('{HP} + 5'), isNull);
    expect(formulaSyntaxError('random(1, 100)'), isNull);
    expect(formulaSyntaxError(''), isNull);
    expect(formulaSyntaxError('   '), isNull);
  });
}