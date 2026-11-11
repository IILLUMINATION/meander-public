import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:flutter/material.dart';

// ============================================================================
//  SET TOP PANEL BLOCK — скрыть или вернуть верхнюю панель игры
// ============================================================================

class SetTopPanelBlockWidget extends StatefulWidget {
  final SetTopPanelBlock block;
  final ValueChanged<ScriptBlockMenuAction>? onMenuAction;
  final VoidCallback? onDelete;

  const SetTopPanelBlockWidget({
    super.key,
    required this.block,
    this.onMenuAction,
    this.onDelete,
  });

  @override
  State<SetTopPanelBlockWidget> createState() => _SetTopPanelBlockWidgetState();
}

class _SetTopPanelBlockWidgetState extends State<SetTopPanelBlockWidget> {
  /// Только три режима: у панели нет «убрать с сохранением места», и автору
  /// незачем выбирать между двумя способами спрятать одно и то же.
  static List<({String value, String label, IconData? icon})> get _modes => [
    (value: 'hide', label: tr('Скрыть'), icon: null),
    (value: 'show', label: tr('Показать'), icon: null),
    (value: 'toggle', label: tr('Переключить'), icon: null),
  ];

  IconData get _modeIcon => switch (widget.block.mode) {
    'show' => Icons.visibility_rounded,
    'toggle' => Icons.swap_horiz_rounded,
    _ => Icons.visibility_off_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return ScriptBlockShell(
      category: BlockCategory.action,
      title: tr('Верхняя панель'),
      icon: _modeIcon,
      onDelete: widget.onDelete,
      onMenuAction: widget.onMenuAction,
      child: ScriptFieldsGroup(
        children: [
          ScriptFieldSegmented<String>(
            label: tr('Действие'),
            icon: _modeIcon,
            value: widget.block.mode,
            options: _modes,
            onChanged: (v) => setState(() => widget.block.mode = v),
          ),
        ],
      ),
    );
  }
}