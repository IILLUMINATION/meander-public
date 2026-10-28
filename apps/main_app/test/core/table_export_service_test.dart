import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:canvas_app/core/services/table_export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';

QuestTable makeTable() => QuestTable(
      name: 'Тест',
      columns: const ['A', 'B'],
      rows: [
        {'A': '1', 'B': 'x'},
        {'A': '2', 'B': 'y'},
      ],
      data: const {'ключ': 'значение'},
    );

String _xmlUnescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"');

/// Читает сетку листа XLSX обратно из zip (мини-парсер для round-trip).
List<List<String>> readXlsxGrid(Uint8List bytes, {String sheet = 'sheet1'}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final file = archive.findFile('xl/worksheets/$sheet.xml');
  expect(file, isNotNull, reason: 'лист $sheet отсутствует в xlsx');
  final xml = utf8.decode(file!.content as List<int>);
  final rows = <List<String>>[];
  final rowRe = RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true);
  final cellRe = RegExp(
    r'<c[^>]*>(?:<v>([^<]*)</v>|<is><t[^>]*>(.*?)</t></is>)</c>',
    dotAll: true,
  );
  for (final rm in rowRe.allMatches(xml)) {
    final cells = <String>[];
    for (final cm in cellRe.allMatches(rm.group(1)!)) {
      cells.add(_xmlUnescape(cm.group(1) ?? cm.group(2) ?? ''));
    }
    rows.add(cells);
  }
  return rows;
}

void main() {
  group('columnLabel / sanitize', () {
    test('columnLabel: A, Z, AA, AB, ZZ, AAA', () {
      expect(TableExportService.columnLabel(0), 'A');
      expect(TableExportService.columnLabel(25), 'Z');
      expect(TableExportService.columnLabel(26), 'AA');
      expect(TableExportService.columnLabel(27), 'AB');
      expect(TableExportService.columnLabel(701), 'ZZ');
      expect(TableExportService.columnLabel(702), 'AAA');
    });

    test('sanitizeFileName: запрещённые символы, пусто, длина', () {
      expect(TableExportService.sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'),
          'a_b_c_d_e_f_g_h_i_j');
      expect(TableExportService.sanitizeFileName('   '), 'таблица');
      expect(
        TableExportService.sanitizeFileName('x' * 100).length,
        80,
      );
    });

    test('sanitizeSheetName: запрещённые символы, длина 31, пусто', () {
      expect(TableExportService.sanitizeSheetName('a/b\\c*d?e[f]g'), 'abcdefg');
      expect(TableExportService.sanitizeSheetName('y' * 40).length, 31);
      expect(TableExportService.sanitizeSheetName('  '), 'Таблица');
    });
  });

  group('CSV', () {
    test('round-trip: значения с запятыми, кавычками, переносами, юникод', () {
      final table = QuestTable(
        name: 't',
        columns: const ['колонка', 'описание'],
        rows: [
          {'колонка': 'простое', 'описание': 'обычное значение'},
          {
            'колонка': 'с запятой, и "кавычками"',
            'описание': 'перенос\nстроки и кавычка " внутри',
          },
          {'колонка': 'юникод 🎉', 'описание': ''},
          {'колонка': '', 'описание': 'пустая первая колонка'},
        ],
      );

      final csv = TableExportService.tableToCsv(table, includeBom: false);
      final parsed = TableExportService.questTableFromCsv(csv, name: 't');

      expect(parsed.columns, table.columns);
      expect(parsed.rows, table.rows);
    });

    test('parseCsv: RFC 4180 — кавычки, "" внутри, CRLF', () {
      final rows = TableExportService.parseCsv(
        '"a,b","x""y"\r\n"c",d\r\n',
      );
      expect(rows, [
        ['a,b', 'x"y'],
        ['c', 'd'],
      ]);
    });

    test('questTableFromCsv: BOM убирается, дубли заголовков уникализируются',
        () {
      final table = TableExportService.questTableFromCsv(
        '\ufeffA,A,B\r\n1,2,3\r\n',
        name: 't',
      );
      expect(table.columns, ['A', 'A (2)', 'B']);
      expect(table.rows, [
        {'A': '1', 'A (2)': '2', 'B': '3'},
      ]);
    });

    test('questTableFromCsv: пустые строки пропускаются, ошибки', () {
      final table = TableExportService.questTableFromCsv(
        'A,B\r\n1,2\r\n,\r\n\r\n',
        name: 't',
      );
      expect(table.rows, [
        {'A': '1', 'B': '2'},
      ]);
      expect(
        () => TableExportService.questTableFromCsv('', name: 't'),
        throwsFormatException,
      );
      expect(
        () => TableExportService.questTableFromCsv('\r\n', name: 't'),
        throwsFormatException,
      );
    });

    test('имена строк переживают CSV-круговорот', () {
      final table = QuestTable(
        name: 'лавка',
        columns: const ['цена', 'запас'],
        rows: [
          {'цена': '30', 'запас': '2'},
          {'цена': '99', 'запас': '1'},
        ],
        rowNames: const ['меч', 'щит'],
      );
      final csv = TableExportService.tableToCsv(table, includeBom: false);
      expect(csv.split('\n').first, '__row_name,цена,запас');
      final restored = TableExportService.questTableFromCsv(
        csv,
        name: 'лавка',
      );
      expect(restored.columns, ['цена', 'запас']);
      expect(restored.rows, table.rows);
      expect(restored.rowNames, ['меч', 'щит']);
      expect(restored.rowIndexByName('щит'), 1);

      // Без имён служебной колонки нет, импорт старого CSV не меняется.
      final plain = TableExportService.tableToCsv(
        makeTable(),
        includeBom: false,
      );
      expect(plain.startsWith('A,B'), isTrue);
      expect(
        TableExportService.questTableFromCsv(plain, name: 't').rowNames,
        ['', ''],
      );
    });

    test('decodeCsvBytes: UTF-8 без BOM и с BOM, фолбэк на Windows-1251', () {
      expect(TableExportService.decodeCsvBytes(utf8.encode('Привет')), 'Привет');

      final withBom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('Тест')]);
      final decoded = TableExportService.decodeCsvBytes(withBom);
      expect(decoded, 'Тест');

      // «Привет» в Windows-1251: П=CF р=F0 и=E8 в=E2 е=E5 т=F2
      final win1251 = Uint8List.fromList([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]);
      expect(TableExportService.decodeCsvBytes(win1251), 'Привет');
    });
  });

  group('JSON', () {
    test('round-trip: toJson → parseQuestTableJson', () {
      final table = makeTable();
      final parsed = TableExportService.parseQuestTableJson(
        const JsonEncoder.withIndent('  ').convert(table.toJson()),
      );
      expect(parsed.name, table.name);
      expect(parsed.columns, table.columns);
      expect(parsed.rows, table.rows);
      expect(parsed.data, table.data);
    });

    test('имена строк попадают в JSON и читаются обратно', () {
      final table = QuestTable(
        name: 'лавка',
        columns: const ['цена'],
        rows: [
          {'цена': 30},
        ],
        rowNames: const ['меч'],
      );
      final json = jsonDecode(
        const JsonEncoder.withIndent('  ').convert(table.toJson()),
      ) as Map<String, dynamic>;
      expect(json['rowNames'], ['меч']);
      final parsed = TableExportService.parseQuestTableJson(
        jsonEncode(json),
      );
      expect(parsed.rowNames, ['меч']);
      expect(parsed.rowIndexByName('меч'), 0);
    });

    test('ошибки: не JSON, не объект, нет columns/rows', () {
      expect(
        () => TableExportService.parseQuestTableJson('не json'),
        throwsFormatException,
      );
      expect(
        () => TableExportService.parseQuestTableJson('[1,2]'),
        throwsFormatException,
      );
      expect(
        () => TableExportService.parseQuestTableJson('{"name":"t"}'),
        throwsFormatException,
      );
      expect(
        () => TableExportService.parseQuestTableJson('{"columns":[],"rows":[1]}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('fallbackName подставляется при пустом name', () {
      final parsed = TableExportService.parseQuestTableJson(
        '{"name":"","columns":["A"],"rows":[]}',
        fallbackName: 'из файла',
      );
      expect(parsed.name, 'из файла');
    });
  });

  group('XLSX', () {
    test('round-trip: сетка совпадает, числа остаются числами', () {
      final table = QuestTable(
        name: 'Боевой',
        columns: const ['Имя', 'HP', 'Описание'],
        rows: [
          {'Имя': 'Герой', 'HP': 100, 'Описание': 'a & b < c > d "e"'},
          {'Имя': 'Враг', 'HP': 50, 'Описание': ''},
        ],
        data: const {'золото': 10},
      );

      final bytes = TableExportService.tableToXlsx(table);
      final grid = readXlsxGrid(bytes);

      expect(grid[0], ['Имя', 'HP', 'Описание']);
      expect(grid[1], ['Герой', '100', 'a & b < c > d "e"']);
      expect(grid[2], ['Враг', '50', '']);

      // числа записаны как <v>100</v> без кавычек inlineStr
      final archive = ZipDecoder().decodeBytes(bytes);
      final xml = utf8.decode(
        archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
      );
      expect(xml, contains('<v>100</v>'));
      expect(xml, isNot(contains('t="inlineStr"><is><t>100')));
    });

    test('имена строк — первая колонка листа', () {
      final table = QuestTable(
        name: 'Лавка',
        columns: const ['цена'],
        rows: [
          {'цена': 30},
          {'цена': 99},
        ],
        rowNames: const ['меч', 'щит'],
      );
      final grid = readXlsxGrid(TableExportService.tableToXlsx(table));
      expect(grid[0], ['__row_name', 'цена']);
      expect(grid[1], ['меч', '30']);
      expect(grid[2], ['щит', '99']);
    });

    test('лист «Данные (KV)» создаётся только при непустом data', () {
      final withData = makeTable();
      final grid = readXlsxGrid(
        TableExportService.tableToXlsx(withData),
        sheet: 'sheet2',
      );
      expect(grid[0], ['ключ', 'значение']);
      expect(grid[1], ['ключ', 'значение']);

      final noData = QuestTable(
        name: 't',
        columns: const ['A'],
        rows: const [],
        data: const {},
      );
      final archive = ZipDecoder().decodeBytes(
        TableExportService.tableToXlsx(noData),
      );
      expect(archive.findFile('xl/worksheets/sheet2.xml'), isNull);
    });
  });
}