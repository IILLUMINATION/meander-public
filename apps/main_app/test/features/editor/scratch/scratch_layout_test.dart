import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_layout.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';

/// Раскладка канваса скриптов.
///
/// Проверяем не пиксели, а правила, на которых держится Scratch-поведение:
/// ширина блока растёт под вложенность, видимые строки отсекаются бинарным
/// поиском, а слот вставки у вложенной ветки приоритетнее родительского.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engine = ScratchLayoutEngine();

  group('ширина растёт под вложенность', () {
    test('вложенный блок шире шапки растягивает контейнер', () {
      // C-форма: ширина = max(шапка, отступ + дети). Короткий ребёнок в
      // шапку влезает, длинный — нет; второй случай и есть «рост в ширину».
      final wide = DelayBlock(
        expression: 'очень длинное выражение задержки на минуту и ещё немного',
      );
      final short = DelayBlock(expression: '1');

      final narrowParent = engine.layout([
        ConditionBlock(thenBlocks: [short]),
      ]);
      final wideParent = engine.layout([
        ConditionBlock(thenBlocks: [wide]),
      ]);

      expect(
        wideParent.size.width,
        greaterThan(narrowParent.size.width),
      );
      final outerRow = wideParent.rows.first;
      final innerRow = wideParent.rows.firstWhere((r) => r.block.id == wide.id);
      expect(innerRow.rect.left, greaterThan(outerRow.rect.left));
      expect(innerRow.rect.right, lessThanOrEqualTo(outerRow.rect.right));
    });

    test('стек события: дети в одной колонке со шляпой', () {
      final child = DelayBlock(
        expression: 'очень длинное выражение задержки на минуту и ещё немного',
      );
      final event = EventBlock(children: [child]);
      final layout = engine.layout([event]);

      final head = layout.headRectOf(event.id)!;
      final row = layout.rows.firstWhere((r) => r.block.id == child.id);
      expect(row.rect.left, head.left, reason: 'в Scratch стек не сдвинут');
      expect(row.rect.top, head.bottom);
      expect(layout.frames, isEmpty, reason: 'событие — шляпа, а не C-форма');
      expect(layout.size.width, greaterThan(head.width));
    });

    test('два уровня вложенности шире одного', () {
      final shallow = engine.layout([
        EventBlock(children: [ConditionBlock(thenBlocks: [DelayBlock()])]),
      ]);
      final deep = engine.layout([
        EventBlock(
          children: [
            ConditionBlock(
              thenBlocks: [
                WhileBlock(children: [DelayBlock()]),
              ],
            ),
          ],
        ),
      ]);
      expect(deep.size.width, greaterThan(shallow.size.width));
    });

    test('длинная подпись увеличивает ширину шапки, но не высоту', () {
      final short = engine.layout([DelayBlock(expression: '1')]);
      final long = engine.layout([
        DelayBlock(expression: 'очень длинное выражение задержки на минуту'),
      ]);
      expect(long.size.width, greaterThan(short.size.width));
      expect(long.size.height, short.size.height);
    });

    test('свёрнутый контейнер не раскладывает тело', () {
      final child = DelayBlock();
      final block = EventBlock(children: [child], collapsed: true);
      final layout = engine.layout([block]);

      expect(layout.rows.any((r) => r.block.id == child.id), isFalse);
      expect(
        layout.size.height,
        ScratchMetrics.headHeightFor(block),
        reason: 'свёрнутый контейнер — плоская шапка',
      );
      expect(layout.frames, isEmpty);
      expect(layout.slots, isEmpty, reason: 'у корня нет слота: канвас свободный');
    });

    test('пустая ветка занимает место и получает слот', () {
      final block = ConditionBlock();
      final layout = engine.layout([block]);
      final empty = layout.rows.where((r) => r.kind == ScratchRowKind.empty);
      expect(empty.length, 2, reason: 'then и else');
      expect(layout.slots.length, 2, reason: 'по слоту на ветку, корень — не слот');
    });
  });

  group('видимая область', () {
    final blocks = [for (var i = 0; i < 200; i++) DelayBlock()];
    final layout = engine.layout(blocks);

    test('возвращает только пересекающиеся строки, столько же, сколько полный проход',
        () {
      final view = const Rect.fromLTWH(0, 500, 300, 200);
      final visible = layout.visibleRows(view);
      final bruteForce = layout.rows.where((r) => r.rect.overlaps(view)).toList();

      expect(visible.length, lessThan(layout.rows.length));
      expect(visible.map((r) => r.block.id), bruteForce.map((r) => r.block.id));
    });

    test('сортировка строк по вертикали монотонна (бинарный поиск корректен)', () {
      for (var i = 1; i < layout.rows.length; i++) {
        expect(
          layout.rows[i].rect.top,
          greaterThanOrEqualTo(layout.rows[i - 1].rect.top),
          reason: 'строка $i нарушила порядок',
        );
      }
    });

    test('область вне дерева не даёт строк', () {
      expect(
        layout.visibleRows(
          Rect.fromLTWH(0, layout.size.height + 100, 300, 100),
        ),
        isEmpty,
      );
    });
  });

  group('слоты и вставка', () {
    test('слот вложенной ветки приоритетнее корневого', () {
      final child = DelayBlock();
      final block = ConditionBlock(thenBlocks: [child]);
      final layout = engine.layout([block]);

      final childRow = layout.rows.firstWhere((r) => r.block.id == child.id);
      final slot = layout.slotAt(childRow.rect.center);
      expect(slot, isNotNull);
      expect(slot!.key, '${block.id}:0');
      expect(slot.list, same(block.thenBlocks));
    });

    test('индекс вставки считается по середине строк', () {
      final first = DelayBlock();
      final second = DelayBlock();
      final layout = engine.layout([first, second]);
      final root = ScratchListSlot(
        key: 'root',
        list: layout.rows.first.ownerList!,
        rect: Rect.zero,
      )..rows.addAll(layout.rows.where((r) => r.kind == ScratchRowKind.head));

      final firstRow = layout.rows.firstWhere((r) => r.block.id == first.id);
      expect(layout.insertIndexIn(root, firstRow.rect.top - 100), 0);
      expect(layout.insertIndexIn(root, firstRow.rect.bottom + 1), 1);
      expect(
        layout.insertIndexIn(root, layout.size.height + 100),
        root.list.length,
      );
    });

    test('rowAt находит шапку и возвращает null вне строк', () {
      final child = DelayBlock();
      final block = ConditionBlock(thenBlocks: [child]);
      final layout = engine.layout([block]);
      final frame = layout.frames.single;

      expect(
        layout.rowAt(frame.rect.topLeft + const Offset(10, 10))?.block.id,
        block.id,
      );
      // Хвост C-формы — часть контейнера, но не строка списка.
      expect(
        layout.rowAt(
          Offset(frame.rect.left + 5, frame.rect.bottom - ScratchMetrics.tailHeight / 2),
        ),
        isNull,
      );
    });
  });

  group('свободные позиции корней', () {
    test('origin ставит стек в точку, корни без origin идут колонкой', () {
      final a = DelayBlock();
      final b = DelayBlock();
      final layout = engine.layout(
        [a, b],
        origins: {a.id: const Offset(400, 120)},
      );

      final aRow = layout.rows.firstWhere((r) => r.block.id == a.id);
      final bRow = layout.rows.firstWhere((r) => r.block.id == b.id);
      expect(aRow.rect.topLeft, const Offset(400, 120));
      // У b origin нет — он встаёт в автоматическую колонку от нуля.
      expect(bRow.rect.left, 0);
      expect(bRow.rect.top, 0);
      expect(layout.bounds.left, 0);
      expect(layout.bounds.right, greaterThanOrEqualTo(400 + aRow.rect.width));
    });

    test('bounds учитывают отрицательные координаты', () {
      final a = DelayBlock();
      final layout = engine.layout(
        [a],
        origins: {a.id: const Offset(-300, -200)},
      );
      expect(layout.bounds.left, -300);
      expect(layout.bounds.top, -200);
      expect(layout.size, layout.bounds.size);
    });

    test('строки отсортированы по вертикали даже при свободных позициях', () {
      final blocks = <VisualScriptBlock>[
        for (var i = 0; i < 30; i++) DelayBlock(),
      ];
      final origins = {
        for (var i = 0; i < blocks.length; i++)
          blocks[i].id: Offset((i % 5) * 300, (i % 3) * 400),
      };
      final layout = engine.layout(blocks, origins: origins);
      for (var i = 1; i < layout.rows.length; i++) {
        expect(
          layout.rows[i - 1].rect.top,
          lessThanOrEqualTo(layout.rows[i].rect.top),
        );
      }
    });

    test('blockAt хватает блок только за шапку', () {
      final child = DelayBlock();
      final event = EventBlock(children: [child]);
      final layout = engine.layout([event]);

      final head = layout.headRectOf(event.id)!;
      expect(layout.blockAt(head.center)?.id, event.id);
      expect(layout.blockAt(layout.headRectOf(child.id)!.center)?.id, child.id);
      // Под шляпой сразу начинается ребёнок: это его шапка, не событие.
      expect(
        layout.blockAt(head.bottomCenter + const Offset(0, 12))?.id,
        child.id,
      );
      // Пустая зона правее всей ширины стека — не блок.
      final childHead = layout.headRectOf(child.id)!;
      expect(
        layout.blockAt(Offset(childHead.right + 10, childHead.top + 12)),
        isNull,
      );
    });

    test('C-форма: тело ветки не хватается как блок', () {
      final condition = ConditionBlock(thenBlocks: [DelayBlock()]);
      final layout = engine.layout([condition]);
      final frame = layout.frames.single;
      expect(
        layout.blockAt(Offset(frame.rect.left + 4, frame.rect.bottom - 6)),
        isNull,
      );
    });
  });

  group('тысяча блоков', () {
    test('раскладывается за один проход и не теряет строк', () {
      final blocks = <VisualScriptBlock>[
        for (var i = 0; i < 50; i++)
          EventBlock(children: [for (var j = 0; j < 19; j++) DelayBlock()]),
      ];
      final watch = Stopwatch()..start();
      final layout = engine.layout(blocks);
      watch.stop();

      expect(layout.rows.length, 1000);
      expect(watch.elapsedMilliseconds, lessThan(2000));
      expect(layout.size.height, greaterThan(0));
    });
  });
}
