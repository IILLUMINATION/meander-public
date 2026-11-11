// Регрессия: `wait` в скрипте события «При входе в ноду» не задерживал
// переход. `loadNode`/`loadInitialNode` снимают очередь задержек ДО
// `_applyNodeView` (чтобы отрисовать кадр до первой паузы), а ветка
// `view['transition']` внутри неё звала `_paceScriptDelays()` — очередь уже
// пуста, ожидание возвращалось сразу, и `wait` перед `go_to_node` терялся:
// переход случался через ~40 мс вместо задержки.
//
// Та же очередь теперь доигрывается фьючерсом, который ветка перехода
// дожидается. Здесь проверяются оба входа (первая нода и переход в ноду) и
// то, что мутация после `wait` не протекает на экран раньше времени.
//
// Движок настоящий (нужен собранный `.so`, как в `reveal_gate_test.dart`).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';
import 'package:mnd_player/providers/game_state_provider.dart';

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

const _questId = 'node-enter-delay-quest';
final _key = (questId: _questId, docKey: 'test');

/// Задержка скриптов входа. Порог проверки заметно ниже неё: без ожидания
/// переход случается за единицы миллисекунд.
const _waitMs = 400;
const _waitThresholdMs = 300;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;

  setUpAll(() async {
    if (_soPath == null) return;
    await initRustCore(externalLibrary: ExternalLibrary.open(_soPath!));
    appDir = await Directory.systemTemp.createTemp('mnd_node_enter_delay_test');
    final questDir = Directory('${appDir.path}/quests/$_questId')
      ..createSync(recursive: true);
    Directory('${questDir.path}/scripts').createSync(recursive: true);
    File('${questDir.path}/config.json').writeAsStringSync(
      jsonEncode({
        'id': _questId,
        'title': 'Delay',
        'version': '1.0.0',
        'startNodeId': 'n1',
      }),
    );
    File('${questDir.path}/nodes.json').writeAsStringSync(
      jsonEncode({
        'nodes': [
          {
            'id': 'n1',
            'title': 'Старт',
            'content': {
              'items': [
                {'type': 'text', 'id': 't1', 'text': 'старт'},
              ],
            },
          },
          {
            'id': 'n2',
            'title': 'Вторая',
            'scriptAssetId': 'scripts/assign.json',
            'content': {
              'items': [
                {'type': 'text', 'id': 't2', 'text': 'вторая'},
              ],
            },
          },
          {
            'id': 'n3',
            'title': 'Автопереход',
            'scriptAssetId': 'scripts/go.json',
            'content': {
              'items': [
                {'type': 'text', 'id': 't3', 'text': 'ждём'},
              ],
            },
          },
        ],
      }),
    );
    File('${questDir.path}/scripts/assign.json').writeAsStringSync(
      jsonEncode({
        'name': 'assign',
        'blocks': [
          {
            'type': 'event',
            'eventType': 'onNodeEnter',
            'children': [
              {'type': 'wait', 'expression': '$_waitMs'},
              {
                'type': 'assign_variable',
                'variable': 'после_задержки',
                'value': '1',
              },
            ],
          },
        ],
      }),
    );
    File('${questDir.path}/scripts/go.json').writeAsStringSync(
      jsonEncode({
        'name': 'go',
        'blocks': [
          {
            'type': 'event',
            'eventType': 'onNodeEnter',
            'children': [
              {'type': 'wait', 'expression': '$_waitMs'},
              {'type': 'go_to_node', 'node_id': 'n2'},
            ],
          },
        ],
      }),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? appDir.path
              : null,
        );
    // Нотификатор поднимает два AudioPlayer'а — в тесте платформы нет, поэтому
    // каналы глушатся (музыки в квесте нет, играть всё равно нечему).
    for (final channel in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(channel),
            (call) async => null,
          );
    }
  });

  tearDownAll(() async {
    if (_soPath != null && appDir.existsSync()) {
      await appDir.delete(recursive: true);
    }
  });

  /// `gameScreenProvider` — autoDispose, поэтому держим подписку, как это
  /// делает игровой экран.
  (ProviderContainer, GameScreenNotifier) startSession() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(gameScreenProvider(_key), (_, __) {});
    final notifier = container.read(gameScreenProvider(_key).notifier);
    return (container, notifier);
  }

  Object? pacedValue(ProviderContainer container) =>
      container.read(gameStateProvider).variables['после_задержки'];

  /// Дождаться ноды `target` и померить, сколько это заняло.
  Future<int> waitForNode(
    GameScreenNotifier notifier,
    Stopwatch sw,
    String target,
  ) async {
    while (notifier.currentNodeId != target &&
        sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(notifier.currentNodeId, target);
    return sw.elapsedMilliseconds;
  }

  test(
    'wait → go_to_node в onNodeEnter: первая нода ждёт задержку',
    skip: skipIfNoSo,
    () async {
      final (_, notifier) = startSession();
      final sw = Stopwatch()..start();
      await notifier.loadInitialNode('n3');
      final elapsed = await waitForNode(notifier, sw, 'n2');
      expect(
        elapsed,
        greaterThan(_waitThresholdMs),
        reason: 'переход обязан ждать $_waitMs мс из `wait`',
      );
    },
  );

  test(
    'wait → go_to_node в onNodeEnter: переход в ноду ждёт задержку',
    skip: skipIfNoSo,
    () async {
      final (_, notifier) = startSession();
      await notifier.loadInitialNode('n1');
      final sw = Stopwatch()..start();
      await notifier.loadNode('n3');
      final elapsed = await waitForNode(notifier, sw, 'n2');
      expect(
        elapsed,
        greaterThan(_waitThresholdMs),
        reason: 'переход обязан ждать $_waitMs мс из `wait`',
      );
    },
  );

  test(
    'wait в onNodeEnter без перехода: мутация после него выходит по времени',
    skip: skipIfNoSo,
    () async {
      final (container, notifier) = startSession();
      await notifier.loadInitialNode('n2');

      expect(
        pacedValue(container),
        isNull,
        reason: 'значение до `wait` не должно протечь на экран',
      );

      // Ждём появления значения опросом: тест не должен зависеть от того,
      // насколько пунктуален таймер под нагрузкой.
      final sw = Stopwatch()..start();
      while (pacedValue(container) == null &&
          sw.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        pacedValue(container),
        isNotNull,
        reason: 'после `wait` мутация обязана дойти до клиента',
      );
    },
  );
}