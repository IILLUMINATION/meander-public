import 'dart:math' as math;
import 'package:flutter/painting.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';

import 'scratch_block_view.dart';

/// Геометрия канваса блоков.
///
/// Значения — в мировых пикселях (до зума). Блоки стыкуются почти вплотную,
/// как в Scratch: стек читается как одна колонка, а не как список карточек.
class ScratchMetrics {
  ScratchMetrics._();

  static const double headHeight = 40;
  static const double headRadius = 8;

  /// Подъём «шляпы» события над обычной шапкой.
  static const double hatRise = 8;

  /// Скругление выреза C-формы: внутренние углы тела ветки.
  static const double bodyRadius = 6;

  /// Паз/шип стыковки блоков — как в Scratch, но чуть мельче: канвас
  /// показывает дерево плотнее одного стека.
  static const double notchWidth = 10;
  static const double notchDepth = 4;
  static const double notchInset = 14;

  static const double padH = 12;
  static const double indent = 20;
  static const double gap = 0;
  static const double branchLabelHeight = 22;
  static const double branchGap = 4;
  static const double tailHeight = 12;
  static const double emptyHeight = 30;
  static const double emptyWidth = 170;
  static const double rootGap = 34;
  static const double chipHeight = 22;
  static const double chipPadH = 8;
  static const double chipGap = 6;
  static const double chipRadius = 4;
  static const double minChipWidth = 28;
  static const double captionLineHeight = 16;

  /// Радиус прилипания к блоку/стеку, мировые пиксели (как SNAP_RADIUS в
  /// Blockly из scratch-blocks: 48 экранных, но у нас плотнее).
  static const double snapRadius = 34;

  static const TextStyle titleStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w700,
    height: 1.15,
  );
  static const TextStyle valueStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  static const TextStyle captionStyle = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    height: 1.15,
  );
  static const TextStyle branchLabelStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
  );

  /// Высота шапки блока: у события добавлен подъём шляпы.
  static double headHeightFor(VisualScriptBlock block) =>
      headHeight + (block is EventBlock ? hatRise : 0.0);
}

/// Измерение текста с кэшем.
///
/// Раскладка тысячи блоков измеряет тысячи строк, но подписи повторяются
/// («Ждать», «Перейти к ноде», «При запуске ноды»). Без кэша каждый пересчёт
/// дерева заново гонял бы TextPainter на каждую строку и на каждый чипс.
class ScratchTextMeter {
  final Map<String, double> _widths = {};
  final Map<String, int> _lines = {};

  double width(String text, TextStyle style, {required int styleKey}) {
    if (text.isEmpty) return 0;
    final key = '$styleKey\u0000$text';
    final cached = _widths[key];
    if (cached != null) return cached;
    if (_widths.length > 4000) _widths.clear();
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final w = painter.width;
    painter.dispose();
    _widths[key] = w;
    return w;
  }

  int lineCount(
    String text,
    TextStyle style,
    double maxWidth, {
    required int styleKey,
  }) {
    final key = '$styleKey\u0000${maxWidth.round()}\u0000$text';
    final cached = _lines[key];
    if (cached != null) return cached;
    if (_lines.length > 2000) _lines.clear();
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    final n = math.max(1, painter.computeLineMetrics().length);
    painter.dispose();
    _lines[key] = n;
    return n;
  }
}

enum ScratchRowKind { head, branchLabel, empty }

/// Строка раскладки: шапка блока, подпись ветки или пустая ветка.
///
/// `tail` отдельной строкой не нужен: хвост C-блока рисуется его frame'ом.
class ScratchRow {
  const ScratchRow({
    required this.block,
    required this.kind,
    required this.rect,
    required this.depth,
    this.ownerList,
    this.index = 0,
    this.label,
    this.branchKey,
  });

  final VisualScriptBlock block;
  final ScratchRowKind kind;
  final Rect rect;

  /// Уровень вложенности: по нему считаются отступ и цвет подписи ветки.
  final int depth;

  /// Список, в котором лежит блок, и его индекс — для вставки и drop.
  final List<VisualScriptBlock>? ownerList;
  final int index;

  /// Подпись ветки или текст пустой ветки.
  final String? label;

  /// Ключ ветки (`<id>:<номер>`) — по нему painter и drop находят одну ветку.
  final String? branchKey;
}

/// Контейнер (событие, условие, цикл, кроссфейд): его C-форма и вырез тела.
class ScratchContainerFrame {
  const ScratchContainerFrame({
    required this.block,
    required this.rect,
    required this.body,
    required this.depth,
  });

  final VisualScriptBlock block;

  /// Полный прямоугольник C-блока, включая хвост.
  final Rect rect;

  /// Вырез: сюда попадает тело (дети). Правая граница выходит за frame —
  /// C-форма открыта справа, как в Scratch.
  final Rect body;

  final int depth;
}

/// Слот вставки: список-владелец и его область в мире.
class ScratchListSlot {
  ScratchListSlot({required this.key, required this.list, required this.rect});

  final String key;
  final List<VisualScriptBlock> list;

  /// Пересчитывается после размещения: у корня границы известны только
  /// когда разложены все блоки.
  Rect rect;
  final List<ScratchRow> rows = [];
}

/// Готовая раскладка дерева: что рисовать и куда можно бросить блок.
class ScratchLayout {
  ScratchLayout({
    required this.rows,
    required this.frames,
    required this.slots,
    required this.size,
    required this.bounds,
  });

  final List<ScratchRow> rows;
  final List<ScratchContainerFrame> frames;
  final List<ScratchListSlot> slots;

  /// Полный размер дерева в мире (совпадает с [bounds].size).
  final Size size;

  /// Границы дерева в мире. У свободно расставленных корней верх может быть
  /// отрицательным, поэтому вписывать в экран нужно по bounds, а не по size.
  final Rect bounds;

  static final ScratchLayout empty = ScratchLayout(
    rows: const [],
    frames: const [],
    slots: const [],
    size: Size.zero,
    bounds: Rect.zero,
  );

  /// Строки, пересекающие видимую область. Ряды отсортированы по `top`,
  /// поэтому начало находится бинарным поиском, а не полным проходом:
  /// на дереве в 1000 блоков это разница между 20 и 1000 вызовами painter'а.
  List<ScratchRow> visibleRows(Rect view) {
    if (rows.isEmpty) return const [];
    // Ряды отсортированы по `top`. Ищем первый, который может попасть в вид,
    // и отступаем назад: при свободной расстановке высокий ряд может начаться
    // выше и всё ещё пересекаться с видом, хотя его `top` меньше.
    var lo = 0;
    var hi = rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (rows[mid].rect.top < view.top) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) lo -= 1;
    while (lo > 0 && rows[lo - 1].rect.bottom >= view.top) {
      lo -= 1;
    }
    final result = <ScratchRow>[];
    for (var i = lo; i < rows.length; i++) {
      final row = rows[i];
      if (row.rect.top > view.bottom) break;
      if (row.rect.overlaps(view)) result.add(row);
    }
    return result;
  }

  /// Блок под точкой (шапка, подпись ветки или пустая ветка).
  ScratchRow? rowAt(Offset point) {
    for (final row in rows) {
      if (row.rect.top > point.dy) break;
      if (row.rect.contains(point)) return row;
    }
    return null;
  }

  /// Слот под точкой: самый узкий из содержащих её — вложенная ветка
  /// приоритетнее события, внутри которого она лежит.
  ScratchListSlot? slotAt(Offset point) {
    ScratchListSlot? best;
    for (final slot in slots) {
      if (point.dx < slot.rect.left - 6 || point.dx > slot.rect.right + 6) {
        continue;
      }
      if (point.dy < slot.rect.top - 8 || point.dy > slot.rect.bottom + 8) {
        continue;
      }
      if (best == null || slot.rect.width < best.rect.width) best = slot;
    }
    return best;
  }

  /// Индекс вставки в слоте для координаты [y].
  int insertIndexIn(ScratchListSlot slot, double y) {
    for (final row in slot.rows) {
      if (y < row.rect.center.dy) return row.index;
    }
    return slot.list.length;
  }

  /// Блок, который можно взять и потащить: только шапка.
  ///
  /// В Scratch блок тянется за себя, а вырез C-формы — пустое место, за
  /// которое тянется канвас. Иначе контейнер «прилипал» бы к пальцу при
  /// попытке прокрутить пустоту внутри ветки.
  VisualScriptBlock? blockAt(Offset point) {
    final row = rowAt(point);
    if (row == null || row.kind != ScratchRowKind.head) return null;
    return row.block;
  }

  /// Верхний левый угол шапки блока (для «схватить за точку» при перетаскивании).
  Rect? headRectOf(String blockId) {
    for (final row in rows) {
      if (row.kind == ScratchRowKind.head && row.block.id == blockId) {
        return row.rect;
      }
    }
    return null;
  }
}

/// Раскладывает дерево блоков в плоский список прямоугольников.
///
/// Два прохода: сначала меряем ширину/высоту поддеревьев, потом расставляем
/// позиции. Иначе не получить Scratch-поведение «блок растёт в ширину под
/// вложенность»: ширина контейнера зависит от детей, а дети должны встать
/// внутри уже известного frame.
class ScratchLayoutEngine {
  ScratchLayoutEngine({ScratchTextMeter? meter})
    : _meter = meter ?? ScratchTextMeter();

  final ScratchTextMeter _meter;

  // Кэши живут один вызов [layout]: дерево между кадрами не меняется, а
  // пересчёт после правки обязан видеть новые значения полей.
  final Map<Object, _Measure> _listMeasures = Map<Object, _Measure>.identity();
  final Map<VisualScriptBlock, double> _blockWidths = Map.identity();
  final Map<VisualScriptBlock, double> _blockHeights = Map.identity();

  /// Разложить корневые блоки.
  ///
  /// [origins] — свободные позиции корней (`id → верхний левый угол`), как в
  /// Scratch: каждый стек живёт там, где его оставил автор. Корни без позиции
  /// (только что загруженный скрипт) встают колонкой вниз от нуля.
  ScratchLayout layout(
    List<VisualScriptBlock> blocks, {
    Map<String, Offset> origins = const {},
  }) {
    _listMeasures.clear();
    _blockWidths.clear();
    _blockHeights.clear();

    final rows = <ScratchRow>[];
    final frames = <ScratchContainerFrame>[];
    final slots = <ScratchListSlot>[];

    var autoY = 0.0;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final height = blockHeight(block);
      final origin = origins[block.id];
      // Слот корня не нужен: у свободного канваса нет «корневого списка» с
      // геометрией. Стек ловится прилипанием, а пустое место — свободный
      // сброс (см. экран).
      _placeBlock(
        block: block,
        index: i,
        list: blocks,
        x: origin?.dx ?? 0,
        y: origin?.dy ?? autoY,
        depth: 0,
        rows: rows,
        frames: frames,
        slots: slots,
        slot: null,
      );
      if (origin == null) autoY += height + ScratchMetrics.rootGap;
    }

    Rect? bounds;
    for (final row in rows) {
      bounds = bounds == null ? row.rect : bounds.expandToInclude(row.rect);
    }
    for (final frame in frames) {
      bounds = bounds == null ? frame.rect : bounds.expandToInclude(frame.rect);
    }

    // Свободные позиции ломают порядок обхода, а painter и hit-test ищут
    // бинарным поиском по `top`. Сортируем один раз здесь.
    rows.sort((a, b) {
      final byTop = a.rect.top.compareTo(b.rect.top);
      return byTop != 0 ? byTop : a.rect.left.compareTo(b.rect.left);
    });

    final box = bounds ?? Rect.zero;
    return ScratchLayout(
      rows: rows,
      frames: frames,
      slots: slots,
      size: box.size,
      bounds: box,
    );
  }

  /// Ширина шапки блока без учёта детей.
  double headWidth(VisualScriptBlock block) {
    final view = scratchViewOf(block);
    var w =
        ScratchMetrics.padH +
        _meter.width(view.title, ScratchMetrics.titleStyle, styleKey: 1);
    for (final value in view.values) {
      w +=
          ScratchMetrics.chipGap +
          math.max(
            ScratchMetrics.minChipWidth,
            _meter.width(value, ScratchMetrics.valueStyle, styleKey: 2) +
                ScratchMetrics.chipPadH * 2,
          );
    }
    w += ScratchMetrics.padH;
    return w;
  }

  /// Ширина блока: у контейнера — максимум из шапки и тела с отступом.
  /// Именно это даёт «рост в ширину» при вложенности.
  double blockWidth(VisualScriptBlock block) {
    final cached = _blockWidths[block];
    if (cached != null) return cached;
    final own = headWidth(block);
    final branches = scratchBranchesOf(block);
    var width = own;
    if (branches.isNotEmpty) {
      var childrenWidth = 0.0;
      for (final branch in branches) {
        childrenWidth = math.max(childrenWidth, _measure(branch.blocks).width);
      }
      // Событие — шляпа со стеком под ней: дети стоят в той же колонке и
      // своего отступа не получают (в Scratch это не C-форма).
      width = block is EventBlock
          ? math.max(own, childrenWidth)
          : math.max(
              own,
              ScratchMetrics.indent + childrenWidth + ScratchMetrics.padH,
            );
    }
    _blockWidths[block] = width;
    return width;
  }

  double blockHeight(VisualScriptBlock block) {
    final cached = _blockHeights[block];
    if (cached != null) return cached;
    final branches = scratchBranchesOf(block);
    var height = ScratchMetrics.headHeightFor(block);
    if (block is EventBlock) {
      // Дети приклеены прямо под шляпой, без зазоров и хвоста.
      if (branches.isNotEmpty) height += _measure(branches.first.blocks).height;
      _blockHeights[block] = height;
      return height;
    }
    if (branches.isNotEmpty) {
      height += ScratchMetrics.branchGap;
      for (final branch in branches) {
        if (branch.label != null) height += ScratchMetrics.branchLabelHeight;
        final m = _measure(branch.blocks);
        height += m.height == 0 ? ScratchMetrics.emptyHeight : m.height;
        height += ScratchMetrics.branchGap;
      }
      height += ScratchMetrics.tailHeight;
    }
    _blockHeights[block] = height;
    return height;
  }

  /// Ширина и высота списка как стека. Кэш по identity списка: модель хранит
  /// вложенные списки объектами, и один и тот же список меряется несколько
  /// раз (ширина контейнера + высота + раскладка).
  _Measure _measure(List<VisualScriptBlock> list) {
    if (list.isEmpty) return const _Measure(0, 0);
    final cached = _listMeasures[list];
    if (cached != null) return cached;
    var width = 0.0;
    var height = 0.0;
    for (var i = 0; i < list.length; i++) {
      final block = list[i];
      width = math.max(width, blockWidth(block));
      height += blockHeight(block);
      if (i != list.length - 1) height += ScratchMetrics.gap;
    }
    final measure = _Measure(width, height);
    _listMeasures[list] = measure;
    return measure;
  }

  void _placeBlock({
    required VisualScriptBlock block,
    required int index,
    required List<VisualScriptBlock> list,
    required double x,
    required double y,
    required int depth,
    required List<ScratchRow> rows,
    required List<ScratchContainerFrame> frames,
    required List<ScratchListSlot> slots,
    required ScratchListSlot? slot,
  }) {
    final width = blockWidth(block);
    final isHat = block is EventBlock;
    final headHeight = ScratchMetrics.headHeightFor(block);
    // Шляпа события не растягивается под ширину детей: в Scratch она своя и
    // стоит в колонке над стеком.
    final rowWidth = isHat ? headWidth(block) : width;
    final row = ScratchRow(
      block: block,
      kind: ScratchRowKind.head,
      rect: Rect.fromLTWH(x, y, rowWidth, headHeight),
      depth: depth,
      ownerList: list,
      index: index,
      branchKey: slot?.key,
    );
    rows.add(row);
    slot?.rows.add(row);

    final branches = scratchBranchesOf(block);
    if (branches.isEmpty) return;

    if (isHat) {
      final children = branches.first.blocks;
      final childSlot = ScratchListSlot(
        key: '${block.id}:0',
        list: children,
        rect: Rect.fromLTRB(
          x,
          y + headHeight,
          x + math.max(width, ScratchMetrics.emptyWidth),
          y + headHeight + ScratchMetrics.emptyHeight,
        ),
      );
      slots.add(childSlot);
      var childY = y + headHeight;
      for (var i = 0; i < children.length; i++) {
        final child = children[i];
        _placeBlock(
          block: child,
          index: i,
          list: children,
          x: x,
          y: childY,
          depth: depth + 1,
          rows: rows,
          frames: frames,
          slots: slots,
          slot: childSlot,
        );
        childY += blockHeight(child) + ScratchMetrics.gap;
      }
      // У пустого события строк нет, но зона броска под шляпой нужна: слот
      // остаётся, даже когда детей нет.
      childSlot.rect = Rect.fromLTRB(
        x,
        y + headHeight,
        x + math.max(width, ScratchMetrics.emptyWidth),
        math.max(childY, y + headHeight + ScratchMetrics.emptyHeight),
      );
      return;
    }

    final frame = Rect.fromLTRB(x, y, x + width, y + blockHeight(block));
    frames.add(
      ScratchContainerFrame(
        block: block,
        rect: frame,
        body: Rect.fromLTRB(
          x + ScratchMetrics.indent,
          y + headHeight + ScratchMetrics.branchGap,
          frame.right,
          frame.bottom - ScratchMetrics.tailHeight,
        ),
        depth: depth,
      ),
    );

    var branchY = y + headHeight + ScratchMetrics.branchGap;
    for (var b = 0; b < branches.length; b++) {
      final branch = branches[b];
      final key = '${block.id}:$b';
      final branchRect = Rect.fromLTRB(
        x + ScratchMetrics.indent,
        branchY,
        x + width - ScratchMetrics.padH / 2,
        branchY +
            (branch.label != null ? ScratchMetrics.branchLabelHeight : 0) +
            (_measure(branch.blocks).height == 0
                ? ScratchMetrics.emptyHeight
                : _measure(branch.blocks).height),
      );
      final branchSlot = ScratchListSlot(
        key: key,
        list: branch.blocks,
        rect: branchRect,
      );
      slots.add(branchSlot);

      if (branch.label != null) {
        rows.add(
          ScratchRow(
            block: block,
            kind: ScratchRowKind.branchLabel,
            rect: Rect.fromLTWH(
              x + ScratchMetrics.indent + ScratchMetrics.padH / 2,
              branchY,
              math.max(
                0,
                width - ScratchMetrics.indent - ScratchMetrics.padH * 1.5,
              ),
              ScratchMetrics.branchLabelHeight,
            ),
            depth: depth + 1,
            label: branch.label,
            branchKey: key,
          ),
        );
        branchY += ScratchMetrics.branchLabelHeight;
      }

      final measure = _measure(branch.blocks);
      if (branch.blocks.isEmpty) {
        rows.add(
          ScratchRow(
            block: block,
            kind: ScratchRowKind.empty,
            rect: Rect.fromLTWH(
              x + ScratchMetrics.indent,
              branchY,
              math.min(
                ScratchMetrics.emptyWidth,
                math.max(
                  80,
                  width - ScratchMetrics.indent - ScratchMetrics.padH,
                ),
              ),
              ScratchMetrics.emptyHeight,
            ),
            depth: depth + 1,
            label: tr('перетащите блоки сюда'),
            branchKey: key,
          ),
        );
        branchY += ScratchMetrics.emptyHeight;
      } else {
        var childY = branchY;
        for (var i = 0; i < branch.blocks.length; i++) {
          final child = branch.blocks[i];
          final childHeight = blockHeight(child);
          _placeBlock(
            block: child,
            index: i,
            list: branch.blocks,
            x: x + ScratchMetrics.indent,
            y: childY,
            depth: depth + 1,
            rows: rows,
            frames: frames,
            slots: slots,
            slot: branchSlot,
          );
          childY += childHeight + ScratchMetrics.gap;
        }
        branchY += measure.height;
      }
      branchY += ScratchMetrics.branchGap;
    }
  }
}

class _Measure {
  const _Measure(this.width, this.height);
  final double width;
  final double height;
}
