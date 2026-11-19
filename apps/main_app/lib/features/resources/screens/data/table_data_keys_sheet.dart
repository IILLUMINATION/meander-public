import 'dart:convert';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/table_path_picker.dart';
import 'package:canvas_app/features/resources/screens/data/table_guide.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';

/// Ключи хранилища скриптов (`data`) — то, с чем работает блок «Данные» и что
/// читают формулы вида `таблица['ключ']`. Сетка (строки/столбцы) сюда не
/// попадает, и раньше эти ключи было вообще негде посмотреть: отсюда вопрос
/// тестера «как удалять значения из таблицы?».
///
/// Возвращает новую карту ключей, если автор применил правки, — иначе `null`.
Future<Map<String, dynamic>?> showTableDataKeysSheet(
  BuildContext context, {
  required QuestTable table,
}) {
  return showAdaptiveSheet<Map<String, dynamic>>(
    context: context,
    title: trf('Ключи скриптов · {p0}', {'p0': table.name}),
    maxWidth: 480,
    isScrollControlled: true,
    builder: (context) => _TableDataKeysSheet(table: table),
  );
}

/// Разбор текста значения: числа, булевы, списки и словари уходят в JSON, всё
/// остальное остаётся строкой. Такого же поведения ждут скрипты.
dynamic parseTableDataValue(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  try {
    return jsonDecode(text);
  } catch (_) {
    return raw;
  }
}

/// Глубокая копия данных: правки вложенных ключей не должны менять таблицу
/// до нажатия «Применить».
dynamic _deepCopyValue(dynamic value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': _deepCopyValue(entry.value),
    };
  }
  if (value is List) return value.map(_deepCopyValue).toList();
  return value;
}

class _DataNode {
  final List<Object> path;
  final dynamic value;

  const _DataNode({required this.path, required this.value});

  String get label => path.isEmpty ? '' : '${path.last}';
}

class _TableDataKeysSheet extends StatefulWidget {
  final QuestTable table;

  const _TableDataKeysSheet({required this.table});

  @override
  State<_TableDataKeysSheet> createState() => _TableDataKeysSheetState();
}

class _TableDataKeysSheetState extends State<_TableDataKeysSheet> {
  late final Map<String, dynamic> _data =
      _deepCopyValue(widget.table.data) as Map<String, dynamic>;
  final TextEditingController _search = TextEditingController();
  final Set<String> _expanded = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  dynamic _resolve(List<Object> path) {
    dynamic current = _data;
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

  void _removeAt(List<Object> path) {
    if (path.isEmpty) return;
    final parent = _resolve(path.sublist(0, path.length - 1));
    final last = path.last;
    setState(() {
      if (parent is Map) {
        parent.remove('$last');
      } else if (parent is List && last is int) {
        if (last >= 0 && last < parent.length) parent.removeAt(last);
      }
      _expanded.removeWhere((key) => key == tablePathOf(path));
    });
  }

  void _appendRows(
    List<Widget> rows,
    dynamic container,
    List<Object> path,
    int depth,
  ) {
    if (container is! Map && container is! List) return;
    final nodes = <_DataNode>[];
    if (container is Map) {
      for (final entry in container.entries) {
        final key = '${entry.key}';
        if (path.isEmpty && key.startsWith('__')) continue;
        nodes.add(_DataNode(path: [...path, key], value: entry.value));
      }
    } else {
      for (var i = 0; i < container.length; i++) {
        nodes.add(_DataNode(path: [...path, i], value: container[i]));
      }
    }
    nodes.sort((a, b) => a.label.compareTo(b.label));

    for (final node in nodes) {
      final value = node.value;
      final canExpand = value is Map || value is List;
      final nodePath = tablePathOf(node.path);
      final isExpanded = _expanded.contains(nodePath);
      rows.add(
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 12 + depth * 16.0, right: 4),
          leading: Icon(
            value is List
                ? Icons.list_rounded
                : value is Map
                ? Icons.account_tree_rounded
                : Icons.label_outline_rounded,
          ),
          title: Text(node.label),
          subtitle: Text(
            depth == 0
                ? TableDataSnapshot.describeValue(value)
                : '$nodePath · ${TableDataSnapshot.describeValue(value)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value is Map)
                _ActionIcon(
                  tooltip: tr('Добавить вложенный ключ'),
                  icon: Icons.add_rounded,
                  onPressed: () => _addMapChild(node.path),
                ),
              if (value is List)
                _ActionIcon(
                  tooltip: tr('Добавить элемент'),
                  icon: Icons.playlist_add_rounded,
                  onPressed: () => _addListItem(node.path),
                ),
              if (canExpand)
                _ActionIcon(
                  tooltip: isExpanded ? tr('Свернуть') : tr('Развернуть'),
                  icon: isExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  onPressed: () => setState(() {
                    if (isExpanded) {
                      _expanded.remove(nodePath);
                    } else {
                      _expanded.add(nodePath);
                    }
                  }),
                ),
              _ActionIcon(
                tooltip: tr('Изменить'),
                icon: Icons.edit_outlined,
                onPressed: () => _editAtPath(node.path),
              ),
              _ActionIcon(
                tooltip: tr('Удалить ключ'),
                icon: Icons.delete_outline,
                color: Theme.of(
                  context,
                ).colorScheme.error.withValues(alpha: 0.9),
                onPressed: () => _removeAt(node.path),
              ),
            ],
          ),
          onTap: () => _editAtPath(node.path),
        ),
      );
      if (canExpand && isExpanded) {
        _appendRows(rows, value, node.path, depth + 1);
      }
    }
  }

  List<_DataNode> _flatNodes(dynamic container, List<Object> path) {
    final out = <_DataNode>[];
    if (container is Map) {
      for (final entry in container.entries) {
        final key = '${entry.key}';
        if (path.isEmpty && key.startsWith('__')) continue;
        final nodePath = [...path, key];
        out.add(_DataNode(path: nodePath, value: entry.value));
        out.addAll(_flatNodes(entry.value, nodePath));
      }
    } else if (container is List) {
      for (var i = 0; i < container.length; i++) {
        final nodePath = [...path, i];
        out.add(_DataNode(path: nodePath, value: container[i]));
        out.addAll(_flatNodes(container[i], nodePath));
      }
    }
    return out;
  }

  List<_DataNode> _visibleNodes() {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return _flatNodes(
      _data,
      const [],
    ).where((node) => node.label.toLowerCase().contains(query)).toList();
  }

  Future<void> _editAtPath(List<Object> path) async {
    final existing = path.last is String ? '${path.last}' : null;
    final edit = await showAppDialog<_KeyEdit>(
      context: context,
      builder: (ctx) => _KeyEditDialog(
        existing: existing,
        current: _resolve(path),
        nameEnabled: existing != null,
      ),
    );
    if (edit == null || !mounted) return;
    if (existing != null && edit.name.isEmpty) return;
    if (existing != null &&
        edit.name.startsWith('__') &&
        !existing.startsWith('__')) {
      _snack(tr('Имена с «__» служебные: движок не сохранит такой ключ.'));
      return;
    }
    final parentPath = path.sublist(0, path.length - 1);
    final parent = _resolve(parentPath);
    if (parent is Map && existing != null) {
      if (existing != edit.name && parent.containsKey(edit.name)) {
        _snack(trf('Ключ «{p0}» уже есть', {'p0': edit.name}));
        return;
      }
      setState(() {
        if (existing != edit.name) parent.remove(existing);
        parent[edit.name] = edit.value;
      });
      return;
    }
    if (parent is List && path.last is int) {
      final index = path.last as int;
      if (index < 0 || index >= parent.length) return;
      setState(() => parent[index] = edit.value);
      return;
    }
    if (path.isEmpty) {
      setState(() => _data[edit.name] = edit.value);
    }
  }

  Future<void> _addMapChild(List<Object> parentPath) async {
    final parent = _resolve(parentPath);
    if (parent is! Map) return;
    final edit = await showAppDialog<_KeyEdit>(
      context: context,
      builder: (ctx) => _KeyEditDialog(existing: null, current: null),
    );
    if (edit == null || edit.name.isEmpty || !mounted) return;
    if (edit.name.startsWith('__')) {
      _snack(tr('Имена с «__» служебные: движок не сохранит такой ключ.'));
      return;
    }
    if (parent.containsKey(edit.name)) {
      _snack(trf('Ключ «{p0}» уже есть', {'p0': edit.name}));
      return;
    }
    setState(() {
      parent[edit.name] = edit.value;
      _expanded.add(tablePathOf(parentPath));
    });
  }

  Future<void> _addListItem(List<Object> path) async {
    final parent = _resolve(path);
    if (parent is! List) return;
    final edit = await showAppDialog<_KeyEdit>(
      context: context,
      builder: (ctx) =>
          _KeyEditDialog(existing: null, current: null, nameEnabled: false),
    );
    if (edit == null || !mounted) return;
    setState(() {
      parent.add(edit.value);
      _expanded.add(tablePathOf(path));
    });
  }

  Future<void> _addRootKey() async {
    final edit = await showAppDialog<_KeyEdit>(
      context: context,
      builder: (ctx) => _KeyEditDialog(existing: null, current: null),
    );
    if (edit == null || edit.name.isEmpty || !mounted) return;
    if (edit.name.startsWith('__')) {
      _snack(tr('Имена с «__» служебные: движок не сохранит такой ключ.'));
      return;
    }
    if (_data.containsKey(edit.name)) {
      _snack(trf('Ключ «{p0}» уже есть', {'p0': edit.name}));
      return;
    }
    setState(() => _data[edit.name] = edit.value);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = _search.text.trim();
    final matches = _visibleNodes();

    final rows = <Widget>[];
    if (query.isEmpty) {
      _appendRows(rows, _data, const [], 0);
    } else {
      for (final node in matches) {
        rows.add(
          ListTile(
            dense: true,
            leading: const Icon(Icons.search_rounded),
            title: Text(node.label),
            subtitle: Text(
              tablePathOf(node.path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _editAtPath(node.path),
          ),
        );
      }
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TableHintBanner(
              text: tr(
                'Блок «Данные» и формулы видят только эти ключи. Строки и столбцы сетки — отдельно.',
              ),
              detailsLabel: tr('Как устроена таблица'),
              onDetails: () =>
                  showTableGuide(context, exampleTable: widget.table.name),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              tr(
                'Ключи можно вкладывать друг в друга и в списки. Путь пишется как ["персонаж"]["инвентарь"][0]; раскройте ›, чтобы увидеть вложенные.',
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
          if (_data.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                tr(
                  'Хранилище пусто: скриптам тут читать нечего. Добавьте первый ключ здесь или операцией «Записать» в блоке «Данные».',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_data.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: tr('Поиск ключа'),
                ),
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: Text(
                      query.isEmpty
                          ? tr('Ключей пока нет.')
                          : trf('Ничего не найдено по запросу «{p0}».', {
                              'p0': query,
                            }),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView(children: rows),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _addRootKey,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(tr('Добавить ключ')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('Отмена')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _data),
                  child: Text(tr('Применить')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;

  const _ActionIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18, color: color),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 36),
      onPressed: onPressed,
    );
  }
}

class _KeyEdit {
  final String name;
  final dynamic value;

  const _KeyEdit({required this.name, required this.value});
}

/// Диалог одного ключа. Контроллеры живут здесь, а не в вызывающем коде:
/// правки применяет лист, который переживает закрытие диалога, а текстовые
/// поля перестраиваются на уходе анимации.
class _KeyEditDialog extends StatefulWidget {
  final String? existing;
  final dynamic current;
  final bool nameEnabled;

  const _KeyEditDialog({
    required this.existing,
    required this.current,
    this.nameEnabled = true,
  });

  @override
  State<_KeyEditDialog> createState() => _KeyEditDialogState();
}

class _KeyEditDialogState extends State<_KeyEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing ?? '',
  );
  late final TextEditingController _value = TextEditingController(
    text: _asEditableText(widget.current),
  );

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(
      context,
      _KeyEdit(
        name: _name.text.trim(),
        value: parseTableDataValue(_value.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        !widget.nameEnabled
            ? tr('Элемент списка')
            : widget.existing == null
            ? tr('Новый ключ')
            : trf('Ключ «{p0}»', {'p0': widget.existing}),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.nameEnabled)
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              decoration: InputDecoration(
                isDense: true,
                labelText: tr('Имя ключа'),
                helperText: tr('как его видит скрипт: gold, opened, items'),
              ),
            ),
          if (widget.nameEnabled) const SizedBox(height: 12),
          TextField(
            controller: _value,
            maxLines: 4,
            decoration: InputDecoration(
              isDense: true,
              labelText: tr('Значение'),
              helperText: tr(
                'текст как есть; числа, true/false, списки [1, 2] и словари {"a": 1} понятны',
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Отмена')),
        ),
        FilledButton(onPressed: _save, child: Text(tr('Сохранить'))),
      ],
    );
  }
}

/// Как показать значение в поле ввода: структуры — JSON'ом, скаляры — как есть.
String _asEditableText(dynamic value) {
  if (value is Map || value is List) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }
  if (value == null) return '';
  return value.toString();
}
