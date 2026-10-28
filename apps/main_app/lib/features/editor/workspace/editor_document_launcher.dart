import 'package:flutter/material.dart';

import 'editor_document.dart';
import 'editor_workspace_scope.dart';
import 'quest_editor_shell.dart';
import '../screens/canvas_screen.dart';
import '../screens/node_content_screen.dart';
import '../screens/tags_screen.dart';
import '../screens/template_manager_screen.dart';
import '../screens/visual_script_editor/visual_script_editor_screen.dart';
import '../../quests/screens/edit_quest_screen.dart';
import '../../game/screens/game_from_save_loader.dart';
import '../../game/screens/game_screen.dart';
import '../../game/screens/load_game_screen.dart';
import '../../guides/guide_catalog.dart';
import '../../guides/screens/guide_screen.dart';
import '../../guides/screens/guides_screen.dart';
import '../../quests/screens/quest_history_screen.dart';
import '../../resources/screens/lua_editor_screen.dart';
import '../../resources/screens/resources_screen.dart';

enum EditorOpenMode { workspace, routeOnly }

class EditorDocumentLauncher {
  const EditorDocumentLauncher._();

  static Future<void> open(
    BuildContext context,
    EditorDocumentDescriptor descriptor, {
    EditorOpenMode mode = EditorOpenMode.workspace,
  }) async {
    final scope = EditorWorkspaceScope.maybeOf(context);
    if (mode == EditorOpenMode.workspace) {
      if (scope != null) {
        scope.openDocument(descriptor);
        return;
      }
      // A normal editor entry without an existing scope creates the workspace
      // instead of silently creating a second route-based document instance.
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => QuestEditorShell(
            questId: descriptor.id.questId,
            initialDocument: descriptor,
          ),
        ),
      );
      return;
    }

    // Route-only is intentional for game/session/deep-link contexts.
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => buildDocument(descriptor, routeOnly: true),
      ),
    );
  }

  static Widget buildDocument(
    EditorDocumentDescriptor descriptor, {
    bool routeOnly = false,
  }) {
    final id = descriptor.id;
    switch (id.kind) {
      case EditorDocumentKind.chapters:
        return TagsScreen(questId: id.questId);
      case EditorDocumentKind.canvas:
        return CanvasScreen(questId: id.questId, tagId: id.key);
      case EditorDocumentKind.node:
        return NodeContentScreen(questId: id.questId, nodeId: id.key);
      case EditorDocumentKind.visualScript:
        return VisualScriptEditorScreen(questId: id.questId, scriptId: id.key);
      case EditorDocumentKind.lua:
        return LuaEditorScreen(
          questId: id.questId,
          fileName: descriptor.routeKey ?? id.key,
        );
      case EditorDocumentKind.resources:
        return ResourcesScreen(questId: id.questId);
      case EditorDocumentKind.templates:
        return TemplateManagerScreen(questId: id.questId);
      case EditorDocumentKind.questSettings:
        return EditQuestScreen(questId: id.questId);
      case EditorDocumentKind.game:
        return GameScreen(
          questId: id.questId,
          startNodeId: descriptor.routeKey,
          isTesting: true,
        );
      case EditorDocumentKind.gameLoad:
        final slotId = descriptor.routeKey;
        if (slotId == null || slotId.isEmpty) {
          // Слот ещё не выбран — экран выбора сохранения во вкладке.
          return LoadGameScreen(questId: id.questId, isTesting: true);
        }
        return GameFromSaveLoader(questId: id.questId, slotId: slotId);
      case EditorDocumentKind.guide:
        if (id.key == 'catalog') return GuidesScreen(questId: id.questId);
        final info = GuideCatalog.byId(id.key);
        // Гайд мог исчезнуть из каталога после обновления — вместо пустой
        // вкладки показываем список, из которого он открывался.
        if (info == null) return GuidesScreen(questId: id.questId);
        return GuideScreen(info: info);
      case EditorDocumentKind.questHistory:
        return QuestHistoryScreen(questId: id.questId);
    }
  }

  static Future<void> openChapters(BuildContext context, String questId) =>
      open(context, EditorDocumentDescriptor.chapters(questId));

  static Future<void> openCanvas(
    BuildContext context,
    String questId,
    String tagId, {
    String title = 'Canvas',
  }) => open(
    context,
    EditorDocumentDescriptor.canvas(questId, tagId, title: title),
  );

  static Future<void> openNode(
    BuildContext context,
    String questId,
    String nodeId, {
    String? title,
    EditorOpenMode mode = EditorOpenMode.workspace,
  }) => open(
    context,
    EditorDocumentDescriptor.node(questId, nodeId, title: title),
    mode: mode,
  );

  static Future<void> openVisualScript(
    BuildContext context,
    String questId,
    String scriptId, {
    String? title,
    EditorOpenMode mode = EditorOpenMode.workspace,
  }) => open(
    context,
    EditorDocumentDescriptor.visualScript(questId, scriptId, title: title),
    mode: mode,
  );

  static Future<void> openLua(
    BuildContext context,
    String questId,
    String fileName, {
    String title = 'Lua',
    String? stableId,
    EditorOpenMode mode = EditorOpenMode.workspace,
  }) => open(
    context,
    EditorDocumentDescriptor.lua(
      questId,
      stableId ?? fileName,
      title: title,
      fileName: fileName,
    ),
    mode: mode,
  );

  static Future<void> openResources(BuildContext context, String questId) =>
      open(context, EditorDocumentDescriptor.resources(questId));

  static Future<void> openTemplates(BuildContext context, String questId) =>
      open(context, EditorDocumentDescriptor.templates(questId));

  static Future<void> openSettings(BuildContext context, String questId) =>
      open(context, EditorDocumentDescriptor.questSettings(questId));

  static Future<void> openGameSimulation(
    BuildContext context,
    String questId, {
    String? startNodeId,
    String? title,
  }) => open(
    context,
    EditorDocumentDescriptor.gameSimulation(
      questId,
      title: title,
      startNodeId: startNodeId,
    ),
  );

  static Future<void> openGameFromSave(
    BuildContext context,
    String questId, {
    String? title,
  }) => open(
    context,
    EditorDocumentDescriptor.gameFromSave(questId, title: title),
  );

  static Future<void> openGuides(BuildContext context, String questId) =>
      open(context, EditorDocumentDescriptor.guidesCatalog(questId));

  static Future<void> openQuestHistory(BuildContext context, String questId) =>
      open(context, EditorDocumentDescriptor.questHistory(questId));
}
