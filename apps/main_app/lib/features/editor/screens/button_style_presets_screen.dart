import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:mnd_player/services/font_service.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/features/editor/screens/button_style_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/archive_entry_paths.dart';
import 'package:canvas_app/core/utils/error_text.dart';

// План 020-C4.5: операции над квестом — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};

class ButtonStylePresetsScreen extends StatefulWidget {
  final String questId;
  const ButtonStylePresetsScreen({super.key, required this.questId});

  @override
  State<ButtonStylePresetsScreen> createState() =>
      _ButtonStylePresetsScreenState();
}

class _ButtonStylePresetsScreenState extends State<ButtonStylePresetsScreen> {
  final TextEditingController _presetNameController = TextEditingController();
  List<ButtonStyleConfig> _presets = [];
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isDirty = false;

  String? _presetCornerAsset;
  String? _presetHAsset;
  String? _presetVAsset;
  String? _presetCenterAsset;
  final Map<String, String> _presetAssetLabels = {};
  Map<String, dynamic> _metadata = {};
  double _presetModuleSize = 12.0;
  int _presetHorizontalModules = 6;
  int _presetVerticalModules = 3;
  int _presetCenterModules = 10;
  bool _presetAutoCenterByText = true;

  // Параметры, редактируемые через ButtonStyleEditorScreen (план: основные
  // кнопки тоже кастомизируемы).
  int _presetFillColorValue = 0xFF1A2336;
  int _presetBorderColorValue = 0xFF26C6DA;
  int _presetTextColorValue = 0xFFFFFFFF;
  double? _presetTextSize;
  int? _presetTextWeight;
  double? _presetLetterSpacing;
  String? _presetFontFamily;
  double? _presetBorderRadius;
  double? _presetBorderWidth;
  double? _presetFillOpacity;
  bool _presetUseGradient = false;
  int? _presetGradientStartColorValue;
  int? _presetGradientEndColorValue;
  String? _presetGradientDirection;
  int? _presetShadowColorValue;
  double? _presetShadowOpacity;
  double? _presetShadowBlur;
  double? _presetShadowOffsetX;
  double? _presetShadowOffsetY;
  double? _presetPaddingH;
  double? _presetPaddingV;

  String get _configPath => QuestPaths.config(widget.questId);

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _presetNameController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      _metadata = await _readMetadata();
      final config = await _readMap(_configPath);
      _presets = _readButtonStylePresets(config);
      _warmAssetLabels();
    } catch (_) {
      _presets = [];
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _warmAssetLabels() {
    for (final preset in _presets) {
      for (final path in [
        preset.cornerAsset,
        preset.hAsset,
        preset.vAsset,
        preset.centerAsset,
      ]) {
        if (path == null || path.trim().isEmpty) continue;
        _presetAssetLabels[path] = _resolveFriendlyResourceName(
          rawIdOrPath: path,
          metadata: _metadata,
        );
      }
    }
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

  Future<Map<String, dynamic>> _readMetadata() async {
    final path = QuestPaths.metadata(widget.questId);
    if (!await (await _qs()).exists(path)) return {};
    return _readMap(path);
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

  Future<void> _pickPresetModuleAsset(_ModuleAssetType type) async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    if (result == null || !mounted) return;

    final label = _resolveFriendlyResourceName(
      rawIdOrPath: result.path,
      metadata: _metadata,
    );
    await _warnIfLargeModuleAsset(result.path);
    if (!mounted) return;

    setState(() {
      switch (type) {
        case _ModuleAssetType.corner:
          _presetCornerAsset = result.path;
          break;
        case _ModuleAssetType.horizontal:
          _presetHAsset = result.path;
          break;
        case _ModuleAssetType.vertical:
          _presetVAsset = result.path;
          break;
        case _ModuleAssetType.center:
          _presetCenterAsset = result.path;
          break;
      }
      _presetAssetLabels[result.path] = label;
      _isDirty = true;
    });
  }

  Future<ui.Size?> _readAssetSize(String relativePath) async {
    try {
      final fullPath = await FileStorage.getFilePath(
        QuestPaths.questFile(widget.questId, relativePath),
      );
      final bytes = await File(fullPath).readAsBytes();
      final completer = Completer<ui.Size?>();
      ui.decodeImageFromList(bytes, (image) {
        final size = ui.Size(image.width.toDouble(), image.height.toDouble());
        image.dispose();
        completer.complete(size);
      });
      // await: без него TimeoutException уходит мимо catch (_) — и вместо
      // «не знаю размер, молча пропускаю» получаем непойманную ошибку.
      return await completer.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  Future<void> _warnIfLargeModuleAsset(String relativePath) async {
    final size = await _readAssetSize(relativePath);
    if (size == null || !mounted) return;
    if (size.width <= 32 && size.height <= 32) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.orange.shade700,
        content: Text(
          trf('Модуль {p0}x{p1}px. Рекомендуется не больше 32x32px и без сложных текстур.', {'p0': size.width.toInt(), 'p1': size.height.toInt()}),
        ),
      ),
    );
  }

  String _assetLabel(String? path) {
    if (path == null || path.trim().isEmpty) return tr('Не выбрано');
    final cached = _presetAssetLabels[path];
    if (cached != null) return cached;
    if (_metadata.isNotEmpty) {
      final resolved = _resolveFriendlyResourceName(
        rawIdOrPath: path,
        metadata: _metadata,
      );
      _presetAssetLabels[path] = resolved;
      return resolved;
    }
    return p.basename(path);
  }

  void _clearPresetDraft() {
    _presetNameController.clear();
    _presetCornerAsset = null;
    _presetHAsset = null;
    _presetVAsset = null;
    _presetCenterAsset = null;
    _presetModuleSize = 12.0;
    _presetHorizontalModules = 6;
    _presetVerticalModules = 3;
    _presetCenterModules = 10;
    _presetAutoCenterByText = true;
    _presetFillColorValue = 0xFF1A2336;
    _presetBorderColorValue = 0xFF26C6DA;
    _presetTextColorValue = 0xFFFFFFFF;
    _presetTextSize = null;
    _presetTextWeight = null;
    _presetLetterSpacing = null;
    _presetFontFamily = null;
    _presetBorderRadius = null;
    _presetBorderWidth = null;
    _presetFillOpacity = null;
    _presetUseGradient = false;
    _presetGradientStartColorValue = null;
    _presetGradientEndColorValue = null;
    _presetGradientDirection = null;
    _presetShadowColorValue = null;
    _presetShadowOpacity = null;
    _presetShadowBlur = null;
    _presetShadowOffsetX = null;
    _presetShadowOffsetY = null;
    _presetPaddingH = null;
    _presetPaddingV = null;
  }

  void _loadPresetDraft(ButtonStyleConfig preset) {
    setState(() {
      _presetNameController.text = preset.presetName?.trim().isNotEmpty == true
          ? preset.presetName!.trim()
          : preset.presetId;
      _presetCornerAsset = preset.cornerAsset;
      _presetHAsset = preset.hAsset;
      _presetVAsset = preset.vAsset;
      _presetCenterAsset = preset.centerAsset;
      _presetModuleSize = preset.moduleSize;
      _presetHorizontalModules = preset.horizontalModules;
      _presetVerticalModules = preset.verticalModules;
      _presetCenterModules = preset.centerModules;
      _presetAutoCenterByText = preset.autoCenterByText;
      _presetFillColorValue = preset.fillColorValue;
      _presetBorderColorValue = preset.borderColorValue;
      _presetTextColorValue = preset.textColorValue;
      _presetTextSize = preset.textSize;
      _presetTextWeight = preset.textWeight;
      _presetLetterSpacing = preset.letterSpacing;
      _presetFontFamily = preset.fontFamily;
      _presetBorderRadius = preset.borderRadius;
      _presetBorderWidth = preset.borderWidth;
      _presetFillOpacity = preset.fillOpacity;
      _presetUseGradient = preset.useGradient;
      _presetGradientStartColorValue = preset.gradientStartColorValue;
      _presetGradientEndColorValue = preset.gradientEndColorValue;
      _presetGradientDirection = preset.gradientDirection;
      _presetShadowColorValue = preset.shadowColorValue;
      _presetShadowOpacity = preset.shadowOpacity;
      _presetShadowBlur = preset.shadowBlur;
      _presetShadowOffsetX = preset.shadowOffsetX;
      _presetShadowOffsetY = preset.shadowOffsetY;
      _presetPaddingH = preset.paddingH;
      _presetPaddingV = preset.paddingV;
      _isDirty = true;
    });
  }

  void _savePresetDraft() {
    final name = _presetNameController.text.trim();
    if (name.isEmpty) {
      _showSnack(tr('Введите название пресета'));
      return;
    }
    // Модульные ассеты не обязательны: пресет может быть плоским стилем
    // (цвета/текст/форма/тень) — «кастомные кнопки» и обычные кнопки теперь
    // разделяют один механизм пресетов.
    final presetId =
        'customPreset:${name.toLowerCase().replaceAll(RegExp(r"\\s+"), "_")}';
    final preset = ButtonStyleConfig(
      presetId: presetId,
      presetName: name,
      horizontalModules: _presetHorizontalModules,
      verticalModules: _presetVerticalModules,
      centerModules: _presetCenterModules,
      moduleSize: _presetModuleSize,
      autoCenterByText: _presetAutoCenterByText,
      fillColorValue: _presetFillColorValue,
      borderColorValue: _presetBorderColorValue,
      textColorValue: _presetTextColorValue,
      cornerAsset: _presetCornerAsset,
      hAsset: _presetHAsset,
      vAsset: _presetVAsset,
      centerAsset: _presetCenterAsset,
      textSize: _presetTextSize,
      textWeight: _presetTextWeight,
      letterSpacing: _presetLetterSpacing,
      fontFamily: _presetFontFamily,
      borderRadius: _presetBorderRadius,
      borderWidth: _presetBorderWidth,
      fillOpacity: _presetFillOpacity,
      useGradient: _presetUseGradient,
      gradientStartColorValue: _presetGradientStartColorValue,
      gradientEndColorValue: _presetGradientEndColorValue,
      gradientDirection: _presetGradientDirection,
      shadowColorValue: _presetShadowColorValue,
      shadowOpacity: _presetShadowOpacity,
      shadowBlur: _presetShadowBlur,
      shadowOffsetX: _presetShadowOffsetX,
      shadowOffsetY: _presetShadowOffsetY,
      paddingH: _presetPaddingH,
      paddingV: _presetPaddingV,
    );

    setState(() {
      final next = List<ButtonStyleConfig>.from(_presets);
      final index = next.indexWhere((p) => p.presetName == name);
      if (index >= 0) {
        next[index] = preset;
      } else {
        next.add(preset);
      }
      _presets = next;
      _clearPresetDraft();
      _isDirty = true;
    });
  }

  Future<void> _saveChanges() async {
    if (_isSaving || !_isDirty) return;
    setState(() => _isSaving = true);
    try {
      final config = await _readMap(_configPath);
      config['buttonStylePresets'] = _presets
          .map((preset) => preset.toJson())
          .toList();
      await (await _qs()).writeJson(_configPath, config);
      if (mounted) {
        setState(() => _isDirty = false);
        _showSnack(tr('Пресеты сохранены'));
      }
    } catch (e) {
      _showSnack(trf('Ошибка сохранения: {p0}', {'p0': friendlyError(e)}));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _exportPresets() async {
    if (_presets.isEmpty) {
      _showSnack(tr('Нет пресетов для экспорта'));
      return;
    }

    final payload = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'presets': _presets.map((p) => p.toJson()).toList(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(payload);
    final archive = Archive();
    final jsonBytes = utf8.encode(content);
    archive.addFile(ArchiveFile('presets.json', jsonBytes.length, jsonBytes));

    final assetPaths = _collectPresetAssetPaths();
    int missingAssets = 0;
    for (final rawPath in assetPaths) {
      final normalized = _normalizeAssetPath(rawPath);
      if (normalized.isEmpty) continue;
      final fullPath = await FileStorage.getFilePath(
        QuestPaths.questFile(widget.questId, normalized),
      );
      final file = File(fullPath);
      if (!await file.exists()) {
        missingAssets++;
        continue;
      }
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(normalized, bytes.length, bytes));
    }

    final zipData = ZipEncoder().encode(archive);
    final fileName = 'button_presets_${widget.questId}.zip';

    try {
      if (kIsWeb ||
          Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS) {
        final result = await FilePicker.saveFile(
          dialogTitle: tr('Экспорт пресетов кнопок'),
          fileName: fileName,
          bytes: Uint8List.fromList(zipData),
          type: FileType.custom,
          allowedExtensions: const ['zip'],
        );
        if (result == null) return;
        final msg = missingAssets > 0
            ? trf('Экспорт готов, пропущено текстур: {p0}', {'p0': missingAssets})
            : tr('Экспорт готов');
        _showSnack(msg);
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final tempFilePath = p.join(tempDir.path, fileName);
      final tempFile = File(tempFilePath);
      await tempFile.writeAsBytes(zipData);

      final params = SaveFileDialogParams(
        sourceFilePath: tempFile.path,
        fileName: fileName,
      );
      final result = await FlutterFileDialog.saveFile(params: params);
      await tempFile.delete();
      if (result != null) {
        final msg = missingAssets > 0
            ? trf('Экспорт готов, пропущено текстур: {p0}', {'p0': missingAssets})
            : tr('Экспорт готов');
        _showSnack(msg);
      }
    } catch (e) {
      _showSnack(trf('Ошибка экспорта: {p0}', {'p0': friendlyError(e)}));
    }
  }

  Future<void> _importPresets() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip', 'json'],
      );
      if (files.isEmpty) return;

      final file = files.single;
      final bytes = await file.readAsBytes();
      final extension = p.extension(file.name).toLowerCase();

      if (extension == '.zip') {
        await _importFromZip(bytes);
        return;
      }

      final content = utf8.decode(bytes);
      await _importFromJson(content);
    } catch (e) {
      _showSnack(trf('Ошибка импорта: {p0}', {'p0': friendlyError(e)}));
    }
  }

  Future<void> _importFromZip(List<int> bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? jsonFile;
    for (final file in archive) {
      if (!file.isFile) continue;
      final name = file.name.toLowerCase();
      if (name.endsWith('presets.json')) {
        jsonFile = file;
        break;
      }
      if (name.endsWith('.json') && jsonFile == null) {
        jsonFile = file;
      }
    }

    if (jsonFile == null) {
      _showSnack(tr('В архиве нет пресетов'));
      return;
    }

    final jsonContent = utf8.decode(_archiveFileBytes(jsonFile));
    final result = _parsePresetsJson(jsonContent);
    if (result.presets.isEmpty) {
      _showSnack(tr('Подходящих пресетов не найдено'));
      return;
    }

    int importedAssets = 0;
    int skippedAssets = 0;
    for (final file in archive) {
      if (!file.isFile) continue;
      if (file == jsonFile) continue;
      // Имя записи архива — недоверенный ввод: `../<чужой квест>/config.json`
      // писал бы в чужую папку квеста.
      final normalized = sanitizeArchiveEntryPath(file.name);
      if (normalized == null) continue;
      final targetPath = await FileStorage.getFilePath(
        QuestPaths.questFile(widget.questId, normalized),
      );
      final target = File(targetPath);
      if (await target.exists()) {
        skippedAssets++;
        continue;
      }
      await target.parent.create(recursive: true);
      await target.writeAsBytes(_archiveFileBytes(file));
      importedAssets++;
    }

    _applyImportedPresets(result.presets);
    _showSnack(
      trf('Импортировано пресетов: {p0}, текстур: {p1}, пропущено текстур: {p2}', {
        'p0': result.presets.length,
        'p1': importedAssets,
        'p2': skippedAssets,
      }),
    );
  }

  Future<void> _importFromJson(String content) async {
    if (content.trim().isEmpty) {
      _showSnack(tr('Файл пустой'));
      return;
    }
    final result = _parsePresetsJson(content);
    if (result.presets.isEmpty) {
      _showSnack(tr('Подходящих пресетов не найдено'));
      return;
    }
    _applyImportedPresets(result.presets);
    final msg = result.skipped > 0
        ? trf('Импортировано: {p0}, пропущено: {p1}', {'p0': result.presets.length, 'p1': result.skipped})
        : trf('Импортировано: {p0}', {'p0': result.presets.length});
    _showSnack(msg);
  }

  _PresetImportResult _parsePresetsJson(String content) {
    final decoded = jsonDecode(content);
    List<dynamic>? list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map<String, dynamic>) {
      if (decoded['presets'] is List) {
        list = decoded['presets'] as List<dynamic>;
      } else if (decoded['buttonStylePresets'] is List) {
        list = decoded['buttonStylePresets'] as List<dynamic>;
      }
    }

    if (list == null) return _PresetImportResult.empty();

    final imported = <ButtonStyleConfig>[];
    int skipped = 0;
    for (final item in list) {
      if (item is! Map) {
        skipped++;
        continue;
      }
      final map = Map<String, dynamic>.from(item);
      var cfg = ButtonStyleConfig.fromJson(map);
      var name = cfg.presetName?.trim();
      name ??= map['presetName']?.toString().trim();
      name ??= map['name']?.toString().trim();
      name ??= map['presetId']?.toString().trim();
      if (name == null || name.isEmpty) {
        skipped++;
        continue;
      }
      cfg = cfg.copyWith(
        presetName: name,
        presetId:
            'customPreset:${name.toLowerCase().replaceAll(RegExp(r"\\s+"), "_")}',
      );
      imported.add(cfg);
    }
    return _PresetImportResult(presets: imported, skipped: skipped);
  }

  void _applyImportedPresets(List<ButtonStyleConfig> imported) {
    final byName = <String, ButtonStyleConfig>{
      for (final preset in _presets)
        if (preset.presetName?.trim().isNotEmpty ?? false)
          preset.presetName!.trim(): preset,
    };
    for (final preset in imported) {
      final key = preset.presetName!.trim();
      byName[key] = preset;
    }

    final next = byName.values.toList()
      ..sort(
        (a, b) =>
            a.presetName!.toLowerCase().compareTo(b.presetName!.toLowerCase()),
      );

    if (!mounted) return;
    setState(() {
      _presets = next;
      _isDirty = true;
    });
  }

  List<int> _archiveFileBytes(ArchiveFile file) {
    return List<int>.from(file.content as List);
  }

  Set<String> _collectPresetAssetPaths() {
    final paths = <String>{};
    for (final preset in _presets) {
      for (final path in [
        preset.cornerAsset,
        preset.hAsset,
        preset.vAsset,
        preset.centerAsset,
      ]) {
        if (path == null || path.trim().isEmpty) continue;
        paths.add(path.trim());
      }
    }
    return paths;
  }

  String _normalizeAssetPath(String rawPath) {
    var normalized = rawPath.replaceAll('\\', '/').trim();
    normalized = normalized.replaceAll(RegExp(r'^/+'), '');
    return normalized;
  }

  Future<bool> _confirmDiscardChanges() async {
    if (!_isDirty) return true;
    final shouldDiscard = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(
          tr('Несохраненные изменения'),
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          tr('Выйти без сохранения пресетов?'),
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Выйти'), style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return shouldDiscard ?? false;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  ButtonStyleConfig _buildDraftStyle() {
    return ButtonStyleConfig(
      presetId: 'draft',
      presetName: _presetNameController.text.trim().isEmpty
          ? tr('Черновик')
          : _presetNameController.text.trim(),
      horizontalModules: _presetHorizontalModules,
      verticalModules: _presetVerticalModules,
      centerModules: _presetCenterModules,
      moduleSize: _presetModuleSize,
      autoCenterByText: _presetAutoCenterByText,
      cornerAsset: _presetCornerAsset,
      hAsset: _presetHAsset,
      vAsset: _presetVAsset,
      centerAsset: _presetCenterAsset,
      fillColorValue: _presetFillColorValue,
      borderColorValue: _presetBorderColorValue,
      textColorValue: _presetTextColorValue,
      textSize: _presetTextSize,
      textWeight: _presetTextWeight,
      letterSpacing: _presetLetterSpacing,
      fontFamily: _presetFontFamily,
      borderRadius: _presetBorderRadius,
      borderWidth: _presetBorderWidth,
      fillOpacity: _presetFillOpacity,
      useGradient: _presetUseGradient,
      gradientStartColorValue: _presetGradientStartColorValue,
      gradientEndColorValue: _presetGradientEndColorValue,
      gradientDirection: _presetGradientDirection,
      shadowColorValue: _presetShadowColorValue,
      shadowOpacity: _presetShadowOpacity,
      shadowBlur: _presetShadowBlur,
      shadowOffsetX: _presetShadowOffsetX,
      shadowOffsetY: _presetShadowOffsetY,
      paddingH: _presetPaddingH,
      paddingV: _presetPaddingV,
    );
  }

  /// Открывает полный редактор параметров (цвета/текст/форма/тень/отступы)
  /// и переносит результат в черновик пресета, сохраняя модульные ассеты.
  Future<void> _openStyleParams() async {
    final edited = await Navigator.push<ButtonStyleConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => ButtonStyleEditorScreen(
          questId: widget.questId,
          initialStyle: _buildDraftStyle(),
        ),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() {
      _presetFillColorValue = edited.fillColorValue;
      _presetBorderColorValue = edited.borderColorValue;
      _presetTextColorValue = edited.textColorValue;
      _presetTextSize = edited.textSize;
      _presetTextWeight = edited.textWeight;
      _presetLetterSpacing = edited.letterSpacing;
      _presetFontFamily = edited.fontFamily;
      _presetBorderRadius = edited.borderRadius;
      _presetBorderWidth = edited.borderWidth;
      _presetFillOpacity = edited.fillOpacity;
      _presetUseGradient = edited.useGradient;
      _presetGradientStartColorValue = edited.gradientStartColorValue;
      _presetGradientEndColorValue = edited.gradientEndColorValue;
      _presetGradientDirection = edited.gradientDirection;
      _presetShadowColorValue = edited.shadowColorValue;
      _presetShadowOpacity = edited.shadowOpacity;
      _presetShadowBlur = edited.shadowBlur;
      _presetShadowOffsetX = edited.shadowOffsetX;
      _presetShadowOffsetY = edited.shadowOffsetY;
      _presetPaddingH = edited.paddingH;
      _presetPaddingV = edited.paddingV;
      _isDirty = true;
    });
    // Грузим шрифт, чтобы превью пресета показывало его сразу.
    final font = edited.fontFamily;
    if (font != null && font.trim().isNotEmpty) {
      await FontService.loadQuestFont(widget.questId, font);
    }
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: child,
    );
  }

  Widget _buildPresetSlot({
    required String title,
    required String? value,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            _assetLabel(value),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: value == null ? Colors.white38 : Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onPick,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: BorderSide(color: Colors.white.withOpacity(0.2)),
                  ),
                  child: Text(tr('Выбрать')),
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.close, color: Colors.white54),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPresetsList() {
    if (_presets.isEmpty) {
      return Text(
        tr('Пока нет сохранённых пресетов.'),
        style: TextStyle(color: Colors.white54, fontSize: 12),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _presets.map((preset) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                preset.presetName ?? preset.presetId,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.edit, size: 18),
                tooltip: tr('Редактировать'),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _loadPresetDraft(preset),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(
                  Icons.close,
                  size: 18,
                  color: Colors.redAccent,
                ),
                tooltip: tr('Удалить'),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  setState(() {
                    _presets = _presets
                        .where((p) => p.presetName != preset.presetName)
                        .toList();
                    _isDirty = true;
                  });
                },
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draftStyle = _buildDraftStyle();
    return PopScope(
      canPop: !_isDirty,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final shouldPop = await _confirmDiscardChanges();
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          title: Text(tr('Кастомные кнопки')),
          backgroundColor: const Color(0xFF121212),
          actions: [
            IconButton(
              tooltip: tr('Импорт'),
              onPressed: _importPresets,
              icon: const Icon(Icons.file_upload_outlined),
            ),
            IconButton(
              tooltip: tr('Экспорт'),
              onPressed: _exportPresets,
              icon: const Icon(Icons.file_download_outlined),
            ),
            TextButton(
              onPressed: _isDirty && !_isSaving ? _saveChanges : null,
              child: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF00C853),
                      ),
                    )
                  : Text(
                      tr('Сохранить'),
                      style: TextStyle(color: Color(0xFF00C853)),
                    ),
            ),
          ],
        ),
        body: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF00C853)),
              )
            : AdaptiveContent(
                maxWidth: 760,
                child: SafeArea(
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        tr('Пресеты кнопок'),
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  tr('Сохранённые пресеты'),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  trf('Всего: {p0}', {'p0': _presets.length}),
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _buildPresetsList(),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _importPresets,
                              icon: const Icon(Icons.file_upload_outlined),
                              label: Text(tr('Импорт')),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _exportPresets,
                              icon: const Icon(Icons.file_download_outlined),
                              label: Text(tr('Экспорт ZIP')),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white10),
                      const SizedBox(height: 12),
                      _buildCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  tr('Новый пресет'),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                TextButton(
                                  onPressed: () => setState(() {
                                    _clearPresetDraft();
                                    _isDirty = true;
                                  }),
                                  child: Text(tr('Сбросить')),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _presetNameController,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: tr('Название пресета'),
                                labelStyle: const TextStyle(
                                  color: Colors.white70,
                                ),
                                filled: true,
                                fillColor: const Color(0xFF151515),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onChanged: (_) => setState(() => _isDirty = true),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              tr('Рекомендуется: до 32x32 px, сплошные/простые модули без сложных текстур, чтобы избежать швов.'),
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Slider(
                                    value: _presetModuleSize,
                                    min: 6,
                                    max: 32,
                                    divisions: 26,
                                    onChanged: (value) => setState(() {
                                      _presetModuleSize = value;
                                      _isDirty = true;
                                    }),
                                  ),
                                ),
                                Text(
                                  trf('Модуль: {p0}', {'p0': _presetModuleSize.toStringAsFixed(0)}),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            _PresetStepper(
                              label: tr('Горизонт'),
                              value: _presetHorizontalModules,
                              min: 2,
                              max: 20,
                              onChanged: (value) => setState(() {
                                _presetHorizontalModules = value;
                                _isDirty = true;
                              }),
                            ),
                            const SizedBox(height: 6),
                            _PresetStepper(
                              label: tr('Вертикаль'),
                              value: _presetVerticalModules,
                              min: 2,
                              max: 10,
                              onChanged: (value) => setState(() {
                                _presetVerticalModules = value;
                                _isDirty = true;
                              }),
                            ),
                            const SizedBox(height: 6),
                            _PresetStepper(
                              label: tr('Центр'),
                              value: _presetCenterModules,
                              min: 4,
                              max: 30,
                              onChanged: (value) => setState(() {
                                _presetCenterModules = value;
                                _isDirty = true;
                              }),
                            ),
                            SwitchListTile(
                              value: _presetAutoCenterByText,
                              onChanged: (value) => setState(() {
                                _presetAutoCenterByText = value;
                                _isDirty = true;
                              }),
                              activeColor: const Color(0xFF00C853),
                              title: Text(
                                tr('Автокомпоновка центра по тексту'),
                                style: TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                tr('Размер центрального модуля подстраивается под длину текста.'),
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                              contentPadding: EdgeInsets.zero,
                            ),
                            const SizedBox(height: 10),
                            _buildPresetSlot(
                              title: tr('Угловой модуль'),
                              value: _presetCornerAsset,
                              onPick: () => _pickPresetModuleAsset(
                                _ModuleAssetType.corner,
                              ),
                              onClear: () => setState(() {
                                _presetCornerAsset = null;
                                _isDirty = true;
                              }),
                            ),
                            const SizedBox(height: 8),
                            _buildPresetSlot(
                              title: tr('Горизонтальный модуль'),
                              value: _presetHAsset,
                              onPick: () => _pickPresetModuleAsset(
                                _ModuleAssetType.horizontal,
                              ),
                              onClear: () => setState(() {
                                _presetHAsset = null;
                                _isDirty = true;
                              }),
                            ),
                            const SizedBox(height: 8),
                            _buildPresetSlot(
                              title: tr('Вертикальный модуль'),
                              value: _presetVAsset,
                              onPick: () => _pickPresetModuleAsset(
                                _ModuleAssetType.vertical,
                              ),
                              onClear: () => setState(() {
                                _presetVAsset = null;
                                _isDirty = true;
                              }),
                            ),
                            const SizedBox(height: 8),
                            _buildPresetSlot(
                              title: tr('Центральный модуль'),
                              value: _presetCenterAsset,
                              onPick: () => _pickPresetModuleAsset(
                                _ModuleAssetType.center,
                              ),
                              onClear: () => setState(() {
                                _presetCenterAsset = null;
                                _isDirty = true;
                              }),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _openStyleParams,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: BorderSide(
                                    color: Colors.white.withOpacity(0.2),
                                  ),
                                ),
                                icon: const Icon(Icons.tune_rounded, size: 18),
                                label: Text(tr('Цвета, текст, форма, тень')),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              tr('Предпросмотр'),
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _QuestModuleButtonPreview(
                              questId: widget.questId,
                              style: draftStyle,
                              text: draftStyle.presetName ?? tr('Пример текста'),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _savePresetDraft,
                                    icon: const Icon(Icons.save),
                                    label: Text(tr('Сохранить пресет')),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF00C853),
                                      foregroundColor: Colors.black,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _PresetImportResult {
  final List<ButtonStyleConfig> presets;
  final int skipped;

  const _PresetImportResult({required this.presets, required this.skipped});

  factory _PresetImportResult.empty() =>
      const _PresetImportResult(presets: [], skipped: 0);
}

enum _ModuleAssetType { corner, horizontal, vertical, center }

class _PresetStepper extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _PresetStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        IconButton(
          onPressed: value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
          color: Colors.white70,
        ),
        Text(
          value.toString(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        IconButton(
          onPressed: value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline),
          color: Colors.white70,
        ),
      ],
    );
  }
}

class _QuestModuleButtonPreview extends StatelessWidget {
  final String questId;
  final ButtonStyleConfig style;
  final String text;

  const _QuestModuleButtonPreview({
    required this.questId,
    required this.style,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    if (!style.hasModuleAssets) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF151515),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Text(
          tr('Нужно выбрать 4 модуля'),
          style: TextStyle(color: Colors.white60),
        ),
      );
    }

    final module = style.moduleSize.clamp(10.0, 24.0);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: _TileImage(questId: questId, path: style.centerAsset!),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: module,
            child: _TileImage(
              questId: questId,
              path: style.hAsset!,
              repeat: ImageRepeat.repeatX,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: module,
            child: Transform.rotate(
              angle: 3.1415926535,
              child: _TileImage(
                questId: questId,
                path: style.hAsset!,
                repeat: ImageRepeat.repeatX,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: module,
            child: _TileImage(
              questId: questId,
              path: style.vAsset!,
              repeat: ImageRepeat.repeatY,
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: module,
            child: Transform.rotate(
              angle: 3.1415926535,
              child: _TileImage(
                questId: questId,
                path: style.vAsset!,
                repeat: ImageRepeat.repeatY,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            width: module,
            height: module,
            child: _TileImage(questId: questId, path: style.cornerAsset!),
          ),
          Positioned(
            right: 0,
            top: 0,
            width: module,
            height: module,
            child: Transform.rotate(
              angle: 1.5707963267,
              child: _TileImage(questId: questId, path: style.cornerAsset!),
            ),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            width: module,
            height: module,
            child: Transform.rotate(
              angle: -1.5707963267,
              child: _TileImage(questId: questId, path: style.cornerAsset!),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            width: module,
            height: module,
            child: Transform.rotate(
              angle: 3.1415926535,
              child: _TileImage(questId: questId, path: style.cornerAsset!),
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: module * 1.2,
              vertical: module * 0.9,
            ),
            alignment: Alignment.center,
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 18,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TileImage extends StatelessWidget {
  final String questId;
  final String path;
  final ImageRepeat repeat;

  const _TileImage({
    required this.questId,
    required this.path,
    this.repeat = ImageRepeat.noRepeat,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      // Резолвер библиотеки: в пресете текстуру можно указать именем файла,
      // а не точным путём — превью должно показывать то же, что плеер.
      future: QuestImageSource.resolve(questId, path),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) {
          return Container(color: Colors.white.withOpacity(0.03));
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: FileImage(file),
              fit: repeat == ImageRepeat.noRepeat ? BoxFit.cover : BoxFit.fill,
              repeat: repeat,
            ),
          ),
        );
      },
    );
  }
}
