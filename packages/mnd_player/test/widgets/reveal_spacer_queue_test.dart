// Очередь раскрытия против «молчаливых» айтемов внутри живой ноды.
//
// Сценарий тестера (24.10): картинка → отступ → текст → текст → ожидание
// ввода → задержка → текст. В рабочей ноде без отступа задержка держит
// последний текст, а с отступом всё появляется сразу.
//
// Причина такого класса багов — лишние `onComplete` от молчаливых айтемов:
// каждый лишний шаг прокручивает движок вперёд, и `wait_input`/`delay`
// оказываются позади. Здесь список собран ровно как в игровом экране
// (`ListView.builder` + `RepaintBoundary`, новые айтемы дописываются в конец),
// а шаг очереди приходит из настоящих виджетов фабрики.
//
// Негативный контроль: если вернуть молчаливому айтему повторный шаг
// (пересоздавать `InstantItem` на каждую пересборку списка), счётчик
// `revealed` дойдёт до задержки и текста за ней без ожидания.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/widgets/content_display_factory.dart';

/// Вся нода в порядке движка: индексы совпадают с `next_item`.
final List<ContentItem> _nodeItems = [
  ContentItem(
    id: 'image',
    type: 'image',
    resourcePath: 'res/images/missing.jpg',
  ),
  ContentItem(id: 'spacer', type: 'spacer', padding: 15),
  ContentItem(id: 'text1', type: 'text', text: 'Первый текст'),
  ContentItem(id: 'text2', type: 'text', text: 'Второй текст'),
  ContentItem(id: 'wait', type: 'wait_input', text: 'Нажмите'),
  ContentItem(id: 'delay', type: 'delay', text: '1.0'),
  ContentItem(id: 'text3', type: 'text', text: 'Текст после задержки'),
];

class _RevealHarness extends StatefulWidget {
  const _RevealHarness();

  @override
  State<_RevealHarness> createState() => _RevealHarnessState();
}

class _RevealHarnessState extends State<_RevealHarness> {
  final List<ContentItem> revealed = [];
  final Map<String, int> completions = {};

  @override
  void initState() {
    super.initState();
    revealed.add(_nodeItems.first);
  }

  void _onCompleted(ContentItem owner) {
    completions[owner.id] = (completions[owner.id] ?? 0) + 1;
    if (revealed.length < _nodeItems.length) {
      setState(() => revealed.add(_nodeItems[revealed.length]));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView.builder(
        itemCount: revealed.length,
        key: const ValueKey('game_list_test_0'),
        itemBuilder: (context, index) {
          final item = revealed[index];
          return RepaintBoundary(
            child: ContentDisplayFactory.build(
              item: item,
              questId: 'q1',
              onInteract: (_) {},
              onInputSubmitted: (_, __) {},
              onComplete: () => _onCompleted(item),
              onTransition: (_) {},
              onNavigateToNode: (_) {},
            ),
          );
        },
      ),
    );
  }
}

void main() {
  testWidgets('отступ и картинка не прокручивают очередь через ожидание', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _RevealHarness())),
    );

    // Кадр раскрытия: картинка, отступ, оба текста успевают отдать шаг
    // (они не держат очередь), дальше стоит `wait_input` и ждёт игрока.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final harness = tester.state<_RevealHarnessState>(
      find.byType(_RevealHarness),
    );
    expect(
      harness.revealed.map((e) => e.id).toList(),
      ['image', 'spacer', 'text1', 'text2', 'wait'],
      reason: 'очередь обязана остановиться на ожидании ввода',
    );
    expect(harness.completions.values.every((n) => n == 1), isTrue);

    // Задержка ещё не раскрыта: ждать её бессмысленно, пока не нажали.
    await tester.pump(const Duration(seconds: 2));
    expect(harness.revealed.last.id, 'wait');
  });

  testWidgets('после нажатия задержка держит следующий текст', (tester) async {
    // Высокое окно: ожидание ввода должно быть реально построено, иначе
    // тапать некуда (в дефолтных 800×600 список строится лениво).
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _RevealHarness())),
    );
    // Каждый кадр раскрывает ровно один молчаливый айтем, а последний
    // `setState` применяется на следующем кадре — без него `wait_input`
    // ещё не в дереве.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    final harness = tester.state<_RevealHarnessState>(
      find.byType(_RevealHarness),
    );
    await tester.tap(find.text('Нажмите'));
    await tester.pump();
    await tester.pump();
    expect(harness.revealed.last.id, 'delay');
    expect(find.text('Текст после задержки'), findsNothing);
    expect(harness.completions['delay'] ?? 0, 0);

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(harness.revealed.last.id, 'text3');
    expect(harness.completions['delay'], 1);
  });
}
