// Сквозной прогон Dart-обёртки хоста плагинов через настоящий FFI-мост:
// установка → событие → команды/переменные/хранилище. Требует собранный
// release-`.so` (`cargo build --release -p mnd-ffi`).

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/engine/plugin_host.dart';
import 'package:mnd_core/src/gen/frb_generated.dart' as gen;

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

const _manifest =
    '{"id":"mnd.test.inventory","name":"Инвентарь","version":"1.0.0","sdk":"1",'
    '"entry":"main.lua","permissions":["ui","quest","storage","events","navigation"],'
    '"hooks":["item_press"]}';

const _source = '''
mnd.on('item_press', function(payload)
  local key = 'pressed:' .. tostring(payload.id)
  mnd.storage.set(key, (mnd.storage.get(key) or 0) + 1)
  mnd.vars.set('hits', (mnd.vars.get('hits') or 0) + 1)
  mnd.ui.toast('Нажато ' .. tostring(payload.id))
  mnd.emit('custom.counter', {count = mnd.vars.get('hits')})
end)
''';

void main() {
  final so = _soPath;
  if (so == null) {
    test(
      'FFI-мост',
      () {},
      skip: 'libmnd_ffi.so не собран: melos run ffi:build:host',
    );
    return;
  }

  setUpAll(() async {
    await gen.RustLib.init(externalLibrary: ExternalLibrary.open(so));
    MeanderPluginHost.reset();
  });

  tearDown(() => MeanderPluginHost.reset());

  test('register rejects a manifest with unknown permission', () async {
    final result = await MeanderPluginHost.register(
      manifestJson: _manifest.replaceFirst('"ui"', '"filesystem"'),
      source: '',
    );
    expect(result.ok, isFalse);
    expect(result.errors, isNotEmpty);
  });

  test('event hook produces commands, var writes and a dirty storage', () async {
    expect(
      (await MeanderPluginHost.register(manifestJson: _manifest, source: _source)).ok,
      isTrue,
    );
    expect(await MeanderPluginHost.activeHooks(), contains('item_press'));

    final dispatch = await MeanderPluginHost.invokeEvent(
      event: 'item_press',
      payload: const {'id': 'key'},
      context: const PluginCallContext(
        questId: 'q1',
        nodeId: 'n1',
        vars: {'hits': 1},
        nowMs: 1000,
      ),
    );

    expect(dispatch.errors, isEmpty);
    final commands = dispatch.commands;
    expect(commands, hasLength(1));
    expect(commands.single.kind, 'toast');
    expect(commands.single.text, 'Нажато key');
    expect(dispatch.varWrites, {'hits': 2});
    expect(dispatch.storages['mnd.test.inventory']!['pressed:key'], 1);
    expect(dispatch.hasWork, isTrue);
  });

  test('second run accumulates through storage and manifests are listed', () async {
    expect(
      (await MeanderPluginHost.register(
        manifestJson: _manifest,
        source: _source,
        storage: const {'pressed:key': 41},
      )).ok,
      isTrue,
    );
    final dispatch = await MeanderPluginHost.invokeEvent(
      event: 'item_press',
      payload: const {'id': 'key'},
    );
    expect(dispatch.storages['mnd.test.inventory']!['pressed:key'], 42);

    final listed = await MeanderPluginHost.manifests();
    expect(listed.map((m) => m['id']), contains('mnd.test.inventory'));
    expect(await MeanderPluginHost.permissions('mnd.test.inventory'), contains('ui'));
  });

  test('denied permission is an error, not a silent skip', () async {
    expect(
      (await MeanderPluginHost.register(
        manifestJson:
            '{"id":"mnd.test.mute","name":"Mute","version":"1.0.0","sdk":"1",'
            '"entry":"main.lua","permissions":[],"hooks":["quest_start"]}',
        source: "mnd.on('quest_start', function() mnd.ui.toast('нельзя') end)",
      )).ok,
      isTrue,
    );
    final dispatch = await MeanderPluginHost.invokeEvent(event: 'quest_start');
    final outcome = dispatch.outcomes.singleWhere(
      (item) => item.pluginId == 'mnd.test.mute',
    );
    expect(outcome.commands, isEmpty);
    expect(outcome.error, contains('ui'));
  });

  test('infinite loop is cut by the instruction budget', () async {
    expect(
      (await MeanderPluginHost.register(
        manifestJson:
            '{"id":"mnd.test.spin","name":"Spin","version":"1.0.0","sdk":"1",'
            '"entry":"main.lua","permissions":[],"hooks":["quest_start"]}',
        source: "mnd.on('quest_start', function() while true do end end)",
      )).ok,
      isTrue,
    );
    final dispatch = await MeanderPluginHost.invokeEvent(event: 'quest_start');
    final outcome = dispatch.outcomes.singleWhere(
      (item) => item.pluginId == 'mnd.test.spin',
    );
    expect(outcome.error, contains('бюджет'));
  });
}
