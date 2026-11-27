// Эталонные плагины из `plugins/examples/` прогоняются через настоящий
// Rust-хост: манифест проверяется ядром, Lua исполняется в песочнице, а
// наружу выходят команды с UI-спеками, которые рисует клиент.
//
// Это не «тест на моках»: если плагин не собирается, spek отклоняет ядро или
// обработчик падает — тест краснеет. Требует собранный release-`.so`
// (`cargo build --release -p mnd-ffi`).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/engine/plugin_host.dart';
import 'package:mnd_core/src/gen/frb_generated.dart' as gen;
import 'package:mnd_player/widgets/plugin_spec_view.dart';

const _soCandidates = [
  '../../crates/mnd-ffi/target/release/libmnd_ffi.so',
  '../../target/release/libmnd_ffi.so',
];

final String? _soPath = () {
  final env = Platform.environment['MND_FFI_SO'];
  if (env != null && File(env).existsSync()) return env;
  for (final candidate in _soCandidates) {
    if (File(candidate).existsSync()) return File(candidate).absolute.path;
  }
  return null;
}();

/// Каталог репозитория: поднимаемся от рабочей папки пакета до `plugins/`.
final String _repoRoot = () {
  var dir = Directory.current.absolute;
  for (var depth = 0; depth < 5; depth++) {
    if (File(
      '${dir.path}/plugins/examples/status-hud/plugin.json',
    ).existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return Directory.current.absolute.path;
}();

class _Example {
  final String directory;
  final String manifestJson;
  final String source;

  _Example(this.directory)
    : manifestJson = File(
        '$_repoRoot/plugins/examples/$directory/plugin.json',
      ).readAsStringSync(),
      source = File(
        '$_repoRoot/plugins/examples/$directory/main.lua',
      ).readAsStringSync();

  String get id => jsonDecode(manifestJson)['id'] as String;
}

Future<PluginDispatch> _event(
  String event, {
  Map<String, dynamic> payload = const {},
  Map<String, dynamic> vars = const {},
  String nodeId = 'start',
}) => MeanderPluginHost.invokeEvent(
  event: event,
  payload: payload,
  context: PluginCallContext(questId: 'q.test', nodeId: nodeId, vars: vars),
);

Future<PluginDispatch> _press(
  _Example plugin,
  String function, {
  Object? args,
  Map<String, dynamic> vars = const {},
}) => MeanderPluginHost.call(
  pluginId: plugin.id,
  function: function,
  args: args,
  context: PluginCallContext(questId: 'q.test', nodeId: 'start', vars: vars),
);

Future<PluginDispatch> _reveal(
  _Example plugin,
  String contentType,
  String itemId,
  Map<String, dynamic> data,
) => _event(
  'item_reveal',
  payload: {
    'node_id': 'start',
    'item_id': itemId,
    // Ровно то, что пишет редактор: полный тип `<pluginId>:<id>` и поля формы.
    'item_json': {
      'id': itemId,
      'type': 'plugin',
      'pluginId': plugin.id,
      'pluginTypeId': '${plugin.id}:$contentType',
      'pluginData': data,
    },
  },
);

Future<_Example> _install(String directory) async {
  final example = _Example(directory);
  final result = await MeanderPluginHost.register(
    manifestJson: example.manifestJson,
    source: example.source,
  );
  expect(result.ok, isTrue, reason: '$directory: ${result.errors}');
  return example;
}

Iterable<Map<String, dynamic>> _renders(
  PluginDispatch dispatch,
  String target,
) => dispatch.commands
    .where((command) => command.kind == 'render' && command.target == target)
    .map((command) => command.spec);

/// Все надписи виджета в дереве — чтобы искать по спеку не конкретный узел.
List<String> _deepText(Map<String, dynamic> spec) => _deepNodes(spec)
    .expand(
      (node) => [
        for (final key in ['text', 'label'])
          if (node[key] is String) node[key] as String,
      ],
    )
    .toList(growable: false);

/// Все узлы спека: структура карточки интереснее, чем её корень.
List<Map<String, dynamic>> _deepNodes(Map<String, dynamic> spec) {
  final found = <Map<String, dynamic>>[];
  void visit(Object? node) {
    if (node is Map) {
      final typed = node.cast<String, dynamic>();
      found.add(typed);
      visit(typed['children']);
      if (typed['row'] != null) visit(typed['row']);
    } else if (node is List) {
      node.forEach(visit);
    }
  }

  visit(spec);
  return found;
}

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
  });

  tearDown(() => MeanderPluginHost.reset());

  test('манифесты эталонных плагинов принимает ядро', () async {
    for (final directory in [
      'status-hud',
      'achievements',
      'combination-lock',
      'travel-journal',
      'shop',
      'inventory',
    ]) {
      final example = _Example(directory);
      final result = await MeanderPluginHost.register(
        manifestJson: example.manifestJson,
        source: example.source,
      );
      expect(result.ok, isTrue, reason: '$directory: ${result.errors}');
      await MeanderPluginHost.unregister(example.id);
    }
  });

  test(
    'статус-панель: рисует HUD, заводит переменные и лечит отдыхом',
    () async {
      final hud = await _install('status-hud');
      expect(await MeanderPluginHost.activeHooks(), contains('node_enter'));

      final started = await _event('quest_start');
      expect(started.errors, isEmpty);
      expect(started.varWrites['hp'], 100);
      expect(started.varWrites['energy'], 6);
      expect(_renders(started, 'slot:status'), isNotEmpty);

      final rested = await _press(
        hud,
        'rest',
        vars: {'hp': 40, 'hpMax': 100, 'energy': 3},
      );
      expect(rested.errors, isEmpty);
      expect(rested.varWrites['hp'], 65);
      expect(rested.varWrites['energy'], 2);
      expect(rested.commands.map((command) => command.kind), contains('toast'));

      final details = await _press(hud, 'openDetails', vars: {'hp': 65});
      expect(_renders(details, 'slot:details'), isNotEmpty);
      final left = await _event('node_enter', nodeId: 'cave');
      expect(left.commands.map((command) => command.kind), contains('close'));
    },
  );

  test('замок: принимает код и уводит на нужную ноду', () async {
    final lock = await _install('combination-lock');
    const itemId = 'item-77';

    final revealed = await _event(
      'item_reveal',
      payload: {
        'node_id': 'start',
        'item_id': itemId,
        'item_json': {
          'id': itemId,
          'type': 'plugin',
          'pluginId': lock.id,
          'pluginTypeId': 'combinationLock',
          'pluginData': {'code': '42', 'title': 'Дверь', 'targetNode': 'room'},
        },
      },
    );
    expect(revealed.errors, isEmpty);
    final keypad = _renders(revealed, 'item:$itemId').first;
    expect(keypad['type'], 'card');

    // Первая цифра — только пополняем ввод, ноду не меняем.
    final first = await _press(lock, 'press', args: '$itemId|4');
    expect(first.errors, isEmpty);
    expect(first.varWrites, contains('lock_item_77'));
    expect(first.varWrites['lock_item_77'], '4');
    expect(
      first.commands.any((command) => command.kind == 'goto_node'),
      isFalse,
    );

    final second = await _press(
      lock,
      'press',
      args: '$itemId|2',
      vars: {'lock_item_77': '4'},
    );
    final goto = second.commands.firstWhere(
      (command) => command.kind == 'goto_node',
    );
    expect(goto.raw['node'], 'room');
    expect(second.varWrites['unlocked_item_77'], true);
    expect(second.errors, isEmpty);
  });

  test('замок: неверный код сбрасывает ввод и не уходит со сцены', () async {
    final lock = await _install('combination-lock');
    const itemId = 'pad';
    await _event(
      'item_reveal',
      payload: {
        'item_id': itemId,
        'item_json': {
          'id': itemId,
          'type': 'plugin',
          'pluginId': lock.id,
          'pluginData': {'code': '91'},
        },
      },
    );
    final wrong = await _press(lock, 'press', args: '$itemId|1');
    expect(wrong.varWrites['lock_pad'], '1');
    final over = await _press(
      lock,
      'press',
      args: '$itemId|5',
      vars: {'lock_pad': '15'},
    );
    expect(
      over.commands.any((command) => command.kind == 'goto_node'),
      isFalse,
    );
    // Две цифры при двухзначном коде — ввод начинается заново с последней.
    expect(over.varWrites['lock_pad'], '5');
  });

  test('замок: attempts/mode/picture из формы правят механику', () async {
    final lock = await _install('combination-lock');
    const itemId = 'safe';

    Future<Map<String, dynamic>> reveal(Map<String, dynamic> data) async {
      final dispatched = await _event(
        'item_reveal',
        payload: {
          'item_id': itemId,
          'item_json': {
            'id': itemId,
            'type': 'plugin',
            'pluginId': lock.id,
            'pluginTypeId': 'combinationLock',
            'pluginData': data,
          },
        },
      );
      expect(dispatched.errors, isEmpty);
      return _renders(dispatched, 'item:$itemId').first;
    }

    // `asset` из формы доезжает до спека картинкой, `select` «сложный» —
    // прямит набранные цифры, `number` строкой «1» ядро не пугает.
    final spec = await reveal({
      'code': '12',
      'attempts': '1',
      'mode': 'сложный',
      'picture': 'images/safe.png',
      'showProgress': false,
    });
    final children = spec['children'] as List;
    final image = children.whereType<Map<String, dynamic>>().firstWhere(
      (child) => child['type'] == 'image',
    );
    expect(image['src'], 'images/safe.png');
    expect(
      children.whereType<Map<String, dynamic>>().where(
        (child) => child['type'] == 'caption',
      ),
      isEmpty,
      reason: 'showProgress: false — счётчика в карточке нет',
    );

    // Единственная попытка: набранный целиком неверный код — «заклинило»,
    // ввод пуст, счётчик вернулся к полному запасу.
    final missed = await _press(
      lock,
      'press',
      args: '$itemId|7',
      vars: {'lock_safe': '1'},
    );
    expect(missed.errors, isEmpty);
    expect(missed.varWrites['lock_safe'], '');
    expect(missed.varWrites['lockleft_safe'], 1);
    expect(missed.commands.map((command) => command.kind), contains('toast'));
    final blind = _renders(missed, 'item:$itemId').first;
    final dotsLine = _deepText(blind).firstWhere((text) => text.contains('○'));
    expect(
      dotsLine,
      isNot(contains('1')),
      reason: 'режим «сложный» — цифры не видны',
    );
  });

  test(
    'замок: режим «с клавиатуры» — поле ввода вместо экранной клавиатуры',
    () async {
      final lock = await _install('combination-lock');
      const itemId = 'terminal';
      final revealed = await _event(
        'item_reveal',
        payload: {
          'item_id': itemId,
          'item_json': {
            'id': itemId,
            'type': 'plugin',
            'pluginId': lock.id,
            'pluginTypeId': 'combinationLock',
            'pluginData': {'code': '42', 'mode': 'с клавиатуры'},
          },
        },
      );
      expect(revealed.errors, isEmpty);
      final spec = _renders(revealed, 'item:$itemId').first;
      final field = _deepNodes(
        spec,
      ).firstWhere((node) => node['type'] == 'input');
      expect(field['args'], itemId);
      expect(field['onSubmit'], 'submit');
      expect(field['maxLength'], 2, reason: 'длиннее кода клиент не вводит');
      expect(
        _deepNodes(spec).where((node) => node['label'] == '7'),
        isEmpty,
        reason: 'в этом режиме кнопок на экране нет',
      );

      // Аргумент колбэка поля собирает клиент: `{args: …, value: набранное}`.
      final typed = await _press(
        lock,
        'typing',
        args: {'args': itemId, 'value': '4'},
      );
      expect(typed.errors, isEmpty);
      expect(typed.varWrites['lock_terminal'], '4');

      final accepted = await _press(
        lock,
        'submit',
        args: {'args': itemId, 'value': '42'},
      );
      expect(accepted.errors, isEmpty);
      expect(accepted.varWrites['unlocked_terminal'], true);
      final open = _renders(accepted, 'item:$itemId').first;
      expect(
        _deepText(open).any((text) => text.contains('открыт')),
        isTrue,
        reason: 'после верного кода карточка переходит в открытое состояние',
      );
    },
  );

  test(
    'журнал: помнит сцены в хранилище и возвращает в любую из них',
    () async {
      final journal = await _install('travel-journal');
      await _event('quest_start');
      for (final node in ['start', 'cellar', 'start']) {
        final entered = await _event('node_enter', nodeId: node);
        expect(entered.errors, isEmpty, reason: node);
      }
      final storage = await MeanderPluginHost.storage(journal.id);
      final places = storage!['places:q.test'] as List;
      expect(places.length, 2);
      expect((places[0] as Map)['visits'], 2);

      final opened = await _press(journal, 'openPage');
      expect(_renders(opened, 'slot:journalPage'), isNotEmpty);

      final travelled = await _press(journal, 'go', args: 'cellar');
      final goto = travelled.commands.firstWhere(
        (command) => command.kind == 'goto_node',
      );
      expect(goto.raw['node'], 'cellar');
      expect(
        travelled.commands.any((command) => command.kind == 'close'),
        isTrue,
        reason: 'страница обязана закрыться перед переходом',
      );
    },
  );

  test('достижения: открываются по прогрессу и не дублируются', () async {
    final trophies = await _install('achievements');
    final first = await _event('quest_start');
    expect(
      first.commands.where((command) => command.kind == 'toast'),
      isNotEmpty,
    );
    final second = await _event('quest_start');
    expect(
      second.commands.where((command) => command.kind == 'toast'),
      isEmpty,
      reason: 'повторный старт не должен выдавать трофей заново',
    );

    for (var tap = 1; tap <= 5; tap++) {
      await _event('item_press', payload: {'item_id': 'item-$tap'});
    }
    final storage = await MeanderPluginHost.storage(trophies.id);
    expect(storage!['ach:q.test:collector'], true);
    expect(storage['ach:q.test:firstStep'], true);
    expect(storage['ach:q.test:taps'], 5);
  });

  test('лавка: берёт экран, тратит монеты и помнит остаток склада', () async {
    final shop = await _install('shop');

    final started = await _event('quest_start');
    expect(started.errors, isEmpty);
    expect(started.varWrites['gold'], 40);
    expect(_renders(started, 'slot:chip'), isNotEmpty);

    final opened = await _press(shop, 'openShop', vars: {'gold': 40});
    expect(
      _renders(opened, 'screen'),
      isNotEmpty,
      reason: 'плагин обязан уметь взять экран целиком',
    );

    final bought = await _press(shop, 'buy', args: 'torch', vars: {'gold': 40});
    expect(bought.errors, isEmpty);
    expect(bought.varWrites['gold'], 28);
    expect(((bought.varWrites['inv'] as List).first as Map)['name'], 'Факел');
    expect(
      bought.commands.map((command) => command.kind),
      containsAll(<String>['toast', 'play_sound', 'render']),
    );
    final stock =
        (await MeanderPluginHost.storage(shop.id))!['stock:q.test'] as Map;
    expect(stock['torch'], 4, reason: 'остаток должен пережить перезапуск');

    final broke = await _press(shop, 'buy', args: 'lantern', vars: {'gold': 5});
    expect(
      broke.varWrites,
      isEmpty,
      reason: 'покупка без денег ничего не меняет',
    );
    expect(
      broke.commands.where((command) => command.kind == 'toast'),
      isNotEmpty,
    );
  });

  test(
    'инвентарь: рюкзак — переменная квеста, а сетка привязана к ней',
    () async {
      final bag = await _install('inventory');
      const panel = 'panel-1';
      const torch = 'torch-1';
      const lantern = 'lantern-1';

      final started = await _event('quest_start');
      expect(started.errors, isEmpty);
      expect(started.varWrites['bag_count'], 0);
      expect(
        _renders(started, 'slot:hud'),
        isEmpty,
        reason:
            'пока в квесте нет ни одной панели, счётчик в углу не появляется',
      );

      // `capacity` приехал строкой, `cellWidth` — числом: форма редактора
      // ничего не гарантирует, плагин обязан свести сам.
      final revealed = await _reveal(bag, 'inventory', panel, {
        'title': 'Рюкзак',
        'capacity': '2',
        'skin': 'золотая',
        'cellWidth': 120,
      });
      expect(revealed.errors, isEmpty);
      expect(revealed.varWrites['bag_cap'], 2);
      final grid = _deepNodes(
        _renders(revealed, 'item:$panel').first,
      ).firstWhere((node) => node['type'] == 'grid');
      expect(
        grid['items'],
        '{bag_items}',
        reason: 'содержимое сетки — переменная квеста',
      );
      expect(grid['cellWidth'], 120);
      expect(
        (grid['row'] as Map)['args'],
        '{key}',
        reason: 'ключ ячейки приходит из элемента',
      );
      expect(_renders(revealed, 'slot:hud'), isNotEmpty);

      final dropped = await _reveal(bag, 'pickup', torch, {
        'name': 'Фонарь',
        'icon': 'bulb',
        'itemKey': 'flashlight',
        'count': 3,
        'picture': 'images/torch.png',
        'sound': 'pickup',
      });
      final button = _renders(dropped, 'item:$torch').first;
      expect(button['label'], 'Фонарь ×3');
      expect(
        button['args'],
        torch,
        reason: 'различает предметы одной поверхности',
      );

      final picked = await _press(
        bag,
        'collect',
        args: torch,
        vars: {'bag_cap': 2},
      );
      expect(picked.errors, isEmpty);
      final items = picked.varWrites['bag_items'] as List;
      expect((items.single as Map)['key'], 'flashlight');
      expect(picked.varWrites['bag_count'], 1);
      expect(
        picked.varWrites['bag_has_flashlight'],
        true,
        reason: 'автор квеста вешает на этот флаг условие двери',
      );
      expect(
        picked.commands.map((command) => command.kind),
        containsAll(<String>['toast', 'play_sound', 'close']),
      );

      // Второй предмет в рюкзак из двух мест — есть; третий уже нет.
      await _reveal(bag, 'pickup', lantern, {
        'name': 'Фонарь запасной',
        'itemKey': 'spare',
      });
      final crowded = await _press(
        bag,
        'collect',
        args: lantern,
        vars: {
          'bag_cap': 1,
          'bag_items': [
            {'key': 'flashlight', 'name': 'Фонарь'},
          ],
        },
      );
      expect(
        crowded.varWrites,
        isEmpty,
        reason: 'нет места — переменные не меняются',
      );
      expect(
        crowded.commands.where((command) => command.kind == 'toast'),
        isNotEmpty,
        reason: 'игрок обязан понять, почему предмет не лёг',
      );

      final second = await _press(
        bag,
        'collect',
        args: lantern,
        vars: {
          'bag_cap': 2,
          'bag_items': [
            {'key': 'flashlight', 'name': 'Фонарь'},
          ],
        },
      );
      expect((second.varWrites['bag_items'] as List), hasLength(2));

      // Осмотр ячейки: аргумент — ключ предмета, карточка берёт данные из
      // переменной, а не из хранилища.
      final examined = await _press(
        bag,
        'examine',
        args: 'flashlight',
        vars: {
          'bag_items': [
            {
              'key': 'flashlight',
              'name': 'Фонарь',
              'icon': 'bulb',
              'count': 3,
              'pic': 'images/torch.png',
              'desc': 'Тепло, но тяжело',
            },
          ],
        },
      );
      final card = _renders(examined, 'slot:inspect').first;
      expect(
        _deepText(card),
        containsAll(<String>['Фонарь ×3', 'Тепло, но тяжело']),
      );
      expect(
        _deepNodes(
          card,
        ).where((node) => node['type'] == 'image').map((node) => node['src']),
        contains('images/torch.png'),
      );

      final used = await _press(
        bag,
        'useItem',
        args: 'flashlight',
        vars: {
          'bag_items': [
            {'key': 'flashlight', 'name': 'Фонарь'},
          ],
        },
      );
      expect(used.errors, isEmpty);
      expect(used.varWrites['bag_used_flashlight'], true);

      final droppedOut = await _press(
        bag,
        'dropItem',
        args: 'flashlight',
        vars: {
          'bag_items': [
            {'key': 'flashlight', 'name': 'Фонарь'},
          ],
        },
      );
      expect(droppedOut.varWrites['bag_items'], isEmpty);
      expect(droppedOut.varWrites['bag_count'], 0);
      expect(droppedOut.varWrites['bag_has_flashlight'], false);
    },
  );

  // FFI-ответ приходит из Rust-порта, а в fake-async-зоне `testWidgets`
  // внешние события не доставляются — поэтому спеки снимаются обычным
  // тестом, а виджет-тест только их рисует.
  test('снимаем спеки эталонных плагинов', () async {
    const vitals = {'hp': 70, 'hpMax': 100, 'energy': 2, 'energyMax': 6};
    await _install('status-hud');
    _rendered['HUD'] = _Shot(
      _renders(await _event('quest_start', vars: vitals), 'slot:status').first,
    );
    _rendered['Карточка'] = _Shot(
      _renders(
        await MeanderPluginHost.call(
          pluginId: 'mnd.examples.statushud',
          function: 'openDetails',
          context: PluginCallContext(questId: 'q.test', vars: vitals),
        ),
        'slot:details',
      ).first,
    );

    final lock = await _install('combination-lock');
    _rendered['Клавиатура'] = _Shot(
      _renders(
        await _event(
          'item_reveal',
          payload: {
            'item_id': 'door',
            'item_json': {
              'id': 'door',
              'type': 'plugin',
              'pluginId': lock.id,
              'pluginData': {
                'code': '777',
                'title': 'Каморка',
                'hint': 'три семёрки',
              },
            },
          },
        ),
        'item:door',
      ).first,
    );

    final journal = await _install('travel-journal');
    await _event('quest_start');
    await _event('node_enter', nodeId: 'start');
    _rendered['Журнал'] = _Shot(
      _renders(await _press(journal, 'openPage'), 'slot:journalPage').first,
    );

    final shop = await _install('shop');
    await _event('quest_start');
    // Экранный спек шире слота: в 320 px он обязан влезать, а на экране — нет.
    _rendered['Лавка'] = _Shot(
      _renders(
        await _press(shop, 'openShop', vars: {'gold': 40}),
        'screen',
      ).first,
      width: 720,
    );

    final bag = await _install('inventory');
    final bagPanel = await _reveal(bag, 'inventory', 'panel-1', {
      'title': 'Рюкзак',
      'capacity': 6,
      'skin': 'лесная',
      'cellWidth': 104,
    });
    // Одна и та же сетка на двух ширинах: клиент сам считает число колонок.
    _rendered['Инвентарь (телефон)'] = _Shot(
      _renders(bagPanel, 'item:panel-1').first,
      width: 320,
    );
    _rendered['Рюкзак (планшет)'] = _Shot(
      _renders(await _press(bag, 'openBag'), 'screen').first,
      width: 720,
    );
  });

  testWidgets('спеки эталонных плагинов рисуются клиентом', (tester) async {
    const vitals = {'hp': 70, 'hpMax': 100, 'energy': 2, 'energyMax': 6};
    expect(_rendered, isNotEmpty);
    for (final entry in _rendered.entries) {
      await _pumpSpec(tester, entry.value, {...vitals, ..._bagVars});
      expect(
        tester.takeException(),
        isNull,
        reason: '${entry.key}: рендерер упал на собственном спеке',
      );
    }
  });
}

/// Снятый ядром спек и ширина, на которой клиент обязан его отрисовать.
class _Shot {
  final Map<String, dynamic> spec;
  final double width;

  _Shot(this.spec, {this.width = 320});
}

/// Рюкзак в переменных: сетка инвентаря рисуется именно по ним, а не по тому,
/// что плагин положил в спек.
const Map<String, dynamic> _bagVars = {
  'bag_cap': 6,
  'bag_count': 3,
  'bag_items': [
    {'key': 'flashlight', 'name': 'Фонарь', 'icon': 'bulb', 'count': 1},
    {'key': 'map', 'name': 'Карта', 'icon': 'map', 'count': 1},
    {'key': 'rope', 'name': 'Верёвка', 'icon': 'drop', 'count': 4},
  ],
};

/// Снятые ядром UI-спеки: имя блока → дерево виджетов.
final Map<String, _Shot> _rendered = {};

/// Отрисовать спек так же, как его рисует слой плагина: ограниченная ширина,
/// тёмная тема. Переполнение или исключение в сборке уронят тест.
Future<void> _pumpSpec(
  WidgetTester tester,
  _Shot shot, [
  Map<String, dynamic> vars = const {},
]) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: shot.width),
            child: PluginSpecView(
              spec: shot.spec,
              vars: vars,
              questId: 'q.test',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
