// Обводка текста в веб-плеере: слой-контур обязан рисоваться той же кистью,
// что у нативного плеера и превью редактора (ContentItem.textOutlinePaint),
// иначе автор настраивает толщину по одному рендеру, а играет другой.
//
// Негативный контроль: в `item_view.dart` `_rich` игнорирует `stroke` — тогда
// тесты 1 и 3 падают (штриховых слоёв нет), а тест 2 остаётся зелёным, потому
// что он и есть проверка «без цвета обводки нет».

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/content_item.dart';
import 'package:mnd_web_player/item_view.dart';
import 'package:mnd_web_player/player.dart';
import 'package:mnd_web_player/quest_bundle.dart';

import 'quest_bundle_test.dart' show mndBytes;

const _outline = Color(0xFFFF0000);

final _questFiles = <String, String>{
  'config.json': jsonEncode({
    'id': 'outline-quest',
    'title': 'Обводка',
    'startNodeId': 'n1',
  }),
  'nodes.json': jsonEncode({
    'nodes': [
      {'id': 'n1', 'title': 'Первая', 'content': {'items': []}},
    ],
    'groups': [],
  }),
};

ContentItem _textItem({
  String text = 'тест обводки',
  Color? outlineColor,
  double? outlineWidth,
}) => ContentItem(
  id: 't1',
  type: 'text',
  text: text,
  textOutlineColor: outlineColor,
  textOutlineWidth: outlineWidth,
);

/// Штриховые кисти, реально стоящие в дереве спанов.
List<Paint> _strokePaints(WidgetTester tester) {
  final result = <Paint>[];
  void collect(InlineSpan span) {
    final paint = span.style?.foreground;
    if (paint != null && paint.style == PaintingStyle.stroke) result.add(paint);
    if (span is TextSpan) span.children?.forEach(collect);
  }

  for (final element in tester.allElements) {
    final widget = element.widget;
    if (widget is RichText) collect(widget.text);
    if (widget is Text) {
      final paint = widget.style?.foreground;
      if (paint != null && paint.style == PaintingStyle.stroke) {
        result.add(paint);
      }
      final span = widget.textSpan;
      if (span != null) collect(span);
    }
  }
  return result;
}

/// Плеер один на файл: `initRustCore()` второй раз бросает «Should not
/// initialize flutter_rust_bridge twice», а движок тут нужен лишь для
/// синхронного `resolveText`. Заводится в первом тесте — под `runAsync`, потому
/// что что FRB-ответ на порт под fake-async зоной `testWidgets` не приходит.
QuestPlayer? _player;

Future<QuestPlayer> _questPlayer(WidgetTester tester) async {
  final built = _player;
  if (built != null) return built;
  QuestPlayer? created;
  await tester.runAsync(() async {
    created = QuestPlayer(
      decodeMnd(mndBytes(_questFiles), 'https://meander.sbs/quest-src/o.mnd'),
    );
    await created!.start();
  });
  final player = created!;
  // Без живой сцены тест «без цвета» был бы зелёным по неверной причине:
  // движок молчит — и штрихов, разумеется, нет.
  expect(player.phase, PlayPhase.playing, reason: player.errorMessage);
  return _player = player;
}

Future<void> renderText(WidgetTester tester, ContentItem item) async {
  final player = await _questPlayer(tester);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: ItemView(player: player, item: item),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('обводка текста в веб-плеере', () {
    tearDownAll(() => _player?.dispose());

    testWidgets('цвет даёт штриховой слой под буквами', (tester) async {
      await renderText(tester, _textItem(outlineColor: _outline));
      final strokes = _strokePaints(tester);
      expect(strokes, isNotEmpty);
      expect(strokes.every((p) => p.color == _outline), isTrue);
      expect(
        strokes.every((p) => p.strokeWidth == kTextOutlineWidthDefault),
        isTrue,
        reason: 'без толщины — дефолт из модели',
      );
    });

    testWidgets('без цвета штрихового слоя нет', (tester) async {
      await renderText(tester, _textItem());
      expect(_strokePaints(tester), isEmpty);
    });

  
  testWidgets('фрагментная обводка даёт тени только выделенному куску', (
    tester,
  ) async {
    await renderText(
      tester,
      _textItem(text: 'до [outline=#0000FF:3]синий[/outline] после'),
    );
    final shadowed = <TextStyle>[];
    void collect(InlineSpan span) {
      if (span is! TextSpan) return;
      if (span.style?.shadows?.isNotEmpty ?? false) shadowed.add(span.style!);
      span.children?.forEach(collect);
    }

    for (final element in tester.allElements) {
      final widget = element.widget;
      if (widget is RichText) collect(widget.text);
    }
    expect(shadowed, isNotEmpty);
    expect(
      shadowed.every(
        (s) => s.shadows!.every((shadow) => shadow.color == const Color(0xFF0000FF)),
      ),
      isTrue,
    );
    expect(shadowed.every((s) => s.shadows!.length == 8), isTrue);
  });

  testWidgets('item-обводка не дублирует фрагментные тени в штриховом слое', (
    tester,
  ) async {
    await renderText(
      tester,
      _textItem(
        text: '[outline=#00FF00]зелёный[/outline] текст',
        outlineColor: _outline,
      ),
    );
    final strokes = _strokePaints(tester);
    expect(strokes, isNotEmpty);
    bool shadowedStroke(InlineSpan span) {
      if (span is! TextSpan) return false;
      if (span.style?.foreground?.style == PaintingStyle.stroke &&
          (span.style?.shadows?.isNotEmpty ?? false)) {
        return true;
      }
      return (span.children ?? const <InlineSpan>[]).any(shadowedStroke);
    }

    final found = tester.allWidgets.whereType<RichText>().any(
          (w) => shadowedStroke(w.text),
        );
    expect(found, isFalse);
  });

  testWidgets('markdown-разновидности уходят в тот же контур', (
      tester,
    ) async {
      await renderText(
        tester,
        _textItem(
          text: '# Заголовок\n\n**жирный** и [color=#00FF00]зелёный[/color]',
          outlineColor: _outline,
          outlineWidth: 5,
        ),
      );
      final strokes = _strokePaints(tester);
      expect(strokes, isNotEmpty);
      expect(strokes.every((p) => p.strokeWidth == 5.0), isTrue);
      expect(
        strokes.every((p) => p.color == _outline),
        isTrue,
        reason: 'inline-цвет не должен просвечивать в контуре',
      );
    });
  });
}
