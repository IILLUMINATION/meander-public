// Палитра функций в редакторе формул: у каждой карточки есть подпись аргументов
// (без неё список — догадки), и тап по карточке ставит шаблон в поле.

import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Список длиннее телефона, а ListView строит карточки лениво: чего не видно —
// того нет в дереве. Экран делаем завысоким, чтобы проверить весь список,
// а не тот его кусок, который влез в 600 px.
Future<void> _openFunctionsTab(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Палитра читает сохранённые раскрытые разделы: без моков плагин
  // настроек недоступен, и первый раздел открывается по умолчанию.
  SharedPreferences.setMockInitialValues({});

  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        home: ExpressionEditorScreen(initialValue: '', questId: 'q'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(Tab, 'Функции'));
  await tester.pumpAndSettle();
}

/// Разделы палитры сворачиваются (так помещается весь список), поэтому
/// перед проверкой содержимого раскрываем все, кроме открытого по умолчанию.
Future<void> _expandAllGroups(WidgetTester tester) async {
  Finder header(String title) =>
      find.descendant(of: find.byType(ListView), matching: find.text(title));
  for (final title in ['Текст', 'Логика', 'Таблицы', 'Переменные']) {
    final finder = header(title);
    if (finder.evaluate().isEmpty) continue;
    await tester.tap(finder.first);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('у новой функции видно, что она принимает', (tester) async {
    await _openFunctionsTab(tester);

    expect(find.text('Числа'), findsOneWidget, reason: 'первая секция');
    expect(
      find.textContaining('mod(a, b)'),
      findsOneWidget,
      reason: 'подпись аргументов прямо на карточке',
    );
  });

  testWidgets('все группы и их подписи на месте', (tester) async {
    await _openFunctionsTab(tester);
    await _expandAllGroups(tester);

    // «Логика» и «Текст» живут не только в заголовках секций, поэтому ищем
    // именно внутри списка функций.
    Finder header(String title) =>
        find.descendant(of: find.byType(ListView), matching: find.text(title));

    expect(header('Числа'), findsOneWidget);
    expect(header('Текст'), findsOneWidget);
    expect(header('Логика'), findsOneWidget);
    expect(header('Таблицы'), findsOneWidget);
    expect(header('Переменные'), findsOneWidget);
    expect(find.textContaining('upper(текст)'), findsOneWidget);
    expect(find.textContaining('plural(число, 1, 2-4, 5+)'), findsOneWidget);
  });

  testWidgets('тап по карточке вставляет шаблон в поле', (tester) async {
    await _openFunctionsTab(tester);

    await tester.tap(find.text('Остаток от деления'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      contains('mod(i, 3)'),
    );
  });

  testWidgets('свёрнутые разделы не занимают место в списке', (tester) async {
    await _openFunctionsTab(tester);

    // По умолчанию раскрыт только первый раздел: иначе список из сотен
    // строк не помещается и искать функцию приходится прокруткой.
    expect(find.textContaining('upper(текст)'), findsNothing);

    final header = find.descendant(
      of: find.byType(ListView),
      matching: find.text('Текст'),
    );
    await tester.tap(header.first);
    await tester.pumpAndSettle();

    expect(find.textContaining('upper(текст)'), findsOneWidget);
  });

  testWidgets('доступ к таблице документирован', (tester) async {
    await _openFunctionsTab(tester);
    await _expandAllGroups(tester);

    expect(find.text('Ячейка таблицы'), findsOneWidget);
    expect(
      find.textContaining('таблица[колонка][строка]'),
      findsOneWidget,
      reason: 'строки считаются с 1 — это надо видеть, а не помнить',
    );
    // Формула про таблицу — это не только `[колонка][строка]`.
    expect(
      find.textContaining('массив номеров; length(table_where('),
      findsOneWidget,
    );
  });

  testWidgets('группа говорит про два содержимых таблицы и про скобки', (
    tester,
  ) async {
    await _openFunctionsTab(tester);
    await _expandAllGroups(tester);

    // Ключи хранилища скриптов — вторая половина таблицы, без неё блок
    // «Данные» выглядит магическим.
    expect(find.text('Ключ хранилища скриптов'), findsOneWidget);
    expect(
      find.textContaining("лавка['ключ'] — то же хранилище"),
      findsOneWidget,
      reason: 'нет ссылки на то, что читает блок «Данные»',
    );
    // Проверено ядром: функция в {…} не вычисляется, а {ссылка + 5} теряет
    // арифметику. Без этой строки автор лечится молча теряемыми данными.
    expect(
      find.textContaining('Функцию оставляем в поле целиком'),
      findsOneWidget,
    );
  });
}
