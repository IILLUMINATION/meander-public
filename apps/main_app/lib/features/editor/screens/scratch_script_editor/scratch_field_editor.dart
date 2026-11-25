import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/audio_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/content_item_picker_model.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/content_item_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/function_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/table_path_picker.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/variable_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/watch_paths_picker_screen.dart';
import 'package:canvas_app/features/resources/screens/lua_inline_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

import 'scratch_block_view.dart';

typedef _StringBinding = ({String initial, ValueChanged<String> save});
typedef _Choice<T> = ({T value, String label, IconData? icon});

Future<bool> editScratchField({
  required BuildContext context,
  required String questId,
  required VisualScriptBlock block,
  required ScratchFieldKind kind,
}) async {
  switch (kind) {
    case ScratchFieldKind.eventType:
      final b = block as EventBlock;
      final current = b.eventType ?? EventType.onNodeEnter;
      final value = await _pick<EventType>(
        context,
        title: tr('Тип события'),
        selected: current,
        options: [
          for (final type in EventType.values)
            (value: type, label: _eventTypeLabel(type), icon: _eventIcon(type)),
        ],
      );
      if (value == null || !context.mounted) return false;
      b.eventType = value;
      return value != current;

    case ScratchFieldKind.eventFunction:
      final b = block as EventBlock;
      final current = b.functionName.trim().isEmpty
          ? 'main'
          : b.functionName.trim();
      final value = await _pick<String>(
        context,
        title: tr('Выбор функции'),
        selected: current,
        options: [
          (value: 'main', label: 'main', icon: Icons.functions_rounded),
          if (current != 'main')
            (value: current, label: current, icon: Icons.check_rounded),
          (
            value: '__create__',
            label: tr('Новая функция'),
            icon: Icons.add_rounded,
          ),
        ],
      );
      if (value == null || !context.mounted) return false;
      final name = value == '__create__'
          ? await _readText(
              context,
              title: tr('Новая функция'),
              initial: '',
              hint: 'checkVisibility',
            )
          : value;
      if (name == null || name.trim().isEmpty || !context.mounted) return false;
      final next = name.trim();
      final changed = next != b.functionName;
      b.functionName = next;
      return changed;

    case ScratchFieldKind.watchPaths:
      final b = block as EventBlock;
      final result = await Navigator.push<List<String>>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              WatchPathsPickerScreen(questId: questId, initial: b.watchPaths),
        ),
      );
      if (result == null || !context.mounted) return false;
      final changed = !listEquals(result, b.watchPaths);
      b.watchPaths = result;
      return changed;

    case ScratchFieldKind.expression:
      final binding = _stringBinding(block);
      if (binding == null) return false;
      return _expression(
        context,
        questId: questId,
        initial: binding.initial,
        onSave: binding.save,
      );

    case ScratchFieldKind.templateExpression:
      final b = block as SetImageBlock;
      return _expression(
        context,
        questId: questId,
        initial: b.source,
        onSave: (value) => b.source = value,
        isTemplate: true,
      );

    case ScratchFieldKind.variable:
      final binding = _variableBinding(block);
      if (binding == null) return false;
      return _variable(
        context,
        questId: questId,
        initial: binding.initial,
        onSave: binding.save,
      );

    case ScratchFieldKind.node:
      final b = block as GoToNodeBlock;
      final previousId = b.targetNodeId;
      final previousName = b.targetNodeName;
      final result = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => NodeSelectionScreen(
            questId: questId,
            selectedNodeId: b.targetNodeId,
            allowCreate: true,
          ),
        ),
      );
      if (result == null || !context.mounted) return false;
      await _updateNodeName(context, questId, b, result);
      return result != previousId || b.targetNodeName != previousName;

    case ScratchFieldKind.contentItem:
      final String? previousId;
      final String previousName;
      final void Function(String, String) save;
      final List<String>? allowedTypes;
      if (block is SetImageBlock) {
        previousId = block.itemId;
        previousName = block.itemName;
        allowedTypes = const ['image'];
        save = (id, name) {
          block.itemId = id;
          block.itemName = name;
        };
      } else {
        final b = block as SetVisibleBlock;
        previousId = b.itemId;
        previousName = b.itemName;
        allowedTypes = null;
        save = (id, name) {
          b.itemId = id;
          b.itemName = name;
        };
      }
      final result = await Navigator.push<ContentItemChoice>(
        context,
        MaterialPageRoute(
          builder: (_) => ContentItemSelectionScreen(
            questId: questId,
            selectedItemId: previousId,
            allowedTypes: allowedTypes,
          ),
        ),
      );
      if (result == null || !context.mounted) return false;
      final location = result.location;
      final name = location.isEmpty || location == result.label
          ? result.label
          : '${result.label} · $location';
      final changed = result.item.id != previousId || name != previousName;
      save(result.item.id, name);
      return changed;

    case ScratchFieldKind.audio:
      final String? previousId;
      final String previousName;
      final String? selectedId;
      final void Function(String, String) save;
      if (block is PlaySoundBlock) {
        previousId = block.audioId;
        previousName = block.audioName;
        selectedId = block.audioId;
        save = (id, name) {
          block.audioId = id;
          block.audioName = name;
        };
      } else if (block is PlayMusicBlock) {
        previousId = block.audioId;
        previousName = block.audioName;
        selectedId = block.audioId;
        save = (id, name) {
          block.audioId = id;
          block.audioName = name;
        };
      } else {
        final b = block as StopSoundBlock;
        previousId = b.audioId;
        previousName = b.audioName;
        selectedId = b.audioId;
        save = (id, name) {
          b.audioId = id;
          b.audioName = name;
        };
      }
      final result = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => AudioSelectionScreen(
            questId: questId,
            selectedAudioId: selectedId,
          ),
        ),
      );
      if (result == null || !context.mounted) return false;
      final name = await _audioName(questId, result);
      if (!context.mounted) return false;
      save(result, name);
      return result != previousId || name != previousName;

    case ScratchFieldKind.script:
      final b = block as CallScriptBlock;
      final result = await Navigator.push<SelectableResource>(
        context,
        MaterialPageRoute(
          builder: (_) => ResourceSelectionScreen(
            questId: questId,
            allowedTypes: const ['script'],
          ),
        ),
      );
      if (result == null || !context.mounted) return false;
      final id = result.name.replaceAll('.json', '');
      final changed = id != b.scriptId || result.friendlyName != b.scriptName;
      b.scriptId = id;
      b.scriptName = result.friendlyName;
      return changed;

    case ScratchFieldKind.function:
      final b = block as CallFunctionBlock;
      final result = await Navigator.push<SelectableFunction>(
        context,
        MaterialPageRoute(
          builder: (_) => FunctionSelectionScreen(questId: questId),
        ),
      );
      if (result == null || !context.mounted) return false;
      final changed =
          result.scriptId != b.functionId ||
          result.functionEntry != b.functionEntry ||
          result.displayName != b.functionName;
      b.functionId = result.scriptId;
      b.functionEntry = result.functionEntry;
      b.functionName = result.displayName;
      return changed;

    case ScratchFieldKind.functionEntry:
      final b = block as CallFunctionBlock;
      return _text(
        context,
        title: tr('Точка входа'),
        initial: b.functionEntry,
        hint: 'main',
        onSave: (value) => b.functionEntry = value,
      );

    case ScratchFieldKind.luaSource:
      final b = block as CallLuaBlock;
      final current = b.scriptId != null;
      return _choose<bool>(
        context,
        title: tr('Источник кода'),
        current: current,
        options: [
          (value: true, label: tr('Из файла'), icon: Icons.description_rounded),
          (value: false, label: 'Inline', icon: Icons.edit_rounded),
        ],
        onSave: (isFile) {
          if (isFile) {
            b.scriptId ??= '';
            if (b.scriptName.trim().isEmpty) b.scriptName = tr('Выберите .lua');
          } else {
            b.scriptId = null;
          }
        },
      );

    case ScratchFieldKind.luaScript:
      final b = block as CallLuaBlock;
      if (b.scriptId != null) {
        final result = await Navigator.push<SelectableResource>(
          context,
          MaterialPageRoute(
            builder: (_) => ResourceSelectionScreen(
              questId: questId,
              allowedTypes: const ['lua'],
            ),
          ),
        );
        if (result == null || !context.mounted) return false;
        final changed =
            result.name != b.scriptId || result.friendlyName != b.scriptName;
        b.scriptId = result.name;
        b.scriptName = result.friendlyName;
        return changed;
      }
      final result = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => LuaInlineEditorScreen(initialText: b.script),
        ),
      );
      if (result == null || !context.mounted) return false;
      final changed = result != b.script;
      b.script = result;
      return changed;

    case ScratchFieldKind.luaFunction:
      final b = block as CallLuaBlock;
      final result = await _readText(
        context,
        title: tr('Имя Lua-функции'),
        initial: b.function,
        hint: 'start',
      );
      if (result == null || !context.mounted) return false;
      final next = result.trim();
      if (next.isEmpty || next == b.function) return false;
      b.function = next;
      return true;

    case ScratchFieldKind.table:
      final b = block as ForEachBlock;
      final result = await _pickTableName(context, questId, b.tableName);
      if (result == null || !context.mounted) return false;
      final changed = result != b.tableName;
      b.tableName = result;
      return changed;

    case ScratchFieldKind.tableVariable:
      final b = block as TableOperationBlock;
      return _variable(
        context,
        questId: questId,
        initial: b.tableName,
        onSave: (value) => b.tableName = value,
        pickerMode: true,
      );

    case ScratchFieldKind.tablePath:
      final b = block as TableOperationBlock;
      final result = await pickTablePath(
        context,
        questId: questId,
        tableName: b.tableName,
        operation: b.operation,
        initial: b.path,
      );
      if (result == null || !context.mounted) return false;
      final changed = result != b.path;
      b.path = result;
      return changed;

    case ScratchFieldKind.tableOperation:
      final b = block as TableOperationBlock;
      return _choose<TableOperation>(
        context,
        title: tr('Операция'),
        current: b.operation,
        options: [
          for (final operation in TableOperation.values)
            (
              value: operation,
              label: operation.label,
              icon: _tableIcon(operation),
            ),
        ],
        onSave: (value) => b.operation = value,
      );

    case ScratchFieldKind.saveOperation:
      final b = block as SaveOperationBlock;
      return _choose<SaveOperation>(
        context,
        title: tr('Операция'),
        current: b.operation,
        options: [
          (
            value: SaveOperation.save,
            label: tr('Сохранить'),
            icon: Icons.save_rounded,
          ),
          (
            value: SaveOperation.open,
            label: tr('Открыть'),
            icon: Icons.folder_open_rounded,
          ),
          (
            value: SaveOperation.load,
            label: tr('Загрузить'),
            icon: Icons.download_rounded,
          ),
          (
            value: SaveOperation.delete,
            label: tr('Удалить'),
            icon: Icons.delete_outline_rounded,
          ),
        ],
        onSave: (value) => b.operation = value,
      );

    case ScratchFieldKind.visibilityMode:
      final b = block as SetVisibleBlock;
      return _choose<String>(
        context,
        title: tr('Действие'),
        current: b.mode,
        options: _modeOptions(includeRemove: true),
        onSave: (value) => b.mode = value,
      );

    case ScratchFieldKind.panelMode:
      final b = block as SetTopPanelBlock;
      return _choose<String>(
        context,
        title: tr('Действие'),
        current: b.mode,
        options: _modeOptions(includeRemove: false),
        onSave: (value) => b.mode = value,
      );

    case ScratchFieldKind.volumeTarget:
      final b = block as SetVolumeBlock;
      return _choose<String>(
        context,
        title: tr('Цель'),
        current: b.target,
        options: [
          (
            value: 'tagAudio',
            label: tr('Музыка главы'),
            icon: Icons.library_music_rounded,
          ),
          (
            value: 'contentAudio',
            label: tr('Звуки ноды'),
            icon: Icons.graphic_eq_rounded,
          ),
        ],
        onSave: (value) => b.target = value,
      );

    case ScratchFieldKind.volume:
      final double initial;
      final ValueChanged<double> save;
      if (block is SetVolumeBlock) {
        initial = block.volume;
        save = (value) => block.volume = value;
      } else if (block is PlaySoundBlock) {
        initial = block.volume;
        save = (value) => block.volume = value;
      } else {
        final b = block as PlayMusicBlock;
        initial = b.volume;
        save = (value) => b.volume = value;
      }
      return _slider(
        context,
        title: tr('Громкость'),
        initial: initial,
        min: 0,
        max: 1,
        divisions: 20,
        onSave: save,
      );

    case ScratchFieldKind.blurTarget:
      final b = block as SetBlurBlock;
      return _choose<String>(
        context,
        title: tr('Цель'),
        current: b.target,
        options: [
          (value: 'node', label: tr('Нода'), icon: Icons.crop_square_rounded),
          (
            value: 'tag',
            label: tr('Глава'),
            icon: Icons.bookmark_outline_rounded,
          ),
          (value: 'quest', label: tr('Квест'), icon: Icons.public_rounded),
        ],
        onSave: (value) => b.target = value,
      );

    case ScratchFieldKind.blur:
      final b = block as SetBlurBlock;
      return _slider(
        context,
        title: tr('Размытие'),
        initial: b.blurValue,
        min: 0,
        max: 30,
        divisions: 30,
        onSave: (value) => b.blurValue = value,
      );

    case ScratchFieldKind.stopSoundTarget:
      final b = block as StopSoundBlock;
      final result = await _pick<String>(
        context,
        title: tr('Цель'),
        selected: b.target,
        options: [
          (
            value: 'all',
            label: tr('Все звуки'),
            icon: Icons.volume_off_rounded,
          ),
          (
            value: 'specific',
            label: tr('Конкретный звук'),
            icon: Icons.audiotrack_rounded,
          ),
        ],
      );
      if (result == null || !context.mounted) return false;
      final allName = tr('Все звуки');
      final changed =
          result != b.target ||
          (result == 'all' && (b.audioId != null || b.audioName != allName));
      b.target = result;
      if (result == 'all') {
        b.audioId = null;
        b.audioName = allName;
      }
      return changed;

    case ScratchFieldKind.pauseTarget:
      final b = block as PauseResumeBlock;
      return _choose<String>(
        context,
        title: tr('Цель'),
        current: b.target,
        options: [
          (value: 'all', label: tr('Всё'), icon: Icons.all_inclusive_rounded),
          (value: 'music', label: tr('Музыка'), icon: Icons.music_note_rounded),
          (value: 'sound', label: tr('Звуки'), icon: Icons.volume_up_rounded),
        ],
        onSave: (value) => b.target = value,
      );

    case ScratchFieldKind.pauseAction:
      final b = block as PauseResumeBlock;
      return _choose<String>(
        context,
        title: tr('Действие'),
        current: b.action,
        options: [
          (
            value: 'toggle',
            label: tr('Переключить'),
            icon: Icons.swap_horiz_rounded,
          ),
          (value: 'pause', label: tr('Пауза'), icon: Icons.pause_rounded),
          (
            value: 'resume',
            label: tr('Продолжить'),
            icon: Icons.play_arrow_rounded,
          ),
        ],
        onSave: (value) => b.action = value,
      );

    case ScratchFieldKind.httpMethod:
      final b = block as HttpRequestBlock;
      return _choose<String>(
        context,
        title: tr('Метод'),
        current: b.method,
        options: [
          for (final method in [
            'GET',
            'POST',
            'PUT',
            'DELETE',
            'PATCH',
            'HEAD',
          ])
            (value: method, label: method, icon: Icons.http_rounded),
        ],
        onSave: (value) => b.method = value,
      );

    case ScratchFieldKind.httpUrl:
      final b = block as HttpRequestBlock;
      return _expression(
        context,
        questId: questId,
        initial: b.url,
        onSave: (value) => b.url = value,
      );

    case ScratchFieldKind.httpBody:
      final b = block as HttpRequestBlock;
      return _expression(
        context,
        questId: questId,
        initial: b.body,
        onSave: (value) => b.body = value,
      );

    case ScratchFieldKind.httpHeaders:
      final b = block as HttpRequestBlock;
      return _expression(
        context,
        questId: questId,
        initial: b.headers,
        onSave: (value) => b.headers = value,
      );

    case ScratchFieldKind.httpResponseVariable:
      final b = block as HttpRequestBlock;
      return _variable(
        context,
        questId: questId,
        initial: b.targetVariable,
        onSave: (value) => b.targetVariable = value,
      );

    case ScratchFieldKind.httpStatusVariable:
      final b = block as HttpRequestBlock;
      return _variable(
        context,
        questId: questId,
        initial: b.statusVariable,
        onSave: (value) => b.statusVariable = value,
      );

    case ScratchFieldKind.musicLoop:
      final b = block as PlayMusicBlock;
      return _choose<bool>(
        context,
        title: tr('Зациклить'),
        current: b.loop,
        options: _yesNoOptions(),
        onSave: (value) => b.loop = value,
      );

    case ScratchFieldKind.musicGlobal:
      final b = block as PlayMusicBlock;
      return _choose<bool>(
        context,
        title: tr('Глобально'),
        current: b.global,
        options: _yesNoOptions(),
        onSave: (value) => b.global = value,
      );

    case ScratchFieldKind.whileSettings:
      final field = await _pick<ScratchFieldKind>(
        context,
        title: tr('Параметры цикла'),
        options: [
          (
            value: ScratchFieldKind.loopCount,
            label: tr('Сколько раз'),
            icon: Icons.repeat_rounded,
          ),
          (
            value: ScratchFieldKind.loopFrom,
            label: tr('Диапазон: от'),
            icon: Icons.swap_vert_rounded,
          ),
          (
            value: ScratchFieldKind.loopTo,
            label: tr('Диапазон: до'),
            icon: Icons.swap_vert_rounded,
          ),
          (
            value: ScratchFieldKind.loopStep,
            label: tr('Диапазон: шаг'),
            icon: Icons.swap_vert_rounded,
          ),
          (
            value: ScratchFieldKind.expression,
            label: tr('Условие пока'),
            icon: Icons.rule_rounded,
          ),
          (
            value: ScratchFieldKind.loopVariable,
            label: tr('Счётчик'),
            icon: Icons.tag_rounded,
          ),
          (
            value: ScratchFieldKind.maxIterations,
            label: tr('Макс. итераций'),
            icon: Icons.shield_outlined,
          ),
        ],
      );
      if (field == null || !context.mounted) return false;
      return editScratchField(
        context: context,
        questId: questId,
        block: block,
        kind: field,
      );

    case ScratchFieldKind.loopCount:
      final b = block as WhileBlock;
      return _expression(
        context,
        questId: questId,
        title: tr('Сколько раз повторить?'),
        initial: b.count,
        onSave: (value) => b.count = value,
      );

    case ScratchFieldKind.loopFrom:
      final b = block as WhileBlock;
      return _expression(
        context,
        questId: questId,
        title: tr('Диапазон: от'),
        initial: b.from,
        onSave: (value) => b.from = value,
      );

    case ScratchFieldKind.loopTo:
      final b = block as WhileBlock;
      return _expression(
        context,
        questId: questId,
        title: tr('Диапазон: до'),
        initial: b.to,
        onSave: (value) => b.to = value,
      );

    case ScratchFieldKind.loopStep:
      final b = block as WhileBlock;
      return _expression(
        context,
        questId: questId,
        title: tr('Диапазон: шаг'),
        initial: b.step,
        onSave: (value) => b.step = value,
      );

    case ScratchFieldKind.loopVariable:
      final b = block as WhileBlock;
      return _variable(
        context,
        questId: questId,
        initial: b.loopVar,
        onSave: (value) => b.loopVar = value,
      );

    case ScratchFieldKind.maxIterations:
      final b = block as WhileBlock;
      final previous = b.maxIterations;
      await _expression(
        context,
        questId: questId,
        title: tr('Макс. итераций (защита от бесконечного цикла)'),
        initial: previous.toString(),
        onSave: (value) {
          final parsed = int.tryParse(value.trim());
          if (parsed != null && parsed > 0) b.maxIterations = parsed;
        },
      );
      return b.maxIterations != previous;

    case ScratchFieldKind.foreachPrefix:
      final b = block as ForEachBlock;
      return _variable(
        context,
        questId: questId,
        initial: b.varPrefix,
        onSave: (value) => b.varPrefix = value,
      );

    case ScratchFieldKind.foreachIndex:
      final b = block as ForEachBlock;
      return _variable(
        context,
        questId: questId,
        initial: b.indexVariable,
        onSave: (value) => b.indexVariable = value,
      );

    case ScratchFieldKind.comment:
      final b = block as CommentBlock;
      return _text(
        context,
        title: tr('Комментарий'),
        initial: b.text,
        multiline: true,
        onSave: (value) => b.text = value,
      );
  }
}

_StringBinding? _stringBinding(VisualScriptBlock block) => switch (block) {
  ConditionBlock b => (
    initial: b.expression,
    save: (value) => b.expression = value,
  ),
  AssignVariableBlock b => (initial: b.value, save: (value) => b.value = value),
  DelayBlock b => (
    initial: b.expression,
    save: (value) => b.expression = value,
  ),
  CrossfadeBlock b => (
    initial: b.durationExpression,
    save: (value) => b.durationExpression = value,
  ),
  OpenLinkBlock b => (initial: b.url, save: (value) => b.url = value),
  TableOperationBlock b => (initial: b.value, save: (value) => b.value = value),
  WhileBlock b => (
    initial: b.expression,
    save: (value) => b.expression = value,
  ),
  _ => null,
};

_StringBinding? _variableBinding(VisualScriptBlock block) => switch (block) {
  AssignVariableBlock b => (
    initial: b.variableName,
    save: (value) => b.variableName = value,
  ),
  TableOperationBlock b => (
    initial: b.targetVariable,
    save: (value) => b.targetVariable = value,
  ),
  _ => null,
};

Future<bool> _expression(
  BuildContext context, {
  required String questId,
  required String initial,
  required ValueChanged<String> onSave,
  String? title,
  bool isTemplate = false,
}) async {
  final result = await Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => ExpressionEditorScreen(
        initialValue: initial,
        questId: questId,
        title: title,
        isTemplate: isTemplate,
      ),
    ),
  );
  if (result == null || !context.mounted) return false;
  final changed = result != initial;
  onSave(result);
  return changed;
}

Future<bool> _variable(
  BuildContext context, {
  required String questId,
  required String initial,
  required ValueChanged<String> onSave,
  bool pickerMode = false,
}) async {
  final result = await Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => VariableSelectionScreen(
        questId: questId,
        selectedVariable: initial,
        pickerMode: pickerMode,
      ),
    ),
  );
  if (result == null || !context.mounted) return false;
  final changed = result != initial;
  onSave(result);
  return changed;
}

Future<T?> _pick<T>(
  BuildContext context, {
  required List<_Choice<T>> options,
  String? title,
  T? selected,
}) {
  return showAdaptiveSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    scrollable: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: Theme.of(
                    ctx,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final option in options)
                  ListTile(
                    leading: option.icon == null
                        ? null
                        : Icon(
                            option.icon,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                    title: Text(option.label),
                    trailing: option.value == selected
                        ? Icon(
                            Icons.check_rounded,
                            color: Theme.of(ctx).colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.pop(ctx, option.value),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<bool> _choose<T>(
  BuildContext context, {
  required String title,
  required T current,
  required List<_Choice<T>> options,
  required ValueChanged<T> onSave,
}) async {
  final result = await _pick<T>(
    context,
    title: title,
    selected: current,
    options: options,
  );
  if (result == null || !context.mounted) return false;
  final changed = result != current;
  onSave(result);
  return changed;
}

Future<bool> _text(
  BuildContext context, {
  required String title,
  required String initial,
  required ValueChanged<String> onSave,
  String? hint,
  bool multiline = false,
}) async {
  final result = await _readText(
    context,
    title: title,
    initial: initial,
    hint: hint,
    multiline: multiline,
  );
  if (result == null || !context.mounted) return false;
  final changed = result != initial;
  onSave(result);
  return changed;
}

Future<String?> _readText(
  BuildContext context, {
  required String title,
  required String initial,
  String? hint,
  bool multiline = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showAppDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: multiline ? 6 : 1,
        keyboardType: multiline ? TextInputType.multiline : TextInputType.text,
        decoration: InputDecoration(
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('Отмена')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(tr('Готово')),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

Future<bool> _slider(
  BuildContext context, {
  required String title,
  required double initial,
  required double min,
  required double max,
  required int divisions,
  required ValueChanged<double> onSave,
}) async {
  var draft = initial.clamp(min, max).toDouble();
  final result = await showAdaptiveSheet<double>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: Theme.of(
                  ctx,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(draft.toStringAsFixed(2)),
              Slider(
                value: draft,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: (value) => setSheetState(() => draft = value),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, draft),
                child: Text(tr('Готово')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (result == null || !context.mounted) return false;
  final changed = result != initial;
  onSave(result);
  return changed;
}

Future<String?> _pickTableName(
  BuildContext context,
  String questId,
  String current,
) async {
  final names = <String>[];
  try {
    final path = QuestPaths.config(questId);
    if (await FileStorage.exists(path)) {
      final config = await FileStorage.readJsonFile(path);
      for (final table in config['tables'] as List<dynamic>? ?? const []) {
        if (table is Map && table['name'] is String) {
          final name = table['name'] as String;
          if (name.isNotEmpty && !names.contains(name)) names.add(name);
        }
      }
    }
  } catch (_) {}
  if (!context.mounted) return null;
  final result = await _pick<String>(
    context,
    title: tr('Выберите таблицу'),
    selected: current,
    options: [
      for (final name in names)
        (value: name, label: name, icon: Icons.dataset_rounded),
      (
        value: '__manual__',
        label: tr('Ввести вручную…'),
        icon: Icons.edit_rounded,
      ),
    ],
  );
  if (result == null || !context.mounted) return null;
  if (result != '__manual__') return result;
  return _readText(
    context,
    title: tr('Имя таблицы'),
    initial: current,
    hint: tr('имя таблицы'),
  );
}

Future<void> _updateNodeName(
  BuildContext context,
  String questId,
  GoToNodeBlock block,
  String nodeId,
) async {
  var name = 'ID: ${nodeId.length > 8 ? nodeId.substring(0, 8) : nodeId}…';
  try {
    final data = await QuestNodesStore.read(questId);
    for (final raw in data['nodes'] as List<dynamic>? ?? const []) {
      if (raw is Map && raw['id']?.toString() == nodeId) {
        name = raw['title'] as String? ?? tr('Нода');
        break;
      }
    }
  } catch (_) {}
  if (!context.mounted) return;
  block.targetNodeId = nodeId;
  block.targetNodeName = name;
}

Future<String> _audioName(String questId, String audioId) async {
  var name = 'ID: ${audioId.length > 8 ? audioId.substring(0, 8) : audioId}…';
  try {
    final path = QuestPaths.metadata(questId);
    if (await FileStorage.exists(path)) {
      final metadata = await FileStorage.readJsonFile(path);
      final value = metadata[audioId];
      if (value is String) {
        name = value;
      } else if (value is Map && value['name'] is String) {
        name = value['name'] as String;
      }
    }
  } catch (_) {}
  return name;
}

List<_Choice<String>> _modeOptions({required bool includeRemove}) => [
  (value: 'hide', label: tr('Скрыть'), icon: Icons.visibility_off_rounded),
  if (includeRemove)
    (value: 'remove', label: tr('Убрать'), icon: Icons.remove_rounded),
  (value: 'show', label: tr('Показать'), icon: Icons.visibility_rounded),
  (value: 'toggle', label: tr('Переключить'), icon: Icons.swap_horiz_rounded),
];

List<_Choice<bool>> _yesNoOptions() => [
  (value: true, label: tr('Да'), icon: Icons.check_rounded),
  (value: false, label: tr('Нет'), icon: Icons.close_rounded),
];

String _eventTypeLabel(EventType type) => switch (type) {
  EventType.onQuestStart => tr('При запуске квеста'),
  EventType.onNodeEnter => tr('При запуске ноды'),
  EventType.onPress => tr('При нажатии'),
  EventType.onContentAppear => tr('При появлении контента'),
  EventType.onDataChange => tr('При изменении данных'),
  EventType.function => tr('Функция'),
};

IconData _eventIcon(EventType type) => switch (type) {
  EventType.onQuestStart => Icons.play_circle_outline_rounded,
  EventType.onNodeEnter => Icons.login_rounded,
  EventType.onPress => Icons.touch_app_rounded,
  EventType.onContentAppear => Icons.visibility_rounded,
  EventType.onDataChange => Icons.change_circle_rounded,
  EventType.function => Icons.functions_rounded,
};

IconData _tableIcon(TableOperation operation) => switch (operation) {
  TableOperation.get => Icons.south_west_rounded,
  TableOperation.set => Icons.save_rounded,
  TableOperation.add => Icons.add_rounded,
  TableOperation.remove => Icons.remove_rounded,
  TableOperation.removeValue => Icons.highlight_remove_rounded,
  TableOperation.clear => Icons.delete_sweep_rounded,
  TableOperation.contains => Icons.search_rounded,
};
