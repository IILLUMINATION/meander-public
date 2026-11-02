import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/assign_variable_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/call_script_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/call_function_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/call_lua_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/condition_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/crossfade_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/delay_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/event_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/go_to_node_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/http_request_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/open_link_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/save_operation_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/pause_resume_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/play_music_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/play_sound_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/set_blur_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/set_image_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/set_visible_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/set_volume_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/stop_music_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/stop_sound_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/for_each_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/while_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/comment_block_widget.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/table_operation_block_widget.dart';
import 'package:flutter/material.dart';

typedef OnBlockDrop =
    void Function(
      VisualScriptBlock droppedBlock,
      List<VisualScriptBlock> targetList,
    );

class BlockFactory extends StatelessWidget {
  final VisualScriptBlock block;
  final String questId;
  final VoidCallback? onDelete;
  final OnBlockDrop onBlockDrop;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  /// Действия контекстного меню (одиночный тап по блоку). Маршрутизируются
  /// в единый обработчик экрана, который умеет правильно копировать/вырезать
  /// именно этот блок и вставлять сразу после него.
  final ValueChanged<ScriptBlockMenuAction>? onMenuAction;

  const BlockFactory({
    super.key,
    required this.block,
    required this.questId,
    this.onDelete,
    required this.onBlockDrop,
    this.onDragUpdate,
    this.onDragStart,
    this.onDragEnd,
    this.onMenuAction,
  });

  @override
  Widget build(BuildContext context) {
    // Сам блок (без drag handle — он больше не используется).
    final blockWidget = _buildBlockWidget(context, isFeedback: false);

    // Feedback (то, что «летит» за пальцем при перетаскивании). Тень нужна,
    // чтобы карточка не сливалась со списком, над которым она висит.
    final feedbackWidget = LayoutBuilder(
      builder: (ctx, _) {
        return Opacity(
          opacity: 0.95,
          child: Material(
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 6,
            shadowColor: Colors.black.withValues(alpha: 0.45),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: _buildBlockWidget(ctx, isFeedback: true),
            ),
          ),
        );
      },
    );

    // Весь блок — это LongPressDraggable.  Долгое нажатие = «взять блок».
    // Обычный тап и тап по внутренним полям/кнопкам работают как раньше.
    return LongPressDraggable<VisualScriptBlock>(
      data: block,
      delay: const Duration(milliseconds: 150),
      hapticFeedbackOnStart: true,
      dragAnchorStrategy: childDragAnchorStrategy,
      feedback: feedbackWidget,
      onDragStarted: onDragStart,
      onDragUpdate: (details) => onDragUpdate?.call(details.globalPosition),
      onDragEnd: (_) => onDragEnd?.call(),
      onDraggableCanceled: (_, __) => onDragEnd?.call(),
      childWhenDragging: Opacity(opacity: 0.25, child: blockWidget),
      child: blockWidget,
    );
  }

  Widget _buildBlockWidget(BuildContext context, {bool isFeedback = false}) {
    final menu = isFeedback ? null : onMenuAction;
    switch (block) {
      case AssignVariableBlock _:
        return AssignVariableBlockWidget(
          block: block as AssignVariableBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case ConditionBlock _:
        return ConditionBlockWidget(
          block: block as ConditionBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
          onBlockDrop: onBlockDrop,
          onDragUpdate: onDragUpdate,
          onDragStart: onDragStart,
          onDragEnd: onDragEnd,
        );

      case EventBlock _:
        return EventBlockWidget(
          block: block as EventBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          // Без этого у события, попавшего в чужой список, не было своего
          // жеста, и тап по нему уходил вверх — к меню контейнера-родителя.
          onMenuAction: menu,
          onBlockDrop: onBlockDrop,
          onDragUpdate: onDragUpdate,
          onDragStart: onDragStart,
          onDragEnd: onDragEnd,
        );

      case CallScriptBlock _:
        return CallScriptBlockWidget(
          block: block as CallScriptBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case CallFunctionBlock _:
        return CallFunctionBlockWidget(
          block: block as CallFunctionBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case CallLuaBlock _:
        return CallLuaBlockWidget(
          block: block as CallLuaBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case SetVolumeBlock _:
        return SetVolumeBlockWidget(
          block: block as SetVolumeBlock,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case SetImageBlock _:
        return SetImageBlockWidget(
          block: block as SetImageBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case SetVisibleBlock _:
        return SetVisibleBlockWidget(
          block: block as SetVisibleBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case SetBlurBlock _:
        return SetBlurBlockWidget(
          block: block as SetBlurBlock,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case GoToNodeBlock _:
        return GoToNodeBlockWidget(
          block: block as GoToNodeBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case DelayBlock _:
        return DelayBlockWidget(
          block: block as DelayBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case TableOperationBlock _:
        // Вот здесь мы вызываем обновленный виджет
        return TableOperationBlockWidget(
          block: block as TableOperationBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case PlaySoundBlock _:
        return PlaySoundBlockWidget(
          block: block as PlaySoundBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case StopSoundBlock _:
        return StopSoundBlockWidget(
          block: block as StopSoundBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case PlayMusicBlock _:
        return PlayMusicBlockWidget(
          block: block as PlayMusicBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case StopMusicBlock _:
        return StopMusicBlockWidget(
          block: block as StopMusicBlock,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case PauseResumeBlock _:
        return PauseResumeBlockWidget(
          block: block as PauseResumeBlock,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case CrossfadeBlock _:
        return CrossfadeBlockWidget(
          block: block as CrossfadeBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
          onBlockDrop: onBlockDrop,
          onDragUpdate: onDragUpdate,
          onDragStart: onDragStart,
          onDragEnd: onDragEnd,
        );

      case SaveOperationBlock _:
        return SaveOperationBlockWidget(
          block: block as SaveOperationBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case OpenLinkBlock _:
        return OpenLinkBlockWidget(
          block: block as OpenLinkBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case HttpRequestBlock _:
        return HttpRequestBlockWidget(
          block: block as HttpRequestBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case CommentBlock _:
        return CommentBlockWidget(
          block: block as CommentBlock,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
        );

      case ForEachBlock _:
        return ForEachBlockWidget(
          block: block as ForEachBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
          onBlockDrop: onBlockDrop,
          onDragUpdate: onDragUpdate,
          onDragStart: onDragStart,
          onDragEnd: onDragEnd,
        );

      case WhileBlock _:
        return WhileBlockWidget(
          block: block as WhileBlock,
          questId: questId,
          onDelete: isFeedback ? null : onDelete,
          onMenuAction: menu,
          onBlockDrop: onBlockDrop,
          onDragUpdate: onDragUpdate,
          onDragStart: onDragStart,
          onDragEnd: onDragEnd,
        );

      case UnknownBlock _:
        final unknown = block as UnknownBlock;
        // Янтарь вне рампы категорий — иначе битый блок притворялся бы
        // «событием». Оттенок берётся по яркости темы: в тёмной теме
        // orange.shade900 был почти нечитаем на тёмном корпусе.
        final warn = Theme.of(context).brightness == Brightness.dark
            ? Colors.orange.shade300
            : Colors.orange.shade800;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: warn.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: warn.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 18, color: warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  trf(
                    'Неизвестный блок{p0} — создан другой версией. Данные сохранятся.',
                    {
                      'p0': unknown.rawType == null
                          ? ''
                          : ' (${unknown.rawType})',
                    },
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: warn,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!isFeedback && onDelete != null)
                GestureDetector(
                  onTap: onDelete,
                  child: Icon(Icons.close_rounded, size: 16, color: warn),
                ),
            ],
          ),
        );

      default:
        final scheme = Theme.of(context).colorScheme;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.error.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.error.withValues(alpha: 0.45)),
          ),
          child: Text(
            trf('Неизвестный блок: {p0}', {'p0': block.runtimeType}),
            style: TextStyle(fontSize: 12, color: scheme.onSurface),
          ),
        );
    }
  }
}
