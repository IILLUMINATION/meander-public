import 'dart:convert';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/parser.dart';
import 'package:flutter_test/flutter_test.dart';

// ============================================================================
//  Контракт парсера скриптов: load→save БЕЗ ПОТЕРЬ.
//
//  Регрессия: ScriptParser не знал тип 'while' и молча выбрасывал блок;
//  автосейв перезаписывал файл пустотой («скрипт пустой после хот
//  рестарта»). Теперь parse→toJson обязан быть тождественным по смыслу,
//  а неизвестные типы — проходить насквозь через UnknownBlock.
// ============================================================================

List<dynamic> roundtrip(List<dynamic> blocksJson) =>
    ScriptParser.parseBlocks(blocksJson)
        .map((b) => b.toJson())
        .toList(growable: false);

dynamic canon(dynamic json) => jsonDecode(jsonEncode(json));

void main() {
  test('while-блок из багрепорта переживает load→save без потерь', () {
    // Дословно blocks из скрипта пользователя (id сохранены).
    final userBlocks = [
      {
        "type": "event",
        "id": "578cc2ae-c7b4-4a6e-8780-a81243ced52a",
        "eventType": "onNodeEnter",
        "children": [
          {
            "type": "while",
            "id": "74ef39a7-1623-44d4-bec8-e3a8e4fc6fb6",
            "count": "3",
            "children": [
              {
                "type": "assign_variable",
                "id": "a05315bf-8d5d-4fa2-babd-edead0b4b09f",
                "variable": "тест",
                "value": "{тест}+1"
              }
            ],
            "collapsed": false,
            "max_iterations": 10000
          }
        ],
        "collapsed": false
      }
    ];

    final result = roundtrip(userBlocks);

    // count остался СТРОКОЙ, max_iterations и дети на месте.
    expect(result, canon(userBlocks));
    final whileJson =
        (result[0]['children'] as List).first as Map<String, dynamic>;
    expect(whileJson['count'], '3');
    expect(whileJson['max_iterations'], 10000);
    expect((whileJson['children'] as List).first['variable'], 'тест');
  });

  test('неизвестный тип проходит насквозь (UnknownBlock), без подмены', () {
    final unknown = {
      "type": "future_block_from_newer_version",
      "id": "x1",
      "customField": 5,
      "nested": {"a": [1, 2]}
    };
    final result = roundtrip([unknown]);
    expect(result.first, canon(unknown));
  });

  test('битый блок известного типа тоже не теряется', () {
    // value числом раньше ронял cast в String → заглушка → потеря.
    final broken = [
      {"type": "assign_variable", "id": "b1", "variable": "x", "value": 42}
    ];
    final parsed = ScriptParser.parseBlocks(broken);
    expect(parsed.single, isA<AssignVariableBlock>());
    final json = parsed.single.toJson();
    expect(json['value'], '42');
    expect(json['variable'], 'x');
  });

  test('легаси-условие variable/comparison/значение нормализуется', () {
    final legacy = [
      {
        "type": "условие",
        "id": "c1",
        "variable": "HP",
        "comparison": ">=",
        "значение": "10",
        "если_да": [
          {"type": "assign_variable", "variable": "флаг", "value": "1"}
        ],
        "если_нет": [],
        "collapsed": false
      }
    ];

    final parsed = ScriptParser.parseBlocks(legacy);
    final cond = parsed.single as ConditionBlock;
    // Числовое значение не квотируется (легаси-семантика).
    expect(cond.expression, '{HP} >= 10');
    expect(
      (cond.thenBlocks.single as AssignVariableBlock).variableName,
      'флаг',
    );
    expect(cond.elseBlocks, isEmpty);
  });

  test('легаси-задержка milliseconds и title-события', () {
    final legacy = [
      {"type": "задержка", "id": "d1", "milliseconds": 1500},
      {
        "title": "При запуске ноды",
        "id": "e1",
        "children": <Map<String, dynamic>>[]
      },
    ];

    final parsed = ScriptParser.parseBlocks(legacy);
    final delay = parsed[0] as DelayBlock;
    expect(delay.expression, '1500');
    final event = parsed[1] as EventBlock;
    expect(event.eventType, EventType.onNodeEnter);
  });

  test('алиас while_loop читается как while', () {
    final alias = [
      {
        "type": "while_loop",
        "id": "w1",
        "count": 2,
        "children": <Map<String, dynamic>>[]
      }
    ];
    final parsed = ScriptParser.parseBlocks(alias);
    expect(parsed.single, isA<WhileBlock>());
  });

  test('set_image переживает load→save и понимает русские ключи', () {
    final block = {
      "type": "set_image",
      "id": "si1",
      "item_id": "1789941265873",
      "item_name": "cat.png",
      "source": "res/{level}.png",
    };
    expect(roundtrip([block]), canon([block]));

    // Рукописный скрипт: движок принимает и русские имена полей.
    final parsed = ScriptParser.parseBlocks([
      {"type": "set_image", "id": "si2", "айтем": "img", "источник": "cat.png"}
    ] as List<dynamic>);
    final image = parsed.single as SetImageBlock;
    expect(image.itemId, 'img');
    expect(image.source, 'cat.png');
    // Подпись объекта на канвасе: без неё блок нераспознаваем, но это
    // только UI — движок читает item_id.
    expect(image.itemName, 'Выберите объект');
  });

  test('set_visible переживает load→save и понимает русские ключи', () {
    for (final mode in ['show', 'hide', 'remove', 'toggle']) {
      final block = {
        "type": "set_visible",
        "id": "sv1",
        "item_id": "1789941265873",
        "item_name": "фото · Новая нода",
        "mode": mode,
      };
      expect(roundtrip([block]), canon([block]), reason: mode);
    }

    // Рукописный скрипт: тип по-русски и поле `видим` вместо `mode`.
    final parsed = ScriptParser.parseBlocks([
      {
        "type": "видимость",
        "id": "sv2",
        "айтем": "photo",
        "видим": false,
      }
    ] as List<dynamic>);
    final visible = parsed.single as SetVisibleBlock;
    expect(visible.itemId, 'photo');
    // `false` в старом смысле прятал айтем целиком, ряд схлопывался — значит
    // это именно «убрать», а не новое «скрыть с местом».
    expect(visible.mode, 'remove');
  });

  test('set_top_panel переживает load→save и понимает русское имя', () {
    for (final mode in ['show', 'hide', 'toggle']) {
      final block = {"type": "set_top_panel", "id": "tp1", "mode": mode};
      expect(roundtrip([block]), canon([block]), reason: mode);
    }

    // Рукописный скрипт с русским типом: тип обязан опознаться, иначе блок
    // станет UnknownBlock и поле «Действие» в редакторе не покажется.
    final parsed = ScriptParser.parseBlocks([
      {"type": "верхняя_панель", "id": "tp2", "режим": "показать"}
    ] as List<dynamic>);
    final panel = parsed.single as SetTopPanelBlock;
    expect(panel.mode, 'показать');
    expect(panel.toJson()['mode'], 'показать');
  });
}
