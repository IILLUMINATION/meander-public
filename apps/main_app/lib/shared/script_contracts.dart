// ============================================================================
//  Единый реестр типов блоков визуальных скриптов.
//
//  Имена должны совпадать с реестром ядра (mnd-core/src/blocks/mod.rs,
//  доступен через listBlockTypes). Строковые литералы вне этого файла
//  запрещены: новый тип блока добавляется ОДИН раз здесь + в виджете.
//
//  Реестр путей квеста (бывший QuestPaths в этом файле) перенесён в
//  mnd_core: `package:mnd_core/utils/quest_paths.dart` (план 020-C6).
// ============================================================================

abstract final class BlockTypes {
  static const event = 'event';
  static const condition = 'condition';
  static const assignVariable = 'assign_variable';
  static const goToNode = 'go_to_node';
  static const callScript = 'call_script';
  static const callFunction = 'call_function';
  static const callLua = 'call_lua';
  static const tableOperation = 'table_operation';
  static const setImage = 'set_image';
  static const setVisible = 'set_visible';
  static const forEach = 'for_each';
  static const whileLoop = 'while';
  static const wait = 'wait';
  static const comment = 'comment';
  static const setVolume = 'set_volume';
  static const setBlur = 'set_blur';
  static const playSound = 'play_sound';
  static const stopSound = 'stop_sound';
  static const playMusic = 'play_music';
  static const stopMusic = 'stop_music';
  static const pauseResume = 'pause_resume';
  static const crossfade = 'crossfade';
  static const openLink = 'open_link';
  static const httpRequest = 'http_request';
  static const saveOperation = 'save_operation';
}
