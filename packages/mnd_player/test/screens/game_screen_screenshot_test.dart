// Снимок из игры: пункт меню появляется только когда хост умеет его принять,
// и по нажатию действительно запускается захват кадра.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';
import 'package:mnd_player/screens/game_screen.dart';
import 'package:mnd_player/utils/quest_shot.dart';

Future<bool> _neverStart() async => false;

/// Кадр сцены для теста: настоящий `toImage` с границы виджета в тестовом
/// биндинге не втягивается в новую картинку (см. [QuestShot.testScene]).
Future<ui.Image> _scene() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 300, 400),
    ui.Paint()..color = const ui.Color(0xFF203050),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(300, 400);
  picture.dispose();
  return image;
}

final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('пункт «Красивый скриншот» запускает захват кадра', (tester) async {
    // Сама растеризация карточки в тестовом биндинге не завершается
    // (см. QuestShot.testScene), поэтому проверяем проводку: меню доходит до
    // захвата кадра, а сборку PNG и сохранение покрывают отдельные тесты.
    var frameRequests = 0;
    final composedFrames = <QuestShotFrame>[];
    QuestShot.testScene = () async {
      frameRequests++;
      return _scene();
    };
    // Растеризация PNG в фейковом времени не завершается — подменяем сборку.
    QuestShot.testCompose = (_, frame) async {
      composedFrames.add(frame);
      return _tinyPng;
    };
    addTearDown(() {
      QuestShot.testScene = null;
      QuestShot.testCompose = null;
    });
    var hostCalls = 0;
    final container = ProviderContainer(
      overrides: [
        gameScreenHooksProvider.overrideWithValue(
          GameScreenHooks(
            onScreenshot: (questId, png) async => hostCalls++,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: GameScreen(
            questId: 'test-quest',
            preflight: _neverStart,
            isTesting: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byTooltip('Ещё'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Красивый скриншот'), findsOneWidget);
    await tester.tap(find.text('Красивый скриншот'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(frameRequests, 1);
    // Сначала превью: кадр собирается под выбранную рамку.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Снимок сцены'), findsOneWidget);
    expect(composedFrames, [QuestShot.lastFrame]);
    expect(hostCalls, 0, reason: 'без подтверждения ничего не сохраняется');

    // Смена рамки в превью пересобирает кадр.
    await tester.tap(find.text('iPad'));
    await tester.pump();
    expect(composedFrames.last, QuestShotFrame.tablet);

    await tester.tap(find.text('В скриншоты'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(hostCalls, 1);
  });

  testWidgets('без хоста пункта снимка нет', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: GameScreen(
            questId: 'test-quest',
            preflight: _neverStart,
            isTesting: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Ещё'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Переменные'), findsOneWidget);
    expect(find.text('Красивый скриншот'), findsNothing);
  });
}