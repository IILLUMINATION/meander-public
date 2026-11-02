import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/save_operation_block_widget.dart';

void main() {
  test('save-блок переживает JSON и понимает все операции', () {
    final load = SaveOperationBlock.fromJson({
      'type': 'save_operation',
      'id': 's1',
      'operation': 'load',
      'slotName': 'слот {герой}',
    });
    expect(load.operation, SaveOperation.load);
    expect(load.slotName, 'слот {герой}');
    expect(load.toJson()['type'], 'save_operation');

    final delete = SaveOperationBlock.fromJson({
      'type': 'save_operation',
      'operation': 'delete',
    });
    expect(delete.operation, SaveOperation.delete);
  });

  testWidgets('в блоке можно выбрать действие и видно поле слота', (
    tester,
  ) async {
    final block = SaveOperationBlock(operation: SaveOperation.save);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SaveOperationBlockWidget(block: block, questId: 'q1'),
        ),
      ),
    );

    expect(find.text('Создать сохранение'), findsOneWidget);
    expect(find.text('Слот'), findsOneWidget);
    expect(find.text('пусто — имя по умолчанию'), findsOneWidget);

    await tester.tap(find.text('Создать сохранение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Открыть сохранения'));
    await tester.pumpAndSettle();

    expect(block.operation, SaveOperation.open);
    expect(find.text('Слот'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}