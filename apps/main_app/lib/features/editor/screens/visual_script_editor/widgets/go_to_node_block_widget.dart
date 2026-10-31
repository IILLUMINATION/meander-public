import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:flutter/material.dart';

// ============================================================================
//  GO TO NODE BLOCK — «Перейти к ноде»
// ============================================================================

class GoToNodeBlockWidget extends StatefulWidget {
  final GoToNodeBlock block;
  final String questId;
  final ValueChanged<ScriptBlockMenuAction>? onMenuAction;
  final VoidCallback? onDelete;

  const GoToNodeBlockWidget({
    super.key,
    required this.block,
    required this.questId,
    this.onMenuAction,
    this.onDelete,
  });

  @override
  State<GoToNodeBlockWidget> createState() => _GoToNodeBlockWidgetState();
}

class _GoToNodeBlockWidgetState extends State<GoToNodeBlockWidget> {
  Future<void> _selectNode() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => NodeSelectionScreen(
          questId: widget.questId,
          selectedNodeId: widget.block.targetNodeId,
          allowCreate: true,
        ),
      ),
    );
    if (result != null && mounted) {
      await _updateNodeInfo(result);
    }
  }

  Future<void> _enterNodeIdManually() async {
    final newId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ExpressionEditorScreen(
          initialValue: widget.block.targetNodeId ?? '',
          questId: widget.questId,
        ),
      ),
    );
    if (newId != null && newId.isNotEmpty && mounted) {
      await _updateNodeInfo(newId);
    }
  }

  Future<void> _updateNodeInfo(String nodeId) async {
    try {
      final nodesData = await QuestNodesStore.read(widget.questId);
      final nodes = (nodesData['nodes'] as List<dynamic>? ?? []);
      final selectedNode = nodes.firstWhere(
        (node) => (node as Map<String, dynamic>)['id'] == nodeId,
        orElse: () => null,
      );
      if (!mounted) return;
      setState(() {
        widget.block.targetNodeId = nodeId;
        if (selectedNode != null) {
          widget.block.targetNodeName =
              (selectedNode as Map<String, dynamic>)['title'] as String? ??
              'Нода';
        } else {
          widget.block.targetNodeName =
              'ID: ${nodeId.substring(0, nodeId.length > 8 ? 8 : nodeId.length)}…';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        widget.block.targetNodeId = nodeId;
        widget.block.targetNodeName = 'ID: $nodeId';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasNode = widget.block.targetNodeId != null;
    return ScriptBlockShell(
      category: BlockCategory.action,
      title: tr('Перейти к ноде'),
      icon: Icons.navigation_rounded,
      onDelete: widget.onDelete,
      onMenuAction: widget.onMenuAction,
      child: ScriptFieldTile(
        label: tr('Целевая нода'),
        value: widget.block.targetNodeName,
        placeholder: tr('не выбрана'),
        icon: Icons.account_tree_outlined,
        onTap: _selectNode,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: tr('Ввести ID вручную'),
              onPressed: _enterNodeIdManually,
              icon: Icon(
                Icons.edit_outlined,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              visualDensity: VisualDensity.compact,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 2),
              child: Icon(
                hasNode ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 16,
                color: hasNode ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
