import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/quest_provider.dart';
import 'package:mnd_player/widgets/items/modal_item_widget.dart';

/// Модалка живёт в списке ноды, а окно — отдельным маршрутом поверх экрана.
/// Меняется нода — виджет-владелец уничтожается, и если маршрут не снять,
/// `AlertDialog` с некликабельным барьером остаётся поверх новой сцены, а его
/// кнопки уже не работают: квест дальше не играется.
void main() {
  ContentItem modalItem() => ContentItem(
    id: 'm1',
    type: 'modal',
    buttonText: 'Хранитель',
    contentMarkdown: 'Дверь заперта',
    modalButtons: const [ModalButtonConfig(id: 'b1', text: 'Понятно')],
  );

  Widget wrap({required bool show, bool allowTextCopy = false}) {
    return ProviderScope(
      overrides: [
        questProvider('q1').overrideWith(
          (ref) => Quest(id: 'q1', title: 'Тест', allowTextCopy: allowTextCopy),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: show
              ? ModalItemWidget(item: modalItem(), questId: 'q1')
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  int barriers(WidgetTester tester) =>
      find.byType(ModalBarrier).evaluate().length;

  testWidgets('модалка снимается вместе с её айтемом', (tester) async {
    // У маршрута сцены тоже есть свой невидимый барьер — отсчёт от него.
    await tester.pumpWidget(wrap(show: false));
    final withoutDialog = barriers(tester);

    await tester.pumpWidget(wrap(show: true));
    await tester.pumpAndSettle();
    expect(find.text('Дверь заперта'), findsOneWidget);
    expect(barriers(tester), greaterThan(withoutDialog));

    // Смена ноды: владельца нет в дереве, окно обязано уйти с ним — иначе
    // барьер остаётся поверх новой сцены и не пропускает тапы.
    await tester.pumpWidget(wrap(show: false));
    await tester.pumpAndSettle();
    expect(find.text('Дверь заперта'), findsNothing);
    expect(barriers(tester), withoutDialog);
  });

  testWidgets('по умолчанию текст модалки не выделяется', (tester) async {
    await tester.pumpWidget(wrap(show: true));
    await tester.pumpAndSettle();
    expect(find.text('Дверь заперта'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('автор включил копирование — текст модалки выделяется', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(show: true, allowTextCopy: true));
    await tester.pumpAndSettle();
    expect(find.text('Дверь заперта'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('закрытая кнопкой модалка не снимается второй раз', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(show: true));
    await tester.pumpAndSettle();
    final withDialog = barriers(tester);

    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
    expect(find.text('Дверь заперта'), findsNothing);
    expect(barriers(tester), lessThan(withDialog));

    // Владелец исчезает уже после закрытия — второго снятия маршрута быть не
    // должно: оно убрало бы чужой экран.
    await tester.pumpWidget(wrap(show: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
