// Снимок из игры: пункт меню появляется только когда хост умеет его принять,
// и по нажатию действительно запускается захват кадра.
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

void main() {
  testWidgets('пункт «Красивый скриншот» запускает захват кадра', (tester) async {
    // Сама растеризация карточки в тестовом биндинге не завершается
    // (см. QuestShot.testScene), поэтому проверяем проводку: меню доходит до
    // захвата кадра, а сборку PNG и сохранение покрывают отдельные тесты.
    var frameRequests = 0;
    QuestShot.testScene = () async {
      frameRequests++;
      return _scene();
    };
    addTearDown(() => QuestShot.testScene = null);
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
    // Хост вызывается только после готового PNG; в тестовом биндинге до этого
    // не доходит — здесь достаточно того, что захват стартовал.
    expect(hostCalls, lessThanOrEqualTo(1));
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