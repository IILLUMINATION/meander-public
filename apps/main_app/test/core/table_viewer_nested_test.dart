import 'package:canvas_app/features/game/screens/table_viewer_screen.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Просмотр таблицы игроком: подтаблица в ячейке открывается отдельным
/// экраном и возвращает назад. Обычная карта в ячейке — просто JSON-текст.
void main() {
  testWidgets('подтаблица открывается тапом и закрывается назад',
      (tester) async {
    final table = QuestTable(
      name: 'Тест',
      columns: const ['A', 'B'],
      rows: [
        {
          'A': '1',
          'B': {
            'name': 'Тест.B1',
            'columns': ['Товар', 'Цена'],
            'rows': [
              {'Товар': 'хлеб', 'Цена': '40'},
            ],
            'data': <String, dynamic>{},
          },
        },
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: TableViewerScreen(tableName: 'Тест', table: table),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Таблица 2×1'), findsOneWidget);

    await tester.tap(find.text('Таблица 2×1'));
    await tester.pumpAndSettle();

    // Внутри — свои столбцы и значения.
    expect(find.text('Товар'), findsOneWidget);
    expect(find.text('Цена'), findsOneWidget);
    expect(find.textContaining('хлеб'), findsOneWidget);
    expect(find.textContaining('Тест.B1'), findsWidgets);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Таблица 2×1'), findsOneWidget);
  });

  testWidgets('обычная карта в ячейке остаётся JSON-текстом', (tester) async {
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
      home: TableViewerScreen(tableName: 'Тест', table: table),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('"foo"'), findsOneWidget);
    expect(find.textContaining('Таблица '), findsNothing);
  });
}
