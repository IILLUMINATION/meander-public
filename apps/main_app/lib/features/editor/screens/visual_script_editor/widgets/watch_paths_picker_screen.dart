import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/table_path_picker.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

/// Путь ячейки в форме движка: `<таблица>.<колонка>.<ряд>`, ряды с 1.
String watchPathForCell(String table, String column, int row) =>
    '$table.$column.$row';

/// Полноэкранный выбор путей события «При изменении данных».
///
/// Старый шит добавлял по одному пути за тап и не показывал ряды сетки:
/// отметить десяток переменных или конкретную ячейку было мучением. Здесь
/// каждый путь — чекбокс: переменные отмечаются пачкой, у таблицы можно взять
/// целиком, ключ хранилища, колонку или отдельную ячейку.
class WatchPathsPickerScreen extends StatefulWidget {
  final String questId;
  final List<String> initial;

  const WatchPathsPickerScreen({
    super.key,
    required this.questId,
    this.initial = const [],
  });

  @override
  State<WatchPathsPickerScreen> createState() => _WatchPathsPickerScreenState();
}

class _WatchPathsPickerScreenState extends State<WatchPathsPickerScreen> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _manual = TextEditingController();
  final Set<String> _selected = <String>{};
  final List<_WatchVariable> _variables = [];
  final List<_WatchTable> _tables = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    for (final path in widget.initial) {
      final trimmed = path.trim();
      // `*` — старое представление «любое изменение»; пустой набор означает
      // то же самое и не занимает место в списке путей.
      if (trimmed.isEmpty || trimmed == '*') continue;
      _selected.add(trimmed);
    }
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final configPath = QuestPaths.config(widget.questId);
      if (await FileStorage.exists(configPath)) {
        final config = await FileStorage.readJsonFile(configPath);
        final seen = <String>{};
        for (final raw
            in config['variables'] as List<dynamic>? ?? const <dynamic>[]) {
          if (raw is! Map) continue;
          final name = '${raw['name'] ?? ''}'.trim();
          // `_…` — служебные переменные движка, их изменений он не отдаёт.
          if (name.isEmpty || name.startsWith('_') || !seen.add(name)) continue;
          _variables.add(
            _WatchVariable(
              name,
              trf('переменная, значение: {p0}', {
                'p0': TableDataSnapshot.describeValue(raw['defaultValue']),
              }),
            ),
          );
        }
        for (final raw
            in config['tables'] as List<dynamic>? ?? const <dynamic>[]) {
          if (raw is! Map) continue;
          final table = QuestTable.fromJson(Map<String, dynamic>.from(raw));
          _tables.add(
            _WatchTable(
              name: table.name,
              dataKeys: table.data.entries
                  .where((e) => !e.key.startsWith('__'))
                  .toList(),
              columns: table.columns,
              rowCount: table.rows.length,
            ),
          );
        }
      }
    } catch (_) {
      // Битый конфиг — остаётся ручной ввод.
    }
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  void _toggle(String path, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(path);
      } else {
        _selected.remove(path);
      }
    });
  }

  void _selectAllVariables() {
    setState(() => _selected.addAll(_variables.map((v) => v.name)));
  }

  void _clearSelection() => setState(_selected.clear);

  String _tablePath(_WatchTable table) => '${table.name}.*';
  String _columnPath(_WatchTable table, String column) =>
      '${table.name}.$column';
  String _cellPath(_WatchTable table, String column, int row) =>
      watchPathForCell(table.name, column, row);

  Future<void> _addManual() async {
    // Контроллер живёт вместе с экраном: диалог доигрывает анимацию закрытия
    // уже после `await`, и dispose() сразу после него роняет TextField.
    _manual.clear();
    final result = await showAppDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Добавить путь')),
        content: TextField(
          controller: _manual,
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr('Здоровье, лавка.цена, лавка.цена.3, *'),
            helperText:
                tr('Несколько путей — через запятую. Таблицу можно писать и с префиксом: table.лавка.цена.'),
          ),
          onSubmitted: (value) => Navigator.pop(
            ctx,
            value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              _manual.text
                  .split(',')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList(),
            ),
            child: Text(tr('Добавить')),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    setState(() {
      for (final path in result) {
        if (path == '*') {
          _selected.clear();
        } else {
          _selected.add(path);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = _search.text.trim().toLowerCase();

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(
          tr('Следить за изменениями'),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: _clearSelection,
              child: Text(tr('Снять выбор')),
            ),
        ],
      ),
      body: AdaptiveContent(
        maxWidth: 860,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Сразу несколько путей: переменная, ключ таблицы, ячейка сетки или * за всем сразу. Пустой список — событие срабатывает на любое изменение.'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: tr('Очистить'),
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _search.clear();
                                  setState(() {});
                                },
                              ),
                        hintText: tr('Поиск по путям'),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: !_loaded
                    ? const Center(child: CircularProgressIndicator())
                    : query.isEmpty
                    ? _buildGroups()
                    : _buildSearchResults(query),
              ),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, {Widget? trailing}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _buildGroups() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final noData = _variables.isEmpty && _tables.isEmpty;

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        CheckboxListTile(
          value: _selected.isEmpty,
          onChanged: (_) => _clearSelection(),
          secondary: Icon(
            Icons.change_circle_rounded,
            color: _selected.isEmpty ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: Text(
            tr('Любое изменение'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            tr('Пока не выбран ни один путь, событие срабатывает на любое изменение в квесте.'),
          ),
        ),
        const Divider(height: 1),
        if (noData)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tr('В квесте пока нет ни переменных, ни таблиц — впишите путь вручную.'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        if (_variables.isNotEmpty) ...[
          _sectionTitle(
            tr('Переменные'),
            trailing: TextButton(
              onPressed: _selectAllVariables,
              child: Text(tr('Выбрать все')),
            ),
          ),
          for (final variable in _variables)
            CheckboxListTile(
              dense: true,
              value: _selected.contains(variable.name),
              onChanged: (value) => _toggle(variable.name, value),
              title: Text(variable.name),
              subtitle: Text(variable.detail),
            ),
        ],
        if (_tables.isNotEmpty) ...[
          _sectionTitle(tr('Таблицы')),
          for (final table in _tables) _buildTable(table),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: OutlinedButton.icon(
            onPressed: _addManual,
            icon: const Icon(Icons.edit_rounded),
            label: Text(tr('Добавить путь')),
          ),
        ),
      ],
    );
  }

  Widget _buildTable(_WatchTable table) {
    // Ключ данных и столбец сетки могут называться одинаково: путь у них
    // один и тот же. Такой ключ показываем строкой столбца — иначе ячейки
    // сетки остались бы без своего раздела.
    final dataKeyTiles = <Widget>[];
    for (final entry in table.dataKeys) {
      if (table.columns.contains(entry.key)) continue;
      final path = '${table.name}.${entry.key}';
      dataKeyTiles.add(
        CheckboxListTile(
          dense: true,
          value: _selected.contains(path),
          onChanged: (value) => _toggle(path, value),
          title: Text(entry.key),
          subtitle: Text(
            '$path · ${TableDataSnapshot.describeValue(entry.value)}',
            style: const TextStyle(fontSize: 11),
          ),
        ),
      );
    }

    final columnTiles = <Widget>[];
    for (final column in table.columns.toSet()) {
      final path = _columnPath(table, column);
      if (table.rowCount == 0) {
        columnTiles.add(
          CheckboxListTile(
            dense: true,
            value: _selected.contains(path),
            onChanged: (value) => _toggle(path, value),
            title: Text(column),
            subtitle: Text(path, style: const TextStyle(fontSize: 11)),
          ),
        );
        continue;
      }
      columnTiles.add(
        ExpansionTile(
          leading: Checkbox(
            value: _selected.contains(path),
            onChanged: (value) => _toggle(path, value),
          ),
          title: Text(column),
          subtitle: Text(path, style: const TextStyle(fontSize: 11)),
          childrenPadding: const EdgeInsets.only(left: 16),
          children: [
            for (var row = 1; row <= table.rowCount; row++)
              CheckboxListTile(
                dense: true,
                value: _selected.contains(_cellPath(table, column, row)),
                onChanged: (value) =>
                    _toggle(_cellPath(table, column, row), value),
                title: Text(trf('Строка {p0}', {'p0': row})),
                subtitle: Text(
                  _cellPath(table, column, row),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
      );
    }

    return ExpansionTile(
      leading: Checkbox(
        value: _selected.contains(_tablePath(table)),
        onChanged: (value) => _toggle(_tablePath(table), value),
      ),
      title: Text(
        table.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        _tablePath(table),
        style: const TextStyle(fontSize: 11),
      ),
      childrenPadding: const EdgeInsets.only(left: 16),
      children: [
        ...dataKeyTiles,
        if (dataKeyTiles.isEmpty && columnTiles.isEmpty)
          ListTile(
            dense: true,
            title: Text(
              tr('В таблице нет ключей и колонок'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ...columnTiles,
      ],
    );
  }

  /// Плоский список для поиска: те же пути, что и в группах, но без
  /// раскрывающихся таблиц — иначе совпадение в свёрнутой колонке не видно.
  List<_WatchOption> _searchOptions(String query) {
    final result = <_WatchOption>[];
    final seen = <String>{};
    void add(_WatchOption option) {
      if (!seen.add(option.path)) return;
      if (option.path.toLowerCase().contains(query)) result.add(option);
    }

    for (final variable in _variables) {
      add(_WatchOption(variable.name, variable.detail));
    }
    for (final table in _tables) {
      add(_WatchOption(_tablePath(table), tr('Вся таблица')));
      for (final entry in table.dataKeys) {
        add(
          _WatchOption(
            '${table.name}.${entry.key}',
            trf('ключ таблицы: {p0}', {
              'p0': TableDataSnapshot.describeValue(entry.value),
            }),
          ),
        );
      }
      for (final column in table.columns) {
        add(_WatchOption(_columnPath(table, column), tr('Вся колонка')));
        for (var row = 1; row <= table.rowCount; row++) {
          add(
            _WatchOption(
              _cellPath(table, column, row),
              trf('Строка {p0}', {'p0': row}),
            ),
          );
        }
      }
    }
    return result;
  }

  Widget _buildSearchResults(String query) {
    final options = _searchOptions(query);
    if (options.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          trf('Ничего не найдено по запросу «{p0}».', {'p0': _search.text}),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: options.length,
      itemBuilder: (_, i) {
        final option = options[i];
        return CheckboxListTile(
          dense: true,
          value: _selected.contains(option.path),
          onChanged: (value) => _toggle(option.path, value),
          title: Text(option.path, overflow: TextOverflow.ellipsis),
          subtitle: Text(option.detail),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Отмена')),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: () => Navigator.pop(context, _selected.toList()),
              icon: const Icon(Icons.check_rounded),
              label: Text(
                _selected.isEmpty
                    ? tr('Готово')
                    : trf('Выбрано: {p0}', {'p0': _selected.length}),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WatchVariable {
  final String name;
  final String detail;

  const _WatchVariable(this.name, this.detail);
}

class _WatchTable {
  final String name;
  final List<MapEntry<String, dynamic>> dataKeys;
  final List<String> columns;
  final int rowCount;

  const _WatchTable({
    required this.name,
    required this.dataKeys,
    required this.columns,
    required this.rowCount,
  });
}

class _WatchOption {
  final String path;
  final String detail;

  const _WatchOption(this.path, this.detail);
}
