// Регрессия #219: при переходе в ноду пропадал её верхний ряд.
//
// Очередь раскрытия (`revealNextItem`) живёт на поколении `_revealGeneration`.
// Поколение увеличивается в начале `loadNode` — а список айтемов новой ноды
// ставится в state только в конце `_applyNodeView`, после FFI-вызовов и
// дискового I/O. В этом окне движок уже на новой ноде, а старые виджеты ещё
// живы и зовут `revealNextItem()` через `onComplete`: цикл получает НОВОЕ
// поколение, съедает айтем #0 (`revealed_count` в движке уже увеличен),
// добавляет его в state — и `_applyNodeView` затирает список пустым.
// Верхний ряд сцены исчезает без единой ошибки в логе.
//
// Здесь окно воспроизводится напрямую: пока `loadNode` в полёте, внешний
// наблюдатель (таймер = тот самый leftover-виджет) тыкает `revealNextItem()`
// каждый оборот событийного цикла. Без `_revealSuspended` первый айтем
// теряется; с ним — нет.
//
// Движок настоящий (нужен собранный `.so`, как в `item_hidden_by_engine_test.dart`):
// проверка именно над последовательностью движка, без заглушек.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';

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

const _questId = 'reveal-gate-quest';

final _key = (questId: _questId, docKey: 'test');

/// Нода, в которую идут оба сценария: три ряда, терять первый нельзя.
const _nodeRows = ['row1', 'row2', 'row3'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;

  setUpAll(() async {
    if (_soPath == null) return;
    await initRustCore(externalLibrary: ExternalLibrary.open(_soPath!));
    appDir = await Directory.systemTemp.createTemp('mnd_reveal_gate_test');
    final questDir = Directory('${appDir.path}/quests/$_questId')
      ..createSync(recursive: true);
    File('${questDir.path}/config.json').writeAsStringSync(
      jsonEncode({
        'id': _questId,
        'title': 'Gate',
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
                {'type': 'text', 'id': 'start', 'text': 'старт'},
              ],
            },
          },
          {
            'id': 'n2',
            'title': 'Инвентарь',
            'content': {
              'items': [
                for (final id in _nodeRows)
                  {'type': 'text', 'id': id, 'text': id},
              ],
            },
          },
        ],
      }),
    );
    // Мок path_provider: `FileStorage` кэширует каталог приложения, поэтому
    // обработчик ставится до первого обращения к нему.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? appDir.path
              : null,
        );
    // Нотификатор поднимает два AudioPlayer'а — в тесте платформы нет, поэтому
    // каналы глушатся (в квесте музыки нет, играть всё равно нечему).
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

  /// Нотификатор живой сессии: `gameScreenProvider` — autoDispose, поэтому
  /// держим подписку, как это делает игровой экран.
  (ProviderContainer, GameScreenNotifier) startSession() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(gameScreenProvider(_key), (_, __) {});
    final notifier = container.read(gameScreenProvider(_key).notifier);
    return (container, notifier);
  }

  List<String> revealedIds(ProviderContainer container) => container
      .read(gameScreenProvider(_key))
      .revealedItems
      .map((item) => item.id)
      .toList();

  /// Очередь раскрытия — fire-and-forget: ждём, пока она отдаст хотя бы один
  /// айтем (или пока не кончится отведённое время).
  Future<void> waitFirstItem(ProviderContainer container) async {
    for (var i = 0; i < 400; i++) {
      if (container.read(gameScreenProvider(_key)).revealedItems.isNotEmpty) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 5));
    }
    fail('очередь раскрытия не отдала ни одного айтема');
  }

  /// Тот самый leftover-виджет: тыкает «я отрисовался, давай следующий айтем»
  /// на каждом обороте цикла — то есть рано или поздно попадает в окно между
  /// сменой поколения и установкой списка новой ноды.
  Timer hammer(GameScreenNotifier notifier) => Timer.periodic(
    const Duration(milliseconds: 1),
    (_) => notifier.revealNextItem(),
  );

  group('раскрытие первого айтема ноды', skip: skipIfNoSo, () {
    test('переход loadNode: ряд #0 новой ноды доходит до списка', () async {
      final (container, notifier) = startSession();
      await notifier.loadInitialNode('n1');
      await waitFirstItem(container);
      expect(revealedIds(container), ['start']);

      final ticks = hammer(notifier);
      try {
        await notifier.loadNode('n2');
      } finally {
        ticks.cancel();
      }
      await waitFirstItem(container);

      // Без блокировки окна здесь ['row2', …] или ['row2', 'row3'] — row1
      // съеден движком и затёрт `_applyNodeView`.
      expect(revealedIds(container).first, 'row1');
      expect(notifier.currentNodeId, 'n2');
    });

    test('перезагрузка из редактора: ряд #0 остаётся на месте', () async {
      final (container, notifier) = startSession();
      await notifier.loadInitialNode('n2');
      await waitFirstItem(container);
      expect(revealedIds(container), ['row1']);

      final ticks = hammer(notifier);
      try {
        await notifier.reloadNodeAfterEditor('n2');
      } finally {
        ticks.cancel();
      }
      await waitFirstItem(container);

      expect(revealedIds(container).first, 'row1');
    });

    test('ни один ряд ноды не потерян, если очередь пинают всё время',
        () async {
      // Полный проход: движок отдаёт все три ряда по одному шагу — список
      // обязан содержать их все, в исходном порядке.
      final (container, notifier) = startSession();
      await notifier.loadInitialNode('n1');
      await waitFirstItem(container);

      final ticks = hammer(notifier);
      try {
        await notifier.loadNode('n2');
      } finally {
        ticks.cancel();
      }
      for (var i = 0; i < 5; i++) {
        notifier.revealNextItem();
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final ids = revealedIds(container);
      expect(ids.first, 'row1');
      expect(ids, containsAllInOrder(_nodeRows));
    });
  });

  // Во время cross-fade (fade/page) уходящая нода остаётся в дереве на
  // 300–820 мс — дольше, чем идёт `loadNode`. Её `TimerItemWidget` продолжает
  // тикать и, догорев, зовёт `onComplete` уже в новой ноде: очередь съедает
  // её айтем, обгоняет `wait_input`/`delay`, и нода показывается целиком
  // сразу. Поэтому шаг помечается сценой, для которой собран виджет.
  group('шаг из ушедшей сцены', skip: skipIfNoSo, () {
    Future<void> waitItems(ProviderContainer container, int count) async {
      for (var i = 0; i < 400; i++) {
        if (container.read(gameScreenProvider(_key)).revealedItems.length >=
            count) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 5));
      }
      fail('очередь не отдала $count айтемов');
    }

    test('не съедает айтем новой ноды', () async {
      final (container, notifier) = startSession();
      await notifier.loadInitialNode('n1');
      await waitFirstItem(container);
      final oldPresentation =
          container.read(gameScreenProvider(_key)).presentationId;
      expect(oldPresentation, isNotEmpty);

      await notifier.loadNode('n2');
      await waitItems(container, 1);
      final before = revealedIds(container);
      expect(before, ['row1']);

      // Догоревший таймер уходящей сцены.
      notifier.revealNextItem(fromPresentationId: oldPresentation);
      await Future.delayed(const Duration(milliseconds: 80));
      expect(revealedIds(container), before, reason: 'чужой шаг съел row2');

      // Шаг текущей сцены по-прежнему двигает очередь.
      notifier.revealNextItem(
        fromPresentationId:
            container.read(gameScreenProvider(_key)).presentationId,
      );
      await waitItems(container, 2);
      expect(revealedIds(container), ['row1', 'row2']);
    });
  });
}
