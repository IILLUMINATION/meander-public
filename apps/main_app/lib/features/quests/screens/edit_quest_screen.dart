import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/services/quest_content_change_bus.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/utils/quest_genres.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_player/widgets/node_transition_switcher.dart';
import 'package:canvas_app/features/editor/screens/button_style_presets_screen.dart';
import 'package:canvas_app/features/editor/workspace/editor_back_handler.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/editor/services/script_providers.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart' as canvas_qp;
import 'package:mnd_core/models/quest_descriptor.dart';
import 'package:mnd_player/providers/quest_provider.dart' as player_qp;
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:mnd_player/widgets/content_display_factory.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:mnd_core/utils/quest_paths.dart';

// План 020-C4.5: операции над квестом — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};

// ============================================================================
//  НАСТРОЙКИ КВЕСТА — Material 3 редизайн
// ============================================================================
//
//  UX-улучшения:
//   • Содержимое разбито на 3 вкладки: «Основное» / «Внешний вид» / «Медиа».
//   • Save — отдельный FAB, появляющийся только при наличии изменений.
//   • Все цвета через ColorScheme; убраны хардкодные тёмные `0xFF1E1E1E`.
//   • AlertDialog'и без backgroundColor-оверрайдов.
//   • RadioListTile/SwitchListTile берут стиль из темы.
//   • Скриншоты — в виде грида с понятной кнопкой «+».
//
// ============================================================================

class EditQuestScreen extends ConsumerStatefulWidget {
  final String questId;
  const EditQuestScreen({super.key, required this.questId});

  @override
  ConsumerState<EditQuestScreen> createState() => _EditQuestScreenState();
}

class _EditQuestScreenState extends ConsumerState<EditQuestScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  late TabController _tabController;

  late TextEditingController _titleController;
  late TextEditingController _authorController;
  late TextEditingController _descriptionController;
  late TextEditingController _versionController;
  final TextEditingController _genreSearch = TextEditingController();
  String _genreQuery = '';

  File? _newPreviewFile;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isDirty = false;
  bool _isProcessingScreenshot = false;

  String? _selectedBackgroundId;
  String? _selectedBackgroundName;

  String? _selectedFontFileName;
  String? _selectedFontName;

  List<String> _selectedGenres = [];

  bool _dimBackground = false;
  bool _hideNodeTitles = false;
  bool _wrapButtonText = true;
  bool _allowOpenContent = false;
  String? _questLanguage;
  bool _musicInBackground = false;
  String _defaultTextFit = 'scale';
  String _nodeTransitionMode = 'none';
  String _scriptEngineMode = kScriptEngineModeNew;

  List<String> _localScreenshots = [];
  List<ButtonStyleConfig> _buttonStylePresets = [];

  /// Пресет кнопок, играющий роль оформления по умолчанию для всего
  /// квеста (#159).
  String? _defaultButtonPresetName;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _titleController = TextEditingController();
    _authorController = TextEditingController();
    _descriptionController = TextEditingController();
    _versionController = TextEditingController();
    _loadQuestData();
  }

  @override
  void dispose() {
    _cleanupTempFile();
    _tabController.dispose();
    _titleController.dispose();
    _authorController.dispose();
    _descriptionController.dispose();
    _versionController.dispose();
    _genreSearch.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  //  Загрузка
  // ---------------------------------------------------------------------------

  Future<void> _loadQuestData() async {
    try {
      final quest = await ref.read(canvas_qp.questProvider(widget.questId).future);

      if (quest != null && mounted) {
        _titleController.text = quest.title;
        _authorController.text = quest.author ?? '';
        _descriptionController.text = quest.description ?? '';
        _versionController.text = _normalizeQuestVersion(quest.version ?? '');
        _localScreenshots = List<String>.from(quest.screenshotFiles ?? []);
        final config = await FileStorage.readJsonFile(
          QuestPaths.config(widget.questId),
        );

        // Старые квесты хранят английские названия жанров; в UI и в API
        // работаем только с каноническими id.
        _selectedGenres = normalizeGenreIds(quest.genres);
        if (_selectedGenres.isEmpty && config['category'] != null) {
          _selectedGenres = normalizeGenreIds([config['category']]);
        }
        _buttonStylePresets = _readButtonStylePresets(config);
        _defaultButtonPresetName = quest.defaultButtonPresetName;

        _dimBackground = quest.dimBackground;
        _hideNodeTitles = quest.hideNodeTitles;
        _wrapButtonText = quest.wrapButtonText;
        _allowOpenContent = quest.allowOpenContent;
        _questLanguage = quest.language;
        _musicInBackground = quest.musicInBackground;
        _defaultTextFit = quest.defaultTextFit;
        _nodeTransitionMode = quest.nodeTransitionMode;
        _scriptEngineMode = kScriptEngineModeNew;

        if (quest.backgroundAssetId != null) {
          _selectedBackgroundId = quest.backgroundAssetId;
          try {
            final metadata = await FileStorage.readJsonFile(
              QuestPaths.metadata(widget.questId),
            );
            _selectedBackgroundName = _resolveFriendlyResourceName(
              rawIdOrPath: quest.backgroundAssetId,
              metadata: metadata,
            );
          } catch (_) {
            _selectedBackgroundName = p.basename(quest.backgroundAssetId!);
          }
        }

        if (quest.customFontFileName != null) {
          _selectedFontFileName = quest.customFontFileName;
          try {
            final metadata = await FileStorage.readJsonFile(
              QuestPaths.metadata(widget.questId),
            );
            _selectedFontName = _resolveFriendlyResourceName(
              rawIdOrPath: quest.customFontFileName,
              metadata: metadata,
            );
          } catch (_) {
            _selectedFontName = p.basename(quest.customFontFileName!);
          }
        }

        void markDirty() => setState(() => _isDirty = true);
        _titleController.addListener(markDirty);
        _authorController.addListener(markDirty);
        _descriptionController.addListener(markDirty);
        _versionController.addListener(markDirty);
      }
    } catch (e, stack) {
      debugPrint('[EDIT_QUEST] Ошибка загрузки данных квеста: $e\n$stack');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  //  Сохранение
  // ---------------------------------------------------------------------------

  Future<void> _saveChanges() async {
    if (_isSaving || !_isDirty) return;
    if (!_formKey.currentState!.validate()) {
      // Если ошибка валидации — переключимся на вкладку «Основное».
      _tabController.animateTo(0);
      return;
    }

    if (_selectedGenres.isEmpty) {
      _tabController.animateTo(0);
      _showSnack(tr('Выберите хотя бы один жанр'), warning: true);
      return;
    }

    setState(() => _isSaving = true);

    try {
      final configPath = QuestPaths.config(widget.questId);
      final config = await _readMap(configPath);

      config['title'] = _titleController.text.trim();
      config['author'] = _authorController.text.trim();
      config['description'] = _descriptionController.text.trim();
      final editedAt = DateTime.now().toIso8601String();
      config['lastEditedAt'] = editedAt;
      // Старый ключ оставляем для совместимости с прежними клиентами.
      config['updated'] = editedAt;
      config['version'] = _normalizeQuestVersion(_versionController.text);
      config['backgroundAssetId'] = _selectedBackgroundId;
      config['customFontFileName'] = _selectedFontFileName;
      config['screenshot_files'] = _localScreenshots;
      config['genres'] = _selectedGenres;
      config['category'] = _selectedGenres.first;
      config['dimBackground'] = _dimBackground;
      config['hideNodeTitles'] = _hideNodeTitles;
      config['wrapButtonText'] = _wrapButtonText;
      config['defaultButtonPresetName'] = _defaultButtonPresetName;
      config['musicInBackground'] = _musicInBackground;
      config['defaultTextFit'] = _defaultTextFit;
      config['nodeTransitionMode'] = _nodeTransitionMode;
      config['scriptEngineMode'] = kScriptEngineModeNew;
      config['allowOpenContent'] = _allowOpenContent;
      config['language'] = _questLanguage;

      if (_newPreviewFile != null) {
        final extension = p.extension(_newPreviewFile!.path);
        final fileName = 'preview$extension';

        final targetPath = await FileStorage.getFilePath(
          QuestPaths.questFile(widget.questId, fileName),
        );

        final targetFile = File(targetPath);
        if (!await targetFile.parent.exists()) {
          await targetFile.parent.create(recursive: true);
        }

        await _newPreviewFile!.copy(targetPath);

        config['previewFileName'] = fileName;
        await _cleanupTempFile();
      }

      await (await _qs()).writeJson(configPath, config);
      QuestContentChangeBus.instance.markChanged(widget.questId);
      ref.invalidate(canvas_qp.questsProvider);
      ref.invalidate(canvas_qp.questProvider(widget.questId));
      // mnd_player имеет отдельный провайдер (другая библиотека) — иначе GameScreen не увидит новую настройку musicInBackground
      ref.invalidate(player_qp.questsProvider);
      ref.invalidate(player_qp.questProvider(widget.questId));

      if (mounted) {
        _showSnack(tr('Изменения сохранены'), success: true);
        Navigator.pop(context, true);
      }
    } catch (e, stack) {
      debugPrint('[EDIT_QUEST] Ошибка сохранения: $e\n$stack');
      if (mounted) {
        _showSnack(trf('Ошибка сохранения: {p0}', {'p0': friendlyError(e)}), error: true);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String _normalizeQuestVersion(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? '1.0.0' : trimmed;
  }

  String _resolveFriendlyResourceName({
    required String? rawIdOrPath,
    required Map<String, dynamic> metadata,
  }) {
    if (rawIdOrPath == null || rawIdOrPath.trim().isEmpty) {
      return '';
    }

    final raw = rawIdOrPath.trim();
    final base = p.basename(raw);
    final rawNoExt = p.basenameWithoutExtension(base).toLowerCase();

    String? tryExtractName(dynamic value) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is Map<String, dynamic>) {
        final nested = value['name'];
        if (nested is String && nested.trim().isNotEmpty) {
          return nested.trim();
        }
      }
      return null;
    }

    final direct =
        tryExtractName(metadata[raw]) ?? tryExtractName(metadata[base]);
    if (direct != null) return direct;

    for (final entry in metadata.entries) {
      final keyBase = p.basename(entry.key);
      final keyNoExt = p.basenameWithoutExtension(keyBase).toLowerCase();
      if (keyBase == base || keyNoExt == rawNoExt) {
        final resolved = tryExtractName(entry.value);
        if (resolved != null) return resolved;
      }
    }

    return base;
  }

  List<ButtonStyleConfig> _readButtonStylePresets(Map<String, dynamic> config) {
    final raw = config['buttonStylePresets'];
    if (raw is! List) return const [];
    final result = <ButtonStyleConfig>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final parsed = ButtonStyleConfig.fromJson(map);
      final hasName = (parsed.presetName?.trim().isNotEmpty ?? false);
      if (hasName) {
        result.add(parsed);
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  //  Действия
  // ---------------------------------------------------------------------------

  Future<void> _pickFont() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (context) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['font'],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _selectedFontFileName = result.name;
        _selectedFontName = result.friendlyName;
        _isDirty = true;
      });
    }
  }

  Future<void> _pickBackground() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (context) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _selectedBackgroundId = result.name;
        _selectedBackgroundName = result.friendlyName;
        _isDirty = true;
      });
    }
  }

  Future<void> _openButtonPresetsEditor() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ButtonStylePresetsScreen(questId: widget.questId),
      ),
    );
    await _reloadButtonPresets();
  }

  Future<void> _reloadButtonPresets() async {
    try {
      final config = await FileStorage.readJsonFile(
        QuestPaths.config(widget.questId),
      );
      if (!mounted) return;
      setState(() {
        _buttonStylePresets = _readButtonStylePresets(config);
        final stillExists = _buttonStylePresets.any(
          (p) => p.presetName?.trim() == _defaultButtonPresetName,
        );
        if (_defaultButtonPresetName != null && !stillExists) {
          // Пресет удалили или переименовали — возвращаемся на стекло.
          _defaultButtonPresetName = null;
          _isDirty = true;
        }
      });
    } catch (_) {}
  }

  ButtonStyleConfig? get _defaultButtonStyle {
    final name = _defaultButtonPresetName;
    if (name == null) return null;
    return _buttonStylePresets
        .where((p) => p.presetName?.trim() == name)
        .firstOrNull;
  }

  /// Пикер стиля по умолчанию для всего квеста (#159). Лист отдаёт `''` для
  /// встроенного стекла и `null`, если его закрыли без выбора.
  Future<void> _pickDefaultButtonPreset() async {
    final names = _buttonStylePresets
        .map((p) => p.presetName?.trim() ?? '')
        .where((n) => n.isNotEmpty)
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final chosen = await showAdaptiveSheet<String>(
      context: context,
      title: tr('Стиль кнопок по умолчанию'),
      showDragHandle: true,
      scrollable: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildPresetChoiceRow(
              sheetContext,
              title: tr('Встроенный (стеклянная кнопка)'),
              value: '',
              selected: _defaultButtonPresetName == null,
            ),
            for (final name in names)
              _buildPresetChoiceRow(
                sheetContext,
                title: name,
                value: name,
                selected: _defaultButtonPresetName == name,
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _defaultButtonPresetName = chosen.isEmpty ? null : chosen;
      _isDirty = true;
    });
  }

  /// Подпись выбранного языка в настройках. Код из удалённого импортированного
  /// языка показывается как есть: строка честно говорит, что квест помечен.
  String get _questLanguageLabel {
    final code = _questLanguage;
    if (code == null) return tr('Не указан');
    for (final language in L10n.supported) {
      if (language.code == code) return language.nativeName;
    }
    return code;
  }

  /// Пикер языка квеста: реестр интерфейсных языков плюс импортированные,
  /// чтобы код совпадал с тем, по которому маркет сортирует выдачу.
  Future<void> _pickQuestLanguage() async {
    final chosen = await showAdaptiveSheet<String>(
      context: context,
      title: tr('Язык квеста'),
      showDragHandle: true,
      scrollable: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildPresetChoiceRow(
              sheetContext,
              title: tr('Не указан'),
              value: '',
              selected: _questLanguage == null,
            ),
            for (final language in L10n.supported)
              _buildPresetChoiceRow(
                sheetContext,
                title: language.nativeName,
                value: language.code,
                selected: _questLanguage == language.code,
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _questLanguage = chosen.isEmpty ? null : chosen;
      _isDirty = true;
    });
  }

  Widget _buildPresetChoiceRow(
    BuildContext sheetContext, {
    required String title,
    required String value,
    required bool selected,
  }) {
    return ListTile(
      title: Text(title),
      trailing: selected ? const Icon(Icons.check_rounded) : null,
      onTap: () => Navigator.pop(sheetContext, value),
    );
  }

  Future<void> _pickPreviewImage() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file != null && file.path != null) {
      final pickedFile = File(file.path!);
      await _cleanupTempFile();
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = p.extension(pickedFile.path);
      final tempPath = p.join(
        tempDir.path,
        'temp_preview_$timestamp$extension',
      );
      final tempFile = await pickedFile.copy(tempPath);
      if (!mounted) return;
      setState(() {
        _newPreviewFile = tempFile;
        _isDirty = true;
      });
    }
  }

  Future<void> _addScreenshot() async {
    if (_isProcessingScreenshot) return;
    setState(() => _isProcessingScreenshot = true);

    final picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );

    if (xFile == null) {
      if (!mounted) return;
      setState(() => _isProcessingScreenshot = false);
      return;
    }

    try {
      final sourceFile = File(xFile.path);
      final fileExt = p.extension(xFile.path);
      final newFileName = '${const Uuid().v4()}$fileExt';

      final screenshotDir = QuestPaths.resScreenshotsDir(widget.questId);
      await FileStorage.createFolder(screenshotDir);

      final targetPath = await FileStorage.getFilePath(
        '$screenshotDir/$newFileName',
      );

      await sourceFile.copy(targetPath);

      if (!mounted) return;
      setState(() {
        _localScreenshots.add(newFileName);
        _isDirty = true;
      });
    } catch (e) {
      if (mounted) {
        _showSnack(
          trf('Ошибка добавления скриншота: {p0}', {'p0': friendlyError(e)}),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingScreenshot = false);
    }
  }

  Future<void> _deleteScreenshot(String fileName) async {
    try {
      setState(() {
        _localScreenshots.remove(fileName);
        _isDirty = true;
      });

      final filePath = QuestPaths.resScreenshot(widget.questId, fileName);
      if (await (await _qs()).exists(filePath)) {
        await FileStorage.delete(filePath);
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          trf('Ошибка удаления скриншота: {p0}', {'p0': friendlyError(e)}),
          error: true,
        );
      }
    }
  }

  Future<void> _cleanupTempFile() async {
    if (_newPreviewFile != null && await _newPreviewFile!.exists()) {
      try {
        await _newPreviewFile!.delete();
      } catch (e) {
        debugPrint('[EDIT_QUEST] Ошибка удаления временного файла: $e');
      }
    }
  }

  Future<bool?> _showUnsavedChangesDialog() {
    return showAppDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text(tr('Несохранённые изменения')),
          content: Text(
            tr('У вас есть несохранённые изменения. Уверены, что хотите выйти?'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Остаться')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              child: Text(tr('Выйти')),
            ),
          ],
        );
      },
    );
  }

  void _showSnack(
    String text, {
    bool success = false,
    bool error = false,
    bool warning = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    Color? bg;
    Color? fg;
    if (success) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
    } else if (error) {
      bg = scheme.error;
      fg = scheme.onError;
    } else if (warning) {
      bg = scheme.tertiaryContainer;
      fg = scheme.onTertiaryContainer;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        closeIconColor: fg,
      ),
    );
  }

  /// Обработка «Назад»: в режиме отдельного маршрута — подтверждение
  /// несохранённых изменений; во вкладке воркспейса — закрытие вкладки
  /// (тоже с подтверждением, если есть правки).
  Future<bool> _handleBackRequest() async {
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);

    Future<void> doExit() async {
      if (document != null && workspace != null) {
        await workspace.closeDocument(document.id);
      } else if (mounted) {
        Navigator.pop(context);
      }
    }

    if (!_isDirty) {
      await doExit();
      return true;
    }
    final shouldPop = await _showUnsavedChangesDialog() ?? false;
    if (shouldPop && mounted) {
      await doExit();
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final questAsync = ref.watch(canvas_qp.questProvider(widget.questId));
    final scheme = Theme.of(context).colorScheme;

    return EditorDocumentBackScope(
      standaloneCanPop: !_isDirty,
      onBackPressed: _handleBackRequest,
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          title: Text(
            tr('Настройки квеста'),
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          bottom: TabBar(
            controller: _tabController,
            isScrollable: false,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurfaceVariant,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
            unselectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
            tabs: [
              Tab(text: tr('Основное')),
              Tab(text: tr('Внешний вид')),
              Tab(text: tr('Медиа')),
            ],
          ),
        ),
        body: _isLoading
            ? Center(child: CircularProgressIndicator(color: scheme.primary))
            : Form(
                key: _formKey,
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _adaptiveWidth(_buildBasicTab(questAsync)),
                    _adaptiveWidth(_buildAppearanceTab()),
                    _adaptiveWidth(_buildMediaTab()),
                  ],
                ),
              ),
        floatingActionButton: _isDirty && !_isLoading
            ? FloatingActionButton.extended(
                heroTag: 'save_quest_settings_fab',
                onPressed: _isSaving ? null : _saveChanges,
                icon: _isSaving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(
                  tr('Сохранить'),
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              )
            : null,
      ),
    );
  }

  /// Ограничивает ширину контента вкладок на ПК, центрируя их.
  Widget _adaptiveWidth(Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: child,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Tab 1: Основное
  // ---------------------------------------------------------------------------

  Widget _buildBasicTab(AsyncValue<Quest?> questAsync) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
      children: [
        questAsync.when(
          data: (quest) => _buildCoverEditor(quest),
          loading: () => _buildCoverEditor(null),
          error: (_, __) => _buildCoverEditor(null),
        ),
        const SizedBox(height: 28),

        _SectionTitle(
          title: tr('Основная информация'),
          subtitle: tr('Заголовок, автор, описание'),
        ),
        const SizedBox(height: 12),
        _styledField(
          controller: _titleController,
          label: tr('Название квеста'),
          icon: Icons.title_rounded,
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? tr('Название обязательно') : null,
        ),
        const SizedBox(height: 12),
        _styledField(
          controller: _authorController,
          label: tr('Автор'),
          icon: Icons.person_outline_rounded,
        ),
        const SizedBox(height: 12),
        _styledField(
          controller: _descriptionController,
          label: tr('Описание'),
          icon: Icons.description_outlined,
          maxLines: 5,
        ),
        const SizedBox(height: 12),
        _styledField(
          controller: _versionController,
          label: tr('Версия квеста'),
          icon: Icons.numbers_rounded,
          hintText: tr('Например: 1.0.0'),
        ),
        const SizedBox(height: 12),
        _NavTile(
          icon: Icons.translate_rounded,
          title: tr('Язык квеста'),
          subtitle: _questLanguageLabel,
          onTap: _pickQuestLanguage,
        ),

        const SizedBox(height: 24),
        _SectionTitle(
          title: tr('Жанры'),
          subtitle: tr('Не больше трёх — это сильно влияет на поиск'),
        ),
        const SizedBox(height: 12),
        _buildGenreSelector(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  //  Tab 2: Внешний вид
  // ---------------------------------------------------------------------------

  Widget _buildAppearanceTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
      children: [
        _SectionTitle(
          title: tr('Атмосфера'),
          subtitle: tr('Фон, шрифт и общий тон квеста'),
        ),
        const SizedBox(height: 12),
        _buildResourceSelector(
          label: tr('Фон меню и загрузки'),
          selectedResourceName: _selectedBackgroundName,
          onTap: _pickBackground,
          onClear: () {
            setState(() {
              _selectedBackgroundId = null;
              _selectedBackgroundName = null;
              _isDirty = true;
            });
          },
        ),
        const SizedBox(height: 10),
        _buildResourceSelector(
          label: tr('Шрифт (для всего квеста)'),
          selectedResourceName: _selectedFontName,
          onTap: _pickFont,
          onClear: () {
            setState(() {
              _selectedFontFileName = null;
              _selectedFontName = null;
              _isDirty = true;
            });
          },
          icon: Icons.text_fields_rounded,
        ),
        const SizedBox(height: 12),

        _buildSwitchCard(
          title: tr('Затемнение фона'),
          subtitle: tr('Включает чёрный оверлей для лучшей читаемости в игре'),
          value: _dimBackground,
          onChanged: (v) => setState(() {
            _dimBackground = v;
            _isDirty = true;
          }),
        ),
        const SizedBox(height: 8),
        _buildSwitchCard(
          title: tr('Скрывать заголовки нод'),
          subtitle: tr('Названия нод не будут отображаться в верхней панели'),
          value: _hideNodeTitles,
          onChanged: (v) => setState(() {
            _hideNodeTitles = v;
            _isDirty = true;
          }),
        ),
        const SizedBox(height: 8),
        _buildSwitchCard(
          title: tr('Переносить текст на кнопках'),
          subtitle: tr('Длинный текст на кнопках будет идти на нескольких строках'),
          value: _wrapButtonText,
          onChanged: (v) => setState(() {
            _wrapButtonText = v;
            _isDirty = true;
          }),
        ),
        const SizedBox(height: 8),
        _buildSwitchCard(
          title: tr('Открытый контент'),
          subtitle:
              tr('Скачавшие квест смогут просматривать его структуру в редакторе. Полезно для обучающих квестов.'),
          value: _allowOpenContent,
          onChanged: (v) => setState(() {
            _allowOpenContent = v;
            _isDirty = true;
          }),
        ),

        const SizedBox(height: 24),
        _SectionTitle(
          title: tr('Стили кнопок'),
          subtitle: tr('Сохранённые пресеты для повторного применения'),
        ),
        const SizedBox(height: 8),
        _NavTile(
          icon: Icons.style_rounded,
          title: tr('Пресеты кнопок'),
          subtitle: _buttonStylePresets.isEmpty
              ? tr('Нет сохранённых пресетов')
              : trf('Сохранено: {n}', {'n': _buttonStylePresets.length}),
          onTap: _openButtonPresetsEditor,
        ),
        if (_buttonStylePresets.isNotEmpty) ...[
          const SizedBox(height: 8),
          _NavTile(
            icon: Icons.auto_awesome_motion_rounded,
            title: tr('Стиль кнопок по умолчанию'),
            subtitle: _defaultButtonPresetName == null
                ? tr('Встроенный — стеклянная кнопка')
                : _defaultButtonPresetName!,
            onTap: _pickDefaultButtonPreset,
          ),
          const SizedBox(height: 12),
          Center(
            child: GlassButton(
              onPressed: null,
              text: tr('Пример кнопки'),
              // Своё оформление у конкретной кнопки всегда сильнее этого.
              styleConfig: _defaultButtonStyle,
              questId: widget.questId,
            ),
          ),
        ],

        const SizedBox(height: 24),
        _SectionTitle(
          title: tr('Текст в строках (по умолчанию)'),
          subtitle: tr('Как себя ведёт длинный текст внутри ячеек'),
        ),
        const SizedBox(height: 8),
        _RadioCard(
          value: 'scale',
          groupValue: _defaultTextFit,
          onChanged: (v) => setState(() {
            _defaultTextFit = v!;
            _isDirty = true;
          }),
          title: tr('Масштабировать (сжимать)'),
          subtitle:
              tr('Текст в одну строку, уменьшается, чтобы влезть. Идеально для статов и коротких лейблов.'),
        ),
        _RadioCard(
          value: 'wrap',
          groupValue: _defaultTextFit,
          onChanged: (v) => setState(() {
            _defaultTextFit = v!;
            _isDirty = true;
          }),
          title: tr('Переносить (много строк)'),
          subtitle:
              tr('Текст переносится на новую строку. Хорошо для описаний внутри столбцов.'),
        ),

        const SizedBox(height: 24),
        _SectionTitle(
          title: tr('Анимация переходов'),
          subtitle: tr('Как сменяются ноды в игре'),
        ),
        const SizedBox(height: 12),
        // Живая превью: тот же движок переходов, что и в игре.
        NodeTransitionPreview(mode: _nodeTransitionMode),
        const SizedBox(height: 12),
        _RadioCard(
          value: 'none',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Без анимации'),
          subtitle: tr('Ноды переключаются мгновенно'),
        ),
        _RadioCard(
          value: 'fade',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Плавное затухание'),
          subtitle: tr('Cross-fade: ноды растворяются друг в друга'),
        ),
        _RadioCard(
          value: 'page',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Перелистывание'),
          subtitle: tr('3D-поворот страницы (rotateY + перспектива)'),
        ),
        _RadioCard(
          value: 'dark',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Затемнение'),
          subtitle: tr('Экран гаснет в чёрный, новая нода проявляется из тьмы'),
        ),
        _RadioCard(
          value: 'slide',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Сдвиг'),
          subtitle: tr('Новая нода въезжает справа, старая уезжает влево'),
        ),
        _RadioCard(
          value: 'slideUp',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Подъём'),
          subtitle: tr('Новая нода поднимается снизу, старая уходит вверх'),
        ),
        _RadioCard(
          value: 'zoom',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Масштаб'),
          subtitle: tr('Новая нода вырастает из мелкого масштаба'),
        ),
        _RadioCard(
          value: 'blur',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Размытие'),
          subtitle: tr('Старая нода уходит в размытие, новая проявляется резкой'),
        ),
        _RadioCard(
          value: 'wipe',
          groupValue: _nodeTransitionMode,
          onChanged: (v) => setState(() {
            _nodeTransitionMode = v!;
            _isDirty = true;
          }),
          title: tr('Шторка'),
          subtitle: tr('Новая нода открывается слева направо'),
        ),

        const SizedBox(height: 24),
        _SectionTitle(
          title: tr('Движок скриптов'),
          subtitle: tr('Совместимость и обработка ошибок'),
        ),
        const SizedBox(height: 8),
        _RadioCard(
          value: kScriptEngineModeNew,
          groupValue: _scriptEngineMode,
          onChanged: null, // только новый режим
          title: tr('Новый (совместимость)'),
          subtitle: tr('Включает новые фиксы и fallback для битых onAppear-target'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  //  Tab 3: Медиа
  // ---------------------------------------------------------------------------

  Widget _buildMediaTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
      children: [
        _SectionTitle(
          title: tr('Аудио'),
          subtitle: tr('Поведение музыки и звуков во время игры'),
        ),
        const SizedBox(height: 12),
        _buildSwitchCard(
          title: tr('Музыка при сворачивании'),
          subtitle:
              tr('Продолжать ли играть музыку, когда приложение свёрнуто. По умолчанию музыка ставится на паузу.'),
          value: _musicInBackground,
          onChanged: (v) => setState(() {
            _musicInBackground = v;
            _isDirty = true;
          }),
        ),
        const SizedBox(height: 24),
        _SectionTitle(
          title: tr('Скриншоты'),
          subtitle: tr('Покажите игроку, как выглядит ваш квест'),
        ),
        const SizedBox(height: 12),
        _buildScreenshotsManager(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  //  PRIMITIVES
  // ---------------------------------------------------------------------------

  Widget _buildCoverEditor(Quest? quest) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _pickPreviewImage,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_newPreviewFile != null)
                Image.file(_newPreviewFile!, fit: BoxFit.cover)
              else if (quest?.localPreviewPath != null)
                Image.file(
                  File(quest!.localPreviewPath!),
                  key: ValueKey(quest.localPreviewPath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _coverPlaceholder(scheme),
                )
              else
                _coverPlaceholder(scheme),

              // Кнопка-кружок «редактировать»
              Positioned(
                bottom: 12,
                right: 12,
                child: Material(
                  color: Colors.black.withOpacity(0.5),
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: _pickPreviewImage,
                    customBorder: const CircleBorder(),
                    child: const SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(
                        Icons.edit_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.primaryContainer.withOpacity(0.5),
            scheme.tertiaryContainer.withOpacity(0.5),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.add_photo_alternate_outlined,
          size: 48,
          color: scheme.onPrimaryContainer.withOpacity(0.6),
        ),
      ),
    );
  }

  Widget _styledField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    int maxLines = 1,
    String? Function(String?)? validator,
    String? hintText,
    Widget? suffixIcon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        prefixIcon: Icon(icon, size: 20),
        suffixIcon: suffixIcon,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildGenreSelector() {
    final scheme = Theme.of(context).colorScheme;
    final query = _genreQuery.trim().toLowerCase();
    // Выбранные жанры держим сверху: иначе после поиска чип, который нужно
    // снять, уезжает в невидимую часть списка.
    final rest = kQuestGenreIds
        .where((id) => !_selectedGenres.contains(id))
        .where(
          (id) => query.isEmpty ||
              genreLabel(id).toLowerCase().contains(query),
        )
        .toList()
      ..sort(
        (a, b) =>
            genreLabel(a).toLowerCase().compareTo(genreLabel(b).toLowerCase()),
      );
    final visible = <String>[..._selectedGenres, ...rest];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _genreSearch,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  hintText: tr('Найти жанр'),
                  suffixIcon: _genreQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: tr('Очистить'),
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _genreSearch.clear();
                            setState(() => _genreQuery = '');
                          },
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${_selectedGenres.length}/3',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: visible.map((id) {
            final isSelected = _selectedGenres.contains(id);
            return FilterChip(
              avatar: isSelected ? null : Icon(genreIcon(id), size: 16),
              label: Text(genreLabel(id)),
              selected: isSelected,
              onSelected: (selected) {
                setState(() {
                  if (selected) {
                    if (_selectedGenres.length < 3) {
                      _selectedGenres.add(id);
                    } else {
                      _showSnack(tr('Максимум 3 жанра'), warning: true);
                    }
                  } else {
                    _selectedGenres.remove(id);
                  }
                  _isDirty = true;
                });
              },
            );
          }).toList(),
        ),
        if (visible.isEmpty && query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              trf('Ничего не найдено по запросу «{p0}».', {'p0': _genreQuery}),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
      ],
    );
  }

  Widget _buildResourceSelector({
    required String label,
    required String? selectedResourceName,
    required VoidCallback onTap,
    required VoidCallback onClear,
    IconData icon = Icons.image_outlined,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: scheme.onSurfaceVariant, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      selectedResourceName ?? tr('Не выбрано'),
                      style: TextStyle(
                        color: selectedResourceName != null
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant.withOpacity(0.7),
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (selectedResourceName != null)
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  color: scheme.onSurfaceVariant,
                  onPressed: onClear,
                  tooltip: tr('Очистить'),
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant.withOpacity(0.5),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchCard({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: SwitchListTile(
          value: value,
          onChanged: onChanged,
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
        ),
      ),
    );
  }

  Widget _buildScreenshotsManager() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 130,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _AddScreenshotButton(
                isLoading: _isProcessingScreenshot,
                onTap: _addScreenshot,
              ),
              ..._localScreenshots.map(
                (fileName) => FutureBuilder<String>(
                  future: FileStorage.getFilePath(
                    QuestPaths.resScreenshot(widget.questId, fileName),
                  ),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const SizedBox.shrink();
                    return _ScreenshotTile(
                      filePath: snapshot.data!,
                      onDelete: () => _deleteScreenshot(fileName),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
//  PRIMITIVES (вынесены наружу для переиспользования)
// ============================================================================

class _SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _SectionTitle({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
            ),
          ),
      ],
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: scheme.onSurfaceVariant, size: 18),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: scheme.onSurfaceVariant.withOpacity(0.5),
        ),
        onTap: onTap,
      ),
    );
  }
}

class _RadioCard extends StatelessWidget {
  final String value;
  final String groupValue;
  final ValueChanged<String?>? onChanged;
  final String title;
  final String subtitle;

  const _RadioCard({
    required this.value,
    required this.groupValue,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = value == groupValue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withOpacity(0.5)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: RadioListTile<String>(
          value: value,
          groupValue: groupValue,
          onChanged: onChanged,
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 2,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  SCREENSHOTS
// ============================================================================

class _AddScreenshotButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onTap;

  const _AddScreenshotButton({required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isLoading ? null : onTap,
          child: SizedBox(
            width: 130,
            child: Center(
              child: isLoading
                  ? SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_a_photo_rounded,
                          color: scheme.onSurfaceVariant,
                          size: 28,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tr('Добавить'),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
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

class _ScreenshotTile extends StatelessWidget {
  final String filePath;
  final VoidCallback onDelete;

  const _ScreenshotTile({required this.filePath, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: SizedBox(
        width: 130,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.file(File(filePath), fit: BoxFit.cover),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Material(
                  color: Colors.black.withOpacity(0.55),
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: onDelete,
                    customBorder: const CircleBorder(),
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
