// «Не сохраняет, когда устанавливаю печать при первом выходе» — у текста,
// которого в ноде ещё нет.
//
// Создание текста и редактирование готового текста шли двумя разными путями.
// Редактирование (`item_editor_helper`) переносило выбор из markdown-редактора
// в айтем, а `ContentEditorLogic.addText` собирал новый `ContentItem` из
// text/fontFamily/textSize и молча терял `textReveal`/`revealSpeed`. То есть
// «Печать», выбранная при создании, исчезала сразу; со второго раза (та же
// кнопка, но уже по готовому тексту) настройка оставалась.

import 'package:canvas_app/features/editor/screens/node_content/content_editor_logic.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Доезжает ли выбор из редактора до созданного айтема.
  Future<ContentItem?> createWithReveal(
    WidgetTester tester,
    String chipLabel,
  ) async {
    ContentItem? created;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    created = await ContentEditorLogic(
                      context: context,
                      questId: 'quest-1',
                      currentNodeId: 'n1',
                    ).addText();
                  },
                  child: const Text('создать текст'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('создать текст'));
    await tester.pumpAndSettle();

    // Оформление texta вынесено из-под поля ввода в отдельную панель.
    await tester.tap(find.byTooltip('Оформление текста'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(chipLabel));
    await tester.pump();
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    // Единственный выход из редактора — стрелка «Закрыть и сохранить».
    await tester.tap(find.byTooltip('Закрыть и сохранить'));
    await tester.pumpAndSettle();
    return created;
  }

  testWidgets('новый текст попадает в ноду до закрытия вкладки', (
    WidgetTester tester,
  ) async {
    final drafts = <ContentItem>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    await ContentEditorLogic(
                      context: context,
                      questId: 'quest-1',
                      currentNodeId: 'n1',
                    ).createItemByType('text', onDraft: drafts.add);
                  },
                  child: const Text('создать текст'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('создать текст'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'черновик');
    await tester.pump();

    expect(drafts, isNotEmpty, reason: 'правка уходит без «Назад»');
    expect(drafts.last.text, 'черновик');

    await tester.tap(find.byTooltip('Закрыть и сохранить'));
    await tester.pumpAndSettle();
  });

  testWidgets('«Печать» при создании текста не теряется', (
    WidgetTester tester,
  ) async {
    final item = await createWithReveal(tester, 'Печать');

    expect(item, isNotNull, reason: 'редактор должен вернуть новый айтем');
    expect(
      item!.textReveal,
      'typewriter',
      reason:
          'addText собирал ContentItem без textReveal — выбор редактора '
          'умирал на первом выходе',
    );
  });

  testWidgets('«Плавно» при создании текста не теряется', (
    WidgetTester tester,
  ) async {
    final item = await createWithReveal(tester, 'Плавно');

    expect(item, isNotNull);
    expect(item!.textReveal, 'fade');
  });

  testWidgets('невыбранный режим остаётся «без анимации» и не пишет поля', (
    WidgetTester tester,
  ) async {
    final item = await createWithReveal(tester, 'Без анимации');

    expect(item, isNotNull);
    expect(item!.textReveal, 'none');
    // Дефолт в JSON не пишется — иначе у каждого текста квеста плодится поле.
    expect(item.toJson().containsKey('textReveal'), isFalse);
  });
}
