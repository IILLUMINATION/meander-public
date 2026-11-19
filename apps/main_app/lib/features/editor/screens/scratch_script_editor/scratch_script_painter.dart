import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:canvas_app/shared/canvas/canvas_grid_painter.dart';

import 'scratch_block_shape.dart';
import 'scratch_block_view.dart';
import 'scratch_camera.dart';
import 'scratch_layout.dart';

/// Цвет значения внутри блока. В Scratch поле — белая плашка с тёмным
/// текстом; на цветном корпусе она читается как поле, а не как ещё один
/// заголовок, и это единственный светлый элемент в блоке.
const Color _fieldFill = Color(0xFFFFFFFF);
const Color _fieldFg = Color(0xFF3D3D3D);

/// Кэш TextPainter'ов для painter'а.
///
/// Живёт в State экрана, а не в painter'е: painter пересоздаётся на каждый
/// rebuild (смена выделения, темы), а текст блоков между кадрами один и тот
/// же. Без кэша панорама дерева в 1000 блоков переразложила бы весь видимый
/// текст на каждом кадре.
class ScratchPaintCache {
  final Map<String, TextPainter> _painters = {};

  TextPainter painter(String text, TextStyle style, {required int styleKey}) {
    if (text.isEmpty) return _empty;
    final key = '$styleKey\u0000$text';
    final cached = _painters[key];
    if (cached != null) return cached;
    if (_painters.length > 3000) _painters.clear();
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _painters[key] = painter;
    return painter;
  }

  static final TextPainter _empty = TextPainter(
    text: const TextSpan(text: ''),
    textDirection: TextDirection.ltr,
  )..layout();
}

/// Рисует дерево блоков на канвасе.
///
/// Всё дерево — один CustomPaint: 1000 виджетов с тенью и текст-стилями
/// Flutter не тянет, а painter рисует только то, что попало в видимую
/// область. Камера подписана через `repaint`, поэтому пан и зум не вызывают
/// rebuild экрана.
class ScratchScriptPainter extends CustomPainter {
  ScratchScriptPainter({
    required this.layout,
    required this.camera,
    required this.cache,
    required this.colorScheme,
    required this.brightness,
    this.selectedId,
    this.dropLine,
    this.emptyHint,
    this.hiddenIds = const {},
    this.ghostBlock,
    this.ghostRect,
  }) : super(repaint: camera);

  final ScratchLayout layout;
  final ScratchCameraController camera;
  final ScratchPaintCache cache;
  final ColorScheme colorScheme;
  final Brightness brightness;

  /// Выделенный блок — светлая обводка по силуэту.
  final String? selectedId;

  /// Линия места вставки при перетаскивании (в мировых координатах).
  final Rect? dropLine;

  /// Что показать, если блоков нет.
  final String? emptyHint;

  /// Блоки, которые сейчас «в руке»: их оригиналы не рисуются, чтобы не
  /// было двух копий одного блока.
  final Set<String> hiddenIds;

  /// Призрак перетаскиваемого блока (как `dragSurface` в Scratch).
  final VisualScriptBlock? ghostBlock;
  final Rect? ghostRect;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = colorScheme.surfaceDim;
    canvas.drawRect(Offset.zero & size, background);

    CanvasGridPainter.paint(
      canvas,
      offset: camera.offset,
      scale: camera.scale,
      screenSize: size,
      color: colorScheme.outlineVariant.withValues(
        alpha: brightness == Brightness.dark ? 0.16 : 0.28,
      ),
    );

    if (layout.rows.isEmpty && emptyHint != null) {
      final painter = cache.painter(
        emptyHint!,
        TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14),
        styleKey: 9,
      );
      painter.paint(
        canvas,
        size.center(Offset.zero) -
            Offset(painter.width / 2, painter.height / 2),
      );
      return;
    }

    final view = camera.visibleWorldRect(size).inflate(40 / camera.scale);

    canvas.save();
    canvas.translate(camera.offset.dx, camera.offset.dy);
    canvas.scale(camera.scale);

    _paintFrames(canvas, view);
    _paintRows(canvas, view);
    // Шипы стыковки рисуются последними: они должны лежать поверх блока
    // ниже, иначе соседняя строка закрашивает стык и блоки выглядят
    // нарезанными полосками.
    _paintTabs(canvas, view);
    _paintGhost(canvas);
    _paintSelection(canvas);
    _paintDropLine(canvas);

    canvas.restore();
  }

  // ── Контейнеры ───────────────────────────────────────────────────

  void _paintFrames(Canvas canvas, Rect view) {
    for (final frame in layout.frames) {
      if (!frame.rect.overlaps(view)) continue;
      if (hiddenIds.contains(frame.block.id)) continue;
      final accent = blockAccent(brightness, frame.block.category);
      canvas.drawPath(
        ScratchShape.container(frame.rect, frame.body),
        Paint()..color = accent,
      );
    }
  }

  void _paintCollapsedBadge(Canvas canvas, VisualScriptBlock block, Rect head) {
    final count = _nestedCount(block);
    if (count == 0) return;
    final text = _countLabel(count);
    final painter = cache.painter(
      text,
      const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: _fieldFg,
      ),
      styleKey: 5,
    );
    final centerY = ScratchShape.textCenterY(head, block);
    final rect = Rect.fromLTWH(
      head.right - painter.width - 24,
      centerY - 10,
      painter.width + 14,
      20,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(10)),
      Paint()..color = _fieldFill.withValues(alpha: 0.92),
    );
    painter.paint(
      canvas,
      Offset(rect.left + 7, rect.center.dy - painter.height / 2),
    );
  }

  int _nestedCount(VisualScriptBlock block) {
    var count = 0;
    for (final list in block.nestedBlockLists) {
      for (final child in list) {
        count += 1 + _nestedCount(child);
      }
    }
    return count;
  }

  String _countLabel(int count) => trf('{p0} внутри', {'p0': count});

  // ── Строки ───────────────────────────────────────────────────────

  void _paintRows(Canvas canvas, Rect view) {
    for (final row in layout.visibleRows(view)) {
      if (hiddenIds.contains(row.block.id)) continue;
      switch (row.kind) {
        case ScratchRowKind.head:
          _paintHead(canvas, row);
        case ScratchRowKind.branchLabel:
          _paintBranchLabel(canvas, row);
        case ScratchRowKind.empty:
          _paintEmptyBranch(canvas, row);
      }
    }
  }

  /// Есть ли у блока C-тело (ветки с отступом). У события дети — это стек
  /// под шляпой, поэтому шип снизу у него остаётся.
  bool _hasCBody(VisualScriptBlock block) =>
      block is! EventBlock &&
      scratchIsCollapsible(block) &&
      !scratchIsCollapsed(block);

  void _paintHead(Canvas canvas, ScratchRow row) {
    final block = row.block;
    final accent = blockAccent(brightness, block.category);
    final path = ScratchShape.headOf(
      block,
      row.rect,
      bottomTab: !_hasCBody(block),
    );
    canvas.drawPath(path, Paint()..color = accent);

    if (scratchIsCollapsible(block) && scratchIsCollapsed(block)) {
      _paintCollapsedBadge(canvas, block, row.rect);
    }

    final view = scratchViewOf(block);
    final centerY = ScratchShape.textCenterY(row.rect, block);
    var x = row.rect.left + ScratchMetrics.padH;

    final title = cache.painter(
      view.title,
      ScratchMetrics.titleStyle.copyWith(color: blockFg),
      styleKey: 1,
    );
    title.paint(canvas, Offset(x, centerY - title.height / 2));
    x += title.width;

    for (final value in view.values) {
      x += ScratchMetrics.chipGap;
      x = _paintChip(canvas, x, centerY, value);
    }
  }

  double _paintChip(Canvas canvas, double x, double centerY, String value) {
    final painter = cache.painter(
      value,
      ScratchMetrics.valueStyle.copyWith(color: _fieldFg),
      styleKey: 2,
    );
    final width = math.max(
      ScratchMetrics.minChipWidth,
      painter.width + ScratchMetrics.chipPadH * 2,
    );
    final rect = Rect.fromLTWH(
      x,
      centerY - ScratchMetrics.chipHeight / 2,
      width,
      ScratchMetrics.chipHeight,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(ScratchMetrics.chipRadius),
    );
    canvas.drawRRect(rrect, Paint()..color = _fieldFill);
    if (painter.width + ScratchMetrics.chipPadH * 2 > width) {
      canvas.save();
      canvas.clipRRect(rrect);
    }
    painter.paint(
      canvas,
      Offset(rect.left + ScratchMetrics.chipPadH, centerY - painter.height / 2),
    );
    if (painter.width + ScratchMetrics.chipPadH * 2 > width) canvas.restore();
    return x + width;
  }

  /// Шипы стыковки поверх всех блоков: нижний блок не должен закрашивать
  /// шип верхнего.
  void _paintTabs(Canvas canvas, Rect view) {
    for (final frame in layout.frames) {
      if (!frame.rect.overlaps(view)) continue;
      if (hiddenIds.contains(frame.block.id)) continue;
      final accent = blockAccent(brightness, frame.block.category);
      final tab = ScratchShape.tabRect(frame.rect);
      canvas.drawPath(
        Path()..addRRect(
          RRect.fromRectAndRadius(
            tab,
            Radius.circular(ScratchMetrics.notchDepth),
          ),
        ),
        Paint()..color = accent,
      );
    }
    for (final row in layout.visibleRows(view)) {
      if (row.kind != ScratchRowKind.head) continue;
      if (hiddenIds.contains(row.block.id)) continue;
      if (_hasCBody(row.block)) continue;
      final accent = blockAccent(brightness, row.block.category);
      final tab = ScratchShape.tabRect(row.rect);
      canvas.drawPath(
        Path()..addRRect(
          RRect.fromRectAndRadius(
            tab,
            Radius.circular(ScratchMetrics.notchDepth),
          ),
        ),
        Paint()..color = accent,
      );
    }
  }

  /// Призрак блока под курсором: так автор видит, что именно тащит, даже
  /// когда блок большой и палец закрывает его.
  void _paintGhost(Canvas canvas) {
    final block = ghostBlock;
    final rect = ghostRect;
    if (block == null || rect == null) return;
    final accent = blockAccent(brightness, block.category);
    final path = ScratchShape.headOf(block, rect, bottomTab: !_hasCBody(block));
    canvas.drawShadow(path, Colors.black54, 8, false);
    canvas.drawPath(path, Paint()..color = accent.withValues(alpha: 0.92));

    final showsBody =
        _hasCBody(block) ||
        (block is EventBlock && !block.collapsed && block.children.isNotEmpty);
    if (showsBody) {
      // Тело призрака — контур: точную C-форму даёт только настоящая
      // раскладка (её у перетаскиваемого блока может ещё не быть).
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect,
          const Radius.circular(ScratchMetrics.headRadius),
        ),
        Paint()
          ..color = accent.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    final head = Rect.fromLTWH(
      rect.left,
      rect.top,
      rect.width,
      ScratchShape.headHeight(block),
    );
    final view = scratchViewOf(block);
    final centerY = ScratchShape.textCenterY(head, block);
    var x = head.left + ScratchMetrics.padH;
    final title = cache.painter(
      view.title,
      ScratchMetrics.titleStyle.copyWith(color: blockFg),
      styleKey: 1,
    );
    title.paint(canvas, Offset(x, centerY - title.height / 2));
    x += title.width;
    for (final value in view.values) {
      x += ScratchMetrics.chipGap;
      x = _paintChip(canvas, x, centerY, value);
    }
  }

  void _paintBranchLabel(Canvas canvas, ScratchRow row) {
    final painter = cache.painter(
      row.label ?? '',
      // Подпись ветки лежит в вырезе C-формы, то есть на фоне канваса, а не
      // на цветном корпусе: белый здесь не читается в светлой теме.
      ScratchMetrics.branchLabelStyle.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
      styleKey: 3,
    );
    painter.paint(
      canvas,
      Offset(row.rect.left, row.rect.center.dy - painter.height / 2),
    );
  }

  void _paintEmptyBranch(Canvas canvas, ScratchRow row) {
    final painter = cache.painter(
      row.label ?? '',
      ScratchMetrics.branchLabelStyle.copyWith(
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        fontWeight: FontWeight.w600,
      ),
      styleKey: 4,
    );
    painter.paint(
      canvas,
      Offset(row.rect.left, row.rect.center.dy - painter.height / 2),
    );
  }

  // ── Выделение и drop ─────────────────────────────────────────────

  void _paintSelection(Canvas canvas) {
    final id = selectedId;
    if (id == null) return;
    Rect? target;
    for (final row in layout.rows) {
      if (row.kind == ScratchRowKind.head && row.block.id == id) {
        target = row.rect;
        break;
      }
    }
    if (target == null) return;
    final block = layout.rows
        .firstWhere((r) => r.kind == ScratchRowKind.head && r.block.id == id)
        .block;
    canvas.drawPath(
      ScratchShape.headOf(block, target, bottomTab: !_hasCBody(block)),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  void _paintDropLine(Canvas canvas) {
    final line = dropLine;
    if (line == null) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(line, const Radius.circular(2)),
      Paint()..color = Colors.white.withValues(alpha: 0.95),
    );
    canvas.drawCircle(
      Offset(line.left + 3, line.center.dy),
      3.5,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(ScratchScriptPainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.selectedId != selectedId ||
        oldDelegate.dropLine != dropLine ||
        oldDelegate.ghostBlock != ghostBlock ||
        oldDelegate.ghostRect != ghostRect ||
        !setEquals(oldDelegate.hiddenIds, hiddenIds) ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.brightness != brightness;
  }
}
