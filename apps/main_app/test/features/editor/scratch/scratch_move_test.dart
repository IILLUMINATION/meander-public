import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_layout.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_move.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';

/// Перенос блока на канвасе — единственная операция, которая меняет дерево
/// без виджета-редактора, поэтому правила переноса проверяются отдельно.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engine = ScratchLayoutEngine();

  ScratchListSlot slotOf(ScratchLayout layout, String key) =>
      layout.slots.firstWhere((s) => s.key == key);

  /// Корень больше не слот раскладки (у свободного канваса нет геометрии
  /// корневого списка), но перенос «после корневого блока» строится так же.
  ScratchListSlot rootSlot(List<VisualScriptBlock> roots, ScratchLayout layout) {
    return ScratchListSlot(
      key: 'root',
      list: roots,
      rect: Rect.zero,
    )..rows.addAll(
        layout.rows.where(
          (r) => r.kind == ScratchRowKind.head && identical(r.ownerList, roots),
        ),
      );
  }

  test('перенос вниз внутри списка не теряет блок и не сдвигает соседа', () {
    final a = DelayBlock();
    final b = DelayBlock();
    final c = DelayBlock();
    final roots = <VisualScriptBlock>[a, b, c];
    final layout = engine.layout(roots);

    // Бросок A в разрыв после C: индекс по раскладке = 3.
    final moved = moveBlockToSlot(
      block: a,
      roots: roots,
      slot: rootSlot(roots, layout),
      index: 3,
    );

    expect(moved, isTrue);
    expect(roots.map((r) => r.id), [b.id, c.id, a.id]);
  });

  test('перенос вверх ставит блок на запрошенную позицию', () {
    final a = DelayBlock();
    final b = DelayBlock();
    final c = DelayBlock();
    final roots = <VisualScriptBlock>[a, b, c];
    final layout = engine.layout(roots);

    expect(
      moveBlockToSlot(
        block: c,
        roots: roots,
        slot: rootSlot(roots, layout),
        index: 0,
      ),
      isTrue,
    );
    expect(roots.map((r) => r.id), [c.id, a.id, b.id]);
  });

  test('перенос в ветку условия', () {
    final condition = ConditionBlock();
    final wait = DelayBlock();
    final roots = <VisualScriptBlock>[condition, wait];
    final layout = engine.layout(roots);

    expect(
      moveBlockToSlot(
        block: wait,
        roots: roots,
        slot: slotOf(layout, '${condition.id}:0'),
        index: 0,
      ),
      isTrue,
    );
    expect(roots.map((r) => r.id), [condition.id]);
    expect(condition.thenBlocks.map((r) => r.id), [wait.id]);
  });

  test('событие нельзя бросить в собственную ветку', () {
    final inner = DelayBlock();
    final event = EventBlock(children: [inner]);
    final outside = DelayBlock();
    final roots = <VisualScriptBlock>[event, outside];
    final layout = engine.layout(roots);

    expect(
      moveBlockToSlot(
        block: event,
        roots: roots,
        slot: slotOf(layout, '${event.id}:0'),
        index: 0,
      ),
      isFalse,
    );
    expect(event.children.map((r) => r.id), [inner.id]);
    expect(roots.map((r) => r.id), [event.id, outside.id]);
  });

  test('вложенный блок можно поднять в корень', () {
    final inner = DelayBlock();
    final event = EventBlock(children: [inner]);
    final roots = <VisualScriptBlock>[event];
    final layout = engine.layout(roots);

    expect(
      moveBlockToSlot(
        block: inner,
        roots: roots,
        slot: rootSlot(roots, layout),
        index: 1,
      ),
      isTrue,
    );
    expect(event.children, isEmpty);
    expect(roots.map((r) => r.id), [event.id, inner.id]);
  });

  test('чужой блок (не из этого дерева) не переносится', () {
    final roots = <VisualScriptBlock>[DelayBlock()];
    final layout = engine.layout(roots);

    expect(
      moveBlockToSlot(
        block: DelayBlock(),
        roots: roots,
        slot: rootSlot(roots, layout),
        index: 0,
      ),
      isFalse,
    );
    expect(roots, hasLength(1));
  });
}
