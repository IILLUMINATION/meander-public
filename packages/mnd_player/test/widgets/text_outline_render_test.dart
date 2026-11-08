// Обводка текста в плеере.
//
// Модель (`ContentItem.textOutlineColor/Width`) уже покрыта тестами mnd_core.
// Здесь проверяется ровно то, что видит игрок: под слоем с заливкой ложится
// второй слой, у которого тот же текст, та же вёрстка, но глифы рисуются
// штриховой кистью цвета обводки.
//
// Негативный контроль: без `textOutlineColor` штриховой кисти в дереве быть не
// должно ни в одной ветке ('wrap'/markdown и 'scale'), то есть тест падает,
// если удалить нижний слой или если он рисуется всегда.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/widgets/content_display_factory.dart';

const _outline = Color(0xFFFF0000);

/// Все штриховые кисти, которыми реально что-то рисуется: стили span'ов,
/// стили `Text` и унаследованный `DefaultTextStyle`.
List<Paint> _strokePaints(WidgetTester tester) {
  final found = <Paint>[];
  void addStyle(TextStyle? style) {
    final fg = style?.foreground;
    if (fg != null && fg.style == PaintingStyle.stroke) found.add(fg);
  }

  void walkSpan(InlineSpan span) {
    if (span is! TextSpan) return;
    addStyle(span.style);
    for (final child in span.children ?? const <InlineSpan>[]) {
      walkSpan(child);
    }
  }

  for (final element in tester.allElements) {
    final widget = element.widget;
    if (widget is RichText) walkSpan(widget.text);
    if (widget is Text) {
      addStyle(widget.style);
      final span = widget.textSpan;
      if (span != null) walkSpan(span);
    }
  }
  return found;
}

/// Плоский список текстов всех нарисованных строк — по нему видно, что слой
/// обводки несёт ровно то же содержимое, что и слой заливки.
List<String> _drawnTexts(WidgetTester tester) {
  return [
    for (final widget in tester.allWidgets)
      if (widget is RichText) widget.text.toPlainText(),
  ];
}

Future<void> renderText(
  WidgetTester tester,
  ContentItem item, {
  String textFit = 'wrap',
  double? revealFraction,
}) async {
  final container = ProviderContainer()..listen(gameStateProvider, (_, __) {});
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: TextItemWidget(
              item: item,
              questId: 'q1',
              onNavigateToNode: (_) {},
              textFit: textFit,
              revealFraction: revealFraction,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ContentItem textItem({
  required String text,
  Color? outlineColor,
  double? outlineWidth,
}) {
  return ContentItem(
    id: 't1',
    type: 'text',
    text: text,
    textOutlineColor: outlineColor,
    textOutlineWidth: outlineWidth,
  );
}

void main() {
  testWidgets('обводка: под текстом лежит штриховой слой того же текста', (
    tester,
  ) async {
    const source =
        '# Заголовок\n\nобычный [color=#00FF00]зелёный[/color] текст';
    await renderText(
      tester,
      textItem(text: source, outlineColor: _outline, outlineWidth: 4),
    );

    final strokes = _strokePaints(tester);
    expect(strokes, isNotEmpty, reason: 'ни одного штрихового слоя');
    expect(strokes.every((p) => p.color == _outline), isTrue);
    expect(strokes.every((p) => p.strokeWidth == 4.0), isTrue);

    // Оба слоя несут один и тот же набор строк, иначе обводка разъехалась бы
    // с заливкой.
    final texts = _drawnTexts(tester);
    expect(texts.length % 2, 0, reason: 'слои не парятся: $texts');
  });

  testWidgets('без цвета обводки штрихового слоя нет вообще', (tester) async {
    await renderText(tester, textItem(text: 'просто текст'));
    expect(_strokePaints(tester), isEmpty);
  });

  testWidgets('толщина без цвета игнорируется, дефолт и потолок применяются', (
    tester,
  ) async {
    await renderText(tester, textItem(text: 'текст', outlineWidth: 9));
    expect(
      _strokePaints(tester),
      isEmpty,
      reason: 'толщина не включает обводку',
    );

    await renderText(tester, textItem(text: 'текст', outlineColor: _outline));
    final defaults = _strokePaints(tester);
    expect(defaults, isNotEmpty);
    expect(
      defaults.every((p) => p.strokeWidth == kTextOutlineWidthDefault),
      isTrue,
      reason: 'без толщины должен работать дефолт',
    );

    await renderText(
      tester,
      textItem(text: 'текст', outlineColor: _outline, outlineWidth: 99),
    );
    final clamped = _strokePaints(tester);
    expect(clamped, isNotEmpty);
    expect(clamped.every((p) => p.strokeWidth == kTextOutlineWidthMax), isTrue);
  });

  testWidgets('режим scale тоже получает слой обводки', (tester) async {
    await renderText(
      tester,
      textItem(
        text: '**жирный** текст',
        outlineColor: _outline,
        outlineWidth: 3,
      ),
      textFit: 'scale',
    );
    final strokes = _strokePaints(tester);
    expect(strokes, isNotEmpty);
    expect(
      strokes.every((p) => p.color == _outline && p.strokeWidth == 3.0),
      isTrue,
    );
    expect(_drawnTexts(tester).where((t) => t.contains('жирный')).length, 2);
  });

  testWidgets('фрагментная обводка — штриховой слой своего цвета и толщины', (
    tester,
  ) async {
    await renderText(
      tester,
      textItem(text: 'до [outline=#0000FF:3]синий[/outline] после'),
    );

    final strokes = _strokePaints(
      tester,
    ).where((p) => p.color == const Color(0xFF0000FF)).toList();
    expect(strokes, isNotEmpty, reason: 'у фрагмента нет штрихового слоя');
    expect(strokes.every((p) => p.strokeWidth == 3.0), isTrue);
    // Копий глифа со сдвигом быть не должно: они давали раздвоенный контур.
    for (final widget in tester.allWidgets.whereType<RichText>()) {
      expect(_anyShadows(widget.text), isFalse, reason: 'остались тени');
    }

    // Слой контура — отдельный: заливка и контур, как у обводки айтема.
    final texts = _drawnTexts(tester);
    expect(texts.length % 2, 0, reason: 'слои не парятся: $texts');
  });

  testWidgets('толщина фрагмента нормируется ядром', (tester) async {
    await renderText(
      tester,
      textItem(text: '[outline=#00FF00:99]жирно[/outline]'),
    );
    expect(
      _strokePaints(tester)
          .where((p) => p.color == const Color(0xFF00FF00))
          .every((p) => p.strokeWidth == kTextOutlineWidthMax),
      isTrue,
    );

    await renderText(
      tester,
      textItem(text: '[outline=#00FF00]тонко[/outline]'),
    );
    expect(
      _strokePaints(tester)
          .where((p) => p.color == const Color(0xFF00FF00))
          .every((p) => p.strokeWidth == kTextOutlineWidthDefault),
      isTrue,
    );
  });

  testWidgets('фрагмент в scale-режиме тоже штриховой, а не теневой', (
    tester,
  ) async {
    await renderText(
      tester,
      textItem(text: '[outline=#0000FF:4]синий[/outline] обычный'),
      textFit: 'scale',
    );
    final strokes = _strokePaints(tester);
    expect(
      strokes.where((p) => p.color == const Color(0xFF0000FF)),
      isNotEmpty,
    );
    for (final widget in tester.allWidgets.whereType<RichText>()) {
      expect(_anyShadows(widget.text), isFalse);
    }
  });

  testWidgets('фрагмент поверх обводки айтема: свой цвет важнее', (
    tester,
  ) async {
    await renderText(
      tester,
      textItem(
        text: '[outline=#00FF00]зелёный[/outline] текст',
        outlineColor: _outline,
      ),
    );
    final strokes = _strokePaints(tester);
    expect(
      strokes.any((p) => p.color == const Color(0xFF00FF00)),
      isTrue,
      reason: 'у фрагмента нет своей кисти',
    );
    expect(
      strokes.any((p) => p.color == _outline),
      isTrue,
      reason: 'остальной текст должен обводиться цветом айтема',
    );
    expect(strokes.every((p) => p.style == PaintingStyle.stroke), isTrue);
  });

  testWidgets('анимация появления режет и слой обводки', (tester) async {
    const full = 'абвгдежз';
    await renderText(
      tester,
      textItem(text: full, outlineColor: _outline),
      revealFraction: 0.5,
    );

    final texts = _drawnTexts(tester);
    final stroked = <String>[];
    // Слой обводки — тот RichText, чьи span'ы штриховые.
    for (final widget in tester.allWidgets) {
      if (widget is! RichText) continue;
      final hasStroke = _spanHasStroke(widget.text);
      if (hasStroke) stroked.add(widget.text.toPlainText());
    }
    expect(stroked, isNotEmpty);
    for (final shown in stroked) {
      expect(
        shown.length,
        lessThan(full.length),
        reason: 'обводка набрана целиком: $shown',
      );
      expect(full.startsWith(shown), isTrue);
    }
    expect(
      texts,
      contains(full),
      reason: 'невидимый резерв габарита обязан быть полным',
    );
  });
}

/// Есть ли в дереве span'ов хоть одна тень (старая техника обводки).
bool _anyShadows(InlineSpan root) {
  if (root is! TextSpan) return false;
  if (root.style?.shadows?.isNotEmpty ?? false) return true;
  return (root.children ?? const <InlineSpan>[]).any(_anyShadows);
}

bool _spanHasStroke(InlineSpan root) {
  if (root is! TextSpan) return false;
  final fg = root.style?.foreground;
  if (fg != null && fg.style == PaintingStyle.stroke) return true;
  return (root.children ?? const <InlineSpan>[]).any(_spanHasStroke);
}
