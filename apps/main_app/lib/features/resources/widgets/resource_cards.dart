import 'package:flutter/material.dart';

import 'package:canvas_app/shared/widgets/image_sizing.dart';
import 'package:canvas_app/shared/widgets/local_file_image.dart';
import 'package:flutter/services.dart';

import 'package:mnd_player/services/font_service.dart';
import 'package:canvas_app/features/resources/models/resource_file.dart';
import 'package:canvas_app/features/resources/widgets/audio_preview_button.dart';
import 'package:canvas_app/features/resources/widgets/resource_type_visuals.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Янтарный акцент для папок (единый для всего экрана ресурсов).
const Color kFolderColor = Color(0xFFFFB300);

/// Контекстное меню ресурса: «Копировать id / Переименовать / Заменить /
/// Сохранить на устройство / Удалить».
///
/// У меню два входа: кнопка «⋮» и правая кнопка мыши по карточке. Долгий тап,
/// с которого меню rosло, на ПК недоступен, поэтому пункты и обработка живут
/// здесь — иначе два входа со временем разъехались бы.
class _ResourceMenu {
  /// Токен, которым движок находит этот файл (`cat.png`, uuid или путь для
  /// скрипта). Пусто — пункт меню не показываем.
  final String reference;
  final bool canReplace;
  final VoidCallback? onRename;
  final VoidCallback? onReplace;
  final VoidCallback? onDelete;

  /// «Сохранить на устройство» — только там, где файл действительно есть
  /// (в пикере ресурсов этот пункт был бы лишним), поэтому null = нет пункта.
  final VoidCallback? onExport;

  const _ResourceMenu({
    required this.reference,
    required this.canReplace,
    this.onRename,
    this.onReplace,
    this.onDelete,
    this.onExport,
  });

  Future<void> _copyReference(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: reference));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // Коротко: автор жмёт «копировать» много раз подряд, и длинное
        // сообщение мешало бы следующему тапу.
        duration: const Duration(seconds: 2),
        content: Text(trf('Скопировано: {reference}', {'reference': reference})),
      ),
    );
  }

  void _handle(BuildContext context, String val) {
    switch (val) {
      case 'copy':
        _copyReference(context);
        break;
      case 'rename':
        onRename?.call();
        break;
      case 'replace':
        onReplace?.call();
        break;
      case 'delete':
        onDelete?.call();
        break;
      case 'export':
        onExport?.call();
        break;
    }
  }

  List<PopupMenuEntry<String>> _items(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      if (reference.isNotEmpty)
        PopupMenuItem(
          value: 'copy',
          child: ListTile(
            leading: Icon(Icons.link_rounded),
            title: Text(tr('Копировать id ресурса')),
            subtitle: Text(
              tr('Вставить в формулу или поле источника'),
              style: TextStyle(fontSize: 11),
            ),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      PopupMenuItem(
        value: 'rename',
        child: ListTile(
          leading: Icon(Icons.edit_rounded),
          title: Text(tr('Переименовать')),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      if (canReplace)
        PopupMenuItem(
          value: 'replace',
          child: ListTile(
            leading: Icon(Icons.swap_horiz_rounded),
            title: Text(tr('Заменить файл')),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      if (onExport != null)
        PopupMenuItem(
          value: 'export',
          child: ListTile(
            leading: Icon(
              Icons.download_rounded,
              color: scheme.onSurfaceVariant,
            ),
            title: Text(tr('Сохранить на устройство')),
            subtitle: Text(
              tr('Забрать файл из песочницы приложения'),
              style: TextStyle(fontSize: 11),
            ),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      PopupMenuItem(
        value: 'delete',
        child: ListTile(
          leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
          title: Text(tr('Удалить'), style: TextStyle(color: scheme.error)),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ];
  }

  /// То же меню у курсора — правый клик по карточке или строке.
  void showAt(BuildContext context, Offset origin) async {
    final scheme = Theme.of(context).colorScheme;
    final val = await showMenu<String>(
      context: context,
      position: contextMenuRect(origin, MediaQuery.sizeOf(context)),
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: _items(context),
    );
    if (!context.mounted || val == null) return;
    _handle(context, val);
  }
}

class _ResourceMenuButton extends StatelessWidget {
  final _ResourceMenu menu;
  final double iconSize;

  const _ResourceMenuButton({required this.menu, this.iconSize = 20});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert_rounded,
        color: scheme.onSurfaceVariant,
        size: iconSize,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      onSelected: (val) => menu._handle(context, val),
      itemBuilder: (_) => menu._items(context),
    );
  }
}

/// Превью-плитка ресурса для сеточного режима.
class ResourceGridCard extends StatelessWidget {
  final ResourceFile resource;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String questId;
  final VoidCallback? onRename;
  final VoidCallback? onReplace;
  final VoidCallback? onDelete;
  final VoidCallback? onExport;

  const ResourceGridCard({
    super.key,
    required this.resource,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.questId,
    this.onRename,
    this.onReplace,
    this.onDelete,
    this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menu = _ResourceMenu(
      canReplace: resource.type != 'script',
      reference: resource.reference,
      onRename: onRename,
      onReplace: onReplace,
      onDelete: onDelete,
      onExport: onExport,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: isSelected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: isSelected
            ? Border.all(color: scheme.primary, width: 2)
            : Border.all(color: scheme.outlineVariant),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          // ПК: то же меню, что у кнопки «⋮», но под курсором и без поиска
          // по экрану глазами — карточек в сетке много.
          onSecondaryTapUp: (details) =>
              menu.showAt(context, details.globalPosition),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: _Preview(resource: resource, questId: questId),
                  ),
                  Expanded(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            resource.friendlyName,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const Spacer(),
                          Text(
                            ResourceTypeVisuals.metaLine(resource),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 10,
                left: 10,
                child: ResourceTypeBadge(resource: resource),
              ),
              if (isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.check_rounded,
                      color: scheme.onPrimary,
                      size: 16,
                    ),
                  ),
                ),
              if (resource.type == 'audio' && !isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: AudioPreviewButton(
                    questId: questId,
                    resourcePath: resource.path,
                  ),
                ),
              if (!isSelected)
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: _ResourceMenuButton(menu: menu),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  final ResourceFile resource;
  final String questId;
  const _Preview({required this.resource, required this.questId});

  @override
  Widget build(BuildContext context) {
    if (resource.type == 'image') {
      return LocalFileImage(
        relativePath: resource.path,
        // Сетка ресурсов — тайлы ~210 px: исходник декодируется под них.
        cacheWidth: imageDecodeWidth(context, divisor: 3, min: 160, max: 480),
        placeholder: const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        errorBuilder: (_, __, ___) => _IconFill(resource: resource),
      );
    }

    if (resource.type == 'font') {
      return FontPreview(questId: questId, fileName: resource.name);
    }

    return _IconFill(resource: resource);
  }
}

class _IconFill extends StatelessWidget {
  final ResourceFile resource;
  const _IconFill({required this.resource});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Center(child: ResourceTypeAvatar(resource: resource, size: 56)),
    );
  }
}

/// Списочная строка ресурса.
class ResourceListTile extends StatelessWidget {
  final ResourceFile resource;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onRename;
  final VoidCallback? onReplace;
  final VoidCallback? onDelete;
  final VoidCallback? onExport;
  final String questId;

  const ResourceListTile({
    super.key,
    required this.resource,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.questId,
    this.onRename,
    this.onReplace,
    this.onDelete,
    this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = ResourceTypeVisuals.color(resource, context);
    final menu = _ResourceMenu(
      canReplace: resource.type != 'script',
      reference: resource.reference,
      onRename: onRename,
      onReplace: onReplace,
      onDelete: onDelete,
      onExport: onExport,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: isSelected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: isSelected
            ? Border.all(color: scheme.primary, width: 1.5)
            : Border.all(color: scheme.outlineVariant),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTapUp: (details) =>
              menu.showAt(context, details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                _leading(),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        resource.friendlyName,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              ResourceTypeVisuals.typeLabel(resource),
                              style: TextStyle(
                                color: accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              ResourceTypeVisuals.metaLine(resource),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (resource.type == 'audio')
                  AudioPreviewButton(
                    questId: questId,
                    resourcePath: resource.path,
                    small: true,
                  ),
                if (isSelected)
                  Icon(
                    Icons.check_circle_rounded,
                    color: scheme.primary,
                    size: 22,
                  )
                else
                  _ResourceMenuButton(menu: menu, iconSize: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _leading() {
    if (resource.type == 'image') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 48,
          height: 48,
          child: LocalFileImage(
            relativePath: resource.path,
            cacheWidth: 96,
            errorBuilder: (_, __, ___) =>
                ResourceTypeAvatar(resource: resource, size: 48),
            placeholder: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    return ResourceTypeAvatar(resource: resource, size: 48);
  }
}

/// Превью-карточка шрифта (рендерит "Aa" загруженным шрифтом).
class FontPreview extends StatefulWidget {
  final String questId;
  final String fileName;

  const FontPreview({super.key, required this.questId, required this.fileName});

  @override
  State<FontPreview> createState() => _FontPreviewState();
}

class _FontPreviewState extends State<FontPreview> {
  String? _loadedFamily;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final family = await FontService.loadQuestFont(
      widget.questId,
      widget.fileName,
    );
    if (mounted) setState(() => _loadedFamily = family);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Center(
        child: _loadedFamily == null
            ? const CircularProgressIndicator(strokeWidth: 2)
            : Text(
                'Aa',
                style: TextStyle(
                  fontFamily: _loadedFamily,
                  fontSize: 46,
                  color: scheme.onSurface,
                ),
              ),
      ),
    );
  }
}

/// Карточка папки (как в библиотеке): grid и list режимы.
class FolderCard extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback? onLongPress;
  final bool isBack;
  final ViewType viewType;
  final bool isSelected;

  /// Кол-во элементов внутри папки (файлы + подпапки). -1 = неизвестно/скрыть.
  final int itemCount;

  /// До 4 ресурсов внутри папки для превью-коллажа (приоритет — картинки).
  final List<ResourceFile> previewResources;

  /// Нужен для рендера превью изображений внутри папки.
  final String? questId;

  const FolderCard({
    super.key,
    required this.name,
    required this.onTap,
    this.isBack = false,
    this.onRename,
    this.onDelete,
    this.onLongPress,
    required this.viewType,
    required this.isSelected,
    this.itemCount = -1,
    this.previewResources = const [],
    this.questId,
  });

  /// Информативный подзаголовок вместо неинформативного «Папка».
  String _countLabel() {
    if (itemCount < 0) return '';
    if (itemCount == 0) return tr('Пусто');
    return '$itemCount ${trp(['элемент', 'элемента', 'элементов'], itemCount)}';
  }

  /// Squircle-превью папки (M3: плоский tonal-контейнер без свечения).
  /// Если внутри есть ресурсы — рисует коллаж их превью, иначе иконку папки.
  Widget _folderIcon(double boxSize) {
    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final isFixedSize = boxSize.isFinite;
        final width = isFixedSize ? boxSize : double.infinity;
        final height = isFixedSize ? boxSize : double.infinity;
        final radius = BorderRadius.circular(isFixedSize ? boxSize * 0.30 : 18);
        final iconSize = isFixedSize ? boxSize * 0.52 : 40.0;
        if (isBack) {
          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: radius,
            ),
            child: Icon(
              Icons.keyboard_return_rounded,
              size: isFixedSize ? boxSize * 0.5 : 40,
              color: scheme.onSurfaceVariant,
            ),
          );
        }
        if (previewResources.isEmpty) {
          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: kFolderColor.withOpacity(0.16),
              borderRadius: radius,
            ),
            child: Icon(
              Icons.folder_rounded,
              size: iconSize,
              color: kFolderColor,
            ),
          );
        }
        return ClipRRect(
          borderRadius: radius,
          child: SizedBox(
            width: width,
            height: height,
            child: _FolderPreview(
              resources: previewResources,
              questId: questId,
              totalCount: itemCount,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = isSelected
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest;
    final borderColor = isSelected ? scheme.primary : scheme.outlineVariant;

    if (viewType == ViewType.grid) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: isBack ? null : onLongPress,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                        child: _folderIcon(double.infinity),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isBack ? tr('Назад') : name,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const Spacer(),
                            if (!isBack && itemCount >= 0)
                              Text(
                                _countLabel(),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 11,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (isSelected)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Icon(
                      Icons.check_circle_rounded,
                      color: scheme.primary,
                      size: 22,
                    ),
                  ),
                if (!isBack && !isSelected)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      icon: Icon(
                        Icons.more_vert_rounded,
                        color: scheme.onSurfaceVariant,
                        size: 20,
                      ),
                      onPressed: () => _showFolderMenu(context),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: isSelected ? 1.5 : 1),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: isBack ? null : onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            child: Row(
              children: [
                _folderIcon(48),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        isBack ? tr('Назад') : name,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (!isBack && itemCount >= 0) ...[
                        const SizedBox(height: 3),
                        Text(
                          _countLabel(),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isSelected)
                  Icon(
                    Icons.check_circle_rounded,
                    color: scheme.primary,
                    size: 22,
                  )
                else if (!isBack)
                  IconButton(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    onPressed: () => _showFolderMenu(context),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showFolderMenu(BuildContext context) {
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: Text(tr('Переименовать')),
                onTap: () {
                  Navigator.pop(ctx);
                  onRename?.call();
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: scheme.error,
                ),
                title: Text(tr('Удалить'), style: TextStyle(color: scheme.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  onDelete?.call();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Чип-фильтр по типу ресурса (как в маркете).
class ResourceFilterChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const ResourceFilterChip({
    super.key,
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: isSelected
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? Colors.transparent
                : scheme.outlineVariant.withOpacity(0.5),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isSelected ? Icons.check_rounded : icon,
                    size: 18,
                    color: isSelected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w600,
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
}

/// Коллаж-превью содержимого папки: 1–4 миниатюры ресурсов (приоритет —
/// картинки). Картинки рендерятся реальными миниатюрами, прочие типы —
/// цветными tonal-плитками с иконкой типа. Плоский M3-стиль.
class _FolderPreview extends StatelessWidget {
  final List<ResourceFile> resources;
  final String? questId;
  final int totalCount;

  const _FolderPreview({
    required this.resources,
    required this.questId,
    required this.totalCount,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tiles = resources.take(4).toList();

    Widget tile(ResourceFile r) =>
        _FolderPreviewTile(resource: r, questId: questId);

    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        if (tiles.length == 1) return tile(tiles[0]);

        const gap = 2.0;
        final itemWidth = (constraints.maxWidth - gap) / 2;
        final itemHeight = tiles.length <= 2
            ? constraints.maxHeight
            : (constraints.maxHeight - gap) / 2;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in tiles)
              SizedBox(width: itemWidth, height: itemHeight, child: tile(item)),
          ],
        );
      },
    );

    // «+N» индикатор, если в папке больше показанных миниатюр.
    final extra = totalCount - tiles.length;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surfaceContainerHigh, child: content),
        if (extra > 0)
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '+$extra',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FolderPreviewTile extends StatelessWidget {
  final ResourceFile resource;
  final String? questId;

  const _FolderPreviewTile({required this.resource, required this.questId});

  @override
  Widget build(BuildContext context) {
    if (resource.type == 'image') {
      return LocalFileImage(
        relativePath: resource.path,
        cacheWidth: imageDecodeWidth(context, divisor: 3, min: 160, max: 480),
        placeholder: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        errorBuilder: (_, __, ___) => _typeTile(),
      );
    }
    return _typeTile();
  }

  Widget _typeTile() {
    return Builder(
      builder: (context) {
        final color = ResourceTypeVisuals.color(resource, context);
        return ColoredBox(
          color: color.withOpacity(0.18),
          child: Center(
            child: Icon(
              ResourceTypeVisuals.icon(resource),
              color: color,
              size: 18,
            ),
          ),
        );
      },
    );
  }
}
