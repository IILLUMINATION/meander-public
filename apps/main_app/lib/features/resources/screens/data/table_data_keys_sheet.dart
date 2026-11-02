import 'dart:convert';

import 'package:canvas_app/features/editor/screens/visual_script_editor/table_path_picker.dart';
import 'package:canvas_app/features/resources/screens/data/table_guide.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
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

class _TableDataKeysSheet extends StatefulWidget {
  final QuestTable table;

  const _TableDataKeysSheet({required this.table});

  @override
  State<_TableDataKeysSheet> createState() => _TableDataKeysSheetState();
}

class _TableDataKeysSheetState extends State<_TableDataKeysSheet> {
  late final Map<String, dynamic> _data = Map.of(widget.table.data);
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> _visibleKeys() {
    final query = _search.text.trim().toLowerCase();
    final keys = _data.keys.toList()..sort();
    if (query.isEmpty) return keys;
    return keys.where((k) => k.toLowerCase().contains(query)).toList();
  }

  Future<void> _editKey({String? existing}) async {
    final edit = await showAppDialog<_KeyEdit>(
      context: context,
      builder: (ctx) =>
          _KeyEditDialog(existing: existing, current: _data[existing]),
    );
    if (edit == null || edit.name.isEmpty || !mounted) return;
    if (edit.name.startsWith('__')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Имена с «__» служебные: движок не сохранит такой ключ.'),
          ),
        ),
      );
      return;
    }
    if (existing != edit.name && _data.containsKey(edit.name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(trf('Ключ «{p0}» уже есть', {'p0': edit.name}))),
      );
      return;
    }
    setState(() {
      if (existing != null && existing != edit.name) _data.remove(existing);
      _data[edit.name] = edit.value;
    });
  }

  void _removeKey(String key) {
    setState(() => _data.remove(key));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keys = _visibleKeys();

    return Column(
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
                prefixIcon: Icon(Icons.search_rounded),
                hintText: tr('Поиск ключа'),
              ),
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: keys.length,
            itemBuilder: (_, i) {
              final key = keys[i];
              final value = _data[key];
              return ListTile(
                dense: true,
                leading: Icon(
                  value is List
                      ? Icons.list_rounded
                      : value is Map
                      ? Icons.account_tree_rounded
                      : Icons.label_outline_rounded,
                  color: scheme.onSurfaceVariant,
                ),
                title: Text(key),
                subtitle: Text(TableDataSnapshot.describeValue(value)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: tr('Изменить'),
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _editKey(existing: key),
                    ),
                    IconButton(
                      tooltip: tr('Удалить ключ'),
                      icon: Icon(
                        Icons.delete_outline,
                        color: scheme.error.withValues(alpha: 0.9),
                      ),
                      onPressed: () => _removeKey(key),
                    ),
                  ],
                ),
                onTap: () => _editKey(existing: key),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _editKey,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(tr('Добавить ключ')),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr('Отмена')),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: () => Navigator.pop(context, _data),
                child: Text(tr('Применить')),
              ),
            ],
          ),
        ),
      ],
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

  const _KeyEditDialog({required this.existing, required this.current});

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
        widget.existing == null
            ? tr('Новый ключ')
            : trf('Ключ «{p0}»', {'p0': widget.existing}),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: widget.existing == null,
            decoration: InputDecoration(
              isDense: true,
              labelText: tr('Имя ключа'),
              helperText: tr('как его видит скрипт: gold, opened, items'),
            ),
          ),
          const SizedBox(height: 12),
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
