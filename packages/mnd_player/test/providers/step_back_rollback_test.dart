// Шаг назад обязан откатывать состояние, а не только менять ноду: иначе
// игрок возвращается на сцену, где уже куплено/потрачено, и квест ломается.
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

const _questId = 'step-back-rollback-quest';
final _key = (questId: _questId, docKey: 'test');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;

  setUpAll(() async {
    if (_soPath == null) return;
    await initRustCore(externalLibrary: ExternalLibrary.open(_soPath!));
    appDir = await Directory.systemTemp.createTemp('mnd_step_back_test');
    final questDir = Directory('${appDir.path}/quests/$_questId')
      ..createSync(recursive: true);
    File('${questDir.path}/config.json').writeAsStringSync(
      jsonEncode({
        'id': _questId,
        'title': 'Step back',
        'version': '1.0.0',
        'startNodeId': 'n1',
        'allowStepBack': true,
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
            'content': {
              'items': [
                {'type': 'text', 'id': 't2', 'text': 'вторая'},
              ],
            },
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

  test(
    'stepBack возвращает переменные и снимает изменения ушедшей ноды',
    skip: skipIfNoSo,
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(gameScreenProvider(_key), (_, __) {});
      final notifier = container.read(gameScreenProvider(_key).notifier);
      final gameState = container.read(gameStateProvider.notifier);

      await notifier.loadInitialNode('n1');
      expect(notifier.currentNodeId, 'n1');
      expect(notifier.canStepBack, isFalse);

      gameState.setVariable('золото', 10);
      await notifier.loadNode('n2');
      expect(notifier.currentNodeId, 'n2');
      expect(notifier.canStepBack, isTrue);

      gameState.setVariable('золото', 0);
      gameState.setVariable('потрачено', true);

      expect(await notifier.stepBack(), isTrue);
      expect(notifier.currentNodeId, 'n1');
      expect(notifier.canStepBack, isFalse);
      expect(container.read(gameStateProvider).variables['золото'], 10);
      expect(
        container.read(gameStateProvider).variables.containsKey('потрачено'),
        isFalse,
      );
      expect(await notifier.stepBack(), isFalse);
    },
  );
}
