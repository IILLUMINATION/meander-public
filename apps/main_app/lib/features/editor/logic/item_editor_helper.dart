import 'dart:async';

import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/screens/node_content/content_editor_logic.dart';
import 'package:canvas_app/features/editor/screens/node_content/container_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_content/stack_canvas/stack_canvas_screen.dart';
import 'package:canvas_app/features/editor/screens/node_content/chat_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_content/video_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/function_selection_screen.dart';
import 'package:canvas_app/features/editor/services/trigger_service.dart';
import 'package:canvas_app/features/editor/workspace/editor_nested_documents.dart';
import 'package:canvas_app/features/resources/screens/markdown_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:mnd_player/utils/trigger_reference.dart';
import 'package:flutter/material.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

class ItemEditorHelper {
  final BuildContext context;
  final String questId;
  final String nodeId;
  final ContentEditorLogic logic;
  final ContentItem Function(int index) getItem;
  final void Function(int index, ContentItem item) updateItem;

  final Future<void> Function()? onBeforeContainerEdit;
  final Future<bool> Function(int index, ContentItem item)? onCustomEditItem;
  final void Function(String targetNodeId)? onJumpToNode;
  final bool fromGameSession;

  ItemEditorHelper({
    required this.context,
    required this.questId,
    required this.nodeId,
    required this.logic,
    required this.getItem,
    required this.updateItem,
    this.onBeforeContainerEdit,
    this.onCustomEditItem,
    this.onJumpToNode,
    this.fromGameSession = false,
  });

  late final ResourceService _resources = ResourceService.forQuest(questId);
  late final ScriptService _scripts = ScriptService(resources: _resources);

  /// Редакторы «по типу» (кнопка, ввод, ожидание ввода, чат, модалка, видео)
  /// собирают `ContentItem` с нуля и знают только про свои поля. Без возврата
  /// чужих полей правка пресета у слоя в стеке обнуляла его геометрию: бокс
  /// схлопывался в точку, и слой исчезал и на канвасе, и в игре — вместе с
  /// именем, группой, замком, прозрачностью и `behaviours`.
  ///
  /// То же касается формул: `numericExprs` и `resourceExpr` такой редактор не
  /// возвращает вовсе, и формула скругления умирала при каждой правке. Их
  /// переносим из оригинала; кто про своё поле всё-таки знает (редактор видео
  /// умеет скругление), перекрывает его сам на месте вызова — [editVideoItem].
  static ContentItem keepLayerFields(
    ContentItem original,
    ContentItem edited,
  ) => edited.copyWith(
    id: original.id,
    flex: original.flex,
    anchorLeft: original.anchorLeft,
    anchorTop: original.anchorTop,
    anchorRight: original.anchorRight,
    anchorBottom: original.anchorBottom,
    offsetLeft: original.offsetLeft,
    offsetTop: original.offsetTop,
    offsetRight: original.offsetRight,
    offsetBottom: original.offsetBottom,
    opacity: original.opacity,
    rotation: original.rotation,
    scale: original.scale,
    isHidden: original.isHidden,
    locked: original.locked,
    groupName: original.groupName,
    layerName: original.layerName,
    behaviours: original.behaviours,
    templateRef: original.templateRef,
    templateVersion: original.templateVersion,
    isTemplateMaster: original.isTemplateMaster,
    resourceExpr: original.resourceExpr,
    numericExprs: original.numericExprs,
  );

  Future<void> editItem(int index) async {
    final item = getItem(index);

    if (onCustomEditItem != null) {
      final handled = await onCustomEditItem!(index, item);
      if (handled) return;
      // Кастомный обработчик может ждать — родителя за это время могли закрыть.
      if (!context.mounted) return;
    }

    if (item.type == 'audio') {
      await editAudioItem(index, item);
      return;
    }

    if (item.type == 'video') {
      await editVideoItem(index, item);
      return;
    }

    if (item.type == 'image') {
      await editImageItem(index, item);
      return;
    }

    if (item.type == 'delay') {
      await editDelayItem(index, item);
      return;
    }

    if (item.type == 'timer') {
      await editTimerItem(index, item);
      return;
    }

    if (item.type == 'spacer') {
      await editSpacerItem(index, item);
      return;
    }

    if (item.type == 'stack') {
      // Стек открывается сразу канвасом: экран «список детей + превью» был
      // лишним шагом — все его правки живут на канвасе.
      await EditorNestedDocuments.open<void>(
        context,
        questId: questId,
        identity: 'stack:$nodeId:${item.id}',
        title: tr('Стек'),
        builder: (_) => StackCanvasScreen(
          stackItem: item,
          questId: questId,
          nodeId: nodeId,
          onJumpToNode: onJumpToNode,
          fromGameSession: fromGameSession,
          onAutoSave: (state) async {
            final newItem = state['item'] as ContentItem?;
            if (newItem != null && context.mounted) updateItem(index, newItem);
            if (context.mounted && onBeforeContainerEdit != null) {
              await onBeforeContainerEdit!();
            }
          },
        ),
      );
      return;
    }

    if (item.type == 'row' || item.type == 'column') {
      if (onBeforeContainerEdit != null) await onBeforeContainerEdit!();
      if (!context.mounted) return;

      final isRow = item.type == 'row';
      final result = await EditorNestedDocuments.open<Map<String, dynamic>>(
        context,
        questId: questId,
        identity: 'container:$nodeId:${item.id}',
        title: isRow ? tr('Ряд') : tr('Колонка'),
        builder: (_) => ContainerEditorScreen(
          questId: questId,
          nodeId: nodeId,
          containerType: item.type,
          initialChildren: item.children ?? [],
          initialAlignment: item.crossAxisAlignment,
          initialTextFit: item.textFit,
          initialRowTextAlign: item.rowTextAlignment,
          initialItemSpacing: item.itemSpacing,
          initialSpacingExpr: item.numericExpr('itemSpacing'),
          initialChildImageRoundedCorners: item.childImageRoundedCorners,
          initialFontFamily: item.fontFamily,
          initialPluginData: item.pluginData,
          onJumpToNode: onJumpToNode,
          fromGameSession: fromGameSession,
          onAutoSave: (state) async {
            final newChildren = state['children'] as List<ContentItem>? ?? [];
            final newAlign = state['alignment'] as String?;
            final newTextFit = state['textFit'] as String?;
            final newRowTextAlign = state['rowTextAlign'] as String?;
            final newPluginData =
                state['pluginData'] as Map<String, dynamic>?;
            final newSpacing = (state['itemSpacing'] as num?)?.toDouble();
            final newSpacingExpr = state['spacingExpr'] as String?;
            final newRoundImages = state['childImageRoundedCorners'] as bool?;
            final newFontFamily = state['fontFamily'] as String?;

            if (!context.mounted) return;
            updateItem(
              index,
              withSpacingExpr(
                item.copyWith(
                  children: newChildren,
                  crossAxisAlignment: newAlign,
                  textFit: newTextFit,
                  rowTextAlignment: newRowTextAlign,
                  pluginData: newPluginData,
                  itemSpacing: newSpacing,
                  clearItemSpacing: newSpacing == null,
                  childImageRoundedCorners: newRoundImages,
                  clearChildImageRoundedCorners: newRoundImages == null,
                  fontFamily: newFontFamily,
                  clearFontFamily: newFontFamily == null,
                ),
                newSpacingExpr,
              ),
            );
            if (context.mounted && onBeforeContainerEdit != null) {
              await onBeforeContainerEdit!();
            }
          },
        ),
      );
      if (result != null && context.mounted) {
        final newChildren = result['children'] as List<ContentItem>? ?? [];
        final newAlign =
            result['crossAxisAlignment'] as String? ??
            result['alignment'] as String?;
        final newTextFit = result['textFit'] as String?;
        final newRowTextAlign =
            result['rowTextAlignment'] as String? ??
            result['rowTextAlign'] as String?;
        final newPluginData = result['pluginData'] as Map<String, dynamic>?;
        final newSpacing = (result['itemSpacing'] as num?)?.toDouble();
        final newSpacingExpr = result['spacingExpr'] as String?;
        final newRoundImages = result['childImageRoundedCorners'] as bool?;
        final newFontFamily = result['fontFamily'] as String?;

        updateItem(
          index,
          withSpacingExpr(
            item.copyWith(
              children: newChildren,
              crossAxisAlignment: newAlign,
              textFit: newTextFit,
              rowTextAlignment: newRowTextAlign,
              pluginData: newPluginData,
              itemSpacing: newSpacing,
              clearItemSpacing: newSpacing == null,
              childImageRoundedCorners: newRoundImages,
              clearChildImageRoundedCorners: newRoundImages == null,
              fontFamily: newFontFamily,
              clearFontFamily: newFontFamily == null,
            ),
            newSpacingExpr,
          ),
        );
      }
      return;
    }

    if (item.type == 'text') {
      ContentItem applyText(MarkdownEditorResult result) => item.copyWith(
        text: result.text,
        fontFamily: result.fontFamily,
        clearFontFamily: result.fontFamily == null,
        textSize: result.textSize,
        clearTextSize: result.textSize == null,
        // Режим и скорость пишутся всегда: «Без анимации» — это тоже
        // выбор автора, а не отсутствие поля.
        textReveal: result.textReveal,
        revealSpeed: result.revealSpeed,
        // Пара «цвет + толщина» снимается целиком: без цвета контура
        // толщина повисла бы мёртвым полем в файле квеста.
        textOutlineColor: result.textOutlineColor,
        textOutlineWidth: result.textOutlineWidth,
        clearTextOutline: result.textOutlineColor == null,
      );

      final result = await EditorNestedDocuments.open<MarkdownEditorResult>(
        context,
        questId: questId,
        identity: 'text:$nodeId:${item.id}',
        title: tr('Текст'),
        builder: (_) => MarkdownEditorScreen(
          initialText: item.text ?? '',
          questId: questId,
          initialFontFamily: item.fontFamily,
          initialTextSize: item.textSize,
          initialTextReveal: item.textReveal,
          initialRevealSpeed: item.revealSpeed,
          initialTextOutlineColor: item.textOutlineColor,
          initialTextOutlineWidth: item.textOutlineWidth,
          onChanged: (result) {
            if (context.mounted) updateItem(index, applyText(result));
          },
        ),
      );
      if (result != null && context.mounted) {
        updateItem(index, applyText(result));
      }
      return;
    }

    if (item.type == 'button' || item.type == 'button_jump') {
      final newItem = await logic.addButton(
        initialText: item.text,
        initialTarget: item.targetNodeId,
        existingItem: item,
        onDraft: (draft) {
          if (context.mounted) updateItem(index, keepLayerFields(item, draft));
        },
      );
      if (newItem != null && context.mounted) {
        updateItem(index, keepLayerFields(item, newItem));
      }
      return;
    }

    if (item.type == 'script' && item.resourcePath != null) {
      // Род редактора выбирает openEditor: путь script-айтема ведёт и на
      // .json, и на .lua. Раньше отсюда всегда шли в визуальный редактор —
      // для .lua открывался призрак scripts/имя.lua.json.
      await _scripts.openEditor(context, item.resourcePath!);
      return;
    }

    if (item.type == 'input') {
      final updated = await logic.addInput(existing: item);
      if (updated != null && context.mounted) {
        updateItem(index, keepLayerFields(item, updated));
      }
      return;
    }

    if (item.type == 'wait_input') {
      final updated = await logic.addWaitInput(existing: item);
      if (updated != null && context.mounted) {
        updateItem(index, keepLayerFields(item, updated));
      }
      return;
    }

    if (item.type == 'chat') {
      final updated = await EditorNestedDocuments.open<ContentItem>(
        context,
        questId: questId,
        identity: 'chat:$nodeId:${item.id}',
        title: tr('Чат'),
        builder: (_) => ChatEditorScreen(
          questId: questId,
          existingItem: item,
          onChanged: (draft) {
            if (context.mounted) updateItem(index, keepLayerFields(item, draft));
          },
        ),
      );
      if (updated != null && context.mounted) {
        updateItem(index, keepLayerFields(item, updated));
      }
      return;
    }

    if (item.type == 'modal') {
      final updated = await logic.editModal(
        existing: item,
        onChanged: (draft) {
          if (context.mounted) updateItem(index, keepLayerFields(item, draft));
        },
      );
      if (updated != null && context.mounted) {
        updateItem(index, keepLayerFields(item, updated));
      }
      return;
    }
  }

  /// Имя файла без пути: ключ metadata квеста.
  static String? _baseName(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.split('/').last;
  }

  /// Подпись ресурса для автора: имя из библиотеки квеста. Имена файлов
  /// картинок и звуков — `1790024448511_<uuid>.png`, такое не читается
  /// глазами и не отличимо от соседнего кадра.
  Future<String> _displayNameOf(String? path) async {
    final file = _baseName(path);
    if (file == null) return '';
    try {
      return await _resources.resolveDisplayName(file);
    } catch (_) {
      return file;
    }
  }

  /// То же для выбора из пикера: он уже несёт дружелюбное имя.
  static String _labelOf(SelectableResource res) {
    final friendly = res.friendlyName.trim();
    return friendly.isEmpty ? res.name : friendly;
  }

  Future<void> editAudioItem(int index, ContentItem item) async {
    double currentVolume = item.volume;
    String? newPath = item.resourcePath;
    String name = await _displayNameOf(newPath);
    if (!context.mounted) return;

    await showAppDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final scheme = Theme.of(context).colorScheme;
          return AlertDialog(
            backgroundColor: scheme.surfaceContainerHigh,
            title: Text(tr('Настройки аудио')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.audiotrack, color: scheme.primary),
                  title: Text(
                    name.isEmpty ? tr('Файл не выбран') : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Icon(Icons.edit, color: scheme.onSurfaceVariant),
                  onTap: () async {
                    final res = await Navigator.push<SelectableResource>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ResourceSelectionScreen(
                          questId: questId,
                          allowedTypes: const ['audio'],
                        ),
                      ),
                    );
                    if (res != null) {
                      setDialogState(() {
                        newPath = res.path;
                        name = _labelOf(res);
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  tr('Громкость'),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                Row(
                  children: [
                    Icon(
                      Icons.volume_down,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    Expanded(
                      child: Slider(
                        value: currentVolume,
                        min: 0.0,
                        max: 1.0,
                        inactiveColor: scheme.surfaceContainerHighest,
                        onChanged: (val) {
                          setDialogState(() => currentVolume = val);
                        },
                      ),
                    ),
                    Icon(
                      Icons.volume_up,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Отмена')),
              ),
              FilledButton(
                onPressed: () {
                  updateItem(
                    index,
                    item.copyWith(volume: currentVolume, resourcePath: newPath),
                  );
                  Navigator.pop(ctx);
                },
                child: Text(tr('ОК')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> editVideoItem(int index, ContentItem item) async {
    final updated = await EditorNestedDocuments.open<ContentItem>(
      context,
      questId: questId,
      identity: 'video:$nodeId:${item.id}',
      title: tr('Видео'),
      builder: (_) => VideoEditorScreen(
        questId: questId,
        existingItem: item,
        onChanged: (draft) {
          if (!context.mounted) return;
          updateItem(
            index,
            keepLayerFields(
              item,
              draft,
            ).withNumericExpr('borderRadius', draft.numericExpr('borderRadius')),
          );
        },
      ),
    );
    if (updated != null && context.mounted) {
      // keepLayerFields возвращает формулы оригинала — у пересобранного айтема
      // их нет. Скругление же редактор видео ведёт сам, и снятая формула
      // означает «снять», а не «не знаю»: перекладываем это поле поверх.
      updateItem(
        index,
        keepLayerFields(
          item,
          updated,
        ).withNumericExpr('borderRadius', updated.numericExpr('borderRadius')),
      );
    }
  }

  Future<void> editImageItem(int index, ContentItem item) async {
    String? newPath = item.resourcePath;
    String expr = item.resourceExpr ?? '';
    String fileLabel = await _displayNameOf(newPath);
    if (!context.mounted) return;

    await showAppDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final scheme = Theme.of(context).colorScheme;
          return AlertDialog(
            backgroundColor: scheme.surfaceContainerHigh,
            title: Text(tr('Настройки изображения')),
            // С полем ввода клавиатура поднимает диалог — без скролла он
            // лезет за экран на маленьких высотах.
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SettingRow(
                    icon: Icons.image,
                    label: tr('Файл'),
                    value: fileLabel.isEmpty ? null : fileLabel,
                    emptyText: tr('Не выбран'),
                    caption: tr('Библиотека ресурсов квеста'),
                    onTap: () async {
                      final res = await Navigator.push<SelectableResource>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ResourceSelectionScreen(
                            questId: questId,
                            allowedTypes: const ['image'],
                          ),
                        ),
                      );
                      if (res != null) {
                        setDialogState(() {
                          newPath = res.path;
                          fileLabel = _labelOf(res);
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  // Картинку задаёт формула: `{pic}`, `res/{level}.png`,
                  // `{Таблица["колонка"][1]}` — тот же синтаксис, что в тексте.
                  // Скрипт меняет источник одним присваиванием, без второго
                  // айтема с взаимоисключающей видимостью.
                  _SettingRow(
                    icon: Icons.functions,
                    label: tr('Формула источника'),
                    value: expr.isEmpty ? null : expr,
                    emptyText: tr('Не задана — показываем файл выше'),
                    caption:
                        tr('Значение подставляет движок при каждом изменении состояния: переменные, ячейка сетки {лавка["цена"][1]}, тернарник'),
                    onTap: () async {
                      final edited = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ExpressionEditorScreen(
                            initialValue: expr,
                            questId: questId,
                            title: tr('Формула источника'),
                            isTemplate: true,
                          ),
                        ),
                      );
                      // null — отмена; пустая строка — формулу сняли.
                      if (edited != null) setDialogState(() => expr = edited);
                    },
                    onClear: expr.isEmpty
                        ? null
                        : () => setDialogState(() => expr = ''),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Отмена')),
              ),
              FilledButton(
                onPressed: () {
                  updateItem(
                    index,
                    item.copyWith(
                      resourcePath: newPath,
                      resourceExpr: expr.isEmpty ? null : expr,
                      clearResourceExpr: expr.isEmpty,
                    ),
                  );
                  Navigator.pop(ctx);
                },
                child: Text(tr('ОК')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> editDelayItem(int index, ContentItem item) async {
    final result = await showDelayDialog(
      context: context,
      questId: questId,
      initialValue: item.text,
      initialHidden: item.isHidden,
      initialExpr: item.numericExpr('duration'),
    );
    if (result != null) {
      updateItem(
        index,
        item
            .copyWith(text: result.seconds, isHidden: result.hidden)
            .withNumericExpr('duration', result.expr),
      );
    }
  }

  Future<void> editTimerItem(int index, ContentItem item) async {
    final result = await showDelayDialog(
      context: context,
      questId: questId,
      initialValue: item.text,
      initialHidden: item.isHidden,
      initialExpr: item.numericExpr('duration'),
      title: tr('Длительность таймера (сек)'),
    );
    if (result != null) {
      updateItem(
        index,
        item
            .copyWith(text: result.seconds, isHidden: result.hidden)
            .withNumericExpr('duration', result.expr),
      );
    }
  }

  /// Применить формулу зазора, приехавшую из редактора контейнера.
  ///
  /// `null` — экран её не возвращал (формулу не трогали), пустая строка —
  /// автор снял формулу, всё остальное — новое выражение. Без этого различия
  /// любой автосейв ряда молча стирал бы формулу.
  static ContentItem withSpacingExpr(ContentItem base, String? reported) =>
      reported == null ? base : base.withNumericExpr('itemSpacing', reported);

  Future<void> editSpacerItem(int index, ContentItem item) async {
    final controller = TextEditingController(
      text: (item.padding ?? 16.0).toStringAsFixed(0),
    );
    var expr = item.numericExpr('padding') ?? '';
    final cs = Theme.of(context).colorScheme;
    final result = await showAppDialog<({double px, String expr})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: cs.surfaceContainerHigh,
          title: Text(
            tr('Размер отступа (px)'),
            style: TextStyle(color: cs.onSurface),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                autofocus: true,
                style: TextStyle(color: cs.onSurface),
                decoration: InputDecoration(hintText: tr('Например: 16')),
              ),
              // Отступ может считать движок: `{hp}/2 + 16`, `hp > 50 ? 40 : 8`.
              // Число выше остаётся — это превью редактора и запасной вариант,
              // когда переменная ещё не завелась.
              _SettingRow(
                icon: Icons.functions,
                label: tr('Формула размера'),
                value: expr.isEmpty ? null : expr,
                emptyText: tr('Не задана — используем число выше'),
                caption:
                    tr('Движок пересчитывает при каждом изменении состояния: переменные, таблицы, тернарник'),
                onTap: () async {
                  final edited = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ExpressionEditorScreen(
                        initialValue: expr,
                        questId: questId,
                        title: tr('Формула размера'),
                      ),
                    ),
                  );
                  // null — отмена; пустая строка — формулу сняли.
                  if (edited != null) setDialogState(() => expr = edited);
                },
                onClear: expr.isEmpty
                    ? null
                    : () => setDialogState(() => expr = ''),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () {
                final val = double.tryParse(
                  controller.text.trim().replaceAll(',', '.'),
                );
                if (val != null && val >= 0) {
                  Navigator.pop(ctx, (px: val, expr: expr));
                }
              },
              child: Text(tr('ОК')),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      updateItem(
        index,
        item
            .copyWith(padding: result.px)
            .withNumericExpr('padding', result.expr),
      );
    }
  }

  /// Диалог длительности задержки/таймера. Возвращает и флаг «скрытый» —
  /// плеер с `isHidden` держит отсчёт, но не рисует прогресс
  /// (`packages/mnd_player/.../content_display_factory.dart`).
  ///
  /// Длительность может считать движок (`{hp}/10`): её заводят рядом с числом,
  /// которое остаётся превью и откатом, если формула не раскрылась.
  static Future<({String seconds, bool hidden, String expr})?> showDelayDialog({
    required BuildContext context,
    required String questId,
    String? initialValue,
    bool initialHidden = false,
    String? initialExpr,
    String? title,
  }) {
    final controller = TextEditingController(text: initialValue ?? '1.0');
    var hidden = initialHidden;
    var expr = initialExpr ?? '';
    final cs = Theme.of(context).colorScheme;
    return showAppDialog<({String seconds, bool hidden, String expr})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: cs.surfaceContainerHigh,
          title: Text(title ?? tr('Задержка (сек)'),
              style: TextStyle(color: cs.onSurface)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                autofocus: true,
                style: TextStyle(color: cs.onSurface),
                decoration: InputDecoration(hintText: tr('Например: 1.5')),
              ),
              _SettingRow(
                icon: Icons.functions,
                label: tr('Формула длительности'),
                value: expr.isEmpty ? null : expr,
                emptyText: tr('Не задана — используем число выше'),
                caption:
                    tr('Считается один раз, когда отсчёт появляется: пересчёт на середине перезапустил бы таймер'),
                onTap: () async {
                  final edited = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ExpressionEditorScreen(
                        initialValue: expr,
                        questId: questId,
                        title: tr('Формула длительности'),
                      ),
                    ),
                  );
                  // null — отмена; пустая строка — формулу сняли.
                  if (edited != null) setDialogState(() => expr = edited);
                },
                onClear: expr.isEmpty
                    ? null
                    : () => setDialogState(() => expr = ''),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  tr('Скрыть отсчёт'),
                  style: TextStyle(color: cs.onSurface),
                ),
                subtitle: Text(
                  tr('Задержка сработает, но прогресс на экране не показывается.'),
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
                value: hidden,
                onChanged: (value) => setDialogState(() => hidden = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () {
                final val = double.tryParse(
                  controller.text.trim().replaceAll(',', '.'),
                );
                if (val != null && val >= 0) {
                  Navigator.pop(
                    ctx,
                    (seconds: val.toString(), hidden: hidden, expr: expr),
                  );
                }
              },
              child: Text(tr('ОК')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> setTargetNodeId(int index) async {
    final selectedNode = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            NodeSelectionScreen(questId: questId, currentNodeId: nodeId),
      ),
    );
    if (selectedNode != null && context.mounted) {
      final item = getItem(index);

      if (item.targetNodeId != null && item.targetNodeId!.isNotEmpty) {
        await deleteConnection(questId, nodeId, item.targetNodeId!);
      }
      await saveConnection(questId, nodeId, selectedNode);

      updateItem(index, item.copyWith(targetNodeId: selectedNode));
    }
  }

  /// Открывает редактор по ссылке триггера: `.lua` → LuaEditorScreen,
  /// `.json` → визуальный редактор (исправлен баг Плана 014: раньше
  /// `.lua` всегда открывался в JSON-редакторе).
  void editTriggerScript(String rawRef) {
    _scripts.openEditor(context, rawRef);
  }

  /// Создание триггерного скрипта (План 014, этап A): мгновенно, без
  /// диалогов имени/папки — авто-имя, шаблон события, сразу редактор.
  Future<void> setTriggerScript(
    int index,
    String type, {
    required bool isNew,
    bool lua = false,
  }) async {
    String? scriptPath;

    if (isNew) {
      try {
        final created = await _scripts.createTriggerScript(
          triggerKey: type,
          lua: lua,
        );
        scriptPath = created.questRelativePath;

        // Сохраняем ссылку в элемент и сразу открываем редактор
        // (главный фикс UX: раньше пользователь возвращался в ноду).
        if (context.mounted) {
          final item = getItem(index);
          updateItem(index, item.withTrigger(type, scriptPath));
          await _scripts.openEditor(context, scriptPath);
        }
      } catch (e) {
        _showSnackBar(
          'Не удалось создать скрипт: ${friendlyError(e)}',
          isError: true,
        );
      }
      return;
    }

    if (!context.mounted) return;
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
    if (res != null) {
      final item = getItem(index);
      updateItem(index, item.withTrigger(type, res.path));
    }
  }

  Future<void> setTriggerFunction(
    int index,
    String type, {
    required bool isNew,
  }) async {
    String? triggerRef;

    if (isNew) {
      try {
        final created = await _resources.createScript(
          initialBlocks: TriggerService.jsonFunctionBlocks(),
        );
        triggerRef = TriggerReference(
          scriptPath: created.questRelativePath,
          functionEntry: 'main',
        ).serialize();

        if (context.mounted) {
          final item = getItem(index);
          updateItem(index, item.withTrigger(type, triggerRef));
          await _scripts.openEditor(context, triggerRef);
        }
      } catch (e) {
        _showSnackBar(
          'Не удалось создать функцию: ${friendlyError(e)}',
          isError: true,
        );
      }
      return;
    }

    if (!context.mounted) return;
    final selected = await Navigator.push<SelectableFunction>(
      context,
      MaterialPageRoute(
        builder: (_) => FunctionSelectionScreen(questId: questId),
      ),
    );
    if (selected != null) {
      final folder = selected.isInternal ? '_internal_scripts' : 'scripts';
      final triggerRef = TriggerReference(
        scriptPath: '$folder/${selected.scriptId}.json',
        functionEntry: selected.functionEntry,
      ).serialize();

      final item = getItem(index);
      updateItem(index, item.withTrigger(type, triggerRef));
    }
  }

  void _showSnackBar(String msg, {bool isError = false}) {
    if (!context.mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: TextStyle(
            color: isError ? cs.onErrorContainer : cs.onPrimaryContainer,
          ),
        ),
        backgroundColor: isError ? cs.errorContainer : cs.primaryContainer,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void removeTrigger(int index, String type) {
    final item = getItem(index);
    final occupied =
        item.resolvedTriggers.containsKey(type) ||
        (item.scriptTriggers?.containsKey(type) ?? false);
    if (!occupied) return;
    updateItem(index, item.withoutTrigger(type));
  }

  Future<String?> pickTriggerType({bool includeTargetNodeId = true}) async {
    final cs = Theme.of(context).colorScheme;
    return await showAdaptiveSheet<String>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                tr('Выберите тип триггера'),
                style: TextStyle(
                  color: cs.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.visibility, color: Colors.blueAccent),
              title: Text(
                tr('При появлении (onAppear)'),
                style: TextStyle(color: cs.onSurface),
              ),
              subtitle: Text(
                tr('Срабатывает, когда элемент становится видимым'),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => Navigator.pop(context, 'onAppear'),
            ),
            ListTile(
              leading: const Icon(Icons.touch_app, color: Colors.greenAccent),
              title: Text(
                tr('При нажатии (onPress)'),
                style: TextStyle(color: cs.onSurface),
              ),
              subtitle: Text(
                tr('Срабатывает при клике на элемент'),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => Navigator.pop(context, 'onPress'),
            ),
            if (includeTargetNodeId)
              ListTile(
                leading: const Icon(Icons.login, color: Colors.green),
                title: Text(
                  tr('Переход к ноде (targetNodeId)'),
                  style: TextStyle(color: cs.onSurface),
                ),
                subtitle: Text(
                  tr('Навигация по клику на элемент'),
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                onTap: () => Navigator.pop(context, 'targetNodeId'),
              ),
          ],
        ),
      ),
    );
  }

  /// Тап по иконке слота триггера на карточке элемента (глазик/палец):
  /// слот занят — сразу открывается редактор скрипта; слот пуст —
  /// меню источников (создание/подключение) для этого события.
  void onTriggerSlotTap(int index, String type) {
    final item = getItem(index);
    final existing = item.scriptForEvent(type) ?? '';
    if (existing.isNotEmpty) {
      editTriggerScript(existing);
      return;
    }
    addTrigger(index, type);
  }

  void addTrigger(int index, String type) {
    if (type == 'targetNodeId') {
      setTargetNodeId(index);
      return;
    }

    final cs = Theme.of(context).colorScheme;
    showAdaptiveSheet<String>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.add_box, color: Colors.green),
              title: Text(
                tr('Новый визуальный скрипт'),
                style: TextStyle(color: cs.onSurface),
              ),
              subtitle: Text(
                tr('Создастся мгновенно и откроется редактор'),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            ListTile(
              leading: const Icon(Icons.data_object, color: Colors.deepPurple),
              title: Text(
                tr('Новый Lua-скрипт'),
                style: TextStyle(color: cs.onSurface),
              ),
              subtitle: Text(
                tr('.lua с функцией события'),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              onTap: () => Navigator.pop(ctx, 'new_lua'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open, color: Colors.blue),
              title: Text(
                tr('Существующий файл'),
                style: TextStyle(color: cs.onSurface),
              ),
              onTap: () => Navigator.pop(ctx, 'existing'),
            ),
            ListTile(
              leading: const Icon(Icons.functions, color: Colors.purple),
              title: Text(
                tr('Существующая функция'),
                style: TextStyle(color: cs.onSurface),
              ),
              onTap: () => Navigator.pop(ctx, 'existing_function'),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add, color: Colors.amber),
              title: Text(
                tr('Новая функция'),
                style: TextStyle(color: cs.onSurface),
              ),
              onTap: () => Navigator.pop(ctx, 'new_function'),
            ),
          ],
        ),
      ),
    ).then((choice) {
      if (choice == 'new') {
        setTriggerScript(index, type, isNew: true);
      } else if (choice == 'new_lua') {
        setTriggerScript(index, type, isNew: true, lua: true);
      } else if (choice == 'existing') {
        setTriggerScript(index, type, isNew: false);
      } else if (choice == 'new_function') {
        setTriggerFunction(index, type, isNew: true);
      } else if (choice == 'existing_function') {
        setTriggerFunction(index, type, isNew: false);
      }
    });
  }

  void showTriggerOptions(int index, {bool includeTargetNodeId = true}) {
    final item = getItem(index);
    final triggers = item.resolvedTriggers;
    final cs = Theme.of(context).colorScheme;

    showAdaptiveSheet(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  tr('Триггеры элемента'),
                  style: TextStyle(
                    color: cs.onSurface,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              if (triggers.isNotEmpty)
                ...triggers.entries.map((e) {
                  final tType = e.key;
                  final tRef = e.value;
                  return _TriggerSlotTile(
                    scripts: _scripts,
                    triggerType: tType,
                    rawRef: tRef,
                    onOpen: () {
                      Navigator.pop(ctx);
                      editTriggerScript(tRef);
                    },
                    onDelete: () {
                      Navigator.pop(ctx);
                      removeTrigger(index, tType);
                    },
                  );
                }),

              if (item.targetNodeId != null && item.targetNodeId!.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.login, color: Colors.green),
                  title: Text(
                    tr('Переход к ноде'),
                    style: TextStyle(color: cs.onSurface),
                  ),
                  subtitle: Text(
                    item.targetNodeId!,
                    style: TextStyle(color: cs.primary),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.edit, color: cs.onSurfaceVariant),
                        onPressed: () {
                          Navigator.pop(ctx);
                          setTargetNodeId(index);
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.delete, color: cs.error),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          if (item.type == 'button') {
                            await deleteConnection(
                              questId,
                              nodeId,
                              item.targetNodeId!,
                            );
                          }
                          updateItem(
                            index,
                            item.copyWith(clearTargetNodeId: true),
                          );
                        },
                      ),
                    ],
                  ),
                ),

              Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),

              ListTile(
                leading: Icon(Icons.add_circle, color: cs.primary),
                title: Text(
                  tr('Добавить триггер'),
                  style: TextStyle(color: cs.onSurface),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final type = await pickTriggerType(
                    includeTargetNodeId: includeTargetNodeId,
                  );
                  if (type != null) {
                    addTrigger(index, type);
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> renameItem(int index) async {
    final item = getItem(index);
    final result = await showTextInputDialog(
      title: tr('Переименовать элемент'),
      initialValue: item.text ?? '',
    );
    if (result == null) return;

    final trimmed = result.trim();
    updateItem(index, item.copyWith(text: trimmed.isEmpty ? null : trimmed));
  }

  Future<String?> showTextInputDialog({
    required String title,
    String initialValue = '',
  }) {
    final controller = TextEditingController(text: initialValue);
    final cs = Theme.of(context).colorScheme;
    return showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surfaceContainerHigh,
        title: Text(title, style: TextStyle(color: cs.onSurface)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: cs.onSurface),
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
}

/// Строка занятого слота триггера: имя скрипта (резолвится асинхронно),
/// чип типа (JSON/Lua/ƒ), тап по строке открывает редактор.
class _TriggerSlotTile extends StatefulWidget {
  final ScriptService scripts;
  final String triggerType;
  final String rawRef;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  const _TriggerSlotTile({
    required this.scripts,
    required this.triggerType,
    required this.rawRef,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  State<_TriggerSlotTile> createState() => _TriggerSlotTileState();
}

class _TriggerSlotTileState extends State<_TriggerSlotTile> {
  String? _name;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = await widget.scripts.displayName(widget.rawRef);
    if (mounted) setState(() => _name = name);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ref = TriggerReference.parse(widget.rawRef);
    final kind = ScriptService.kindOfRef(widget.rawRef);
    final (chipLabel, chipIcon, chipColor) = switch (kind) {
      ScriptKind.json => ('JSON', Icons.account_tree_rounded, Colors.blue),
      ScriptKind.lua => ('Lua', Icons.data_object_rounded, Colors.deepPurple),
      ScriptKind.unknown => ('?', Icons.help_outline_rounded, cs.outline),
    };
    final isFunction = ref.isFunctionRef;
    final displayLabel = isFunction ? 'ƒ' : chipLabel;
    final displayIcon = isFunction ? Icons.functions_rounded : chipIcon;
    final displayColor = isFunction ? Colors.purple : chipColor;

    return ListTile(
      leading: const Icon(Icons.bolt, color: Colors.amber),
      title: Row(
        children: [
          Expanded(
            child: Text(
              TriggerService.labelForTrigger(widget.triggerType),
              style: TextStyle(color: cs.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: displayColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(displayIcon, size: 12, color: displayColor),
                const SizedBox(width: 4),
                Text(
                  displayLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: displayColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      subtitle: Text(
        _name ?? widget.rawRef,
        style: TextStyle(color: cs.primary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: widget.onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.edit, color: cs.onSurfaceVariant),
            onPressed: widget.onOpen,
          ),
          IconButton(
            icon: Icon(Icons.delete, color: cs.error),
            onPressed: widget.onDelete,
          ),
        ],
      ),
    );
  }
}

/// Строка настройки в диалоге: значение печатаем целиком. `ListTile` режет
/// заголовок до одной строки, а имя файла вида `1789941265873.png` без хвоста
/// не опознать.
class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final String emptyText;
  final String caption;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _SettingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.emptyText,
    required this.caption,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final muted = scheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(icon, color: scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: textTheme.labelSmall?.copyWith(color: muted),
                  ),
                  Text(
                    value ?? emptyText,
                    style: textTheme.bodyMedium?.copyWith(
                      color: value == null ? muted : scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    caption,
                    style: textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            if (onClear != null)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: tr('Снять'),
                onPressed: onClear,
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Icon(Icons.chevron_right, color: muted),
              ),
          ],
        ),
      ),
    );
  }
}
