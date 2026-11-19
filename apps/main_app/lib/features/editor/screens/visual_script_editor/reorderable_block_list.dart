import 'package:canvas_app/features/editor/screens/visual_script_editor/block_factory.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/providers/visual_script_clipboard_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef OnBlockDrop =
    void Function(
      VisualScriptBlock droppedBlock,
      List<VisualScriptBlock> targetList,
    );

class ReorderableBlockList extends ConsumerStatefulWidget {
  final List<VisualScriptBlock> blocks;
  final String questId;
  final OnBlockDrop onBlockDrop;
  final String? emptyPlaceholder;
  final bool allowEventBlocks;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  /// Резолвер GlobalKey по id блока — нужен экрану, чтобы измерить экранные
  /// позиции блоков и определить ближайшее к центру место вставки нового блока.
  final GlobalKey Function(String id)? blockKeyResolver;

  const ReorderableBlockList({
    super.key,
    required this.blocks,
    required this.questId,
    required this.onBlockDrop,
    this.allowEventBlocks = true,
    this.emptyPlaceholder,
    this.onDragUpdate,
    this.onDragStart,
    this.onDragEnd,
    this.blockKeyResolver,
  });

  @override
  ConsumerState<ReorderableBlockList> createState() =>
      _ReorderableBlockListState();
}

class _ReorderableBlockListState extends ConsumerState<ReorderableBlockList> {
  // Хранит состояние hover для каждого индекса вставки
  final Map<int, bool> _dragTargetsHoverStates = {};

  // Индекс активного DragTarget во время перетаскивания
  int? _activeDragTargetIndex;

  @override
  Widget build(BuildContext context) {
    final clipboardItem = ref.watch(visualScriptClipboardProvider);
    final canPasteFromClipboard =
        clipboardItem != null &&
        (widget.allowEventBlocks ||
            clipboardItem.blocks.every((block) => block is! EventBlock));

    if (widget.blocks.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DragTarget<VisualScriptBlock>(
            builder: (context, candidateData, rejectedData) {
              final isActive = candidateData.isNotEmpty;
              return Container(
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(
                    // Цвет из темы: белая опакность была видна только на
                    // тёмном фоне редактора, в светлой теме зона вставки
                    // исчезала.
                    color: isActive
                        ? scheme.primary
                        : scheme.outlineVariant.withOpacity(0.5),
                    width: 1.5,
                  ),
                  color: isActive ? scheme.primary.withValues(alpha: 0.08) : null,
                  // Тот же радиус, что у карточки блока: зона вставки — та же
                  // плашка, только пустая.
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  widget.emptyPlaceholder ?? tr('Перетащите сюда действия'),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                    fontSize: 12,
                  ),
                ),
              );
            },
            onAcceptWithDetails: (details) {
              if (!widget.allowEventBlocks && details.data is EventBlock) {
                return;
              }
              widget.onBlockDrop(details.data, widget.blocks);
              setState(() {
                widget.blocks.insert(0, details.data);
              });
              widget.onDragEnd?.call();
            },
          ),
          if (canPasteFromClipboard)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton.icon(
                  onPressed: () => _pasteFromClipboard(insertIndex: 0),
                  icon: const Icon(Icons.content_paste_rounded, size: 16),
                  label: Text(tr('Вставить из буфера')),
                ),
              ),
            ),
        ],
      );
    }

    // Инициализируем состояния hover для всех индексов
    for (int i = 0; i <= widget.blocks.length; i++) {
      if (!_dragTargetsHoverStates.containsKey(i)) {
        _dragTargetsHoverStates[i] = false;
      }
    }

    // Создаем список с DragTargets между элементами
    List<Widget> children = [];

    for (int i = 0; i < widget.blocks.length; i++) {
      // Добавляем DragTarget перед каждым элементом (включая первый)
      children.add(_buildDragTarget(i));

      // Добавляем сам элемент
      children.add(_buildBlock(widget.blocks[i]));
    }

    // Добавляем DragTarget в конец списка (после последнего элемента)
    children.add(_buildDragTarget(widget.blocks.length));

    return Column(children: children);
  }

  Widget _buildDragTarget(int insertIndex) {
    return DragTarget<VisualScriptBlock>(
      builder: (context, candidateData, rejectedData) {
        bool isActive = _activeDragTargetIndex == insertIndex;
        // Разрыв между карточками целиком принадлежит зоне вставки: только
        // так у пальца есть 12 px попадания, а не 10 из 22, и весь зазор
        // между соседями «ловит» блок. Неактивная зона прозрачна.
        return Container(
          height: 12,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: isActive
              // Скруглённая с обоих концов линия: прямоугольный 2-пиксельный
              // «ус» над карточкой с радиусом 18 выглядел обломком.
              ? Container(
                  height: 3,
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                )
              : null,
        );
      },
      onAcceptWithDetails: (details) {
        if (!widget.allowEventBlocks && details.data is EventBlock) {
          return;
        }
        // Обновляем состояние hover
        setState(() {
          _dragTargetsHoverStates[insertIndex] = false;
          _activeDragTargetIndex = null;
        });

        // Находим и удаляем блок из старого места, если он там был
        int oldIndex = widget.blocks.indexWhere(
          (block) => block.id == details.data.id,
        );
        final bool isFromOtherList = oldIndex == -1;
        if (oldIndex != -1) {
          setState(() {
            widget.blocks.removeAt(oldIndex);
            // Корректируем индекс вставки, если блок перемещается вниз по списку
            if (oldIndex < insertIndex) {
              insertIndex--;
            }
          });
        }

        // Вставляем блок в новое место
        if (isFromOtherList) {
          widget.onBlockDrop(details.data, widget.blocks);
        }
        setState(() {
          widget.blocks.insert(insertIndex, details.data);
        });
        widget.onDragEnd?.call();
      },
      onLeave: (details) {
        setState(() {
          _dragTargetsHoverStates[insertIndex] = false;
          if (_activeDragTargetIndex == insertIndex) {
            _activeDragTargetIndex = null;
          }
        });
      },
      onWillAcceptWithDetails: (details) {
        if (!widget.allowEventBlocks && details.data is EventBlock) {
          return false;
        }
        setState(() {
          _activeDragTargetIndex = insertIndex;
        });
        // Проверяем, что перетаскиваемый блок не является самим собой
        // Проверяем, что блок не находится уже в этом же месте
        int currentIndex = widget.blocks.indexWhere(
          (block) => block.id == details.data.id,
        );
        if (currentIndex == insertIndex ||
            (currentIndex == insertIndex - 1 && insertIndex > 0)) {
          return false;
        }
        return true;
      },
    );
  }

  Widget _buildBlock(VisualScriptBlock block) {
    final factory = BlockFactory(
      key: ValueKey(block.id),
      block: block,
      questId: widget.questId,
      onDelete: () {
        setState(() {
          widget.blocks.remove(block);
        });
      },
      onMenuAction: (action) => _handleBlockMenuAction(action, block),
      onBlockDrop: widget.onBlockDrop,
      onDragUpdate: widget.onDragUpdate,
      onDragStart: widget.onDragStart,
      onDragEnd: widget.onDragEnd,
    );

    // Если экран дал резолвер ключей — оборачиваем блок в KeyedSubtree с
    // GlobalKey, чтобы экран мог измерить его экранную позицию и определить
    // ближайшее к центру место для вставки нового блока.
    final resolver = widget.blockKeyResolver;
    if (resolver != null) {
      return KeyedSubtree(key: resolver(block.id), child: factory);
    }
    return factory;
  }

  /// Обработчик контекстного меню для КОНКРЕТНОГО дочернего блока (короткий
  /// тап по блоку → меню в [ScriptBlockShell]). Все операции применяются
  /// именно к этому блоку и его списку-владельцу [widget.blocks], а вставка
  /// происходит сразу рядом с ним (а не в конец и не на уровне события).
  void _handleBlockMenuAction(
    ScriptBlockMenuAction action,
    VisualScriptBlock block,
  ) {
    final index = widget.blocks.indexWhere((entry) => entry.id == block.id);
    switch (action) {
      case ScriptBlockMenuAction.copy:
        ref
            .read(visualScriptClipboardProvider.notifier)
            .state = VisualScriptClipboardItem(
          blocks: [block.clone()],
          operation: 'copy',
        );
        _showSnack(blockOperationToast(action, block));
        return;
      case ScriptBlockMenuAction.cut:
        ref
            .read(visualScriptClipboardProvider.notifier)
            .state = VisualScriptClipboardItem(
          blocks: [block.clone()],
          operation: 'cut',
        );
        if (index != -1) {
          setState(() => widget.blocks.removeAt(index));
        }
        _showSnack(blockOperationToast(action, block));
        return;
      case ScriptBlockMenuAction.duplicate:
        if (index != -1) {
          setState(() => widget.blocks.insert(index + 1, block.clone()));
        }
        return;
      case ScriptBlockMenuAction.paste:
        // Вставка скопированных блоков сразу после текущего блока.
        _pasteFromClipboard(
          insertIndex: index == -1 ? widget.blocks.length : index + 1,
        );
        return;
      case ScriptBlockMenuAction.delete:
        if (index != -1) {
          setState(() => widget.blocks.removeAt(index));
        }
        return;
    }
  }

  void _pasteFromClipboard({required int insertIndex}) {
    final clipboardItem = ref.read(visualScriptClipboardProvider);
    if (clipboardItem == null) {
      _showSnack(tr('Буфер обмена пуст'));
      return;
    }
    if (!widget.allowEventBlocks &&
        clipboardItem.blocks.any((block) => block is EventBlock)) {
      _showSnack(tr('Сюда нельзя вставить событие'));
      return;
    }

    final cloned = cloneBlocks(clipboardItem.blocks);
    final safeIndex = insertIndex.clamp(0, widget.blocks.length).toInt();
    setState(() {
      widget.blocks.insertAll(safeIndex, cloned);
    });
    if (clipboardItem.operation == 'cut') {
      ref.read(visualScriptClipboardProvider.notifier).state = null;
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    // Без цвета фона: раньше зелёный/оранжевый/красный ничего не значили и
    // перекрикивали тему редактора.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
