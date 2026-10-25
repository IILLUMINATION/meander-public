import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/reorderable_block_list.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/watch_paths_picker_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

// ============================================================================
//  EVENT BLOCK — Material 3 (тема)
// ============================================================================
//
//  Корневой блок-контейнер скрипта. Использует тот же `ScriptBlockShell`, что
//  и обычные блоки — но с двумя дополнительными вкладами:
//   • при типе Function — отображается «карточка функции» (ScriptFieldTile)
//   • в теле — заголовок «Содержимое» + ReorderableBlockList
//
//  Все цвета берутся ИСКЛЮЧИТЕЛЬНО из Theme.of(context).colorScheme:
//  primary/primaryContainer для иконки события (через ScriptBlockShell),
//  onSurface/onSurfaceVariant для текста, surfaceContainerHighest для
//  внутренних плашек.
// ============================================================================

typedef OnBlockDrop =
    void Function(
      VisualScriptBlock droppedBlock,
      List<VisualScriptBlock> targetList,
    );

class EventBlockWidget extends ConsumerStatefulWidget {
  final EventBlock block;
  final String questId;
  final List<String> availableFunctionNames;
  final VoidCallback? onDelete;
  final OnBlockDrop onBlockDrop;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  /// Меню самого события (короткий тап). Операции над списком-владельцем
  /// знает только экран, поэтому обрабатывает он: дубликат и вставка
  /// происходят рядом с событием, а не внутрь его детей.
  final ValueChanged<ScriptBlockMenuAction>? onMenuAction;

  /// Резолвер GlobalKey по id блока — нужен экрану, чтобы измерить позиции
  /// дочерних блоков и понять, куда (ближе к центру экрана) вставлять новый.
  final GlobalKey Function(String id)? blockKeyResolver;

  const EventBlockWidget({
    super.key,
    required this.block,
    required this.questId,
    this.availableFunctionNames = const [],
    this.onDelete,
    required this.onBlockDrop,
    this.onDragUpdate,
    this.onDragStart,
    this.onDragEnd,
    this.onMenuAction,
    this.blockKeyResolver,
  });

  @override
  ConsumerState<EventBlockWidget> createState() => _EventBlockWidgetState();
}

class _EventBlockWidgetState extends ConsumerState<EventBlockWidget> {
  // ---------------------------------------------------------------------------
  //  HELPERS
  // ---------------------------------------------------------------------------

  String _eventTitle(EventType type) {
    switch (type) {
      case EventType.onQuestStart:
        return tr('При запуске квеста');
      case EventType.onNodeEnter:
        return tr('При входе в ноду');
      case EventType.onPress:
        return tr('По нажатию');
      case EventType.onContentAppear:
        return tr('При появлении контента');
      case EventType.onDataChange:
        return tr('При изменении данных');
      case EventType.function:
        return tr('Функция');
    }
  }

  String _eventSubtitle(EventType type) {
    // Используется только в bottom sheet выбора типа события — оставлено как
    // подсказка в списке.
    switch (type) {
      case EventType.onQuestStart:
        return tr('Один раз при запуске игры, до первой ноды. Скрипт с таким блоком в папке scripts/ движок находит сам.');
      case EventType.onNodeEnter:
        return tr('Срабатывает при заходе на ноду');
      case EventType.onPress:
        return tr('Срабатывает при нажатии');
      case EventType.onContentAppear:
        return tr('Срабатывает при показе элемента');
      case EventType.onDataChange:
        return tr('Срабатывает, когда меняется один из указанных путей: переменная, ключ таблицы или ячейка. * — следить за всем.');
      case EventType.function:
        return tr('Вызывается по имени');
    }
  }

  IconData _eventIcon(EventType type) {
    switch (type) {
      case EventType.onQuestStart:
        return Icons.play_circle_outline_rounded;
      case EventType.onNodeEnter:
        return Icons.login_rounded;
      case EventType.onPress:
        return Icons.touch_app_rounded;
      case EventType.onContentAppear:
        return Icons.visibility_rounded;
      case EventType.onDataChange:
        return Icons.change_circle_rounded;
      case EventType.function:
        return Icons.functions_rounded;
    }
  }

  // ---------------------------------------------------------------------------
  //  ACTIONS
  // ---------------------------------------------------------------------------

  Future<void> _selectEventType() async {
    final current = widget.block.eventType ?? EventType.onNodeEnter;
    final value = await showAdaptiveSheet<EventType>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  tr('Тип события'),
                  style: Theme.of(
                    ctx,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              ...EventType.values.map((type) {
                final isSelected = type == current;
                return ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _eventIcon(type),
                      color: isSelected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                      size: 20,
                    ),
                  ),
                  title: Text(
                    _eventTitle(type),
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.w800
                          : FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(_eventSubtitle(type)),
                  trailing: isSelected
                      ? Icon(Icons.check_rounded, color: scheme.primary)
                      : null,
                  onTap: () => Navigator.pop(ctx, type),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (value != null && value != current) {
      setState(() => widget.block.eventType = value);
    }
  }

  Future<void> _editWatchPaths() async {
    final result = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => WatchPathsPickerScreen(
          questId: widget.questId,
          initial: widget.block.watchPaths,
        ),
      ),
    );
    if (result != null) {
      setState(() => widget.block.watchPaths = result);
    }
  }

  Future<void> _selectFunctionName() async {
    final names = <String>{
      'main',
      widget.block.functionName.trim().isEmpty
          ? 'main'
          : widget.block.functionName.trim(),
      ...widget.availableFunctionNames
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.trim()),
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final value = await showAdaptiveSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      scrollable: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    tr('Выбор функции'),
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                title: Text(
                  tr('Новая функция'),
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(tr('Создать с нуля')),
                onTap: () => Navigator.pop(ctx, '__create__'),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: names.length,
                  itemBuilder: (_, i) {
                    final name = names[i];
                    final isSelected = name == widget.block.functionName;
                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? scheme.primaryContainer
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          isSelected
                              ? Icons.check_rounded
                              : Icons.functions_rounded,
                          color: isSelected
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        name,
                        style: TextStyle(
                          fontWeight: isSelected
                              ? FontWeight.w800
                              : FontWeight.w500,
                        ),
                      ),
                      onTap: () => Navigator.pop(ctx, name),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (value == null) return;
    if (value == '__create__') {
      final created = await _createFunctionName();
      if (created == null) return;
      if (!mounted) return;
      setState(() {
        widget.block.functionName = created;
      });
      return;
    }
    setState(() {
      widget.block.functionName = value;
    });
  }

  Future<String?> _createFunctionName() async {
    final controller = TextEditingController();
    final created = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Новая функция')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('Имя функции'),
            hintText: 'checkVisibility',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Создать')),
          ),
        ],
      ),
    );
    if (created == null || created.isEmpty) return null;
    return created;
  }

  // ---------------------------------------------------------------------------
  //  BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final eventType = widget.block.eventType ?? EventType.onNodeEnter;
    final isFunction = eventType == EventType.function;
    final isDataWatch = eventType == EventType.onDataChange;
    final title = _eventTitle(eventType);

    return ScriptBlockShell(
      category: BlockCategory.event,
      title: title,
      icon: _eventIcon(eventType),
      onDelete: widget.onDelete,
      onMenuAction: widget.onMenuAction,
      menuScope: blockScope(widget.block).noun,
      collapsible: true,
      collapsed: widget.block.collapsed,
      onToggleCollapse: () {
        setState(() {
          widget.block.collapsed = !widget.block.collapsed;
        });
      },
      // Имя и способ запуска видны в свёрнутом блоке: без этого событие-функция
      // выглядит как обычное и юзер ждёт, что нода сама её выполнит.
      headerSuffix: isFunction
          ? _FunctionBadge(name: widget.block.functionName)
          : isDataWatch
          ? _WatchBadge(paths: widget.block.watchPaths)
          : null,
      // Действия скрипта — плоскими карточками под шапкой события, а не
      // внутри цветного корпуса: иначе событие выглядит фоном всего скрипта.
      // Заглушки конца у него нет — следующая шляпа начинает новый скрипт.
      body: ReorderableBlockList(
        blocks: widget.block.children,
        questId: widget.questId,
        onBlockDrop: widget.onBlockDrop,
        allowEventBlocks: false,
        emptyPlaceholder: tr('Перетащите сюда действия'),
        onDragUpdate: widget.onDragUpdate,
        onDragStart: widget.onDragStart,
        onDragEnd: widget.onDragEnd,
        blockKeyResolver: widget.blockKeyResolver,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Компактное pill-поле выбора типа события
          ScriptFieldTile(
            label: tr('Тип'),
            value: title,
            icon: Icons.swap_horiz_rounded,
            onTap: _selectEventType,
          ),
          if (isFunction) ...[
            const SizedBox(height: 4),
            ScriptFieldTile(
              label: tr('Функция'),
              value: widget.block.functionName,
              placeholder: tr('не задана'),
              icon: Icons.tag_rounded,
              onTap: _selectFunctionName,
            ),
            _FunctionHint(),
          ],
          if (isDataWatch) ...[
            const SizedBox(height: 4),
            ScriptFieldTile(
              label: tr('Следить'),
              value: widget.block.watchPaths.join(', '),
              placeholder: tr('любое изменение'),
              icon: Icons.change_circle_rounded,
              onTap: _editWatchPaths,
            ),
            _DataWatchHint(),
          ],
        ],
      ),
    );
  }
}

/// Чип в шапке события-функции: имя + напоминание, что запуск только извне.
///
/// В свёрнутом блоке подсказка из тела не видна, а именно в свёрнутом виде
/// событие-функция чаще всего и выглядит как «обычное» — отсюда ожидание,
/// что нода выполнит скрипт сама.
class _FunctionBadge extends StatelessWidget {
  final String name;
  const _FunctionBadge({required this.name});

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    return Tooltip(
      message:
          tr('Вызывается извне: блоком «Вызвать функцию» или триггером. Нода этот скрипт сама не запустит.'),
      child: ShellValueChip(
        value: trimmed,
        placeholder: tr('без имени'),
        icon: Icons.call_missed_outgoing_rounded,
      ),
    );
  }
}

/// Подсказка на событии-функции.
///
/// Скрипт, прикреплённый к ноде, движок запускает на «входе в ноду» и «показе
/// контента». Если единственное его событие — функция, он молча не выполнится
/// никогда: именно так «не работает» блок, добавленный в пустой скрипт.
class _FunctionHint extends StatelessWidget {
  const _FunctionHint();

  @override
  Widget build(BuildContext context) {
    final fg =
        DefaultTextStyle.of(context).style.color ??
        Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 13,
            color: fg.withOpacity(0.7),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              tr('Запускается только по вызову: блоком «Вызвать функцию» или триггером. Прикреплённый к ноде скрипт с одним таким событием не выполнится никогда.'),
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                color: fg.withOpacity(0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Чип в шапке события «При изменении данных».
///
/// В свёрнутом блоке тело с полем «Следить» не видно, а именно по подпискам
/// автор понимает, чем это событие отличается от «при входе в ноду».
class _WatchBadge extends StatelessWidget {
  final List<String> paths;
  const _WatchBadge({required this.paths});

  @override
  Widget build(BuildContext context) {
    // Одно значение + счётчик: список путей длиннее двух слов порвал бы
    // заголовок блока.
    final label = paths.isEmpty
        ? ''
        : paths.length == 1
        ? paths.first
        : '${paths.first} +${paths.length - 1}';
    return Tooltip(
      message: paths.isEmpty
          ? tr('Срабатывает на любое изменение данных.')
          : trf('Следит за: {p0}', {'p0': paths.join(', ')}),
      child: ShellValueChip(
        value: label,
        placeholder: tr('любое изменение'),
        icon: Icons.change_circle_rounded,
        maxWidth: 180,
      ),
    );
  }
}

/// Подсказка на событии «При изменении данных».
///
/// Два факта без текста выглядят багом: скрипт ноды следит только в своей
/// ноде, а собственная запись в подписанный путь запускает событие заново.
class _DataWatchHint extends StatelessWidget {
  const _DataWatchHint();

  @override
  Widget build(BuildContext context) {
    final fg =
        DefaultTextStyle.of(context).style.color ??
        Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 13,
            color: fg.withOpacity(0.7),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              tr('Проверяется на каждом шаге игры: что именно изменилось — в {_changed_path} и {_changed_paths}. Скрипт из scripts/ следит всё время, скрипт ноды — только пока игрок в ней. Запись в подписанный путь вызывает событие заново, но глубже четырёх звеньев цепочка обрывается.'),
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                color: fg.withOpacity(0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

