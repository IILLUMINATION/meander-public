import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/data/table_guide.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:flutter/material.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

/// Срез таблицы так, как её видит блок «Данные»: ключи `data` (ключ →
/// значение) плюс сетка. У сетки путь — адрес ячейки (`["колонка"][1]` или
/// `["колонка"]["имя строки"]`), у хранилища — имя ключа. Показываем автору
/// оба вида, иначе он пишет в путь ссылку из текста и «Записать» молчит.
class TableDataSnapshot {
  final String name;
  final Map<String, dynamic> data;
  final List<String> columns;
  final List<String> rowNames;
  final int rowCount;

  const TableDataSnapshot({
    required this.name,
    required this.data,
    required this.columns,
    this.rowNames = const [],
    required this.rowCount,
  });

  /// Первое непустое имя строки — им можно адресовать ячейку вместо номера.
  String get firstRowName =>
      rowNames.firstWhere((n) => n.trim().isNotEmpty, orElse: () => '');

  bool get hasKeys => data.isNotEmpty;

  /// Есть ли хотя бы один список — только в них работает «Добавить» и
  /// «Удалить значение».
  bool get hasList => data.values.any((v) => v is List);

  /// Человекочитаемый тип значения для подсказки под ключом.
  static String describeValue(dynamic value) {
    if (value is List) return trf('список ({p0})', {'p0': value.length});
    if (value is Map) return trf('словарь ({p0})', {'p0': value.length});
    if (value is num) return tr('число');
    if (value is bool) return tr('да/нет');
    if (value == null) return tr('пусто');
    final s = value.toString();
    return s.length <= 24 ? s : '${s.substring(0, 21)}…';
  }
}

/// Прочитать таблицу квеста по имени. `null` — таблицы нет в конфиге.
Future<TableDataSnapshot?> loadTableDataSnapshot(
  String questId,
  String tableName,
) async {
  try {
    final configPath = QuestPaths.config(questId);
    if (!await FileStorage.exists(configPath)) return null;
    final config = await FileStorage.readJsonFile(configPath);
    for (final raw in config['tables'] as List<dynamic>? ?? const []) {
      if (raw is! Map) continue;
      final table = QuestTable.fromJson(Map<String, dynamic>.from(raw));
      if (table.name != tableName) continue;
      return TableDataSnapshot(
        name: table.name,
        data: table.data,
        columns: table.columns,
        rowNames: table.rowNames,
        rowCount: table.rows.length,
      );
    }
  } catch (_) {
    // Конфиг может быть пустым или битым — пикер тогда просто без ключей.
  }
  return null;
}

/// Безопасный сегмент пути можно писать без кавычек: `gold`, `items`.
/// Точка и скобки меняют разбор, поэтому такие имена всегда в кавычках.
bool _isBarePathKey(String key) =>
    key.isNotEmpty &&
    !key.contains('.') &&
    !key.contains('[') &&
    !key.contains(']') &&
    !key.contains('"') &&
    !key.contains("'") &&
    !key.contains(' ') &&
    !key.contains('\t') &&
    !key.contains('\n');

/// Путь по вложенным ключам и индексам: `gold`, `gold["sub"]`, `items[0]`.
String tablePathOf(List<Object> path) {
  final buffer = StringBuffer();
  for (var i = 0; i < path.length; i++) {
    final segment = path[i];
    if (segment is int) {
      buffer.write('[$segment]');
      continue;
    }
    final key = '$segment';
    if (i == 0 && _isBarePathKey(key)) {
      buffer.write(key);
    } else {
      buffer.write('["${escapeTableKey(key)}"]');
    }
  }
  return buffer.toString();
}

/// Ссылка для текста и формул: `{таблица["ключ"]["вложенный"]}`.
/// Путь из пикера — уже готовая часть после имени таблицы.
String tableTextReference(String tableName, String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '{$tableName}';
  if (trimmed.startsWith('[')) return '{$tableName$trimmed}';
  final bracket = trimmed.indexOf('[');
  final head = bracket < 0 ? trimmed : trimmed.substring(0, bracket);
  final rest = bracket < 0 ? '' : trimmed.substring(bracket);
  return '{$tableName["${escapeTableKey(head)}"]$rest}';
}

/// Выбор пути блока «Данные»: реальные ключи таблицы + ручной ввод +
/// редактор формул. Возвращает строку пути или `null`, если автор отменил.
Future<String?> pickTablePath(
  BuildContext context, {
  required String questId,
  required String tableName,
  required TableOperation operation,
  String initial = '',
  String? description,
}) {
  return Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => TablePathPickerScreen(
        questId: questId,
        tableName: tableName,
        operation: operation,
        initial: initial,
        description: description,
      ),
    ),
  );
}

/// Пикер ключа для вставки в текст: возвращает готовую ссылку
/// `{таблица["ключ"]["вложенный"]}`, а не сырой путь блока «Данные».
Future<String?> pickTableKeyReference(
  BuildContext context, {
  required String questId,
  required String tableName,
  String initial = '',
}) async {
  final path = await pickTablePath(
    context,
    questId: questId,
    tableName: tableName,
    operation: TableOperation.get,
    initial: initial,
    description: tr(
      'Выберите ключ или вложенный путь — в текст вставится ссылка вида {таблица["ключ"]}.',
    ),
  );
  if (path == null) return null;
  return tableTextReference(tableName, path);
}

class TablePathPickerScreen extends StatefulWidget {
  final String questId;
  final String tableName;
  final TableOperation operation;
  final String initial;
  final String? description;

  const TablePathPickerScreen({
    super.key,
    required this.questId,
    required this.tableName,
    required this.operation,
    this.initial = '',
    this.description,
  });

  @override
  State<TablePathPickerScreen> createState() => _TablePathPickerScreenState();
}

class _TablePathPickerScreenState extends State<TablePathPickerScreen> {
  final TextEditingController _manual = TextEditingController();
  final TextEditingController _search = TextEditingController();
  TableDataSnapshot? _snapshot;
  bool _loaded = false;

  /// Текущий уровень дерева: имена ключей (`String`) и индексы списков (`int`).
  final List<Object> _path = [];

  @override
  void initState() {
    super.initState();
    _manual.text = widget.initial;
    _load();
  }

  @override
  void dispose() {
    _manual.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final snapshot = await loadTableDataSnapshot(
      widget.questId,
      widget.tableName,
    );
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loaded = true;
    });
  }

  void _choose(String path) => Navigator.pop(context, path);

  /// Адрес ячейки для поля «Путь» — номер строки с 1 или точное имя строки.
  static String _gridPath(String column, [String rowName = '']) {
    final col = escapeTableKey(column);
    final row = escapeTableKey(rowName.trim());
    if (row.isNotEmpty) return '["$col"]["$row"]';
    return '["$col"][1]';
  }

  /// Ссылка на ячейку так, как её пишут в тексте и формулах.
  static String _gridRef(String table, String column, [String rowName = '']) {
    return '{$table${_gridPath(column, rowName)}}';
  }

  Future<void> _openFormulaEditor() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ExpressionEditorScreen(
          initialValue: _manual.text,
          questId: widget.questId,
        ),
      ),
    );
    if (result != null && mounted) _manual.text = result;
  }

  dynamic _valueAtPath(List<Object> path) {
    dynamic current = _snapshot?.data;
    for (final segment in path) {
      if (current is Map) {
        current = current[segment];
      } else if (current is List && segment is int) {
        if (segment < 0 || segment >= current.length) return null;
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  List<MapEntry<Object, dynamic>> _entriesAtCurrent() {
    final current = _valueAtPath(_path);
    final entries = <MapEntry<Object, dynamic>>[];
    if (current is Map) {
      for (final entry in current.entries) {
        final key = entry.key.toString();
        if (_path.isEmpty && key.startsWith('__')) continue;
        entries.add(MapEntry<Object, dynamic>(key, entry.value));
      }
    } else if (current is List) {
      for (var i = 0; i < current.length; i++) {
        entries.add(MapEntry<Object, dynamic>(i, current[i]));
      }
    }
    entries.sort((a, b) => '${a.key}'.compareTo('${b.key}'));
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return entries;
    return entries
        .where((e) => '${e.key}'.toLowerCase().contains(query))
        .toList();
  }

  void _drill(Object segment) {
    setState(() {
      _path.add(segment);
      _search.clear();
    });
  }

  void _goToLevel(int length) {
    setState(() {
      _path.removeRange(length, _path.length);
      _search.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entriesAtCurrent();
    final snapshot = _snapshot;
    final op = widget.operation;
    final currentPath = tablePathOf(_path);
    final atRoot = _path.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(trf('Путь в «{p0}»', {'p0': widget.tableName})),
        actions: [
          IconButton(
            tooltip: tr('Как устроена таблица'),
            onPressed: () =>
                showTableGuide(context, exampleTable: widget.tableName),
            icon: const Icon(Icons.help_outline_rounded),
          ),
          IconButton(
            tooltip: tr('Открыть редактор формул'),
            onPressed: _openFormulaEditor,
            icon: const Icon(Icons.calculate_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trf(
                      'Путь — имя ключа хранилища («gold») или адрес ячейки сетки: колонка и строка, строка — с 1 или по имени. В тексте та же ячейка пишется как {p0}.',
                      {'p0': _gridRef(widget.tableName, 'колонка')},
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  Text(
                    tr(
                      'Вложенные ключи и элементы списков — это тоже путь: gold["sub"], items[0]. Кнопка › раскрывает уровень, тап по строке выбирает его целиком.',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    widget.description ?? op.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (snapshot != null && !snapshot.hasKeys && snapshot.rowCount > 0)
              _InfoCard(
                icon: Icons.grid_on_rounded,
                text: trf(
                  'В таблице {p0} рядов сетки и ещё нет ключей хранилища. Ячейку выбирайте адресом из списка ниже, а ключ создаст операция «Записать».',
                  {'p0': snapshot.rowCount},
                ),
              ),
            if (!atRoot)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          ActionChip(
                            label: Text(widget.tableName),
                            onPressed: () => _goToLevel(0),
                          ),
                          for (var i = 0; i < _path.length; i++)
                            ActionChip(
                              label: Text('${_path[i]}'),
                              onPressed: () => _goToLevel(i + 1),
                            ),
                        ],
                      ),
                    ),
                    if (_path.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => _choose(currentPath),
                        icon: const Icon(Icons.check_rounded, size: 16),
                        label: Text(tr('Выбрать путь')),
                      ),
                  ],
                ),
              ),
            if (snapshot != null && snapshot.columns.isNotEmpty && atRoot)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(
                        'Ячейка сетки: номер строки — с 1, имя — если оно задано. Нажмите, чтобы подставить путь.',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: snapshot.columns.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemBuilder: (_, i) {
                          final column = snapshot.columns[i];
                          final path = _gridPath(column, snapshot.firstRowName);
                          return ActionChip(
                            onPressed: () => _choose(path),
                            avatar: const Icon(Icons.grid_on_rounded, size: 14),
                            label: Text(path),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: atRoot ? tr('Поиск ключа') : tr('Поиск на уровне'),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 300,
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : entries.isEmpty
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _search.text.trim().isNotEmpty
                            ? trf('Ничего не найдено по запросу «{p0}».', {
                                'p0': _search.text,
                              })
                            : atRoot
                            ? trf(
                                'У хранилища «{p0}» пока нет ключей. Введите имя пути ниже — «Записать» создаст ключ; ячейка сетки адресуется через ["колонка"][1].',
                                {'p0': widget.tableName},
                              )
                            : tr('На этом уровне пусто.'),
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (_, i) {
                        final entry = entries[i];
                        final value = entry.value;
                        final isContainer = value is Map || value is List;
                        final nextPath = tablePathOf([..._path, entry.key]);
                        final described = TableDataSnapshot.describeValue(
                          value,
                        );
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            value is List
                                ? Icons.list_rounded
                                : value is Map
                                ? Icons.account_tree_rounded
                                : Icons.label_outline_rounded,
                          ),
                          title: Text(
                            entry.key is int
                                ? '[${entry.key}]'
                                : '${entry.key}',
                          ),
                          subtitle: Text(
                            currentPath.isEmpty
                                ? described
                                : '$nextPath · $described',
                          ),
                          trailing: isContainer
                              ? IconButton(
                                  tooltip: tr('Открыть вложенные'),
                                  icon: const Icon(Icons.chevron_right_rounded),
                                  onPressed: () => _drill(entry.key),
                                )
                              : null,
                          onTap: () => _choose(nextPath),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manual,
                      onSubmitted: (v) => _choose(v),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: tr('Путь вручную'),
                        helperText: op.hintFor('path'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _choose(_manual.text),
                    child: Text(tr('Выбрать')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoCard({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
