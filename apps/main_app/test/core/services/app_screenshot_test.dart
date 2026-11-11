// Снимок экрана делается внутри приложения (RenderRepaintBoundary), а не
// внешним скриншотерем: на Wayland окно снаружи снять нельзя. Проверяем, что
// кадр действительно превращается в файл-PNG по заданному каталогу.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/core/services/app_screenshot.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mnd_shot_');
    AppScreenshot.overrideDirectory = temp.path;
  });

  tearDown(() {
    AppScreenshot.overrideDirectory = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  testWidgets('хоткей выключен без каталога снимков', (tester) async {
    AppScreenshot.overrideDirectory = '';
    expect(AppScreenshot.enabled, isFalse);
    expect(await AppScreenshot.capture(), isNull);
  });

  testWidgets('кадр сохраняется в PNG', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: AppScreenshot.boundaryKey,
          child: const ColoredBox(
            color: Color(0xFF123456),
            child: SizedBox(width: 64, height: 32),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    String? path;
    await tester.runAsync(() async {
      path = await AppScreenshot.capture();
    });

    expect(path, isNotNull, reason: 'кадр должен быть записан');
    final file = File(path!);
    expect(file.existsSync(), isTrue);
    // Сигнатура PNG: без неё «снимок» открывается как битый файл.
    expect(
      file.readAsBytesSync().sublist(0, 8),
      [137, 80, 78, 71, 13, 10, 26, 10],
    );
  });
}
