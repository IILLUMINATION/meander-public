import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/services/device_export_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/resources/models/resource_file.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:canvas_app/features/asset_market/screens/asset_market_screen.dart';
import 'package:canvas_app/features/resources/widgets/resource_cards.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/screens/folder_picker_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:photo_view/photo_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

class ResourcesScreen extends ConsumerStatefulWidget {
  final String questId;

  /// Начальный текст поиска — приходит из глобального поиска квеста.
  final String initialSearch;

  const ResourcesScreen({
    super.key,
    required this.questId,
    this.initialSearch = '',
  });
  @override
  ConsumerState<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends ConsumerState<ResourcesScreen> {
  final TextEditingController _searchController = TextEditingController();
  late final ScrollController _scrollController;

  String _searchQuery = '';
  String _selectedType = 'all';

  // Навигация по папкам
  String _currentFolder = '/';
  List<String> _explicitFolders = [];
  List<ResourceFile> _resources = [];
  bool _isLoading = true;
  bool _isGridView = true;

  /// Сжимать ввозимые PNG в WebP (#148). Выключается в меню «Добавить» —
  /// например когда автору нужен именно исходный PNG для дальнейшей обработки.
  bool _convertImagesOnImport = true;

  // Мультивыделение
  bool _isSelectionMode = false;
  final Set<String> _selectedItems = {};

  ResourceService get _svc => ref.read(resourceServiceProvider(widget.questId));

  String _normalizeFolderPath(String path) =>
      ResourceService.normalizeFolderPath(path);

  bool _isSameOrDescendantFolder(String parent, String candidate) =>
      ResourceService.isSameOrDescendantFolder(parent, candidate);

  @override
  void initState() {
    super.initState();
    // Папка переживает пересоздание экрана: воркспейс может заменить вкладку
    // библиотеки скриптом (авто-вкладки выключены) и открыть её заново при
    // возврате.
    _currentFolder = ref.read(resourcesFolderProvider(widget.questId));
    _scrollController = ScrollController(
      initialScrollOffset: ref.read(
        resourcesScrollOffsetProvider(widget.questId),
      ),
    )..addListener(_rememberScrollPosition);
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
    if (widget.initialSearch.isNotEmpty) {
      _searchController.text = widget.initialSearch;
      _searchQuery = widget.initialSearch;
    }
    _loadPreferences();
    _loadResources();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _rememberScrollPosition() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    if (offset < 0) return;
    ref.read(resourcesScrollOffsetProvider(widget.questId).notifier).state =
        offset;
  }

  // --- PREFERENCES ---
  Future<void> _loadPreferences() async {
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
    setState(() {
      _isGridView = !_isGridView;
    });
    await prefs.setBool('resources_grid_view', _isGridView);
  }

  // --- ЗАГРУЗКА ---

  Future<void> _loadResources({bool refreshOnly = false}) async {
    final svc = ref.read(resourceServiceProvider(widget.questId));
    if (!refreshOnly) {
      final cached = svc.lastLoaded;
      if (cached != null) {
        // Снимок прошлого открытия рисуем сразу, без спиннера: возврат из
        // скрипта пересоздаёт экран, а данные уже в памяти. Диск читается
        // фоном — если что-то поменялось, список обновится.
        _applyData(cached);
      } else {
        setState(() => _isLoading = true);
      }
    }

    try {
      final data = await svc.loadResources();
      if (mounted) setState(() => _applyData(data));
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _applyData(ResourcesData data) {
    _explicitFolders = data.explicitFolders;
    _resources = data.resources;
    _isLoading = false;
    // Папку могли удалить/переименовать, пока экран был закрыт.
    if (_currentFolder != '/' &&
        !_allFolders.contains(_normalizeFolderPath(_currentFolder))) {
      _currentFolder = '/';
      ref.read(resourcesFolderProvider(widget.questId).notifier).state = '/';
    }
    _selectedItems.removeWhere((id) {
      final isFile = data.resources.any((r) => r.id == id);
      if (isFile) return false;
      if (id.startsWith('/')) {
        return !_allFolders.contains(id);
      }
      return true;
    });
    if (_selectedItems.isEmpty) _isSelectionMode = false;
  }

  // --- ЛОГИКА ПАПОК ---

  List<String> get _allFolders {
    final folders = _explicitFolders.map(_normalizeFolderPath).toSet();
    for (var res in _resources) {
      final folder = _normalizeFolderPath(res.folder);
      if (folder != '/') folders.add(folder);
    }
    return folders.toList()..sort();
  }

  void _changeFolder(String newPath) {
    setState(() => _currentFolder = newPath);
    ref.read(resourcesFolderProvider(widget.questId).notifier).state =
        _currentFolder;
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  void _goUpOneLevel() {
    final parts = _currentFolder.split('/');
    if (parts.length <= 2) {
      _changeFolder('/');
    } else {
      parts.removeLast();
      _changeFolder(parts.join('/'));
    }
    _exitSelectionMode();
  }

  void _handleBackPress() {
    if (_isSelectionMode) {
      _exitSelectionMode();
      return;
    }
    if (_currentFolder == '/') {
      // Внутри воркспейса — браузерная история (вкладка остаётся открытой),
      // в отдельном маршруте — закрытие экрана.
      final document = EditorDocumentContext.maybeOf(context);
      final workspace = EditorWorkspaceScope.maybeOf(context);
      if (document != null && workspace != null) {
        unawaited(workspace.requestBack());
      } else {
        _closeDocument();
      }
    } else {
      _goUpOneLevel();
    }
  }

  Future<void> _closeDocument() async {
    if (!mounted) return;
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);
    if (document != null && workspace != null) {
      await workspace.closeDocument(document.id);
    } else {
      Navigator.pop(context);
    }
  }

  List<String> get _subFolders {
    final sub = <String>{};
    for (var f in _allFolders) {
      final folderPath = _normalizeFolderPath(f);
      if (_isSameOrDescendantFolder(_currentFolder, folderPath) &&
          folderPath != _normalizeFolderPath(_currentFolder)) {
        String relative = folderPath.substring(
          _normalizeFolderPath(_currentFolder).length,
        );
        if (relative.startsWith('/')) relative = relative.substring(1);
        final parts = relative.split('/');
        if (parts.isNotEmpty && parts[0].isNotEmpty) {
          sub.add(parts[0]);
        }
      }
    }
    return sub.toList()..sort();
  }

  /// Считает прямые дочерние элементы папки (файлы + непосредственные подпапки).
  int _countFolderItems(String folderPath) {
    final normalized = _normalizeFolderPath(folderPath);

    final fileCount = _resources
        .where((r) => _normalizeFolderPath(r.folder) == normalized)
        .length;

    final directSubFolders = <String>{};
    for (final f in _allFolders) {
      final folder = _normalizeFolderPath(f);
      if (folder == normalized) continue;
      if (folder.startsWith('$normalized/')) {
        var relative = folder.substring(normalized.length);
        if (relative.startsWith('/')) relative = relative.substring(1);
        final firstSegment = relative.split('/').first;
        if (firstSegment.isNotEmpty) directSubFolders.add(firstSegment);
      }
    }

    return fileCount + directSubFolders.length;
  }

  /// Собирает до 4 ресурсов внутри папки (включая вложенные) для превью-коллажа.
  /// Картинки идут первыми, затем прочие типы.
  List<ResourceFile> _folderPreviewResources(String folderPath) {
    final normalized = _normalizeFolderPath(folderPath);
    final inside =
        _resources.where((r) {
          final f = _normalizeFolderPath(r.folder);
          return f == normalized || f.startsWith('$normalized/');
        }).toList()..sort((a, b) {
          // Картинки — в начало.
          final aImg = a.type == 'image' ? 0 : 1;
          final bImg = b.type == 'image' ? 0 : 1;
          if (aImg != bImg) return aImg - bImg;
          return a.friendlyName.toLowerCase().compareTo(
            b.friendlyName.toLowerCase(),
          );
        });
    return inside.take(4).toList();
  }

  Future<void> _createNewFolder() async {
    final name = await _showNameDialog('', title: tr('Новая папка'));
    if (name == null || name.isEmpty || name.contains('/')) {
      if (name != null && name.contains('/'))
        _showError(tr("Имя не может содержать '/'"));
      return;
    }

    String newPath = _currentFolder == '/' ? '/$name' : '$_currentFolder/$name';
    newPath = _normalizeFolderPath(newPath);

    try {
      await _svc.createFolder(newPath);
      await _loadResources(refreshOnly: true);
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  Future<void> _deleteFolder(String folderName) async {
    String folderPath = _currentFolder == '/'
        ? '/$folderName'
        : '$_currentFolder/$folderName';

    if (!folderName.startsWith('/')) {
      // это имя
    } else {
      folderPath = folderName;
    }
    folderPath = _normalizeFolderPath(folderPath);

    final filesInFolder = _resources
        .where(
          (r) =>
              _normalizeFolderPath(r.folder) == folderPath ||
              _normalizeFolderPath(r.folder).startsWith('$folderPath/'),
        )
        .toList();

    bool deleteFiles = false;

    if (filesInFolder.isNotEmpty) {
      final action = await showAppDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Удаление папки')),
          content: Text(
            trf('Папка содержит {p0} файлов.\nЧто с ними сделать?', {'p0': filesInFolder.length}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: Text(tr('Отмена')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'move'),
              child: Text(tr('В корень')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: Text(tr('Удалить всё')),
            ),
          ],
        ),
      );

      if (action == 'cancel' || action == null) return;
      if (action == 'delete') deleteFiles = true;
    } else {
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Удалить пустую папку?')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Нет')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: Text(tr('Да')),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    try {
      await _svc.deleteFolder(
        folderPath,
        filesInFolder,
        deleteFiles: deleteFiles,
      );
      await _loadResources(refreshOnly: true);
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  Future<void> _renameFolder(String folderName) async {
    final fullOldPath = _normalizeFolderPath(
      _currentFolder == '/' ? '/$folderName' : '$_currentFolder/$folderName',
    );
    final newName = await _showNameDialog(
      folderName,
      title: tr('Переименовать папку'),
    );
    if (newName == null || newName.isEmpty || newName.contains('/')) return;
    final fullNewPath = _normalizeFolderPath(
      _currentFolder == '/' ? '/$newName' : '$_currentFolder/$newName',
    );

    try {
      await _svc.renameFolder(fullOldPath, fullNewPath);
      await _loadResources(refreshOnly: true);
      _showSuccess(tr("Папка переименована"));
    } catch (e) {
      _showError(trf('Ошибка: {p0}', {'p0': friendlyError(e)}));
    }
  }

  // --- МУЛЬТИВЫДЕЛЕНИЕ ---

  void _toggleSelection(String idOrPath) {
    setState(() {
      if (_selectedItems.contains(idOrPath)) {
        _selectedItems.remove(idOrPath);
        if (_selectedItems.isEmpty) _isSelectionMode = false;
      } else {
        _selectedItems.add(idOrPath);
        _isSelectionMode = true;
      }
    });
  }

  void _enterSelectionMode(String idOrPath) {
    setState(() {
      _isSelectionMode = true;
      _selectedItems.add(idOrPath);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedItems.clear();
    });
  }

  void _selectAll() {
    final visibleFiles = _resources
        .where(
          (r) =>
              r.folder == _currentFolder &&
              (_selectedType == 'all' || r.type == _selectedType),
        )
        .map((e) => e.id)
        .toList();

    final visibleFolders = _subFolders
        .map((f) => _currentFolder == '/' ? '/$f' : '$_currentFolder/$f')
        .toList();

    setState(() {
      _selectedItems.addAll(visibleFiles);
      _selectedItems.addAll(visibleFolders);
      _isSelectionMode = true;
    });
  }

  // --- ДЕЙСТВИЯ ---

  Future<void> _deleteSelected() async {
    final count = _selectedItems.length;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(trf('Удалить {count} объект(ов)?', {'count': count})),
        content: Text(tr('Папки будут удалены вместе с содержимым.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _svc.deleteItems(_selectedItems, _resources);
        _exitSelectionMode();
        await _loadResources(refreshOnly: true);
        _showSuccess(tr("Удалено"));
      } catch (e) {
        _showError(friendlyError(e));
      }
    }
  }

  Future<void> _moveSelected() async {
    final selectedFolder = _selectedItems.firstWhere(
      (e) => e.startsWith('/'),
      orElse: () => '',
    );

    final targetFolder = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => FolderPickerScreen(
          questId: widget.questId,
          excludePath: selectedFolder.isEmpty ? null : selectedFolder,
        ),
      ),
    );

    if (targetFolder != null) {
      try {
        await _svc.moveItems(_selectedItems, _resources, targetFolder);
        _exitSelectionMode();
        await _loadResources(refreshOnly: true);
        _showSuccess(tr("Перемещено"));
      } catch (e) {
        _showError(friendlyError(e));
      }
    }
  }

  List<ResourceFile> _collectSelectedScriptResources() {
    final scripts = <ResourceFile>{};
    for (final item in _selectedItems) {
      if (item.startsWith('/')) {
        scripts.addAll(
          _resources.where(
            (r) =>
                r.type == 'script' &&
                (r.folder == item || r.folder.startsWith('$item/')),
          ),
        );
        continue;
      }

      final res = _resources.firstWhere(
        (r) => r.id == item,
        orElse: () => ResourceFile.empty,
      );
      if (res.id.isNotEmpty && res.type == 'script') {
        scripts.add(res);
      }
    }
    return scripts.toList();
  }

  String _shortQuestId(String questId) {
    if (questId.length <= 20) return questId;
    return '${questId.substring(0, 8)}...${questId.substring(questId.length - 6)}';
  }

  Future<String?> _pickTargetQuestId() async {
    final quests = await _svc.listOtherQuests();
    if (!mounted) return null;

    if (quests.isEmpty) {
      _showError(tr('Других квестов не найдено'));
      return null;
    }

    return showAdaptiveSheet<String>(
      context: context,
      scrollable: true,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        final textTheme = Theme.of(ctx).textTheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('Куда копировать скрипты'),
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  tr('Выберите квест-получатель'),
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: quests.length,
                  itemBuilder: (context, index) {
                    final quest = quests[index];
                    return Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      // Цвет и рамка — на Material: ListTile рисует фон/ink
                      // на ближайшем Material-предке, цветная декорация
                      // контейнера их прячет.
                      child: Material(
                        color: scheme.surfaceContainerHigh,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: scheme.outlineVariant),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: Icon(
                            Icons.folder_copy_rounded,
                            color: scheme.primary,
                          ),
                          title: Text(
                            quest.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'ID: ${_shortQuestId(quest.id)}',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => Navigator.pop(ctx, quest.id),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copySelectedScripts() async {
    final scripts = _collectSelectedScriptResources();
    if (scripts.isEmpty) {
      _showError(tr('Выберите хотя бы один скрипт'));
      return;
    }

    final mode = await showAdaptiveSheet<String>(
      context: context,
      scrollable: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: Text(tr('Копировать в этот квест')),
              onTap: () => Navigator.pop(ctx, 'same'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(tr('Копировать в другой квест')),
              onTap: () => Navigator.pop(ctx, 'other'),
            ),
          ],
        ),
      ),
    );

    if (mode == null) return;

    String targetQuestId = widget.questId;
    if (mode == 'other') {
      final selected = await _pickTargetQuestId();
      if (selected == null || selected.isEmpty) return;
      targetQuestId = selected;
    }

    final result = await _svc.copyScripts(scripts, targetQuestId);
    final copied = result.copied;
    final failed = result.failed;

    _exitSelectionMode();
    if (targetQuestId == widget.questId) {
      await _loadResources(refreshOnly: true);
    }

    if (copied > 0 && failed == 0) {
      _showSuccess(trf('Скопировано скриптов: {p0}', {'p0': copied}));
    } else if (copied > 0) {
      _showSuccess(
        trf('Скопировано: {p0}, с ошибками: {p1}', {
          'p0': copied,
          'p1': failed,
        }),
      );
    } else {
      _showError(tr('Не удалось скопировать выбранные скрипты'));
    }
  }

  // --- ADD RESOURCES ---

  Future<void> _addImageResource() async {
    final picker = ImagePicker();
    final List<XFile> images = await picker.pickMultiImage();
    if (images.isEmpty) return;

    try {
      final created = await _svc.importFiles(
        images
            .map((img) => (sourcePath: img.path, displayName: img.name))
            .toList(),
        'image',
        _currentFolder,
        convertImages: _convertImagesOnImport,
      );
      await _loadResources(refreshOnly: true);
      _showSuccess(trf('Добавлено {p0} фото', {'p0': created.length}));
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  Future<void> _addAudioResource() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'ogg', 'm4a'],
    );
    if (files.isEmpty) return;

    try {
      final created = await _svc.importFiles(
        files
            .where((f) => f.path != null)
            .map((f) => (sourcePath: f.path!, displayName: f.name))
            .toList(),
        'audio',
        _currentFolder,
      );
      await _loadResources(refreshOnly: true);
      _showSuccess(trf('Добавлено {p0} аудио', {'p0': created.length}));
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  Future<void> _addVideoResource() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v'],
      allowMultiple: true,
    );
    if (files.isEmpty) return;

    try {
      final created = await _svc.importFiles(
        files
            .where((f) => f.path != null)
            .map((f) => (sourcePath: f.path!, displayName: f.name))
            .toList(),
        'video',
        _currentFolder,
      );
      await _loadResources(refreshOnly: true);
      _showSuccess(trf('Добавлено {p0} видео', {'p0': created.length}));
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  Future<void> _addFontResource() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf'],
    );
    if (files.isEmpty) return;

    try {
      final created = await _svc.importFiles(
        files
            .where((f) => f.path != null)
            .map((f) => (sourcePath: f.path!, displayName: f.name))
            .toList(),
        'font',
        _currentFolder,
      );
      await _loadResources(refreshOnly: true);
      _showSuccess(trf('Добавлено {p0} шрифтов', {'p0': created.length}));
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  /// Мгновенное создание скрипта (Adobe-стиль): без диалогов — авто-имя,
  /// папка = текущая, и сразу в редактор. Переименование — внутри редактора.
  Future<void> _createNewScript() async {
    try {
      final created = await _svc.createScript(folder: _currentFolder);
      await _loadResources(refreshOnly: true);

      if (mounted) {
        await EditorDocumentLauncher.openVisualScript(
          context,
          widget.questId,
          created.id,
          title: created.name,
        );
        await _loadResources(refreshOnly: true);
      }
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  /// Мгновенное создание .lua (Adobe-стиль): авто-имя и сразу редактор.
  Future<void> _createNewLua() async {
    try {
      final created = await _svc.createLuaScript(folder: _currentFolder);
      await _loadResources(refreshOnly: true);

      if (mounted) {
        await EditorDocumentLauncher.openLua(
          context,
          widget.questId,
          created.fileName,
          title: created.name,
          stableId: created.stableId,
        );
        await _loadResources(refreshOnly: true);
      }
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  Future<void> _renameResource(ResourceFile resource) async {
    final newName = await _showNameDialog(
      resource.friendlyName,
      title: tr('Переименовать'),
    );
    if (newName != null && newName.isNotEmpty) {
      await _svc.renameResource(resource, newName);
      await _loadResources(refreshOnly: true);
    }
  }

  Future<void> _replaceResource(ResourceFile resource) async {
    List<String> allowedExtensions = [];
    String dialogTitle = tr('Выберите файл');

    if (resource.type == 'image') {
      allowedExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
      dialogTitle = tr('Выберите изображение');
    } else if (resource.type == 'audio') {
      allowedExtensions = ['mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac'];
      dialogTitle = tr('Выберите аудио');
    } else if (resource.type == 'video') {
      allowedExtensions = ['mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v'];
      dialogTitle = tr('Выберите видео');
    } else if (resource.type == 'font') {
      allowedExtensions = ['ttf', 'otf', 'woff', 'woff2'];
      dialogTitle = tr('Выберите шрифт');
    }

    final files = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      allowedExtensions: allowedExtensions.isNotEmpty
          ? allowedExtensions
          : null,
      type: allowedExtensions.isNotEmpty ? FileType.custom : FileType.any,
    );

    if (files.isEmpty) return;

    final sourcePath = files.single.path;
    if (sourcePath == null) return;

    try {
      await _svc.replaceResourceFile(resource, sourcePath);

      imageCache.clear();
      imageCache.clearLiveImages();

      await _loadResources(refreshOnly: true);

      if (!mounted) return;
      _showSuccess(
        trf('Файл "{p0}" заменён', {'p0': resource.friendlyName}),
      );
    } catch (e) {
      if (!mounted) return;
      _showError(
        trf('Ошибка замены файла: {p0}', {'p0': friendlyError(e)}),
      );
    }
  }

  Future<void> _deleteResource(ResourceFile resource) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить ресурс?')),
        content: Text(trf('"{p0}" будет удалён безвозвратно.', {'p0': resource.friendlyName})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _svc.deleteResource(resource);
      await _loadResources(refreshOnly: true);
      _showSuccess(tr('Удалено'));
    } catch (e) {
      _showError(friendlyError(e));
    }
  }

  // --- ЭКСПОРТ НА УСТРОЙСТВО (#149) ---

  /// Выбранные файлы: папки разворачиваем рекурсивно, дубли убираем по пути.
  List<ResourceFile> _selectedFilesForExport() {
    final byPath = <String, ResourceFile>{};
    for (final item in _selectedItems) {
      if (item.startsWith('/')) {
        for (final r in _resources.where(
          (r) => r.folder == item || r.folder.startsWith('$item/'),
        )) {
          byPath[r.path] = r;
        }
        continue;
      }
      final res = _resources.firstWhere(
        (r) => r.id == item,
        orElse: () => ResourceFile.empty,
      );
      if (res.id.isNotEmpty) byPath[res.path] = res;
    }
    return byPath.values.toList();
  }

  Future<void> _exportResource(ResourceFile resource) async {
    try {
      final saved = await DeviceExportService.exportOne(
        DeviceExportItem(
          fileName: resource.name,
          sourcePath: await _svc.absolutePath(resource.path),
        ),
      );
      if (!mounted || !saved) return;
      _showSuccess(trf('Сохранено: {p0}', {'p0': resource.friendlyName}));
    } catch (e) {
      _showError(
        trf('Не удалось сохранить файл: {p0}', {'p0': friendlyError(e)}),
      );
    }
  }

  Future<void> _exportSelected() async {
    final files = _selectedFilesForExport();
    if (files.isEmpty) {
      _showError(tr('Нечего сохранять'));
      return;
    }
    if (files.length == 1) {
      await _exportResource(files.first);
      return;
    }
    try {
      final items = <DeviceExportItem>[];
      for (final f in files) {
        items.add(
          DeviceExportItem(
            fileName: DeviceExportService.archiveName(
              folder: f.folder,
              fileName: f.name,
            ),
            sourcePath: await _svc.absolutePath(f.path),
          ),
        );
      }
      final saved = await DeviceExportService.exportZip(
        items,
        zipName: 'resources_${widget.questId.substring(0, 8)}.zip',
      );
      if (!mounted || !saved) return;
      _showSuccess(trf('Сохранено файлов: {p0}', {'p0': items.length}));
    } catch (e) {
      _showError(trf('Не удалось сохранить: {p0}', {'p0': friendlyError(e)}));
    }
  }

  // --- UI HELPERS ---

  Future<String?> _showNameDialog(String initial, {required String title}) {
    final c = TextEditingController(text: initial);
    return showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            filled: true,
            border: OutlineInputBorder(),
          ),
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
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(color: scheme.onErrorContainer)),
        backgroundColor: scheme.errorContainer,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(color: scheme.onPrimaryContainer)),
        backgroundColor: scheme.primaryContainer,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _openFullScreenImage(ResourceFile res) async {
    final path = await _svc.absolutePath(res.path);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.transparent),
          body: PhotoView(imageProvider: FileImage(File(path))),
        ),
      ),
    );
  }

  // --- UI BUILD ---

  @override
  Widget build(BuildContext context) {
    final gridItems = _buildItems();
    final scheme = Theme.of(context).colorScheme;

    // ВАЖНО: без EditorDocumentBackScope. Регистрация handler'а здесь
    // создавала рекурсию «Назад»: терминальный путь шелла вызвал бы
    // handler → _handleBackPress → в корне папки → scope.requestBack →
    // снова терминальный путь. Закрытие вкладки выполняет сам шелл
    // дефолтным путём; стрелка AppBar (строка ниже) идёт через
    // requestBack и учитывает стек.

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: tr('Поиск файлов...'),
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
                        ResourceFilterChip(
                          label: tr('Картинки'),
                          icon: Icons.image_rounded,
                          isSelected: _selectedType == 'image',
                          onTap: () => setState(() => _selectedType = 'image'),
                        ),
                        ResourceFilterChip(
                          label: tr('Звуки'),
                          icon: Icons.audiotrack_rounded,
                          isSelected: _selectedType == 'audio',
                          onTap: () => setState(() => _selectedType = 'audio'),
                        ),
                        ResourceFilterChip(
                          label: tr('Шрифты'),
                          icon: Icons.text_fields_rounded,
                          isSelected: _selectedType == 'font',
                          onTap: () => setState(() => _selectedType = 'font'),
                        ),
                        ResourceFilterChip(
                          label: tr('Скрипты'),
                          icon: Icons.code_rounded,
                          isSelected: _selectedType == 'script',
                          onTap: () => setState(() => _selectedType = 'script'),
                        ),
                        ResourceFilterChip(
                          label: 'Lua',
                          icon: Icons.data_object_rounded,
                          isSelected: _selectedType == 'lua',
                          onTap: () => setState(() => _selectedType = 'lua'),
                        ),
                      ],
                    ),
                  ),
                ),

                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : gridItems.isEmpty
                      ? _buildEmptyState()
                      : _isGridView
                      ? GridView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
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
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
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
      bottomNavigationBar: _isSelectionMode ? _buildSelectionBar() : null,
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton.extended(
              heroTag: null,
              onPressed: _showAddMenu,
              icon: const Icon(Icons.add_rounded),
              label: Text(tr('Добавить')),
            ),
    );
  }

  Widget _buildHeader() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final inRoot = _currentFolder == '/';
    final folderName = inRoot ? tr('Ресурсы') : p.basename(_currentFolder);
    final subtitle = inRoot
        ? tr('Картинки, звуки, шрифты, скрипты и Lua')
        : _currentFolder;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _handleBackPress,
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
              color: inRoot
                  ? scheme.primaryContainer
                  : const Color(0xFFFFB300).withOpacity(0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              inRoot ? Icons.folder_special_rounded : Icons.folder_rounded,
              color: inRoot
                  ? scheme.onPrimaryContainer
                  : const Color(0xFFFFB300),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  folderName,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
          const SizedBox(width: 8),
          IconButton(
            onPressed: _openMarketPicker,
            tooltip: tr('Маркет ассетов'),
            icon: const Icon(Icons.storefront_rounded),
            style: IconButton.styleFrom(
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// Маркет ассетов наравне с загрузкой своих файлов: выбранное из маркета
  /// скачивается в квест (res/... + metadata) — как при добавлении из пикера.
  Future<void> _openMarketPicker() async {
    final kind = switch (_selectedType) {
      'image' => 'background',
      'font' => 'font',
      'audio' => 'sfx',
      _ => null,
    };
    final importedPath = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => AssetMarketScreen(
          questId: widget.questId,
          initialKind: kind,
          pickerMode: true,
        ),
      ),
    );
    if (!mounted) return;
    await _loadResources();
    if (!mounted) return;
    if (importedPath != null && importedPath.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Добавлено из маркета'))));
    }
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
                  : tr('Добавьте файлы или создайте папку'),
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

  Widget _buildSelectionBar() {
    final scheme = Theme.of(context).colorScheme;
    final hasScripts = _collectSelectedScriptResources().isNotEmpty;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: _exitSelectionMode,
              icon: const Icon(Icons.close_rounded),
            ),
            Text(
              '${_selectedItems.length}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const Spacer(),
            IconButton(
              tooltip: tr('Выбрать всё'),
              onPressed: _selectAll,
              icon: const Icon(Icons.select_all_rounded),
            ),
            if (hasScripts)
              IconButton(
                tooltip: tr('Копировать скрипты'),
                onPressed: _copySelectedScripts,
                icon: const Icon(Icons.copy_rounded),
              ),
            IconButton(
              tooltip: tr('Сохранить на устройство'),
              onPressed: _exportSelected,
              icon: const Icon(Icons.download_rounded),
            ),
            IconButton(
              tooltip: tr('Переместить'),
              onPressed: _moveSelected,
              icon: const Icon(Icons.drive_file_move_outline),
            ),
            IconButton(
              tooltip: tr('Удалить'),
              onPressed: _deleteSelected,
              icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddMenu() {
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheetState) => Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.image_rounded),
                  title: Text(tr('Картинки')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addImageResource();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.audiotrack_rounded),
                  title: Text(tr('Аудио')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addAudioResource();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.videocam_rounded),
                  title: Text(tr('Видео')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addVideoResource();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.text_fields_rounded),
                  title: Text(tr('Шрифты')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addFontResource();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: Text(tr('Новый скрипт')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _createNewScript();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.data_object_rounded),
                  title: Text(tr('Новый .lua')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _createNewLua();
                  },
                ),
                SwitchListTile(
                  value: _convertImagesOnImport,
                  secondary: const Icon(Icons.compress_rounded),
                  title: Text(tr('Сжимать картинки при импорте')),
                  subtitle: Text(
                    tr('PNG пережимается в WebP без потери качества, обычно выходит в два раза меньше. JPEG остаётся как есть; если WebP вышел больше оригинала — тоже'),
                  ),
                  onChanged: (value) async {
                    setSheetState(() => _convertImagesOnImport = value);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('resources_convert_to_webp', value);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildItems() {
    final items = <Widget>[];

    // Кнопка "назад" (вверх) при навигации внутри папок
    if (_currentFolder != '/') {
      items.add(
        FolderCard(
          name: '..',
          isBack: true,
          viewType: _isGridView ? ViewType.grid : ViewType.list,
          isSelected: false,
          onTap: _goUpOneLevel,
        ),
      );
    }

    // Папки текущего уровня
    final query = _searchQuery.toLowerCase();
    for (final folder in _subFolders) {
      if (query.isNotEmpty && !folder.toLowerCase().contains(query)) {
        continue;
      }
      final fullPath = _currentFolder == '/'
          ? '/$folder'
          : '$_currentFolder/$folder';
      final selected = _selectedItems.contains(fullPath);
      items.add(
        FolderCard(
          name: folder,
          viewType: _isGridView ? ViewType.grid : ViewType.list,
          isSelected: selected,
          itemCount: _countFolderItems(fullPath),
          previewResources: _folderPreviewResources(fullPath),
          questId: widget.questId,
          onTap: () {
            if (_isSelectionMode) {
              _toggleSelection(fullPath);
            } else {
              _changeFolder(fullPath);
            }
          },
          onLongPress: () => _enterSelectionMode(fullPath),
          onRename: () => _renameFolder(folder),
          onDelete: () => _deleteFolder(folder),
        ),
      );
    }

    // Файлы текущего уровня
    final files =
        _resources.where((r) {
          if (_normalizeFolderPath(r.folder) !=
              _normalizeFolderPath(_currentFolder)) {
            return false;
          }
          if (_selectedType != 'all' && r.type != _selectedType) return false;
          if (query.isNotEmpty &&
              !r.friendlyName.toLowerCase().contains(query)) {
            return false;
          }
          return true;
        }).toList()..sort(
          (a, b) => a.friendlyName.toLowerCase().compareTo(
            b.friendlyName.toLowerCase(),
          ),
        );

    for (final res in files) {
      items.add(_buildResourceItem(res));
    }

    return items;
  }

  Widget _buildResourceItem(ResourceFile res) {
    final selected = _selectedItems.contains(res.id);

    void onTap() {
      if (_isSelectionMode) {
        _toggleSelection(res.id);
        return;
      }
      if (res.type == 'image') {
        _openFullScreenImage(res);
      } else if (res.type == 'script') {
        EditorDocumentLauncher.openVisualScript(
          context,
          widget.questId,
          res.id.replaceAll('.json', ''),
          title: res.friendlyName,
        );
      } else if (res.type == 'lua') {
        EditorDocumentLauncher.openLua(
          context,
          widget.questId,
          res.name,
          title: res.friendlyName,
          stableId: res.stableId,
        );
      }
    }

    if (_isGridView) {
      return ResourceGridCard(
        resource: res,
        questId: widget.questId,
        isSelected: selected,
        onTap: onTap,
        onLongPress: () => _enterSelectionMode(res.id),
        onRename: () => _renameResource(res),
        onReplace: () => _replaceResource(res),
        onDelete: () => _deleteResource(res),
        onExport: () => _exportResource(res),
      );
    }

    return ResourceListTile(
      resource: res,
      questId: widget.questId,
      isSelected: selected,
      onTap: onTap,
      onLongPress: () => _enterSelectionMode(res.id),
      onRename: () => _renameResource(res),
      onReplace: () => _replaceResource(res),
      onDelete: () => _deleteResource(res),
      onExport: () => _exportResource(res),
    );
  }
}
