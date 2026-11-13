import 'package:canvas_app/features/resources/models/resource_file.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:canvas_app/features/resources/widgets/resource_cards.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/features/music_library/screens/music_library_screen.dart';
import 'package:canvas_app/features/asset_market/screens/asset_market_screen.dart';
import 'package:canvas_app/features/library/screens/my_library_screen.dart';
import 'package:canvas_app/features/library/services/my_library_service.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Лёгкое описание выбранного ресурса, которое возвращается вызывающей
/// стороне через [Navigator.pop]. Контракт API экрана — оставлен прежним,
/// чтобы не ломать многочисленные места использования.
class SelectableResource {
  final String path;
  final String name;
  final String friendlyName;
  final String type;
  final String folder;

  SelectableResource({
    required this.path,
    required this.name,
    required this.friendlyName,
    required this.type,
    this.folder = '/',
  });
}

/// Экран выбора ресурса (картинка/аудио/шрифт/скрипт) из библиотеки квеста.
///
/// Редизайн под Material 3: использует токены темы (без захардкоженных
/// чёрно-белых цветов) и переиспользует те же карточки, что и основной
/// экран ресурсов — [ResourceGridCard], [ResourceListTile], [FolderCard],
/// [ResourceFilterChip].
class ResourceSelectionScreen extends ConsumerStatefulWidget {
  final String questId;
  final List<String> allowedTypes;

  const ResourceSelectionScreen({
    super.key,
    required this.questId,
    this.allowedTypes = const ['image'],
  });

  @override
  ConsumerState<ResourceSelectionScreen> createState() =>
      _ResourceSelectionScreenState();
}

class _ResourceSelectionScreenState
    extends ConsumerState<ResourceSelectionScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _currentFolder = '/';
  // 'all' либо один из allowedTypes — фильтр по типу. Показывается только
  // если allowedTypes.length > 1.
  String _selectedType = 'all';
  List<String> _explicitFolders = [];
  List<SelectableResource> _resources = [];
  bool _isLoading = true;
  bool _isGridView = true;

  /// Общая с экраном ресурсов настройка (#148): пережимать ввозимые PNG
  /// в WebP. Здесь её только читаем — переключатель живёт в меню «Добавить».
  bool _convertImagesOnImport = true;
  bool _showLibrary = false;
  List<LibraryItem> _libraryItems = [];
  bool _libraryLoading = false;

  ResourceService get _svc => ref.read(resourceServiceProvider(widget.questId));

  bool _matchesSearch(SelectableResource resource, String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return true;

    final fileNoExt = p.basenameWithoutExtension(resource.name).toLowerCase();
    final normalizedFolder = _normalizeFolderPath(
      resource.folder,
    ).toLowerCase();
    final normalizedPath = resource.path.toLowerCase();
    final normalizedFriendly = resource.friendlyName.toLowerCase();
    final normalizedName = resource.name.toLowerCase();

    return normalizedFriendly.contains(query) ||
        normalizedName.contains(query) ||
        fileNoExt.contains(query) ||
        normalizedPath.contains(query) ||
        normalizedFolder.contains(query);
  }

  String _normalizeFolderPath(String path) =>
      ResourceService.normalizeFolderPath(path);

  @override
  void initState() {
    super.initState();
    _loadViewPreference();
    _loadResources();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadViewPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isGridView = prefs.getBool('resources_grid_view') ?? true;
        _convertImagesOnImport =
            prefs.getBool('resources_convert_to_webp') ?? true;
      });
    }
  }

  Future<void> _toggleViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _isGridView = !_isGridView);
    await prefs.setBool('resources_grid_view', _isGridView);
  }

  Future<void> _loadResources() async {
    setState(() => _isLoading = true);
    try {
      final data = await _svc.loadResources();
      final relativeRoot = '${QuestPaths.questRoot(widget.questId)}/';

      final resources = data.resources
          .where((r) => widget.allowedTypes.contains(r.type))
          .map(
            (r) => SelectableResource(
              path: r.path.startsWith(relativeRoot)
                  ? r.path.substring(relativeRoot.length)
                  : r.path,
              name: r.name,
              friendlyName: r.friendlyName,
              type: r.type,
              folder: r.folder,
            ),
          )
          .toList();

      if (mounted) {
        setState(() {
          _explicitFolders = data.explicitFolders;
          _resources = resources;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadLibrary() async {
    setState(() => _libraryLoading = true);
    try {
      final items = await MyLibraryService.loadAssets();
      // map market kind to resource type for filtering
      String mapKind(String k) {
        if (k == 'background' || k == 'image') return 'image';
        if (k == 'sfx') return 'audio';
        return k;
      }
      final filtered = items.where((e) => widget.allowedTypes.contains(mapKind(e.kind))).toList();
      if (mounted) setState(() { _libraryItems = filtered; _libraryLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _libraryLoading = false);
    }
  }



  // --- Folder Logic ---

  List<String> get _allFolders {
    final folders = _explicitFolders.map(_normalizeFolderPath).toSet();
    for (var res in _resources) {
      final folder = _normalizeFolderPath(res.folder);
      if (folder != '/') folders.add(folder);
    }
    return folders.toList()..sort();
  }

  void _goUpOneLevel() {
    final parts = _normalizeFolderPath(_currentFolder).split('/');
    if (parts.length <= 2) {
      setState(() => _currentFolder = '/');
    } else {
      parts.removeLast();
      setState(() => _currentFolder = parts.join('/'));
    }
  }

  Future<void> _createNewFolder() async {
    final folderName = await _showNameDialog('', title: tr('Новая папка'));
    if (folderName == null || folderName.isEmpty || folderName.contains('/')) {
      return;
    }

    String newPath = _currentFolder == '/'
        ? '/$folderName'
        : '$_currentFolder/$folderName';
    newPath = _normalizeFolderPath(newPath);

    try {
      await _svc.createFolder(newPath);
      await _loadResources();
      if (!mounted) return;
      setState(() => _currentFolder = newPath);
    } catch (e) {
      // ignore
    }
  }

  // --- Adding Resources ---

  Future<void> _addNewResource() async {
    if (widget.allowedTypes.length > 1) {
      showAdaptiveSheet(
        context: context,
        scrollable: true,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Wrap(
            children: [
              if (widget.allowedTypes.contains('image'))
                ListTile(
                  leading: const Icon(Icons.image_rounded),
                  title: Text(tr('Картинки')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addImageResource();
                  },
                ),
              if (widget.allowedTypes.contains('audio'))
                ListTile(
                  leading: const Icon(Icons.audiotrack_rounded),
                  title: Text(tr('Аудио')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addAudioResource();
                  },
                ),
              if (widget.allowedTypes.contains('video'))
                ListTile(
                  leading: const Icon(Icons.videocam_rounded),
                  title: Text(tr('Видео')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addVideoResource();
                  },
                ),
              if (widget.allowedTypes.contains('font'))
                ListTile(
                  leading: const Icon(Icons.text_fields_rounded),
                  title: Text(tr('Шрифты')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addFontResource();
                  },
                ),
              if (widget.allowedTypes.contains('script'))
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: Text(tr('Новый скрипт')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _createScriptResource();
                  },
                ),
              if (widget.allowedTypes.contains('lua'))
                ListTile(
                  leading: const Icon(Icons.data_object_rounded),
                  title: Text(tr('Новый .lua')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _createLuaResource();
                  },
                ),
            ],
          ),
        ),
      );
    } else {
      if (widget.allowedTypes.contains('image')) {
        _addImageResource();
      } else if (widget.allowedTypes.contains('audio')) {
        _addAudioResource();
      } else if (widget.allowedTypes.contains('video')) {
        _addVideoResource();
      } else if (widget.allowedTypes.contains('font')) {
        _addFontResource();
      } else if (widget.allowedTypes.contains('script')) {
        _createScriptResource();
      } else if (widget.allowedTypes.contains('lua')) {
        _createLuaResource();
      }
    }
  }

  Future<void> _addImageResource() async {
    final picker = ImagePicker();
    final List<XFile> images = await picker.pickMultiImage();
    if (images.isEmpty) return;

    await _svc.importFiles(
      images
          .map((img) => (sourcePath: img.path, displayName: img.name))
          .toList(),
      'image',
      _currentFolder,
      convertImages: _convertImagesOnImport,
    );
    await _loadResources();
  }

  Future<void> _addAudioResource() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'ogg', 'm4a'],
    );
    if (files.isEmpty) return;

    await _svc.importFiles(
      files
          .where((f) => f.path != null)
          .map((f) => (sourcePath: f.path!, displayName: f.name))
          .toList(),
      'audio',
      _currentFolder,
    );
    await _loadResources();
  }

  Future<void> _addVideoResource() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v'],
      allowMultiple: true,
    );
    if (files.isEmpty) return;

    await _svc.importFiles(
      files
          .where((f) => f.path != null)
          .map((f) => (sourcePath: f.path!, displayName: f.name))
          .toList(),
      'video',
      _currentFolder,
    );
    await _loadResources();
  }

  Future<void> _addFontResource() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf'],
    );
    if (files.isEmpty) return;

    await _svc.importFiles(
      files
          .where((f) => f.path != null)
          .map((f) => (sourcePath: f.path!, displayName: f.name))
          .toList(),
      'font',
      _currentFolder,
    );
    await _loadResources();
  }

  /// Мгновенное «создать и выбрать»: без диалогов — авто-имя, папка =
  /// текущая, и сразу возвращаем вызывающей стороне.
  Future<void> _createScriptResource() async {
    final created = await _svc.createScript(folder: _currentFolder);
    await _loadResources();
    if (!mounted) return;
    Navigator.pop(
      context,
      SelectableResource(
        path: created.questRelativePath,
        name: created.fileName,
        friendlyName: created.name,
        type: 'script',
        folder: _currentFolder,
      ),
    );
  }

  Future<void> _createLuaResource() async {
    final created = await _svc.createLuaScript(folder: _currentFolder);
    await _loadResources();
    if (!mounted) return;
    Navigator.pop(
      context,
      SelectableResource(
        path: created.questRelativePath,
        name: created.fileName,
        friendlyName: created.name,
        type: 'lua',
        folder: _currentFolder,
      ),
    );
  }

  Future<void> _renameResource(SelectableResource resource) async {
    final newName = await _showNameDialog(
      resource.friendlyName,
      title: tr('Переименовать'),
    );
    final trimmed = newName?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == resource.friendlyName) return;

    // У скриптов имя дублируется в самом JSON — renameResource чинит и его,
    // и сообщает имя открытому редактору (иначе автосейв вернул бы старое).
    final isScript = resource.type == 'script' || resource.type == 'lua';
    if (isScript) {
      await _svc.renameByFileName(resource.name, trimmed);
    } else {
      await _svc.updateMetadata(
        resource.name,
        trimmed,
        _normalizeFolderPath(resource.folder),
      );
    }
    await _loadResources();
  }

  Future<String?> _showNameDialog(String initial, {required String title}) {
    final c = TextEditingController(text: initial);
    return showAppDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: Text(tr('ОК')),
            ),
          ],
        );
      },
    );
  }

  // --- UI ---

  /// Конвертирует наш [SelectableResource] в общий [ResourceFile], чтобы
  /// можно было переиспользовать M3-карточки из основного экрана ресурсов.
  /// Поле [ResourceFile.path] — полный путь от корня хранилища (с префиксом
  /// `quests/<id>/`), как ожидает рендер превью.
  ResourceFile _toResourceFile(SelectableResource r) {
    return ResourceFile(
      id: r.name,
      name: r.name,
      path: QuestPaths.questFile(widget.questId, r.path),
      type: r.type,
      friendlyName: r.friendlyName,
      folder: r.folder,
    );
  }

  /// Список «эффективно разрешённых» типов с учётом текущего фильтра-чипа.
  List<String> get _effectiveTypes {
    if (_selectedType == 'all') return widget.allowedTypes;
    return [_selectedType];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final entries = <Map<String, dynamic>>[];
    final currentFolder = _normalizeFolderPath(_currentFolder);
    final query = _searchQuery.trim().toLowerCase();
    final useFlatSearch = query.isNotEmpty;

    final effective = _effectiveTypes;

    if (useFlatSearch) {
      final filtered = _resources
          .where((r) => effective.contains(r.type))
          .where((r) => _matchesSearch(r, query))
          .toList();
      for (final res in filtered) {
        entries.add({'type': 'resource', 'resource': res});
      }
    } else {
      if (currentFolder != '/') {
        entries.add({'type': 'back'});
      }

      final directFolders = <String>{};
      for (final rawFolder in _allFolders) {
        final folder = _normalizeFolderPath(rawFolder);
        if (folder == '/') continue;
        if (currentFolder == '/') {
          final segments = folder
              .split('/')
              .where((s) => s.isNotEmpty)
              .toList();
          if (segments.length == 1) {
            directFolders.add(folder);
          }
          continue;
        }
        final prefix = '$currentFolder/';
        if (folder.startsWith(prefix)) {
          final relative = folder.substring(prefix.length);
          if (!relative.contains('/')) {
            directFolders.add(folder);
          }
        }
      }

      final sortedFolders = directFolders.toList()..sort();
      for (final folderPath in sortedFolders) {
        entries.add({
          'type': 'folder',
          'name': p.basename(folderPath),
          'path': folderPath,
        });
      }

      final files = _resources
          .where((r) => effective.contains(r.type))
          .where((r) => _normalizeFolderPath(r.folder) == currentFolder)
          .toList();
      for (var f in files) {
        entries.add({'type': 'resource', 'resource': f});
      }
    }

    final viewType = _isGridView ? ViewType.grid : ViewType.list;

    Widget buildEntry(Map<String, dynamic> e) {
      if (e['type'] == 'back') {
        return FolderCard(
          name: '..',
          isBack: true,
          viewType: viewType,
          isSelected: false,
          onTap: _goUpOneLevel,
        );
      }
      if (e['type'] == 'folder') {
        return FolderCard(
          name: e['name'] as String,
          viewType: viewType,
          isSelected: false,
          onTap: () => setState(() => _currentFolder = e['path'] as String),
        );
      }
      final res = e['resource'] as SelectableResource;
      final asFile = _toResourceFile(res);
      void onTap() => Navigator.pop(context, res);
      if (_isGridView) {
        return ResourceGridCard(
          resource: asFile,
          questId: widget.questId,
          isSelected: false,
          onTap: onTap,
          onLongPress: () => _renameResource(res),
          onRename: () => _renameResource(res),
        );
      }
      return ResourceListTile(
        resource: asFile,
        questId: widget.questId,
        isSelected: false,
        onTap: onTap,
        onLongPress: () => _renameResource(res),
        onRename: () => _renameResource(res),
      );
    }

    final gridItems = entries.map(buildEntry).toList();
    final showTypeChips = widget.allowedTypes.length > 1;
    final inRoot = _currentFolder == '/';
    final title = inRoot ? tr('Выбрать ресурс') : p.basename(_currentFolder);
    final subtitle = inRoot ? _allowedTypesSubtitle() : _currentFolder;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header в стиле resources_screen.
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.surfaceContainerHigh,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          inRoot
                              ? Icons.collections_bookmark_rounded
                              : Icons.folder_rounded,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (subtitle.isNotEmpty)
                              Text(
                                subtitle,
                                style: textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _createNewFolder,
                        tooltip: tr('Новая папка'),
                        icon: const Icon(Icons.create_new_folder_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.surfaceContainerHigh,
                        ),
                      ),
                      if (widget.allowedTypes.contains('audio')) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () async {
                            final res = await Navigator.push<String>(
                              context,
                              MaterialPageRoute(builder: (_) => MusicLibraryScreen(questId: widget.questId, pickerMode: true)),
                            );
                            if (res != null && context.mounted) Navigator.pop(context, SelectableResource(path: res, name: p.basename(res), friendlyName: p.basename(res), type: 'audio', folder: '/'));
                          },
                          tooltip: tr('Библиотека музыки'),
                          icon: const Icon(Icons.library_music_rounded),
                          style: IconButton.styleFrom(backgroundColor: scheme.tertiaryContainer, foregroundColor: scheme.onTertiaryContainer),
                        ),
                      ],
                      // Generic asset market for images/fonts/sfx
                      if (widget.allowedTypes.any((t) => ['image', 'font', 'audio'].contains(t))) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () async {
                            String? kind;
                            if (widget.allowedTypes.contains('font')) kind = 'font';
                            else if (widget.allowedTypes.contains('image')) kind = 'background';
                            else if (widget.allowedTypes.contains('audio')) kind = 'sfx';
                            final res = await Navigator.push<String>(
                              context,
                              MaterialPageRoute(builder: (_) => AssetMarketScreen(questId: widget.questId, initialKind: kind, pickerMode: true)),
                            );
                            if (res != null && context.mounted) {
                              final type = res.contains('font') ? 'font' : res.contains('audio') ? 'audio' : 'image';
                              Navigator.pop(context, SelectableResource(path: res, name: p.basename(res), friendlyName: p.basename(res), type: type, folder: '/'));
                            }
                          },
                          tooltip: tr('Маркет ассетов'),
                          icon: const Icon(Icons.store_rounded),
                          style: IconButton.styleFrom(backgroundColor: scheme.secondaryContainer, foregroundColor: scheme.onSecondaryContainer),
                        ),
                      ],
                      // Personal library (cart) — like market but personal
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () async {
                          String? kind;
                          if (widget.allowedTypes.contains('font')) kind = 'font';
                          else if (widget.allowedTypes.contains('image')) kind = 'background';
                          else if (widget.allowedTypes.contains('audio')) kind = 'sfx';
                          else if (widget.allowedTypes.contains('video')) kind = 'video';
                          final res = await Navigator.push<String>(
                            context,
                            MaterialPageRoute(builder: (_) => MyLibraryScreen(questId: widget.questId, initialKind: kind, pickerMode: true)),
                          );
                          if (res != null && context.mounted) {
                            final type = res.contains('font') ? 'font' : res.contains('audio') ? 'audio' : res.contains('video') ? 'video' : 'image';
                            Navigator.pop(context, SelectableResource(path: res, name: p.basename(res), friendlyName: p.basename(res), type: type, folder: '/'));
                          }
                        },
                        tooltip: tr('Моя библиотека'),
                        icon: const Icon(Icons.bookmarks_rounded),
                        style: IconButton.styleFrom(backgroundColor: scheme.primaryContainer, foregroundColor: scheme.onPrimaryContainer),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: false, label: Text(tr('Квест')), icon: Icon(Icons.folder_rounded, size: 18)),
                      ButtonSegment(value: true, label: Text(tr('Библиотека')), icon: Icon(Icons.bookmarks_rounded, size: 18)),
                    ],
                    selected: {_showLibrary},
                    onSelectionChanged: (s) {
                      final v = s.first;
                      setState(() => _showLibrary = v);
                      if (v) _loadLibrary();
                    },
                  ),
                ),
                const SizedBox(height: 8),
                // Поиск + переключатель вида.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: tr('Поиск...'),
                              prefixIcon: const Icon(Icons.search_rounded),
                              filled: true,
                              fillColor: scheme.surfaceContainerHigh,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 0,
                              ),
                            ),
                            onChanged: (v) => setState(() => _searchQuery = v),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _toggleViewMode,
                        icon: Icon(
                          _isGridView
                              ? Icons.grid_view_rounded
                              : Icons.view_list_rounded,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.surfaceContainerHigh,
                          minimumSize: const Size(48, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                if (showTypeChips)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ResourceFilterChip(
                            label: tr('Все'),
                            icon: Icons.apps_rounded,
                            isSelected: _selectedType == 'all',
                            onTap: () => setState(() => _selectedType = 'all'),
                          ),
                          if (widget.allowedTypes.contains('image'))
                            ResourceFilterChip(
                              label: tr('Картинки'),
                              icon: Icons.image_rounded,
                              isSelected: _selectedType == 'image',
                              onTap: () =>
                                  setState(() => _selectedType = 'image'),
                            ),
                          if (widget.allowedTypes.contains('audio'))
                            ResourceFilterChip(
                              label: tr('Звуки'),
                              icon: Icons.audiotrack_rounded,
                              isSelected: _selectedType == 'audio',
                              onTap: () =>
                                  setState(() => _selectedType = 'audio'),
                            ),
                          if (widget.allowedTypes.contains('video'))
                            ResourceFilterChip(
                              label: tr('Видео'),
                              icon: Icons.videocam_rounded,
                              isSelected: _selectedType == 'video',
                              onTap: () =>
                                  setState(() => _selectedType = 'video'),
                            ),
                          if (widget.allowedTypes.contains('font'))
                            ResourceFilterChip(
                              label: tr('Шрифты'),
                              icon: Icons.text_fields_rounded,
                              isSelected: _selectedType == 'font',
                              onTap: () =>
                                  setState(() => _selectedType = 'font'),
                            ),
                          if (widget.allowedTypes.contains('script'))
                            ResourceFilterChip(
                              label: tr('Скрипты'),
                              icon: Icons.code_rounded,
                              isSelected: _selectedType == 'script',
                              onTap: () =>
                                  setState(() => _selectedType = 'script'),
                            ),
                          if (widget.allowedTypes.contains('lua'))
                            ResourceFilterChip(
                              label: 'Lua',
                              icon: Icons.data_object_rounded,
                              isSelected: _selectedType == 'lua',
                              onTap: () =>
                                  setState(() => _selectedType = 'lua'),
                            ),
                        ],
                      ),
                    ),
                  ),

                Expanded(
                  child: _showLibrary
                      ? _buildLibraryView()
                      : _isLoading
                          ? const Center(child: CircularProgressIndicator())
                          : gridItems.isEmpty
                              ? _buildEmptyState()
                              : _isGridView
                                  ? GridView.builder(
                                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                                      gridDelegate:
                                          const SliverGridDelegateWithMaxCrossAxisExtent(
                                            maxCrossAxisExtent: 210,
                                            crossAxisSpacing: 12,
                                            mainAxisSpacing: 12,
                                            childAspectRatio: 0.82,
                                          ),
                                      itemCount: gridItems.length,
                                      itemBuilder: (ctx, i) => gridItems[i],
                                    )
                                  : ListView.separated(
                                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                                      itemCount: gridItems.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (ctx, i) => gridItems[i],
                                    ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(heroTag: null, 
        onPressed: _addNewResource,
        icon: const Icon(Icons.add_rounded),
        label: Text(tr('Загрузить')),
      ),
    );
  }

  String _allowedTypesSubtitle() {
    // Не const: подписи типов строятся под текущий язык.
    final names = {
      'image': tr('картинки'),
      'audio': tr('аудио'),
      'video': tr('видео'),
      'font': tr('шрифты'),
      'script': tr('скрипты'),
      'lua': 'lua',
    };
    final parts = widget.allowedTypes.map((t) => names[t] ?? t).toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) {
      return trf('Выберите {p0}', {'p0': parts.first});
    }
    return trf('Выберите {p0}', {'p0': parts.join(' · ')});
  }

  Widget _buildEmptyState() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isSearching = _searchQuery.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isSearching
                    ? Icons.search_off_rounded
                    : Icons.folder_open_rounded,
                size: 44,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isSearching ? tr('Ничего не найдено') : tr('Здесь пока пусто'),
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isSearching
                  ? tr('Попробуйте изменить запрос или фильтр')
                  : tr('Добавьте файлы кнопкой «Загрузить»'),
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Библиотечный kind → тип пикера ресурсов.
  static String _mapKind(String k) {
    if (k == 'background' || k == 'image') return 'image';
    if (k == 'sfx') return 'audio';
    return k;
  }

  /// Ассет из библиотеки → файл в текущем квесте. `copyAssetToQuest`
  /// возвращает null, когда файла нет на диске и скачивание не удалось:
  /// раньше тап по карточке молча ничего не делал, и это выглядело как
  /// сломанная кнопка, а не как отсутствующий ассет.
  Future<void> _useLibraryItem(LibraryItem item) async {
    String? dest;
    try {
      dest = await MyLibraryService.copyAssetToQuest(item, widget.questId);
    } catch (e) {
      debugPrint('[Resources] copyAssetToQuest error: $e');
    }
    if (!mounted) return;
    if (dest == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(trf('«{p0}» не добавился: файл недоступен', {'p0': item.title}),
              style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
      return;
    }
    Navigator.pop(
      context,
      SelectableResource(
        path: dest,
        name: p.basename(dest),
        friendlyName: item.title,
        type: _mapKind(item.kind),
        folder: '/',
      ),
    );
  }

  Widget _buildLibraryView() {
    if (_libraryLoading) return const Center(child: CircularProgressIndicator());
    // Filter by search and type
    final query = _searchQuery.trim().toLowerCase();
    final effectiveType = _selectedType == 'all' ? null : _selectedType;
    final filtered = _libraryItems.where((item) {
      if (effectiveType != null && _mapKind(item.kind) != effectiveType) return false;
      if (query.isNotEmpty) {
        final title = item.title.toLowerCase();
        if (!title.contains(query)) return false;
      }
      return true;
    }).toList();

    if (filtered.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 96, height: 96, decoration: BoxDecoration(color: scheme.surfaceContainerHigh, shape: BoxShape.circle), child: Icon(Icons.bookmarks_outlined, size: 44, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Text(tr('Библиотека пуста'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(tr('Добавляйте ассеты из хаба кнопкой "В библиотеку"'), style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
          ]),
        ),
      );
    }

    final viewType = _isGridView ? ViewType.grid : ViewType.list;
    return _isGridView
        ? GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 210, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.82),
            itemCount: filtered.length,
            itemBuilder: (ctx, i) {
              final item = filtered[i];
              return _LibraryGridCard(
                item: item,
                viewType: viewType,
                onTap: () => _useLibraryItem(item),
              );
            },
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) {
              final item = filtered[i];
              return _LibraryListTile(
                item: item,
                onTap: () => _useLibraryItem(item),
              );
            },
          );
  }
}

class _LibraryGridCard extends StatelessWidget {
  final LibraryItem item;
  final ViewType viewType;
  final VoidCallback onTap;
  const _LibraryGridCard({required this.item, required this.viewType, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    IconData icon;
    switch (item.kind) {
      case 'background': icon = Icons.wallpaper_rounded; break;
      case 'sfx': icon = Icons.music_note_rounded; break;
      case 'font': icon = Icons.text_fields_rounded; break;
      case 'button_preset': icon = Icons.smart_button_rounded; break;
      default: icon = Icons.image_rounded;
    }
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: item.coverUrl != null
                ? Image.network(item.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: scheme.secondaryContainer, child: Center(child: Icon(icon, size: 28))))
                : Container(color: scheme.secondaryContainer, child: Center(child: Icon(icon, size: 28, color: scheme.onSecondaryContainer))),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              Text(item.kind, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.bookmarks_rounded, size: 12, color: scheme.primary),
                const SizedBox(width: 4),
                Expanded(child: Text(tr('Из библиотеки'), style: TextStyle(fontSize: 10, color: scheme.primary, fontWeight: FontWeight.w600))),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _LibraryListTile extends StatelessWidget {
  final LibraryItem item;
  final VoidCallback onTap;
  const _LibraryListTile({required this.item, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    IconData icon;
    switch (item.kind) {
      case 'background': icon = Icons.wallpaper_rounded; break;
      case 'sfx': icon = Icons.music_note_rounded; break;
      case 'font': icon = Icons.text_fields_rounded; break;
      case 'button_preset': icon = Icons.smart_button_rounded; break;
      default: icon = Icons.image_rounded;
    }
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: Container(
          width: 48, height: 48,
          decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
          child: item.coverUrl != null
              ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(item.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(icon, size: 20)))
              : Icon(icon, size: 20, color: scheme.onSecondaryContainer),
        ),
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        subtitle: Text(item.kind, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        trailing: const Icon(Icons.add_rounded, size: 18),
        onTap: onTap,
      ),
    );
  }
}
