// Редактор: хранилище скриптов таблицы доступно из UI.
//
// Претензия тестера — «как удалять значения из таблицы?». Причина: блок
// «Данные» работает только с `data` (ключ → значение), а редактор таблицы
// показывал лишь сетку, поэтому ключи было не видно и не достать. Проверяем
// шит ключей, шпаргалку и то, что правка ключей попадает в сохранение и в
// отмену.

import 'dart:convert';

import 'package:canvas_app/core/services/table_export_service.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/resources/screens/data/table_data_keys_sheet.dart';
import 'package:canvas_app/features/resources/screens/data/table_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/data/table_guide.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

QuestTable makeTable() => QuestTable(
  name: 'Лавка',
  columns: const ['товар', 'цена'],
  rows: [
    {'товар': 'хлеб', 'цена': '30'},
    {'товар': 'молоко', 'цена': '40'},
  ],
  data: const {'открыто': true, 'gold': 30},
);

void main() {
  test('значение разбирается как JSON, а не как текст', () {
    expect(parseTableDataValue('30'), 30);
    expect(parseTableDataValue('true'), true);
    expect(parseTableDataValue('[1, "меч"]'), [1, 'меч']);
    expect(parseTableDataValue('{"a": 1}'), {'a': 1});
    expect(parseTableDataValue('меч'), 'меч');
    expect(parseTableDataValue(''), '');
  });

  Future<void> openGuide(WidgetTester tester, {String table = 'лавка'}) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTableGuide(context, exampleTable: table),
                child: const Text('guide'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('guide'));
    await tester.pumpAndSettle();
  }

  testWidgets('шпаргалка: живая сетка, все операции и примеры', (tester) async {
    await openGuide(tester);

    expect(find.textContaining('два хранилища'), findsOneWidget);
    // Демо-сетка показывает адрес выбранной ячейки: строка с 1, столбец по
    // имени. Формат ровно тот, который принимает движок.
    // Одна и та же ссылка встречается в демо и в рецепте чтения — оба
    // должны показывать адрес, который принимает движок.
    expect(find.text('{лавка["цена"][2]}'), findsWidgets);
    expect(find.text('["цена"][2]'), findsOneWidget);
    // Хранилище ключей — отдельный адрес без колонки и строки.
    expect(find.text("{лавка['золото']}"), findsWidgets);

    // Тап по другой ячейке пересчитывает адрес: колонка и строка в демо не
    // декоративные, по ним строится путь.
    await tester.tap(find.text('7'));
    await tester.pump();
    expect(find.text('{лавка["запас"][3]}'), findsOneWidget);
    expect(find.text('["запас"][3]'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Все операции'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    for (final op in TableOperation.values) {
      expect(
        find.text(op.label),
        findsOneWidget,
        reason: 'в шпаргалке нет «${op.label}»',
      );
    }
    expect(
      find.textContaining('остальные операции — пути').evaluate().length,
      lessThanOrEqualTo(1),
    );

    await tester.scrollUntilVisible(
      find.text('Добавить тренажёр в «Мои квесты»'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Добавить тренажёр в «Мои квесты»'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> openEditor(
    WidgetTester tester,
    QuestTable table, {
    required ValueChanged<QuestTable> onSave,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TableEditorScreen(table: table, questId: 'keys', onSave: onSave),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('шит ключей: видно ключи, удаление не трогает таблицу', (
    tester,
  ) async {
    final table = makeTable();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTableDataKeysSheet(context, table: table),
                child: const Text('ключи'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ключи'));
    await tester.pumpAndSettle();

    expect(find.text('gold'), findsOneWidget);
    expect(find.text('открыто'), findsOneWidget);
    expect(find.text('да/нет'), findsOneWidget);
    expect(
      find.textContaining('Блок «Данные» и формулы видят только эти ключи'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Удалить ключ').first);
    await tester.pumpAndSettle();
    expect(find.text('gold'), findsNothing);

    expect(
      table.data.containsKey('gold'),
      isTrue,
      reason: 'до «Применить» исходная таблица не меняется',
    );

    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('шит ключей: новый ключ создаётся и уходит наружу', (
    tester,
  ) async {
    final table = makeTable();
    Map<String, dynamic>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showTableDataKeysSheet(context, table: table);
                },
                child: const Text('ключи'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ключи'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Добавить ключ'));
    await tester.pumpAndSettle();
    expect(find.text('Новый ключ'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Имя ключа'),
      'инвентарь',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Значение'),
      '["лук"]',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();

    expect(find.text('инвентарь'), findsOneWidget);
    expect(find.text('список (1)'), findsOneWidget);

    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();

    expect(result, contains('инвентарь'));
    expect(result!['инвентарь'], ['лук']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('редактор: счётчик ключей в шапке и в статусе', (tester) async {
    await openEditor(tester, makeTable(), onSave: (_) {});

    expect(find.byTooltip('Ключи скриптов: 2'), findsOneWidget);
    expect(find.textContaining('ключей скриптов: 2'), findsOneWidget);
  });

  testWidgets('редактор: удалённый ключ доезжает до onSave', (tester) async {
    QuestTable? saved;
    await openEditor(tester, makeTable(), onSave: (t) => saved = t);

    await tester.tap(find.byTooltip('Ключи скриптов: 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Удалить ключ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Ключи скриптов: 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Сохранить'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.data.containsKey('gold'), isFalse);
    expect(saved!.data['открыто'], true);
    // Сетка не пострадала.
    expect(saved!.rows.first['товар'], 'хлеб');
  });

  testWidgets('редактор: отмена шага возвращает ключ хранилища', (
    tester,
  ) async {
    await openEditor(tester, makeTable(), onSave: (_) {});

    await tester.tap(find.byTooltip('Ключи скриптов: 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Удалить ключ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ключи скриптов: 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Отменить'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Ключи скриптов: 2'), findsOneWidget);
    expect(find.textContaining('ключей скриптов: 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('редактор: «применить» без правок не плодит шагов отмены', (
    tester,
  ) async {
    await openEditor(tester, makeTable(), onSave: (_) {});

    await tester.tap(find.byTooltip('Ключи скриптов: 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();

    // Кнопка отмены появляется только когда стек непустой.
    expect(find.byTooltip('Отменить'), findsNothing);
  });

  testWidgets('шпаргалка из статуса таблицы открывается', (tester) async {
    await openEditor(tester, makeTable(), onSave: (_) {});

    await tester.tap(find.byTooltip('Как устроена таблица'));
    await tester.pumpAndSettle();

    // На телефоне шит без заголовка — проверяем содержимое.
    expect(find.textContaining('два хранилища'), findsOneWidget);
    // Секции в ленивом списке: дальше первого экрана их надо долистать.
    await tester.scrollUntilVisible(
      find.text('Все операции'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Все операции'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('CSV по формату не вмещает хранилище — JSON вмещает', () {
    // Не придуманное ограничение: поля CSV — это ряды сетки. Тест держит
    // формулировку в меню экспорта честной.
    final csv = TableExportService.tableToCsv(makeTable());
    expect(csv, contains('товар,цена'));
    expect(csv, contains('хлеб'));
    expect(csv, isNot(contains('открыто')));

    expect(jsonEncode(makeTable().toJson()), contains('открыто'));
  });

  testWidgets('меню экспорта говорит, кто забирает ключи хранилища', (
    tester,
  ) async {
    await openEditor(tester, makeTable(), onSave: (_) {});

    await tester.tap(find.byTooltip('Экспорт'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('ключи хранилища в файл не пишутся'),
      findsOneWidget,
      reason: 'иначе автор теряет хранилище молча',
    );
    expect(
      find.textContaining('сетка + отдельный лист «Данные»'),
      findsOneWidget,
    );
    expect(find.textContaining('полный слепок'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('шит ключей: вложенные ключи и элементы списков', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final table = QuestTable(
      name: 'Лавка',
      columns: const ['товар'],
      rows: [
        {'товар': 'хлеб'},
      ],
      data: {
        'персонаж': {
          'инвентарь': ['меч'],
          'опыт': 3,
        },
        'gold': 30,
      },
    );
    Map<String, dynamic>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showTableDataKeysSheet(context, table: table);
                },
                child: const Text('ключи'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ключи'));
    await tester.pumpAndSettle();

    expect(find.text('персонаж'), findsOneWidget);
    expect(find.textContaining('Ключи можно вкладывать'), findsOneWidget);

    // Раскрываем словарь персонажа и список инвентаря.
    await tester.ensureVisible(find.text('персонаж'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('персонаж'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Развернуть'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('инвентарь'), findsOneWidget);
    expect(find.text('опыт'), findsOneWidget);

    await tester.ensureVisible(find.text('инвентарь'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('инвентарь'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Развернуть'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
    expect(find.textContaining('меч'), findsOneWidget);

    // Правка элемента списка: имя не нужно, только значение.
    await tester.ensureVisible(find.text('0'));
    await tester.tap(find.text('0'));
    await tester.pumpAndSettle();
    expect(find.text('Элемент списка'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Имя ключа'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextField, 'Значение'),
      'кинжал',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('кинжал'), findsOneWidget);

    // Добавление вложенного ключа в словарь.
    await tester.ensureVisible(find.text('персонаж'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('персонаж'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Добавить вложенный ключ'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Имя ключа'),
      'уровень',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Значение'), '2');
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    // Новый ключ может оказаться ниже видимой части списка.
    await tester.drag(find.byType(ListView).last, const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(find.text('уровень'), findsOneWidget);

    // Удаление вложенного ключа.
    await tester.ensureVisible(find.text('уровень'));
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('уровень'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Удалить ключ'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('уровень'), findsNothing);

    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!['персонаж'], isA<Map>());
    expect((result!['персонаж'] as Map)['инвентарь'], ['кинжал']);
    expect((result!['персонаж'] as Map).containsKey('уровень'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('режим вставки: в шапке есть выбор ключа хранилища', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TableEditorScreen(
          table: makeTable(),
          questId: 'keys',
          onSave: (_) {},
          cellPickerMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Вставить ключ хранилища'), findsOneWidget);
    expect(find.textContaining('ключ в шапке'), findsOneWidget);
  });
}
