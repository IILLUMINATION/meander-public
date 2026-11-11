import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/painting.dart';

/// Красивый снимок сцены квеста: карточка в мягкой рамке с подписью Meander.
///
/// В игре кадр обрезан интерфейсом и системными панелями, а для маркета нужен
/// чистый кадр. Композиция нарочно не «скриншот экрана», а карточка: фон —
/// затемнённый и размытый цвет самой сцены, скруглённые углы, мягкая тень и
/// подпись внизу. Так снимок не выглядит как окно приложения со случайной
/// ОС-рамкой.
class QuestShot {
  /// Подмена кадра сцены в тестах.
  ///
  /// `RenderRepaintBoundary.toImage` в тестовом биндинге даёт картинку, которую
  /// нельзя втянуть в новый `Picture` (растеризация такого кадра не
  /// завершается), поэтому тест подставляет кадр из `PictureRecorder`.
  ///
  /// Поле публичное намеренно: иначе виджет-тест не может дойти до сборки
  /// карточки. В рабочем коде остаётся `null`.
  static Future<ui.Image> Function()? testScene;

  /// Ширина готового снимка: вдвое больше типичной карточки маркета, чтобы
  /// снимок не мылил на Retina-экранах.
  static const double outputWidth = 1440;

  /// Поля вокруг карточки.
  static const double padding = 72;

  /// Полоса под подпись.
  static const double captionHeight = 96;

  /// Радиус карточки.
  static const double radius = 32;

  /// Собрать PNG из кадра сцены.
  ///
  /// Кадр вписывается по ширине; высота результата зависит от пропорций
  /// сцены — вертикальный кадр телефона не разбавляется пустыми полями.
  static Future<Uint8List> compose(ui.Image shot, {String watermark = 'Meander'}) async {
    final double cardWidth = outputWidth - padding * 2;
    final double scale = cardWidth / shot.width;
    final double cardHeight = shot.height * scale;
    final double width = outputWidth;
    final double height = cardHeight + padding * 2 + captionHeight;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));

    // Фон: затемнённый средний цвет сцены с диагональным градиентом. Он не
    // спорит с картинкой, но не даёт «серого поля».
    final accent = await _averageColor(shot);
    final dark = Color.lerp(accent, const Color(0xFF0B0B0F), 0.72)!;
    final darker = Color.lerp(accent, const Color(0xFF05050A), 0.88)!;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, 0),
          Offset(width, height),
          [dark, darker],
        ),
    );

    final cardRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(padding, padding, cardWidth, cardHeight),
      const Radius.circular(radius),
    );

    // Тень рисуется размытым скруглённым прямоугольником: тень BlurStyle.
    // normal на прозрачном фоне даёт ровный ореол без «лестницы».
    canvas.drawRRect(
      cardRect.shift(const Offset(0, 24)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 32),
    );

    canvas.save();
    canvas.clipRRect(cardRect);
    canvas.drawImageRect(
      shot,
      Rect.fromLTWH(0, 0, shot.width.toDouble(), shot.height.toDouble()),
      cardRect.outerRect,
      Paint()..filterQuality = FilterQuality.high,
    );
    // Затемнение к низу кадра: айтемы у края не сливаются с подписью.
    canvas.drawRect(
      cardRect.outerRect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, cardRect.bottom - 220),
          Offset(0, cardRect.bottom),
          [Colors.transparent, Colors.black.withValues(alpha: 0.28)],
        ),
    );
    canvas.restore();

    // Тонкая светлая рамка — карточка «отрывается» от фона.
    canvas.drawRRect(
      cardRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.16),
    );

    _paintWatermark(
      canvas,
      watermark,
      Offset(width - padding, height - captionHeight / 2),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.ceil(), height.ceil());
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
      shot.dispose();
    }
  }

  /// Подпись справа внизу: слово Meander тонким начертанием и точка-акцент.
  static void _paintWatermark(Canvas canvas, String text, Offset anchor) {
    const double fontSize = 34;
    final style = TextStyle(
      color: Colors.white.withValues(alpha: 0.62),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.6,
    );
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final left = anchor.dx - painter.width;
    final top = anchor.dy - painter.height / 2;
    painter.paint(canvas, Offset(left, top));
    canvas.drawCircle(
      Offset(left - 14, top + painter.height * 0.62),
      4,
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );
  }

  /// Средний цвет кадра по сетке 8×8: усреднять все пиксели дорого, а для
  /// фона хватает грубого представления о сцене.
  static Future<Color> _averageColor(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return const Color(0xFF1A1720);
    final bytes = data.buffer.asUint8List();
    final stepX = (image.width / 8).ceil().clamp(1, image.width);
    final stepY = (image.height / 8).ceil().clamp(1, image.height);
    var r = 0, g = 0, b = 0, count = 0;
    for (var y = 0; y < image.height; y += stepY) {
      for (var x = 0; x < image.width; x += stepX) {
        final i = (y * image.width + x) * 4;
        if (i + 2 >= bytes.length) continue;
        r += bytes[i];
        g += bytes[i + 1];
        b += bytes[i + 2];
        count++;
      }
    }
    if (count == 0) return const Color(0xFF1A1720);
    return Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
  }
}