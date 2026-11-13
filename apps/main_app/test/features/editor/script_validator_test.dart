import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_validator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Проверка перед выходом из редактора: незаполненные обязательные поля и
/// коллизия «переменная называется как таблица» — ровно та пара, из-за
/// которой `table_cell(Оружие, …)` молча возвращала null.
void main() {
  EventBlock scriptWith(List<VisualScriptBlock> children) => EventBlock(
    id: 'ev-1',
    eventType: EventType.onDataChange,
    children: children,
  );

  List<String> messagesOf(
    List<VisualScriptBlock> blocks, {
    Set<String> tables = const {},
  }) =>
      validateScriptBlocks(
        blocks,
        tables: tables,
      ).map((issue) => issue.message).toList();

  test('корректный скрипт не даёт замечаний', () {
    final messages = messagesOf([
      scriptWith([
        AssignVariableBlock(
          id: 'a-1',
          variableName: 'Урон',
          value: '{{Оружие["Урон"][Оружие]}}',
        ),
        SetImageBlock(id: 'i-1', itemId: 'item-1', source: 'res/x.webp'),
      ]),
    ]);

    expect(messages, isEmpty);
  });

  test('пустые обязательные поля попадают в отчёт с id блока', () {
    final issues = validateScriptBlocks([
      scriptWith([
        AssignVariableBlock(id: 'a-1', variableName: '', value: ''),
        SetImageBlock(id: 'i-1', source: ''),
        GoToNodeBlock(id: 'g-1'),
        ConditionBlock(id: 'c-1', expression: ''),
      ]),
    ]);
    final byBlock = <String, List<String>>{};
    for (final issue in issues) {
      (byBlock[issue.blockId] ??= []).add(issue.message);
    }

    expect(byBlock.keys, containsAll(['a-1', 'i-1', 'g-1', 'c-1']));
    expect(byBlock['a-1']!.join(' '), contains('переменная'));
    expect(byBlock['i-1']!.join(' '), contains('объект'));
    expect(byBlock['g-1']!.join(' '), contains('нода'));
    expect(byBlock['c-1']!.join(' '), contains('условие'));
  });

  test('переменная с именем таблицы отмечена отдельно', () {
    final messages = messagesOf([
      scriptWith([
        AssignVariableBlock(id: 'a-1', variableName: 'Оружие', value: '1'),
      ]),
    ], tables: {'Оружие'});

    expect(messages.single, contains('таблица'));
  });

  test('вложенные блоки тоже проверяются', () {
    final messages = messagesOf([
      scriptWith([
        WhileBlock(
          id: 'w-1',
          expression: 'true',
          children: [GoToNodeBlock(id: 'g-1')],
        ),
      ]),
    ]);

    expect(messages, isNotEmpty);
  });

  test('кривой синтаксис формулы попадает в отчёт', () {
    final messages = messagesOf([
      scriptWith([
        AssignVariableBlock(
          id: 'a-1',
          variableName: 'Урон',
          value: '{{Оружие["Урон"][Оружие]}',
        ),
      ]),
    ]);

    expect(messages.single, contains('Не закрыта'));
  });

  test('событие без типа — проблема', () {
    final messages = messagesOf([EventBlock(id: 'ev-1')]);

    expect(messages, isNotEmpty);
  });
}