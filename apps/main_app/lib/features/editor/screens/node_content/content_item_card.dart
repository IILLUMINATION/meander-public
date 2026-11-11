import 'dart:io';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:mnd_player/widgets/shared/markdown_color.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';

class ContentItemCard extends StatelessWidget {
  final ContentItem item;
  final int index;
  final String questId;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback? onRename;
  final VoidCallback? onTriggerSettings;
  final VoidCallback? onOnAppearTriggerTap;
  final VoidCallback? onOnPressTriggerTap;
  final VoidCallback? onLayoutSettings;
  final VoidCallback? onCopy; // <-- НОВЫЙ КОЛЛБЕК
  final VoidCallback? onPasteInto;
  final VoidCallback? onSaveAsTemplate;
  final Function(String)? onJumpToTarget;
  final String? displayScriptName;
  final String? pluginTitle;
  final Color? pluginAccentColor;
  final bool hasTriggerWarning;
  final String? triggerWarningMessage;

  // ====== Linked-template badge (Templates v2) ======
  /// Имя мастер-шаблона, на который ссылается этот ContentItem.
  /// Если задан — карточка показывает полоску в шапке с двумя возможными
  /// цветами (см. [templateInstanceIsMaster]).
  final String? templateInstanceName;

  /// true — `item.templateRef` есть, но мастер не найден в репозитории
  /// (удалён или ещё не загружен). Полоска становится красной.
  final bool templateInstanceMissing;

  /// true — это сам **мастер**-элемент (источник правды для linked).
  /// Полоска золотая, иконка корона. Редактирование работает обычным
  /// способом (в отличие от linked), а после сохранения ноды изменения
  /// синхронизируются в `TemplateRepository`.
  ///
  /// false — это **linked**-инстанс, read-only, полоска голубая.
  final bool templateInstanceIsMaster;

  /// Опциональный обработчик клика по полоске шаблона (меню действий).
  final VoidCallback? onTemplateInstanceTap;

  const ContentItemCard({
    super.key,
    required this.item,
    required this.index,
    required this.questId,
    required this.onDelete,
    required this.onEdit,
    this.onRename,
    this.onTriggerSettings,
    this.onOnAppearTriggerTap,
    this.onOnPressTriggerTap,
    this.onLayoutSettings,
    this.onCopy, // <--
    this.onPasteInto,
    this.onSaveAsTemplate,
    this.onJumpToTarget,
    this.displayScriptName,
    this.pluginTitle,
    this.pluginAccentColor,
    this.hasTriggerWarning = false,
    this.triggerWarningMessage,
    this.templateInstanceName,
    this.templateInstanceMissing = false,
    this.templateInstanceIsMaster = false,
    this.onTemplateInstanceTap,
  });

  Future<String> _resolveResourceName(
    String? resourcePath, {
    String? emptyLabel,
  }) async {
    // Подпись по умолчанию nullable: default-значение параметра обязано быть
    // compile-time константой, а tr() вызывается по текущему языку.
    if (resourcePath == null || resourcePath.isEmpty) {
      return emptyLabel ?? tr('Аудио');
    }
    final fileName = p.basename(resourcePath);
    final metadataPath = QuestPaths.metadata(questId);
    try {
      if (await FileStorage.exists(metadataPath)) {
        final metadata = await FileStorage.readJsonFile(metadataPath);
        final val = metadata[fileName];
        if (val is String && val.trim().isNotEmpty) {
          return val;
        }
        if (val is Map) {
          final name = val['name'] as String?;
          if (name != null && name.trim().isNotEmpty) {
            return name;
          }
        }
      }
    } catch (_) {}
    return p.basenameWithoutExtension(fileName);
  }

  @override
  Widget build(BuildContext context) {
    final bool isContainer =
        item.type == 'row' || item.type == 'column' || item.type == 'stack';
    final triggerMap = item.resolvedTriggers;
    final bool hasOnAppear = (triggerMap['onAppear'] ?? '').trim().isNotEmpty;
    final bool hasOnPress =
        ((item.type == 'input'
                    ? triggerMap['onSubmit']
                    : triggerMap['onPress']) ??
                '')
            .trim()
            .isNotEmpty;
    final bool hasAnyTrigger = triggerMap.values.any(
      (path) => path.trim().isNotEmpty,
    );
    final bool supportsTrigger = item.type != 'script';
    final bool hasTarget =
        (item.targetNodeId ?? '').trim().isNotEmpty &&
        !(item.targetNodeId ?? '').trim().startsWith('=');
    final bool canJumpToTarget =
        (item.type == 'button' || item.type == 'button_jump') && hasTarget;
    // audio и timer теперь тоже показывают статусные иконки (глазик onAppear).
    final bool supportsStatusActions =
        (item.type == 'button' ||
            item.type == 'button_jump' ||
            item.type == 'image' ||
            item.type == 'row' ||
            item.type == 'column' ||
            item.type == 'text' ||
            item.type == 'input' ||
            item.type == 'audio' ||
            item.type == 'delay' ||
            item.type == 'timer' ||
            item.type == 'stack') &&
        (onOnAppearTriggerTap != null ||
            onOnPressTriggerTap != null ||
            canJumpToTarget);
    // Типы, для которых в шапке доступен только глазик (onAppear),
    // без иконки onPress/onSubmit и без перехода к ноде.
    final bool onlyVisibilityTrigger =
        item.type == 'audio' || item.type == 'timer' || item.type == 'delay';

    final scheme = Theme.of(context).colorScheme;
    Color accentColor = scheme.onSurfaceVariant;
    IconData typeIcon = Icons.help_outline;

    switch (item.type) {
      case 'row':
        accentColor = Colors.orange;
        typeIcon = Icons.table_rows_rounded;
        break;
      case 'column':
        accentColor = Colors.purpleAccent;
        typeIcon = Icons.view_column_rounded;
        break;
      case 'stack':
        accentColor = Colors.lightGreenAccent;
        typeIcon = Icons.dashboard_customize_rounded;
        break;
      case 'button':
        accentColor = Colors.cyanAccent;
        typeIcon = Icons.smart_button;
        break;
      case 'button_jump':
        accentColor = Colors.tealAccent;
        typeIcon = Icons.forward_rounded;
        break;
      case 'script':
        accentColor = const Color(0xFF00C853);
        typeIcon = Icons.code;
        break;
      case 'text':
        accentColor = scheme.onSurface;
        typeIcon = Icons.text_fields;
        break;
      case 'image':
        accentColor = Colors.blue;
        typeIcon = Icons.image;
        break;
      case 'audio':
        accentColor = Colors.greenAccent;
        typeIcon = Icons.audiotrack;
        break;
      case 'video':
        accentColor = Colors.redAccent;
        typeIcon = Icons.videocam;
        break;
      case 'input':
        accentColor = Colors.pinkAccent;
        typeIcon = Icons.edit;
        break;
      case 'timer':
      case 'delay':
        accentColor = Colors.yellow;
        typeIcon = Icons.timer;
        break;
      case 'wait_input':
        accentColor = Colors.amberAccent;
        typeIcon = Icons.touch_app;
        break;
      case 'modal':
        accentColor = Colors.orangeAccent;
        typeIcon = Icons.chat_bubble_outline;
        break;
      case 'chat':
        accentColor = Colors.blueAccent;
        typeIcon = Icons.chat_bubble;
        break;
      case 'plugin':
        accentColor = pluginAccentColor ?? Colors.deepPurpleAccent;
        typeIcon = Icons.extension;
        break;
    }

    return GestureDetector(
      // ПК: правый клик по карточке — меню действий элемента, тот же набор
      // пунктов, что у кнопки «⋮».
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: _hasQuickActions(hasTarget, hasTriggerWarning)
          ? (details) => _showMenuAt(
              context,
              details.globalPosition,
              hasTrigger: hasAnyTrigger,
              hasTriggerWarning: hasTriggerWarning,
            )
          : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Полоска-индикатор для linked / master / битой ссылки.
            if (item.hasTemplateLink ||
                templateInstanceName != null ||
                templateInstanceMissing)
              _buildTemplateLinkedStripe(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: scheme.surfaceContainerHighest.withOpacity(0.4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: Container(
                      width: 34,
                      height: 34,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.drag_indicator,
                        color: scheme.onSurfaceVariant,
                        size: 22,
                      ),
                    ),
                  ),
                  Icon(typeIcon, size: 16, color: accentColor),
                  const SizedBox(width: 8),
                  if (supportsStatusActions) ...[
                    _buildStatusIconButton(
                      icon: Icons.visibility_outlined,
                      color: hasOnAppear
                          ? const Color(0xFFFFD54F)
                          : scheme.onSurfaceVariant,
                      onTap: supportsTrigger ? onOnAppearTriggerTap : null,
                      tooltip: tr('Триггер onAppear'),
                    ),
                    if (!onlyVisibilityTrigger)
                      _buildStatusIconButton(
                        icon: item.type == 'input'
                            ? Icons.input_rounded
                            : Icons.touch_app_outlined,
                        color: hasOnPress
                            ? const Color(0xFFE040FB)
                            : scheme.onSurfaceVariant,
                        onTap: supportsTrigger ? onOnPressTriggerTap : null,
                        tooltip: item.type == 'input'
                            ? tr('Скрипт при вводе (onSubmit)')
                            : tr('Скрипт по нажатию (onPress)'),
                      ),
                    if (item.type == 'button' || item.type == 'button_jump')
                      _buildStatusIconButton(
                        icon: Icons.open_in_new,
                        color: canJumpToTarget
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                                context,
                              ).colorScheme.onSurface.withOpacity(0.38),
                        onTap: canJumpToTarget && onJumpToTarget != null
                            ? () => onJumpToTarget!(item.targetNodeId!)
                            : null,
                        tooltip: tr('Переход к ноде'),
                      ),
                    // Полное окно «Триггеры элемента»: все слоты + переходы +
                    // добавление. Тапы по иконкам выше — быстрые действия.
                    if (onTriggerSettings != null)
                      _buildStatusIconButton(
                        icon: Icons.bolt,
                        color: hasAnyTrigger
                            ? Colors.amber
                            : scheme.onSurfaceVariant,
                        onTap: onTriggerSettings,
                        tooltip: tr('Все триггеры элемента'),
                      ),
                    const SizedBox(width: 4),
                  ],
                  if (onLayoutSettings != null)
                    _buildFlexButton(item.flex, onLayoutSettings!),
                  if (onCopy != null)
                    _buildIconButton(
                      Icons.copy,
                      scheme.onSurfaceVariant,
                      onCopy!,
                      tooltip: tr('Копировать'),
                    ),
                  _buildIconButton(Icons.edit, scheme.onSurfaceVariant, onEdit),
                  _buildIconButton(
                    Icons.delete_outline,
                    scheme.error,
                    onDelete,
                  ),
                  if (_hasQuickActions(hasTarget, hasTriggerWarning))
                    _buildMoreActionsMenu(
                      hasTrigger: hasAnyTrigger,
                      hasTriggerWarning: hasTriggerWarning,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  isContainer
                      ? _buildContainerPreview(item, context)
                      : _buildItemContent(item, context, questId),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTemplateLinkedStripe() {
    final isBroken = templateInstanceMissing;
    final isMaster = templateInstanceIsMaster && !isBroken;

    // Цвета:
    // * красный — битая ссылка
    // * золотой — мастер-элемент (правки распространяются)
    // * голубой — обычный linked-инстанс (read-only от мастера)
    final Color color;
    if (isBroken) {
      color = Colors.redAccent;
    } else if (isMaster) {
      color = Colors.amber;
    } else {
      color = Colors.cyanAccent;
    }

    final IconData icon;
    if (isBroken) {
      icon = Icons.link_off;
    } else if (isMaster) {
      icon = Icons.workspace_premium; // «корона»-эмблема мастер-шаблона
    } else {
      icon = Icons.link;
    }

    final String label;
    if (isBroken) {
      label = tr('Шаблон удалён или недоступен');
    } else if (isMaster) {
      label = templateInstanceName != null && templateInstanceName!.isNotEmpty
          ? trf('Мастер шаблона: {p0}', {'p0': templateInstanceName!})
          : tr('Мастер шаблона');
    } else {
      label = templateInstanceName != null && templateInstanceName!.isNotEmpty
          ? trf('Связан с шаблоном: {p0}', {'p0': templateInstanceName!})
          : tr('Связан с шаблоном');
    }

    return InkWell(
      onTap: onTemplateInstanceTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          border: Border(
            bottom: BorderSide(color: color.withOpacity(0.35), width: 0.8),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (item.templateVersion != null && !isBroken) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'v${item.templateVersion}',
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            if (onTemplateInstanceTap != null) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right,
                color: color.withOpacity(0.7),
                size: 14,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIconButton(
    IconData icon,
    Color color,
    VoidCallback onTap, {
    String? tooltip,
  }) {
    return IconButton(
      icon: Icon(icon, size: 18, color: color),
      onPressed: onTap,
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: const EdgeInsets.all(4),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        hoverColor: color.withOpacity(0.1),
      ),
    );
  }

  Widget _buildStatusIconButton({
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
    required String tooltip,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20, color: color),
      onPressed: onTap,
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      padding: const EdgeInsets.all(3),
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        hoverColor: color.withOpacity(0.1),
      ),
    );
  }

  bool _hasQuickActions(bool hasTarget, bool hasTriggerWarning) {
    // Переименовать оставляем только для контейнеров (row/column).
    final bool isContainer =
        item.type == 'row' || item.type == 'column' || item.type == 'stack';
    return (isContainer && onRename != null) ||
        onSaveAsTemplate != null ||
        (isContainer && onPasteInto != null) ||
        // Триггеры: пункт показываем, если хост не вынес их в иконки шапки,
        // но передал onTriggerSettings (например, container_editor_screen).
        (onTriggerSettings != null &&
            item.type != 'script' &&
            onOnAppearTriggerTap == null &&
            onOnPressTriggerTap == null) ||
        // Сообщение о проблеме триггера — чтобы пользователь мог его прочитать.
        hasTriggerWarning;
  }

  Widget _buildFlexButton(int flex, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: tr('Размер в контейнере'),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.45)),
            ),
            child: Text(
              'x$flex',
              style: const TextStyle(
                color: Colors.orangeAccent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onMenuAction(String value) {
    if (value == 'rename') onRename?.call();
    if (value == 'paste_into') onPasteInto?.call();
    if (value == 'save_template') onSaveAsTemplate?.call();
    if (value == 'trigger') onTriggerSettings?.call();
    // 'trigger_warning' — информационный пункт, действий не выполняет.
  }

  /// Пункты меню «Действия» — общие для кнопки «⋮» и правого клика по
  /// карточке: на ПК долгий тап недоступен, а искать иконку на каждом
  /// элементе ленты — лишнее движение мышью.
  List<PopupMenuEntry<String>> _menuItems(
    BuildContext context, {
    required bool hasTrigger,
    required bool hasTriggerWarning,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Меню упрощено: копирование вынесено в отдельную иконку,
    // триггеры — в иконки шапки, «Перейти к ноде» — иконка у кнопок.
    final bool isContainer = item.type == 'row' || item.type == 'column';
    final items = <PopupMenuEntry<String>>[];
    // Переименовать — только для контейнеров (row/column).
    if (isContainer && onRename != null) {
      items.add(
        PopupMenuItem(value: 'rename', child: Text(tr('Переименовать'))),
      );
    }
    if (onSaveAsTemplate != null) {
      items.add(
        PopupMenuItem(
          value: 'save_template',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.bookmark_add_outlined, size: 18),
            title: Text(tr('Сохранить как шаблон')),
          ),
        ),
      );
    }
    // Вставить внутрь — только для контейнеров (row/column).
    if (isContainer && onPasteInto != null) {
      items.add(
        PopupMenuItem(value: 'paste_into', child: Text(tr('Вставить внутрь'))),
      );
    }
    // Триггеры: показываем, только если хост не вынес их в шапку.
    // Это покрывает container_editor_screen, где иконки шапки не
    // подключены — иначе настройки триггера были бы недостижимы.
    if (onTriggerSettings != null &&
        item.type != 'script' &&
        onOnAppearTriggerTap == null &&
        onOnPressTriggerTap == null) {
      items.add(
        PopupMenuItem(
          value: 'trigger',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              hasTrigger ? Icons.bolt : Icons.bolt_outlined,
              size: 18,
            ),
            title: Text(
              hasTrigger ? tr('Триггер: изменить') : tr('Добавить триггер'),
            ),
          ),
        ),
      );
    }
    // Сообщение о проблеме триггера — информационный пункт.
    if (hasTriggerWarning) {
      items.add(
        PopupMenuItem(
          value: 'trigger_warning',
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.error_outline, size: 18, color: scheme.error),
            title: Text(
              triggerWarningMessage ?? tr('Проблема триггера'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        ),
      );
    }
    return items;
  }

  Widget _buildMoreActionsMenu({
    required bool hasTrigger,
    required bool hasTriggerWarning,
  }) {
    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return PopupMenuButton<String>(
          icon: Icon(
            hasTriggerWarning ? Icons.error_outline : Icons.more_horiz,
            color: hasTriggerWarning ? scheme.error : scheme.onSurfaceVariant,
          ),
          tooltip: tr('Действия'),
          onSelected: _onMenuAction,
          itemBuilder: (_) => _menuItems(
            context,
            hasTrigger: hasTrigger,
            hasTriggerWarning: hasTriggerWarning,
          ),
        );
      },
    );
  }

  /// То же меню у курсора — правый клик по карточке элемента.
  void _showMenuAt(
    BuildContext context,
    Offset origin, {
    required bool hasTrigger,
    required bool hasTriggerWarning,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final value = await showMenu<String>(
      context: context,
      position: contextMenuRect(origin, MediaQuery.sizeOf(context)),
      color: scheme.surfaceContainerHigh,
      items: _menuItems(
        context,
        hasTrigger: hasTrigger,
        hasTriggerWarning: hasTriggerWarning,
      ),
    );
    if (!context.mounted || value == null) return;
    _onMenuAction(value);
  }

  /// M3-обёртка для контента-превью: мягкий контейнер с иконкой-аватаром,
  /// заголовком и подзаголовком. Используется большинством типов элементов.
  Widget _buildTile(
    BuildContext context, {
    required IconData icon,
    required Color accent,
    required String title,
    String? subtitle,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                Text(
                  title,
                  style: textTheme.titleSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  Widget _buildContainerPreview(ContentItem item, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasName = item.text != null && item.text!.trim().isNotEmpty;

    Widget preview;
    if (item.children == null || item.children!.isEmpty) {
      preview = Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          tr('Контейнер пуст'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    } else {
      preview = SizedBox(
        height: 44,
        child: Row(
          children: item.children!.take(5).map((child) {
            return Expanded(
              flex: child.flex,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Icon(
                    _getIconForType(child.type),
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );
    }

    if (!hasName) return preview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            item.text!.trim(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: item.type == 'row' ? Colors.orange : Colors.purpleAccent,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        preview,
      ],
    );
  }

  Widget _buildItemContent(
    ContentItem item,
    BuildContext context,
    String questId,
  ) {
    final scheme = Theme.of(context).colorScheme;
    switch (item.type) {
      case 'text':
        final rawText = item.text ?? '';
        final display = rawText.length > 200
            ? '${rawText.substring(0, 200)}...'
            : rawText;
        final markdownText = preserveMarkdownHardLineBreaks(display);

        // Фрагментная `[outline=…]` рисуется штриховым слоем, как в игре:
        // копии глифа со сдвигом давали раздвоенный контур.
        MarkdownConfig configFor({bool strokeLayer = false}) => MarkdownConfig(
          configs: [
            PConfig(
              textStyle: strokeLayer
                  ? TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      foreground: transparentTextOutlineStroke,
                    )
                  : TextStyle(
                      color: scheme.onSurface,
                      fontSize: 14,
                      height: 1.3,
                    ),
            ),
            ListConfig(
              marginLeft: 18.0,
              marginBottom: 0.0,
              marker: safeListMarker(scheme.onSurface),
            ),
            CheckBoxConfig(builder: safeCheckboxBuilder(scheme.onSurface)),
            BlockquoteConfig(
              textColor: scheme.onSurfaceVariant,
              sideColor: scheme.onSurfaceVariant,
            ),
          ],
        );

        Widget layer({bool strokeLayer = false}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children:
              createColorMarkdownGenerator(
                linesMargin: const EdgeInsets.symmetric(vertical: 2),
                questId: questId,
                outlineMode: strokeLayer
                    ? TextOutlineMode.stroke
                    : TextOutlineMode.none,
              ).buildWidgets(
                markdownText,
                config: configFor(strokeLayer: strokeLayer),
              ),
        );

        if (!hasInlineOutline(markdownText)) return layer();
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.topLeft,
                child: layer(strokeLayer: true),
              ),
            ),
            layer(),
          ],
        );

      case 'button':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: scheme.secondaryContainer,
          ),
          child: Text(
            item.text ?? tr('Кнопка'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      case 'image':
        if (item.resourcePath == null) return const SizedBox.shrink();
        return FutureBuilder<File?>(
          // Тот же резолв, что у плеера: путь, имя из библиотеки или uuid.
          future: QuestImageSource.resolve(questId, item.resourcePath),
          builder: (context, snapshot) {
            if (snapshot.hasData && snapshot.data != null) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(
                  snapshot.data!,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              );
            }
            return Container(
              height: 80,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            );
          },
        );
      case 'audio':
        return FutureBuilder<String>(
          future: _resolveResourceName(item.resourcePath),
          builder: (context, snapshot) {
            return _buildTile(
              context,
              icon: Icons.music_note,
              accent: Colors.greenAccent,
              subtitle: tr('Аудио'),
              title:
                  snapshot.data ??
                  item.resourcePath?.split('/').last ??
                  tr('Аудио'),
            );
          },
        );
      case 'video':
        final src = item.effectiveVideoSource ?? tr('Видео');
        final isNet = item.videoUrl != null && item.videoUrl!.isNotEmpty;
        if (isNet) {
          return _buildTile(
            context,
            icon: Icons.videocam,
            accent: Colors.redAccent,
            subtitle: item.isYoutubeVideo ? 'YouTube' : tr('Видео URL'),
            title: item.videoUrl ?? src,
          );
        }
        return FutureBuilder<String>(
          // Как и у аудио: файл видео в библиотеке назван человеком, и это
          // имя автору полезнее `1790024448511_<uuid>.mp4`.
          future: _resolveResourceName(src, emptyLabel: tr('Видео')),
          builder: (context, snapshot) {
            return _buildTile(
              context,
              icon: Icons.videocam,
              accent: Colors.redAccent,
              subtitle: tr('Видео файл'),
              title: snapshot.data ?? src.split('/').last,
            );
          },
        );
      case 'script':
        return _buildTile(
          context,
          icon: Icons.terminal,
          accent: const Color(0xFF00C853),
          subtitle: tr('Логический скрипт'),
          title:
              displayScriptName ??
              item.resourcePath?.split('/').last ??
              'Script',
        );
      case 'input':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.text != null && item.text!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  item.text!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            _buildTile(
              context,
              icon: Icons.edit,
              accent: Colors.pinkAccent,
              subtitle: tr('Поле ввода'),
              title: trf('Сохранить в {{p0}}', {'p0': item.variableName}),
            ),
          ],
        );
      case 'timer':
      case 'delay':
        return _buildTile(
          context,
          icon: Icons.hourglass_bottom,
          accent: Colors.amber,
          subtitle: tr('Задержка'),
          title: trf('{p0} сек.', {'p0': item.text ?? '1'}),
          trailing: item.isHidden
              ? Icon(
                  Icons.visibility_off,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                )
              : null,
        );
      case 'wait_input':
        return _buildTile(
          context,
          icon: Icons.touch_app,
          accent: Colors.amberAccent,
          subtitle: tr('Пауза до клика'),
          title: item.text?.isNotEmpty == true
              ? item.text!
              : tr('Нажмите для продолжения'),
        );
      case 'modal':
        return _buildTile(
          context,
          icon: Icons.chat_bubble_outline,
          accent: Colors.orangeAccent,
          subtitle: tr('Модальное окно'),
          title: item.text?.isNotEmpty == true
              ? item.text!
              : tr('Модальное окно'),
        );
      case 'chat':
        final senderName = item.senderName ?? tr('Отправитель');
        final avatarColor = Color(item.avatarColor ?? 0xFF26C6DA);
        final text = item.text?.isNotEmpty == true
            ? item.text!
            : tr('Текст сообщения');
        final displayText = text.length > 150
            ? '${text.substring(0, 150)}...'
            : text;

        if (item.isIncoming) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: avatarColor,
                child: item.avatarPath != null
                    ? null
                    : const Icon(Icons.person, size: 16, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      senderName,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.zero,
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(16),
                        ),
                      ),
                      child: Text(
                        displayText,
                        style: TextStyle(color: scheme.onSurface, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        } else {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      senderName,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.zero,
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(16),
                        ),
                      ),
                      child: Text(
                        displayText,
                        style: TextStyle(
                          color: scheme.onPrimaryContainer,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
      case 'plugin':
        final title = pluginTitle ?? item.pluginTypeId ?? 'Plugin content';
        final data = item.pluginData ?? const <String, dynamic>{};
        final summary = data.isEmpty
            ? tr('Нет данных')
            : data.entries.map((e) => '${e.key}: ${e.value}').join(', ');
        return _buildTile(
          context,
          icon: Icons.extension,
          accent: pluginAccentColor ?? Colors.deepPurpleAccent,
          subtitle: title,
          title: summary,
        );
      default:
        return Text(
          item.type,
          style: TextStyle(color: scheme.onSurfaceVariant),
        );
    }
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case 'text':
        return Icons.text_fields;
      case 'button':
        return Icons.smart_button;
      case 'image':
        return Icons.image;
      case 'audio':
        return Icons.audiotrack;
      case 'script':
        return Icons.code;
      case 'timer':
      case 'delay':
        return Icons.timer;
      case 'input':
        return Icons.edit;
      case 'wait_input':
        return Icons.touch_app;
      case 'row':
        return Icons.table_rows_rounded;
      case 'column':
        return Icons.view_column_rounded;
      case 'plugin':
        return Icons.extension;
      default:
        return Icons.help_outline;
    }
  }
}
