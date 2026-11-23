import 'dart:async';
import 'dart:convert';
import 'package:canvas_app/core/services/template_asset_installer.dart';
import 'package:canvas_app/core/utils/content_item_utils.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/features/editor/providers/template_provider.dart';
import 'package:canvas_app/features/editor/utils/template_applier.dart';
import 'package:canvas_app/features/editor/widgets/template_picker_sheet.dart';
import 'package:canvas_app/features/editor/widgets/template_save_dialog.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:canvas_app/features/editor/screens/node_content/content_editor_logic.dart';
import 'package:canvas_app/features/editor/logic/item_editor_helper.dart';
import 'package:canvas_app/features/editor/screens/node_content/content_item_card.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:mnd_player/services/font_service.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:canvas_app/features/plugins/models/plugin_content_type.dart';
import 'package:canvas_app/features/plugins/providers/plugin_content_types_provider.dart';
import 'package:canvas_app/features/editor/widgets/plugin_content_form.dart';
import 'package:mnd_player/utils/trigger_reference.dart';
import 'package:collection/collection.dart';
import 'package:canvas_app/features/editor/widgets/content_add_menu.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

const String _contentClipboardPrefix = 'MND_CONTENT_ITEM::';
ContentItem? _contentItemClipboardItem;

class ContainerEditorScreen extends ConsumerStatefulWidget {
  final String questId;
  final String nodeId;
  final String containerType;
  final List<ContentItem> initialChildren;
  final String initialAlignment;
  final String initialTextFit;
  final String initialRowTextAlign;
  final double? initialItemSpacing;

  /// Формула зазора (`numericExprs['itemSpacing']`) — движок считает её в
  /// плеере, [_currentItemSpacing] остаётся числом-превью.
  final String? initialSpacingExpr;
  final bool? initialChildImageRoundedCorners;
  final String? initialFontFamily;

  final Map<String, dynamic>? initialPluginData;

  /// Вызывается перед запуском симуляции из контейнера,
  /// чтобы родитель сохранил ноду с актуальными данными.
  final Future<void> Function(Map<String, dynamic>)? onAutoSave;

  /// Форсированное сохранение ноды на диск перед запуском симуляции.
  /// Вызывается после [onAutoSave] и дожидается завершения записи: без него
  /// debounced-сохранение родителя не успевает, и игра читает ноду без
  /// добавленных внутрь ряда/колонки детей (#39).
  final Future<void> Function()? onForceSave;

  final void Function(String targetNodeId)? onJumpToNode;
  final bool fromGameSession;

  const ContainerEditorScreen({
    super.key,
    required this.questId,
    required this.nodeId,
    required this.containerType,
    required this.initialChildren,
    this.initialAlignment = 'center',
    this.initialTextFit = 'auto',
    this.initialRowTextAlign = 'center',
    this.initialItemSpacing,
    this.initialSpacingExpr,
    this.initialChildImageRoundedCorners,
    this.initialFontFamily,
    this.initialPluginData,
    this.onAutoSave,
    this.onForceSave,
    this.onJumpToNode,
    this.fromGameSession = false,
  });

  @override
  ConsumerState<ContainerEditorScreen> createState() =>
      _ContainerEditorScreenState();
}

class _ContainerEditorScreenState extends ConsumerState<ContainerEditorScreen> {
  late List<ContentItem> _children;
  late ContentEditorLogic _logic;
  late String _currentAlignment;
  late String _currentTextFit;
  late String _currentRowTextAlign;
  double? _currentItemSpacing;

  /// Формула зазора между детьми; пустая строка и `null` — «формулы нет».
  String? _currentSpacingExpr;
  bool? _currentChildImageRoundedCorners;
  Map<String, dynamic>? _currentPluginData;

  /// Шрифт контейнера (путь ресурса res/fonts/...): наследуется детьми,
  /// у которых нет своего шрифта.
  String? _currentFontFamily;
  final Map<String, String> _resourceNames = {};

  String get _rowEditorTitle => tr('Редактор Строки');
  String get _columnEditorTitle => tr('Редактор Столбца');
  String _fontLabel(String path) {
    final base = path.contains('/')
        ? path.substring(path.lastIndexOf('/') + 1)
        : path;
    return base;
  }

  Future<void> _pickContainerFont(
    void Function(VoidCallback fn) setModalState,
    BuildContext sheetContext,
  ) async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['font'],
        ),
      ),
    );
    if (result == null || !sheetContext.mounted) return;
    await FontService.loadQuestFont(widget.questId, result.path);
    if (!sheetContext.mounted) return;
    setModalState(() => _currentFontFamily = result.path);
  }

  String get _settingsTooltip => tr('Настройки');

  String get _textFitLabel {
    if (_currentTextFit == 'auto') {
      return tr('Текст: Авто (по квесту)');
    }
    if (_currentTextFit == 'scale') {
      return tr('Текст: Масштабирование');
    }
    return tr('Текст: Перенос');
  }

  @override
  void initState() {
    super.initState();
    _children = List.from(widget.initialChildren);
    _currentAlignment = widget.initialAlignment;
    _currentTextFit = widget.initialTextFit;
    _currentRowTextAlign = widget.initialRowTextAlign;
    _currentItemSpacing = widget.initialItemSpacing;
    _currentSpacingExpr = widget.initialSpacingExpr;
    _currentChildImageRoundedCorners = widget.initialChildImageRoundedCorners;
    _currentFontFamily = widget.initialFontFamily;
    _currentPluginData = widget.initialPluginData != null
        ? Map<String, dynamic>.from(widget.initialPluginData!)
        : null;
    _logic = ContentEditorLogic(
      context: context,
      questId: widget.questId,
      currentNodeId: widget.nodeId,
    );
    _loadMetadata();
  }

  Future<void> _loadMetadata() async {
    try {
      final metaPath = QuestPaths.metadata(widget.questId);
      if (await FileStorage.exists(metaPath)) {
        final metaData = await FileStorage.readJsonFile(metaPath);
        if (mounted) {
          setState(() {
            _resourceNames.clear();
            metaData.forEach((key, value) {
              if (value is Map && value['name'] != null) {
                _resourceNames[key] = value['name'];
              } else if (value is String) {
                _resourceNames[key] = value;
              }
            });
          });
        }
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Симуляция (запуск игры из контейнерного редактора)
  // ---------------------------------------------------------------------------

  /// Черновик/финал из вложенного редактора: сразу в список детей, чтобы
  /// закрытие ради сохранения не требовалось.
  void _upsertChild(ContentItem item) {
    if (!mounted) return;
    final index = _children.indexWhere((existing) => existing.id == item.id);
    final normalized = item.copyWith(flex: 1);
    if (index >= 0) {
      setState(() => _children[index] = normalized);
    } else {
      setState(() => _children.add(normalized));
    }
    widget.onAutoSave?.call(_currentState());
  }

  Map<String, dynamic> _currentState() => {
    'children': _children,
    'alignment': _currentAlignment,
    'textFit': _currentTextFit,
    'rowTextAlign': _currentRowTextAlign,
    if (_currentItemSpacing != null) 'itemSpacing': _currentItemSpacing,
    'spacingExpr': _currentSpacingExpr ?? '',
    if (_currentChildImageRoundedCorners != null)
      'childImageRoundedCorners': _currentChildImageRoundedCorners,
    if (_currentFontFamily != null) 'fontFamily': _currentFontFamily,
    if (_currentPluginData != null) 'pluginData': _currentPluginData,
  };

  Future<void> _launchQuest() async {
    if (widget.onAutoSave != null) {
      await widget.onAutoSave!(_currentState());
    }
    // Дети ряда/колонки живут в родительской ноде, а её запись отложена
    // debounce'ом: без форс-сейва симуляция стартует со старым списком
    // детей, и добавленный контент «пропадает» (#39).
    await widget.onForceSave?.call();
    if (!mounted) return;

    if (widget.fromGameSession) {
      Navigator.pop(context, true);
    } else {
      await EditorDocumentLauncher.openGameSimulation(
        context,
        widget.questId,
        startNodeId: widget.nodeId,
      );
    }
  }

  Future<void> _launchQuestFromSave() async {
    if (widget.onAutoSave != null) {
      await widget.onAutoSave!(_currentState());
    }
    // Та же причина, что и в [_launchQuest]: нода должна быть на диске.
    await widget.onForceSave?.call();
    if (!mounted) return;
    await EditorDocumentLauncher.openGameFromSave(context, widget.questId);
  }

  void _deleteItem(int index) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        title: Text(tr('Удалить элемент?')),
        content: Text(tr('Это действие нельзя отменить.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      setState(() {
        _children.removeAt(index);
      });
      widget.onAutoSave?.call(_currentState());
    }
  }

  void _saveAndExit() {
    Navigator.pop(context, {
      'children': _children,
      'alignment': _currentAlignment,
      'textFit': _currentTextFit,
      'rowTextAlign': _currentRowTextAlign,
      if (_currentItemSpacing != null) 'itemSpacing': _currentItemSpacing,
      'spacingExpr': _currentSpacingExpr ?? '',
      if (_currentChildImageRoundedCorners != null)
        'childImageRoundedCorners': _currentChildImageRoundedCorners,
      if (_currentFontFamily != null) 'fontFamily': _currentFontFamily,
      if (_currentPluginData != null) 'pluginData': _currentPluginData,
    });
  }

  Future<void> _copyItemAt(int index) async {
    final item = _children[index];
    _contentItemClipboardItem = item;
    await Clipboard.setData(
      ClipboardData(
        text: '$_contentClipboardPrefix${jsonEncode(item.toJson())}',
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Элемент скопирован')),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<ContentItem?> _readContentItemFromClipboard() async {
    ContentItem? source = _contentItemClipboardItem;
    final clipboardData = await Clipboard.getData('text/plain');
    final raw = clipboardData?.text?.trim() ?? '';
    if (raw.startsWith(_contentClipboardPrefix)) {
      final payload = raw.substring(_contentClipboardPrefix.length);
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          source = ContentItem.fromJson(decoded);
        } else if (decoded is Map) {
          source = ContentItem.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }
    return source;
  }

  Future<void> _pasteCopiedItem() async {
    final source = await _readContentItemFromClipboard();
    if (!mounted) return;

    if (source == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Буфер элементов пуст')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final newItem = ContentItemUtils.duplicate(source);
    setState(() {
      _children.add(newItem);
    });
  }

  // ============================================================
  // Templates
  // ============================================================

  Future<void> _saveItemAsTemplate(int index) async {
    if (index < 0 || index >= _children.length) return;
    final item = _children[index];

    final TemplateKind kind;
    switch (item.type) {
      case 'row':
        kind = TemplateKind.row;
        break;
      case 'column':
        kind = TemplateKind.column;
        break;
      case 'modal':
        kind = TemplateKind.modal;
        break;
      default:
        kind = TemplateKind.content;
    }

    final result = await TemplateSaveDialog.show(
      context,
      title: tr('Сохранить как шаблон'),
      kind: kind,
      initialName: (item.text != null && item.text!.trim().isNotEmpty)
          ? item.text!.trim()
          : null,
    );
    if (result == null || !mounted) return;

    final template = TemplateApplier.makeFromContentItem(
      name: result.name,
      item: item,
      description: result.description,
      category: result.category,
    );

    final actions = ref.read(templateActionsProvider);
    if (result.scope == TemplateScope.global) {
      await actions.saveAsGlobal(template, sourceQuestId: widget.questId);
    } else {
      await actions.saveToQuest(widget.questId, template);
    }

    // Дожидаемся перечитывания templatesByIdProvider, чтобы карточка
    // сразу нашла master и отрисовалась золотой (а не «битой ссылкой»
    // на ~100мс пока провайдер в loading).
    try {
      await ref.read(templatesByIdProvider(widget.questId).future);
    } catch (_) {}

    // Помечаем исходный item как мастер-элемент шаблона. Дальше любые
    // правки этого item'а будут синхронизироваться обратно в
    // TemplateRepository (см. node_content_screen._syncMasterTemplates),
    // и все linked-инстансы автоматически обновятся.
    if (!mounted) return;
    setState(() {
      _children[index] = item.copyWith(
        templateRef: template.id,
        templateVersion: template.contentVersion,
        isTemplateMaster: true,
      );
    });
    // ignore: avoid_print
    print(
      '[Templates] Container item ${item.id} marked as master of template '
      '${template.id}',
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Шаблон сохранён. Элемент помечен как мастер.')),
        backgroundColor: Colors.amber.shade700,
      ),
    );
  }

  Future<void> _insertFromTemplate({int? intoContainerIndex}) async {
    final picked = await TemplatePickerSheet.showWithMode(
      context,
      questId: widget.questId,
      allowedKinds: const {
        TemplateKind.content,
        TemplateKind.row,
        TemplateKind.column,
        TemplateKind.modal,
      },
      title: tr('Вставить из шаблона'),
      allowLinked: true,
    );
    if (picked == null || !mounted) return;
    final template = picked.template;

    // --- Linked-режим: вставляем тонкий инстанс, мастер пиннется в квест ---
    if (picked.mode == TemplatePickMode.linked) {
      // Если мастер был глобальным — копируем его в квест (с ассетами),
      // чтобы при экспорте квеста линкованный инстанс не остался без мастера.
      TemplateItem masterInQuest = template;
      try {
        if (picked.wasGlobal) {
          masterInQuest = await ref
              .read(templateActionsProvider)
              .pinToQuest(template, widget.questId);
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Не удалось закрепить шаблон в квесте: {p0}', {'p0': friendlyError(e)}),
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final linked = TemplateApplier.buildLinkedContentItem(masterInQuest);
      if (linked == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Не удалось создать связанный элемент')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      setState(() {
        if (intoContainerIndex != null &&
            intoContainerIndex >= 0 &&
            intoContainerIndex < _children.length) {
          final container = _children[intoContainerIndex];
          if (container.type == 'row' || container.type == 'column') {
            final children = List<ContentItem>.from(
              container.children ?? const [],
            );
            children.add(linked);
            _children[intoContainerIndex] = container.copyWith(
              children: children,
            );
            return;
          }
        }
        _children.add(linked.copyWith(flex: 1));
      });

      return;
    }

    // --- Snapshot-режим (старое поведение) ---
    // Предупреждение про плагины
    final pluginIds = TemplateApplier.collectPluginIds(template);
    if (pluginIds.isNotEmpty) {
      final cs = Theme.of(context).colorScheme;
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: cs.surfaceContainerHigh,
          title: Text(
            tr('Шаблон использует плагины'),
            style: TextStyle(color: cs.onSurface),
          ),
          content: Text(
            trf('Этот шаблон ссылается на плагины: {p0}. Если они не установлены в текущем квесте, контент может работать некорректно. Продолжить вставку?', {'p0': pluginIds.join(", ")}),
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Вставить')),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    // Сначала устанавливаем ассеты шаблона в квест (если есть).
    final installed = await TemplateAssetInstaller.installToQuest(
      template: template,
      questId: widget.questId,
    );
    final effectiveTemplate = installed.template;

    final newItem = TemplateApplier.buildContentItem(effectiveTemplate);
    if (newItem == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Не удалось построить элемент из шаблона')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      if (intoContainerIndex != null &&
          intoContainerIndex >= 0 &&
          intoContainerIndex < _children.length) {
        final container = _children[intoContainerIndex];
        if (container.type == 'row' || container.type == 'column') {
          final children = List<ContentItem>.from(
            container.children ?? const [],
          );
          children.add(newItem);
          _children[intoContainerIndex] = container.copyWith(
            children: children,
          );
          return;
        }
      }
      _children.add(newItem.copyWith(flex: 1));
    });

  }

  // ============================================================
  //  Linked-templates: меню для инстанса
  // ============================================================

  /// Открыть меню действий для linked-инстанса: посмотреть мастер,
  /// отвязать (превратить в snapshot-копию).
  Future<void> _showLinkedInstanceMenu(int index) async {
    if (index < 0 || index >= _children.length) return;
    final item = _children[index];
    if (!item.isTemplateInstance) return;

    final masters = ref.read(templatesByIdProvider(widget.questId)).valueOrNull;
    final master = masters?[item.templateRef];
    final isBroken = master == null;

    final cs = Theme.of(context).colorScheme;
    await showAdaptiveSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(
                isBroken ? Icons.link_off : Icons.link,
                color: isBroken ? cs.error : cs.tertiary,
              ),
              title: Text(
                isBroken
                    ? tr('Связанный шаблон удалён')
                    : trf('Связан с шаблоном «{p0}»', {'p0': master.name}),
                style: TextStyle(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                isBroken
                    ? tr('Содержимое больше не подгружается из мастера. Можно отвязать (станет пустым snapshot) или удалить.')
                    : trf('Изменения мастера автоматически отражаются здесь. Версия v{p0}.', {'p0': master.contentVersion}),
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ),
            Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
            ListTile(
              leading: Icon(Icons.link_off, color: cs.tertiary),
              title: Text(
                tr('Отвязать (превратить в копию)'),
                style: TextStyle(color: cs.onSurface),
              ),
              subtitle: Text(
                tr('После отвязки изменения мастера на этот элемент не повлияют.'),
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _detachLinkedInstance(index);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: cs.error),
              title: Text(
                tr('Удалить элемент'),
                style: TextStyle(color: cs.onSurface),
              ),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _children.removeAt(index));
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// Отвязать инстанс: резолвим через [TemplateInstanceResolver], затем
  /// сохраняем как обычный snapshot со свежими id.
  void _detachLinkedInstance(int index) {
    if (index < 0 || index >= _children.length) return;
    final item = _children[index];
    if (!item.isTemplateInstance) return;

    final resolver = ref
        .read(templateInstanceResolverProvider(widget.questId))
        .valueOrNull;
    if (resolver == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Резолвер шаблонов ещё не загружен, попробуйте позже')),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final resolved = resolver.resolveTree(item);
    if (!resolved.isTemplateInstance && resolved == item) {
      setState(() {
        _children[index] = item.copyWith(
          clearTemplateLink: true,
          children: const [],
          modalButtons: const [],
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Шаблон не найден — элемент отвязан и очищен')),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }

    final detached = TemplateApplier.detachContentItem(resolved);
    setState(() => _children[index] = detached);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Элемент отвязан от шаблона')),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _pasteIntoContainerItem(int index) async {
    if (index < 0 || index >= _children.length) return;
    final container = _children[index];
    if (container.type != 'row' && container.type != 'column') return;

    final source = await _readContentItemFromClipboard();
    if (source == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Буфер элементов пуст')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final newChild = ContentItemUtils.duplicate(source);
    final children = List<ContentItem>.from(container.children ?? const []);
    children.add(newChild);

    setState(() {
      _children[index] = container.copyWith(children: children);
    });

  }

  // --- Верхний уровень ---
  void _showSettingsDialog() {
    final isRow = widget.containerType == 'row';
    final cs = Theme.of(context).colorScheme;
    // Локальное состояние для модалки. Применяем по факту выхода.
    double? localSpacing = _currentItemSpacing;
    String localSpacingExpr = _currentSpacingExpr ?? '';
    bool? localRoundImages = _currentChildImageRoundedCorners;
    showAdaptiveSheet(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final maxHeight = MediaQuery.of(context).size.height * 0.85;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        tr('Настройки контейнера'),
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        isRow
                            ? tr('Вертикальное выравнивание')
                            : tr('Горизонтальное выравнивание'),
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    _buildRadioTile(
                      title: isRow ? tr('Сверху') : tr('Слева'),
                      value: 'start',
                      groupValue: _currentAlignment,
                      icon: isRow
                          ? Icons.vertical_align_top
                          : Icons.align_horizontal_left,
                      onChanged: (v) =>
                          setModalState(() => _currentAlignment = v),
                    ),
                    _buildRadioTile(
                      title: tr('По центру'),
                      value: 'center',
                      groupValue: _currentAlignment,
                      icon: isRow
                          ? Icons.vertical_align_center
                          : Icons.align_horizontal_center,
                      onChanged: (v) =>
                          setModalState(() => _currentAlignment = v),
                    ),
                    _buildRadioTile(
                      title: isRow ? tr('Снизу') : tr('Справа'),
                      value: 'end',
                      groupValue: _currentAlignment,
                      icon: isRow
                          ? Icons.vertical_align_bottom
                          : Icons.align_horizontal_right,
                      onChanged: (v) =>
                          setModalState(() => _currentAlignment = v),
                    ),
                    Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        tr('Шрифт контейнера (наследуется детьми)'),
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.font_download_rounded),
                      title: Text(
                        _currentFontFamily != null
                            ? _fontLabel(_currentFontFamily!)
                            : tr('Как в квесте'),
                        style: TextStyle(color: cs.onSurface),
                      ),
                      trailing: _currentFontFamily != null
                          ? IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: tr('Сбросить шрифт'),
                              onPressed: () => setModalState(
                                () => _currentFontFamily = null,
                              ),
                            )
                          : null,
                      onTap: () => _pickContainerFont(setModalState, context),
                    ),
                    if (isRow) ...[
                      Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          tr('Отображение текста'),
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      _buildRadioTile(
                        title: tr('Авто (как в настройках квеста)'),
                        value: 'auto',
                        groupValue: _currentTextFit,
                        icon: Icons.brightness_auto,
                        onChanged: (v) =>
                            setModalState(() => _currentTextFit = v),
                      ),
                      _buildRadioTile(
                        title: tr('Масштабировать (одна строка)'),
                        value: 'scale',
                        groupValue: _currentTextFit,
                        icon: Icons.compress,
                        onChanged: (v) =>
                            setModalState(() => _currentTextFit = v),
                      ),
                      _buildRadioTile(
                        title: tr('Переносить (много строк)'),
                        value: 'wrap',
                        groupValue: _currentTextFit,
                        icon: Icons.wrap_text,
                        onChanged: (v) =>
                            setModalState(() => _currentTextFit = v),
                      ),
                      Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          tr('Выравнивание текста в строке'),
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      _buildRadioTile(
                        title: tr('Слева'),
                        value: 'start',
                        groupValue: _currentRowTextAlign,
                        icon: Icons.format_align_left,
                        onChanged: (v) =>
                            setModalState(() => _currentRowTextAlign = v),
                      ),
                      _buildRadioTile(
                        title: tr('По центру'),
                        value: 'center',
                        groupValue: _currentRowTextAlign,
                        icon: Icons.format_align_center,
                        onChanged: (v) =>
                            setModalState(() => _currentRowTextAlign = v),
                      ),
                      _buildRadioTile(
                        title: tr('Справа'),
                        value: 'end',
                        groupValue: _currentRowTextAlign,
                        icon: Icons.format_align_right,
                        onChanged: (v) =>
                            setModalState(() => _currentRowTextAlign = v),
                      ),
                    ],
                    Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        tr('Внутренний отступ между элементами'),
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    SwitchListTile(
                      title: Text(
                        tr('Переопределить отступ'),
                        style: TextStyle(color: cs.onSurface),
                      ),
                      subtitle: Text(
                        localSpacing == null
                            ? trf('Используется значение по умолчанию ({p0})', {'p0': isRow ? tr('4 px по горизонтали') : tr('8 px снизу')})
                            : trf('Своё значение: {p0} px', {'p0': localSpacing!.round()}),
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      value: localSpacing != null,
                      onChanged: (v) => setModalState(() {
                        localSpacing = v ? (isRow ? 8.0 : 8.0) : null;
                      }),
                    ),
                    if (localSpacing != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Slider(
                          value: localSpacing!.clamp(0.0, 32.0),
                          min: 0.0,
                          max: 32.0,
                          divisions: 32,
                          label: '${localSpacing!.round()} px',
                          onChanged: (v) =>
                              setModalState(() => localSpacing = v),
                        ),
                      ),
                    // Зазор может считать движок: `hp > 50 ? 4 : 12`,
                    // `min(20, count)`. Число выше — превью и откат.
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      leading: Icon(Icons.functions, color: cs.primary),
                      title: Text(
                        tr('Формула зазора'),
                        style: TextStyle(color: cs.onSurface),
                      ),
                      subtitle: Text(
                        localSpacingExpr.isEmpty
                            ? tr('Не задана — используем число выше')
                            : localSpacingExpr,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      trailing: localSpacingExpr.isEmpty
                          ? null
                          : IconButton(
                              tooltip: tr('Снять формулу'),
                              icon: const Icon(Icons.clear),
                              onPressed: () => setModalState(
                                () => localSpacingExpr = '',
                              ),
                            ),
                      onTap: () async {
                        final edited = await Navigator.push<String>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ExpressionEditorScreen(
                              initialValue: localSpacingExpr,
                              questId: widget.questId,
                              title: tr('Формула зазора'),
                            ),
                          ),
                        );
                        // null — отмена; пустая строка — формулу сняли.
                        if (edited != null) {
                          setModalState(() => localSpacingExpr = edited);
                        }
                      },
                    ),
                    Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
                    SwitchListTile(
                      title: Text(
                        tr('Переопределить скругление картинок'),
                        style: TextStyle(color: cs.onSurface),
                      ),
                      subtitle: Text(
                        localRoundImages == null
                            ? tr('Наследуется настройка ноды')
                            : tr('Своё значение для этого контейнера'),
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      value: localRoundImages != null,
                      onChanged: (v) {
                        setModalState(() {
                          localRoundImages = v ? true : null;
                        });
                      },
                    ),
                    if (localRoundImages != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(
                              value: true,
                              label: Text(tr('Скруглять')),
                              icon: Icon(Icons.rounded_corner_rounded),
                            ),
                            ButtonSegment(
                              value: false,
                              label: Text(tr('Прямые')),
                              icon: Icon(Icons.crop_square_rounded),
                            ),
                          ],
                          selected: {localRoundImages!},
                          onSelectionChanged: (set) {
                            setModalState(() => localRoundImages = set.first);
                          },
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).then((_) {
      setState(() {
        _currentItemSpacing = localSpacing;
        _currentSpacingExpr = localSpacingExpr.isEmpty
            ? null
            : localSpacingExpr;
        _currentChildImageRoundedCorners = localRoundImages;
      });
      widget.onAutoSave?.call(_currentState());
    });
  }

  Widget _buildRadioTile({
    required String title,
    required String value,
    required String groupValue,
    required IconData icon,
    required Function(String) onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = value == groupValue;
    return ListTile(
      leading: Icon(icon, color: isSelected ? cs.primary : cs.onSurfaceVariant),
      title: Text(
        title,
        style: TextStyle(
          color: isSelected ? cs.primary : cs.onSurface,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: isSelected ? Icon(Icons.check, color: cs.primary) : null,
      onTap: () => onChanged(value),
    );
  }

  void _changeFlex(int index) {
    final cs = Theme.of(context).colorScheme;
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surfaceContainerHigh,
        title: Text(tr('Вес (Ширина)'), style: TextStyle(color: cs.onSurface)),
        actions: [1, 2, 3, 4]
            .map(
              (f) => TextButton(
                child: Text(
                  'x$f',
                  style: TextStyle(fontSize: 18, color: cs.primary),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(
                    () => _children[index] = _children[index].copyWith(flex: f),
                  );
                },
              ),
            )
            .toList(),
      ),
    );
  }

  PluginContentType? _findPluginType(String? typeId) =>
      findPluginContentType(ref, typeId);

  /// Айтем плагина внутри контейнера: тип — из манифеста, поля — из формы.
  Future<ContentItem?> _createPluginChildItem(String? pluginTypeId) {
    final type = _findPluginType(pluginTypeId);
    if (type == null) return Future.value();
    return createPluginContentItem(
      context,
      type: type,
      questId: widget.questId,
    );
  }

  ItemEditorHelper get _itemHelper => ItemEditorHelper(
    context: context,
    questId: widget.questId,
    nodeId: widget.nodeId,
    logic: _logic,
    getItem: (i) => _children[i],
    updateItem: (i, item) {
      setState(() {
        _children[i] = item;
      });
      widget.onAutoSave?.call(_currentState());
    },
    // Вложенный ряд/колонка получает тот же форс-сейв: запуск симуляции из
    // второго уровня вложенности тоже не должен терять детей.
    onForceContainerSave: widget.onForceSave,
    // Айтем плагина не имеет своего редактора: его поля описаны в манифесте,
    // и форма та же, что и при добавлении.
    onCustomEditItem: (index, item) async {
      if (item.type != 'plugin') return false;
      final pluginType = _findPluginType(item.pluginTypeId);
      if (pluginType == null) return true;
      final data = await showPluginContentForm(
        context,
        type: pluginType,
        questId: widget.questId,
        initial: item.pluginData,
      );
      if (data != null && mounted) {
        setState(
          () => _children[index] = item.copyWith(
            pluginTypeId: pluginType.id,
            pluginId: pluginType.pluginId,
            pluginData: data,
          ),
        );
        widget.onAutoSave?.call(_currentState());
      }
      return true;
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Типы контента плагинов приходят из Rust-хоста асинхронно: следим,
    // чтобы карточки плагин-айтемов перерисовались, когда они появятся.
    ref.watch(pluginContentTypesProvider);
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) _saveAndExit();
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          backgroundColor: cs.surface,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.containerType == 'row'
                    ? _rowEditorTitle
                    : _columnEditorTitle,
                style: const TextStyle(fontSize: 18),
              ),
              if (widget.containerType == 'row')
                Text(
                  _textFitLabel,
                  style: TextStyle(fontSize: 12, color: cs.primary),
                ),
            ],
          ),
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: cs.onSurface),
            onPressed: _saveAndExit,
          ),
          actions: [
            IconButton(
              icon: Icon(
                Icons.play_circle_fill_rounded,
                color: cs.primary,
                size: 28,
              ),
              tooltip: tr('Играть с текущей ноды'),
              onPressed: _launchQuest,
            ),
            IconButton(
              icon: Icon(Icons.history_rounded, color: cs.tertiary),
              tooltip: tr('Играть из сохранения'),
              onPressed: _launchQuestFromSave,
            ),
            IconButton(
              icon: const Icon(Icons.content_paste),
              onPressed: _pasteCopiedItem,
              tooltip: tr('Вставить'),
            ),
            IconButton(
              icon: const Icon(Icons.tune),
              onPressed: _showSettingsDialog,
              tooltip: _settingsTooltip,
            ),
          ],
          elevation: 0,
        ),
        floatingActionButton: FloatingActionButton(
          heroTag: 'container_editor_fab',
          onPressed: () {
            ContentAddMenuSheet.show(
              context,
              onItemSelected: (type, {pluginTypeId}) async {
                final newItem = type == 'plugin'
                    ? await _createPluginChildItem(pluginTypeId)
                    : await _logic.createItemByType(
                        type,
                        onDraft: _upsertChild,
                      );
                if (newItem != null && mounted) _upsertChild(newItem);
              },
              onPaste: _pasteCopiedItem,
              onInsertFromTemplate: _insertFromTemplate,
            );
          },
          backgroundColor: cs.primary,
          child: Icon(Icons.add, color: cs.onPrimary),
        ),
        body: AdaptiveContent(
          maxWidth: 880,
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(bottom: 80, top: 10),
            itemCount: _children.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (oldIndex < newIndex) newIndex -= 1;
                final item = _children.removeAt(oldIndex);
                _children.insert(newIndex, item);
              });
            },
            itemBuilder: (context, index) {
              final item = _children[index];
              String? displayScriptName;

              // Иконка обозначения имени скрипта. resolvedTriggers — тот же
              // набор, что читает плеер (behaviours + legacy).
              final triggers = item.resolvedTriggers;
              bool hasTrigger = triggers.isNotEmpty;

              if (hasTrigger) {
                final rawRef = triggers.values.firstOrNull;
                if (rawRef != null) {
                  final triggerRef = TriggerReference.parse(rawRef);
                  final fileName = p.basename(triggerRef.scriptPath);
                  final baseName = _resourceNames[fileName] ?? fileName;
                  displayScriptName = triggerRef.isFunctionRef
                      ? '$baseName :: ${triggerRef.functionEntry}'
                      : baseName;
                }
              }

              // --- Template link metadata for this item ---
              String? linkedMasterName;
              bool linkedMissing = false;
              ContentItem displayItem = item;
              if (item.hasTemplateLink) {
                final masters = ref
                    .watch(templatesByIdProvider(widget.questId))
                    .valueOrNull;
                final master = masters?[item.templateRef];
                if (master != null) {
                  linkedMasterName = master.name;
                } else {
                  linkedMissing = true;
                }
                // Резолвер нужен только для linked-инстансов. Мастер-элемент
                // содержит полный payload локально и рендерится как есть.
                if (item.isTemplateInstance) {
                  final resolver = ref
                      .watch(templateInstanceResolverProvider(widget.questId))
                      .valueOrNull;
                  if (resolver != null) {
                    displayItem = resolver.resolveTree(item);
                  }
                }
              }

              final pluginType = item.type == 'plugin'
                  ? _findPluginType(item.pluginTypeId)
                  : null;
              final pluginAccent = pluginType?.accentColor;

              return ContentItemCard(
                key: ValueKey(item.id),
                index: index,
                item: displayItem,
                questId: widget.questId,
                displayScriptName: displayScriptName,
                pluginTitle: pluginType?.name,
                pluginAccentColor: pluginAccent,
                templateInstanceName: linkedMasterName,
                templateInstanceMissing: linkedMissing,
                templateInstanceIsMaster: item.isTemplateMasterItem,
                onTemplateInstanceTap: item.hasTemplateLink
                    ? () => _showLinkedInstanceMenu(index)
                    : null,
                onDelete: () => _deleteItem(index),
                // Для linked-инстансов — меню. Для мастера — обычное
                // редактирование (изменения раскатятся при сохранении ноды).
                onEdit: item.isTemplateInstance
                    ? () => _showLinkedInstanceMenu(index)
                    : () => _itemHelper.editItem(index),
                onRename: (item.type == 'row' || item.type == 'column')
                    ? () => _itemHelper.renameItem(index)
                    : null,
                onTriggerSettings: () => _itemHelper.showTriggerOptions(
                  index,
                  includeTargetNodeId:
                      item.type != 'row' && item.type != 'column',
                ),
                onOnAppearTriggerTap: () =>
                    _itemHelper.onTriggerSlotTap(index, 'onAppear'),
                onOnPressTriggerTap: () => _itemHelper.onTriggerSlotTap(
                  index,
                  item.type == 'input' ? 'onSubmit' : 'onPress',
                ),
                onCopy: () => _copyItemAt(index),
                onSaveAsTemplate: () => _saveItemAsTemplate(index),
                onPasteInto: (item.type == 'row' || item.type == 'column')
                    ? () => _pasteIntoContainerItem(index)
                    : null,
                onLayoutSettings: widget.containerType == 'row'
                    ? () => _changeFlex(index)
                    : null,
                onJumpToTarget: widget.onJumpToNode != null
                    ? (target) {
                        _saveAndExit();
                        widget.onJumpToNode!(target);
                      }
                    : null,
              );
            },
          ),
        ),
      ),
    );
  }
}
