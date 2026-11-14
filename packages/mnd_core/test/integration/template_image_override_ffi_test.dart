/// «Сменить картинку» из мастер-шаблона должна работать в копиях (FFI).
///
/// Скрипт мастера адресует картинку по id мастера, а в инстансе шаблона тот
/// же айтем носит производный `tpl_<sha1>` id. Проверяем через реальный
/// Rust-мост: id айтема, который получает клиент, есть в переопределениях.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_core/src/gen/frb_generated.dart' as gen;

String? _soPath() {
  final env = Platform.environment['MND_FFI_SO'];
  if (env != null && File(env).existsSync()) return env;
  for (final c in [
    '../../target/release/libmnd_ffi.so',
    '../target/release/libmnd_ffi.so',
  ]) {
    if (File(c).existsSync()) return File(c).absolute.path;
  }
  return null;
}

final String? soPath = _soPath();
final Object? skipIfNoSo = soPath == null
    ? 'libmnd_ffi.so не найден. Соберите: cargo build -p mnd-ffi --release'
    : false;

Future<MeanderGameEngine> _engine() {
  return MeanderGameEngine.create(
    questId: 'q_tpl',
    config: {
      'id': 'q_tpl',
      'title': 'Templates',
      'version': '1.0.0',
      'startNodeId': 'n1',
    },
    nodesJson: {
      'nodes': [
        {
          'id': 'n1',
          'title': 'Start',
          'scriptAssetId': 'scripts/swap.json',
          'content': {
            'items': [
              {'type': 'column', 'id': 'hud-1', 'templateRef': 'tpl-hud'},
            ],
          },
        },
        {
          'id': 'n2',
          'title': 'Second',
          'content': {
            'items': [
              {'type': 'column', 'id': 'hud-2', 'templateRef': 'tpl-hud'},
            ],
          },
        },
      ],
    },
    templates: [
      {
        'id': 'tpl-hud',
        'name': 'HUD',
        'kind': 'column',
        'payload': {
          'type': 'column',
          'id': 'master-hud',
          'children': [
            {'type': 'image', 'id': 'master-ico', 'resourcePath': 'res/a.png'},
          ],
        },
      },
    ],
    embeddedScripts: {
      'scripts/swap.json': jsonEncode({
        'name': 'swap',
        'blocks': [
          {'type': 'set_image', 'item_id': 'master-ico', 'source': 'res/b.png'},
        ],
      }),
    },
    platformOs: 'linux',
  );
}

void main() {
  if (soPath != null) {
    setUpAll(() async {
      await gen.RustLib.init(
        externalLibrary: ExternalLibrary.open(soPath!),
      );
    });
  }

  group('Шаблоны: переопределение картинки (реальный .so)',
      skip: skipIfNoSo, () {
    test('картинка меняется и в инстансе, который видит клиент', () async {
      final engine = await _engine();
      await engine.startNew();

      final step = await engine.nextItem();
      expect(step.isItem, isTrue);
      final hud = step.item!;
      final ico = (hud['children'] as List).first as Map<String, dynamic>;
      // Клиент рисует картинку по id раскрытого айтема — не мастерского.
      expect(ico['id'], isNot('master-ico'));
      expect(ico['id'], startsWith('tpl_'));

      final raw = await engine.evaluate('_internal_item_sources');
      final overrides = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : raw as Map<String, dynamic>;
      expect(overrides['master-ico'], 'res/b.png',
          reason: 'мастер тоже должен обновиться');
      expect(overrides[ico['id']], 'res/b.png',
          reason: 'картинка в инстансе должна браться из переопределения');
      expect(
        overrides.keys.where((k) => k.toString().startsWith('tpl_')).length,
        greaterThanOrEqualTo(2),
        reason: 'копия в ноде n2 тоже должна получить переопределение',
      );

      engine.dispose();
    });
  });
}