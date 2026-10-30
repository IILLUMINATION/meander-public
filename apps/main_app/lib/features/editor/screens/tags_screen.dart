import 'dart:async';
import 'package:canvas_app/core/services/template_asset_installer.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:canvas_app/core/services/local_history_service.dart'; // Для авто-бэкапа
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/providers/tag_provider.dart';
import 'package:canvas_app/features/editor/providers/template_provider.dart';
import 'package:canvas_app/features/editor/screens/chapter_folder_picker_screen.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/editor/utils/template_applier.dart';
import 'package:canvas_app/features/editor/widgets/template_picker_sheet.dart';
import 'package:canvas_app/features/editor/widgets/template_save_dialog.dart';
import 'package:canvas_app/features/editor/widgets/editor_ui.dart';
import 'package:canvas_app/features/onboarding/controllers/tutorial_controller.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

// План 020-C4.5: операции над квестом — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};

// Модель для сортировки
class TagWithStats {
  final Tag tag;
  final TagStats stats;
  TagWithStats({required this.tag, required this.stats});
}

enum TagSortFilter { alphabetical, byNodeCount, byForkCount }

class TagsScreen extends ConsumerStatefulWidget {
  final String questId;

  const TagsScreen({super.key, required this.questId});

  @override
  ConsumerState<TagsScreen> createState() => _TagsScreenState();
}

class _TagsScreenState extends ConsumerState<TagsScreen> {
  final TextEditingController _searchController = TextEditingController();
  TagSortFilter _activeFilter = TagSortFilter.alphabetical;
  bool _isDescending = false;
  bool _isProcessing = false; // Защита от двойных нажатий
  String _currentFolder = '/';
  List<String> _explicitFolders = [];

  /// Ключ FAB «Создать» — для подсветки в обучении.
  final GlobalKey _createFabKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadFolderConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctrl = ref.read(tutorialControllerProvider.notifier);
      ctrl.registerTarget(TutorialTargets.tagsCreateFab, _createFabKey);
      // Если обучение всё ещё на шаге «открой Сценарий и Главы» —
      // продвигаем сразу на «создай главу».
      final state = ref.read(tutorialControllerProvider);
      if (state.step == TutorialStep.openEditor ||
          state.step == TutorialStep.editorIntroModal) {
        ctrl.goTo(TutorialStep.highlightCreateChapter);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<TagWithStats> _filterAndSortTags(List<TagWithStats> tagsWithStats) {
    final searchQuery = _searchController.text.toLowerCase();
    var filtered = tagsWithStats
        .where((item) => item.tag.folderPath == _currentFolder)
        .toList();
    if (searchQuery.isNotEmpty) {
      filtered = filtered
          .where((item) => item.tag.name.toLowerCase().contains(searchQuery))
          .toList();
    }

    filtered.sort((a, b) {
      int comparison;
      switch (_activeFilter) {
        case TagSortFilter.alphabetical:
          comparison = a.tag.name.toLowerCase().compareTo(
            b.tag.name.toLowerCase(),
          );
          return comparison;
        case TagSortFilter.byNodeCount:
          comparison = a.stats.nodesCount.compareTo(b.stats.nodesCount);
          break;
        case TagSortFilter.byForkCount:
          comparison = a.stats.forksCount.compareTo(b.stats.forksCount);
          break;
      }
      return _isDescending ? -comparison : comparison;
    });

    return filtered;
  }

  Future<void> _loadFolderConfig() async {
    try {
      final configPath = QuestPaths.config(widget.questId);
      if (!await (await _qs()).exists(configPath)) {
        if (mounted) setState(() => _explicitFolders = []);
        return;
      }
      final config = await _readMap(configPath);
      final folders = List<String>.from(config['__folders__'] ?? []);
      if (!mounted) return;
      setState(() {
        _explicitFolders =
            folders
                .map(Tag.normalizeFolderPath)
                .where((path) => path != '/')
                .toSet()
                .toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      });
    } catch (_) {}
  }

  Future<void> _saveFolderConfig(List<String> folders) async {
    final configPath = QuestPaths.config(widget.questId);
    if (!await (await _qs()).exists(configPath)) return;
    final config = await _readMap(configPath);
    await (await _qs()).writeJson(configPath, {
      ...config,
      '__folders__': folders,
    });
  }

  List<String> _allFolders(List<TagWithStats> tagsWithStats) {
    final folders = {
      ..._explicitFolders,
      ...tagsWithStats
          .map((item) => item.tag.folderPath)
          .where((path) => path != '/'),
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return folders;
  }

  List<String> _subFolders(List<String> allFolders) {
    final sub = <String>{};
    for (final folder in allFolders) {
      if (!folder.startsWith(_currentFolder) || folder == _currentFolder) {
        continue;
      }
      var relative = folder.substring(_currentFolder.length);
      if (relative.startsWith('/')) relative = relative.substring(1);
      if (relative.isEmpty) continue;
      final parts = relative.split('/');
      if (parts.first.isNotEmpty) {
        final fullPath = _currentFolder == '/'
            ? '/${parts.first}'
            : '$_currentFolder/${parts.first}';
        sub.add(fullPath);
      }
    }
    final list = sub.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  String _folderLabel(String folderPath) {
    if (folderPath == '/') return tr('Без папки');
    return folderPath.startsWith('/') ? folderPath.substring(1) : folderPath;
  }

  Future<List<String>> _loadExistingFolders() async {
    try {
      final tags = await ref.read(questTagsProvider(widget.questId).future);
      final folders = {
        ..._explicitFolders,
        ...tags.map((tag) => tag.folderPath).where((path) => path != '/'),
      }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return folders;
    } catch (_) {
      return const [];
    }
  }

  void _openFolder(String path) {
    setState(() => _currentFolder = Tag.normalizeFolderPath(path));
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

  void _goUpOneLevel() {
    if (_currentFolder == '/') return;
    final parts = _currentFolder.split('/');
    if (parts.length <= 2) {
      _openFolder('/');
      return;
    }
    parts.removeLast();
    _openFolder(parts.join('/'));
  }

  Future<String?> _showNameDialog(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    return showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: tr('Название'),
            hintStyle: TextStyle(color: Colors.white54),
            filled: true,
            fillColor: Color(0xFF1E1E1E),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
  }

  Future<void> _createFolder() async {
    final name = await _showNameDialog(tr('Новая папка'));
    if (name == null || name.isEmpty || name.contains('/')) return;

    final newPath = Tag.normalizeFolderPath(
      _currentFolder == '/' ? '/$name' : '$_currentFolder/$name',
    );
    if (_explicitFolders.contains(newPath)) return;

    final updatedFolders = [..._explicitFolders, newPath]
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await _saveFolderConfig(updatedFolders);
    if (!mounted) return;
    setState(() => _explicitFolders = updatedFolders);
  }

  Future<void> _renameFolder(String folderPath) async {
    // Контейнер берётся до первого await: диалог имени и запись файлов живут
    // долго, а экран за это время можно закрыть. На мёртвом state `ref`
    // бросает ещё до своей проверки — в debug это «This widget has been
    // unmounted…».
    final container = ProviderScope.containerOf(context, listen: false);
    final currentName = p.basename(folderPath);
    final newName = await _showNameDialog(
      tr('Переименовать папку'),
      initial: currentName,
    );
    if (newName == null || newName.isEmpty || newName.contains('/')) return;

    final parent = p.dirname(folderPath).replaceAll('\\', '/');
    final normalizedParent = parent == '.' ? '/' : parent;
    final newPath = Tag.normalizeFolderPath(
      normalizedParent == '/' ? '/$newName' : '$normalizedParent/$newName',
    );
    if (newPath == folderPath) return;

    final tags = await container.read(questTagsProvider(widget.questId).future);
    for (final tag in tags) {
      if (tag.folderPath == folderPath ||
          tag.folderPath.startsWith('$folderPath/')) {
        final targetFolder = Tag.normalizeFolderPath(
          tag.folderPath.replaceFirst(folderPath, newPath),
        );
        await updateTagName(
          widget.questId,
          tag.id,
          tag.name,
          folderPath: targetFolder,
          backgroundAudioId: tag.backgroundAudioId,
          backgroundAssetId: tag.backgroundAssetId,
        );
      }
    }

    final updatedFolders =
        _explicitFolders
            .map((folder) {
              if (folder == folderPath) return newPath;
              if (folder.startsWith('$folderPath/')) {
                return Tag.normalizeFolderPath(
                  folder.replaceFirst(folderPath, newPath),
                );
              }
              return folder;
            })
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await _saveFolderConfig(updatedFolders);

    // Главы переименованы на диске — пусть список узнает об этом даже без
    // экрана: канвас и фильтр стрелок читают тот же провайдер.
    container.invalidate(questTagsProvider(widget.questId));
    if (!mounted) return;
    setState(() {
      _explicitFolders = updatedFolders;
      if (_currentFolder == folderPath ||
          _currentFolder.startsWith('$folderPath/')) {
        _currentFolder = Tag.normalizeFolderPath(
          _currentFolder.replaceFirst(folderPath, newPath),
        );
      }
    });
  }

  Future<void> _deleteFolder(String folderPath) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final tags = await ref.read(questTagsProvider(widget.questId).future);
    if (!mounted) return;

    final affectedTags = tags
        .where(
          (tag) =>
              tag.folderPath == folderPath ||
              tag.folderPath.startsWith('$folderPath/'),
        )
        .toList();

    final action = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(
          tr('Удалить папку?'),
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          affectedTags.isEmpty
              ? tr('Папка пуста.')
              : trf('В папке {p0} глав. Что сделать с ними?', {
                  'p0': affectedTags.length,
                }),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(tr('Отмена')),
          ),
          if (affectedTags.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'move'),
              child: Text(tr('В корень')),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: Text(
              tr('Удалить'),
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (action == null || action == 'cancel') return;

    if (action == 'move') {
      for (final tag in affectedTags) {
        await updateTagName(
          widget.questId,
          tag.id,
          tag.name,
          folderPath: '/',
          backgroundAudioId: tag.backgroundAudioId,
          backgroundAssetId: tag.backgroundAssetId,
        );
      }
    } else if (action == 'delete') {
      for (final tag in affectedTags) {
        await deleteTag(widget.questId, tag.id);
      }
    }

    final updatedFolders =
        _explicitFolders
            .where(
              (folder) =>
                  folder != folderPath && !folder.startsWith('$folderPath/'),
            )
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await _saveFolderConfig(updatedFolders);

    // Главы удалены (или вынесены в корень) на диске — обновляем провайдеры
    // через container: экрана может уже не быть, а канвас читает их же.
    container.invalidate(questTagsProvider(widget.questId));
    container.invalidate(allQuestNodesProvider(widget.questId));
    if (!mounted) return;
    setState(() {
      _explicitFolders = updatedFolders;
      if (_currentFolder == folderPath ||
          _currentFolder.startsWith('$folderPath/')) {
        _currentFolder = '/';
      }
    });
  }

  void _showFolderMenu(String folderPath) {
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded, color: Colors.white70),
              title: Text(
                tr('Переименовать'),
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                _renameFolder(folderPath);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.redAccent,
              ),
              title: Text(
                tr('Удалить папку'),
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.pop(context);
                _deleteFolder(folderPath);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _showTagDialog({Tag? existingTag}) async {
    final nameController = TextEditingController(text: existingTag?.name ?? '');
    final folderController = TextEditingController(
      text: existingTag != null
          ? ((existingTag.folderPath == '/')
                ? ''
                : existingTag.folderPath.substring(1))
          : (_currentFolder == '/' ? '' : _currentFolder.substring(1)),
    );
    final existingFolders = await _loadExistingFolders();
    final currentFolderPath = existingTag?.folderPath;
    final folderSuggestions = existingFolders
        .where((path) => path != currentFolderPath)
        .toList();
    String? selectedAudioId = existingTag?.backgroundAudioId;
    String selectedAudioName = tr('Не выбрано');
    String? selectedImageId = existingTag?.backgroundAssetId;
    String selectedImageName = tr('Не выбрано');

    if (selectedAudioId != null || selectedImageId != null) {
      try {
        final metadata = await FileStorage.readJsonFile(
          QuestPaths.metadata(widget.questId),
        );
        if (selectedAudioId != null) {
          selectedAudioName =
              metadata[selectedAudioId]?['name'] ?? selectedAudioId;
        }
        if (selectedImageId != null) {
          selectedImageName =
              metadata[selectedImageId]?['name'] ?? selectedImageId;
        }
      } catch (_) {}
    }

    if (!mounted) return null;

    return showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text(
                existingTag == null
                    ? tr('Новая глава')
                    : tr('Редактировать главу'),
                style: GoogleFonts.manrope(fontWeight: FontWeight.bold),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTextField(
                      controller: nameController,
                      hint: tr('Название главы'),
                      scheme: scheme,
                    ),
                    const SizedBox(height: 12),
                    _buildTextField(
                      controller: folderController,
                      hint: tr('Папка (например: Глава 1/Сцена A)'),
                      scheme: scheme,
                    ),
                    if (folderSuggestions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: folderSuggestions
                            .map(
                              (path) => ActionChip(
                                label: Text(_folderLabel(path)),
                                onPressed: () {
                                  setDialogState(() {
                                    folderController.text = _folderLabel(path);
                                  });
                                },
                              ),
                            )
                            .toList(),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      tr('Ресурсы'),
                      style: GoogleFonts.manrope(
                        color: scheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildResourcePicker(
                      scheme: scheme,
                      icon: Icons.image_outlined,
                      title: tr('Фон'),
                      selectedName: selectedImageName,
                      hasSelection: selectedImageId != null,
                      onTap: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ResourceSelectionScreen(
                              questId: widget.questId,
                              allowedTypes: const ['image'],
                            ),
                          ),
                        );
                        if (result != null) {
                          setDialogState(() {
                            selectedImageId = result.name;
                            selectedImageName = result.friendlyName;
                          });
                        }
                      },
                      onClear: () => setDialogState(() {
                        selectedImageId = null;
                        selectedImageName = tr('Не выбрано');
                      }),
                    ),
                    const SizedBox(height: 12),
                    _buildResourcePicker(
                      scheme: scheme,
                      icon: Icons.music_note_rounded,
                      title: tr('Музыка'),
                      selectedName: selectedAudioName,
                      hasSelection: selectedAudioId != null,
                      onTap: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ResourceSelectionScreen(
                              questId: widget.questId,
                              allowedTypes: const ['audio'],
                            ),
                          ),
                        );
                        if (result != null) {
                          setDialogState(() {
                            selectedAudioId = result.name;
                            selectedAudioName = result.friendlyName;
                          });
                        }
                      },
                      onClear: () => setDialogState(() {
                        selectedAudioId = null;
                        selectedAudioName = tr('Не выбрано');
                      }),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('Отмена')),
                ),
                FilledButton(
                  onPressed: () {
                    if (nameController.text.trim().isNotEmpty) {
                      Navigator.pop(context, {
                        'name': nameController.text.trim(),
                        'folderPath': folderController.text.trim(),
                        'audioId': selectedAudioId,
                        'imageId': selectedImageId,
                      });
                    }
                  },
                  child: Text(tr('Сохранить')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required ColorScheme scheme,
  }) {
    return TextField(
      controller: controller,
      style: TextStyle(color: scheme.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      autofocus: true,
    );
  }

  Widget _buildResourcePicker({
    required ColorScheme scheme,
    required IconData icon,
    required String title,
    required String selectedName,
    required bool hasSelection,
    required VoidCallback onTap,
    required VoidCallback onClear,
  }) {
    // Не `selectedName != 'Не выбрано'`: подпись теперь локализирована, и
    // сравнение текста молча сломалось бы на любом языке кроме русского.
    final isSelected = hasSelection;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: scheme.onSurfaceVariant, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: scheme.onSurface, fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selectedName,
                    style: TextStyle(
                      color: isSelected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (isSelected)
              IconButton(
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: onClear,
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              )
            else
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _createNewTag() async {
    final container = ProviderScope.containerOf(context, listen: false);
    // Если обучение на шаге «подсветка кнопки Создать» — продвигаем
    // вперёд ещё до открытия диалога, чтобы подсветка не мешала.
    final tutorial = ref.read(tutorialControllerProvider);
    if (tutorial.step == TutorialStep.highlightCreateChapter) {
      ref.read(tutorialControllerProvider.notifier).next();
    }

    final result = await _showTagDialog();
    if (result == null || !mounted) return;

    await createTag(
      widget.questId,
      result['name'],
      folderPath: result['folderPath'],
      backgroundAudioId: result['audioId'],
      backgroundAssetId: result['imageId'],
    );
    // Глава уже на диске, а экрана может не быть: write живёт дольше тапа по
    // «Назад». Через container — иначе список глав останется без новой главы.
    container.invalidate(questTagsProvider(widget.questId));
  }

  Future<void> _editTag(Tag tag) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final result = await _showTagDialog(existingTag: tag);
    if (result == null || !mounted) return;

    await updateTagName(
      widget.questId,
      tag.id,
      result['name'],
      folderPath: result['folderPath'],
      backgroundAudioId: result['audioId'],
      backgroundAssetId: result['imageId'],
    );
    container.invalidate(questTagsProvider(widget.questId));
  }

  Future<void> _moveTagToFolder(Tag tag) async {
    final container = ProviderScope.containerOf(context, listen: false);
    if (!mounted) return;
    final folders = await _loadExistingFolders();
    if (!mounted) return;

    final selectedPath = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ChapterFolderPickerScreen(
          title: tr('Переместить главу'),
          folders: folders,
          initialFolder: tag.folderPath,
        ),
      ),
    );

    if (selectedPath == null || !mounted) return;
    final normalized = Tag.normalizeFolderPath(selectedPath);
    if (normalized == tag.folderPath) return;

    await updateTagName(
      widget.questId,
      tag.id,
      tag.name,
      folderPath: normalized,
      backgroundAudioId: tag.backgroundAudioId,
      backgroundAssetId: tag.backgroundAssetId,
    );

    container.invalidate(questTagsProvider(widget.questId));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          trf('Глава перемещена в "{p0}"', {'p0': _folderLabel(normalized)}),
        ),
        backgroundColor: const Color(0xFF00C853),
      ),
    );
  }

  Future<void> _duplicateTagAction(Tag tag) async {
    final container = ProviderScope.containerOf(context, listen: false);
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      final success = await duplicateTag(widget.questId, tag.id);
      // Копия главы легла на диск, пока экрана могло уже не быть — провайдеры
      // обновляем через container, иначе канвас не узнает о дубликате.
      if (success) {
        container.invalidate(questTagsProvider(widget.questId));
        container.invalidate(allQuestNodesProvider(widget.questId));
      }
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('Глава скопирована')),
              backgroundColor: Color(0xFF00C853),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('Ошибка копирования')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ============================================================
  // Шаблоны глав
  // ============================================================

  /// Сохранить главу как шаблон.
  Future<void> _saveChapterAsTemplate(Tag tag) async {
    try {
      // Все ноды квеста, фильтруем по chapterId
      final allNodes = await ref.read(
        allQuestNodesProvider(widget.questId).future,
      );
      final chapterNodes = allNodes
          .where((n) => n.chapterId == tag.id)
          .toList();

      // Связи берём из config.json
      List<Map<String, dynamic>> connections = const [];
      try {
        final configPath = QuestPaths.config(widget.questId);
        if (await (await _qs()).exists(configPath)) {
          final config = await _readMap(configPath);
          final rawConns = config['connections'];
          if (rawConns is List) {
            connections = rawConns
                .whereType<Map>()
                .map((c) => Map<String, dynamic>.from(c))
                .toList();
          }
        }
      } catch (_) {}

      if (!mounted) return;

      final result = await TemplateSaveDialog.show(
        context,
        title: tr('Сохранить главу как шаблон'),
        kind: TemplateKind.chapter,
        initialName: tag.name,
      );
      if (result == null || !mounted) return;

      final template = TemplateApplier.makeFromChapter(
        name: result.name,
        nodes: chapterNodes,
        connections: connections,
        chapterName: tag.name,
        description: result.description,
        category: result.category,
      );

      final actions = ref.read(templateActionsProvider);
      if (result.scope == TemplateScope.global) {
        await actions.saveAsGlobal(template, sourceQuestId: widget.questId);
      } else {
        await actions.saveToQuest(widget.questId, template);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trf('Шаблон главы сохранён (нод: {p0}, связей: {p1})', {
              'p0': chapterNodes.length,
              'p1': connections.where((c) {
                final ids = chapterNodes.map((n) => n.id).toSet();
                return ids.contains(c['fromId']?.toString()) &&
                    ids.contains(c['toId']?.toString());
              }).length,
            }),
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trf('Ошибка сохранения шаблона: {p0}', {'p0': friendlyError(e)}),
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Вставить главу из шаблона.
  Future<void> _insertChapterFromTemplate() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final picked = await TemplatePickerSheet.show(
      context,
      questId: widget.questId,
      allowedKinds: const {TemplateKind.chapter},
      title: tr('Вставить главу из шаблона'),
    );
    if (picked == null || !mounted) return;

    // Предупреждение про плагины
    final pluginIds = TemplateApplier.collectPluginIds(picked);
    if (pluginIds.isNotEmpty) {
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text(
            tr('Шаблон использует плагины'),
            style: TextStyle(color: Colors.white),
          ),
          content: Text(
            trf(
              'Этот шаблон ссылается на плагины: {p0}. Если они не установлены в текущем квесте, глава может работать некорректно. Продолжить вставку?',
              {'p0': pluginIds.join(", ")},
            ),
            style: const TextStyle(color: Colors.white70),
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
      if (confirm != true || !mounted) return;
    }

    // Имя новой главы. По умолчанию — chapterName из payload или имя шаблона.
    final defaultName = trf('{p0} (из шаблона)', {
      'p0':
          (picked.payload['chapterName']?.toString().trim().isNotEmpty == true)
          ? picked.payload['chapterName']
          : picked.name,
    });
    final newName = await _showNameDialog(
      tr('Название новой главы'),
      initial: defaultName,
    );
    if (newName == null || newName.isEmpty || !mounted) return;

    try {
      // Устанавливаем ассеты в квест.
      final installed = await TemplateAssetInstaller.installToQuest(
        template: picked,
        questId: widget.questId,
      );
      final effectiveTemplate = installed.template;

      // Создаём новую главу (с тем же folderPath, что и текущая папка),
      // чтобы получить chapterId.
      final folder = _currentFolder == '/' ? null : _currentFolder;
      final newTag = await createTag(
        widget.questId,
        newName,
        folderPath: folder,
      );
      if (newTag == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Не удалось создать главу')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Пересобираем ноды и связи под новый chapterId.
      final applied = TemplateApplier.buildChapter(
        effectiveTemplate,
        targetChapterId: newTag.id,
      );
      if (applied == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Не удалось распаковать шаблон главы')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Сохраняем ноды.
      if (applied.nodes.isNotEmpty) {
        await saveNodes(widget.questId, applied.nodes);
      }

      // Добавляем связи в config.json.
      if (applied.connections.isNotEmpty) {
        await FileStorage.synchronized('config_${widget.questId}', () async {
          final configPath = QuestPaths.config(widget.questId);
          if (!await (await _qs()).exists(configPath)) return;
          final config = await _readMap(configPath);
          final connsJson = (config['connections'] as List<dynamic>? ?? [])
              .toList();
          for (final c in applied.connections) {
            connsJson.add(c.toJson());
          }
          await (await _qs()).writeJson(configPath, {
            ...config,
            'connections': connsJson,
          });
        });
      }

      container.invalidate(questTagsProvider(widget.questId));
      container.invalidate(allQuestNodesProvider(widget.questId));
      if (!mounted) return;

      final report = installed.assetsReport;
      final msg = report.copied > 0
          ? trf(
              'Глава «{p0}» вставлена (нод: {p1}, связей: {p2}, ресурсов: {p3}, пропущено: {p4})',
              {
                'p0': newTag.name,
                'p1': applied.nodes.length,
                'p2': applied.connections.length,
                'p3': report.copied,
                'p4': report.skippedExisting,
              },
            )
          : trf('Глава «{p0}» вставлена (нод: {p1}, связей: {p2})', {
              'p0': newTag.name,
              'p1': applied.nodes.length,
              'p2': applied.connections.length,
            });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.blue),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trf('Ошибка вставки главы: {p0}', {'p0': friendlyError(e)}),
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showTagOptions(Tag tag) {
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            _buildOptionTile(
              icon: Icons.edit_rounded,
              title: tr('Редактировать'),
              color: Colors.white,
              onTap: () {
                Navigator.pop(context);
                _editTag(tag);
              },
            ),
            _buildOptionTile(
              icon: Icons.copy_rounded,
              title: tr('Дублировать'),
              color: Colors.blueAccent,
              onTap: () {
                Navigator.pop(context);
                _duplicateTagAction(tag);
              },
            ),
            _buildOptionTile(
              icon: Icons.drive_file_move_rounded,
              title: tr('Переместить в папку'),
              color: Colors.orangeAccent,
              onTap: () {
                Navigator.pop(context);
                _moveTagToFolder(tag);
              },
            ),
            _buildOptionTile(
              icon: Icons.bookmark_add_outlined,
              title: tr('Сохранить как шаблон'),
              color: Colors.cyanAccent,
              onTap: () {
                Navigator.pop(context);
                _saveChapterAsTemplate(tag);
              },
            ),
            const Divider(color: Colors.white10, height: 24),
            _buildOptionTile(
              icon: Icons.delete_outline_rounded,
              title: tr('Удалить'),
              color: Colors.redAccent,
              onTap: () {
                Navigator.pop(context);
                _deleteTag(tag);
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      onTap: onTap,
    );
  }

  Future<void> _deleteTag(Tag tag) async {
    // Контейнер берётся до первого await: авто-бэкап и стирание папки главы —
    // долгие операции, и экран за это время можно закрыть.
    final container = ProviderScope.containerOf(context, listen: false);
    final statsFuture = nodeDeletionStats(widget.questId, chapterId: tag.id);
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(
          tr('Удалить главу?'),
          style: TextStyle(color: Colors.white),
        ),
        content: FutureBuilder<(int, int)>(
          future: statsFuture,
          builder: (context, snapshot) {
            final stats = snapshot.data;
            final dangerous =
                stats != null && stats.$1 > 0 && stats.$2 * 2 > stats.$1;
            return Text(
              '${tr('Внимание: Все ноды внутри этой главы будут удалены безвозвратно!\n\nРекомендуется создать резервную копию.')}'
              '${dangerous ? '\n\n${stats.$2} / ${stats.$1} нод' : ''}',
              style: TextStyle(color: Colors.white70),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              tr('Удалить'),
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      // АВТО-БЭКАП
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Создание авто-бэкапа...')),
            duration: Duration(seconds: 1),
          ),
        );
        // Вызываем сервис для создания бэкапа
        await LocalHistoryService.createSnapshot(widget.questId);
      } catch (_) {
        // Ошибки бэкапа не должны блокировать удаление,
        // но можно добавить логгирование при желании
      }

      // Само удаление. deleteTag не бросает — он возвращает false, если не
      // смог; раньше этот ответ терялся и снэкбар всегда говорил «удалена».
      final removed = await deleteTag(widget.questId, tag.id);

      // Глава стёрта с диска — провайдеры обновляем через container: экрана
      // может уже не быть, а `ref` на мёртвом state бросает, и канвас так и
      // остаётся с удалённой главой.
      container.invalidate(questTagsProvider(widget.questId));
      container.invalidate(allQuestNodesProvider(widget.questId));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            removed
                ? tr('Глава удалена (создан авто-бэкап)')
                : tr('Не удалось удалить главу'),
          ),
          backgroundColor: removed ? Colors.orange : Colors.red,
        ),
      );
    }
  }

  void _showFilterDialog() {
    showAdaptiveSheet(
      context: context,
      scrollable: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Сортировка'),
                      style: GoogleFonts.manrope(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildRadioTile(
                      title: tr('По алфавиту (А-Я)'),
                      value: TagSortFilter.alphabetical,
                      groupValue: _activeFilter,
                      onChanged: (v) => setModalState(() {
                        _activeFilter = v!;
                      }),
                    ),
                    _buildRadioTile(
                      title: tr('По количеству нод'),
                      value: TagSortFilter.byNodeCount,
                      groupValue: _activeFilter,
                      onChanged: (v) => setModalState(() => _activeFilter = v!),
                    ),
                    _buildRadioTile(
                      title: tr('По развилкам'),
                      value: TagSortFilter.byForkCount,
                      groupValue: _activeFilter,
                      onChanged: (v) => setModalState(() => _activeFilter = v!),
                    ),
                    const SizedBox(height: 16),
                    const Divider(color: Colors.white12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          tr('Порядок:'),
                          style: TextStyle(color: Colors.white70),
                        ),
                        ToggleButtons(
                          isSelected: [
                            _isDescending == false,
                            _isDescending == true,
                          ],
                          onPressed: (index) {
                            setModalState(() {
                              _isDescending = index == 1;
                            });
                          },
                          color: Colors.white,
                          selectedColor: Colors.black,
                          fillColor: const Color(0xFF00C853),
                          borderRadius: BorderRadius.circular(8),
                          children: const [
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text("ASC"),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text("DESC"),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: () {
                          setState(() {}); // Обновляем основной экран
                          Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00C853),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          tr('Применить'),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRadioTile<T>({
    required String title,
    required T value,
    required T groupValue,
    required ValueChanged<T?> onChanged,
  }) {
    return RadioListTile<T>(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      value: value,
      groupValue: groupValue,
      onChanged: onChanged,
      activeColor: const Color(0xFF00C853),
      contentPadding: EdgeInsets.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tagsAsync = ref.watch(questTagsProvider(widget.questId));

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          tooltip: tr('Закрыть вкладку'),
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _closeDocument,
        ),
        title: Text(
          tr('Мои главы'),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
        ),
        actions: [
          IconButton(
            tooltip: tr('Вставить главу из шаблона'),
            icon: Icon(Icons.bookmark_added_rounded, color: scheme.tertiary),
            onPressed: _insertChapterFromTemplate,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AdaptiveContent(
        maxWidth: 800,
        child: Column(
          children: [
            // SEARCH BAR
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: EditorSearchField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  EditorIconButton(
                    icon: Icons.filter_list_rounded,
                    tooltip: tr('Сортировка'),
                    onPressed: _showFilterDialog,
                  ),
                ],
              ),
            ),

            // LIST
            Expanded(
              child: tagsAsync.when(
                loading: () => Center(
                  child: CircularProgressIndicator(color: scheme.primary),
                ),
                error: (err, _) => Center(
                  child: Text(
                    trf('Ошибка: {p0}', {'p0': friendlyError(err)}),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
                data: (tags) {
                  if (tags.isEmpty) {
                    return EditorEmptyState(
                      icon: Icons.dashboard_customize_outlined,
                      message: tr('Создайте первую главу'),
                      hint: tr('Главы группируют ноды вашей истории'),
                    );
                  }

                  return FutureBuilder<List<TagWithStats>>(
                    future: Future.wait(
                      tags.map((tag) async {
                        final stats = await ref.read(
                          tagStatsProvider(
                            TagInfo(questId: widget.questId, tagId: tag.id),
                          ).future,
                        );
                        return TagWithStats(tag: tag, stats: stats);
                      }),
                    ),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF00C853),
                          ),
                        );
                      }

                      final allItems = snapshot.data!;
                      final allFolders = _allFolders(allItems);
                      final subFolders = _subFolders(allFolders);
                      final filteredTags = _filterAndSortTags(allItems);

                      return ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Row(
                            children: [
                              if (_currentFolder != '/')
                                EditorIconButton(
                                  icon: Icons.keyboard_return_rounded,
                                  tooltip: tr('На уровень выше'),
                                  onPressed: _goUpOneLevel,
                                ),
                              if (_currentFolder != '/')
                                const SizedBox(width: 8),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 13,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        _currentFolder == '/'
                                            ? Icons.home_rounded
                                            : Icons.folder_open_rounded,
                                        size: 18,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _currentFolder == '/'
                                              ? tr('Корень')
                                              : _folderLabel(_currentFolder),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: scheme.onSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              EditorIconButton(
                                icon: Icons.create_new_folder_outlined,
                                tooltip: tr('Новая папка'),
                                onPressed: _createFolder,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          for (final folderPath in subFolders)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _FolderCard(
                                name: p.basename(folderPath),
                                onTap: () => _openFolder(folderPath),
                                onMore: () => _showFolderMenu(folderPath),
                              ),
                            ),
                          if (filteredTags.isEmpty && subFolders.isEmpty)
                            Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: EditorEmptyState(
                                icon: Icons.search_off_rounded,
                                message: tr('Ничего не найдено'),
                              ),
                            ),
                          for (final item in filteredTags)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _TagCard(
                                tag: item.tag,
                                stats: item.stats,
                                onTap: () {
                                  // Если обучение на шаге «открой главу» —
                                  // продвигаем на «добавить узел».
                                  final tutorial = ref.read(
                                    tutorialControllerProvider,
                                  );
                                  if (tutorial.step ==
                                      TutorialStep.openChapterModal) {
                                    ref
                                        .read(
                                          tutorialControllerProvider.notifier,
                                        )
                                        .next();
                                  }
                                  EditorDocumentLauncher.openCanvas(
                                    context,
                                    widget.questId,
                                    item.tag.id,
                                    title: item.tag.name,
                                  );
                                },
                                onMore: () => _showTagOptions(item.tag),
                              ),
                            ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        key: _createFabKey,
        onPressed: _createNewTag,
        icon: const Icon(Icons.add_rounded),
        label: Text(
          tr('Создать'),
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _TagCard extends StatelessWidget {
  final Tag tag;
  final TagStats stats;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _TagCard({
    required this.tag,
    required this.stats,
    required this.onTap,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return EditorListCard(
      icon: Icons.bookmark_rounded,
      title: tag.name,
      subtitle: trf('Папка: {p0}', {
        'p0': tag.folderPath == '/'
            ? tr('Без папки')
            : tag.folderPath.substring(1),
      }),
      onTap: onTap,
      onMore: onMore,
      badges: [
        EditorBadge(
          icon: Icons.account_tree_rounded,
          label: trf('{p0} нод', {'p0': stats.nodesCount}),
          color: scheme.primary,
        ),
        EditorBadge(
          icon: Icons.call_split_rounded,
          label: trf('{p0} развилок', {'p0': stats.forksCount}),
          color: scheme.tertiary,
        ),
      ],
    );
  }
}

class _FolderCard extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _FolderCard({
    required this.name,
    required this.onTap,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.folder_rounded,
                  color: scheme.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
              ),
              IconButton(
                onPressed: onMore,
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
