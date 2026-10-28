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

  group('имена строк', () {
    QuestTable makeTable({List<String>? names}) => QuestTable(
          name: 'лавка',
          columns: const ['цена'],
          rows: [
            {'цена': 30},
            {'цена': 50},
            {'цена': 70},
          ],
          rowNames: names,
        );

    test('список выравнивается по числу строк', () {
      final short = makeTable(names: const ['меч']);
      expect(short.rowNames, ['меч', '', '']);
      expect(short.rowName(0), 'меч');
      expect(short.rowName(2), '');
      expect(short.hasRowNames, isTrue);

      final long = makeTable(names: const ['а', 'б', 'в', 'г']);
      expect(long.rowNames, ['а', 'б', 'в']);

      expect(makeTable(names: const ['', ' ', '']).hasRowNames, isFalse);
    });

    test('имена переживают JSON, в том числе старый ключ row_names', () {
      final table = makeTable(names: const ['меч', '', 'щит']);
      final decoded = QuestTable.fromJson(table.toJson());
      expect(decoded.rowNames, ['меч', '', 'щит']);
      expect(decoded.rowNames, isNot(same(table.rowNames)),
          reason: 'список должен копироваться, а не шариться');

      final legacyKey = QuestTable.fromJson({
        'name': 'лавка',
        'columns': ['цена'],
        'rows': [
          {'цена': 30},
          {'цена': 50},
        ],
        'row_names': ['меч', ''],
      });
      expect(legacyKey.rowNames, ['меч', '']);

      final old = QuestTable.fromJson({
        'name': 'лавка',
        'columns': ['цена'],
        'rows': [
          {'цена': 30},
          {'цена': 50},
        ],
      });
      expect(old.rowNames, ['', '']);
      expect(old.hasRowNames, isFalse);
    });

    test('rowNames не протекает в data при старом формате', () {
      final decoded = QuestTable.fromJson({
        'columns': [],
        'rows': [],
        'rowNames': ['меч', 'щит'],
      });
      expect(decoded.data, isEmpty);
      expect(decoded.rowNames, isEmpty,
          reason: 'строк нет — имена не должны создать фантомные строки');
    });

    test('insertRowAt/removeRowAt/moveRow держат имена в паре со строками', () {
      final table = makeTable(names: const ['меч', 'щит', 'лук']);
      table.insertRowAt(1, {'цена': 40}, name: ' копьё ');
      expect(table.rows.map((r) => r['цена']), [30, 40, 50, 70]);
      expect(table.rowNames, ['меч', 'копьё', 'щит', 'лук']);

      table.removeRowAt(1);
      expect(table.rows.map((r) => r['цена']), [30, 50, 70]);
      expect(table.rowNames, ['меч', 'щит', 'лук']);

      table.moveRow(0, 2);
      expect(table.rows.map((r) => r['цена']), [50, 70, 30]);
      expect(table.rowNames, ['щит', 'лук', 'меч']);

      table.addEmptyRow();
      expect(table.rowNames, ['щит', 'лук', 'меч', '']);
    });

    test('setRowName тримит и игнорирует строку вне диапазона', () {
      final table = makeTable();
      table.setRowName(1, '  щит  ');
      expect(table.rowName(1), 'щит');
      table.setRowName(9, 'нет');
      expect(table.rowNames, ['', 'щит', '']);

      final short = makeTable(names: const []);
      short.rowNames = [];
      short.setRowName(2, 'лук');
      expect(short.rowNames, ['', '', 'лук']);
    });

    test('rowIndexByName ищет по имени и не путает пустое', () {
      final table = makeTable(names: const ['меч', '', 'меч']);
      expect(table.rowIndexByName(' меч '), 0);
      expect(table.rowIndexByName(''), isNull);
      expect(table.rowIndexByName('   '), isNull);
      expect(table.rowIndexByName('нет'), isNull);
      expect(table.rowIndexByName('меч'), 0,
          reason: 'дубликаты допустимы, находится первая строка');
    });
  });

  group('escapeTableKey', () {
    test('кавычка и обратный слэш экранируются, остальное не трогается', () {
      expect(escapeTableKey('меч'), 'меч');
      expect(escapeTableKey('{тест}'), '{тест}');
      expect(escapeTableKey('a}b'), 'a}b');
      expect(escapeTableKey('a"b'), r'a\"b');
      expect(escapeTableKey(r'a\b'), r'a\\b');
      // Слэш экранируется первым: иначе `\"` превратился бы в `\\"`.
      expect(escapeTableKey(r'a\"b'), r'a\\\"b');
    });
  });
}
