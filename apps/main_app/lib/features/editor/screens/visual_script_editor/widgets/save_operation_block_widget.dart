import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';

// ============================================================================
//  SAVE OPERATION BLOCK — сохранения квеста из сценария
// ============================================================================

class SaveOperationBlockWidget extends StatefulWidget {
  final SaveOperationBlock block;
  final String questId;
  final ValueChanged<ScriptBlockMenuAction>? onMenuAction;
  final VoidCallback? onDelete;

  const SaveOperationBlockWidget({
    super.key,
    required this.block,
    required this.questId,
    this.onMenuAction,
    this.onDelete,
  });

  @override
  State<SaveOperationBlockWidget> createState() =>
      _SaveOperationBlockWidgetState();
}

class _SaveOperationBlockWidgetState extends State<SaveOperationBlockWidget> {
  String _label(SaveOperation op) => switch (op) {
    SaveOperation.save => tr('Создать сохранение'),
    SaveOperation.open => tr('Открыть сохранения'),
    SaveOperation.load => tr('Загрузить сохранение'),
    SaveOperation.delete => tr('Удалить сохранение'),
  };

  IconData _icon(SaveOperation op) => switch (op) {
    SaveOperation.save => Icons.save_rounded,
    SaveOperation.open => Icons.bookmarks_rounded,
    SaveOperation.load => Icons.restore_rounded,
    SaveOperation.delete => Icons.delete_outline_rounded,
  };

  Future<void> _pickOperation() async {
    final scheme = Theme.of(context).colorScheme;
    final result = await showAdaptiveSheet<SaveOperation>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final op in SaveOperation.values)
              ListTile(
                leading: Icon(
                  _icon(op),
                  color: op == widget.block.operation
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                title: Text(_label(op)),
                selected: op == widget.block.operation,
                onTap: () => Navigator.pop(ctx, op),
              ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() => widget.block.operation = result);
    }
  }

  Future<void> _editSlot() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ExpressionEditorScreen(
          initialValue: widget.block.slotName,
          questId: widget.questId,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() => widget.block.slotName = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final op = widget.block.operation;
    final needsSlot = op != SaveOperation.open;
    return ScriptBlockShell(
      category: BlockCategory.action,
      title: tr('Сохранения'),
      icon: _icon(op),
      onDelete: widget.onDelete,
      onMenuAction: widget.onMenuAction,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ScriptFieldTile(
            label: tr('Действие'),
            value: _label(op),
            placeholder: tr('выберите действие'),
            icon: _icon(op),
            onTap: _pickOperation,
          ),
          if (needsSlot)
            ScriptFieldTile(
              label: tr('Слот'),
              value: widget.block.slotName,
              placeholder: op == SaveOperation.save
                  ? tr('пусто — имя по умолчанию')
                  : tr('имя слота или {переменная}'),
              icon: Icons.bookmark_outline_rounded,
              onTap: _editSlot,
              hint: tr('Имя можно собрать формулой: «слот {герой}».'),
            ),
        ],
      ),
    );
  }
}
