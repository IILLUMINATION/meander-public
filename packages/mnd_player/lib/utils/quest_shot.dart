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
/// Рамка устройства вокруг кадра: маркетплейсы любят мокапы, а «просто
/// прямоугольник» теряется среди чужих скриншотов.
///
/// Рамки рисуются векторно на Canvas, а не накладываются готовыми PNG:
/// так они остаются резкими на любом размере, не зависят от сторонних
/// SVG-ассетов и лицензий и не требуют ассет-бандла в плеере.
enum QuestShotFrame {
  none('Без рамки'),
  phone('iPhone'),
  tablet('iPad'),
  laptop('Ноутбук');

  const QuestShotFrame(this.label);

  /// Подпись для интерфейса.
  final String label;

  static QuestShotFrame fromName(String? raw) {
    for (final frame in values) {
      if (frame.name == raw) return frame;
    }
    return QuestShotFrame.phone;
  }
}

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

  /// Подмена сборки карточки в тестах: настоящая растеризация PNG в фейковом
  /// времени виджет-теста не завершается. Публичное поле — как [testScene];
  /// в рабочем коде остаётся `null`.
  static Future<Uint8List> Function(ui.Image shot, QuestShotFrame frame)?
  testCompose;

  /// Ширина готового снимка: вдвое больше типичной карточки маркета, чтобы
  /// снимок не мылил на Retina-экранах.
  static const double outputWidth = 1440;

  /// Поля вокруг карточки.
  static const double padding = 72;

  /// Полоса под подпись.
  static const double captionHeight = 96;

  /// Радиус карточки.
  static const double radius = 32;

  /// Последняя выбранная рамка: диалог снимка открывается с ней же, чтобы
  /// автор не выбирал «iPhone» заново после каждого снимка.
  static QuestShotFrame lastFrame = QuestShotFrame.phone;

  /// Пропорции экрана устройства (ширина / высота) и доля безеля.
  static ({double aspect, double bezel, double bodyShare}) _geometry(
    QuestShotFrame frame,
  ) => switch (frame) {
    // 1290×2796 — пропорции iPhone 15 Pro.
    QuestShotFrame.phone => (aspect: 1290 / 2796, bezel: 0.032, bodyShare: 0.52),
    // 1668×2388 — iPad Pro 11".
    QuestShotFrame.tablet => (aspect: 1668 / 2388, bezel: 0.045, bodyShare: 0.74),
    // 2560×1600 — крышка ноутбука.
    QuestShotFrame.laptop => (aspect: 1.6, bezel: 0.03, bodyShare: 0.96),
    QuestShotFrame.none => (aspect: 1, bezel: 0, bodyShare: 1),
  };

  /// Собрать PNG из кадра сцены.
  ///
  /// Кадр вписывается по ширине; высота результата зависит от пропорций
  /// сцены — вертикальный кадр телефона не разбавляется пустыми полями.
  ///
  /// Владеет [shot] и освобождает его после сборки: вызывающему не нужно
  /// помнить про dispose, а повторная сборка просит копию (`Image.clone`).
  static Future<Uint8List> compose(
    ui.Image shot, {
    String watermark = 'Meander',
    QuestShotFrame frame = QuestShotFrame.phone,
  }) async {
    lastFrame = frame;
    final recorder = ui.PictureRecorder();
    // Размер холста считаем до рисования: от рамки зависит высота карточки.
    final layout = _Layout.of(shot, frame, outputWidth, padding, captionHeight);
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, layout.width, layout.height),
    );

    // Фон: затемнённый средний цвет сцены с диагональным градиентом. Он не
    // спорит с картинкой, но не даёт «серого поля».
    final accent = await _averageColor(shot);
    final dark = Color.lerp(accent, const Color(0xFF0B0B0F), 0.72)!;
    final darker = Color.lerp(accent, const Color(0xFF05050A), 0.88)!;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, layout.width, layout.height),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, 0),
          Offset(layout.width, layout.height),
          [dark, darker],
        ),
    );

    if (frame == QuestShotFrame.none) {
      _paintCard(canvas, shot, layout, radius: radius);
    } else {
      _paintDevice(canvas, shot, frame, layout);
    }

    _paintWatermark(
      canvas,
      watermark,
      Offset(layout.width - padding, layout.height - captionHeight / 2),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      layout.width.ceil(),
      layout.height.ceil(),
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
      shot.dispose();
    }
  }

  /// Прежний вид: скруглённая карточка прямо на фоне.
  static void _paintCard(
    Canvas canvas,
    ui.Image shot,
    _Layout layout, {
    required double radius,
  }) {
    final cardRect = RRect.fromRectAndRadius(layout.screen, Radius.circular(radius));
    // Тень рисуется размытым скруглённым прямоугольником: тень BlurStyle
    // normal на прозрачном фоне даёт ровный ореол без «лестницы».
    canvas.drawRRect(
      cardRect.shift(const Offset(0, 24)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 32),
    );
    _drawShotCover(canvas, shot, layout.screen, cardRect, radius);
    canvas.drawRRect(
      cardRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.16),
    );
  }

  /// Устройство: корпус, экран с кадром и характерные детали.
  static void _paintDevice(
    Canvas canvas,
    ui.Image shot,
    QuestShotFrame frame,
    _Layout layout,
  ) {
    final body = RRect.fromRectAndRadius(
      layout.body,
      Radius.circular(layout.bodyRadius),
    );

    // Тень под корпусом — как у карточки, но плотнее и ниже.
    canvas.drawRRect(
      body.shift(const Offset(0, 28)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40),
    );

    // Металлический корпус: тёмный градиент + светлая кромка.
    canvas.drawRRect(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          body.outerRect.topLeft,
          body.outerRect.bottomRight,
          const [Color(0xFF35353D), Color(0xFF101014), Color(0xFF26262C)],
          const [0.0, 0.6, 1.0],
        ),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.18),
    );

    // Боковые кнопки: две слева, одна справа — узнаваемый силуэт iPhone.
    if (frame == QuestShotFrame.phone) {
      final buttonPaint = Paint()..color = const Color(0xFF3A3A42);
      final w = layout.body.width * 0.012;
      final r = Radius.circular(w / 2);
      final left = layout.body.left - w * 0.35;
      final right = layout.body.right - w * 0.65;
      for (final (dy, h) in [
        (0.17, 0.045),
        (0.29, 0.075),
        (0.39, 0.075),
      ]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left,
              layout.body.top + layout.body.height * dy,
              w,
              layout.body.height * h,
            ),
            r,
          ),
          buttonPaint,
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            right,
            layout.body.top + layout.body.height * 0.25,
            w,
            layout.body.height * 0.12,
          ),
          r,
        ),
        buttonPaint,
      );
    }

    // Экран: кадр сцены с обрезкой по скруглению.
    final screenClip = RRect.fromRectAndRadius(
      layout.screen,
      Radius.circular(layout.screenRadius),
    );
    _drawShotCover(canvas, shot, layout.screen, screenClip, layout.screenRadius);

    // Динамический остров (iPhone) или точка камеры (iPad/ноутбук).
    switch (frame) {
      case QuestShotFrame.phone:
        final island = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(
              layout.screen.center.dx,
              layout.screen.top + layout.screen.width * 0.055,
            ),
            width: layout.screen.width * 0.30,
            height: layout.screen.width * 0.075,
          ),
          Radius.circular(layout.screen.width * 0.04),
        );
        canvas.drawRRect(island, Paint()..color = const Color(0xFF050506));
        canvas.drawCircle(
          Offset(island.right - island.width * 0.18, island.center.dy),
          layout.screen.width * 0.008,
          Paint()..color = const Color(0xFF1B2A3A),
        );
      case QuestShotFrame.tablet:
      case QuestShotFrame.laptop:
        canvas.drawCircle(
          Offset(layout.body.center.dx, (layout.body.top + layout.screen.top) / 2),
          layout.body.width * 0.006,
          Paint()..color = const Color(0xFF15161B),
        );
      case QuestShotFrame.none:
        break;
    }

    // Основание ноутбука: чуть шире крышки и с тенью.
    if (frame == QuestShotFrame.laptop) {
      final baseHeight = layout.body.height * 0.028;
      final base = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          layout.body.left - layout.body.width * 0.045,
          layout.body.bottom,
          layout.body.width * 1.09,
          baseHeight,
        ),
        Radius.circular(baseHeight * 0.6),
      );
      canvas.drawRRect(
        base,
        Paint()
          ..shader = ui.Gradient.linear(
            base.outerRect.topCenter,
            base.outerRect.bottomCenter,
            const [Color(0xFF3C3C44), Color(0xFF141418)],
          ),
      );
      canvas.drawRRect(
        base,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.white.withValues(alpha: 0.12),
      );
    }
  }

  /// Вписать кадр в прямоугольник экрана без пустых полей (cover) и
  /// обрезать по скруглению.
  static void _drawShotCover(
    Canvas canvas,
    ui.Image shot,
    Rect target,
    RRect clip,
    double radius,
  ) {
    canvas.save();
    canvas.clipRRect(clip);
    final scale = (target.width / shot.width) > (target.height / shot.height)
        ? target.width / shot.width
        : target.height / shot.height;
    final dw = shot.width * scale;
    final dh = shot.height * scale;
    final src = Rect.fromLTWH(0, 0, shot.width.toDouble(), shot.height.toDouble());
    final dst = Rect.fromLTWH(
      target.center.dx - dw / 2,
      target.center.dy - dh / 2,
      dw,
      dh,
    );
    canvas.drawImageRect(shot, src, dst, Paint()..filterQuality = FilterQuality.high);
    // Затемнение к низу кадра: айтемы у края не сливаются с подписью.
    canvas.drawRect(
      target,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, target.bottom - target.height * 0.18),
          Offset(0, target.bottom),
          [Colors.transparent, Colors.black.withValues(alpha: 0.28)],
        ),
    );
    canvas.restore();
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

/// Размеры готовой карточки и прямоугольники корпуса/экрана.
///
/// Считаются один раз до рисования: от рамки зависит и высота холста, и
/// область, в которую вписывается кадр.
class _Layout {
  const _Layout({
    required this.width,
    required this.height,
    required this.body,
    required this.screen,
    required this.bodyRadius,
    required this.screenRadius,
  });

  final double width;
  final double height;
  final Rect body;
  final Rect screen;
  final double bodyRadius;
  final double screenRadius;

  static _Layout of(
    ui.Image shot,
    QuestShotFrame frame,
    double outputWidth,
    double padding,
    double captionHeight,
  ) {
    final contentWidth = outputWidth - padding * 2;
    if (frame == QuestShotFrame.none) {
      final scale = contentWidth / shot.width;
      final cardHeight = shot.height * scale;
      final screen = Rect.fromLTWH(padding, padding, contentWidth, cardHeight);
      return _Layout(
        width: outputWidth,
        height: cardHeight + padding * 2 + captionHeight,
        body: screen,
        screen: screen,
        bodyRadius: QuestShot.radius,
        screenRadius: QuestShot.radius,
      );
    }

    final geometry = QuestShot._geometry(frame);
    final bodyWidth = contentWidth * geometry.bodyShare;
    final bezel = bodyWidth * geometry.bezel;
    final screenWidth = bodyWidth - bezel * 2;
    final screenHeight = screenWidth / geometry.aspect;
    final bodyHeight = screenHeight + bezel * 2;
    // Основание ноутбука рисуется под крышкой — его высоту тоже нужно
    // заложить в холст, иначе подпись ляжет на клавиатуру.
    final baseHeight = frame == QuestShotFrame.laptop ? bodyHeight * 0.028 : 0.0;

    final left = (outputWidth - bodyWidth) / 2;
    return _Layout(
      width: outputWidth,
      height: bodyHeight + baseHeight + padding * 2 + captionHeight,
      body: Rect.fromLTWH(left, padding, bodyWidth, bodyHeight),
      screen: Rect.fromLTWH(
        left + bezel,
        padding + bezel,
        screenWidth,
        screenHeight,
      ),
      bodyRadius: switch (frame) {
        QuestShotFrame.phone => bodyWidth * 0.145,
        QuestShotFrame.tablet => bodyWidth * 0.06,
        QuestShotFrame.laptop => bodyWidth * 0.022,
        QuestShotFrame.none => 0,
      },
      screenRadius: switch (frame) {
        QuestShotFrame.phone => screenWidth * 0.10,
        QuestShotFrame.tablet => screenWidth * 0.03,
        QuestShotFrame.laptop => screenWidth * 0.012,
        QuestShotFrame.none => 0,
      },
    );
  }
}
