import 'package:canvas_app/features/resources/screens/data/table_editor_screen.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Подтаблицы в ячейке: создание, спуск/подъём по ярусам и сохранение.
/// Негативный контроль — обычная карта в ячейке (`{foo: bar}`) не должна
/// притворяться таблицей: значок и пункт «Открыть» появляются только у
/// структур `{columns: [...], rows: [...]}`.
void main() {
  QuestTable rootTable() => QuestTable(
        name: 'Тест',
        columns: const ['A', 'B'],
        rows: [
          {'A': '1', 'B': 'x'},
          {'A': '2', 'B': 'y'},
        ],
      );

  testWidgets('создать подтаблицу в ячейке, отредактировать и вернуться',
      (tester) async {
    QuestTable? saved;
    await tester.pumpWidget(MaterialApp(
      home: TableEditorScreen(
        table: rootTable(),
        questId: 'nested',
        onSave: (t) => saved = t,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('x'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Заменить на вложенную таблицу'));
    await tester.pumpAndSettle();

    expect(find.text('Заменить значение вложенной таблицей?'), findsOneWidget);
    await tester.tap(find.text('Заменить'));
    await tester.pumpAndSettle();

    // Мы внутри подтаблицы: свой заголовок и свои столбцы.
    expect(find.text('Подтаблица'), findsWidgets);
    expect(find.text('Столбец 1'), findsOneWidget);
    expect(find.text('Столбец 2'), findsOneWidget);

    // Номер строки выбирает ячейку A1 подтаблицы, дальше обычная формула-бар.
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'внутри');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Применить'));
    await tester.pumpAndSettle();
    // Значение видно и в ячейке, и в строке формулы.
    expect(find.text('внутри'), findsWidgets);

    await tester.tap(find.byTooltip('На уровень выше'));
    await tester.pumpAndSettle();

    // В родителе ячейка показывает значок подтаблицы.
    expect(find.text('Таблица 2×1'), findsOneWidget);

    // Повторный вход: тап по ячейке → строка формулы → открыть.
    await tester.tap(find.text('Таблица 2×1'));
    // У ячейки есть onDoubleTap, поэтому одиночный тап подтверждается
    // только после окна распознавания двойного.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Вложенная таблица в ячейке'), findsOneWidget);
    await tester.tap(find.text('Вложенная таблица в ячейке'));
    await tester.pumpAndSettle();
    expect(find.text('внутри'), findsOneWidget);

    await tester.tap(find.byTooltip('На уровень выше'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Сохранить'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    final cell = saved!.rows[0]['B'];
    expect(cell, isA<Map>());
    final nested = QuestTable.nestedFromValue(cell);
    expect(nested, isNotNull);
    expect(nested!.columns, ['Столбец 1', 'Столбец 2']);
    expect(nested.rows.single['Столбец 1'], 'внутри');
    // Родительская сетка не изменилась в остальных ячейках.
    expect(saved!.rows[0]['A'], '1');
    expect(saved!.rows[1]['B'], 'y');
  });

  testWidgets('подтаблица из сохранённого JSON открывается и не теряется',
      (tester) async {
    QuestTable? saved;
    final table = QuestTable(
      name: 'Тест',
      columns: const ['A'],
      rows: [
        {
          'A': {
            'name': 'Тест.A1',
            'columns': ['Товар', 'Цена'],
            'rows': [
              {'Товар': 'хлеб', 'Цена': '40'},
            ],
            'data': {'валюта': '₽'},
          },
        },
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: TableEditorScreen(
        table: table,
        questId: 'nested-json',
        onSave: (t) => saved = t,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Таблица 2×1'), findsOneWidget);

    await tester.tap(find.text('Таблица 2×1'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Вложенная таблица в ячейке'));
    await tester.pumpAndSettle();

    expect(find.text('Товар'), findsOneWidget);
    expect(find.text('Цена'), findsOneWidget);
    expect(find.text('хлеб'), findsOneWidget);

    await tester.tap(find.byTooltip('На уровень выше'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Сохранить'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    final nested = QuestTable.nestedFromValue(saved!.rows[0]['A']);
    expect(nested, isNotNull);
    expect(nested!.rows.single['Товар'], 'хлеб');
    expect(nested.data['валюта'], '₽');
  });

  testWidgets('обычная карта в ячейке — не подтаблица', (tester) async {
    final table = QuestTable(
      name: 'Тест',
      columns: const ['A'],
      rows: [
        {
          'A': {'foo': 'bar'},
        },
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: TableEditorScreen(
        table: table,
        questId: 'not-a-table',
        onSave: (t) {},
      ),
    ));
    await tester.pumpAndSettle();

    // Значение показано текстом, значка подтаблицы нет.
    expect(find.textContaining('foo'), findsOneWidget);
    expect(find.textContaining('Таблица '), findsNothing);

    await tester.longPress(find.textContaining('foo'));
    await tester.pumpAndSettle();
    expect(find.text('Открыть вложенную таблицу'), findsNothing);
    expect(find.text('Заменить на вложенную таблицу'), findsOneWidget);
  });
}
