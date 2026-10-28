import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:canvas_app/core/l10n/l10n.dart';

/// Экспорт и импорт таблиц QuestTable: CSV (RFC 4180), XLSX, JSON.
///
/// Экспортируются визуальные `columns`/`rows`; скриптовое KV-хранилище
/// `data` попадает в XLSX отдельным листом и в JSON «как есть».
class TableExportService {
  TableExportService._();

  static const int _maxCellLength = 32000;
  static const int _maxSheetRows = 16000;

  /// Метка колонки как в Excel: 0 → A, 25 → Z, 26 → AA.
  static String columnLabel(int index) {
    var n = index + 1;
    final sb = StringBuffer();
    while (n > 0) {
      final rem = (n - 1) % 26;
      sb.writeCharCode(65 + rem);
      n = (n - 1) ~/ 26;
    }
    return sb.toString().split('').reversed.join();
  }

  /// Имя для файла на диске: без запрещённых символов, не длиннее 80.
  static String sanitizeFileName(String name) {
    final clean = name
        .replaceAll(RegExp(r'[\\/*?:"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return 'таблица';
    return clean.length > 80 ? clean.substring(0, 80) : clean;
  }

  /// Имя листа XLSX: без запрещённых символов, не длиннее 31.
  static String sanitizeSheetName(String name) {
    final clean = name.replaceAll(RegExp(r'[\\/*?:\[\]]'), '').trim();
    if (clean.isEmpty) return 'Таблица';
    return clean.length > 31 ? clean.substring(0, 31) : clean;
  }

  // ---------------------------------------------------------------------------
  //  Значения
  // ---------------------------------------------------------------------------

  /// Отображение значения ячейки как текста (для CSV и ячеек XLSX).
  static String valueToText(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is Map || value is List) {
      try {
        return jsonEncode(value);
      } catch (_) {}
    }
    return formatScriptValue(value);
  }

  static String _limit(String s) =>
      s.length > _maxCellLength ? s.substring(0, _maxCellLength) : s;

  // ---------------------------------------------------------------------------
  //  CSV
  // ---------------------------------------------------------------------------

  static String _escapeCsvField(String field) {
    if (field.contains(',') ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  /// Таблица в CSV. BOM помогает Excel/Google Sheets распознать UTF-8.
  /// Если у строк есть имена, первая колонка — `__row_name`: импорт по ней
  /// восстановит имена, а в остальных программах это просто колонка.
  static String tableToCsv(QuestTable table, {bool includeBom = true}) {
    final buffer = StringBuffer();
    final withNames = table.hasRowNames;
    void writeRow(List<String> values) {
      buffer.writeln(values.map(_escapeCsvField).join(','));
    }

    writeRow([if (withNames) '__row_name', ...table.columns]);
    final maxRows =
        table.rows.length > _maxSheetRows ? _maxSheetRows : table.rows.length;
    for (var i = 0; i < maxRows; i++) {
      final row = table.rows[i];
      writeRow([
        if (withNames) table.rowName(i),
        ...table.columns.map((col) => valueToText(row[col])),
      ]);
    }

    final csv = buffer.toString();
    return includeBom ? '\ufeff$csv' : csv;
  }

  /// Парсер CSV по RFC 4180: кавычки, "" внутри кавычек, CRLF/LF/CR.
  static List<List<String>> parseCsv(String csv) {
    var text = csv;
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }

    final rows = <List<String>>[];
    final field = StringBuffer();
    var row = <String>[];
    var inQuotes = false;

    List<String> finishRow() {
      row.add(field.toString());
      field.clear();
      final finished = row;
      row = <String>[];
      return finished;
    }

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(ch);
        }
      } else if (ch == '"') {
        inQuotes = true;
      } else if (ch == ',') {
        row.add(field.toString());
        field.clear();
      } else if (ch == '\n') {
        rows.add(finishRow());
      } else if (ch == '\r') {
        rows.add(finishRow());
        if (i + 1 < text.length && text[i + 1] == '\n') i++;
      } else {
        field.write(ch);
      }
    }

    if (field.isNotEmpty || row.isNotEmpty) rows.add(finishRow());
    return rows;
  }

  /// CSV в QuestTable: первая строка = заголовки колонок, далее данные.
  /// Значения остаются строками — так же, как в редакторе Meander.
  static QuestTable questTableFromCsv(String csv, {required String name}) {
    final rowsRaw = parseCsv(csv);
    if (rowsRaw.isEmpty) {
      throw FormatException(tr('Файл CSV пуст'));
    }

    var header = rowsRaw.first;
    final hasRowNames = header.isNotEmpty && header.first.trim() == '__row_name';
    if (hasRowNames) header = header.sublist(1);
    if (header.isEmpty) {
      throw FormatException(tr('Файл CSV не содержит заголовков'));
    }
    if (header.length == 1 && header.first.trim().isEmpty) {
      throw FormatException(tr('Файл CSV не содержит заголовков'));
    }

    final columns = <String>[];
    final used = <String>{};
    for (var i = 0; i < header.length; i++) {
      var colName = header[i].trim();
      if (colName.isEmpty) colName = columnLabel(i);
      var unique = colName;
      var suffix = 2;
      while (used.contains(unique)) {
        unique = '$colName ($suffix)';
        suffix++;
      }
      used.add(unique);
      columns.add(unique);
    }

    final dataRows = <Map<String, dynamic>>[];
    final rowNames = <String>[];
    final offset = hasRowNames ? 1 : 0;
    for (final raw in rowsRaw.skip(1)) {
      final row = <String, dynamic>{};
      var allEmpty = true;
      final rowName = hasRowNames && raw.isNotEmpty ? raw.first.trim() : '';
      if (rowName.isNotEmpty) allEmpty = false;
      for (var i = 0; i < columns.length; i++) {
        final at = i + offset;
        final v = at < raw.length ? raw[at] : '';
        if (v.isNotEmpty) allEmpty = false;
        row[columns[i]] = v;
      }
      if (!allEmpty) {
        dataRows.add(row);
        rowNames.add(rowName);
      }
    }

    return QuestTable(
      name: name,
      columns: columns,
      rows: dataRows,
      rowNames: hasRowNames ? rowNames : null,
    );
  }

  // ---------------------------------------------------------------------------
  //  JSON
  // ---------------------------------------------------------------------------

  static QuestTable parseQuestTableJson(String content, {String? fallbackName}) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw FormatException(tr('Файл не является корректным JSON'));
    }
    if (decoded is! Map) {
      throw FormatException(tr('JSON должен содержать объект таблицы'));
    }
    final json = Map<String, dynamic>.from(decoded);
    if (json['columns'] is! List) {
      throw FormatException(tr('Поле "columns" отсутствует или не список'));
    }
    if (json['rows'] is! List) {
      throw FormatException(tr('Поле "rows" отсутствует или не список'));
    }
    for (final r in json['rows'] as List) {
      if (r is! Map) {
        throw FormatException(
            tr('Каждая строка должна быть объектом'),
          );
      }
    }
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      json['name'] = fallbackName ?? 'таблица';
    }
    return QuestTable.fromJson(json);
  }

  // ---------------------------------------------------------------------------
  //  Импорт из файла
  // ---------------------------------------------------------------------------

  /// Декодирование CSV-файла. UTF-8 с BOM — основной вариант; при
  /// невалидном UTF-8 пробуем Windows-1251 (ANSI-выгрузка из русского Excel).
  static String decodeCsvBytes(Uint8List bytes) {
    final utf8Text = utf8.decode(bytes, allowMalformed: true);
    if (utf8Text.contains('\uFFFD')) {
      return _decodeWindows1251(bytes);
    }
    return utf8Text;
  }

  static String _decodeWindows1251(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      if (b >= 0xC0 && b <= 0xFF) {
        sb.writeCharCode(0x0410 + (b - 0xC0));
      } else if (b == 0xA8) {
        sb.writeCharCode(0x0401);
      } else if (b == 0xB8) {
        sb.writeCharCode(0x0451);
      } else {
        sb.writeCharCode(b);
      }
    }
    return sb.toString();
  }

  /// Импорт таблицы из CSV/JSON-файла. Имя таблицы — из имени файла.
  static Future<QuestTable> importTableFromFile(String filePath) async {    final ext = p.extension(filePath).toLowerCase();
    final file = File(filePath);
    if (!await file.exists()) {
      throw FormatException(
        trf('Файл не найден: {p0}', {'p0': filePath}),
      );
    }
    final name = sanitizeFileName(p.basenameWithoutExtension(filePath));

    if (ext == '.json') {
      final content = await file.readAsString();
      return parseQuestTableJson(content, fallbackName: name);
    }
    if (ext == '.csv') {
      final bytes = await file.readAsBytes();
      return questTableFromCsv(decodeCsvBytes(bytes), name: name);
    }
    throw FormatException(trf('Неподдерживаемый формат: {p0}', {'p0': ext}));
  }

  // ---------------------------------------------------------------------------
  //  XLSX
  // ---------------------------------------------------------------------------

  /// Таблица в XLSX: лист с колонками/строками + лист «Данные» с KV из `data`.
  ///
  /// Формат XLSX — это zip с OOXML-файлами; собирается напрямую через
  /// `package:archive` (без лишних зависимостей и конфликтов версий).
  /// Ячейки пишутся как inline-строки или числа.
  static Uint8List tableToXlsx(QuestTable table) {
    final sheets = <_XlsxSheet>[
      _XlsxSheet(
        name: sanitizeSheetName(table.name),
        rows: _tableToXlsxRows(table),
      ),
    ];
    if (table.data.isNotEmpty) {
      sheets.add(_XlsxSheet(name: tr('Данные (KV)'), rows: _kvToXlsxRows(table)));
    }
    return _buildXlsx(sheets);
  }

  static List<List<Map<String, dynamic>>> _tableToXlsxRows(QuestTable table) {
    final rows = <List<Map<String, dynamic>>>[];
    final withNames = table.hasRowNames;
    rows.add([
      if (withNames) {'v': '__row_name', 'bold': true},
      for (final col in table.columns) {'v': col, 'bold': true},
    ]);
    final maxRows = table.rows.length > _maxSheetRows
        ? _maxSheetRows
        : table.rows.length;
    for (var i = 0; i < maxRows; i++) {
      final row = table.rows[i];
      rows.add([
        if (withNames) {'v': table.rowName(i)},
        for (final col in table.columns)
          {'v': _smartValue(row[col])},
      ]);
    }
    return rows;
  }

  static List<List<Map<String, dynamic>>> _kvToXlsxRows(QuestTable table) {
    final rows = <List<Map<String, dynamic>>>[
      [
        {'v': 'ключ', 'bold': true},
        {'v': 'значение', 'bold': true},
      ],
    ];
    for (final entry in table.data.entries) {
      rows.add([
        {'v': entry.key},
        {'v': _smartValue(entry.value)},
      ]);
    }
    return rows;
  }

  /// Число → число, остальные значения → текст (мапы/списки — компактный JSON).
  static dynamic _smartValue(dynamic value) {
    if (value == null) return '';
    if (value is num) return value;
    return _limit(valueToText(value));
  }

  static String _colRef(int index) => columnLabel(index);

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _sheetXml(_XlsxSheet sheet) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    );
    buffer.write('<sheetData>');
    for (var r = 0; r < sheet.rows.length; r++) {
      buffer.write('<row r="${r + 1}">');
      final cells = sheet.rows[r];
      for (var c = 0; c < cells.length; c++) {
        final cell = cells[c];
        final ref = '${_colRef(c)}${r + 1}';
        final v = cell['v'];
        final bold = cell['bold'] == true;
        final style = bold ? ' s="1"' : '';
        if (v is num) {
          buffer.write('<c r="$ref"$style><v>$v</v></c>');
        } else {
          final text = _xmlEscape(v?.toString() ?? '');
          buffer.write(
            '<c r="$ref"$style t="inlineStr"><is><t xml:space="preserve">$text</t></is></c>',
          );
        }
      }
      buffer.write('</row>');
    }
    buffer.write('</sheetData></worksheet>');
    return buffer.toString();
  }

  static Uint8List _buildXlsx(List<_XlsxSheet> sheets) {
    final archive = Archive();
    void addFile(String path, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    final typeEntries = [
      for (var i = 0; i < sheets.length; i++)
        '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
    ].join();
    addFile(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '$typeEntries'
      '</Types>',
    );

    addFile(
      '_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>',
    );

    final sheetsXml = [
      for (var i = 0; i < sheets.length; i++)
        '<sheet name="${_xmlEscape(sheets[i].name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>',
    ].join();
    addFile(
      'xl/workbook.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>$sheetsXml</sheets></workbook>',
    );

    final sheetRels = [
      for (var i = 0; i < sheets.length; i++)
        '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>',
    ].join();
    addFile(
      'xl/_rels/workbook.xml.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '$sheetRels'
      '<Relationship Id="rIdStyle" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>',
    );

    addFile(
      'xl/styles.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="2"><font><name t="Calibri"/></font><font><b/><name t="Calibri"/></font></fonts>'
      '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="2">'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      '</cellXfs>'
      '</styleSheet>',
    );

    for (var i = 0; i < sheets.length; i++) {
      addFile('xl/worksheets/sheet${i + 1}.xml', _sheetXml(sheets[i]));
    }

    final zipBytes = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipBytes);
  }

  // ---------------------------------------------------------------------------
  //  Сохранение в файл
  // ---------------------------------------------------------------------------

  static Future<bool> exportTableCsv(QuestTable table) async {
    final csv = tableToCsv(table);
    return _saveBytes(
      bytes: Uint8List.fromList(utf8.encode(csv)),
      fileName: '${sanitizeFileName(table.name)}.csv',
      dialogTitle: tr('Экспорт таблицы в CSV'),
      extensions: const ['csv'],
    );
  }

  static Future<bool> exportTableXlsx(QuestTable table) async {
    final bytes = tableToXlsx(table);
    return _saveBytes(
      bytes: bytes,
      fileName: '${sanitizeFileName(table.name)}.xlsx',
      dialogTitle: tr('Экспорт таблицы в XLSX'),
      extensions: const ['xlsx'],
    );
  }

  static Future<bool> exportTableJson(QuestTable table) async {
    final json = const JsonEncoder.withIndent(
      '  ',
    ).convert(table.toJson());
    return _saveBytes(
      bytes: Uint8List.fromList(utf8.encode(json)),
      fileName: '${sanitizeFileName(table.name)}.json',
      dialogTitle: tr('Экспорт таблицы в JSON'),
      extensions: const ['json'],
    );
  }

  static Future<bool> _saveBytes({
    required Uint8List bytes,
    required String fileName,
    required String dialogTitle,
    required List<String> extensions,
  }) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final result = await FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: extensions,
      );
      return result != null;
    }
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(p.join(tempDir.path, fileName));
    await tempFile.writeAsBytes(bytes);
    final params = SaveFileDialogParams(
      sourceFilePath: tempFile.path,
      fileName: fileName,
    );
    final result = await FlutterFileDialog.saveFile(params: params);
    try {
      await tempFile.delete();
    } catch (_) {}
    return result != null;
  }
}

/// Внутреннее описание листа XLSX для генератора.
class _XlsxSheet {
  final String name;
  final List<List<Map<String, dynamic>>> rows;

  const _XlsxSheet({required this.name, required this.rows});
}
