import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/features/resources/screens/data/table_examples.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Справочник по таблицам. Вместо простыни текста: живая сетка, которую можно
/// потыкать, карточка ключей хранилища, готовые рецепты для блока «Данные»
/// и квест-тренажёр, который добавляется в «Мои квесты» одной кнопкой.
///
/// [exampleTable] — настоящее имя таблицы, если шпаргалку открыли из неё:
/// в примерах будет видно своё имя, а не выдуманное.
Future<void> showTableGuide(BuildContext context, {String exampleTable = ''}) {
  return showAdaptiveSheet<void>(
    context: context,
    title: tr('Таблицы: как читать и как менять'),
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    maxWidth: 520,
    builder: (context) => _TableGuideSheet(exampleTable: exampleTable),
  );
}

class _TableGuideSheet extends StatefulWidget {
  final String exampleTable;

  const _TableGuideSheet({required this.exampleTable});

  @override
  State<_TableGuideSheet> createState() => _TableGuideSheetState();
}

class _TableGuideSheetState extends State<_TableGuideSheet> {
  bool _importing = false;

  String get _table =>
      widget.exampleTable.trim().isEmpty ? tr('лавка') : widget.exampleTable;

  Future<void> _addExamples() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      await TableExamples.importAll();
      if (!mounted) return;
      ProviderScope.containerOf(
        context,
        listen: false,
      ).invalidate(questsProvider);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(tr('Тренажёр добавлен. Открой «Мои квесты».')),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              trf('Не удалось добавить тренажёр: {p0}', {'p0': '$e'}),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text(
          tr(
            'В таблице два хранилища. Сетка — то, что видно в редакторе. Ключи — то, что скрипты читают по имени. Адрес ячейки работает и там, и там.',
          ),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        _SectionTitle(tr('Сетка: нажми на ячейку')),
        _TableDemo(table: _table),
        const SizedBox(height: 16),
        _SectionTitle(tr('Ключи хранилища')),
        _StorageDemo(table: _table),
        const SizedBox(height: 16),
        _SectionTitle(tr('Записать из блока «Данные»')),
        _WriteRecipe(table: _table),
        const SizedBox(height: 16),
        _SectionTitle(tr('Все операции')),
        _OperationsLegend(),
        const SizedBox(height: 16),
        _SectionTitle(tr('Прочитать в тексте')),
        _ReadRecipe(table: _table),
        const SizedBox(height: 16),
        _SectionTitle(tr('Частые промахи')),
        _Mistakes(),
        const SizedBox(height: 18),
        _ExamplesCard(importing: _importing, onAdd: _addExamples),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// Живая сетка «лавка»: тап по ячейке показывает её ссылку, путь для блока и
/// значение. Так 1-based строки видно на экране, а не в абзаце.
class _TableDemo extends StatefulWidget {
  final String table;

  const _TableDemo({required this.table});

  @override
  State<_TableDemo> createState() => _TableDemoState();
}

class _TableDemoState extends State<_TableDemo> {
  static const List<List<int>> _values = [
    [10, 2],
    [20, 0],
    [5, 7],
  ];

  int _row = 1;
  int _column = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final columns = [tr('цена'), tr('запас')];
    final rowNumber = _row + 1;
    final path = '["${columns[_column]}"][$rowNumber]';
    final value = _values[_row][_column];

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _CellBox(text: tr('строка'), width: 46, subtle: true),
              const SizedBox(width: 4),
              for (var c = 0; c < columns.length; c++) ...[
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _column = c),
                    child: _CellBox(
                      text: columns[c],
                      highlighted: c == _column,
                      subtle: true,
                    ),
                  ),
                ),
                if (c != columns.length - 1) const SizedBox(width: 4),
              ],
            ],
          ),
          const SizedBox(height: 4),
          for (var r = 0; r < _values.length; r++) ...[
            Row(
              children: [
                _CellBox(
                  text: '${r + 1}',
                  width: 46,
                  subtle: true,
                  highlighted: r == _row,
                ),
                const SizedBox(width: 4),
                for (var c = 0; c < columns.length; c++) ...[
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setState(() {
                        _row = r;
                        _column = c;
                      }),
                      child: _CellBox(
                        text: '${_values[r][c]}',
                        highlighted: r == _row && c == _column,
                      ),
                    ),
                  ),
                  if (c != columns.length - 1) const SizedBox(width: 4),
                ],
              ],
            ),
            if (r != _values.length - 1) const SizedBox(height: 4),
          ],
          const SizedBox(height: 10),
          _CodeLine(
            label: tr('Ссылка в тексте'),
            value: '{${widget.table}$path}',
          ),
          const SizedBox(height: 4),
          _CodeLine(label: tr('Путь в блоке «Данные»'), value: path),
          const SizedBox(height: 4),
          _CodeLine(label: tr('Значение'), value: '$value'),
          const SizedBox(height: 8),
          Text(
            tr('Строки считаются с 1. У столбца номера нет — только имя.'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _CellBox extends StatelessWidget {
  final String text;
  final bool highlighted;
  final bool subtle;
  final double? width;

  const _CellBox({
    required this.text,
    this.highlighted = false,
    this.subtle = false,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = highlighted
        ? scheme.primaryContainer
        : subtle
        ? scheme.surfaceContainerHighest
        : scheme.surface;
    return Container(
      width: width,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlighted ? scheme.primary : scheme.outlineVariant,
          width: highlighted ? 1.5 : 1,
        ),
      ),
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: highlighted ? FontWeight.w800 : FontWeight.w500,
          color: highlighted ? scheme.onPrimaryContainer : scheme.onSurface,
        ),
      ),
    );
  }
}

class _StorageDemo extends StatelessWidget {
  final String table;

  const _StorageDemo({required this.table});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Это не сетка: у ключей нет колонки и строки, только имя.'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            tr(
              'Вложенное значение адресуется путём: персонаж["инвентарь"][0]. В пикере пути кнопка › раскрывает уровень.',
            ),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _KeyRow(keyName: tr('золото'), value: '60'),
          const SizedBox(height: 4),
          _KeyRow(keyName: tr('открыто'), value: 'true'),
          const SizedBox(height: 10),
          _CodeLine(
            label: tr('Ссылка в тексте'),
            value: "{$table['${tr('золото')}']}",
          ),
          const SizedBox(height: 4),
          _CodeLine(label: tr('Путь в блоке «Данные»'), value: tr('золото')),
          const SizedBox(height: 4),
          _CodeLine(label: tr('Значение'), value: '60'),
        ],
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  final String keyName;
  final String value;

  const _KeyRow({required this.keyName, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              keyName,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _WriteRecipe extends StatelessWidget {
  final String table;

  const _WriteRecipe({required this.table});

  @override
  Widget build(BuildContext context) {
    final goldRef = "{$table['${tr('золото')}']}";
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _NumberedStep(
            number: '1',
            text: tr('В блоке «Данные» выбери таблицу и операцию «Записать».'),
          ),
          const SizedBox(height: 8),
          _NumberedStep(
            number: '2',
            text: tr(
              'В поле «Путь» вставь адрес: ячейка — ["колонка"][2], ключ — золото.',
            ),
          ),
          const SizedBox(height: 8),
          _NumberedStep(
            number: '3',
            text: trf(
              'В поле «Значение» — новое значение или формула. Например, {p0} + 50.',
              {'p0': goldRef},
            ),
          ),
          const SizedBox(height: 12),
          _BeforeAfter(
            label: tr('ячейка'),
            before: '["${tr('цена')}"][2] = 20',
            after: '["${tr('цена')}"][2] = 42',
          ),
          const SizedBox(height: 6),
          _BeforeAfter(
            label: tr('ключ'),
            before: '${tr('золото')} = 10',
            after: '${tr('золото')} = 60',
          ),
          const SizedBox(height: 10),
          Text(
            tr(
              'Ссылку из текста можно вставлять в путь как есть: фигурные скобки и имя таблицы снимаются сами.',
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _OperationsLegend extends StatelessWidget {
  const _OperationsLegend();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final op in TableOperation.values)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text(
                    op.label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tr(
              '«Получить» и «Записать» понимают адрес ячейки. Остальные операции — пути внутри ключей и списков.',
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadRecipe extends StatelessWidget {
  final String table;

  const _ReadRecipe({required this.table});

  @override
  Widget build(BuildContext context) {
    final cell = '{$table["${tr('цена')}"][2]}';
    final key = "{$table['${tr('золото')}']}";
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReadRow(label: tr('Ячейка сетки'), value: cell),
          const SizedBox(height: 6),
          _ReadRow(label: tr('Ключ хранилища'), value: key),
          const SizedBox(height: 6),
          _ReadRow(
            label: tr('Блок «Получить»'),
            value: tr(
              'Путь = ["цена"][2] или золото, результат — в переменную',
            ),
          ),
          const SizedBox(height: 10),
          Text(
            trf(
              'Фигурные скобки — только вокруг ссылки целиком: {p0} теряет «+ 5». Считать — функцией без скобок: {p1}.',
              {
                'p0': '{$table["${tr('цена')}"][2] + 5}',
                'p1': 'table_cell($table, "${tr('цена')}", 1) + 5',
              },
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadRow extends StatelessWidget {
  final String label;
  final String value;

  const _ReadRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _Mistakes extends StatelessWidget {
  const _Mistakes();

  List<String> get _keys => [
    tr(
      'Пустой путь: «Записать» ничего не делает, «Получить» берёт запасное значение.',
    ),
    tr('Номер строки 0 или больше числа строк — промах. Строки с 1.'),
    tr('Опечатка в имени таблицы: в логе скрипта будет список доступных имён.'),
    tr(
      'Адрес ячейки понимают «Получить» и «Записать». «Добавить» и «Удалить» работают только с ключами.',
    ),
    tr(
      'Имя колонки без строки — это ключ хранилища, а не ячейка. Для сетки нужен адрес ["цена"][2].',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final key in _keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5, right: 8),
                    child: Icon(
                      Icons.circle,
                      size: 5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      key,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ExamplesCard extends StatelessWidget {
  final bool importing;
  final VoidCallback onAdd;

  const _ExamplesCard({required this.importing, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Квест-тренажёр'),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            tr(
              'Один большой интерактивный квест: сетка и ключи, вложенные пути, списки, все операции блока «Данные», формулы и разбор ошибок. Открой его в редакторе и посмотри таблицы и скрипты изнутри.',
            ),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: importing ? null : onAdd,
            icon: importing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded, size: 18),
            label: Text(tr('Добавить тренажёр в «Мои квесты»')),
          ),
        ],
      ),
    );
  }
}

class _BeforeAfter extends StatelessWidget {
  final String label;
  final String before;
  final String after;

  const _BeforeAfter({
    required this.label,
    required this.before,
    required this.after,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(before, style: Theme.of(context).textTheme.bodySmall),
                Text(
                  after,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberedStep extends StatelessWidget {
  final String number;
  final String text;

  const _NumberedStep({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(height: 1.35),
          ),
        ),
      ],
    );
  }
}

class _CodeLine extends StatelessWidget {
  final String label;
  final String value;

  const _CodeLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;

  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

/// Компактная строка-напоминание над таблицей или блоком: коротко о том, что
/// сетка и хранилище скриптов — разные вещи, плюс вход в шпаргалку.
class TableHintBanner extends StatelessWidget {
  final String text;
  final VoidCallback? onDetails;
  final String? detailsLabel;

  const TableHintBanner({
    super.key,
    required this.text,
    this.onDetails,
    this.detailsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lightbulb_outline_rounded,
            size: 16,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
                height: 1.3,
              ),
            ),
          ),
          if (onDetails != null)
            Flexible(
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: onDetails,
                child: Text(
                  detailsLabel ?? tr('Подробнее'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
