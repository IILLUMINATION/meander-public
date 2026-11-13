// Редактор формул: фигурные скобки в палитре и живая подсказка о незакрытой
// скобке. Регресс: `{`/`}` в палитре не было вовсе, а незакрытая скобка
// проходила молча — движок возвращал null без объяснения.

import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _openEditor(WidgetTester tester, {String value = ''}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: ExpressionEditorScreen(initialValue: value, questId: 'q'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('в палитре «Логика» есть фигурные скобки', (tester) async {
    await _openEditor(tester);
    await tester.tap(find.widgetWithText(Tab, 'Логика'));
    await tester.pumpAndSettle();

    expect(find.text('{'), findsOneWidget);
    expect(find.text('}'), findsOneWidget);
  });

  testWidgets('незакрытая скобка видна под полем', (tester) async {
    await _openEditor(tester, value: '{{Оружие["Картинка"][Оружие]}');

    expect(find.textContaining('Не закрыта'), findsOneWidget);
  });

  testWidgets('справка объясняет адресацию таблицы и кавычки', (
    tester,
  ) async {
    await _openEditor(tester);

    await tester.tap(find.byTooltip('Как писать формулы'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ячейка таблицы'), findsOneWidget);
    expect(
      find.textContaining('внутри кавычек'),
      findsOneWidget,
      reason: 'главная причина пустых значений: ["{переменная}"]',
    );
  });

  testWidgets('корректная формула не показывает ошибку', (tester) async {
    await _openEditor(tester, value: '{{Оружие["Картинка"][Оружие]}}');

    expect(find.textContaining('Не закрыта'), findsNothing);
  });
}