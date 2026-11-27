import 'dart:async';

import 'package:canvas_app/models/content_item_model.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/services/trigger_service.dart';
import 'package:canvas_app/features/resources/screens/markdown_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/variable_selection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';

// План 020-C4.5: операции над квестом — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};

/// Экран редактирования всплывающего окна (Modal)
class ModalEditorScreen extends ConsumerStatefulWidget {
  final String questId;
  final ContentItem? existingItem;

  /// Стабильный id для новой модалки: без него каждый вызов автосохранения
  /// создавал бы новый элемент в ноде.
  final String? draftId;

  /// Автосохранение в родительскую вкладку без закрытия экрана.
  final ValueChanged<ContentItem>? onChanged;

  const ModalEditorScreen({
    super.key,
    required this.questId,
    this.existingItem,
    this.draftId,
    this.onChanged,
  });

  @override
  ConsumerState<ModalEditorScreen> createState() => _ModalEditorScreenState();
}

class _ModalEditorScreenState extends ConsumerState<ModalEditorScreen> {
  String? _lastAutosave;
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  late TextEditingController _buttonTextController;
  String? _targetNodeId;
  String _targetNodeName = tr('Не выбрана');
  bool _autoClose = false;
  String _autoCloseDelay = '2';
  bool _showTimer = false; // Показывать ли таймер при автозакрытии
  String? _scriptAssetId; // ID скрипта для выполнения
  List<ModalButtonConfig> _modalButtons = []; // Список кнопок
  late TextEditingController _autoCloseDelayController;
  final Map<String, String> _resourceNames = {};

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.existingItem?.buttonText ?? tr('Уведомление'),
    );
    _contentController = TextEditingController(
      text: widget.existingItem?.contentMarkdown ?? '',
    );
    _buttonTextController = TextEditingController(
      text: widget.existingItem?.placeholderText ?? tr('Закрыть'),
    );
    _targetNodeId = widget.existingItem?.targetNodeId;
    _scriptAssetId = widget.existingItem?.scriptAssetId;
    _autoCloseDelayController = TextEditingController();

    // Загружаем кнопки если есть
    if (widget.existingItem?.modalButtons != null) {
      _modalButtons = List.from(widget.existingItem!.modalButtons!);
    }

    // Проверяем, было ли настроено автозакрытие
    if (widget.existingItem?.targetNodeId == '_CLOSE_MODAL') {
      _autoClose = true;
      _scriptAssetId = null;
      _autoCloseDelay = widget.existingItem?.text ?? '2';
      _autoCloseDelayController.text = _autoCloseDelay;
      // Флаг показа таймера — собственное поле модели.
      _showTimer = widget.existingItem?.showTimer ?? false;
    } else {
      _autoCloseDelayController.text = _autoCloseDelay;
      if (_scriptAssetId != null) {
        _targetNodeId = null;
        _targetNodeName = tr('Не выбрана');
      } else if (_targetNodeId != null) {
        unawaited(_updateTargetNodeName());
      } else {
        _targetNodeName = tr('Не выбрана');
      }
    }

    _lastAutosave = _snapshot(_buildContentItem());
    for (final controller in [
      _titleController,
      _contentController,
      _buttonTextController,
      _autoCloseDelayController,
    ]) {
      controller.addListener(_scheduleAutosave);
    }
    _loadMetadataNames();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleAutosave();
  }

  void _scheduleAutosave() => _emitAutosave();

  String _snapshot(ContentItem item) => item.toJson().toString();

  void _emitAutosave() {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    final item = _buildContentItem();
    final snapshot = _snapshot(item);
    if (snapshot == _lastAutosave) return;
    _lastAutosave = snapshot;
    onChanged(item);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _buttonTextController.dispose();
    _autoCloseDelayController.dispose();
    super.dispose();
  }

  Future<void> _loadMetadataNames() async {
    try {
      final metaPath = QuestPaths.metadata(widget.questId);
      if (!await (await _qs()).exists(metaPath)) return;
      final metadata = await _readMap(metaPath);
      if (!mounted) return;
      setState(() {
        _resourceNames.clear();
        metadata.forEach((key, value) {
          if (value is Map && value['name'] != null) {
            _resourceNames[key.toString()] = value['name'].toString();
          } else if (value is String) {
            _resourceNames[key.toString()] = value;
          }
        });
      });
    } catch (_) {}
  }

  String _resolveScriptDisplayName(String? scriptPath) {
    if (scriptPath == null || scriptPath.trim().isEmpty) {
      return tr('Скрипт не выбран');
    }
    final fileName = p.basename(scriptPath.trim());
    return _resourceNames[fileName] ?? fileName;
  }

  /// Мгновенный выбор/создание скрипта (План 014, этап A2): авто-имя,
  /// без диалогов; поддерживаются визуальный и Lua. Возвращает `scripts/…`.
  Future<String?> _selectOrCreateScriptPath() async {
    final cs = Theme.of(context).colorScheme;
    final choice = await showAdaptiveSheet<String>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.add, color: cs.primary),
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
      if (!mounted) return null;
      final res = await Navigator.push<SelectableResource>(
        context,
        MaterialPageRoute(
          builder: (_) => ResourceSelectionScreen(
            questId: widget.questId,
            allowedTypes: const ['script', 'lua'],
          ),
        ),
      );
      return res?.path;
    }

    if (choice == 'new' || choice == 'new_lua') {
      final resources = ResourceService.forQuest(widget.questId);
      final scripts = ScriptService(resources: resources);
      try {
        final created = choice == 'new_lua'
            ? await resources.createLuaScript()
            : await resources.createScript();
        _resourceNames[created.fileName] = created.name;
        if (mounted) {
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

  Future<void> _pickScript() async {
    final path = await _selectOrCreateScriptPath();
    if (path == null) return;
    if (!mounted) return;
    setState(() {
      _scriptAssetId = path;
      _autoClose = false;
      _targetNodeId = null;
      _targetNodeName = tr('Не выбрана');
    });
  }

  Future<void> _editCurrentScript() async {
    final scriptPath = _scriptAssetId;
    if (scriptPath == null || scriptPath.trim().isEmpty) return;

    final fullPath = QuestPaths.questFile(widget.questId, scriptPath);
    if (!await (await _qs()).exists(fullPath)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Скрипт не найден')),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    if (!mounted) return;
    // Маршрутизация .lua/.json через ScriptService (План 014).
    final scripts = ScriptService(
      resources: ResourceService.forQuest(widget.questId),
    );
    unawaited(scripts.openEditor(
        context,
        scriptPath,
        mode: EditorOpenMode.routeOnly,
      ));
  }

  Future<void> _selectTargetNode() async {
    final nodeId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => NodeSelectionScreen(
          questId: widget.questId,
          selectedNodeId: _targetNodeId,
          allowCreate: true,
        ),
      ),
    );

    if (nodeId != null && mounted) {
      setState(() {
        _targetNodeId = nodeId;
        _autoClose = false;
        _scriptAssetId = null;
      });
      _updateTargetNodeName();
    }
  }

  Future<void> _updateTargetNodeName() async {
    if (_targetNodeId == null) {
      setState(() => _targetNodeName = tr('Не выбрана'));
      return;
    }

    // Получаем название ноды из провайдера
    try {
      final nodes = await ref.read(
        allQuestNodesProvider(widget.questId).future,
      );
      final node = nodes.firstWhere(
        (n) => n.id == _targetNodeId,
        orElse: () => SavedNode(
          id: _targetNodeId!,
          chapterId: '',
          title: tr('Нода не найдена'),
          content: {},
        ),
      );
      if (mounted) {
        setState(() {
          _targetNodeName = node.title.isNotEmpty
              ? node.title
              : tr('Нода без имени');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _targetNodeName = tr('Нода без имени');
        });
      }
    }
  }

  Future<void> _openContentEditor() async {
    final result = await Navigator.push<MarkdownEditorResult>(
      context,
      MaterialPageRoute(
        builder: (context) => MarkdownEditorScreen(
          initialText: _contentController.text,
          onChanged: (result) {
            if (!mounted) return;
            setState(() => _contentController.text = result.text);
          },
          questId: widget.questId,
          supportsTextSize: false,
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        _contentController.text = result.text;
      });
    }
  }

  Future<void> _editFormula(
    TextEditingController controller,
    String label,
  ) async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => ExpressionEditorScreen(
          initialValue: controller.text,
          questId: widget.questId,
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        controller.text = _stripWrappingQuotes(result);
      });
    }
  }

  String _stripWrappingQuotes(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2) {
      final startsWithQuote =
          trimmed.startsWith('"') || trimmed.startsWith("'");
      final endsWithQuote = trimmed.endsWith('"') || trimmed.endsWith("'");
      if (startsWithQuote && endsWithQuote) {
        return trimmed.substring(1, trimmed.length - 1);
      }
    }
    return value;
  }

  Future<void> _selectVariable(TextEditingController controller) async {
    final variableName = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => VariableSelectionScreen(
          questId: widget.questId,
          selectedVariable: controller.text.isNotEmpty ? controller.text : null,
        ),
      ),
    );

    if (variableName != null && mounted) {
      setState(() {
        controller.text = '{$variableName}';
      });
    }
  }

  Future<void> _selectScript() async {
    final cs = Theme.of(context).colorScheme;
    final action = await showAdaptiveSheet<String>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.folder_open, color: cs.onSurfaceVariant),
              title: Text(
                tr('Выбрать/создать скрипт'),
                style: TextStyle(color: cs.onSurface),
              ),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            if (_scriptAssetId != null && _scriptAssetId!.isNotEmpty)
              ListTile(
                leading: Icon(Icons.edit, color: cs.tertiary),
                title: Text(
                  tr('Редактировать текущий скрипт'),
                  style: TextStyle(color: cs.onSurface),
                ),
                onTap: () => Navigator.pop(ctx, 'edit'),
              ),
            if (_scriptAssetId != null && _scriptAssetId!.isNotEmpty)
              ListTile(
                leading: Icon(Icons.delete, color: cs.error),
                title: Text(
                  tr('Удалить скрипт'),
                  style: TextStyle(color: cs.onSurface),
                ),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'pick') {
      await _pickScript();
      return;
    }
    if (action == 'edit') {
      await _editCurrentScript();
      return;
    }
    if (action == 'delete') {
      setState(() => _scriptAssetId = null);
    }
  }

  ContentItem _buildContentItem() {
    String? targetNodeId;
    String? text;
    String? contentMarkdown;

    if (_autoClose) {
      targetNodeId = '_CLOSE_MODAL';
      text = _autoCloseDelay;
      // Сохраняем содержимое даже при автозакрытии!
      contentMarkdown = _contentController.text;
    } else {
      targetNodeId = _scriptAssetId != null ? null : _targetNodeId;
      text = null;
      contentMarkdown = _contentController.text;
    }

    return ContentItem(
      id:
          widget.existingItem?.id ??
          widget.draftId ??
          const Uuid().v4(),
      type: 'modal',
      text: text,
      contentMarkdown: contentMarkdown,
      buttonText: _titleController.text.trim().isEmpty
          ? tr('Уведомление')
          : _titleController.text.trim(),
      placeholderText: _buttonTextController.text.trim().isEmpty
          ? tr('Закрыть')
          : _buttonTextController.text.trim(),
      targetNodeId: targetNodeId,
      scriptAssetId: _autoClose ? null : _scriptAssetId,
      modalButtons: _modalButtons.isNotEmpty ? _modalButtons : null,
      // Настройки этого шита больше не занимают `scriptTriggers`: иначе
      // правка модалки стирала бы скрипты, привязанные через карточку элемента.
      scriptTriggers: widget.existingItem?.scriptTriggers,
      showTimer: _showTimer,
      flex: 1,
    );
  }

  void _save() {
    final item = _buildContentItem();
    Navigator.pop(context, item);
  }

  void _addButton() {
    setState(() {
      _modalButtons.add(
        ModalButtonConfig(
          id: const Uuid().v4(),
          text: trf('Кнопка {p0}', {'p0': _modalButtons.length + 1}),
          isPrimary: _modalButtons.isEmpty,
        ),
      );
    });
  }

  void _editButton(int index) {
    final button = _modalButtons[index];
    showAdaptiveSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      isScrollControlled: true,
      builder: (ctx) => _ButtonEditorSheet(
        button: button,
        questId: widget.questId,
        onSave: (updatedButton) {
          setState(() {
            _modalButtons[index] = updatedButton;
          });
          Navigator.pop(ctx);
        },
      ),
    );
  }

  void _removeButton(int index) {
    setState(() {
      _modalButtons.removeAt(index);
      // Гарантируем только одну primary-кнопку.
      if (_modalButtons.isEmpty) return;
      final firstPrimaryIndex = _modalButtons.indexWhere((b) => b.isPrimary);
      final primaryIndex = firstPrimaryIndex >= 0 ? firstPrimaryIndex : 0;
      _modalButtons = _modalButtons
          .asMap()
          .entries
          .map((e) => e.value.copyWith(isPrimary: e.key == primaryIndex))
          .toList();
    });
  }

  void _moveButton(int index, int delta) {
    final newIndex = index + delta;
    if (newIndex < 0 || newIndex >= _modalButtons.length) return;
    setState(() {
      final temp = _modalButtons[index];
      _modalButtons[index] = _modalButtons[newIndex];
      _modalButtons[newIndex] = temp;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: cs.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          tr('Всплывающее окно'),
          style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              tr('Готово'),
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: AdaptiveContent(
        maxWidth: 720,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Заголовок окна
              _buildSection(
                title: tr('Заголовок окна'),
                subtitle:
                    tr('Текст в верхней части уведомления (поддерживает формулы)'),
                child: _buildFormulaField(
                  controller: _titleController,
                  hintText: tr('Уведомление'),
                  label: tr('Заголовок'),
                ),
              ),
              const SizedBox(height: 24),

              // Содержимое
              _buildSection(
                title: tr('Содержимое'),
                subtitle:
                    tr('Основной текст сообщения (поддерживает Markdown и формулы)'),
                child: InkWell(
                  onTap: _openContentEditor,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _contentController.text.isEmpty
                                ? tr('Нажмите для редактирования')
                                : _contentController.text.length > 50
                                ? '${_contentController.text.substring(0, 50)}...'
                                : _contentController.text,
                            style: TextStyle(
                              color: _contentController.text.isEmpty
                                  ? cs.onSurfaceVariant
                                  : cs.onSurface,
                            ),
                          ),
                        ),
                        Icon(Icons.edit, color: cs.primary, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Текст кнопки
              _buildSection(
                title: tr('Текст кнопки'),
                subtitle: tr('Надпись на кнопке закрытия (поддерживает формулы)'),
                child: _buildFormulaField(
                  controller: _buttonTextController,
                  hintText: tr('Закрыть'),
                  label: tr('Текст кнопки'),
                ),
              ),
              const SizedBox(height: 24),

              // Секция кнопок (новая функция)
              _buildSection(
                title: tr('Кнопки'),
                subtitle:
                    tr('Можно добавить несколько кнопок с разными действиями'),
                child: Column(
                  children: [
                    ..._modalButtons.asMap().entries.map((entry) {
                      final index = entry.key;
                      final button = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildButtonTile(button, index),
                      );
                    }),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _addButton,
                        icon: Icon(Icons.add, color: cs.primary),
                        label: Text(
                          tr('Добавить кнопку'),
                          style: TextStyle(color: cs.primary),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: cs.primary),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Действие после закрытия
              _buildSection(
                title: tr('Действие после закрытия'),
                subtitle: tr('Что произойдёт когда игрок нажмёт кнопку'),
                child: Material(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          selected: !_autoClose && _scriptAssetId == null,
                          selectedTileColor: cs.primary.withValues(alpha: 0.1),
                          leading: Radio<bool>(
                            value: false,
                            groupValue: _scriptAssetId == null ? _autoClose : null,
                            onChanged: (value) {
                              setState(() {
                                _autoClose = false;
                                _scriptAssetId = null;
                              });
                            },
                            activeColor: cs.primary,
                          ),
                          title: Text(
                            tr('Перейти к ноде'),
                            style: TextStyle(color: cs.onSurface),
                          ),
                          subtitle: Text(
                            _targetNodeId != null
                                ? trf('Нода: {_targetNodeName}', {'_targetNodeName': _targetNodeName})
                                : tr('Нода не выбрана'),
                            style: TextStyle(
                              color: _targetNodeId != null
                                  ? cs.onSurfaceVariant
                                  : cs.onSurfaceVariant.withValues(alpha: 0.6),
                            ),
                          ),
                          onTap: () {
                            setState(() {
                              _autoClose = false;
                              _scriptAssetId = null;
                            });
                          },
                        ),
                        if (!_autoClose && _scriptAssetId == null)
                          Padding(
                            padding: const EdgeInsets.only(left: 56, top: 8),
                            child: SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _selectTargetNode,
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: Text(_targetNodeName),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: cs.onSurface,
                                  side: BorderSide(color: cs.primary),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Divider(color: cs.outlineVariant, height: 24),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          selected: _autoClose,
                          selectedTileColor: cs.primary.withValues(alpha: 0.1),
                          leading: Radio<bool>(
                            value: true,
                            groupValue: _autoClose,
                            onChanged: (value) {
                              setState(() {
                                _autoClose = true;
                                _scriptAssetId = null;
                              });
                            },
                            activeColor: cs.primary,
                          ),
                          title: Text(
                            tr('Автоматическое закрытие'),
                            style: TextStyle(color: cs.onSurface),
                          ),
                          subtitle: Text(
                            tr('Окно закроется через указанное время'),
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          onTap: () {
                            setState(() {
                              _autoClose = true;
                              _scriptAssetId = null;
                            });
                          },
                        ),
                        if (_autoClose) ...[
                          Padding(
                            padding: const EdgeInsets.only(
                              left: 56,
                              top: 8,
                              bottom: 8,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  tr('Через '),
                                  style: TextStyle(color: cs.onSurfaceVariant),
                                ),
                                SizedBox(
                                  width: 80,
                                  child: TextField(
                                    onChanged: (val) => _autoCloseDelay = val,
                                    controller: _autoCloseDelayController,
                                    style: TextStyle(color: cs.onSurface),
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.allow(
                                        RegExp(r'[0-9.]'),
                                      ),
                                    ],
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                      filled: true,
                                      fillColor: cs.surfaceContainerHigh,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                ),
                                Text(
                                  tr(' сек'),
                                  style: TextStyle(color: cs.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          // Переключатель показа таймера
                          Padding(
                            padding: const EdgeInsets.only(left: 48, bottom: 8),
                            child: Row(
                              children: [
                                Switch(
                                  value: _showTimer,
                                  onChanged: (value) {
                                    setState(() => _showTimer = value);
                                  },
                                  activeColor: cs.primary,
                                ),
                                Expanded(
                                  child: Text(
                                    tr('Показывать таймер обратного отсчёта'),
                                    style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        Divider(color: cs.outlineVariant, height: 24),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          selected: _scriptAssetId != null,
                          selectedTileColor: cs.primary.withValues(alpha: 0.1),
                          leading: Radio<bool>(
                            value: true,
                            groupValue: _scriptAssetId != null,
                            onChanged: (value) {
                              if (value == true) {
                                _selectScript();
                              } else {
                                setState(() => _scriptAssetId = null);
                              }
                            },
                            activeColor: cs.primary,
                          ),
                          title: Text(
                            tr('Выполнить скрипт'),
                            style: TextStyle(color: cs.onSurface),
                          ),
                          subtitle: Text(
                            _scriptAssetId != null
                                ? trf('Скрипт: {p0}', {'p0': _resolveScriptDisplayName(_scriptAssetId)})
                                : tr('Скрипт не выбран'),
                            style: TextStyle(
                              color: _scriptAssetId != null
                                  ? cs.onSurfaceVariant
                                  : cs.onSurfaceVariant.withValues(alpha: 0.6),
                            ),
                          ),
                          trailing: _scriptAssetId != null
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        Icons.edit,
                                        color: cs.tertiary,
                                        size: 18,
                                      ),
                                      onPressed: _editCurrentScript,
                                      tooltip: tr('Редактировать скрипт'),
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        Icons.delete,
                                        color: cs.error,
                                        size: 18,
                                      ),
                                      onPressed: () =>
                                          setState(() => _scriptAssetId = null),
                                      tooltip: tr('Удалить скрипт'),
                                    ),
                                  ],
                                )
                              : null,
                          onTap: () {
                            _selectScript();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Подсказка
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.tertiary.withValues(alpha: 0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: cs.tertiary, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        tr('В тексте можно использовать переменные в формате {variableName} и формулы. Например: "Привет, {playerName}!" или "{health + 10}".'),
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: cs.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _buildFormulaField({
    required TextEditingController controller,
    required String hintText,
    required String label,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: TextStyle(color: cs.onSurface),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: TextStyle(
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              filled: true,
              fillColor: cs.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Кнопка редактора формул
        IconButton(
          onPressed: () => _editFormula(controller, label),
          icon: Icon(Icons.functions, color: cs.primary),
          tooltip: tr('Редактор формул'),
        ),
        // Кнопка выбора переменной
        IconButton(
          onPressed: () => _selectVariable(controller),
          icon: Icon(Icons.code, color: cs.tertiary),
          tooltip: tr('Вставить переменную'),
        ),
      ],
    );
  }

  Widget _buildButtonTile(ModalButtonConfig button, int index) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          // Кнопки перемещения
          Column(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 18),
                color: cs.onSurfaceVariant,
                onPressed: index > 0 ? () => _moveButton(index, -1) : null,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward, size: 18),
                color: cs.onSurfaceVariant,
                onPressed: index < _modalButtons.length - 1
                    ? () => _moveButton(index, 1)
                    : null,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(width: 8),
          // Индикатор primary
          Container(
            width: 4,
            height: 40,
            decoration: BoxDecoration(
              color: button.isPrimary
                  ? cs.primary
                  : cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          // Информация о кнопке
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  button.text,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  _getButtonActionText(button),
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
          // Кнопки действий
          IconButton(
            icon: const Icon(Icons.edit, size: 18),
            color: cs.primary,
            onPressed: () => _editButton(index),
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 18),
            color: cs.error,
            onPressed: () => _removeButton(index),
          ),
        ],
      ),
    );
  }

  String _getButtonActionText(ModalButtonConfig button) {
    if (button.targetNodeId != null && button.targetNodeId != '_CLOSE_MODAL') {
      return tr('Переход к ноде');
    } else if (button.scriptAssetId != null) {
      return tr('Выполнение скрипта');
    } else if (button.targetNodeId == '_CLOSE_MODAL') {
      return tr('Закрыть окно');
    }
    return tr('Нет действия');
  }
}

/// Виджет редактирования кнопки
class _ButtonEditorSheet extends StatefulWidget {
  final ModalButtonConfig button;
  final String questId;
  final Function(ModalButtonConfig) onSave;

  const _ButtonEditorSheet({
    required this.button,
    required this.questId,
    required this.onSave,
  });

  @override
  State<_ButtonEditorSheet> createState() => _ButtonEditorSheetState();
}

class _ButtonEditorSheetState extends State<_ButtonEditorSheet> {
  late TextEditingController _textController;
  String? _targetNodeId;
  String? _scriptAssetId;
  bool _isPrimary = false;
  final Map<String, String> _resourceNames = {};

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.button.text);
    _targetNodeId = widget.button.targetNodeId;
    _scriptAssetId = widget.button.scriptAssetId;
    _isPrimary = widget.button.isPrimary;
    _loadMetadataNames();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _editFormula() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => ExpressionEditorScreen(
          initialValue: _textController.text,
          questId: widget.questId,
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        _textController.text = _stripWrappingQuotes(result);
      });
    }
  }

  String _stripWrappingQuotes(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2) {
      final startsWithQuote =
          trimmed.startsWith('"') || trimmed.startsWith("'");
      final endsWithQuote = trimmed.endsWith('"') || trimmed.endsWith("'");
      if (startsWithQuote && endsWithQuote) {
        return trimmed.substring(1, trimmed.length - 1);
      }
    }
    return value;
  }

  Future<void> _selectTargetNode() async {
    final nodeId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => NodeSelectionScreen(
          questId: widget.questId,
          selectedNodeId: _targetNodeId,
          allowCreate: true,
        ),
      ),
    );

    if (nodeId != null && mounted) {
      setState(() {
        _targetNodeId = nodeId;
        _scriptAssetId = null;
      });
    }
  }

  Future<void> _loadMetadataNames() async {
    try {
      final metaPath = QuestPaths.metadata(widget.questId);
      if (!await (await _qs()).exists(metaPath)) return;
      final metadata = await _readMap(metaPath);
      if (!mounted) return;
      setState(() {
        _resourceNames.clear();
        metadata.forEach((key, value) {
          if (value is Map && value['name'] != null) {
            _resourceNames[key.toString()] = value['name'].toString();
          } else if (value is String) {
            _resourceNames[key.toString()] = value;
          }
        });
      });
    } catch (_) {}
  }

  String _resolveScriptDisplayName(String? scriptPath) {
    if (scriptPath == null || scriptPath.trim().isEmpty) {
      return tr('Скрипт не выбран');
    }
    final fileName = p.basename(scriptPath.trim());
    return _resourceNames[fileName] ?? fileName;
  }

  Future<String?> _selectOrCreateScriptPath() async {
    final cs = Theme.of(context).colorScheme;
    final choice = await showAdaptiveSheet<String>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.add, color: cs.primary),
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
      if (!mounted) return null;
      final res = await Navigator.push<SelectableResource>(
        context,
        MaterialPageRoute(
          builder: (_) => ResourceSelectionScreen(
            questId: widget.questId,
            allowedTypes: const ['script', 'lua'],
          ),
        ),
      );
      return res?.path;
    }

    if (choice == 'new' || choice == 'new_lua') {
      final resources = ResourceService.forQuest(widget.questId);
      final scripts = ScriptService(resources: resources);
      try {
        final created = choice == 'new_lua'
            ? await resources.createLuaScript()
            : await resources.createScript();
        _resourceNames[created.fileName] = created.name;
        if (mounted) {
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

  Future<void> _pickScript() async {
    final path = await _selectOrCreateScriptPath();
    if (path == null) return;
    if (!mounted) return;
    setState(() {
      _scriptAssetId = path;
      _targetNodeId = null;
    });
  }

  Future<void> _editCurrentScript() async {
    final scriptPath = _scriptAssetId;
    if (scriptPath == null || scriptPath.trim().isEmpty) return;

    final fullPath = QuestPaths.questFile(widget.questId, scriptPath);
    if (!await (await _qs()).exists(fullPath)) return;

    if (!mounted) return;
    // Маршрутизация .lua/.json через ScriptService (План 014).
    final scripts = ScriptService(
      resources: ResourceService.forQuest(widget.questId),
    );
    unawaited(scripts.openEditor(
        context,
        scriptPath,
        mode: EditorOpenMode.routeOnly,
      ));
  }

  void _save() {
    widget.onSave(
      ModalButtonConfig(
        id: widget.button.id,
        text: _textController.text.trim(),
        targetNodeId: _targetNodeId,
        scriptAssetId: _scriptAssetId,
        isPrimary: _isPrimary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Material(
          color: cs.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      tr('Редактирование кнопки'),
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close, color: cs.onSurfaceVariant),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Текст кнопки
                Text(
                  tr('Текст кнопки'),
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        style: TextStyle(color: cs.onSurface),
                        decoration: InputDecoration(
                          hintText: tr('Текст кнопки'),
                          hintStyle: TextStyle(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                          ),
                          filled: true,
                          fillColor: cs.surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _editFormula,
                      icon: Icon(Icons.functions, color: cs.primary),
                      tooltip: tr('Редактор формул'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Действие
                Text(
                  tr('Действие'),
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Material(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        RadioListTile<bool>(
                          value: false,
                          groupValue: _scriptAssetId != null,
                          onChanged: (value) {
                            setState(() => _scriptAssetId = null);
                          },
                          title: Text(
                            tr('Перейти к ноде'),
                            style: TextStyle(color: cs.onSurface),
                          ),
                          activeColor: cs.primary,
                        ),
                        if (_scriptAssetId == null)
                          Padding(
                            padding: const EdgeInsets.only(left: 48),
                            child: SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _selectTargetNode,
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: Text(
                                  _targetNodeId != null
                                      ? tr('Нода выбрана')
                                      : tr('Выбрать ноду'),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: cs.onSurface,
                                  side: BorderSide(color: cs.primary),
                                ),
                              ),
                            ),
                          ),
                        Divider(color: cs.outlineVariant, height: 24),
                        RadioListTile<bool>(
                          value: true,
                          groupValue: _scriptAssetId != null,
                          onChanged: (value) {
                            _pickScript();
                          },
                          title: Text(
                            tr('Выполнить скрипт'),
                            style: TextStyle(color: cs.onSurface),
                          ),
                          activeColor: cs.primary,
                        ),
                        if (_scriptAssetId != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 48, right: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _resolveScriptDisplayName(_scriptAssetId),
                                    style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.edit,
                                    color: cs.tertiary,
                                    size: 18,
                                  ),
                                  onPressed: _editCurrentScript,
                                  tooltip: tr('Редактировать скрипт'),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Primary кнопка
                SwitchListTile(
                  value: _isPrimary,
                  onChanged: (value) {
                    setState(() => _isPrimary = value);
                  },
                  title: Text(
                    tr('Основная кнопка'),
                    style: TextStyle(color: cs.onSurface),
                  ),
                  activeColor: cs.primary,
                ),
                const SizedBox(height: 24),
                // Кнопка сохранения
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      tr('Сохранить'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
