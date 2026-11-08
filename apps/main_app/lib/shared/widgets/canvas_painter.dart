import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:canvas_app/models/canvas_lod.dart';
import 'package:canvas_app/models/canvas_models.dart';
import 'package:canvas_app/features/editor/providers/canvas_provider.dart';
import 'package:canvas_app/shared/widgets/canvas_thumbnail_cache.dart';

class InfiniteCanvasPainter extends CustomPainter {
  final CanvasState state;
  final NodeRenderer nodeRenderer;

  /// Цена кадра канваса. Инстанц живёт в `State` экрана и передаётся сюда,
  /// чтобы бюджет подписей пережил перестройку виджета.
  final CanvasFrameCost frameCost;

  /// Выключается в тестах: там реальное время сборки списка нестабильно.
  final bool measureFrame;
  final Set<String> problematicNodeIds;
  final bool showOnlyProblematic;
  final Set<ConnectionKind> visibleConnectionKinds;

  /// Миниатюры карточек: фон сцены под текстом. Художник только читает кэш,
  /// загрузку он лишь запрашивает — она асинхронная.
  final CanvasThumbnailCache? thumbnails;
  final String questId;

  // --- НОВЫЕ ПОЛЯ ДЛЯ ЛОКАЛЬНОЙ ОТРИСОВКИ (Плавность) ---
  final String? resizingGroupId;
  final Rect? temporaryGroupRect;

  final String? resizingCommentId;
  final Size? temporaryCommentSize;

  final String? movingItemId; // ID перемещаемого объекта (группа или коммент)
  final Offset?
  temporaryItemPosition; // Его временная позиция (absolute world coords)

  InfiniteCanvasPainter(
    this.state, {
    NodeRenderer? nodeRenderer,
    CanvasFrameCost? frameCost,
    this.measureFrame = true,
    this.problematicNodeIds = const <String>{},
    this.showOnlyProblematic = false,
    this.visibleConnectionKinds = const <ConnectionKind>{
      ConnectionKind.content,
      ConnectionKind.timer,
      ConnectionKind.script,
    },
    this.thumbnails,
    this.questId = '',
    this.resizingGroupId,
    this.temporaryGroupRect,
    this.resizingCommentId,
    this.temporaryCommentSize,
    this.movingItemId,
    this.temporaryItemPosition,
  }) : nodeRenderer = nodeRenderer ?? NodeRenderer(),
       frameCost = frameCost ?? CanvasFrameCost();

  @override
  void paint(Canvas canvas, Size size) {
    // Ценой кадра правим бюджет подписей: текст нод — самая дорогая часть
    // отрисовки (layout на каждую ноду), и именно он режется первым.
    final frameStopwatch = measureFrame ? (Stopwatch()..start()) : null;
    // 1. Фон
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = CanvasTheme.background,
    );
    _drawAdaptiveGrid(canvas, size);

    canvas.save();
    canvas.translate(state.offset.dx, state.offset.dy);
    canvas.scale(state.scale);

    // Видимая область (до групп — для кулла)
    final visibleRect = Rect.fromLTWH(
      -state.offset.dx / state.scale,
      -state.offset.dy / state.scale,
      size.width / state.scale,
      size.height / state.scale,
    );
    final expandedRect = visibleRect.inflate(100);
    final visibleNodes = state.spatialHash.query(expandedRect);
    final visibleNodeIds = visibleNodes.map((n) => n.id).toSet();

    // --- ГРУППЫ --- (кулл)
    for (final group in state.groups) {
      final r = group.id == resizingGroupId && temporaryGroupRect != null
          ? temporaryGroupRect!
          : group.id == movingItemId && temporaryItemPosition != null
              ? Rect.fromLTWH(temporaryItemPosition!.dx, temporaryItemPosition!.dy, group.rect.width, group.rect.height)
              : group.rect;
      if (!r.overlaps(expandedRect)) continue;
      if (group.id == resizingGroupId && temporaryGroupRect != null) {
        _drawGroup(canvas, group.copyWith(rect: temporaryGroupRect!));
      } else if (group.id == movingItemId && temporaryItemPosition != null) {
        final newRect = Rect.fromLTWH(temporaryItemPosition!.dx, temporaryItemPosition!.dy, group.rect.width, group.rect.height);
        _drawGroup(canvas, group.copyWith(rect: newRect));
      } else {
        _drawGroup(canvas, group);
      }
    }

    final bool isSearching = state.searchQuery.isNotEmpty;
    final matchingNodeIds = state.matchingNodeIds;

    // --- СВЯЗИ --- (батчинг + LOD, геометрия из провайдера)
    final isLowDetail = state.scale < 0.5;
    final kindFilteredConnections = state.connections
        .where((connection) => visibleConnectionKinds.contains(connection.kind))
        .toList();
    final visibleConnections = kindFilteredConnections.where((connection) {
      if (visibleNodeIds.contains(connection.fromNode.id) ||
          visibleNodeIds.contains(connection.toNode.id)) {
        return true;
      }
      final g = state.connectionGeometries[connection.id];
      if (g == null) return false;
      return g.bounds.overlaps(expandedRect);
    }).toList();

    // Батчинг: 1 drawPath на вид связи вместо 2* N
    if (visibleConnections.isNotEmpty) {
      final solidContent = Path();
      final solidTimer = Path();
      final solidScript = Path();
      final arrowPath = Path();
      for (final c in visibleConnections) {
        final g = state.connectionGeometries[c.id];
        if (g == null) continue;
        Path target;
        if (c.kind == ConnectionKind.timer) {
          target = solidTimer;
        } else if (c.kind == ConnectionKind.script) {
          target = solidScript;
        } else {
          target = solidContent;
        }
        if (isLowDetail) {
          target.moveTo(g.start.dx, g.start.dy);
          target.lineTo(g.end.dx, g.end.dy);
        } else {
          if (c.isVirtual) {
            // В LOD-дальности пунктир — визуальный мусор, рисуем сплошной тонкой
            target.moveTo(g.start.dx, g.start.dy);
            target.lineTo(g.end.dx, g.end.dy);
          } else {
            target.moveTo(g.start.dx, g.start.dy);
            target.cubicTo(g.cp1.dx, g.cp1.dy, g.cp2.dx, g.cp2.dy, g.end.dx, g.end.dy);
            _addArrowToPath(arrowPath, g.cp2, g.end);
          }
        }
      }
      // content — синий, timer — amber, script — violet; все 3 батча — 3 draw calls
      canvas.drawPath(
          solidContent,
          Paint()
            ..color = CanvasTheme.connectionContent
            ..style = PaintingStyle.stroke
            ..strokeWidth = isLowDetail ? 1.2 : 3);
      canvas.drawPath(
          solidScript,
          Paint()
            ..color = CanvasTheme.connectionScript
            ..style = PaintingStyle.stroke
            ..strokeWidth = isLowDetail ? 1.2 : 3);
      canvas.drawPath(
          solidTimer,
          Paint()
            ..color = CanvasTheme.connectionTimer
            ..style = PaintingStyle.stroke
            ..strokeWidth = isLowDetail ? 1.2 : 3);
      if (!isLowDetail) {
        canvas.drawPath(
            arrowPath,
            Paint()
              ..color = CanvasTheme.connectionContent
              ..style = PaintingStyle.fill);
      }
    }

    if (state.connectionMode &&
        state.connectionStartNodeId != null &&
        state.connectionPreviewEnd != null) {
      final startNode = state.nodes.firstWhere(
        (n) => n.id == state.connectionStartNodeId,
      );
      _drawConnectionPreview(canvas, startNode, state.connectionPreviewEnd!);
    }

    // --- НОДЫ --- (LOD: при отдалении падают описание/пилюли/якоря, название
    // остаётся — оно нужно для ориентира. Экономим только когда кадр не влезает:
    // подписи нормируются бюджетом из измеренной цены кадра.)
    final bool showDetails = CanvasLod.showDetails(state.scale);
    final List<({Node node, bool dimmed})> priorityTitles = [];
    final List<({Node node, bool dimmed})> otherTitles = [];
    for (final node in visibleNodes) {
      final bool isSearchDimmed =
          isSearching && !matchingNodeIds.contains(node.id);
      final bool isProblemDimmed =
          showOnlyProblematic && !problematicNodeIds.contains(node.id);
      final bool isDimmed = isSearchDimmed || isProblemDimmed;
      final bool isSelected = state.selectedNodeIds.contains(node.id);

      final thumbnailSource =
          showDetails && state.scale >= CanvasLod.thumbnailMinScale
          ? NodeRenderer.thumbnailSource(node)
          : null;
      if (thumbnailSource != null) {
        thumbnails?.ensure(questId, thumbnailSource);
      }

      nodeRenderer.drawNode(
        canvas,
        node,
        thumbnail: thumbnailSource == null
            ? null
            : thumbnails?.imageFor(thumbnailSource),
        isSelected: isSelected && !isDimmed,
        isHovered: node.id == state.hoveredNodeId && !isDimmed,
        isConnectionStart: node.id == state.connectionStartNodeId,
        isConnectionTarget:
            state.connectionMode &&
            state.connectionStartNodeId != null &&
            node.id == state.hoveredNodeId &&
            node.id != state.connectionStartNodeId &&
            !isDimmed,
        isConnectionMode: state.connectionMode,
        isDimmed: isDimmed,
        hasValidationIssue: problematicNodeIds.contains(node.id),
        allConnections: state.connections,
        showDetails: showDetails,
      );

      final bool isPriority =
          isSelected ||
          node.id == state.hoveredNodeId ||
          node.id == state.connectionStartNodeId ||
          (isSearching && matchingNodeIds.contains(node.id));
      final entry = (node: node, dimmed: isDimmed);
      if (isPriority) {
        priorityTitles.add(entry);
      } else {
        otherTitles.add(entry);
      }
    }

    // Выбранные/наведённые/попавшие в поиск подписаны в первую очередь — при
    // урезанном бюджете страдают остальные ноды, а не то, с чем автор работает.
    var titlesLeft = frameCost.budgetFor(visibleNodes.length);
    for (final titles in [priorityTitles, otherTitles]) {
      for (final title in titles) {
        if (titlesLeft <= 0) break;
        titlesLeft--;
        nodeRenderer.drawNodeTitle(canvas, title.node, isDimmed: title.dimmed);
      }
    }

    // --- КОММЕНТАРИИ --- (кулл)
    for (final comment in state.comments) {
      final r = comment.id == resizingCommentId && temporaryCommentSize != null
          ? (comment.position & temporaryCommentSize!)
          : comment.id == movingItemId && temporaryItemPosition != null
              ? temporaryItemPosition! & comment.size
              : comment.rect;
      if (!r.overlaps(expandedRect)) continue;
      if (comment.id == resizingCommentId && temporaryCommentSize != null) {
        _drawComment(canvas, comment.copyWith(size: temporaryCommentSize!));
      } else if (comment.id == movingItemId && temporaryItemPosition != null) {
        _drawComment(canvas, comment.copyWith(position: temporaryItemPosition!));
      } else {
        _drawComment(canvas, comment);
      }
    }

    canvas.restore();

    // Рамка выделения (Лассо)
    if (state.selectionMode && state.selectionRect != null) {
      final paint = Paint()
        ..color = CanvasTheme.selection.withOpacity(0.2)
        ..style = PaintingStyle.fill;
      final borderPaint = Paint()
        ..color = CanvasTheme.selection.withOpacity(0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawRect(state.selectionRect!, paint);
      canvas.drawRect(state.selectionRect!, borderPaint);
    }

    frameStopwatch?.stop();
    if (frameStopwatch != null) {
      frameCost.record(
        frameStopwatch.elapsedMicroseconds / 1000.0,
        visibleNodes: visibleNodes.length,
      );
    }
  }

  void _drawAdaptiveGrid(Canvas canvas, Size size) {
    const baseGridSize = 50.0;
    final scale = state.scale;
    int lodLevel = 1;
    double currentGridSize = baseGridSize * scale;
    while (currentGridSize < 20 && lodLevel < 100) {
      lodLevel *= 5;
      currentGridSize = baseGridSize * lodLevel * scale;
    }
    if (currentGridSize < 5) return;
    final gridPaint = Paint()
      ..color = CanvasTheme.grid
      ..strokeWidth = 1;
    final offsetX = state.offset.dx % currentGridSize;
    final offsetY = state.offset.dy % currentGridSize;
    for (double x = offsetX; x < size.width; x += currentGridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = offsetY; y < size.height; y += currentGridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  void _drawGroup(Canvas canvas, CanvasGroup group) {
    final rrect = RRect.fromRectAndRadius(
      group.rect,
      const Radius.circular(20),
    );

    // Мягкая полупрозрачная заливка тоном группы
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = group.color.withOpacity(0.10)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = group.color.withOpacity(0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Заголовок группы в виде чипа с тоном группы
    final labelPainter = TextPainter(
      text: TextSpan(
        text: group.label,
        style: TextStyle(
          color: CanvasTheme.nodeTitle,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: group.rect.width - 32);

    final chipRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        group.rect.left + 12,
        group.rect.top + 12,
        labelPainter.width + 28,
        28,
      ),
      const Radius.circular(14),
    );
    canvas.drawRRect(
      chipRect,
      Paint()..color = CanvasTheme.nodeHeader.withOpacity(0.95),
    );
    // Цветная точка-маркер группы
    canvas.drawCircle(
      Offset(chipRect.left + 13, chipRect.top + 14),
      4,
      Paint()..color = group.color,
    );
    labelPainter.paint(
      canvas,
      Offset(chipRect.left + 22, chipRect.top + (28 - labelPainter.height) / 2),
    );

    // RESIZE HANDLE
    _drawResizeHandle(canvas, group.rect.bottomRight, size: 15);
  }

  void _drawComment(Canvas canvas, CanvasComment comment) {
    final rect = comment.rect;
    const radius = Radius.circular(16);
    final rrect = RRect.fromRectAndRadius(rect, radius);

    // Тень убрана: глубину задаёт тон поверхности, а не drop shadow.
    // Тело комментария на M3-контейнере
    canvas.drawRRect(rrect, Paint()..color = CanvasTheme.commentBody);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = CanvasTheme.commentText.withOpacity(0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: comment.text,
        style: TextStyle(color: CanvasTheme.commentText, fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width - 24);

    textPainter.paint(canvas, rect.topLeft + const Offset(12, 12));

    // RESIZE HANDLE
    _drawResizeHandle(
      canvas,
      rect.bottomRight,
      color: CanvasTheme.commentText.withOpacity(0.35),
      size: 12,
    );
  }

  void _drawResizeHandle(
    Canvas canvas,
    Offset position, {
    Color? color,
    double size = 10,
  }) {
    final paint = Paint()
      ..color = color ?? CanvasTheme.nodePreview.withOpacity(0.6)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(position.dx, position.dy)
      ..lineTo(position.dx - size, position.dy)
      ..lineTo(position.dx, position.dy - size)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _addArrowToPath(Path arrowPath, Offset from, Offset to) {
    final d = to - from;
    if (d.distance == 0) return;
    final angle = math.atan2(d.dy, d.dx);
    const sz = 12.0;
    const ang = math.pi / 6;
    arrowPath.moveTo(to.dx, to.dy);
    arrowPath.lineTo(to.dx - sz * math.cos(angle - ang), to.dy - sz * math.sin(angle - ang));
    arrowPath.lineTo(to.dx - sz * math.cos(angle + ang), to.dy - sz * math.sin(angle + ang));
    arrowPath.close();
  }

  void _drawConnectionPreview(Canvas canvas, Node startNode, Offset endPos) {
    final start = startNode.getClosestAnchor(endPos);
    _drawCubicBezier(
      canvas,
      start,
      endPos,
      CanvasTheme.accent.withOpacity(0.6),
      startNode.position,
      endPos,
    );
  }

  void _drawCubicBezier(
    Canvas canvas,
    Offset start,
    Offset end,
    Color color,
    Offset fromCenter,
    Offset toCenter,
  ) {
    final controls = _calculateBezierControls(start, end, fromCenter, toCenter);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(
        controls.$1.dx,
        controls.$1.dy,
        controls.$2.dx,
        controls.$2.dy,
        end.dx,
        end.dy,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    _drawArrow(canvas, controls.$2, end, color);
  }

  (Offset, Offset) _calculateBezierControls(
    Offset start,
    Offset end,
    Offset fromCenter,
    Offset toCenter,
  ) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final distance = math.sqrt(dx * dx + dy * dy);
    final controlOffset = math.min(distance * 0.5, 100.0);
    late final Offset control1;
    late final Offset control2;
    if ((start.dx - fromCenter.dx).abs() > (start.dy - fromCenter.dy).abs()) {
      control1 = Offset(
        start.dx + (dx > 0 ? controlOffset : -controlOffset),
        start.dy,
      );
    } else {
      control1 = Offset(
        start.dx,
        start.dy + (dy > 0 ? controlOffset : -controlOffset),
      );
    }
    if ((end.dx - toCenter.dx).abs() > (end.dy - toCenter.dy).abs()) {
      control2 = Offset(
        end.dx - (dx > 0 ? controlOffset : -controlOffset),
        end.dy,
      );
    } else {
      control2 = Offset(
        end.dx,
        end.dy - (dy > 0 ? controlOffset : -controlOffset),
      );
    }
    return (control1, control2);
  }

  void _drawArrow(Canvas canvas, Offset from, Offset to, Color color) {
    final direction = (to - from);
    if (direction.distance == 0) return;
    final angle = math.atan2(direction.dy, direction.dx);
    const arrowSize = 12.0;
    const arrowAngle = math.pi / 6;
    final arrowPath = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(
        to.dx - arrowSize * math.cos(angle - arrowAngle),
        to.dy - arrowSize * math.sin(angle - arrowAngle),
      )
      ..lineTo(
        to.dx - arrowSize * math.cos(angle + arrowAngle),
        to.dy - arrowSize * math.sin(angle + arrowAngle),
      )
      ..close();
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant InfiniteCanvasPainter oldDelegate) {
    if (resizingGroupId != oldDelegate.resizingGroupId ||
        temporaryGroupRect != oldDelegate.temporaryGroupRect ||
        resizingCommentId != oldDelegate.resizingCommentId ||
        temporaryCommentSize != oldDelegate.temporaryCommentSize ||
        movingItemId != oldDelegate.movingItemId ||
        temporaryItemPosition != oldDelegate.temporaryItemPosition) {
      return true;
    }
    if (showOnlyProblematic != oldDelegate.showOnlyProblematic ||
        problematicNodeIds.length != oldDelegate.problematicNodeIds.length ||
        !problematicNodeIds.containsAll(oldDelegate.problematicNodeIds)) {
      return true;
    }
    if (visibleConnectionKinds.length !=
            oldDelegate.visibleConnectionKinds.length ||
        !visibleConnectionKinds.containsAll(
          oldDelegate.visibleConnectionKinds,
        )) {
      return true;
    }
    if (thumbnails != oldDelegate.thumbnails ||
        questId != oldDelegate.questId) {
      return true;
    }
    return oldDelegate.state != state;
  }
}
