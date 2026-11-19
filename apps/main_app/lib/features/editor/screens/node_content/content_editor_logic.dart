import 'dart:async';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/services/trigger_service.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/features/resources/screens/markdown_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_content/button_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_content/modal_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_content/video_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/variable_selection_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/editor/workspace/editor_nested_documents.dart';

class ContentEditorLogic {
  final BuildContext context;
  final String questId;
  final String currentNodeId;

  ContentEditorLogic({
    required this.context,
    required this.questId,
    required this.currentNodeId,
  });

  Future<ContentItem?> createItemByType(
    String type, {
    void Function(ContentItem item)? onDraft,
  }) async {
    switch (type) {
      case 'row':
        return ContentItem(id: const Uuid().v4(), type: 'row', children: []);
      case 'column':
        return ContentItem(id: const Uuid().v4(), type: 'column', children: []);
      case 'stack':
        // «Стек» — якорная область: фикс. высота, дети по якорям.
        return ContentItem(
          id: const Uuid().v4(),
          type: 'stack',
          children: [],
          stackHeight: 220,
          backgroundColor: const Color(0x14FFFFFF),
          borderRadius: 12,
        );
      case 'text':
        return addText(onDraft: onDraft);
      case 'image':
        return addResource('image');
      case 'audio':
        return addResource('audio');
      case 'video':
        return addVideo(onDraft: onDraft);
      case 'button':
      case 'button_jump':
        return addButton(onDraft: onDraft);
      case 'input':
        return addInput();
      case 'delay':
      case 'timer':
        return ContentItem(id: const Uuid().v4(), type: 'delay', text: '1.0');
      case 'wait_input':
        return addWaitInput();
      case 'modal':
        return addModal(onDraft: onDraft);
      case 'chat':
        return ContentItem(id: const Uuid().v4(), type: 'chat');
      case 'spacer':
        // Высота хранится в padding (переиспользуем существующее поле,
        // чтобы не плодить новые в модели). Дефолт — 16 px.
        return ContentItem(
          id: const Uuid().v4(),
          type: 'spacer',
          padding: 16.0,
        );
      default:
        return null;
    }
  }

  ContentItem _textItem(String id, MarkdownEditorResult result) => ContentItem(
    id: id,
    type: 'text',
    text: result.text,
    fontFamily: result.fontFamily,
    textSize: result.textSize,
    // Режим появления выбран в этом же редакторе — раньше сюда не доезжал,
    // и «Печать» умирала на первом выходе; со второго раза настройку
    // сохранял путь редактирования готового айтема.
    textReveal: result.textReveal,
    revealSpeed: result.revealSpeed,
    textOutlineColor: result.textOutlineColor,
    textOutlineWidth: result.textOutlineWidth,
    flex: 1,
  );

  Future<ContentItem?> addText({
    String? initialText,
    void Function(ContentItem item)? onDraft,
  }) async {
    final draftId = const Uuid().v4();
    final result = await EditorNestedDocuments.open<MarkdownEditorResult>(
      context,
      questId: questId,
      identity: 'text:$currentNodeId:$draftId',
      title: tr('Текст'),
      builder: (_) => MarkdownEditorScreen(
        initialText: initialText ?? '',
        questId: questId,
        onChanged: onDraft == null
            ? null
            : (result) => onDraft(_textItem(draftId, result)),
      ),
    );
    if (result != null) return _textItem(draftId, result);
    return null;
  }

  Future<ContentItem?> addResource(String type) async {
    final res = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ResourceSelectionScreen(questId: questId, allowedTypes: [type]),
      ),
    );
    if (res != null) {
      return ContentItem(
        id: const Uuid().v4(),
        type: type,
        resourcePath: res.path,
        flex: 1,
        volume: 1.0,
      );
    }
    return null;
  }

  Future<ContentItem?> addButton({
    String? initialText,
    String? initialTarget,
    ContentItem? existingItem,
    void Function(ContentItem item)? onDraft,
  }) async {
    final draftId = existingItem?.id ?? const Uuid().v4();
    final result = await EditorNestedDocuments.open<ContentItem>(
      context,
      questId: questId,
      identity: 'button:$currentNodeId:$draftId',
      title: tr('Кнопка'),
      builder: (_) => ButtonEditorScreen(
        questId: questId,
        currentNodeId: currentNodeId,
        existingItem: existingItem,
        initialText: initialText,
        initialTarget: initialTarget,
        draftId: draftId,
        onChanged: onDraft,
      ),
    );
    return result;
  }

  Future<ContentItem?> addInput({ContentItem? existing}) async {
    final promptC = TextEditingController(text: existing?.text ?? '');
    final placeholderC = TextEditingController(
      text: existing?.placeholderText ?? '',
    );
    final buttonC = TextEditingController(text: existing?.buttonText ?? '');
    bool? wrapTextOverride = existing?.wrapTextOverride;
    String? selectedVar = existing?.variableName;

    String? targetId = existing?.targetNodeId;
    Map<String, String>? triggers = existing?.scriptTriggers != null
        ? Map.from(existing!.scriptTriggers!)
        : null;

    Future<void> _configureAction() async {
      final actionType = await showAppDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text(
            tr('Действие после ввода'),
            style: TextStyle(color: Colors.white),
          ),
          content: Text(
            tr('Что произойдет после нажатия кнопки подтверждения?'),
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'nextItem'),
              child: Text(tr('Следующий элемент')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'goToNode'),
              child: Text(tr('Перейти к ноде')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'runScript'),
              child: Text(tr('Выполнить скрипт')),
            ),
          ],
        ),
      );

      if (actionType == null) return;

      if (actionType == 'nextItem') {
        targetId = null;
        triggers?.remove('onSubmit');
      } else if (actionType == 'goToNode') {
        if (!context.mounted) return;
        final tid = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (context) => NodeSelectionScreen(
              questId: questId,
              currentNodeId: currentNodeId,
              selectedNodeId: targetId,
            ),
          ),
        );
        if (tid != null) {
          targetId = tid;
          await saveConnection(questId, currentNodeId, tid);
          triggers?.remove('onSubmit');
        }
      } else if (actionType == 'runScript') {
        final sp = await _selectOrCreateScript();
        if (sp != null) {
          if (triggers == null) triggers = {};
          triggers!['onSubmit'] = sp;
          targetId = null;
        }
      }
    }

    return await showAppDialog<ContentItem>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text(
            tr('Поле ввода'),
            style: TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              children: [
                TextField(
                  controller: promptC,
                  decoration: InputDecoration(labelText: tr('Вопрос')),
                  style: const TextStyle(color: Colors.white),
                ),
                ListTile(
                  title: Text(tr('Переменная')),
                  subtitle: Text(
                    selectedVar ?? tr('Не выбрана'),
                    style: const TextStyle(color: Colors.white54),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                  onTap: () async {
                    final v = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VariableSelectionScreen(
                          questId: questId,
                          selectedVariable: selectedVar,
                        ),
                      ),
                    );
                    if (v != null) setState(() => selectedVar = v);
                  },
                ),
                ListTile(
                  title: Text(tr('Действие (опционально)')),
                  subtitle: Text(
                    targetId != null
                        ? tr('Переход к ноде')
                        : (triggers?.containsKey('onSubmit') ?? false)
                        ? tr('Скрипт')
                        : tr('Дальше по списку'),
                    style: const TextStyle(color: Colors.blueAccent),
                  ),
                  trailing: const Icon(
                    Icons.settings,
                    size: 18,
                    color: Colors.blueAccent,
                  ),
                  onTap: () async {
                    await _configureAction();
                    setState(() {});
                  },
                ),
                TextField(
                  controller: placeholderC,
                  decoration: InputDecoration(labelText: tr('Подсказка')),
                  style: const TextStyle(color: Colors.white),
                ),
                TextField(
                  controller: buttonC,
                  decoration: InputDecoration(labelText: tr('Текст кнопки')),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    tr('Перенос текста кнопки'),
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                RadioListTile<bool?>(
                  value: null,
                  groupValue: wrapTextOverride,
                  onChanged: (val) => setState(() => wrapTextOverride = val),
                  title: Text(
                    tr('Как в настройках квеста'),
                    style: TextStyle(color: Colors.white),
                  ),
                  activeColor: const Color(0xFF00C853),
                  contentPadding: EdgeInsets.zero,
                ),
                RadioListTile<bool?>(
                  value: true,
                  groupValue: wrapTextOverride,
                  onChanged: (val) => setState(() => wrapTextOverride = val),
                  title: Text(
                    tr('Переносить'),
                    style: TextStyle(color: Colors.white),
                  ),
                  activeColor: const Color(0xFF00C853),
                  contentPadding: EdgeInsets.zero,
                ),
                RadioListTile<bool?>(
                  value: false,
                  groupValue: wrapTextOverride,
                  onChanged: (val) => setState(() => wrapTextOverride = val),
                  title: Text(
                    tr('Не переносить'),
                    style: TextStyle(color: Colors.white),
                  ),
                  activeColor: const Color(0xFF00C853),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Отмена')),
            ),
            TextButton(
              onPressed: () {
                if (selectedVar == null) return;
                Navigator.pop(
                  context,
                  ContentItem(
                    id: existing?.id ?? const Uuid().v4(),
                    type: 'input',
                    text: promptC.text,
                    variableName: selectedVar,
                    placeholderText: placeholderC.text,
                    buttonText: buttonC.text,
                    targetNodeId: targetId,
                    scriptTriggers: triggers,
                    flex: existing?.flex ?? 1,
                    wrapText: existing?.wrapText ?? true,
                    wrapTextOverride: wrapTextOverride,
                  ),
                );
              },
              child: Text(tr('ОК')),
            ),
          ],
        ),
      ),
    );
  }

  Future<ContentItem?> addWaitInput({ContentItem? existing}) async {
    final textController = TextEditingController(
      text: existing?.text ?? tr('Нажмите для продолжения'),
    );

    final result = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(
          tr('Пауза (Клик)'),
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('Текст подсказки:'),
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: textController,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: tr('Нажмите для продолжения'),
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF00C853)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr('Игрок должен будет нажать на экран, чтобы продолжить.'),
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, {
              'text': textController.text.trim().isEmpty
                  ? tr('Нажмите для продолжения')
                  : textController.text.trim(),
            }),
            child: Text(tr('ОК'), style: TextStyle(color: Color(0xFF00C853))),
          ),
        ],
      ),
    );

    if (result == null) return null;

    return ContentItem(
      id: existing?.id ?? const Uuid().v4(),
      type: 'wait_input',
      text: result['text'],
      flex: existing?.flex ?? 1,
    );
  }

  /// Мгновенный выбор/создание скрипта (План 014, этап A2).
  /// Возвращает путь (`scripts/…`) либо null при отмене.
  Future<String?> _selectOrCreateScript() async {
    final cs = Theme.of(context).colorScheme;
    final choice = await showAdaptiveSheet<String>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.add, color: Colors.green),
              title: Text(
                tr('Новый визуальный скрипт'),
                style: TextStyle(color: cs.onSurface),
              ),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            ListTile(
              leading: const Icon(Icons.data_object, color: Colors.deepPurple),
              title: Text(
                tr('Новый Lua-скрипт'),
                style: TextStyle(color: cs.onSurface),
              ),
              onTap: () => Navigator.pop(ctx, 'new_lua'),
            ),
            ListTile(
              leading: Icon(Icons.folder, color: cs.onSurfaceVariant),
              title: Text(
                tr('Существующий'),
                style: TextStyle(color: cs.onSurface),
              ),
              onTap: () => Navigator.pop(ctx, 'existing'),
            ),
          ],
        ),
      ),
    );

    if (choice == 'existing') {
      if (!context.mounted) return null;
      final res = await Navigator.push<SelectableResource>(
        context,
        MaterialPageRoute(
          builder: (_) => ResourceSelectionScreen(
            questId: questId,
            // JSON-скрипты и .lua-файлы оба могут быть триггером.
            allowedTypes: const ['script', 'lua'],
          ),
        ),
      );
      return res?.path;
    } else if (choice == 'new' || choice == 'new_lua') {
      final resources = ResourceService.forQuest(questId);
      final scripts = ScriptService(resources: resources);
      try {
        final created = choice == 'new_lua'
            ? await resources.createLuaScript()
            : await resources.createScript();
        if (context.mounted) {
          unawaited(scripts.openEditor(
            context,
            created.questRelativePath,
            mode: EditorOpenMode.routeOnly,
          ));
        }
        return created.questRelativePath;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<ContentItem?> addModal({
    void Function(ContentItem item)? onDraft,
  }) async {
    final draftId = const Uuid().v4();
    final result = await EditorNestedDocuments.open<ContentItem>(
      context,
      questId: questId,
      identity: 'modal:$currentNodeId:$draftId',
      title: tr('Модальное окно'),
      builder: (_) => ModalEditorScreen(
        questId: questId,
        draftId: draftId,
        onChanged: onDraft,
      ),
    );
    return result;
  }

  Future<ContentItem?> editModal({
    required ContentItem existing,
    void Function(ContentItem item)? onChanged,
  }) async {
    final result = await EditorNestedDocuments.open<ContentItem>(
      context,
      questId: questId,
      identity: 'modal:$currentNodeId:${existing.id}',
      title: tr('Модальное окно'),
      builder: (_) => ModalEditorScreen(
        questId: questId,
        existingItem: existing,
        onChanged: onChanged,
      ),
    );
    return result;
  }

  Future<ContentItem?> addVideo({
    ContentItem? existing,
    void Function(ContentItem item)? onDraft,
  }) async {
    final draftId = existing?.id ?? const Uuid().v4();
    final result = await EditorNestedDocuments.open<ContentItem>(
      context,
      questId: questId,
      identity: 'video:$currentNodeId:$draftId',
      title: tr('Видео'),
      builder: (_) => VideoEditorScreen(
        questId: questId,
        existingItem: existing,
        draftId: draftId,
        onChanged: onDraft,
      ),
    );
    return result;
  }
}
