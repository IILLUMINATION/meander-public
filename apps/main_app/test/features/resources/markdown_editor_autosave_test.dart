// Вкладка редактора текста не должна требовать «Назад» ради сохранения:
// каждая правка сразу уходит родительской вкладке через onChanged.

import 'package:canvas_app/features/resources/screens/markdown_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('текст уходит в onChanged без закрытия редактора', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MarkdownEditorScreen(
          initialText: 'старый',
          questId: 'q-text',
          onChanged: (result) => changes.add(result.text),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'новый');
    await tester.pump();

    expect(changes, isNotEmpty);
    expect(changes.last, 'новый');
  });

  testWidgets('без onChanged редактор работает как раньше', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MarkdownEditorScreen(initialText: 'текст', questId: 'q-text'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'другой');
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
