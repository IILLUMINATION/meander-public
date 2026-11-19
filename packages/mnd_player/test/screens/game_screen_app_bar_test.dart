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

/// Системный «назад»: вызываем тот же колбэк, что Flutter зовёт из
/// `handlePopRoute` у `PopScope` (сам канал в widget-тесте недоступен).
Future<void> systemBack(WidgetTester tester) async {
  final scope =
      tester
              .widgetList(
                find.byWidgetPredicate((widget) => widget is PopScope),
              )
              .first
          as PopScope;
  scope.onPopInvokedWithResult?.call(false, null);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('редкие кнопки шапки — в подменю, а не в ряд с «назад»', (
    tester,
  ) async {
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
  });

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

  /// Шапка игры с квестом, у которого включён/выключен шаг назад.
  Future<void> pumpGameScreen(
    WidgetTester tester, {
    required bool stepBack,
    bool isTesting = true,
    bool isActive = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        // Значение синхронное (FutureOr): тест про шапку, а не про загрузку.
        questProvider('test-quest').overrideWith(
          (ref) =>
              Quest(id: 'test-quest', title: 'Тест', allowStepBack: stepBack),
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
            isTesting: isTesting,
            isActive: isActive,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    if (find.byTooltip('Ещё').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Ещё'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
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

  testWidgets('системный «назад» без шага назад спрашивает подтверждение', (
    tester,
  ) async {
    await pumpGameScreen(tester, stepBack: false, isTesting: false);
    await systemBack(tester);
    expect(find.text('Выйти из квеста?'), findsOneWidget);
    expect(find.text('Остаться'), findsOneWidget);

    await tester.tap(find.text('Остаться'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Выйти из квеста?'), findsNothing);
  });

  testWidgets('в тестовом режиме системный «назад» выходит без модалки', (
    tester,
  ) async {
    await pumpGameScreen(tester, stepBack: false);
    await systemBack(tester);
    expect(find.text('Выйти из квеста?'), findsNothing);
  });

  testWidgets('неактивная игровая вкладка не перехватывает «назад»', (
    tester,
  ) async {
    await pumpGameScreen(
      tester,
      stepBack: false,
      isTesting: false,
      isActive: false,
    );
    expect(find.byType(PopScope), findsNothing);
    expect(find.text('Выйти из квеста?'), findsNothing);
  });

  testWidgets('системный «назад» с шагом назад не выходит из квеста', (
    tester,
  ) async {
    await pumpGameScreen(tester, stepBack: true);
    await systemBack(tester);
    expect(find.text('Выйти из квеста?'), findsNothing);
    expect(find.text('Это начало квеста — назад некуда'), findsOneWidget);
  });
}
