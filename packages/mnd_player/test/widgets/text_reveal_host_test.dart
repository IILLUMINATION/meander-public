// Появление текста в плеере.
//
// Здесь держится главный контракт фичи: анимация — это только то, что МЕЖДУ
// первым и последним кадром. Первый кадр без `textReveal` и последний кадр при
// любом режиме обязаны давать тот же текст, что отдаёт обычный текстовый
// элемент, — иначе поедут и 821 существующий виджет-тест, и все уже написанные
// квесты.
//
// Отдельно проверяются два выключателя, которые обязаны гасить анимацию
// полностью: `suppressInteractions` (симуляция в редакторе) и предпочтение
// игрока.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/quest_provider.dart';
import 'package:mnd_player/providers/text_reveal_preference.dart';
import 'package:mnd_player/widgets/content_display_factory.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _text = 'АБВГДЕЖЗ';

void _usePreference(TextRevealPreference value) {
  // То же хранилище, что в бою: тест гоняет настоящий notifier, а не
  // заглушку провайдера.
  SharedPreferences.setMockInitialValues({
    kPlayerTextRevealPreferenceKey: value.name,
  });
}

ContentItem _item({
  String text = _text,
  String textReveal = 'none',
  double revealSpeed = 40,
}) => ContentItem(
  id: 't1',
  type: 'text',
  text: text,
  textReveal: textReveal,
  revealSpeed: revealSpeed,
);

Widget _host(
  ContentItem item, {
  bool suppressInteractions = false,
  bool allowTextCopy = false,
}) {
  return ProviderScope(
    overrides: [
      questProvider('q1').overrideWith(
        (ref) => Quest(id: 'q1', title: 'Тест', allowTextCopy: allowTextCopy),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: TextRevealHost(
          item: item,
          questId: 'q1',
          onNavigateToNode: (_) {},
          suppressInteractions: suppressInteractions,
        ),
      ),
    ),
  );
}

/// Хост не стартует, пока предпочтение не приехало с диска: один кадр на
/// загрузку, потом ещё один на перестройку после старта.
Future<void> _mount(WidgetTester tester, Widget host) async {
  await tester.pumpWidget(host);
  await tester.pump();
  await tester.pump();
}

/// 8 видимых символов при 40 символах в секунду = 200 мс.
const Duration _full = Duration(milliseconds: 240);

/// Что видит игрок. Под набираемым блоком лежит невидимая (Opacity 0) копия
/// целого текста — она держит габарит, чтобы колонка не прыгала на каждый
/// символ, но в проверка содержимого попадать не должна.
List<String> _visibleTexts(WidgetTester tester) {
  final result = <String>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    final reserved = find
        .ancestor(
          of: find.byWidget(rich),
          matching: find.byWidgetPredicate(
            (w) => w is Opacity && w.opacity == 0,
          ),
        )
        .evaluate()
        .isNotEmpty;
    if (reserved) continue;
    final text = rich.text.toPlainText();
    if (text.isNotEmpty) result.add(text);
  }
  return result;
}

Finder _shown(String value) => find.text(value, findRichText: true);

void main() {
  setUp(() => _usePreference(TextRevealPreference.normal));

  testWidgets('без анимации первый кадр показывает весь текст', (tester) async {
    // Негативный контроль: этот тест проходил бы и до правок модели. Если он
    // падает — анимация включается сама по себе, а не по флагу автора.
    await _mount(tester, _host(_item()));
    expect(_visibleTexts(tester), [_text]);
  });

  testWidgets('typewriter начинает с пустого блока и добирает текст до конца', (
    tester,
  ) async {
    await _mount(tester, _host(_item(textReveal: 'typewriter')));
    expect(_visibleTexts(tester), isEmpty);

    await tester.pump(const Duration(milliseconds: 100));
    expect(_visibleTexts(tester), ['АБВГ']);

    await tester.pump(_full);
    await tester.pump();
    expect(_visibleTexts(tester), [_text]);
  });

  testWidgets('посередине набора видно ровно столько, сколько прошло', (
    tester,
  ) async {
    await _mount(tester, _host(_item(textReveal: 'typewriter')));
    await tester.pump(const Duration(milliseconds: 100));
    // Половина пути от 8 символов = 4.
    expect(_visibleTexts(tester), ['АБВГ']);
  });

  testWidgets('тап по набираемому тексту досматривает его мгновенно', (
    tester,
  ) async {
    await _mount(tester, _host(_item(textReveal: 'typewriter')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_visibleTexts(tester), ['АБ']);

    await tester.tap(find.byType(TextRevealHost));
    await tester.pump();
    expect(_visibleTexts(tester), [_text]);
  });

  testWidgets('fade затемняет целый блок, а не набирает его', (tester) async {
    await _mount(tester, _host(_item(textReveal: 'fade')));

    // Текст сразу полный — анимируется только непрозрачность.
    expect(_shown(_text), findsOneWidget);
    final dimmed = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .where((w) => w.opacity < 1.0)
        .toList();
    expect(dimmed, isNotEmpty);
  });

  testWidgets('симуляция редактора стоит на месте: набор выключен', (
    tester,
  ) async {
    await _mount(
      tester,
      _host(_item(textReveal: 'typewriter'), suppressInteractions: true),
    );
    expect(_visibleTexts(tester), [_text]);
  });

  testWidgets('игрок выключил анимацию — получает весь текст сразу', (
    tester,
  ) async {
    _usePreference(TextRevealPreference.off);
    await _mount(tester, _host(_item(textReveal: 'typewriter')));
    expect(_visibleTexts(tester), [_text]);
  });

  testWidgets('набор не показывает служебные знаки markdown', (tester) async {
    // Главный смысл плана префикса: игрок никогда не видит сырые `**`, `](` и
    // осколки тегов. Без плана на этих кадрах они бы мелькали.
    final item = _item(
      text: '**жирный** текст',
      textReveal: 'typewriter',
      revealSpeed: 20,
    );
    await _mount(tester, _host(item));
    for (var step = 0; step < 12; step++) {
      await tester.pump(const Duration(milliseconds: 20));
      for (final visible in _visibleTexts(tester)) {
        expect(
          visible.contains('*'),
          isFalse,
          reason: 'протёк маркер: $visible',
        );
      }
    }
    await tester.pump(const Duration(seconds: 1));
    expect(_visibleTexts(tester).join(), 'жирный текст');
  });

  testWidgets('«Быстро» домножает скорость автора', (tester) async {
    // 8 символов при 40/с и «Быстро» (×2) = 100 мс, но у набора есть пол в
    // 120 мс — на 150 мс текст уже полный. Без множащего предпочтение было бы
    // 200 мс, и на этом кадре набор ещё шёл бы.
    _usePreference(TextRevealPreference.fast);
    await _mount(tester, _host(_item(textReveal: 'typewriter')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(_visibleTexts(tester), [_text]);
  });

  testWidgets('«Медленно» делит скорость автора пополам', (tester) async {
    // ×0.5 → 400 мс: на том же кадре в 150 мс набрано 3 символа из 8.
    _usePreference(TextRevealPreference.slow);
    await _mount(tester, _host(_item(textReveal: 'typewriter')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(_visibleTexts(tester), ['АБВ']);
  });
  testWidgets('по умолчанию текст нельзя выделить и скопировать', (
    tester,
  ) async {
    await _mount(tester, _host(_item()));
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('автор включил копирование — текст выделяется', (tester) async {
    await _mount(tester, _host(_item(), allowTextCopy: true));
    expect(find.byType(SelectionArea), findsOneWidget);
  });
}
