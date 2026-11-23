// #14: на Android выбор режима вставки шаблона не нажимался.
//
// Раньше после тапа по шаблону поверх bottom sheet открывался AlertDialog, и
// его барьер перехватывал тапы — «Копия» / «Связанный» не срабатывали.
// Теперь выбор режима — это шаг самого шита, без второго роута. Тест держит
// это поведение: второй роут (AlertDialog) не появляется, кнопки режима
// находятся в том же дереве и срабатывают.

import 'package:canvas_app/features/editor/providers/template_provider.dart';
import 'package:canvas_app/features/editor/widgets/template_picker_sheet.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final template = TemplateItem(
    id: 'tpl-1',
    name: 'Тест-шаблон',
    kind: TemplateKind.content,
    payload: {'id': 'i1', 'type': 'text', 'text': 'hi'},
  );

  testWidgets('режим вставки выбирается внутри шита, без AlertDialog', (
    tester,
  ) async {
    TemplatePickResult? result;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          combinedTemplatesProvider.overrideWith(
            (ref, filter) async => [template],
          ),
          questTemplatesProvider.overrideWith((ref, questId) async => [template]),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showModalBottomSheet<TemplatePickResult>(
                      context: ctx,
                      isScrollControlled: true,
                      builder: (_) => const SizedBox(
                        height: 600,
                        child: TemplatePickerSheet(
                          questId: 'q1',
                          allowLinked: true,
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Тест-шаблон'), findsOneWidget);

    // Тап по шаблону: режим спрашивается в этом же шите.
    await tester.tap(find.text('Тест-шаблон'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(FilledButton), findsNWidgets(2));
    expect(find.byType(TextButton), findsOneWidget);

    // «Отмена» возвращает к списку, ничего не выбирая.
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.text('Тест-шаблон'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(result, isNull);

    // «Связанный» (вторая кнопка режима) отдаёт результат в linked-режиме.
    await tester.tap(find.text('Тест-шаблон'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.mode, TemplatePickMode.linked);
    expect(result!.template.id, 'tpl-1');
  });
}
