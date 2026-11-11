/// Инстанс шаблона в браузере: движок обязан развернуть мастер-кнопку и
/// отдать её триггер, иначе нажатие на такую кнопку мёртвое.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_web_player/player.dart';
import 'package:mnd_web_player/quest_bundle.dart';

import 'quest_bundle_test.dart' show mndBytes;

const _scriptId = 'scripts/s1.json';

/// Очередь раскрытия и переходы PLAYER-неawait'ятся (`revealNext` из
/// post-frame), поэтому в тесте ждём конкретное состояние, а не «тик».
Future<void> _settle(QuestPlayer player, bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'плеер не дошёл до состояния за 5 с');
}

final _questFiles = <String, String>{
  'config.json': jsonEncode({
    'id': 'tpl-quest',
    'title': 'Шаблоны',
    'startNodeId': 'n1',
  }),
  'nodes.json': jsonEncode({
    'nodes': [
      {
        'id': 'n1',
        'title': 'Первая',
        'content': {
          'items': [
            {
              'id': 'b1',
              'type': 'button',
              // Инстанс: ни текста, ни триггеров — всё в мастере.
              'templateRef': 't1',
            },
          ],
        },
      },
      {
        'id': 'n2',
        'title': 'Вторая',
        'content': {'items': []},
      },
    ],
    'groups': [],
  }),
  // Редактор пишет карту, а не голый массив.
  'res/templates.json': jsonEncode({
    'schemaVersion': 1,
    'templates': [
      {
        'id': 't1',
        'name': 'Кнопка хода',
        'kind': 'button',
        'payload': {
          'id': 'master-1',
          'type': 'button',
          'text': 'Вперёд',
          'scriptTriggers': {'onPress': _scriptId},
        },
      },
    ],
  }),
  _scriptId: jsonEncode({
    'id': 's1',
    'name': 'Ход вперёд',
    'blocks': [
      {
        'type': 'event',
        'id': 'e1',
        'eventType': 'onNodeEnter',
        'children': [
          {'type': 'go_to_node', 'id': 'g1', 'node_id': 'n2'},
        ],
      },
    ],
  }),
};

void main() {
  group('шаблоны в веб-плеере', () {
    test('res/templates.json карты раскрыт в движке', () async {
      final bundle = decodeMnd(
        mndBytes(_questFiles),
        'https://meander.illuminat.dev/quest-src/tpl-quest.mnd',
      );
      expect(bundle.templates, hasLength(1));

      final player = QuestPlayer(bundle);
      addTearDown(player.dispose);
      await player.start();

      expect(player.phase, PlayPhase.playing);
      expect(player.errorMessage, isNull);
      await _settle(player, () => player.revealed.isNotEmpty);
      // Раскрытие делает движок: без списка шаблонов здесь остался бы
      // неразвёрнутый инстанс — без текста и без триггера.
      final button = player.revealed.single;
      expect(button.type, 'button');
      expect(player.resolveText(button.text ?? ''), 'Вперёд');
      expect(button.scriptForEvent('onPress'), _scriptId);

      await player.tapItem(button);
      await _settle(player, () => player.nodeId == 'n2');

      expect(player.errorMessage, isNull);
    });
  });
}
