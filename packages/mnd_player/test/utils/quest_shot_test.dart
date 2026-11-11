import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/quest_shot.dart';

/// Сцена для теста: тёмно-синий кадр 400×300 с красной полосой слева —
/// по цветам видно, что кадр реально вклеен в карточку.
Future<ui.Image> _scene() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 400, 300),
    ui.Paint()..color = const ui.Color(0xFF102040),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 40, 300),
    ui.Paint()..color = const ui.Color(0xFFAA2222),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(400, 300);
  picture.dispose();
  return image;
}

Future<ui.Image> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  return frame.image;
}

Future<ui.Color> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final bytes = data.buffer.asUint8List();
  final i = (y * image.width + x) * 4;
  return ui.Color.fromARGB(
    bytes[i + 3],
    bytes[i],
    bytes[i + 1],
    bytes[i + 2],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('снимок — карточка с полями и подписью, а не голый кадр', () async {
    final png = await QuestShot.compose(await _scene());
    final image = await _decode(png);
    addTearDown(image.dispose);

    // Ширина фиксированная, высота = кадр по ширине + поля + подпись.
    expect(image.width, QuestShot.outputWidth.ceil());
    final cardWidth = QuestShot.outputWidth - QuestShot.padding * 2;
    final cardHeight = 300 * (cardWidth / 400);
    expect(
      image.height,
      (cardHeight + QuestShot.padding * 2 + QuestShot.captionHeight).ceil(),
    );

    // Угол — фон, а не кадр: карточка скруглена и отступает от края.
    expect((await _pixel(image, 2, 2)).a, 1.0);
    // Внутри карточки слева красная полоса исходника.
    final left = await _pixel(
      image,
      (QuestShot.padding + 10).toInt(),
      (QuestShot.padding + 40).toInt(),
    );
    expect(left.r, greaterThan(0.5));
    expect(left.b, lessThan(0.5));
    // В центре — синий исходник, а не фон.
    final center = await _pixel(
      image,
      image.width ~/ 2,
      (QuestShot.padding + cardHeight / 2).toInt(),
    );
    expect(center.b, greaterThan(center.r));
  });
}