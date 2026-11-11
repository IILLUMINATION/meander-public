// Превью снимка: кадр показывается до сохранения, рамка пересобирает
// карточку, а «В скриншоты»/«Экспортировать» возвращают готовый PNG.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/quest_shot.dart';
import 'package:mnd_player/widgets/quest_shot_preview.dart';

/// 1×1 прозрачный PNG: превью не должно падать на декодировании.
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('превью показывает кадр и пересобирает рамку', (tester) async {
    final frames = <QuestShotFrame>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showQuestShotPreview(
                  context,
                  initialFrame: QuestShotFrame.phone,
                  compose: (frame) async {
                    frames.add(frame);
                    return _tinyPng;
                  },
                ),
                child: const Text('открыть'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    expect(find.text('Снимок сцены'), findsOneWidget);
    expect(frames, [QuestShotFrame.phone]);

    await tester.tap(find.text('iPad'));
    await tester.pumpAndSettle();
    expect(frames, [QuestShotFrame.phone, QuestShotFrame.tablet]);

    await tester.ensureVisible(find.text('Ноутбук'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ноутбук'));
    await tester.pumpAndSettle();
    expect(frames.last, QuestShotFrame.laptop);
  });

  testWidgets('«В скриншоты» отдаёт действие и последнюю рамку', (tester) async {
    QuestShotResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showQuestShotPreview(
                    context,
                    compose: (_) async => _tinyPng,
                  );
                },
                child: const Text('открыть'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('В скриншоты'));
    await tester.pumpAndSettle();

    expect(result?.action, QuestShotAction.save);
    expect(result?.png, _tinyPng);
    expect(find.text('Снимок сцены'), findsNothing);
  });

  testWidgets('без экспорта кнопка скрыта', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showQuestShotPreview(
                  context,
                  canExport: false,
                  compose: (_) async => _tinyPng,
                ),
                child: const Text('открыть'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    expect(find.text('Экспортировать'), findsNothing);
    expect(find.text('В скриншоты'), findsOneWidget);
  });
}
