// Общий редактор поста: один экран на стену сообщества и канал.
//
// Контракт, который нельзя терять при унификации: пустой текст не
// отправляется, «Отправить» уходит ровно с набранным текстом, а пост
// закрывает экран только после успешной отправки — при ошибке набранное
// остаётся в поле.

import 'package:canvas_app/shared/compose/post_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpEditor(
    WidgetTester tester, {
    required Future<bool> Function(String text) onSubmit,
    String? initialText,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: PostEditorScreen(
          onSubmit: onSubmit,
          initialText: initialText ?? '',
        ),
      ),
    );
  }

  testWidgets('пустой текст не отправляется', (tester) async {
    final sent = <String>[];
    await pumpEditor(
      tester,
      onSubmit: (text) async {
        sent.add(text);
        return true;
      },
    );

    await tester.tap(find.byKey(const ValueKey('post-editor-submit')));
    await tester.pump();

    expect(sent, isEmpty);
  });

  testWidgets('текст уходит без хвостовых пробелов и закрывает экран', (
    tester,
  ) async {
    final sent = <String>[];
    await pumpEditor(
      tester,
      onSubmit: (text) async {
        sent.add(text);
        return true;
      },
    );

    await tester.enterText(
      find.byKey(const ValueKey('post-editor-field')),
      '  Привет, мир  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('post-editor-submit')));
    await tester.pumpAndSettle();

    expect(sent, ['Привет, мир']);
    // Экран ушёл: маршрут был единственным.
    expect(find.byKey(const ValueKey('post-editor-field')), findsNothing);
  });

  testWidgets('ошибка отправки оставляет текст в поле', (tester) async {
    await pumpEditor(tester, onSubmit: (_) async => false);

    await tester.enterText(
      find.byKey(const ValueKey('post-editor-field')),
      'Черновик',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('post-editor-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Черновик'), findsOneWidget);
  });

  testWidgets('предпросмотр показывает текст без markdown-разметки', (
    tester,
  ) async {
    await pumpEditor(tester, onSubmit: (_) async => true);

    await tester.enterText(
      find.byKey(const ValueKey('post-editor-field')),
      '**жирный**',
    );
    await tester.pump();
    await tester.tap(find.text('Предпросмотр'));
    await tester.pumpAndSettle();

    expect(find.textContaining('жирный'), findsWidgets);
    expect(find.text('**жирный**'), findsNothing);
  });
}