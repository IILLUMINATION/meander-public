import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';

void main() {
  group('QuestTable', () {
    test('round-trip fromJson/toJson', () {
      final table = QuestTable(
        name: 'inv',
        columns: const ['item', 'qty'],
        rows: [
          {'item': 'sword', 'qty': 1},
          {'item': 'gold', 'qty': 50},
        ],
        data: const {'meta': 'starter'},
      );
      final decoded = QuestTable.fromJson(table.toJson());
      expect(decoded.name, table.name);
      expect(decoded.columns, table.columns);
      expect(decoded.rows, table.rows);
      expect(decoded.data, table.data);
    });

    test('addEmptyRow adds empty fields for every column', () {
      final table = QuestTable(
        name: 't',
        columns: ['a', 'b'],
        rows: [],
      )..addEmptyRow();
      expect(table.rows.length, 1);
      expect(table.rows.first.keys, containsAll(['a', 'b']));
    });

    test('updateColumns drops removed columns and adds new ones with empty',
        () {
      final table = QuestTable(
        name: 't',
        columns: ['a', 'b'],
        rows: [
          {'a': 1, 'b': 2},
        ],
      )..updateColumns(['a', 'c']);
      expect(table.columns, ['a', 'c']);
      expect(table.rows.first.containsKey('b'), isFalse);
      expect(table.rows.first['c'], '');
    });
    test('handles __table_full_json__ correctly without polluting data', () {
      final jsonWithFull = {
        'рука': [
          {'название': 'Яблочко'},
        ],
        '__table_full_json__': '{"name":"Инвентерь","columns":[],"rows":[],"data":{"рука":[{"название":"Яблочко"}]}}'
      };
      final decoded = QuestTable.fromJson(jsonWithFull);
      expect(decoded.name, 'Инвентерь');
      expect(decoded.data.containsKey('__table_full_json__'), isFalse);
      expect(decoded.data['рука'], [
        {'название': 'Яблочко'},
      ]);
    });
  });

  group('вложенные таблицы в ячейке', () {
    final nested = QuestTable(
      name: 'подтаблица',
      columns: const ['товар', 'цена'],
      rows: [
        {'товар': 'хлеб', 'цена': 30},
      ],
      data: const {'открыто': true},
    );

    test('ячейка-таблица распознаётся и читается обратно', () {
      final value = nested.toNestedValue();
      expect(QuestTable.isNestedValue(value), isTrue);
      final restored = QuestTable.nestedFromValue(value);
      expect(restored, isNotNull);
      expect(restored!.name, 'подтаблица');
      expect(restored.columns, ['товар', 'цена']);
      expect(restored.rows.first['товар'], 'хлеб');
      expect(restored.data['открыто'], isTrue);
    });

    test('обычные значения и KV-объекты не принимаются за таблицу', () {
      expect(QuestTable.isNestedValue('просто строка'), isFalse);
      expect(QuestTable.isNestedValue({'columns': []}), isFalse);
      expect(QuestTable.isNestedValue({'rows': []}), isFalse);
      expect(QuestTable.nestedFromValue({'columns': [], 'rows': []}), isNotNull,
          reason: 'пустая таблица — всё ещё валидная вложенная таблица');
      expect(
        QuestTable.nestedFromValue({'товар': 'хлеб', 'цена': 30}),
        isNull,
        reason: 'объект данных без сетки не должен открываться как таблица',
      );
    });

    test('вложенность переживает JSON-кодирование родителя', () {
      final parent = QuestTable(
        name: 'root',
        columns: const ['раздел'],
        rows: [
          {'раздел': nested.toNestedValue()},
        ],
      );
      final decoded = QuestTable.fromJson(
        jsonDecode(jsonEncode(parent.toJson())) as Map<String, dynamic>,
      );
      final inner = QuestTable.nestedFromValue(decoded.rows.first['раздел']);
      expect(inner, isNotNull);
      expect(inner!.rows.first['цена'], 30);
    });
  });
}
