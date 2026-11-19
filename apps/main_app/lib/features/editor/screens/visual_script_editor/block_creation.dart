import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/shared/script_contracts.dart';

/// Создать пустой блок по имени типа из палитры (`BlockPaletteEntry.name`).
///
/// Одна точка на оба редактора скриптов: палитра отдаёт имя типа из ядра,
/// и если новый канвас заведёт свой switch, очередной тип блока появится в
/// одном редакторе и молча превратится в «Присвоить» в другом.
VisualScriptBlock createBlockOfType(String blockType) {
  switch (blockType) {
    case BlockTypes.assignVariable:
      return AssignVariableBlock();
    case BlockTypes.condition:
      return ConditionBlock();
    case BlockTypes.goToNode:
      return GoToNodeBlock();
    case BlockTypes.setVolume:
      return SetVolumeBlock();
    case BlockTypes.setBlur:
      return SetBlurBlock();
    case BlockTypes.wait:
      return DelayBlock();
    case BlockTypes.callScript:
      return CallScriptBlock();
    case BlockTypes.callFunction:
      return CallFunctionBlock();
    case BlockTypes.callLua:
      return CallLuaBlock();
    case BlockTypes.tableOperation:
      return TableOperationBlock();
    case BlockTypes.setImage:
      return SetImageBlock();
    case BlockTypes.setVisible:
      return SetVisibleBlock();
    case BlockTypes.setTopPanel:
      return SetTopPanelBlock();
    case BlockTypes.playSound:
      return PlaySoundBlock();
    case BlockTypes.stopSound:
      return StopSoundBlock();
    case BlockTypes.playMusic:
      return PlayMusicBlock();
    case BlockTypes.stopMusic:
      return StopMusicBlock();
    case BlockTypes.pauseResume:
      return PauseResumeBlock();
    case BlockTypes.crossfade:
      return CrossfadeBlock();
    case BlockTypes.saveOperation:
      return SaveOperationBlock();
    case BlockTypes.openLink:
      return OpenLinkBlock();
    case BlockTypes.httpRequest:
      return HttpRequestBlock();
    case BlockTypes.comment:
      return CommentBlock();
    case BlockTypes.forEach:
      return ForEachBlock();
    case BlockTypes.whileLoop:
      return WhileBlock();
    default:
      return AssignVariableBlock(variableName: 'unknown');
  }
}