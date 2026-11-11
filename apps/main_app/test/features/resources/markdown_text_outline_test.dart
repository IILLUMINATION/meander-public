// «Обводка текста — как в стеке, только у обычного текста ноды».
//
// Настройка живёт в паре полей `textOutlineColor`/`textOutlineWidth`, их же
// рисует плеер. Риск здесь не в рендере, а в пути значения: панель оформления
// → `MarkdownEditorResult` → айтем. Тем же путём умерла «Печать» при создании
// текста (#286): редактор значение возвращал, а сборщик нового айтема его терял.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ:
//  * «обводка при создании доезжает до айтема» падает, если `_result()` или
//    `addText` потеряли поле — тогда в файле квеста ключа нет;
//  * «тяга ползунка меняет толщину» падает, если панель пишет значение в
//    локальную копию;
//  * «убрать снимает пару» падает, если вызывающая сторона не ставит
//    `clearTextOutline` — тогда контур переживает «убрать»;
//  * «превью несёт контур» падает, если контур не дошёл до конфигов
//    предпросмотра; контур — штриховой слой кистью из ядра, а не копии глифа.

import 'package:canvas_app/features/editor/screens/node_content/content_editor_logic.dart';
import 'package:canvas_app/features/resources/screens/markdown_editor_screen.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:flutter/material.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _outline = Color(0xFFFF0000);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Телефонное окно 420×760 — в нём панель оформления открывается шитом
  /// (на широком окне это диалог, но контролы те же).
  Future<void> pumpPhone(WidgetTester tester, Widget home) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 760);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: home)));
    await tester.pumpAndSettle();
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Оформление текста'));
    await tester.pumpAndSettle();
  }

  Future<void> closePanel(WidgetTester tester) async {
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
  }

  Future<MarkdownEditorResult?> editExisting(
    WidgetTester tester, {
    String initialText = 'текст',
    Color? initialOutlineColor,
    double? initialOutlineWidth,
    Future<void> Function(WidgetTester tester)? insidePanel,
  }) async {
    MarkdownEditorResult? result;
    await pumpPhone(
      tester,
      Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result = await Navigator.push<MarkdownEditorResult>(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) => MarkdownEditorScreen(
                      initialText: initialText,
                      questId: 'q1',
                      initialTextOutlineColor: initialOutlineColor,
                      initialTextOutlineWidth: initialOutlineWidth,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await openPanel(tester);
    if (insidePanel != null) await insidePanel(tester);
    await closePanel(tester);
    await tester.tap(find.byTooltip('Закрыть и сохранить'));
    await tester.pumpAndSettle();
    return result;
  }

  /// Путь автора: тап по плашке → диалог цвета → «Применить».
  Future<void> pickOutlineColor(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('md_outline_swatch')));
    await tester.pumpAndSettle();
    expect(find.text('Цвет обводки'), findsOneWidget);
    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();
  }

  /// Штриховой слой обводки: `foreground` со штриховой кистью. Тени в превью
  /// больше не используются — они давали раздвоенный контур.
  bool outlineInSpan(InlineSpan? span) {
    if (span is! TextSpan) return false;
    final fg = span.style?.foreground;
    if (fg != null &&
        fg.style == PaintingStyle.stroke &&
        fg.color == _outline) {
      return true;
    }
    return span.children?.any(outlineInSpan) ?? false;
  }

  /// Все штриховые кисти дерева span'ов.
  List<Paint> strokesIn(InlineSpan? span) {
    if (span is! TextSpan) return const [];
    final fg = span.style?.foreground;
    return [
      if (fg != null && fg.style == PaintingStyle.stroke) fg,
      for (final child in span.children ?? const <InlineSpan>[])
        ...strokesIn(child),
    ];
  }

  testWidgets('обводка при создании текста доезжает до нового айтема', (
    tester,
  ) async {
    ContentItem? created;
    await pumpPhone(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                created = await ContentEditorLogic(
                  context: context,
                  questId: 'quest-1',
                  currentNodeId: 'n1',
                ).addText();
              },
              child: const Text('создать текст'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('создать текст'));
    await tester.pumpAndSettle();

    await openPanel(tester);
    await pickOutlineColor(tester);
    await closePanel(tester);
    await tester.tap(find.byTooltip('Закрыть и сохранить'));
    await tester.pumpAndSettle();

    expect(created, isNotNull, reason: 'редактор должен вернуть новый айтем');
    expect(
      created!.textOutlineColor,
      isNotNull,
      reason:
          'addText собирал ContentItem без обводки — выбор редактора '
          'умирал на первом выходе',
    );
    // Дефолтная толщина в файл не пишется: её подставляет плеер.
    expect(created!.toJson().containsKey('textOutlineColor'), isTrue);
    expect(created!.toJson().containsKey('textOutlineWidth'), isFalse);
  });

  testWidgets('тяга ползунка отдаёт толщину в результат', (tester) async {
    final result = await editExisting(
      tester,
      initialOutlineColor: _outline,
      insidePanel: (t) async {
        // Появление выключено, поэтому ползунков ровно два: размер и обводка.
        expect(find.byType(Slider), findsNWidgets(2));
        await t.drag(
          find.byKey(const ValueKey('md_outline_slider')),
          const Offset(-140, 0),
        );
        await t.pumpAndSettle();
      },
    );

    expect(result?.textOutlineColor, _outline);
    expect(
      result?.textOutlineWidth,
      lessThan(2.0),
      reason: 'тяга влево обязана уменьшить толщину',
    );
  });

  testWidgets('«убрать» снимает и цвет, и толщину', (tester) async {
    final result = await editExisting(
      tester,
      initialOutlineColor: _outline,
      initialOutlineWidth: 5,
      insidePanel: (t) async {
        expect(find.text('5 px'), findsWidgets);
        await t.tap(find.text('убрать'));
        await t.pumpAndSettle();
      },
    );

    expect(result?.textOutlineColor, isNull);
    expect(
      result?.textOutlineWidth,
      isNull,
      reason: 'толщина без цвета — мёртвое поле в файле квеста',
    );
  });

  testWidgets('без обводки редактор не плодит ключей в json', (tester) async {
    final result = await editExisting(tester);

    expect(result?.textOutlineColor, isNull);
    final item = ContentItem(
      id: 't1',
      type: 'text',
      text: result?.text,
      textOutlineColor: result?.textOutlineColor,
      textOutlineWidth: result?.textOutlineWidth,
    );
    expect(item.toJson().containsKey('textOutlineColor'), isFalse);
  });

  testWidgets('обводка подсвечивает кнопку оформления и видна в превью', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      const MarkdownEditorScreen(
        initialText: 'важный текст',
        questId: 'q1',
        initialTextOutlineColor: _outline,
        initialTextOutlineWidth: 3,
      ),
    );

    final badge = tester.widget<Badge>(
      find.ancestor(
        of: find.byIcon(Icons.tune_rounded),
        matching: find.byType(Badge),
      ),
    );
    expect(badge.isLabelVisible, isTrue, reason: 'обводка — тоже оформление');

    await tester.tap(find.text('Предпросмотр'));
    await tester.pumpAndSettle();

    // Буквы остаются залиты цветом: контур — штриховой слой под глифами, а не
    // вместо них, ровно как в игре.
    final spans = <InlineSpan?>[
      ...tester.widgetList<Text>(find.byType(Text)).map((w) => w.textSpan),
      ...tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text),
    ];
    expect(
      spans.any(outlineInSpan),
      isTrue,
      reason: 'превью обязано показывать обводку',
    );
    final strokes = <Paint>[for (final span in spans) ...strokesIn(span)];
    expect(strokes, isNotEmpty, reason: 'нет штриховой кисти');
    expect(
      strokes.every((p) => p.color == _outline && p.strokeWidth == 3.0),
      isTrue,
      reason: 'кисть обязана нести цвет и толщину из полей айтема',
    );
    expect(
      spans.whereType<TextSpan>().any(
        (s) => s.style?.shadows?.isNotEmpty ?? false,
      ),
      isFalse,
      reason: 'копии глифа со сдвигом в превью не используются',
    );
  });
}
