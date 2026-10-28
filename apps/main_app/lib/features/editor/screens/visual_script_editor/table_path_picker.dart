import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/data/table_guide.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

/// Срез таблицы так, как её видит блок «Данные»: движок работает только с
/// `data` (ключ → значение). Колонки и ряды сетки в `data` не попадают, и
/// именно на этом спотыкаются тестировщики: «удаляю значение из таблицы, а оно
/// остаётся». Поэтому пикер показывает ключи и честно говорит, если их нет.
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
  String get firstRowName => rowNames.firstWhere(
    (n) => n.trim().isNotEmpty,
    orElse: () => '',
  );

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

/// Выбор пути блока «Данные»: реальные ключи таблицы + ручной ввод +
/// редактор формул. Возвращает строку пути или `null`, если автор отменил.
Future<String?> pickTablePath(
  BuildContext context, {
  required String questId,
  required String tableName,
  required TableOperation operation,
  String initial = '',
}) {
  return Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => TablePathPickerScreen(
        questId: questId,
        tableName: tableName,
        operation: operation,
        initial: initial,
      ),
    ),
  );
}

class TablePathPickerScreen extends StatefulWidget {
  final String questId;
  final String tableName;
  final TableOperation operation;
  final String initial;

  const TablePathPickerScreen({
    super.key,
    required this.questId,
    required this.tableName,
    required this.operation,
    this.initial = '',
  });

  @override
  State<TablePathPickerScreen> createState() => _TablePathPickerScreenState();
}

class _TablePathPickerScreenState extends State<TablePathPickerScreen> {
  final TextEditingController _manual = TextEditingController();
  final TextEditingController _search = TextEditingController();
  TableDataSnapshot? _snapshot;
  bool _loaded = false;

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

  /// Ссылка на ячейку первой строки колонки — та же форма, что вставляет пикер
  /// ячейки в тексте. Сетка путём блока «Данные» не является, поэтому её не
  /// подставляем в поле пути, а даём скопировать.
  static String _gridRef(
    String table,
    String column, [
    String rowName = '',
  ]) {
    final col = escapeTableKey(column);
    final row = escapeTableKey(rowName.trim());
    if (row.isNotEmpty) return '{$table["$col"]["$row"]}';
    return '{$table["$col"][1]}';
  }

  Future<void> _copyGridRef(String ref) async {
    await Clipboard.setData(ClipboardData(text: ref));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(trf('Скопировано — вставьте в текст или формулу: {ref}', {'ref': ref})),
          duration: const Duration(seconds: 2),
        ),
      );
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

  List<MapEntry<String, dynamic>> _visibleKeys() {
    final query = _search.text.trim().toLowerCase();
    final entries = (_snapshot?.data ?? const <String, dynamic>{}).entries
        .where((e) => !e.key.startsWith('__'))
        .toList();
    if (query.isEmpty) return entries;
    return entries
        .where((e) => e.key.toLowerCase().contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keys = _visibleKeys();
    final snapshot = _snapshot;
    final op = widget.operation;

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
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trf('Путь — это имя, под которым блок «Данные» хранит значение внутри таблицы. Ряд и колонка сетки путём не считаются: их читают ссылкой вида {p0} в тексте и формулах.', {'p0': _gridRef(widget.tableName, 'колонка')}),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  Text(
                    op.description,
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
                text:
                    trf('В таблице {p0} рядов сетки, но блок «Данные» работает только с ключами хранилища. Запишите первый ключ операцией «Записать» — он появится здесь.', {'p0': snapshot.rowCount}),
              ),
            if (snapshot != null && snapshot.columns.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Сетка — это не путь. Вот так её ячейку читают из текста (номер строки менять самому, с 1):'),
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
                          final ref = _gridRef(
                            widget.tableName,
                            snapshot.columns[i],
                            snapshot.firstRowName,
                          );
                          return ActionChip(
                            onPressed: () => _copyGridRef(ref),
                            avatar: const Icon(
                              Icons.copy_rounded,
                              size: 14,
                            ),
                            label: Text(ref),
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
                  hintText: tr('Поиск ключа'),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : keys.isEmpty
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        snapshot != null && snapshot.hasKeys
                            ? trf('Ничего не найдено по запросу «{p0}».', {'p0': _search.text})
                            : trf('У хранилища «{p0}» пока нет ключей. Введите имя пути ниже — «Записать» создаст ключ, а «Получить» вернёт запасное значение.', {'p0': widget.tableName}),
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      itemCount: keys.length,
                      itemBuilder: (_, i) {
                        final entry = keys[i];
                        final described = TableDataSnapshot.describeValue(
                          entry.value,
                        );
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            entry.value is List
                                ? Icons.list_rounded
                                : entry.value is Map
                                ? Icons.account_tree_rounded
                                : Icons.label_outline_rounded,
                          ),
                          title: Text(entry.key),
                          subtitle: Text(described),
                          trailing: entry.value is List
                              ? IconButton(
                                  tooltip: tr('Путь к первому элементу'),
                                  icon: const Icon(Icons.skip_next_rounded),
                                  onPressed: () =>
                                      _choose('${entry.key}[0]'),
                                )
                              : null,
                          onTap: () => _choose(entry.key),
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

