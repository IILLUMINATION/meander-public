import 'package:canvas_app/features/editor/screens/visual_script_editor/name_conflicts.dart';
import 'package:flutter_test/flutter_test.dart';

/// Переменные и таблицы делят одно пространство имён формул: коллизия ломает
/// `table_cell(имя, …)` и путает переименование. Проверка обязана ловить её
/// без учёта регистра и пробелов.
void main() {
  test('свободное имя не конфликтует', () {
    expect(conflictingName('Урон', ['HP', 'Оружие']), isNull);
  });

  test('точное совпадение конфликтует', () {
    expect(conflictingName('Оружие', ['HP', 'Оружие']), 'Оружие');
  });

  test('регистр не спасает от коллизии', () {
    expect(conflictingName('оружие', ['Оружие']), 'Оружие');
  });

  test('пробелы вокруг имени срезаются', () {
    expect(conflictingName('  HP ', ['HP']), 'HP');
  });

  test('переименование в себя (и смену регистра) пропускаем', () {
    expect(conflictingName('Оружие', ['Оружие', 'HP'], ignore: 'Оружие'), isNull);
    expect(conflictingName('ОРУЖИЕ', ['Оружие'], ignore: 'Оружие'), isNull);
  });

  test('пустое имя не конфликтует', () {
    expect(conflictingName('   ', ['HP']), isNull);
  });

  test('пустые имена в списке занятых игнорируются', () {
    expect(conflictingName('HP', ['', '  ']), isNull);
  });
}