import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/core/services/table_export_service.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/data/table_data_keys_sheet.dart';
import 'package:canvas_app/features/resources/screens/data/table_guide.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

/// Визуальный редактор таблиц («кассета», ведущая себя как базовый Excel):
/// адресная строка, формула-бар, редактируемые ячейки, вставка фото из
/// ресурсов квеста (хранится только путь `res/...`), импорт/экспорт CSV и
/// XLSX. Значения ячеек — строки-формулы, вычисляемые движком.
class TableEditorScreen extends StatefulWidget {
  final QuestTable table;
  final String questId;
  final Function(QuestTable) onSave;

  /// Если `true` — экран работает как пикер ячейки: редактирование скрыто,
  /// тап по ячейке возвращает `Navigator.pop(context, '{имя["колонка"][N]}')`.
  final bool cellPickerMode;

  const TableEditorScreen({
    super.key,
    required this.table,
    required this.questId,
    required this.onSave,
    this.cellPickerMode = false,
  });

  @override
  State<TableEditorScreen> createState() => _TableEditorScreenState();
}

/// Один ярус редактора: корневая таблица или вложенная в ячейку.
class _TableLevel {
  final QuestTable table;
  final String label;

  /// Координаты ячейки родителя, в которой живёт этот ярус.
  final int? parentRow;
  final int? parentCol;

  int? selRow;
  int selCol = 0;
  final List<Map<String, dynamic>> undo = [];

  _TableLevel({
    required this.table,
    this.label = '',
    this.parentRow,
    this.parentCol,
  });
}

class _TableEditorScreenState extends State<TableEditorScreen> {
  static const double _colWidth = 170;
  static const double _rowHeight = 48;
  static const double _headerHeight = 38;
  static const double _rowNumWidth = 64;
  static const int _maxUndo = 30;

  /// Ярусы: первый — корневая таблица, дальше — подтаблицы в ячейках.
  final List<_TableLevel> _levels = [];

  _TableLevel get _level => _levels.last;
  QuestTable get _table => _level.table;
  int? get _selRow => _level.selRow;
  set _selRow(int? value) => _level.selRow = value;
  int get _selCol => _level.selCol;
  set _selCol(int value) => _level.selCol = value;
  List<Map<String, dynamic>> get _undoStack => _level.undo;
  bool get _isNestedLevel => _levels.length > 1;

  bool _hasEdits = false;

  final TextEditingController _formulaCtrl = TextEditingController();
  final TextEditingController _addrCtrl = TextEditingController();
  final FocusNode _formulaFocus = FocusNode();
  final FocusNode _gridFocus = FocusNode();
  final ScrollController _hScroll = ScrollController();
  final ScrollController _vScroll = ScrollController();
  final ScrollController _hHeader = ScrollController();
  final ScrollController _vRows = ScrollController();

  bool _editingFormula = false;

  /// Кэш будущих путей ресурсов (чтобы FutureBuilder не пересоздавался на
  /// каждый rebuild — иначе бесконечный цикл перерисовки).
  final Map<String, Future<File?>> _fileFutures = {};

  static final RegExp _imageExt = RegExp(r'\.(png|jpe?g|webp|gif|bmp)$');

  /// Является ли значение ячейки ссылкой на картинку ресурсов квеста.
  static bool isImageResource(String value) {
    final v = value.trim();
    return v.startsWith('res/') && _imageExt.hasMatch(v.toLowerCase());
  }

  @override
  void initState() {
    super.initState();
    _levels.add(
      _TableLevel(
        table: QuestTable(
          name: widget.table.name,
          columns: List.of(widget.table.columns),
          rows: widget.table.rows
              .map((r) => Map<String, dynamic>.from(r))
              .toList(),
          data: Map.of(widget.table.data),
        ),
      ),
    );
    _hScroll.addListener(_syncHeaderScroll);
    _vScroll.addListener(_syncRowNumbersScroll);
  }

  void _syncHeaderScroll() {
    if (!_hHeader.hasClients || !_hScroll.hasClients) return;
    final target = _hScroll.offset
        .clamp(0.0, _hHeader.position.maxScrollExtent);
    if ((_hHeader.offset - target).abs() > 0.5) _hHeader.jumpTo(target);
  }

  void _syncRowNumbersScroll() {
    if (!_vRows.hasClients || !_vScroll.hasClients) return;
    final target = _vScroll.offset
        .clamp(0.0, _vRows.position.maxScrollExtent);
    if ((_vRows.offset - target).abs() > 0.5) _vRows.jumpTo(target);
  }

  @override
  void dispose() {
    _hScroll.removeListener(_syncHeaderScroll);
    _vScroll.removeListener(_syncRowNumbersScroll);
    _formulaCtrl.dispose();
    _addrCtrl.dispose();
    _formulaFocus.dispose();
    _gridFocus.dispose();
    _hScroll.dispose();
    _vScroll.dispose();
    _hHeader.dispose();
    _vRows.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  //  Выбор ячейки / адрес
  // ---------------------------------------------------------------------------

  String _cellAddress(int row, int col) =>
      '${TableExportService.columnLabel(col)}${row + 1}';

  dynamic _cellValue(int row, int col) {
    if (row < 0 || row >= _table.rows.length) return null;
    if (col < 0 || col >= _table.columns.length) return null;
    return _table.rows[row][_table.columns[col]];
  }

  bool _isNestedCell(int row, int col) =>
      QuestTable.isNestedValue(_cellValue(row, col));

  /// Обычный текст ячейки для формулы. Вложенная таблица — не формула.
  String _cellText(int row, int col) {
    final value = _cellValue(row, col);
    if (QuestTable.isNestedValue(value)) return '';
    return value == null ? '' : value.toString();
  }

  void _syncFormulaFromSelection() {
    if (_selRow != null && _table.columns.isNotEmpty) {
      _formulaCtrl.text = _cellText(_selRow!, _selCol);
      _addrCtrl.text = _cellAddress(_selRow!, _selCol);
    } else {
      _formulaCtrl.clear();
      _addrCtrl.clear();
    }
    _editingFormula = false;
  }

  void _selectCell(int row, int col, {bool scrollIntoView = true}) {
    if (row < 0 || row >= _table.rows.length) return;
    if (col < 0 || col >= _table.columns.length) return;
    _commitFormulaEditIfNeeded();
    setState(() {
      _selRow = row;
      _selCol = col;
      _syncFormulaFromSelection();
    });
    if (scrollIntoView) _ensureCellVisible(row, col);
  }

  void _ensureCellVisible(int row, int col) {
    if (!_vScroll.hasClients || !_hScroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vScroll.hasClients || !_hScroll.hasClients) return;
      final top = row * _rowHeight;
      final bottom = top + _rowHeight;
      final viewTop = _vScroll.offset + 24;
      final viewBottom = _vScroll.offset + _vScroll.position.viewportDimension;
      if (top < viewTop) {
        _vScroll.jumpTo(
          (top - 8).clamp(0.0, _vScroll.position.maxScrollExtent),
        );
      } else if (bottom > viewBottom) {
        final target = bottom - _vScroll.position.viewportDimension + 8;
        _vScroll.jumpTo(target.clamp(0.0, _vScroll.position.maxScrollExtent));
      }

      final left = col * _colWidth;
      final right = left + _colWidth;
      final viewLeft = _hScroll.offset;
      final viewRight = _hScroll.offset + _hScroll.position.viewportDimension;
      if (left < viewLeft) {
        _hScroll.jumpTo(
          (left - 8).clamp(0.0, _hScroll.position.maxScrollExtent),
        );
      } else if (right > viewRight) {
        final target = right - _hScroll.position.viewportDimension + 8;
        _hScroll.jumpTo(target.clamp(0.0, _hScroll.position.maxScrollExtent));
      }
    });
  }

  /// Ссылка вида `{имя["колонка"][N]}` для выбранной ячейки (N — 1-based).
  String _cellRef(int row, int col) {
    final colName = _table.columns[col].replaceAll('"', r'\"');
    // Номер строки обязательно в своих скобках: {т["цена"]1} движок читает как
    // {т["цена"]} + мусор, «1» съедается молча и вместо ячейки приходит весь
    // столбец. Канон — {т["цена"][1]}, он покрыт тестом ядра.
    return '{${_table.name}["$colName"][${row + 1}]}';
  }

  /// Парсит адрес вида «A12» → (row: 11, col: 0).
  (int, int)? _parseAddress(String raw) {
    final m = RegExp(r'^\s*([A-Za-z]{1,3})\s*(\d+)\s*$').firstMatch(raw);
    if (m == null) return null;
    final letters = m.group(1)!.toUpperCase();
    var col = 0;
    for (final ch in letters.split('')) {
      col = col * 26 + (ch.codeUnitAt(0) - 64);
    }
    final row = int.parse(m.group(2)!) - 1;
    return (row, col - 1);
  }

  void _jumpToAddress(String raw) {
    final parsed = _parseAddress(raw);
    if (parsed == null) {
      _snack(tr('Неверный адрес ячейки (пример: A1)'));
      return;
    }
    final (row, col) = parsed;
    if (row < 0 ||
        row >= _table.rows.length ||
        col < 0 ||
        col >= _table.columns.length) {
      _snack(tr('Ячейка вне диапазона таблицы'));
      return;
    }
    _selectCell(row, col);
  }

  // ---------------------------------------------------------------------------
  //  Формула-бар
  // ---------------------------------------------------------------------------

  void _commitFormulaEditIfNeeded() {
    if (!_editingFormula || _selRow == null) return;
    _applyFormula(_formulaCtrl.text);
  }

  void _applyFormula(String raw) {
    if (_selRow == null) return;
    if (_table.rows.isEmpty) return;
    final col = _table.columns[_selCol];
    final row = _selRow!;
    if (row >= _table.rows.length) return;
    // Формула не должна затирать вложенную таблицу: у неё своя жизнь.
    if (QuestTable.isNestedValue(_table.rows[row][col])) {
      _editingFormula = false;
      return;
    }
    if (_table.rows[row][col] == raw) {
      _editingFormula = false;
      return;
    }
    _pushUndo(columns: false, rows: true);
    setState(() {
      _table.rows[row][col] = raw;
      _editingFormula = false;
      _hasEdits = true;
    });
  }

  void _clearCurrentCell() {
    if (_selRow == null) return;
    _pushUndo(columns: false, rows: true);
    setState(() {
      _table.rows[_selRow!][_table.columns[_selCol]] = '';
      _formulaCtrl.clear();
      _hasEdits = true;
    });
  }

  Future<void> _insertImageIntoCurrent() async {
    if (_selRow == null) {
      _snack(tr('Сначала выберите ячейку'));
      return;
    }
    final res = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    if (res == null || !mounted) return;
    _pushUndo(columns: false, rows: true);
    setState(() {
      _table.rows[_selRow!][_table.columns[_selCol]] = res.path;
      _formulaCtrl.text = res.path;
      _hasEdits = true;
    });
  }

  /// Полноценный редактор формул (выбор переменных, операторы) — как в
  /// блоках скриптов. Возвращаемое значение кладётся в ячейку как есть.
  Future<void> _openFormulaEditor() async {
    final expr = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ExpressionEditorScreen(
          initialValue: _formulaCtrl.text,
          questId: widget.questId,
        ),
      ),
    );
    if (expr == null || !mounted) return;
    if (_selRow != null) {
      setState(() {
        _formulaCtrl.text = expr;
        _applyFormula(expr);
      });
    } else {
      _formulaCtrl.text = expr;
    }
  }

  // ---------------------------------------------------------------------------
  //  Столбцы и строки
  // ---------------------------------------------------------------------------

  void _pushUndo({required bool columns, required bool rows}) {
    // Глубокий снимок: ячейка может содержать вложенную таблицу, и её правки
    // не должны менять уже сохранённый шаг отмены.
    _undoStack.add({
      'columns': columns || rows ? List.of(_table.columns) : _table.columns,
      'rows': rows ? _deepCopy(_table.rows) : _table.rows,
      'data': _deepCopy(_table.data),
    });
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
  }

  static dynamic _deepCopy(dynamic value) {
    try {
      return jsonDecode(jsonEncode(value));
    } catch (_) {
      return value;
    }
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    final snap = _undoStack.removeLast();
    setState(() {
      _table.columns = List<String>.from(snap['columns'] as List);
      _table.rows = (snap['rows'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      final data = snap['data'];
      if (data is Map) {
        _table.data = Map<String, dynamic>.from(data.cast<String, dynamic>());
      }
      _hasEdits = true;
      if (_selCol >= _table.columns.length) _selCol = 0;
      if ((_selRow ?? 0) >= _table.rows.length) _selRow = null;
      _syncFormulaFromSelection();
    });
  }

  /// Ключи хранилища скриптов (`data`) — единственное, что видит блок «Данные».
  Future<void> _editDataKeys() async {
    _commitFormulaEditIfNeeded();
    final next = await showTableDataKeysSheet(context, table: _table);
    if (next == null || !mounted) return;
    if (mapEquals(next, _table.data)) return;
    final before = _table.data.length;
    _pushUndo(columns: false, rows: false);
    setState(() {
      _table.data = next;
      _hasEdits = true;
    });
    _snack(trf('Ключей скриптов: было {before}, стало {p0}', {'before': before, 'p0': next.length}));
  }

  Future<void> _addColumn() async {
    final ctrl = TextEditingController();
    final name = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Новый столбец')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Название')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Добавить')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    if (_table.columns.contains(name)) {
      _snack(trf('Столбец «{col}» уже есть', {'col': name}));
      return;
    }
    _pushUndo(columns: true, rows: true);
    setState(() {
      _table.updateColumns([..._table.columns, name]);
      _hasEdits = true;
      _selCol = _table.columns.length - 1;
    });
  }

  Future<void> _renameColumn(int index) async {
    if (index < 0 || index >= _table.columns.length) return;
    final old = _table.columns[index];
    final ctrl = TextEditingController(text: old);
    final name = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Переименовать столбец')),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == old || !mounted) return;
    if (_table.columns.contains(name)) {
      _snack(trf('Столбец «{col}» уже есть', {'col': name}));
      return;
    }
    _pushUndo(columns: true, rows: true);
    final newCols = [..._table.columns];
    newCols[index] = name;
    for (final row in _table.rows) {
      final v = row.remove(old);
      row[name] = v ?? '';
    }
    setState(() {
      _table.columns = newCols;
      _hasEdits = true;
    });
  }

  void _deleteColumn(int index) {
    if (index < 0 || index >= _table.columns.length) return;
    final col = _table.columns[index];
    _pushUndo(columns: true, rows: true);
    final newCols = [..._table.columns]..remove(col);
    setState(() {
      _table.updateColumns(newCols);
      if (_selCol >= _table.columns.length) _selCol = 0;
      _formulaCtrl.clear();
      _hasEdits = true;
    });
    _snackWithUndo(trf('Столбец «{p0}» удалён', {'p0': col}));
  }

  void _deleteRow(int index) {
    if (index < 0 || index >= _table.rows.length) return;
    _pushUndo(columns: false, rows: true);
    setState(() {
      _table.rows.removeAt(index);
      if ((_selRow ?? 0) >= _table.rows.length) {
        _selRow = _table.rows.isEmpty ? null : _table.rows.length - 1;
      }
      _formulaCtrl.clear();
      _hasEdits = true;
    });
    _snackWithUndo(trf('Строка {p0} удалена', {'p0': index + 1}));
  }

  /// Вставляет пустую строку на позицию [index] и выделяет её — как
  /// «Вставить» в Excel.
  void _insertRowAt(int index) {
    final insertAt = index.clamp(0, _table.rows.length);
    _pushUndo(columns: false, rows: true);
    setState(() {
      _table.rows.insert(insertAt, {for (final col in _table.columns) col: ''});
      _selRow = insertAt;
      _hasEdits = true;
      _syncFormulaFromSelection();
    });
    _ensureCellVisible(insertAt, _selCol);
  }

  /// Вставляет пустую строку сразу под выбранной (или в конец, если
  /// ничего не выбрано).
  void _insertRowBelow() =>
      _insertRowAt(_selRow == null ? _table.rows.length : _selRow! + 1);

  void _selectRow(int row) {
    if (_table.columns.isEmpty) return;
    _selectCell(
      row,
      _selCol.clamp(0, _table.columns.length - 1),
      scrollIntoView: false,
    );
  }

  Future<void> _rowMenu(int row) async {
    if (row < 0 || row >= _table.rows.length) return;
    _selectRow(row);
    final scheme = Theme.of(context).colorScheme;
    final action = await showAdaptiveSheet<String>(
      context: context,
      scrollable: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  trf('Строка {p0}', {'p0': row + 1}),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              dense: true,
            ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: Text(tr('Вставить строку выше')),
              onTap: () => Navigator.pop(ctx, 'insertAbove'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: Text(tr('Вставить строку ниже')),
              onTap: () => Navigator.pop(ctx, 'insertBelow'),
            ),
            ListTile(
              leading: const Icon(Icons.chevron_left),
              title: Text(tr('Переместить выше')),
              enabled: row > 0,
              onTap: () => Navigator.pop(ctx, 'moveUp'),
            ),
            ListTile(
              leading: const Icon(Icons.chevron_right),
              title: Text(tr('Переместить ниже')),
              enabled: row < _table.rows.length - 1,
              onTap: () => Navigator.pop(ctx, 'moveDown'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(
                tr('Удалить строку'),
                style: TextStyle(color: scheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'insertAbove':
        _insertRowAt(row);
      case 'insertBelow':
        _insertRowAt(row + 1);
      case 'moveUp':
        _moveRow(row, -1);
      case 'moveDown':
        _moveRow(row, 1);
      case 'delete':
        _deleteRow(row);
    }
  }

  void _moveRow(int index, int dir) {
    if (index < 0 || index >= _table.rows.length) return;
    final target = index + dir;
    if (target < 0 || target >= _table.rows.length) return;
    _pushUndo(columns: false, rows: true);
    setState(() {
      final row = _table.rows.removeAt(index);
      _table.rows.insert(target, row);
      _selRow = target;
      _formulaCtrl.clear();
      _hasEdits = true;
    });
  }

  /// Вставляет колонку справа от выбранной (или в конец).
  Future<void> _insertColumnRight() async {
    final ctrl = TextEditingController();
    final name = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Новый столбец')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Название')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Добавить')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    if (_table.columns.contains(name)) {
      _snack(trf('Столбец «{col}» уже есть', {'col': name}));
      return;
    }
    final insertAt = _selRow == null
        ? _table.columns.length
        : (_selCol + 1).clamp(0, _table.columns.length);
    _pushUndo(columns: true, rows: true);
    final newCols = [..._table.columns]..insert(insertAt, name);
    setState(() {
      _table.updateColumns(newCols);
      _selCol = insertAt;
      _hasEdits = true;
    });
  }

  void _moveColumn(int index, int dir) {
    if (index < 0 || index >= _table.columns.length) return;
    final target = index + dir;
    if (target < 0 || target >= _table.columns.length) return;
    final old = _table.columns[index];
    final newCols = [..._table.columns];
    newCols.removeAt(index);
    newCols.insert(target, old);
    _pushUndo(columns: true, rows: true);
    setState(() {
      for (final row in _table.rows) {
        final v = row[old];
        row
          ..remove(old)
          ..removeWhere((key, _) => !newCols.contains(key));
        row[old] = v ?? '';
      }
      _table.columns = newCols;
      _selCol = target;
      _formulaCtrl.clear();
      _hasEdits = true;
    });
  }

  // ---------------------------------------------------------------------------
  //  Вложенные таблицы и меню ячейки
  // ---------------------------------------------------------------------------

  QuestTable _newNestedTable() {
    final first = tr('Столбец 1');
    final second = tr('Столбец 2');
    final address = _selRow == null
        ? _table.name
        : '${_table.name}.${_cellAddress(_selRow!, _selCol)}';
    return QuestTable(
      name: address,
      columns: [first, second],
      rows: [
        {first: '', second: ''},
      ],
    );
  }

  /// Открывает подтаблицу в ячейке. Пустая ячейка получает заготовку, а
  /// формулу или картинку перед заменой подтверждаем.
  Future<void> _openNestedEditor(int row, int col) async {
    if (widget.cellPickerMode) return;
    _commitFormulaEditIfNeeded();
    final raw = _cellValue(row, col);
    QuestTable child;
    if (QuestTable.isNestedValue(raw)) {
      child = QuestTable.nestedFromValue(raw)!;
    } else {
      final hasValue = _cellText(row, col).trim().isNotEmpty;
      if (hasValue) {
        final replace = await showAppDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('Заменить значение вложенной таблицей?')),
            content: Text(
              tr('В ячейке уже есть значение или формула. Оно будет заменено подтаблицей.'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('Отмена')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('Заменить')),
              ),
            ],
          ),
        );
        if (replace != true || !mounted) return;
      }
      _pushUndo(columns: true, rows: true);
      child = _newNestedTable();
      setState(() {
        _table.rows[row][_table.columns[col]] = child.toNestedValue();
        _hasEdits = true;
      });
    }
    if (!mounted) return;
    setState(() {
      _levels.add(
        _TableLevel(
          table: child,
          label: _cellAddress(row, col),
          parentRow: row,
          parentCol: col,
        ),
      );
      _syncFormulaFromSelection();
    });
    _resetScrolls();
    _gridFocus.requestFocus();
  }

  void _syncCurrentLevelIntoParent() {
    final level = _level;
    final row = level.parentRow;
    final col = level.parentCol;
    if (row == null || col == null || _levels.length < 2) return;
    final parent = _levels[_levels.length - 2];
    if (row >= parent.table.rows.length ||
        col >= parent.table.columns.length) {
      return;
    }
    parent.table.rows[row][parent.table.columns[col]] =
        level.table.toNestedValue();
  }

  /// Ярус выше: изменения подтаблицы возвращаются в ячейку родителя.
  void _drillUpTo(int index) {
    if (index < 0 || index >= _levels.length - 1) return;
    _commitFormulaEditIfNeeded();
    setState(() {
      while (_levels.length - 1 > index) {
        final closing = _levels.last;
        _syncCurrentLevelIntoParent();
        _levels.removeLast();
        final parent = _levels.last;
        final row = closing.parentRow;
        if (row != null &&
            row >= 0 &&
            row < parent.table.rows.length) {
          parent.selRow = row;
          if (parent.table.columns.isNotEmpty) {
            parent.selCol = (closing.parentCol ?? 0)
                .clamp(0, parent.table.columns.length - 1);
          }
        }
      }
      _syncFormulaFromSelection();
    });
    final level = _level;
    if (level.selRow != null && level.table.columns.isNotEmpty) {
      _ensureCellVisible(level.selRow!, level.selCol);
    }
  }

  void _drillUp() => _drillUpTo(_levels.length - 2);

  void _resetScrolls() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_hScroll.hasClients) _hScroll.jumpTo(0);
      if (_vScroll.hasClients) _vScroll.jumpTo(0);
    });
  }

  void _syncAllLevels() {
    for (var i = _levels.length - 1; i > 0; i--) {
      final child = _levels[i];
      final row = child.parentRow;
      final col = child.parentCol;
      if (row == null || col == null) continue;
      final parent = _levels[i - 1];
      if (row >= parent.table.rows.length ||
          col >= parent.table.columns.length) {
        continue;
      }
      parent.table.rows[row][parent.table.columns[col]] =
          child.table.toNestedValue();
    }
  }

  void _deleteNestedCell(int row, int col) {
    _pushUndo(columns: false, rows: true);
    setState(() {
      _table.rows[row][_table.columns[col]] = '';
      _hasEdits = true;
      _syncFormulaFromSelection();
    });
    _snack(tr('Вложенная таблица удалена'));
  }

  Future<void> _openCellMenu(int row, int col) async {
    if (widget.cellPickerMode) return;
    _selectCell(row, col, scrollIntoView: false);
    final nested = QuestTable.nestedFromValue(_cellValue(row, col));
    final hasValue = _cellText(row, col).trim().isNotEmpty;
    final scheme = Theme.of(context).colorScheme;

    final action = await showAdaptiveSheet<String>(
      context: context,
      scrollable: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  trf('Ячейка {p0}', {'p0': _cellAddress(row, col)}),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                nested != null
                    ? trf('Вложенная таблица {p0}×{p1}', {
                        'p0': nested.columns.length,
                        'p1': nested.rows.length,
                      })
                    : (hasValue ? tr('Формула или значение') : tr('Пусто')),
              ),
              dense: true,
            ),
            if (nested != null)
              ListTile(
                leading: const Icon(Icons.grid_on_rounded),
                title: Text(tr('Открыть вложенную таблицу')),
                onTap: () => Navigator.pop(ctx, 'openNested'),
              )
            else ...[
              ListTile(
                leading: const Icon(Icons.functions),
                title: Text(tr('Изменить формулу')),
                onTap: () => Navigator.pop(ctx, 'formula'),
              ),
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(
                  hasValue
                      ? tr('Заменить на вложенную таблицу')
                      : tr('Создать вложенную таблицу'),
                ),
                onTap: () => Navigator.pop(ctx, 'makeNested'),
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(tr('Вставить картинку из ресурсов')),
                onTap: () => Navigator.pop(ctx, 'image'),
              ),
            ],
            if (hasValue && nested == null)
              ListTile(
                leading: const Icon(Icons.backspace_outlined),
                title: Text(tr('Очистить ячейку')),
                onTap: () => Navigator.pop(ctx, 'clear'),
              ),
            if (nested != null)
              ListTile(
                leading: Icon(Icons.delete_outline, color: scheme.error),
                title: Text(
                  tr('Удалить вложенную таблицу'),
                  style: TextStyle(color: scheme.error),
                ),
                onTap: () => Navigator.pop(ctx, 'deleteNested'),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.table_rows_rounded),
              title: Text(tr('Вставить строку ниже')),
              onTap: () => Navigator.pop(ctx, 'insertRow'),
            ),
            ListTile(
              leading: const Icon(Icons.view_column_rounded),
              title: Text(tr('Вставить столбец справа')),
              onTap: () => Navigator.pop(ctx, 'insertColumn'),
            ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'openNested':
        await _openNestedEditor(row, col);
      case 'formula':
        await _openFormulaEditor();
      case 'makeNested':
        await _openNestedEditor(row, col);
      case 'image':
        await _insertImageIntoCurrent();
      case 'clear':
        _clearCurrentCell();
      case 'deleteNested':
        _deleteNestedCell(row, col);
      case 'insertRow':
        _insertRowBelow();
      case 'insertColumn':
        await _insertColumnRight();
    }
  }



  Future<void> _importCsv() async {
    final files = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (files.isEmpty || files.single.path == null || !mounted) {
      return;
    }
    try {
      final imported = await TableExportService.importTableFromFile(
        files.single.path!,
      );
      _pushUndo(columns: true, rows: true);
      if (!mounted) return;
      setState(() {
        _table.columns = List.of(imported.columns);
        _table.rows = imported.rows
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        _selRow = null;
        _selCol = 0;
        _formulaCtrl.clear();
        _hasEdits = true;
      });
      _snackWithUndo(
        trf('Импортировано: {p0} столбцов, {p1} строк', {
          'p0': _table.columns.length,
          'p1': _table.rows.length,
        }),
      );
    } catch (e) {
      _snack(trf('Ошибка импорта CSV: {p0}', {'p0': friendlyError(e)}));
    }
  }

  Future<void> _export(String format) async {
    _commitFormulaEditIfNeeded();
    try {
      final ok = switch (format) {
        'csv' => await TableExportService.exportTableCsv(_table),
        'xlsx' => await TableExportService.exportTableXlsx(_table),
        'json' => await TableExportService.exportTableJson(_table),
        _ => false,
      };
      if (ok) {
        // CSV физически не умеет пары «ключ → значение»: без этой строки
        // автор теряет хранилище молча и ищет баг в движке.
        _snack(
          format == 'csv' && _table.data.isNotEmpty
              ? trf('CSV сохранён: в нём только сетка, {p0} ключей хранилища остались здесь', {'p0': _table.data.length})
              : tr('Файл сохранён'),
        );
      }
    } catch (e) {
      _snack(trf('Ошибка экспорта: {p0}', {'p0': friendlyError(e)}));
    }
  }

  // ---------------------------------------------------------------------------
  //  Сохранение / выход
  // ---------------------------------------------------------------------------

  void _save() {
    _commitFormulaEditIfNeeded();
    _syncAllLevels();
    widget.onSave(_levels.first.table);
    Navigator.pop(context);
  }

  Future<bool> _confirmDiscard() async {
    if (!_hasEdits) return true;
    final action = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Несохранённые изменения')),
        content: Text(tr('Сохранить таблицу перед выходом?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: Text(tr('Не сохранять')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(tr('Остаться')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (action == 'save') {
      _save();
      return false;
    }
    if (action == 'cancel' || action == null) return false;
    return true;
  }

  // ---------------------------------------------------------------------------
  //  UI helpers
  // ---------------------------------------------------------------------------

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  void _snackWithUndo(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: tr('Отменить'), onPressed: _undo),
      ),
    );
  }

  Widget _thumbnail(String path) {
    final future = _fileFutures.putIfAbsent(
      path,
      () => _resolveResourceFile(path),
    );
    return FutureBuilder<File?>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final file = snap.data;
        if (file == null || !file.existsSync()) {
          return const Icon(Icons.broken_image, size: 20, color: Colors.red);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(
            file,
            width: 40,
            height: 28,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.broken_image, size: 20, color: Colors.red),
          ),
        );
      },
    );
  }

  Future<File?> _resolveResourceFile(String relativePath) =>
      QuestImageSource.resolve(widget.questId, relativePath);

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!_isNestedLevel) return KeyEventResult.ignored;
      _drillUp();
      return KeyEventResult.handled;
    }
    if (_selRow == null || _table.columns.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final dir = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      _selectCell(
        (_selRow! + dir).clamp(0, _table.rows.length - 1),
        _selCol,
        scrollIntoView: true,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      final dir = event.logicalKey == LogicalKeyboardKey.arrowRight ? 1 : -1;
      _selectCell(
        _selRow!,
        (_selCol + dir).clamp(0, _table.columns.length - 1),
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _selectCell(
        (_selRow! + 1).clamp(0, _table.rows.length - 1),
        _selCol,
        scrollIntoView: true,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: widget.cellPickerMode,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        // «Назад» внутри подтаблицы возвращает на ярус выше, а не закрывает
        // весь редактор с потерей контекста.
        if (_isNestedLevel) {
          _drillUp();
          return;
        }
        if (await _confirmDiscard()) {
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          backgroundColor: scheme.surface,
          foregroundColor: scheme.onSurface,
          leading: _isNestedLevel
              ? IconButton(
                  tooltip: tr('На уровень выше'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _drillUp,
                )
              : null,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _table.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.manrope(fontWeight: FontWeight.bold),
              ),
              Text(
                widget.cellPickerMode
                    ? tr('Выбор ячейки')
                    : (_isNestedLevel ? tr('Подтаблица') : tr('Редактор таблицы')),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          bottom: _isNestedLevel
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(34),
                  child: SizedBox(height: 34, child: _buildBreadcrumbs(scheme)),
                )
              : null,
          actions: [
            if (widget.cellPickerMode)
              IconButton(
                tooltip: tr('Вернуться'),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              )
            else ...[
              if (_undoStack.isNotEmpty)
                IconButton(
                  tooltip: tr('Отменить'),
                  icon: const Icon(Icons.undo),
                  onPressed: _undo,
                ),
              IconButton(
                tooltip: _table.data.isEmpty
                    ? tr('Ключи скриптов — пусто')
                    : trf('Ключи скриптов: {n}', {'n': _table.data.length}),
                icon: _table.data.isEmpty
                    ? const Icon(Icons.data_object_rounded)
                    : Badge.count(
                        count: _table.data.length,
                        child: const Icon(Icons.data_object_rounded),
                      ),
                onPressed: _editDataKeys,
              ),
              PopupMenuButton<String>(
                tooltip: tr('Экспорт'),
                icon: const Icon(Icons.ios_share),
                onSelected: _export,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'csv',
                    child: _ExportOption(
                      title: 'CSV',
                      note: tr('только сетка: ключи хранилища в файл не пишутся'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'xlsx',
                    child: _ExportOption(
                      title: 'XLSX (Excel)',
                      note: tr('сетка + отдельный лист «Данные»'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'json',
                    child: _ExportOption(
                      title: 'JSON',
                      note: tr('полный слепок: сетка и хранилище'),
                    ),
                  ),
                ],
              ),
              IconButton(
                tooltip: tr('Сохранить'),
                icon: const Icon(Icons.check, color: Colors.green),
                onPressed: _save,
              ),
            ],
          ],
        ),
        body: Focus(
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: Column(
            children: [
              if (!widget.cellPickerMode) ...[
                _buildToolbar(scheme),
                _buildFormulaBar(scheme),
              ],
              Expanded(child: _buildGrid(scheme)),
              _buildStatusBar(scheme),
            ],
          ),
        ),
      ),
    );
  }

  /// Дорожка ярусов: корень › A3 › B1. Тап по любому звену возвращает туда.
  Widget _buildBreadcrumbs(ColorScheme scheme) {
    final children = <Widget>[];
    for (var i = 0; i < _levels.length; i++) {
      if (i > 0) {
        children.add(
          Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
        );
      }
      final level = _levels[i];
      final isCurrent = i == _levels.length - 1;
      final label = i == 0 ? level.table.name : level.label;
      children.add(
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: isCurrent ? null : () => _drillUpTo(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: children),
    );
  }

  void _openNestedFromSelection() {
    if (_selRow == null || _table.columns.isEmpty) {
      _snack(tr('Сначала выберите ячейку'));
      return;
    }
    _openNestedEditor(_selRow!, _selCol);
  }

  Widget _buildToolbar(ColorScheme scheme) {
    final hasSelection = _selRow != null && _table.columns.isNotEmpty;
    final selectedNested =
        hasSelection && _isNestedCell(_selRow!, _selCol);

    // Одна компактная строка с горизонтальным скроллом: кнопки не прыгают
    // на вторую строку и не отнимают высоту у сетки на телефоне.
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _toolButton(
                    icon: Icons.playlist_add_rounded,
                    label: tr('Строка'),
                    onTap: _insertRowBelow,
                  ),
                  _toolButton(
                    icon: Icons.view_column_rounded,
                    label: tr('Столбец'),
                    onTap: _addColumn,
                  ),
                  _toolButton(
                    icon: Icons.account_tree_outlined,
                    label: tr('Подтаблица'),
                    onTap: hasSelection ? _openNestedFromSelection : null,
                  ),
                  _toolButton(
                    icon: Icons.functions,
                    label: tr('Формула'),
                    onTap: hasSelection && !selectedNested
                        ? _openFormulaEditor
                        : null,
                  ),
                  _toolButton(
                    icon: Icons.description_outlined,
                    label: tr('Импорт CSV'),
                    onTap: _importCsv,
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: tr('Отменить изменение'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.undo, size: 20),
            onPressed: _undoStack.isEmpty ? null : _undo,
          ),
        ],
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _buildFormulaBar(ColorScheme scheme) {
    final hasSelection = _selRow != null && _table.columns.isNotEmpty;
    final selectedNested =
        hasSelection && _isNestedCell(_selRow!, _selCol);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: scheme.surfaceContainer,
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 64, maxWidth: 96),
            child: TextField(
              controller: _addrCtrl,
              enabled: hasSelection,
              style: GoogleFonts.firaCode(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: scheme.primary),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: scheme.primary),
                ),
                disabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
                hintText: 'A1',
                hintStyle: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              onSubmitted: _jumpToAddress,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: selectedNested
                ? InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _openNestedEditor(_selRow!, _selCol),
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.grid_on_rounded,
                            size: 18,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tr('Вложенная таблица в ячейке'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Text(
                            tr('Открыть'),
                            style: TextStyle(
                              color: scheme.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: scheme.primary,
                          ),
                        ],
                      ),
                    ),
                  )
                : TextField(
                    controller: _formulaCtrl,
                    focusNode: _formulaFocus,
                    enabled: hasSelection,
                    style: GoogleFonts.firaCode(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      hintText: tr('Значение или формула, напр. {gold} + 2'),
                      border: const OutlineInputBorder(),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: tr('Вставить картинку из ресурсов'),
                            icon: const Icon(Icons.image, size: 20),
                            onPressed:
                                hasSelection ? _insertImageIntoCurrent : null,
                          ),
                          IconButton(
                            tooltip: tr('Очистить ячейку'),
                            icon: const Icon(Icons.backspace, size: 20),
                            onPressed: hasSelection ? _clearCurrentCell : null,
                          ),
                        ],
                      ),
                    ),
                    onChanged: (_) => setState(() => _editingFormula = true),
                    onSubmitted: (raw) {
                      _applyFormula(raw);
                      if (_selRow != null) {
                        final nextRow = (_selRow! + 1).clamp(
                          0,
                          _table.rows.length - 1,
                        );
                        _selectCell(nextRow, _selCol);
                      }
                    },
                  ),
          ),
          const SizedBox(width: 8),
          if (selectedNested)
            IconButton(
              tooltip: tr('Открыть вложенную таблицу'),
              icon: const Icon(Icons.grid_on_rounded, size: 22),
              onPressed: () => _openNestedEditor(_selRow!, _selCol),
            )
          else
            IconButton(
              tooltip: applyFormulaTooltip,
              icon: Icon(
                Icons.check,
                size: 22,
                color:
                    _editingFormula ? scheme.primary : scheme.onSurfaceVariant,
              ),
              onPressed: hasSelection && _editingFormula
                  ? () => _applyFormula(_formulaCtrl.text)
                  : null,
            ),
        ],
      ),
    );
  }

  static String get applyFormulaTooltip => tr('Применить');

  Widget _buildGrid(ColorScheme scheme) {
    if (_table.columns.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.table_chart, size: 56, color: scheme.outlineVariant),
            const SizedBox(height: 16),
            Text(
              tr('Нет столбцов'),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _addColumn,
              icon: const Icon(Icons.view_column_rounded, size: 18),
              label: Text(tr('Добавить столбец')),
            ),
          ],
        ),
      );
    }

    // Шапка живёт над вертикальной прокруткой, номера строк — слева от
    // горизонтальной: так заголовки не уезжают при листании, как в Excel.
    return Column(
      children: [
        Row(
          children: [
            _cornerCell(scheme),
            Expanded(
              child: SingleChildScrollView(
                controller: _hHeader,
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  children: [
                    for (var c = 0; c < _table.columns.length; c++)
                      _columnHeader(scheme, c),
                    _addColumnCell(scheme),
                  ],
                ),
              ),
            ),
          ],
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _rowNumWidth,
                child: SingleChildScrollView(
                  controller: _vRows,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      for (var r = 0; r < _table.rows.length; r++)
                        _rowNumberCell(scheme, r),
                      _addRowCell(scheme),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Scrollbar(
                  controller: _vScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _vScroll,
                    child: SingleChildScrollView(
                      controller: _hScroll,
                      scrollDirection: Axis.horizontal,
                      child: Column(
                        children: [
                          for (var r = 0; r < _table.rows.length; r++)
                            _dataRow(scheme, r),
                          const SizedBox(height: 72),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cornerCell(ColorScheme scheme) {
    final totalCells = _table.rows.length * _table.columns.length;
    return InkWell(
      onTap: widget.cellPickerMode ? null : _insertRowBelow,
      child: Container(
        height: _headerHeight,
        width: _rowNumWidth,
        alignment: Alignment.center,
        color: scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, size: 16, color: scheme.primary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                totalCells > 0
                    ? trf('{totalCells} яч.', {'totalCells': totalCells})
                    : '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addColumnCell(ColorScheme scheme) {
    return InkWell(
      onTap: widget.cellPickerMode ? null : _addColumn,
      child: Container(
        width: 52,
        height: _headerHeight,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(
            right: BorderSide(color: scheme.outlineVariant),
            bottom: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: Icon(Icons.add_rounded, size: 20, color: scheme.primary),
      ),
    );
  }

  Widget _addRowCell(ColorScheme scheme) {
    return InkWell(
      onTap: widget.cellPickerMode ? null : _insertRowBelow,
      child: Container(
        width: _rowNumWidth,
        height: _rowHeight,
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: scheme.outlineVariant),
            bottom: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: Icon(Icons.add_rounded, size: 20, color: scheme.primary),
      ),
    );
  }

  Widget _columnHeader(ColorScheme scheme, int col) {
    final isSelected = _selCol == col;
    final name = _table.columns[col];
    return InkWell(
      onTap: () {
        if (_table.rows.isNotEmpty) _selectCell(0, col, scrollIntoView: true);
      },
      onLongPress:
          widget.cellPickerMode ? null : () => _columnMenu(scheme, col),
      // ПК: меню колонки по правой кнопке, а не долгим тапом.
      onSecondaryTap:
          widget.cellPickerMode ? null : () => _columnMenu(scheme, col),
      child: Container(
        width: _colWidth,
        height: _headerHeight,
        padding: const EdgeInsets.only(left: 10, right: 2),
        decoration: BoxDecoration(
          color: isSelected
              ? scheme.primaryContainer.withValues(alpha: 0.55)
              : scheme.surfaceContainerHighest,
          border: Border(
            right: BorderSide(color: scheme.outlineVariant),
            bottom: BorderSide(
              color: isSelected ? scheme.primary : scheme.outlineVariant,
              width: isSelected ? 2 : 1,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            _tinyButton(
              tooltip: tr('Меню столбца'),
              icon: Icons.more_vert,
              color: scheme.onSurfaceVariant,
              onTap: () => _columnMenu(scheme, col),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _columnMenu(ColorScheme scheme, int col) async {
    if (widget.cellPickerMode) return;
    if (col < 0 || col >= _table.columns.length) return;
    _selectCell(_selRow ?? 0, col, scrollIntoView: false);
    final action = await showAdaptiveSheet<String>(
      context: context,
      scrollable: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  trf('Столбец «{p0}»', {'p0': _table.columns[col]}),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              dense: true,
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text(tr('Переименовать')),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.view_column_rounded),
              title: Text(tr('Вставить столбец справа')),
              onTap: () => Navigator.pop(ctx, 'insertRight'),
            ),
            ListTile(
              leading: const Icon(Icons.chevron_left),
              title: Text(tr('Переместить влево')),
              enabled: col > 0,
              onTap: () => Navigator.pop(ctx, 'left'),
            ),
            ListTile(
              leading: const Icon(Icons.chevron_right),
              title: Text(tr('Переместить вправо')),
              enabled: col < _table.columns.length - 1,
              onTap: () => Navigator.pop(ctx, 'right'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(
                tr('Удалить столбец'),
                style: TextStyle(color: scheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        await _renameColumn(col);
      case 'insertRight':
        await _insertColumnRight();
      case 'left':
        _moveColumn(col, -1);
      case 'right':
        _moveColumn(col, 1);
      case 'delete':
        _deleteColumn(col);
    }
  }

  Widget _dataRow(ColorScheme scheme, int r) {
    final rowIsSelected = _selRow == r;
    return Row(
      children: [
        for (var c = 0; c < _table.columns.length; c++)
          _dataCell(scheme, r, c, rowIsSelected),
      ],
    );
  }

  Widget _rowNumberCell(ColorScheme scheme, int r) {
    final isSelectedRow = _selRow == r;
    return Container(
      width: _rowNumWidth,
      height: _rowHeight,
      decoration: BoxDecoration(
        color: isSelectedRow
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : scheme.surfaceContainerHigh,
        border: Border(
          right: BorderSide(color: scheme.outlineVariant),
          bottom: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          InkWell(
            onTap: () => _selectRow(r),
            onLongPress:
                widget.cellPickerMode ? null : () => _rowMenu(r),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Text(
                '${r + 1}',
                style: TextStyle(
                  color: isSelectedRow
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: isSelectedRow
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
          if (!widget.cellPickerMode)
            _tinyButton(
              tooltip: tr('Меню строки'),
              icon: Icons.more_vert,
              color: scheme.onSurfaceVariant,
              onTap: () => _rowMenu(r),
            ),
        ],
      ),
    );
  }

  Widget _tinyButton({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: Icon(
            icon,
            size: 13,
            color: onTap == null ? color.withValues(alpha: 0.3) : color,
          ),
        ),
      ),
    );
  }

  Widget _dataCell(ColorScheme scheme, int r, int c, bool isSelectedRow) {
    final col = _table.columns[c];
    final raw = _table.rows[r][col];
    final nested = QuestTable.nestedFromValue(raw);
    final value = raw == null || nested != null ? '' : raw.toString();
    final isSelected = _selRow == r && _selCol == c;
    final isImage = nested == null && isImageResource(value);

    final Widget content;
    if (nested != null) {
      content = _nestedBadge(scheme, nested);
    } else if (isImage) {
      content = Row(
        children: [
          SizedBox(width: 40, height: 28, child: _thumbnail(value)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        ],
      );
    } else {
      content = Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.firaCode(color: scheme.onSurface, fontSize: 13),
      );
    }

    return SizedBox(
      width: _colWidth,
      height: _rowHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (widget.cellPickerMode) {
            Navigator.pop(context, _cellRef(r, c));
            return;
          }
          _gridFocus.requestFocus();
          _selectCell(r, c, scrollIntoView: false);
        },
        // ПК: двойной клик по обычной ячейке открывает редактор формулы —
        // иначе мышью в формулу не попасть. Вложенная таблица открывается
        // двойным кликом и на телефоне, и на ПК.
        onDoubleTap: widget.cellPickerMode
            ? null
            : () {
                _selectCell(r, c, scrollIntoView: false);
                if (nested != null) {
                  _openNestedEditor(r, c);
                } else if (isDesktopWidth(context)) {
                  _openFormulaEditor();
                }
              },
        onLongPress: widget.cellPickerMode
            ? null
            : () {
                _selectCell(r, c, scrollIntoView: false);
                _openCellMenu(r, c);
              },
        onSecondaryTap: widget.cellPickerMode
            ? null
            : () {
                _selectCell(r, c, scrollIntoView: false);
                _openCellMenu(r, c);
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.primaryContainer.withValues(alpha: 0.30)
                : (isSelectedRow ? scheme.surfaceContainerHigh : null),
            border: isSelected
                ? Border.all(color: scheme.primary, width: 2)
                : Border(
                    right: BorderSide(color: scheme.outlineVariant),
                    bottom: BorderSide(color: scheme.outlineVariant),
                  ),
          ),
          alignment: Alignment.centerLeft,
          child: content,
        ),
      ),
    );
  }

  /// Ячейка с подтаблицей: видно, что внутри сетка, и сколько в ней ячеек.
  Widget _nestedBadge(ColorScheme scheme, QuestTable nested) {
    return Tooltip(
      message: tr('Вложенная таблица'),
      child: Row(
        children: [
        Icon(Icons.grid_on_rounded, size: 18, color: scheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            trf('Таблица {p0}×{p1}', {
              'p0': nested.columns.length,
              'p1': nested.rows.length,
            }),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
          Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }

  Widget _buildStatusBar(ColorScheme scheme) {
    if (widget.cellPickerMode) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        color: scheme.primaryContainer.withValues(alpha: 0.4),
        child: Row(
          children: [
            Icon(Icons.touch_app, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr('Нажмите на ячейку, чтобы вставить ссылку на неё в текст'),
                style: TextStyle(color: scheme.onSurface, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    final statusText = <String>[
      '${_table.rows.length} строк',
      '${_table.columns.length} столбцов',
    ];
    final extras = <String>[];
    final allKeys = _table.rows.fold<Set<String>>({}, (acc, r) {
      acc.addAll(r.keys);
      return acc;
    });
    final strayKeys = allKeys.difference(_table.columns.toSet());
    if (strayKeys.isNotEmpty) {
      extras.add('лишние ключи: ${strayKeys.join(', ')}');
    }
    // Отдельно говорим про хранилище скриптов: без этой строки автор думает,
    // что блок «Данные» читает сетку.
    final dataHint = _table.data.isEmpty
        ? tr('ключей скриптов нет')
        : trf('ключей скриптов: {p0}', {'p0': _table.data.length});

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: scheme.surfaceContainerHigh,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: InkWell(
                onTap: _editDataKeys,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  child: Text(
                    [statusText.join(' · '), dataHint, ...extras].join(' · '),
                    maxLines: 1,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_selRow != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                trf('Выбрано: {p0}', {'p0': _cellAddress(_selRow!, _selCol)}),
                maxLines: 1,
                style: TextStyle(color: scheme.primary, fontSize: 12),
              ),
            ),
          IconButton(
            tooltip: tr('Как устроена таблица'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.help_outline_rounded, size: 18),
            onPressed: () =>
                showTableGuide(context, exampleTable: _table.name),
          ),
        ],
      ),
    );
  }
}

/// Пункт меню экспорта: формат и одна строка о том, что в него попадает.
class _ExportOption extends StatelessWidget {
  final String title;
  final String note;

  const _ExportOption({required this.title, required this.note});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title),
        Text(
          note,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontSize: 11,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}
