import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Камера канваса блоков: панорама и зум.
///
/// Отдельный [ChangeNotifier], а не поле в `setState`: жест панорамирования
/// приходит 60–120 раз в секунду, и пересборка дерева виджетов на каждый тик
/// съела бы весь бюджет кадра. Painter подписан на этот объект через
/// `repaint` и перерисовывается один, без rebuild'а экрана.
class ScratchCameraController extends ChangeNotifier {
  ScratchCameraController({
    Offset offset = Offset.zero,
    double scale = 1.0,
    this.minScale = 0.2,
    this.maxScale = 3.0,
  }) : _offset = offset,
       _scale = scale;

  final double minScale;
  final double maxScale;

  Offset _offset;
  double _scale;

  Offset get offset => _offset;
  double get scale => _scale;

  Offset screenToWorld(Offset point) => (point - _offset) / _scale;

  Offset worldToScreen(Offset point) => point * _scale + _offset;

  Rect visibleWorldRect(Size screenSize) => Rect.fromPoints(
    screenToWorld(Offset.zero),
    screenToWorld(screenSize.bottomRight(Offset.zero)),
  );

  void panBy(Offset delta) {
    if (delta == Offset.zero) return;
    _offset += delta;
    notifyListeners();
  }

  /// Зум вокруг экранной точки: точка под курсором остаётся на месте.
  void zoomAt(double newScale, Offset focalPoint) {
    final clamped = newScale.clamp(minScale, maxScale);
    if (clamped == _scale) return;
    final delta = clamped / _scale;
    _offset = focalPoint - (focalPoint - _offset) * delta;
    _scale = clamped;
    notifyListeners();
  }

  void zoomAtCenter(double factor, Size screenSize) {
    zoomAt(_scale * factor, screenSize.center(Offset.zero));
  }

  void reset() {
    _offset = Offset.zero;
    _scale = 1.0;
    notifyListeners();
  }

  /// Вписать всё дерево в экран (с полями), но не приближать мельче
  /// [minScale] и не отдалять сильнее, чем нужно для чтения.
  void fit(Rect content, Size screenSize, {double padding = 60}) {
    if (content.isEmpty || screenSize.isEmpty) return;
    final availableW = screenSize.width - padding * 2;
    final availableH = screenSize.height - padding * 2;
    if (availableW <= 0 || availableH <= 0) return;
    final scaleX = availableW / content.width;
    final scaleY = availableH / content.height;
    final next = (scaleX < scaleY ? scaleX : scaleY).clamp(minScale, 1.0);
    _scale = next;
    _offset = screenSize.center(Offset.zero) - content.center * next;
    notifyListeners();
  }
}
