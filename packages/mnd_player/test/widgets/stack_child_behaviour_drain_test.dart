// Рантайм: виджет, который запускает поведение сам, обязан слить из движка
// ВСЁ его наследие, а не только дельту переменных.
//
// Скрипт слоя стека (и ребёнка ряда/колонки, и конца видео) ядро исполняет по
// прямой просьбе плеера: `next_item` таких айтемов не видит. При этом движок
// раскладывает последствия по разным очередям: переменные — в dirty-дельту,
// звуки — в `_internal_audio_queue`, `open_link` — во внешние команды, `wait` —
// в pacing-шаги. Если слить только дельту, звук из onAppear доживёт до
// следующего слива и заиграет уже в другой сцене, а чужие pacing-кадры
// наложатся на новую ноду.
//
// Нужен собранный `.so` (как в `item_hidden_by_engine_test.dart`): движок
// настоящий, без заглушек.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/widgets/items/game_stack_widget.dart';

final String? _soPath = () {
  final env = Platform.environment['MND_FFI_SO'];
  if (env != null && File(env).existsSync()) return env;
  for (final candidate in [
    '../../target/release/libmnd_ffi.so',
    '../../crates/mnd-ffi/target/release/libmnd_ffi.so',
  ]) {
    if (File(candidate).existsSync()) return File(candidate).absolute.path;
  }
  return null;
}();

final Object? skipIfNoSo = _soPath == null
    ? 'libmnd_ffi.so не найден: cargo build --release -p mnd-ffi (или MND_FFI_SO)'
    : false;

void main() {
  late MeanderGameEngine engine;

  setUpAll(() async {
    if (_soPath == null) return;
    await initRustCore(externalLibrary: ExternalLibrary.open(_soPath!));
    engine = await MeanderGameEngine.create(
      questId: 'q1',
      config: {
        'id': 'q1',
        'title': 'Q',
        'version': '1.0.0',
        'startNodeId': 'n1',
      },
      nodesJson: {'nodes': []},
      platformOs: 'linux',
    );
  });

  tearDownAll(() {
    if (_soPath != null) engine.dispose();
  });

  /// Стек со слоем, у которого есть onAppear-скрипт. Файл несуществующий —
  /// движок его просто не находит, но сам факт запуска поведения важен:
  /// наследие в очередях мы кладём руками ниже.
  ContentItem stackWithAppearLayer() => ContentItem(
    id: 's1',
    type: 'stack',
    stackHeight: 120,
    children: [
      ContentItem(
        id: 'layer',
        type: 'text',
        text: 'слой',
        behaviours: const [
          ContentTrigger(event: 'onAppear', script: 'scripts/gone.json'),
        ],
      ),
    ],
  );

  /// Реальные FFI-ответы не крутятся в fake-async зоне виджет-теста: кадры
  /// прокручиваем парой `runAsync` + `pump` (тот же приём, что в
  /// `image_resource_expr_test.dart`). Признак окончания синхронизации —
  /// переменная доехала в `gameStateProvider`: это последний шаг слития,
  /// очереди к нему уже опустошены.
  Future<void> settleUntilSynced(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    for (var i = 0; i < 40; i++) {
      if (container.read(gameStateProvider).variables.containsKey('HP')) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    throw StateError('Синхронизация после onAppear так и не завершилась');
  }

  Future<ProviderContainer> render(WidgetTester tester) async {
    final container = ProviderContainer()
      ..listen(gameStateProvider, (_, __) {});
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: GameStackWidget(
                item: stackWithAppearLayer(),
                questId: 'q1',
                engine: engine,
                onInteract: (_) {},
                onInputSubmitted: (_, __) {},
                onComplete: () {},
                onTransition: (_) {},
                onNavigateToNode: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await settleUntilSynced(tester, container);
    return container;
  }

  group('слияние очередей onAppear', skip: skipIfNoSo, () {
    testWidgets('onAppear слоя не оставляет в движке непрослушанных команд', (
      tester,
    ) async {
      // Наследие исполнения: звук, ссылка и кадр `wait` — в очередях движка.
      engine.setStateVariable('_internal_audio_queue', [
        {'type': 'play_sound', 'audio_id': 'a.mp3', 'volume': 1.0},
      ]);
      engine.setStateVariable('_internal_external_commands', [
        {'type': 'open_link', 'url': 'https://example.com'},
      ]);
      engine.setStateVariable('_internal_delay_queue', [
        {'type': 'delay', 'ms': 50, 'variables': {}, 'tables': {}, 'audio': []},
      ]);
      engine.setStateVariable('HP', 7);

      final container = await render(tester);

      // Переменная обязана дойти до клиента — слить очереди, потеряв
      // состояние, хуже, чем не слить ничего.
      expect(container.read(gameStateProvider).variables['HP'], 7);
      final drained = await tester.runAsync(() async {
        return {
          'audio': await engine.drainAudio(),
          'external': await engine.drainExternal(),
          'delays': await engine.drainDelaySteps(),
        };
      });
      expect(drained!['audio'], {'commands': isEmpty});
      expect(drained['external'], {'commands': isEmpty});
      expect(drained['delays'], isEmpty);
    });
  });
}
