import 'dart:convert';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:mnd_core/engine/game_engine.dart' show listBlockTypes;
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
//  ПАЛИТРА БЛОКОВ — то, чем автор добавляет действие
// ============================================================================
//
//  Блоки приходят из Rust-ядра (listBlockTypes) и группируются по
//  категориям. Раньше это был полноэкранный экран со списком без поиска:
//  чтобы найти нужный блок, список прокручивали глазами, а выбранный блок
//  «зависал» плавающей карточкой, которую надо было ещё и перетащить.
//
//  Здесь палитра живёт в шите (на телефоне — снизу, на ПК — диалог у
//  курсора) и делает три вещи:
//  - поиск по названию, имени типа и тексту подсказок;
//  - фильтры-чипы по категориям + секция недавно добавленных;
//  - тап = выбор, без второго жеста.
//
//  Акценты категорий берутся из blockAccent() — той же функции, которой
//  красится полоса самого блока (см. #224). Палитра и список блоков обязаны
//  показывать один цвет для одной категории, иначе выбор блока превращается
//  в угадывание по радуге.
// ============================================================================

/// Одна плитка палитры = тип блока из реестра ядра.
class BlockPaletteEntry {
  const BlockPaletteEntry({
    required this.name,
    required this.displayName,
    required this.category,
  });

  /// Имя типа — контракт с ядром и `_createBlockFromType` в редакторе.
  final String name;

  /// Как блок подписан в палитре и в снакбаре после вставки.
  final String displayName;

  /// Категория из ядра: variable/data/flow/script/audio/network/comment.
  final String category;
}

/// Названия категорий (из Rust BlockCategory). Геттер, а не const-таблица:
/// подписи строятся под текущий язык, ключи (`variable` и т. п.) — данные.
Map<String, String> get _kCategoryLabels => {
  'variable': tr('Переменные'),
  'data': tr('Данные'),
  'flow': tr('Управление'),
  'script': tr('Скрипты'),
  'audio': tr('Аудио'),
  'network': tr('Сеть'),
  'comment': tr('Заметки'),
};

/// Порядок категорий в списке (переменные → данные → управление → ...).
const _kCategoryOrder = [
  'variable',
  'data',
  'flow',
  'script',
  'audio',
  'network',
  'comment',
];

const _kCategoryIcons = <String, IconData>{
  'variable': Icons.edit_note_rounded,
  'data': Icons.dataset_rounded,
  'flow': Icons.call_split_rounded,
  'script': Icons.code_rounded,
  'audio': Icons.volume_up_rounded,
  'network': Icons.http_rounded,
  'comment': Icons.chat_bubble_outline_rounded,
};

/// Категория палитры → категория блока. Ядро группирует блоки по своей
/// таксономии, а акцент корпуса блока считается по `BlockCategory` — мост
/// нужен, чтобы цвет в палитре совпадал с цветом вставляемого блока.
///
/// «Данные» идёт в variable, потому что блок трогает ключи хранилища
/// скриптов — это переменные, только живущие в таблице. «Аудио» и «Сеть» —
/// action: они делают что-то, а не меняют состояние скрипта.
const _kCategoryAccent = <String, BlockCategory>{
  'variable': BlockCategory.variable,
  'data': BlockCategory.variable,
  'flow': BlockCategory.control,
  'script': BlockCategory.script,
  'audio': BlockCategory.action,
  'network': BlockCategory.action,
  'comment': BlockCategory.comment,
};

/// Одна строка под заголовком категории. Название «Данные» обманчиво: автор
/// ждёт редактора сетки, а блок трогает только ключи хранилища скриптов —
/// отсюда пустые промахи «Удалить» по ряду.
///
/// Геттер вместо `const`: const-карта запомнила бы строки первого вызова и
/// пережила смену языка русскими.
Map<String, String> get kBlockCategoryHints => {
  'data':
      tr('Блок «Данные» читает и пишет ключи хранилища скриптов — лавка[\'ключ\']. Ряды сетки он не трогает: для них ссылки {лавка["цена"][1]} и функции table_*.'),
  'flow':
      tr('«Цикл (таблица)» проходит по рядам сетки, переменная получает целый ряд. Ключи хранилища — блок «Данные».'),
};

/// Подсказка на плитке блока (долгое нажатие/наведение). Ключ — имя типа из
/// реестра ядра, поэтому новые блоки просто молча остаются без подсказки.
Map<String, String> get kBlockTileHints => {
  'table_operation':
      tr('Работает с хранилищем скриптов таблицы, ряды сетки не меняются.\n«Удалить» — по ключу или индексу; «Удалить значение» — по значению в списке.\nПустое поле «Путь» = промах: блок ничего не делает.'),
  'for_each':
      tr('Идёт по рядам сетки таблицы. В переменную кладётся целый ряд-словарь: ряд["цена"].'),
  'assign_variable':
      tr('Переменные квеста — не то же, что ключи таблицы: их читает {имя}.'),
};

/// Сколько недавно выбранных блоков помнить.
const int kRecentBlockTypesLimit = 6;

/// Ключ SharedPreferences со списком имён типов: свежие выбраны первыми.
const String kRecentBlockTypesKey = 'block_palette_recent_types';

/// Реестр блоков из ядра. Бросает, если FFI недоступен, — ловит палитра.
List<BlockPaletteEntry> readBlockPalette() {
  final list = (jsonDecode(listBlockTypes()) as List).cast<Map<String, dynamic>>();
  return list
      .map(
        (m) => BlockPaletteEntry(
          name: m['name'] as String,
          displayName: m['displayName'] as String,
          category: m['category'] as String,
        ),
      )
      .toList();
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll('ё', 'е').trim();

/// Всё, по чему ищем: подпись, имя типа, категория и оба текста подсказок.
/// Подсказки — не баловство: «хранилище» ищет блок «Данные», а «ряд» —
/// «Цикл (таблица)», и человек набирает слово из того, что уже видел.
String _searchKey(BlockPaletteEntry e) => _normalize([
      e.displayName,
      e.name,
      _kCategoryLabels[e.category] ?? e.category,
      kBlockTileHints[e.name] ?? '',
      kBlockCategoryHints[e.category] ?? '',
    ].join(' '));

/// Фильтр палитры: [category] — точная категория, [query] — все слова подряд
/// (регистр и «ё» не важны). Пустой запрос и null-категория = без фильтра.
List<BlockPaletteEntry> filterPalette(
  List<BlockPaletteEntry> entries, {
  String query = '',
  String? category,
}) {
  final words = _normalize(query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty && category == null) return entries;
  return entries.where((e) {
    if (category != null && e.category != category) return false;
    if (words.isEmpty) return true;
    final key = _searchKey(e);
    return words.every(key.contains);
  }).toList();
}

Future<List<String>> loadRecentBlockTypes() async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getStringList(kRecentBlockTypesKey);
  return stored == null ? const [] : List<String>.from(stored);
}

/// Записать выбор в «недавние» и вернуть список. Старые значения за границей
/// лимита отрезаются, повтор уходит в начало, а не удваивается.
Future<List<String>> recordRecentBlockType(String blockType) async {
  final prefs = await SharedPreferences.getInstance();
  final next = [
    blockType,
    ...?prefs.getStringList(kRecentBlockTypesKey)?.where((t) => t != blockType),
  ];
  final trimmed = next.take(kRecentBlockTypesLimit).toList();
  await prefs.setStringList(kRecentBlockTypesKey, trimmed);
  return trimmed;
}

/// Палитра в адаптивном шите: снизу на телефоне, диалогом у курсора на ПК.
/// Возвращает выбранный блок или null, если автор закрыл палитру.
Future<BlockPaletteEntry?> showBlockPicker(
  BuildContext context, {
  Offset? anchor,
  List<BlockPaletteEntry>? entries,
}) {
  return showAdaptiveSheet<BlockPaletteEntry>(
    context: context,
    title: tr('Добавить блок'),
    maxWidth: 560,
    anchor: anchor,
    isScrollControlled: true,
    showDragHandle: true,
    // На ПК диалог уже ограничен 80 % высоты, extra-скролл внутри только
    // плодит вторую полосу прокрутки.
    scrollable: false,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => BlockPalette(entries: entries),
  );
}

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

class BlockPalette extends StatefulWidget {
  const BlockPalette({super.key, this.entries});

  /// Тесты подают свой список, чтобы не зависеть от собранного Rust-ядра.
  /// null — читать реестр из ядра.
  final List<BlockPaletteEntry>? entries;

  @override
  State<BlockPalette> createState() => _BlockPaletteState();
}

class _BlockPaletteState extends State<BlockPalette> {
  final TextEditingController _queryController = TextEditingController();
  List<BlockPaletteEntry>? _all;
  List<String> _recent = const [];
  String? _category;
  String? _error;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(() => setState(() {}));
    if (widget.entries != null) {
      _all = widget.entries;
    } else {
      try {
        _all = readBlockPalette();
      } catch (e) {
        _error = e.toString();
      }
    }
    if (widget.entries == null) {
      // «Недавние» — единственное, что зависит от prefs. Тестам, которые
      // подают свой список блоков, хранилище не нужно.
      loadRecentBlockTypes().then((value) {
        if (mounted) setState(() => _recent = value);
      });
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _pick(BlockPaletteEntry entry) {
    Navigator.pop(context, entry);
    if (widget.entries != null) return;
    recordRecentBlockType(entry.name).then((next) {
      if (mounted) setState(() => _recent = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = _all;

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          trf('Реестр блоков недоступен: {_error}', {'_error': _error}),
          style: TextStyle(color: scheme.error),
        ),
      );
    }
    if (entries == null) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final query = _queryController.text;
    final visible = filterPalette(entries, query: query, category: _category);
    final recent = query.isEmpty && _category == null
        ? _recentEntries(entries)
        : const <BlockPaletteEntry>[];

    final grouped = <String, List<BlockPaletteEntry>>{};
    for (final e in visible) {
      grouped.putIfAbsent(e.category, () => []).add(e);
    }

    return SizedBox(
      // 72 % экрана: ниже — палитра превращается в прокрутку со скучающим
      // пальцем, выше — не видно список блоков, куда она вставляет.
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              key: const Key('block-palette-search'),
              controller: _queryController,
              // Клавиатура сразу только там, где есть физическая: на телефоне
              // автор чаще смотрит список, чем печатает.
              autofocus: isDesktopWidth(context),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: tr('Поиск блока'),
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        tooltip: tr('Очистить'),
                        onPressed: _queryController.clear,
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
          _CategoryChips(
            selected: _category,
            onSelected: (value) => setState(() => _category = value),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: visible.isEmpty
                ? _EmptySearch(
                    onReset: () {
                      _queryController.clear();
                      setState(() => _category = null);
                    },
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      if (recent.isNotEmpty)
                        _PaletteSection(
                          title: tr('Недавние'),
                          icon: Icons.history_rounded,
                          accent: scheme.primary,
                          entries: recent,
                          onPick: _pick,
                        ),
                      for (final catKey in _kCategoryOrder)
                        if (grouped.containsKey(catKey))
                          _PaletteSection(
                            catKey: catKey,
                            entries: grouped[catKey]!,
                            onPick: _pick,
                          ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Недавние в порядке записи, только те, что реально есть в реестре.
  List<BlockPaletteEntry> _recentEntries(List<BlockPaletteEntry> entries) {
    final byName = {for (final e in entries) e.name: e};
    return [for (final name in _recent) if (byName.containsKey(name)) byName[name]!];
  }
}

class _CategoryChips extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onSelected;

  const _CategoryChips({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      _Chip(label: tr('Все'), value: null, selected: selected, onSelected: onSelected),
      for (final catKey in _kCategoryOrder)
        _Chip(
          label: _kCategoryLabels[catKey] ?? catKey,
          value: catKey,
          selected: selected,
          onSelected: onSelected,
        ),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final chip in chips)
            Padding(padding: const EdgeInsets.only(right: 6), child: chip),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String? value;
  final String? selected;
  final ValueChanged<String?> onSelected;

  const _Chip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected == value,
      onSelected: (_) => onSelected(value),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      // Пилюлей, как чип значения в шапке блока: фильтр и значение должны
      // читаться одним и тем же элементом.
      shape: const StadiumBorder(),
    );
  }
}

class _PaletteSection extends StatelessWidget {
  /// Категория из ядра. Если задана [title]/[icon]/[accent] — они важнее
  /// (так рисуются «Недавние»).
  final String? catKey;
  final String? title;
  final IconData? icon;
  final Color? accent;
  final List<BlockPaletteEntry> entries;
  final ValueChanged<BlockPaletteEntry> onPick;

  const _PaletteSection({
    this.catKey,
    this.title,
    this.icon,
    this.accent,
    required this.entries,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cat = catKey;
    final label = title ?? _kCategoryLabels[cat ?? ''] ?? cat ?? '';
    final tint =
        accent ??
        blockAccent(theme.brightness, _kCategoryAccent[cat ?? ''] ?? BlockCategory.action);
    final headIcon = icon ?? _kCategoryIcons[cat ?? ''];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
          child: Row(
            children: [
              if (headIcon != null) ...[
                Icon(headIcon, size: 15, color: tint),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Divider(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                  height: 1,
                  thickness: 1,
                ),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final entry in entries)
              _BlockChip(
                entry: entry,
                accent: tint,
                icon: headIcon ?? _kCategoryIcons[entry.category],
                onTap: () => onPick(entry),
              ),
          ],
        ),
        if (cat != null) BlockCategoryHint(catKey: cat),
      ],
    );
  }
}

/// Плитка блока — тот же язык, что и у карточки блока в списке: скруглённая
/// плашка, иконка категории в тонированной плашке, тонкая рамка.
class _BlockChip extends StatelessWidget {
  final BlockPaletteEntry entry;
  final Color accent;
  final IconData? icon;
  final VoidCallback onTap;

  const _BlockChip({
    required this.entry,
    required this.accent,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = kBlockTileHints[entry.name];

    final chip = Material(
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 14, 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  icon ?? Icons.extension_rounded,
                  size: 15,
                  color: accent,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                entry.displayName,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (hint == null) return chip;
    // Долгий тап на телефоне тоже открывает подсказку — просто он ещё и
    // выбирает блок, поэтому текст держим коротким и по делу.
    return Tooltip(message: hint, padding: const EdgeInsets.all(10), child: chip);
  }
}

class _EmptySearch extends StatelessWidget {
  final VoidCallback onReset;

  const _EmptySearch({required this.onReset});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(
            tr('Ничего не нашлось'),
            style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            tr('Попробуйте другое слово или снимите фильтр'),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          TextButton(onPressed: onReset, child: Text(tr('Сбросить'))),
        ],
      ),
    );
  }
}

/// Строка-напоминание под категорией. Пустая категория ничего не рисует —
/// секции не должны превращаться в стену текста.
class BlockCategoryHint extends StatelessWidget {
  final String catKey;

  const BlockCategoryHint({super.key, required this.catKey});

  @override
  Widget build(BuildContext context) {
    final hint = kBlockCategoryHints[catKey];
    if (hint == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 7),
            child: Icon(
              Icons.info_outline_rounded,
              size: 13,
              color: scheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              hint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
