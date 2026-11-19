import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// В каком редакторе скриптов работает автор.
///
/// Оба редактора правят один и тот же файл скрипта (`scripts/<id>.json`):
/// старый — карточками в списке, новый — блоками на бесконечном канвасе, как
/// в Scratch. Выбор — личное предпочтение, поэтому он хранится на устройстве
/// и никуда не синхронизируется.
enum ScriptEditorMode {
  /// Классический список карточек: привычный, с инлайн-полями.
  classic,

  /// Канвас: зум, панорама, C-блоки, всё дерево видно целиком.
  canvas;

  static ScriptEditorMode parse(String? raw) {
    for (final mode in ScriptEditorMode.values) {
      if (mode.name == raw) return mode;
    }
    return ScriptEditorMode.classic;
  }

  String get storageKey => 'script_editor_mode';
}

/// Кэш выбранного режима.
///
/// `EditorDocumentLauncher.buildDocument` синхронный (его зовут из вкладок и
/// из восстановления сессии), поэтому режим читается заранее в bootstrap и
/// держится в памяти. Смена настройки обновляет кэш сразу — открытая вкладка
/// переживёт до следующего открытия документа.
class ScriptEditorModeStore {
  ScriptEditorModeStore._();
  static final ScriptEditorModeStore instance = ScriptEditorModeStore._();

  ScriptEditorMode _mode = ScriptEditorMode.classic;
  bool _loaded = false;

  ScriptEditorMode get mode => _mode;

  @visibleForTesting
  void resetForTests() {
    _mode = ScriptEditorMode.classic;
    _loaded = false;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _mode = ScriptEditorMode.parse(prefs.getString(_mode.storageKey));
    _loaded = true;
  }

  Future<void> set(ScriptEditorMode mode) async {
    _mode = mode;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(mode.storageKey, mode.name);
  }
}