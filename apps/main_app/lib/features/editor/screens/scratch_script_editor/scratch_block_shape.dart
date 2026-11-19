import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';

import 'scratch_layout.dart';

/// Силуэты блоков в грамматике Scratch: паз на верхней кромке, шип снизу,
/// «шляпа» события и C-форма контейнера с закруглённым вырезом.
///
/// Отдельный файл, а не методы painter'а: те же пути нужны выделению,
/// призраку перетаскивания и тестам геометрии. Painter только заливает их
/// цветом категории.
class ScratchShape {
  ScratchShape._();

  /// Шип снизу: половинка «таблетки» торчит за `rect.bottom`, вторая половина
  /// лежит внутри блока. Так блок стыкуется со следующим без щели, а на
  /// свободном конце стека шип виден, как в Scratch.
  static Rect tabRect(Rect rect) => Rect.fromLTWH(
    rect.left + ScratchMetrics.notchInset,
    rect.bottom - ScratchMetrics.notchDepth,
    ScratchMetrics.notchWidth,
    ScratchMetrics.notchDepth * 2,
  );

  /// Паз на кромке: та же «таблетка», вырезанная из заливки.
  static Rect notchRect(Rect rect, {required bool atTop}) => Rect.fromLTWH(
    rect.left + ScratchMetrics.notchInset,
    atTop
        ? rect.top - ScratchMetrics.notchDepth
        : rect.bottom - ScratchMetrics.notchDepth,
    ScratchMetrics.notchWidth,
    ScratchMetrics.notchDepth * 2,
  );

  static Path _pill(Rect rect) => Path()
    ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)));

  /// Путь шапки блока. [hat] — событие: верх поднят дугой, как у шляпы.
  /// [topNotch] — вырез сверху (его закрывает шип блока выше, если он есть).
  /// [bottomTab] — собственный шип.
  static Path head(
    Rect rect, {
    required bool hat,
    bool topNotch = true,
    bool bottomTab = false,
  }) {
    var path = hat ? _hat(rect) : _rounded(rect);
    if (topNotch) {
      path = Path.combine(
        PathOperation.difference,
        path,
        _pill(notchRect(rect, atTop: true)),
      );
    }
    if (bottomTab) {
      path = Path.combine(PathOperation.union, path, _pill(tabRect(rect)));
    }
    return path;
  }

  /// Шляпа: стороны поднимаются на [ScratchMetrics.hatRise], верх — широкая
  /// дуга. Так `при запуске ноды` читается как начало скрипта, а не как
  /// обычная команда.
  static Path _hat(Rect rect) {
    final r = ScratchMetrics.headRadius;
    final rise = ScratchMetrics.hatRise;
    final top = rect.top;
    final bottom = rect.bottom;
    final path = Path()
      ..moveTo(rect.left, bottom - r)
      ..lineTo(rect.left, top + rise)
      ..quadraticBezierTo(
        rect.left + rect.width * 0.14,
        top,
        rect.left + rect.width * 0.5,
        top,
      )
      ..quadraticBezierTo(
        rect.left + rect.width * 0.86,
        top,
        rect.right,
        top + rise,
      )
      ..lineTo(rect.right, bottom - r)
      ..quadraticBezierTo(rect.right, bottom, rect.right - r, bottom)
      ..lineTo(rect.left + r, bottom)
      ..quadraticBezierTo(rect.left, bottom, rect.left, bottom - r)
      ..close();
    return path;
  }

  static Path _rounded(Rect rect) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(ScratchMetrics.headRadius)),
    );

  /// C-форма: корпус минус тело ветки. Тело выходит за правую кромку, поэтому
  /// правая сторона открыта, как в Scratch; скругление тела даёт закруглённые
  /// внутренние углы.
  static Path container(Rect rect, Rect body, {bool topNotch = true}) {
    var outer = Path.combine(
      PathOperation.union,
      _rounded(rect),
      _pill(tabRect(rect)),
    );
    final cut = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            body.left,
            body.top,
            math.max(body.right, rect.right) + 24,
            body.bottom,
          ),
          Radius.circular(ScratchMetrics.bodyRadius),
        ),
      );
    outer = Path.combine(PathOperation.difference, outer, cut);
    if (topNotch) {
      outer = Path.combine(
        PathOperation.difference,
        outer,
        _pill(notchRect(rect, atTop: true)),
      );
    }
    return outer;
  }

  /// Путь шапки конкретного блока.
  static Path headOf(
    VisualScriptBlock block,
    Rect rect, {
    bool bottomTab = false,
  }) => head(rect, hat: block is EventBlock, bottomTab: bottomTab);

  /// Центр строки текста: у шляпы текст ниже подъёма, у обычного блока — по
  /// центру.
  static double textCenterY(Rect rect, VisualScriptBlock block) =>
      block is EventBlock
      ? rect.top + ScratchMetrics.hatRise + ScratchMetrics.headHeight / 2
      : rect.center.dy;

  /// Полная высота шапки: у события она выше на подъём шляпы.
  static double headHeight(VisualScriptBlock block) =>
      ScratchMetrics.headHeightFor(block);
}
