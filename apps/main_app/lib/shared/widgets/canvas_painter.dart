import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:canvas_app/models/canvas_lod.dart';
import 'package:canvas_app/models/canvas_models.dart';
import 'package:canvas_app/models/canvas_picture_cache.dart';
import 'package:canvas_app/features/editor/providers/canvas_provider.dart';

class InfiniteCanvasPainter extends CustomPainter {
  final CanvasState state;
  final NodeRenderer nodeRenderer;

  /// Решение о детализации — переживает перестройку виджета.
  final CanvasLodState lod;

  /// Записанные пикчи нод: пока нода не менялась, кадр её не перерисовывает.
  final CanvasNodePictureCache nodePictures;
  final Set<String> problematicNodeIds;
  final bool showOnlyProblematic;
  final Set<ConnectionKind> visibleConnectionKinds;

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
    CanvasLodState? lod,
    CanvasNodePictureCache? nodePictures,
    this.problematicNodeIds = const <String>{},
    this.showOnlyProblematic = false,
    this.visibleConnectionKinds = const <ConnectionKind>{
      ConnectionKind.content,
      ConnectionKind.timer,
      ConnectionKind.script,
    },
    this.resizingGroupId,
    this.temporaryGroupRect,
    this.resizingCommentId,
    this.temporaryCommentSize,
    this.movingItemId,
    this.temporaryItemPosition,
  }) : nodeRenderer = nodeRenderer ?? NodeRenderer(),
       lod = lod ?? CanvasLodState(),
       nodePictures = nodePictures ?? CanvasNodePictureCache();

  @override
  void paint(Canvas canvas, Size size) {
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
          ? Rect.fromLTWH(
              temporaryItemPosition!.dx,
              temporaryItemPosition!.dy,
              group.rect.width,
              group.rect.height,
            )
          : group.rect;
      if (!r.overlaps(expandedRect)) continue;
      if (group.id == resizingGroupId && temporaryGroupRect != null) {
        _drawGroup(canvas, group.copyWith(rect: temporaryGroupRect!));
      } else if (group.id == movingItemId && temporaryItemPosition != null) {
        final newRect = Rect.fromLTWH(
          temporaryItemPosition!.dx,
          temporaryItemPosition!.dy,
          group.rect.width,
          group.rect.height,
        );
        _drawGroup(canvas, group.copyWith(rect: newRect));
      } else {
        _drawGroup(canvas, group);
      }
    }

    final bool isSearching = state.searchQuery.isNotEmpty;
    final matchingNodeIds = state.matchingNodeIds;

    // --- СВЯЗИ --- (батчинг, геометрия из провайдера)
    //
    // Кривые и стрелки рисуются при любом зуме: направление связи — часть
    // графа, без него отдалённый канвас нечитаем. Толщина и размер стрелки
    // в мировых координатах подобраны так, чтобы на экране они почти не
    // истончались: при зуме 1 это 3 и 12, при отдалении — до 8 и 28.
    final strokeWidth = (3.0 / state.scale).clamp(3.0, 8.0);
    final arrowSize = (12.0 / state.scale).clamp(12.0, 28.0);
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

    // Батчинг: 1 drawPath на вид связи. Виртуальные рёбра (timer/script)
    // рисуются пунктиром — иначе они неотличимы от content-рёбер и сливаются
    // с ними в одну сплошную линию. На мелком зуме пунктир нечитаем, там
    // остаётся тонкая сплошная.
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
        if (c.isVirtual) {
          // Служебные связи (таймер/скрипт) — пунктиром и без стрелок: иначе
          // они неотличимы от обычных переходов и сливаются с ними в линию.
          target.addPath(_dashedPathFor(g), Offset.zero);
        } else {
          final curve = Path()
            ..moveTo(g.start.dx, g.start.dy)
            ..cubicTo(
              g.cp1.dx,
              g.cp1.dy,
              g.cp2.dx,
              g.cp2.dy,
              g.end.dx,
              g.end.dy,
            );
          target.addPath(curve, Offset.zero);
          _addArrowToPath(arrowPath, g.cp2, g.end, size: arrowSize);
        }
      }
      // content — синий, timer — amber, script — violet; все 3 батча — 3 draw calls
      canvas.drawPath(
        solidContent,
        Paint()
          ..color = CanvasTheme.connectionContent
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
      canvas.drawPath(
        solidScript,
        Paint()
          ..color = CanvasTheme.connectionScript
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
      canvas.drawPath(
        solidTimer,
        Paint()
          ..color = CanvasTheme.connectionTimer
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
      canvas.drawPath(
        arrowPath,
        Paint()
          ..color = CanvasTheme.connectionContent
          ..style = PaintingStyle.fill,
      );
    }

    if (state.connectionMode &&
        state.connectionStartNodeId != null &&
        state.connectionPreviewEnd != null) {
      final startNode = state.nodes.firstWhere(
        (n) => n.id == state.connectionStartNodeId,
      );
      _drawConnectionPreview(canvas, startNode, state.connectionPreviewEnd!);
    }

    // --- НОДЫ --- (тело карточки прячется по числу нод в кадре с
    // гистерезисом; подписи рисуются всегда, потому что стоят в кеше)
    final bool showDetails = lod.detailsFor(visibleNodes.length);
    // Исходящие связи нужны только как «есть/нет» — считаем один раз на кадр,
    // а не полным перебором рёбер на каждую ноду.
    final nodeIdsWithOutgoing = <String>{
      for (final connection in state.connections) connection.fromNode.id,
    };
    final List<({Node node, bool dimmed})> priorityTitles = [];
    final List<({Node node, bool dimmed})> otherTitles = [];
    for (final node in visibleNodes) {
      final bool isSearchDimmed =
          isSearching && !matchingNodeIds.contains(node.id);
      final bool isProblemDimmed =
          showOnlyProblematic && !problematicNodeIds.contains(node.id);
      final bool isDimmed = isSearchDimmed || isProblemDimmed;
      final bool isSelected = state.selectedNodeIds.contains(node.id);

      final bool isHovered = node.id == state.hoveredNodeId && !isDimmed;
      final bool isConnectionStart = node.id == state.connectionStartNodeId;
      final bool isConnectionTarget =
          state.connectionMode &&
          state.connectionStartNodeId != null &&
          node.id == state.hoveredNodeId &&
          node.id != state.connectionStartNodeId &&
          !isDimmed;

      final bodySignature = _bodySignature(
        node,
        isSelected: isSelected && !isDimmed,
        isHovered: isHovered,
        isConnectionStart: isConnectionStart,
        isConnectionTarget: isConnectionTarget,
        isConnectionMode: state.connectionMode,
        isDimmed: isDimmed,
        hasValidationIssue: problematicNodeIds.contains(node.id),
        hasOutgoing: nodeIdsWithOutgoing.contains(node.id),
        showDetails: showDetails,
      );
      canvas.drawPicture(
        nodePictures.body(
          node.id,
          bodySignature,
          (recorder) => nodeRenderer.drawNode(
            recorder,
            node,
            isSelected: isSelected && !isDimmed,
            isHovered: isHovered,
            isConnectionStart: isConnectionStart,
            isConnectionTarget: isConnectionTarget,
            isConnectionMode: state.connectionMode,
            isDimmed: isDimmed,
            hasValidationIssue: problematicNodeIds.contains(node.id),
            allConnections: state.connections,
            showDetails: showDetails,
          ),
        ),
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

    // Подписи — второй проход: они рисуются поверх всех тел. Каждая тоже
    // записана в пикчу, поэтому «подписать все видимые» больше не стоит
    // кадра: цена — только у нод, которые изменились.
    for (final titles in [priorityTitles, otherTitles]) {
      for (final title in titles) {
        final signature = _titleSignature(title.node, title.dimmed);
        canvas.drawPicture(
          nodePictures.title(
            title.node.id,
            signature,
            (recorder) => nodeRenderer.drawNodeTitle(
              recorder,
              title.node,
              isDimmed: title.dimmed,
            ),
          ),
        );
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
        _drawComment(
          canvas,
          comment.copyWith(position: temporaryItemPosition!),
        );
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

    nodePictures.retainOnly(visibleNodeIds);
  }

  /// Подпись для кеша тела ноды. Всё, что влияет на пикчу, обязано сюда
  /// попасть: иначе нода останется нарисованной со старым текстом.
  static int _bodySignature(
    Node node, {
    required bool isSelected,
    required bool isHovered,
    required bool isConnectionStart,
    required bool isConnectionTarget,
    required bool isConnectionMode,
    required bool isDimmed,
    required bool hasValidationIssue,
    required bool hasOutgoing,
    required bool showDetails,
  }) {
    return Object.hash(
      node.id,
      node.rect,
      node.color.value,
      node.isStartNode,
      node.timerDuration,
      node.scriptCount,
      node.backgroundAssetId,
      node.hasImageItem,
      node.hasAudioItem,
      node.branchTotal,
      node.replyCount,
      Object.hashAll(node.textLines),
      Object.hashAll(node.branchLabels),
      hasOutgoing,
      hasValidationIssue,
      Object.hash(
        isSelected,
        isHovered,
        isConnectionStart,
        isConnectionTarget,
        isConnectionMode,
        isDimmed,
        showDetails,
      ),
    );
  }

  /// Подпись для кеша заголовка: он рисуется со своей шириной (её задаёт
  /// место под иконки в шапке) и своим цветом.
  static int _titleSignature(Node node, bool isDimmed) {
    return Object.hash(
      node.id,
      node.rect,
      node.label,
      node.headerRightInset,
      node.color.value,
      isDimmed,
    );
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

  /// Пунктирная копия кривой связи.
  ///
  /// Нарезка на сегменты — самая дорогая часть отрисовки виртуальных рёбер
  /// (у большого квеста их сотни), а геометрия между кадрами панорамы/зума не
  /// меняется. Ключ — сам объект геометрии (пересоздаётся при движении нод),
  /// поэтому кэш живёт по identity и не требует сравнений путей.
  static final Map<ConnectionGeometry, Path> _dashedPaths =
      <ConnectionGeometry, Path>{};

  Path _dashedPathFor(ConnectionGeometry g) {
    final cached = _dashedPaths[g];
    if (cached != null) return cached;
    final curve = Path()
      ..moveTo(g.start.dx, g.start.dy)
      ..cubicTo(g.cp1.dx, g.cp1.dy, g.cp2.dx, g.cp2.dy, g.end.dx, g.end.dy);
    final dashed = Path();
    for (final metric in curve.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + _dash, metric.length);
        dashed.addPath(metric.extractPath(distance, end), Offset.zero);
        distance = end + _dashGap;
      }
    }
    if (_dashedPaths.length > 4096) _dashedPaths.clear();
    _dashedPaths[g] = dashed;
    return dashed;
  }

  static const double _dash = 8;
  static const double _dashGap = 6;

  void _addArrowToPath(
    Path arrowPath,
    Offset from,
    Offset to, {
    double size = 12.0,
  }) {
    final d = to - from;
    if (d.distance == 0) return;
    final angle = math.atan2(d.dy, d.dx);
    final sz = size;
    const ang = math.pi / 6;
    arrowPath.moveTo(to.dx, to.dy);
    arrowPath.lineTo(
      to.dx - sz * math.cos(angle - ang),
      to.dy - sz * math.sin(angle - ang),
    );
    arrowPath.lineTo(
      to.dx - sz * math.cos(angle + ang),
      to.dy - sz * math.sin(angle + ang),
    );
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
    return oldDelegate.state != state;
  }
}
