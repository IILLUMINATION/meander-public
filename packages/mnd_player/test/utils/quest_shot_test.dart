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
  // Зелёная полоса у правого края: по ней видно, что и правый край кадра
  // не срезан.
  canvas.drawRect(
    const ui.Rect.fromLTWH(360, 0, 40, 300),
    ui.Paint()..color = const ui.Color(0xFF22AA44),
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

/// Сколько пикселей картинки подходят под условие (whole-image scan).
Future<int> _countPixels(ui.Image image, bool Function(ui.Color) test) async {
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final bytes = data.buffer.asUint8List();
  var count = 0;
  for (var i = 0; i + 3 < bytes.length; i += 4) {
    final c = ui.Color.fromARGB(
      bytes[i + 3],
      bytes[i],
      bytes[i + 1],
      bytes[i + 2],
    );
    if (test(c)) count++;
  }
  return count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('без рамки — карточка с полями и подписью, а не голый кадр', () async {
    final png = await QuestShot.compose(
      await _scene(),
      frame: QuestShotFrame.none,
    );
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

  test('рамка устройства не режет кадр: видны оба края сцены', () async {
    final flat = await _decode(
      await QuestShot.compose(await _scene(), frame: QuestShotFrame.none),
    );
    addTearDown(flat.dispose);
    final phone = await _decode(
      await QuestShot.compose(await _scene(), frame: QuestShotFrame.phone),
    );
    addTearDown(phone.dispose);
    final tablet = await _decode(
      await QuestShot.compose(await _scene(), frame: QuestShotFrame.tablet),
    );
    addTearDown(tablet.dispose);
    final laptop = await _decode(
      await QuestShot.compose(await _scene(), frame: QuestShotFrame.laptop),
    );
    addTearDown(laptop.dispose);

    expect(phone.width, QuestShot.outputWidth.ceil());
    expect(tablet.width, QuestShot.outputWidth.ceil());
    expect(laptop.width, QuestShot.outputWidth.ceil());
    // Пропорции реальные: телефон (9:19.5) выше планшета (3:4), тот выше
    // карточки по кадру, а широкий ноутбук — самый низкий.
    expect(phone.height, greaterThan(tablet.height));
    expect(tablet.height, greaterThan(flat.height));
    expect(flat.height, greaterThan(laptop.height));

    // В центре экрана — синий кадр сцены, а не корпус.
    final center = await _pixel(phone, phone.width ~/ 2, phone.height ~/ 2);
    expect(center.b, greaterThan(center.r));

    // Полосы исходника у обоих краёв переживают вписывание: cover-обрезка
    // срезала бы их полностью (400×300 в экран 9:19.5).
    final red = await _countPixels(
      phone,
      (c) => c.r > 0.45 && c.g < 0.35 && c.b < 0.35,
    );
    final green = await _countPixels(
      phone,
      (c) => c.g > 0.45 && c.r < 0.35 && c.b < 0.35,
    );
    expect(red, greaterThan(200), reason: 'левый край кадра срезан');
    expect(green, greaterThan(200), reason: 'правый край кадра срезан');

    // У самого края холста — фон, а не кадр.
    final nearLeft = await _pixel(phone, 4, phone.height ~/ 2);
    expect(nearLeft.b, lessThan(0.35));
  });

  test('рамка подбирается по пропорциям кадра', () {
    expect(QuestShot.frameForAspect(1206 / 2622), QuestShotFrame.phone);
    expect(QuestShot.frameForAspect(2064 / 2752), QuestShotFrame.tablet);
    expect(QuestShot.frameForAspect(3024 / 1964), QuestShotFrame.laptop);
    // Широкий десктопный экран — ноутбук, почти квадратный — планшет.
    expect(QuestShot.frameForAspect(1680 / 948), QuestShotFrame.laptop);
    expect(QuestShot.frameForAspect(1.0), QuestShotFrame.tablet);
  });
}
