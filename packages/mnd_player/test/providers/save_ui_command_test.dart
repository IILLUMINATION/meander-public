// Регрессия: блок `save_operation` («Открыть сохранение») кладёт команду в
// очередь внешних команд движка. Клиент обязан её вычитать после КАЖДОГО
// исполнения скрипта: при входе в ноду, при нажатии и после live-reload.
// Иначе `open_saves` срабатывает только на старте квеста: очередь просто
// никто не опустошает.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';
import 'package:mnd_player/screens/game_screen.dart';
import 'package:mnd_player/screens/load_game_screen.dart';
import 'package:mnd_player/services/save_game_provider.dart';

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

const _questId = 'save-ui-command-quest';
final _key = (questId: _questId, docKey: 'test');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;

  setUpAll(() async {
    if (_soPath == null) return;
    await initRustCore(externalLibrary: ExternalLibrary.open(_soPath!));
    appDir = await Directory.systemTemp.createTemp('mnd_save_ui_test');
    final questDir = Directory('${appDir.path}/quests/$_questId')
      ..createSync(recursive: true);
    Directory('${questDir.path}/scripts').createSync(recursive: true);
    File('${questDir.path}/config.json').writeAsStringSync(
      jsonEncode({
        'id': _questId,
        'title': 'Save UI',
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
                {
                  'type': 'button',
                  'id': 'btn',
                  'text': 'Открыть сохранения',
                  'scriptTriggers': {'onPress': 'scripts/open_press.json'},
                },
              ],
            },
          },
          {
            'id': 'n2',
            'title': 'Сохранения',
            'scriptAssetId': 'scripts/open_enter.json',
            'content': {
              'items': [
                {'type': 'text', 'id': 't2', 'text': 'список'},
              ],
            },
          },
        ],
      }),
    );
    File('${questDir.path}/scripts/open_press.json').writeAsStringSync(
      jsonEncode({
        'name': 'open_press',
        'blocks': [
          {
            'type': 'event',
            'eventType': 'onPress',
            'children': [
              {'type': 'save_operation', 'operation': 'open'},
            ],
          },
        ],
      }),
    );
    File('${questDir.path}/scripts/open_enter.json').writeAsStringSync(
      jsonEncode({
        'name': 'open_enter',
        'blocks': [
          {
            'type': 'event',
            'eventType': 'onNodeEnter',
            'children': [
              {'type': 'save_operation', 'operation': 'open'},
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

  (ProviderContainer, GameScreenNotifier) startSession() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(gameScreenProvider(_key), (_, __) {});
    final notifier = container.read(gameScreenProvider(_key).notifier);
    return (container, notifier);
  }

  Map<String, dynamic>? takeCommand(ProviderContainer container) {
    final command = container.read(saveUiCommandProvider);
    container.read(saveUiCommandProvider.notifier).state = null;
    return command;
  }

  test(
    'save_operation open при нажатии доходит до UI',
    skip: skipIfNoSo,
    () async {
      final (container, notifier) = startSession();
      await notifier.loadInitialNode('n1');
      final item = ContentItem.fromJson(
        Map<String, dynamic>.from(
          (notifier.state.currentNode!.content['items'] as List).first as Map,
        ),
      );

      await notifier.handleInteraction(item, 'scripts/open_press.json');

      expect(takeCommand(container), {'type': 'open_saves'});
    },
  );

  test(
    'save_operation open при входе в ноду доходит до UI',
    skip: skipIfNoSo,
    () async {
      final (container, notifier) = startSession();
      await notifier.loadInitialNode('n1');
      takeCommand(container);

      await notifier.loadNode('n2');

      expect(takeCommand(container), {'type': 'open_saves'});
    },
  );

  test(
    'save_operation open при тестовом старте с ноды доходит до UI',
    skip: skipIfNoSo,
    () async {
      final (container, notifier) = startSession();

      await notifier.loadInitialNode('n2');

      expect(takeCommand(container), {'type': 'open_saves'});
    },
  );

  testWidgets(
    'команда open_saves от экрана открывает список сохранений',
    skip: _soPath == null,
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: GameScreen(
              questId: _questId,
              docKey: 'save-ui-widget',
              isTesting: true,
              // Движок в этом тесте не нужен: проверяем доставку уже
              // готовой команды до UI-экрана.
              preflight: () async => false,
            ),
          ),
        ),
      );
      await tester.pump();

      container.read(saveUiCommandProvider.notifier).state = {
        'type': 'open_saves',
      };
      await tester.pump();
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byType(LoadGameScreen).evaluate().isNotEmpty) break;
      }
      expect(find.byType(LoadGameScreen), findsOneWidget);
    },
  );
}
