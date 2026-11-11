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
    // Офскрин-рендер под устройство поднимает второй GameScreen — в тесте
    // подменяем его готовым кадром.
    final deviceRequests = <QuestShotFrame>[];
    QuestShot.testDeviceScene = (frame) async {
      deviceRequests.add(frame);
      return _scene();
    };
    // Растеризация PNG в фейковом времени не завершается — подменяем сборку.
    final composedFrames = <QuestShotFrame>[];
    QuestShot.testCompose = (_, frame) async {
      composedFrames.add(frame);
      return _tinyPng;
    };
    addTearDown(() {
      QuestShot.testDeviceScene = null;
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

    // Широкое тестовое окно (800×600) открывает MacBook.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Снимок сцены'), findsOneWidget);
    expect(composedFrames, [QuestShotFrame.laptop]);
    expect(deviceRequests, [QuestShotFrame.laptop]);
    expect(hostCalls, 0, reason: 'без подтверждения ничего не сохраняется');

    // Смена рамки перерисовывает квест в размерах устройства и собирает кадр.
    await tester.tap(find.text('iPhone 17'));
    await tester.pump();
    expect(deviceRequests.last, QuestShotFrame.phone);
    expect(composedFrames.last, QuestShotFrame.phone);

    await tester.tap(find.text('В скриншоты'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(hostCalls, 1);
  });

  testWidgets('кадр для мокапа не запускает и не гасит игровую сессию', (
    tester,
  ) async {
    var started = 0;
    var ended = 0;
    final container = ProviderContainer(
      overrides: [
        gameScreenHooksProvider.overrideWithValue(
          GameScreenHooks(
            onGameSessionStarted: (_) => started++,
            onGameSessionEnded: (_) => ended++,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: SizedBox(
            width: 402,
            height: 874,
            child: GameScreen(
              questId: 'test-quest',
              shotOnly: true,
              isTesting: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // Копия только рисует состояние — старт сессии пропущен.
    expect(started, 0);

    // Убираем копию: настоящая сессия (и её хук завершения) не должна
    // пострадать.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(ended, 0);
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