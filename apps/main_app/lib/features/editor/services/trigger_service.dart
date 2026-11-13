import 'package:flutter/material.dart';

import 'package:mnd_player/utils/trigger_reference.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/screens/folder_picker_screen.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Шаблоны и метаданные триггеров: имена Lua-функций по событиям,
/// стартовые блоки JSON, шаблоны Lua.
class TriggerService {
  const TriggerService._();

  /// UI-ключ триггера → имя функции Lua в движке
  /// (crates/mnd-core/src/engine.rs: вызов по имени события, фолбэк `start`).
  static const Map<String, String> luaEventFunctions = {
    'onPress': 'onPress',
    'onAppear': 'onContentAppear',
  };

  /// Имя функции Lua для ключа триггера (фолбэк — `start`).
  static String luaFunctionForTrigger(String triggerKey) =>
      luaEventFunctions[triggerKey] ?? 'start';

  /// Человекочитаемое имя типа триггера.
  static String labelForTrigger(String triggerKey) => switch (triggerKey) {
    'onAppear' => tr('При появлении'),
    'onPress' => tr('При нажатии'),
    'onSubmit' => tr('При вводе'),
    _ => triggerKey,
  };

  /// Шаблон нового Lua-триггера: функция события с аргументом item_id.
  static String luaTemplate(String triggerKey, String scriptName) {
    final fn = luaFunctionForTrigger(triggerKey);
    return '-- $scriptName\n'
        'function $fn(item_id)\n'
        '    core.set_var(\'x\', 42)\n'
        'end\n';
  }

  /// Стартовый JSON-блок триггера (event-обёртка с нужным событием).
  static List<Map<String, dynamic>> jsonInitialBlocks(String triggerKey) {
    final eventType = switch (triggerKey) {
      'onPress' => 'onPress',
      'onAppear' => 'onContentAppear',
      _ => 'onNodeEnter',
    };
    return [
      {'type': 'event', 'eventType': eventType, 'children': []},
    ];
  }

  /// Блок JSON-функции (для триггеров-функций через #fn=).
  static List<Map<String, dynamic>> jsonFunctionBlocks({
    String functionName = 'main',
  }) {
    return [
      {
        'type': 'event',
        'eventType': 'function',
        'functionName': functionName,
        'children': <Map<String, dynamic>>[],
      },
    ];
  }
}

/// Тип ссылки на скрипт (для чипов в триггер-шитах и маршрутизации).
enum ScriptKind { json, lua, unknown }

/// Классификация и маршрутизация ссылок на скрипты.
class ScriptService {
  final ResourceService resources;

  ScriptService({required this.resources});

  factory ScriptService.forQuest(String questId) {
    // Для UI-кода на экране: сервис создаётся напрямую (см. провайдер в
    // script_providers.dart при необходимости).
    return ScriptService(resources: ResourceService.forQuest(questId));
  }

  static ScriptKind kindOfRef(String rawRef) {
    final ref = TriggerReference.parse(rawRef);
    if (ref.scriptPath.isEmpty) return ScriptKind.unknown;
    final fileName = ref.scriptPath.split('/').last;
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.lua')) return ScriptKind.lua;
    if (lower.endsWith('.json')) return ScriptKind.json;
    return ScriptKind.unknown;
  }

  /// Человекочитаемое имя триггера (JSON: из файла, Lua: из metadata;
  /// `#fn=` добавляет « :: функция»).
  Future<String> displayName(String rawRef) =>
      resources.resolveScriptDisplayName(rawRef);

  /// Создаёт триггерный скрипт и открывает редактор.
  ///
  /// [lua] — создать `.lua` (иначе визуальный JSON); [triggerKey] — ключ
  /// события (onPress/onAppear/...) для шаблона; мгновенное создание:
  /// авто-имя, без диалогов и выбора папки (папка = текущая/корень).
  Future<CreatedScript> createTriggerScript({
    required String triggerKey,
    required bool lua,
    String folder = '/',
  }) async {
    if (lua) {
      final prefix = switch (triggerKey) {
        'onPress' => tr('Нажатие'),
        'onAppear' => tr('Появление'),
        _ => tr('Скрипт'),
      };
      final name = await resources.autoScriptName(prefix: prefix);
      return resources.createLuaScript(
        name: name,
        folder: folder,
        template: TriggerService.luaTemplate(triggerKey, name),
      );
    }
    return resources.createScript(
      folder: folder,
      initialBlocks: TriggerService.jsonInitialBlocks(triggerKey),
    );
  }

  /// Открывает нужный редактор по сырой ссылке триггера/блока:
  /// `.lua` → [LuaEditorScreen], `.json` → [VisualScriptEditorScreen].
  /// Ссылки с `#fn=` открывают сам скрипт.
  ///
  /// Возвращает future навигации (чтобы вызывающий мог делать refresh
  /// после выхода из редактора).
  ///
  /// [mode] — куда открывать. Из незакрытого ещё редактора элемента
  /// (кнопка, модалка) обязаны просить [EditorOpenMode.routeOnly]:
  /// воркспейс-режим заменит вкладку ноды этим скриптом, а вместе с
  /// ней умрёт и редактор, который ждёт результат.
  /// Открывает редактор скрипта по ссылке триггера.
  ///
  /// Способ открытия зависит от контекста: внутри воркспейса (у экрана есть
  /// [EditorWorkspaceScope]) скрипт становится вкладкой, а из экрана-маршрута
  /// (редактор стека, контейнер, модалки) — отдельным экраном поверх. Иначе
  /// из стека поднимался ВТОРОЙ `QuestEditorShell`: «Назад» в нём уводил не
  /// обратно в стек, а на восстановленную вкладку ноды, и правки скрипта и
  /// стека расходились по двум разным состояниям воркспейса.
  Future<void> openEditor(
    BuildContext context,
    String rawRef, {
    EditorOpenMode? mode,
  }) async {
    final resolvedMode = mode ??
        (EditorWorkspaceScope.maybeOf(context) == null
            ? EditorOpenMode.routeOnly
            : EditorOpenMode.workspace);
    final ref = TriggerReference.parse(rawRef);
    final fileName = ref.scriptPath.split('/').last;
    switch (kindOfRef(rawRef)) {
      case ScriptKind.lua:
        final resource = await resources.findResourceByFileName(fileName);
        if (!context.mounted) return;
        return EditorDocumentLauncher.openLua(
          context,
          resources.questId,
          fileName,
          title: resource?.friendlyName ?? fileName,
          stableId: resource?.stableId,
          mode: resolvedMode,
        );
      case ScriptKind.json:
        final dot = fileName.lastIndexOf('.');
        final scriptId = dot > 0 ? fileName.substring(0, dot) : fileName;
        return EditorDocumentLauncher.openVisualScript(
          context,
          resources.questId,
          scriptId,
          title: fileName,
          mode: resolvedMode,
        );
      case ScriptKind.unknown:
        return Future.value();
    }
  }

  /// «Сохранить в…» для редакторов скриптов (План 014, этап D): переименование
  /// (человекочитаемое имя) и перемещение в виртуальную папку. Физическое
  /// имя файла не меняется — на него ссылаются триггеры нод.
  /// Возвращает true, если что-то изменилось (для обновления UI редактора).
  Future<bool> showSaveLocationSheet(
    BuildContext context,
    String fileName,
  ) async {
    final cs = Theme.of(context).colorScheme;
    final choice = await showAdaptiveSheet<String>(
      context: context,
      scrollable: true,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.edit_rounded, color: cs.primary),
              title: Text(
                tr('Переименовать'),
                style: TextStyle(color: cs.onSurface),
              ),
              subtitle: Text(
                tr('Отображаемое имя скрипта'),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.folder_rounded, color: cs.primary),
              title: Text(
                tr('Переместить в папку…'),
                style: TextStyle(color: cs.onSurface),
              ),
              subtitle: Text(
                tr('Виртуальные папки библиотеки ресурсов'),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
          ],
        ),
      ),
    );

    if (choice == null) return false;

    final resource = await resources.findResourceByFileName(fileName);
    if (resource == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Ресурс не найден'))),
        );
      }
      return false;
    }

    if (choice == 'rename') {
      if (!context.mounted) return false;
      final newName = await _showNameDialog(context, resource.friendlyName);
      if (newName == null || newName.trim().isEmpty) return false;
      final trimmed = newName.trim();
      await resources.renameResource(resource, trimmed);
      return true;
    }

    // move
    if (!context.mounted) return false;
    final folder = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => FolderPickerScreen(
          questId: resources.questId,
          initialFolder: resource.folder,
          title: tr('Папка скрипта'),
          ctaLabel: tr('Сохранить сюда'),
        ),
      ),
    );
    if (folder == null) return false;
    await resources.setResourceFolder(fileName, folder);
    return true;
  }

  Future<String?> _showNameDialog(BuildContext context, String current) {
    final controller = TextEditingController(text: current);
    final cs = Theme.of(context).colorScheme;
    return showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surfaceContainerHigh,
        title: Text(
          tr('Переименовать скрипт'),
          style: TextStyle(color: cs.onSurface),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: cs.onSurface),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
  }
}
