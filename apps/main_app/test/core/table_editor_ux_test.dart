import 'package:canvas_app/features/resources/screens/data/table_editor_screen.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  QuestTable makeTable() => QuestTable(
        name: 'Тест',
        columns: const ['A', 'B'],
        rows: [
          {'A': '1', 'B': 'x'},
          {'A': '2', 'B': 'y'},
        ],
        data: const {'key': 'value'},
      );

  testWidgets('cell picker: тап по ячейке возвращает {имя["колонка"][N]}',
      (tester) async {
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                picked = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TableEditorScreen(
                      table: makeTable(),
                      questId: 'picker',
                      onSave: (t) {},
                      cellPickerMode: true,
                    ),
                  ),
                );
              },
              child: const Text('открыть'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();

    expect(find.text('Выбор ячейки'), findsOneWidget);
    expect(find.text('Нажмите на ячейку, чтобы вставить ссылку на неё в текст'),
        findsOneWidget);
    expect(find.byTooltip('Сохранить'), findsNothing);
    expect(find.byTooltip('Колонка'), findsNothing);

    await tester.tap(find.text('x'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(picked, r'{Тест["B"][1]}');

    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1').last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(picked, r'{Тест["A"][1]}');
  });

  testWidgets('insert row below and move row up/down', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TableEditorScreen(
        table: makeTable(),
        questId: 'smoke',
        onSave: (t) {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 строк'), findsOneWidget);

    await tester.tap(find.text('Строка'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 строк'), findsOneWidget);

    // Меню строки — одна кнопка на строке, как в Excel mobile.
    await tester.tap(find.byTooltip('Меню строки').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переместить выше'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('y'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('B1'), findsOneWidget);

    await tester.tap(find.byTooltip('Отменить').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('3 строк'), findsOneWidget);
  });

  testWidgets('имя строки принимает скобки, кавычки и слэш', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TableEditorScreen(
        table: makeTable(),
        questId: 'rename',
        onSave: (t) {},
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Меню строки').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Имя строки…'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, r'{тест}"a\b');
    await tester.pumpAndSettle();
    // Превью адреса экранирует кавычку и слэш, но само имя остаётся как есть.
    expect(
      find.text(r'{Тест["A"]["{тест}\"a\\b"]}'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();

    // find.text совпал бы и с содержимым TextField, поэтому проверяем, что
    // диалог закрылся, а имя попало именно в подпись строки.
    expect(find.text('Имя строки 1'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && w.data == r'{тест}"a\b',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ссылка на именованную строку экранирует кавычку и слэш',
      (tester) async {
    final table = QuestTable(
      name: 'Тест',
      columns: const ['A'],
      rows: [
        {'A': '10'},
        {'A': '20'},
        {'A': '30'},
      ],
      rowNames: const ['{тест}', 'a"b', r'a\b'],
      data: const {},
    );

    Future<String?> pick(String cell) async {
      String? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  picked = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TableEditorScreen(
                        table: table,
                        questId: 'picker-named',
                        onSave: (t) {},
                        cellPickerMode: true,
                      ),
                    ),
                  );
                },
                child: const Text('открыть'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(cell));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      return picked;
    }

    expect(await pick('10'), '{Тест["A"]["{тест}"]}');
    expect(await pick('20'), r'{Тест["A"]["a\"b"]}');
    expect(await pick('30'), r'{Тест["A"]["a\\b"]}');
  });
}
