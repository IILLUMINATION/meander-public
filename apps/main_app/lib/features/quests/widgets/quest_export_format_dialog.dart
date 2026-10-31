import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:flutter/material.dart';

/// Диалог выбора формата нод для `.mnd`. По умолчанию — новый per-node.
Future<QuestArchiveNodesFormat?> showQuestExportFormatDialog(
  BuildContext context,
) {
  var selected = QuestArchiveNodesFormat.perNode;

  return showDialog<QuestArchiveNodesFormat>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Widget option({
          required QuestArchiveNodesFormat value,
          required String title,
          required String subtitle,
        }) {
          final isSelected = selected == value;
          return ListTile(
            onTap: () => setState(() => selected = value),
            leading: Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
            title: Text(title),
            subtitle: Text(subtitle),
          );
        }

        return AlertDialog(
          title: Text(tr('Формат экспорта')),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              option(
                value: QuestArchiveNodesFormat.perNode,
                title: tr('Новый формат (.mnd)'),
                subtitle: tr(
                  'nodes/index.json и nodes/<id>.json. Откроется в новом плеере.',
                ),
              ),
              option(
                value: QuestArchiveNodesFormat.legacy,
                title: tr('Legacy (.mnd)'),
                subtitle: tr(
                  'Единый nodes.json. Совместим со старыми плеерами и веб-версией.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: Text(tr('Экспортировать (.mnd)')),
            ),
          ],
        );
      },
    ),
  );
}
