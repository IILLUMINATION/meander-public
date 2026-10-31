import 'dart:async';

import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:canvas_app/features/editor/services/trigger_service.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/button_style_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/button_style_presets_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:mnd_player/widgets/content_display_factory.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';

enum _ButtonActionType { goToNode, runScript }

class _SavedButtonPreset {
  final String name;
  final ButtonStyleConfig config;

  const _SavedButtonPreset({required this.name, required this.config});
}

class ButtonEditorScreen extends StatefulWidget {
  final String questId;
  final String currentNodeId;
  final ContentItem? existingItem;
  final String? initialText;
  final String? initialTarget;

  const ButtonEditorScreen({
    super.key,
    required this.questId,
    required this.currentNodeId,
    this.existingItem,
    this.initialText,
    this.initialTarget,
  });

  @override
  State<ButtonEditorScreen> createState() => _ButtonEditorScreenState();
}

class _ButtonEditorScreenState extends State<ButtonEditorScreen> {
  final _textController = TextEditingController();
  _ButtonActionType _actionType = _ButtonActionType.goToNode;
  String? _targetNodeId;
  String? _targetNodeTitle;
  String? _scriptPath;
  final Map<String, String> _resourceNames = {};
  bool? _wrapTextOverride;
  ButtonStyleConfig? _buttonStyle;
  String _styleChoice = 'default';
  List<_SavedButtonPreset> _customButtonPresets = const [];

  /// Пресет, назначенный квесту как оформление по умолчанию (#159). Кнопка без
  /// своего стиля играет именно им — превью обязано показывать то же, что
  /// увидит игрок, а не встроенное стекло.
  ButtonStyleConfig? _questDefaultStyle;

  String get _buttonPresetsPath => QuestPaths.buttonPresets(widget.questId);
  String get _configPath => QuestPaths.config(widget.questId);

  @override
  void initState() {
    super.initState();
    final existing = widget.existingItem;
    _textController.text = widget.initialText ?? existing?.text ?? '';
    _targetNodeId = widget.initialTarget ?? existing?.targetNodeId;
    _scriptPath = existing?.scriptTriggers?['onPress'];
    _wrapTextOverride = existing?.wrapTextOverride;
    _buttonStyle = existing?.buttonStyle;
    if (_buttonStyle != null) {
      final presetId = _buttonStyle!.presetId;
      if (presetId == 'fantasy' || presetId == 'classic') {
        _buttonStyle = null;
        _styleChoice = 'default';
      } else if ((_buttonStyle!.presetName?.trim().isNotEmpty ?? false)) {
        _styleChoice = 'custom:${_buttonStyle!.presetName!.trim()}';
      } else {
        _styleChoice = 'custom';
      }
    }
    if (_scriptPath != null && _scriptPath!.isNotEmpty) {
      _actionType = _ButtonActionType.runScript;
    }
    _loadMetadataNames();
    _loadButtonPresets();
    _resolveTargetNodeTitle();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _resolveTargetNodeTitle() async {
    final id = _targetNodeId;
    if (id == null || id.isEmpty || id.startsWith('=')) return;
    try {
      final data = await QuestNodesStore.read(widget.questId);
      final nodes = data['nodes'] as List<dynamic>? ?? const [];
      final found = nodes.firstWhereOrNull(
        (n) => n is Map && n['id']?.toString() == id,
      );
      if (found is Map && mounted) {
        setState(() {
          _targetNodeTitle = found['title']?.toString();
        });
      }
    } catch (_) {}
  }

  Future<void> _pickTargetNode() async {
    final hint = _textController.text.trim();
    final targetId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => NodeSelectionScreen(
          questId: widget.questId,
          currentNodeId: widget.currentNodeId,
          selectedNodeId:
              _targetNodeId != null && !_targetNodeId!.startsWith('=')
              ? _targetNodeId
              : null,
          suggestedTitle: hint.isEmpty ? null : hint,
        ),
      ),
    );
    if (targetId == null) return;
    await saveConnection(widget.questId, widget.currentNodeId, targetId);
    if (!mounted) return;
    setState(() {
      _targetNodeId = targetId;
      _targetNodeTitle = null;
    });
    _resolveTargetNodeTitle();
  }

  Future<void> _editButtonText() async {
    final value = await _showPlainTextDialog(
      title: tr('Текст кнопки'),
      initialValue: _textController.text,
    );
    if (value != null) {
      if (!mounted) return;
      setState(() => _textController.text = value);
    }
  }

  Future<void> _editButtonTextFormula() async {
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => ExpressionEditorScreen(
          initialValue: _textController.text,
          questId: widget.questId,
        ),
      ),
    );
    if (value != null) {
      if (!mounted) return;
      setState(() => _textController.text = _stripWrappingQuotes(value));
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

  Future<String?> _selectOrCreateScript() async {
    final scheme = Theme.of(context).colorScheme;
    final choice = await showAdaptiveSheet<String>(
      context: context,
      backgroundColor: scheme.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(Icons.add_rounded, color: scheme.primary),
                title: Text(tr('Новый визуальный скрипт')),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
              ListTile(
                leading: const Icon(
                  Icons.data_object_rounded,
                  color: Colors.deepPurple,
                ),
                title: Text(tr('Новый Lua-скрипт')),
                onTap: () => Navigator.pop(ctx, 'new_lua'),
              ),
              ListTile(
                leading: Icon(Icons.folder_rounded, color: scheme.primary),
                title: Text(tr('Существующий')),
                onTap: () => Navigator.pop(ctx, 'existing'),
              ),
              const SizedBox(height: 8),
            ],
          ),
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
            // JSON-скрипты и .lua-файлы оба могут быть триггером кнопки.
            allowedTypes: const ['script', 'lua'],
          ),
        ),
      );
      return res?.path;
    } else if (choice == 'new' || choice == 'new_lua') {
      // Мгновенное создание (План 014, этап A2): авто-имя, без диалогов,
      // сразу редактор.
      final resources = ResourceService.forQuest(widget.questId);
      final scripts = ScriptService(resources: resources);
      try {
        final created = choice == 'new_lua'
            ? await resources.createLuaScript()
            : await resources.createScript();
        _resourceNames[created.fileName] = created.name;
        if (mounted) {
          unawaited(
            scripts.openEditor(
              context,
              created.questRelativePath,
              mode: EditorOpenMode.routeOnly,
            ),
          );
        }
        return created.questRelativePath;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> _pickScript() async {
    final sp = await _selectOrCreateScript();
    if (sp == null) return;
    if (!mounted) return;
    setState(() => _scriptPath = sp);
  }

  Future<void> _loadMetadataNames() async {
    try {
      final metaPath = QuestPaths.metadata(widget.questId);
      if (!await FileStorage.exists(metaPath)) return;
      final metadata = await FileStorage.readJsonFile(metaPath);
      if (!mounted) return;
      setState(() {
        _resourceNames.clear();
        metadata.forEach((key, value) {
          if (value is Map && value['name'] != null) {
            _resourceNames[key] = value['name'].toString();
          } else if (value is String) {
            _resourceNames[key] = value;
          }
        });
      });
    } catch (_) {}
  }

  Future<void> _loadButtonPresets() async {
    try {
      final qs = await QuestStore.defaultInstance();
      final presetByName = <String, _SavedButtonPreset>{};
      String? questDefaultName;
      if (await qs.exists(_configPath)) {
        final config = await qs.readJson(_configPath) ?? {};
        questDefaultName = (config['defaultButtonPresetName'] as String?)
            ?.trim();
        final rawConfigPresets =
            config['buttonStylePresets'] as List<dynamic>? ?? const [];
        for (final raw in rawConfigPresets) {
          if (raw is! Map) continue;
          final cfg = ButtonStyleConfig.fromJson(
            Map<String, dynamic>.from(raw),
          );
          final name = cfg.presetName?.trim();
          if (name == null || name.isEmpty) continue;
          presetByName[name] = _SavedButtonPreset(name: name, config: cfg);
        }
      }

      if (presetByName.isEmpty && await qs.exists(_buttonPresetsPath)) {
        final legacy = await qs.readJson(_buttonPresetsPath) ?? {};
        final list = legacy['presets'] as List<dynamic>? ?? const [];
        for (final raw in list) {
          if (raw is! Map) continue;
          final map = Map<String, dynamic>.from(raw);
          final name = map['name']?.toString().trim();
          final configRaw = map['config'];
          if (name == null || name.isEmpty || configRaw is! Map) continue;
          presetByName[name] = _SavedButtonPreset(
            name: name,
            config: ButtonStyleConfig.fromJson(
              Map<String, dynamic>.from(configRaw),
            ).copyWith(presetName: name),
          );
        }
      }

      final presets = presetByName.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _customButtonPresets = presets;
        _questDefaultStyle =
            (questDefaultName == null || questDefaultName.isEmpty)
            ? null
            : presetByName[questDefaultName]?.config;
        if (_buttonStyle != null &&
            (_buttonStyle!.presetName?.isNotEmpty ?? false)) {
          final key = 'custom:${_buttonStyle!.presetName!}';
          if (_customButtonPresets.any((p) => 'custom:${p.name}' == key)) {
            _styleChoice = key;
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _openPresetsEditor() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ButtonStylePresetsScreen(questId: widget.questId),
      ),
    );
    await _loadButtonPresets();
    if (!mounted) return;
    if (_styleChoice.startsWith('custom:')) {
      _applyStyleChoice(_styleChoice);
    }
  }

  /// Открывает полный редактор параметров стиля. Работает и когда стиль не
  /// выбран (редактор стартует с настоящего дефолта игры — стеклянной
  /// кнопки), и поверх пресета (копия пресета становится индивидуальным
  /// стилем кнопки).
  Future<void> _openStyleEditor() async {
    final edited = await Navigator.push<ButtonStyleConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => ButtonStyleEditorScreen(
          questId: widget.questId,
          initialStyle: _buttonStyle,
          sampleText: _textController.text.trim().isEmpty
              ? null
              : _textController.text.trim(),
        ),
      ),
    );
    // null = отмена или «не менял параметры» — стиль остаётся как был.
    if (edited == null || !mounted) return;
    setState(() {
      _buttonStyle = edited.copyWith(presetId: 'custom', presetName: null);
      _styleChoice = 'custom';
    });
    // После редактора могли сохранить новый пресет — подтягиваем список.
    await _loadButtonPresets();
  }

  void _applyStyleChoice(String choice) {
    setState(() {
      _styleChoice = choice;
      if (choice == 'default') {
        _buttonStyle = null;
        return;
      }
      if (choice == 'custom') {
        return;
      }
      if (choice.startsWith('custom:')) {
        final name = choice.substring('custom:'.length);
        final preset = _customButtonPresets
            .where((p) => p.name == name)
            .firstOrNull;
        if (preset != null) {
          _buttonStyle = preset.config.copyWith(
            presetId:
                'customPreset:${preset.name.toLowerCase().replaceAll(" ", "_")}',
            presetName: preset.name,
          );
        }
        return;
      }
    });
  }

  String _resolveScriptDisplayName(String? scriptPath) {
    if (scriptPath == null || scriptPath.trim().isEmpty) {
      return tr('Скрипт не выбран');
    }
    final fileName = p.basename(scriptPath.trim());
    return _resourceNames[fileName] ?? fileName;
  }

  Future<void> _editCurrentScript() async {
    if (_scriptPath == null) return;
    final fullPath = QuestPaths.questFile(widget.questId, _scriptPath!);
    if (!await FileStorage.exists(fullPath)) {
      _showSnack(tr('Скрипт не найден'));
      return;
    }

    if (!mounted) return;
    // Маршрутизация .lua/.json через ScriptService (План 014).
    final scripts = ScriptService(
      resources: ResourceService.forQuest(widget.questId),
    );
    await scripts.openEditor(
      context,
      _scriptPath!,
      mode: EditorOpenMode.routeOnly,
    );
  }

  Future<void> _editTargetFormula() async {
    final currentFormula =
        _targetNodeId != null && _targetNodeId!.startsWith('=')
        ? _targetNodeId!.substring(1)
        : '';
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => ExpressionEditorScreen(
          initialValue: currentFormula,
          questId: widget.questId,
        ),
      ),
    );
    if (value != null && value.trim().isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _targetNodeId = '=${value.trim()}';
        _targetNodeTitle = null;
      });
    }
  }

  Future<bool> _save() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      _showSnack(tr('Введите текст кнопки'));
      return false;
    }

    if (_actionType == _ButtonActionType.goToNode && _targetNodeId == null) {
      _showSnack(tr('Выберите ноду для перехода'));
      return false;
    }
    if (_actionType == _ButtonActionType.runScript && _scriptPath == null) {
      _showSnack(tr('Выберите или создайте скрипт'));
      return false;
    }

    Map<String, String>? triggers = widget.existingItem?.scriptTriggers != null
        ? Map.from(widget.existingItem!.scriptTriggers!)
        : null;

    if (_actionType == _ButtonActionType.runScript) {
      triggers ??= {};
      triggers['onPress'] = _scriptPath!;
    } else {
      triggers?.remove('onPress');
      if (triggers != null && triggers.isEmpty) triggers = null;
    }

    final result = ContentItem(
      id: widget.existingItem?.id ?? const Uuid().v4(),
      type: 'button',
      text: text,
      targetNodeId: _actionType == _ButtonActionType.goToNode
          ? _targetNodeId
          : null,
      scriptTriggers: triggers,
      flex: widget.existingItem?.flex ?? 1,
      wrapText: widget.existingItem?.wrapText ?? true,
      wrapTextOverride: _wrapTextOverride,
      buttonStyle: _buttonStyle,
    );

    Navigator.pop(context, result);
    return true;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<String?> _showPlainTextDialog({
    required String title,
    String initialValue = '',
  }) {
    final controller = TextEditingController(text: initialValue);
    return showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('ОК')),
          ),
        ],
      ),
    );
  }

  Widget _buildStylePreview({String? sampleText}) {
    final text =
        sampleText ??
        (_textController.text.trim().isEmpty
            ? tr('Пример текста')
            : _textController.text.trim());
    return Center(
      child: GlassButton(
        onPressed: null,
        text: text,
        wrapText: true,
        // Тот же порядок, что в игре: свой стиль кнопки, иначе стиль квеста,
        // иначе встроенное стекло (#159).
        styleConfig: _buttonStyle ?? _questDefaultStyle,
        fontFamily: null,
        questId: widget.questId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final customValues = _customButtonPresets
        .map((p) => 'custom:${p.name}')
        .toSet();
    final dropdownValue =
        (_styleChoice == 'default' ||
            _styleChoice == 'custom' ||
            customValues.contains(_styleChoice))
        ? _styleChoice
        : 'default';

    return PopScope(
      // При создании новой кнопки бэк просто закрывает экран (отмена) — не
      // блокируем выход. При редактировании существующей — бэк сохраняет.
      canPop: widget.existingItem == null,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _save();
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          title: Text(tr('Кнопка'), style: textTheme.titleLarge),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton.filledTonal(
                onPressed: _save,
                icon: const Icon(Icons.check_rounded),
                tooltip: tr('Сохранить'),
              ),
            ),
          ],
        ),
        body: AdaptiveContent(
          maxWidth: 720,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionLabel(tr('Текст кнопки'), scheme, textTheme),
                  _buildCard(
                    scheme: scheme,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        InkWell(
                          onTap: _editButtonText,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Text(
                              _textController.text.isEmpty
                                  ? tr('Нажмите, чтобы ввести текст')
                                  : _textController.text,
                              style: textTheme.bodyLarge?.copyWith(
                                color: _textController.text.isEmpty
                                    ? scheme.onSurfaceVariant
                                    : scheme.onSurface,
                              ),
                              maxLines: 3,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _editButtonText,
                                icon: const Icon(Icons.edit_rounded, size: 18),
                                label: Text(tr('Текст')),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _editButtonTextFormula,
                                icon: const Icon(
                                  Icons.functions_rounded,
                                  size: 18,
                                ),
                                label: Text(tr('Формула')),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),
                  _buildSectionLabel(tr('Действие'), scheme, textTheme),
                  _buildCard(
                    scheme: scheme,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SegmentedButton<_ButtonActionType>(
                          segments: [
                            ButtonSegment(
                              value: _ButtonActionType.goToNode,
                              label: Text(tr('К ноде')),
                              icon: Icon(Icons.arrow_forward_rounded),
                            ),
                            ButtonSegment(
                              value: _ButtonActionType.runScript,
                              label: Text(tr('Скрипт')),
                              icon: Icon(Icons.code_rounded),
                            ),
                          ],
                          selected: {_actionType},
                          onSelectionChanged: (s) =>
                              setState(() => _actionType = s.first),
                        ),
                        const SizedBox(height: 12),
                        if (_actionType == _ButtonActionType.goToNode)
                          _buildTargetNodeBlock(scheme, textTheme),
                        if (_actionType == _ButtonActionType.runScript)
                          _buildScriptBlock(scheme, textTheme),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),
                  _buildSectionLabel(tr('Перенос текста'), scheme, textTheme),
                  _buildCard(
                    scheme: scheme,
                    child: Column(
                      children: [
                        _buildWrapOption(
                          scheme,
                          textTheme,
                          value: null,
                          title: tr('Как в настройках квеста'),
                          subtitle: tr(
                            'Использовать общий параметр переноса текста на кнопках.',
                          ),
                        ),
                        _buildWrapOption(
                          scheme,
                          textTheme,
                          value: true,
                          title: tr('Переносить'),
                          subtitle: tr(
                            'Локально разрешить перенос текста на несколько строк.',
                          ),
                        ),
                        _buildWrapOption(
                          scheme,
                          textTheme,
                          value: false,
                          title: tr('Не переносить'),
                          subtitle: tr(
                            'Локально показывать кнопку в одну строку.',
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),
                  _buildSectionLabel(
                    tr('Стилизация кнопки'),
                    scheme,
                    textTheme,
                  ),
                  _buildCard(
                    scheme: scheme,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButtonFormField<String>(
                          value: dropdownValue,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: tr('Шаблон'),
                            filled: true,
                            fillColor: scheme.surface,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: scheme.outlineVariant,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: scheme.outlineVariant,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: scheme.primary,
                                width: 1.5,
                              ),
                            ),
                          ),
                          items: [
                            if (_styleChoice == 'custom')
                              DropdownMenuItem(
                                value: 'custom',
                                child: Text(tr('Текущий (без пресета)')),
                              ),
                            DropdownMenuItem(
                              value: 'default',
                              child: Text(
                                _questDefaultStyle?.presetName == null
                                    ? tr('Без кастомного стиля')
                                    : trf('Как в квесте: {p0}', {
                                        'p0': _questDefaultStyle!.presetName,
                                      }),
                              ),
                            ),
                            ..._customButtonPresets.map(
                              (preset) => DropdownMenuItem(
                                value: 'custom:${preset.name}',
                                child: Text(
                                  trf('Пресет: {p0}', {'p0': preset.name}),
                                ),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            _applyStyleChoice(value);
                          },
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _openPresetsEditor,
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: Text(tr('Редактор пресетов')),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.tonalIcon(
                            onPressed: _openStyleEditor,
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: Text(tr('Настроить параметры')),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_styleChoice == 'custom')
                          Text(
                            tr(
                              'Индивидуальный стиль: изменение параметров не влияет на пресеты.',
                            ),
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        else
                          Text(
                            tr(
                              'Параметры выбранного пресета можно изменить, не трогая сам пресет.',
                            ),
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        const SizedBox(height: 12),
                        Text(
                          tr('Превью (как в игре)'),
                          style: textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: _buildStylePreview(),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.check_rounded),
                      label: Text(tr('Сохранить')),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(
    String title,
    ColorScheme scheme,
    TextTheme textTheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: textTheme.titleSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildCard({required ColorScheme scheme, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _buildTargetNodeBlock(ColorScheme scheme, TextTheme textTheme) {
    final isFormula = _targetNodeId != null && _targetNodeId!.startsWith('=');
    final hasTarget = _targetNodeId != null;

    String titleText;
    String? subtitleText;
    IconData leadingIcon;
    Color leadingBg;
    Color leadingFg;

    if (!hasTarget) {
      titleText = tr('Нода не выбрана');
      subtitleText = tr('Выберите целевую ноду для перехода');
      leadingIcon = Icons.help_outline_rounded;
      leadingBg = scheme.surface;
      leadingFg = scheme.onSurfaceVariant;
    } else if (isFormula) {
      titleText = tr('Формула');
      subtitleText = _targetNodeId!.substring(1);
      leadingIcon = Icons.functions_rounded;
      leadingBg = scheme.tertiaryContainer;
      leadingFg = scheme.onTertiaryContainer;
    } else {
      titleText = _targetNodeTitle ?? tr('Нода');
      subtitleText = _targetNodeId;
      leadingIcon = Icons.arrow_forward_rounded;
      leadingBg = scheme.primaryContainer;
      leadingFg = scheme.onPrimaryContainer;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _pickTargetNode,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: leadingBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(leadingIcon, color: leadingFg, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          titleText,
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitleText != null && subtitleText.isNotEmpty)
                          Text(
                            subtitleText,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontFamily: isFormula ? 'monospace' : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _pickTargetNode,
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                label: Text(tr('Выбрать ноду')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _editTargetFormula,
                icon: const Icon(Icons.functions_rounded, size: 18),
                label: Text(tr('Формула ID')),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildScriptBlock(ColorScheme scheme, TextTheme textTheme) {
    final hasScript = _scriptPath != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _pickScript,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: hasScript
                          ? scheme.primaryContainer
                          : scheme.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.code_rounded,
                      color: hasScript
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _resolveScriptDisplayName(_scriptPath),
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hasScript)
                    IconButton(
                      onPressed: _editCurrentScript,
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      tooltip: tr('Редактировать'),
                    ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWrapOption(
    ColorScheme scheme,
    TextTheme textTheme, {
    required bool? value,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _wrapTextOverride == value;
    return InkWell(
      onTap: () => setState(() => _wrapTextOverride = value),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Radio<bool?>(
              value: value,
              groupValue: _wrapTextOverride,
              onChanged: (v) => setState(() => _wrapTextOverride = v),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: textTheme.bodyLarge?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
