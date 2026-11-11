// Регрессия (#242): шапка игрового экрана не должна разрастаться до
// неширокого телефона.
//
// На «Последнем лесе» (Android, 360 px) в actions стояло шесть пилюль,
// AppBar не вмещал их и рисовал «Громкость» поверх стрелки «назад». Редкие
// кнопки — появление текста, переменные (тест-режим) и редактирование ноды —
// уехали в подменю «Ещё», часто используемые остались в шапке.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/quest_descriptor.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/providers/quest_provider.dart';
import 'package:mnd_player/screens/game_screen.dart';

Future<bool> _neverStart() async => false;

void main() {
  testWidgets(
    'редкие кнопки шапки — в подменю, а не в ряд с «назад»',
    (tester) async {
      // Узкий телефон: ровно та ширина, на которой баг был виден.
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var editTaps = 0;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: GameScreen(
              questId: 'test-quest',
              // Префлайт = false: сессия не стартует, движок/FFI не нужны.
              preflight: _neverStart,
              isTesting: true,
              onEditNode: () => editTaps++,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Переполнение шапки фреймворк оформляет как исключение layoutа.
      expect(tester.takeException(), isNull);

      // Сам баг: AppBar не лезет в ширину, а уводит actions влево, и
      // «Громкость» рисуется поверх стрелки «назад».
      expect(
        tester.getRect(find.byTooltip('Назад')).right,
        lessThan(tester.getRect(find.byTooltip('Громкость')).left),
      );

      // В шапке только частые кнопки.
      expect(find.byTooltip('Громкость'), findsOneWidget);
      expect(find.byTooltip('Сохранить'), findsOneWidget);
      expect(find.byTooltip('Загрузить'), findsOneWidget);
      // Редкие — не видны, пока меню не открыто.
      expect(find.byTooltip('Переменные'), findsNothing);
      expect(find.byTooltip('Редактировать ноду'), findsNothing);
      expect(find.byTooltip('Ещё'), findsOneWidget);

      await tester.tap(find.byTooltip('Ещё'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Переменные'), findsOneWidget);
      expect(find.text('Редактировать ноду'), findsOneWidget);

      await tester.tap(find.text('Редактировать ноду'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(editTaps, 1);
    },
  );

  testWidgets('скрипт прячет и возвращает верхнюю панель', (tester) async {
    // Панель — часть сцены: переменную сеет движок из настройки квеста,
    // затем её меняет блок set_top_panel. Здесь проверяем саму реакцию
    // экрана на переменную, не поднимая FFI-движок.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final gameState = container.read(gameStateProvider.notifier);
    gameState.setVariable('_internal_top_panel_hidden', true);

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
    expect(find.byTooltip('Громкость'), findsNothing);
    expect(find.byTooltip('Сохранить'), findsNothing);

    // Вернуть панель — тот же экран, без пересоздания.
    gameState.setVariable('_internal_top_panel_hidden', false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Громкость'), findsOneWidget);
    expect(find.byTooltip('Сохранить'), findsOneWidget);
  });

  test('шаг назад ведёт на предыдущую ноду истории', () {
    // История пишется именами нод; текущая — последняя запись, шаг назад
    // берёт предпоследнюю.
    expect(stepBackTarget(['A', 'B']), 'A');
    expect(stepBackTarget(['A', 'B', 'C']), 'B');
    // В начале квеста (или в битом сейве с пустыми записями) — некуда.
    expect(stepBackTarget([]), isNull);
    expect(stepBackTarget(['A']), isNull);
    expect(stepBackTarget(['A', '']), 'A');
    expect(stepBackTarget(['', '']), isNull);
  });

  /// Шапка игры с квестом, у которого включён/выключен шаг назад.
  Future<void> pumpGameScreen(WidgetTester tester, {required bool stepBack}) async {
    final container = ProviderContainer(
      overrides: [
        // Значение синхронное (FutureOr): тест про шапку, а не про загрузку.
        questProvider('test-quest').overrideWith(
          (ref) => Quest(
            id: 'test-quest',
            title: 'Тест',
            allowStepBack: stepBack,
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
  }

  testWidgets('без настройки автора кнопки «Шаг назад» нет', (tester) async {
    await pumpGameScreen(tester, stepBack: false);
    // Меню открылось (в тест-режиме там есть «Переменные»).
    expect(find.text('Переменные'), findsOneWidget);
    expect(find.text('Шаг назад'), findsNothing);
  });

  testWidgets('с настройкой автора в меню есть «Шаг назад»', (tester) async {
    await pumpGameScreen(tester, stepBack: true);
    expect(find.text('Шаг назад'), findsOneWidget);
  });
}
