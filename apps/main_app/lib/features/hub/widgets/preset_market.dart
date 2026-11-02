import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/models/user_profile_model.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Пресет одного квеста для отображения в списке маркета пресетов.
class QuestPresetEntry {
  final String questId;
  final String questTitle;
  final String presetId;
  final String presetName;
  final ButtonStyleConfig config;

  /// true — пресет создан в своём квесте, false — квест пришёл из маркета
  /// (или его автор — не текущий пользователь), значит пресет чужой.
  final bool isOwn;

  /// Автор квеста-источника из config.json (может быть null у своих квестов).
  final String? authorId;

  /// Имя автора квеста-источника (config.json → 'author'). Есть почти у всех
  /// квестов, в отличие от authorId, и служит надёжной сверкой «свой/чужой».
  final String? authorName;

  const QuestPresetEntry({
    required this.questId,
    required this.questTitle,
    required this.presetId,
    required this.presetName,
    required this.config,
    this.isOwn = true,
    this.authorId,
    this.authorName,
  });
}

/// Список пресетов из всех квестов (каждый config.json → buttonStylePresets).
final allQuestPresetsProvider =
    FutureProvider.autoDispose<List<QuestPresetEntry>>((ref) async {
      final appDir = await FileStorage.getAppDirectory();
      final questsDir = Directory(p.join(appDir.path, QuestPaths.questsDir));
      if (!await questsDir.exists()) return const [];

      final prefs = await SharedPreferences.getInstance();
      final currentUserId = (prefs.getString('user_id') ?? '').trim();

      final result = <QuestPresetEntry>[];
      for (final entity in questsDir.listSync()) {
        if (entity is! Directory) continue;
        final questId = p.basename(entity.path);
        if (questId.isEmpty) continue;
        try {
          final configFile = File(p.join(entity.path, 'config.json'));
          if (!await configFile.exists()) continue;
          final decoded = jsonDecode(await configFile.readAsString());
          if (decoded is! Map<String, dynamic>) continue;

          final questTitle = (decoded['title']?.toString() ?? '').trim().isEmpty
              ? questId
              : decoded['title'].toString();

          // Квест из маркета помечен marketQuestId / isMarketDownloaded — его
          // пресеты созданы другим автором, публиковать их от своего имени
          // нельзя. Дополнительно запоминаем автора квеста: если он не совпадёт
          // с текущим пользователем, пресет тоже считается чужим (страховка
          // для квестов, установленных мимо маркета — вручную из ZIP).
          final marketQuestId = (decoded['marketQuestId']?.toString() ?? '')
              .trim();
          final cameFromMarket =
              decoded['isMarketDownloaded'] == true || marketQuestId.isNotEmpty;
          final authorId = (decoded['authorId']?.toString() ?? '').trim();
          // Свой только если квест не из маркета и его автор — не кто-то
          // другой (для квестов, установленных мимо маркета, вручную из ZIP).
          // Если пользователь не залогинен, автора сверить не с чем — тогда
          // доверяем только флагам квеста.
          final isOwn =
              !cameFromMarket &&
              (authorId.isEmpty ||
                  currentUserId.isEmpty ||
                  authorId == currentUserId);
          final authorName = (decoded['author']?.toString() ?? '').trim();

          final rawPresets = decoded['buttonStylePresets'];
          if (rawPresets is! List) continue;
          for (final item in rawPresets) {
            if (item is! Map) continue;
            final cfg = ButtonStyleConfig.fromJson(
              Map<String, dynamic>.from(item),
            );
            final name = cfg.presetName?.trim();
            if (name == null || name.isEmpty) continue;
            result.add(
              QuestPresetEntry(
                questId: questId,
                questTitle: questTitle,
                presetId: cfg.presetId,
                presetName: name,
                config: cfg,
                isOwn: isOwn,
                authorId: authorId.isEmpty ? null : authorId,
                authorName: authorName.isEmpty ? null : authorName,
              ),
            );
          }
        } catch (_) {
          // квест с битым конфигом просто пропускаем
        }
      }
      // Свои пресеты — сверху, дальше по алфавиту: сразу видно, что публиковать
      // можно только первые, остальные пришли с чужими квестами.
      result.sort((a, b) {
        if (a.isOwn != b.isOwn) return a.isOwn ? -1 : 1;
        return a.presetName.toLowerCase().compareTo(b.presetName.toLowerCase());
      });
      return result;
    });

/// Профиль текущего пользователя (или null, если не залогинен/оффлайн).
/// Реактивен на логин/логаут: экраны, сверяющие «свой/чужой» пресет,
/// должны пересчитываться при смене пользователя.
final currentUserProfileProvider = FutureProvider.autoDispose<UserProfile?>((
  ref,
) async {
  final prefs = await SharedPreferences.getInstance();
  final userId = (prefs.getString('user_id') ?? '').trim();
  if (userId.isEmpty) return null;
  try {
    final api = ref.watch(apiServiceProvider);
    final data = await api.get('profiles/$userId');
    return UserProfile.fromJson(data);
  } catch (_) {
    return null;
  }
});

/// Сервис публикации/импорта пресетов кнопок (ZIP + presets.json внутри).
class PresetMarketService {
  /// Собрать ZIP: presets.json + файлы модулей (пути как в квесте).
  static Future<File> buildPresetZip({required QuestPresetEntry entry}) async {
    final archive = Archive();
    final payload = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'sourceQuest': entry.questTitle,
      'presets': [entry.config.toJson()],
    };
    final jsonBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    archive.addFile(ArchiveFile('presets.json', jsonBytes.length, jsonBytes));

    for (final path in _collectAssetPaths(entry.config)) {
      final normalized = _normalizePath(path);
      if (normalized.isEmpty) continue;
      final fullPath = await FileStorage.getFilePath(
        QuestPaths.isQuestPath(path)
            ? path
            : QuestPaths.questFile(entry.questId, path),
      );
      final f = File(fullPath);
      if (!await f.exists()) continue;
      archive.addFile(
        ArchiveFile(normalized, await f.length(), await f.readAsBytes()),
      );
    }

    final data = ZipEncoder().encode(archive);
    final tmp = await getTemporaryDirectory();
    final zipFile = File(
      p.join(tmp.path, 'preset_${DateTime.now().millisecondsSinceEpoch}.zip'),
    );
    await zipFile.writeAsBytes(data);
    return zipFile;
  }

  /// Отрендерить PNG-обложку из RepaintBoundary с ключом [key].
  static Future<File?> renderCover(GlobalKey key) async {
    try {
      final boundary =
          key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) return null;
      final tmp = await getTemporaryDirectory();
      final f = File(
        p.join(
          tmp.path,
          'preset_cover_${DateTime.now().millisecondsSinceEpoch}.png',
        ),
      );
      await f.writeAsBytes(byteData.buffer.asUint8List());
      return f;
    } catch (_) {
      return null;
    }
  }

  /// Отправить пресет на модерацию как kind=button_preset (ZIP).
  /// Публикует ZIP. Возвращает ID созданного маркет-ассета (для привязки
  /// «пресет → публикация») либо null, если сервер не вернул id.
  static Future<String?> publish({
    required File zipFile,
    required File? coverFile,
    required String title,
    required String genre,
    required String license,
    required String description,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token') ?? '';
    final uri = Uri.parse('${AppConfig.apiUrl}/assets');
    final req = http.MultipartRequest('POST', uri);
    if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
    req.fields['kind'] = 'button_preset';
    req.fields['title'] = title;
    if (genre.trim().isNotEmpty) req.fields['genre'] = genre.trim();
    req.fields['license'] = license;
    req.fields['description'] = description;
    req.files.add(await http.MultipartFile.fromPath('assetFile', zipFile.path));
    if (coverFile != null) {
      req.files.add(await http.MultipartFile.fromPath('cover', coverFile.path));
    }
    final streamed = await req.send();
    final respStr = await streamed.stream.bytesToString();
    if (streamed.statusCode == 201) {
      try {
        return (jsonDecode(respStr) as Map<String, dynamic>)['id']?.toString();
      } catch (_) {
        return null;
      }
    }
    if (streamed.statusCode == 429) throw Exception(tr('Лимит 5/час'));
    if (streamed.statusCode == 409) throw Exception(tr('Дубликат файла'));
    throw Exception('HTTP ${streamed.statusCode}: $respStr');
  }

  /// Каталог-кэш, куда распаковываются ZIP-пресеты из маркета (для превью).
  static Future<Directory> presetCacheDir(String assetId) async {
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, 'preset_previews', assetId));
  }

  /// Вычистить кэш превью пресета (после удаления из маркета),
  /// чтобы приложение не рисовало удалённое из кэша и не пыталось
  /// докачивать ZIP уже несуществующего ресурса.
  static Future<void> clearPreviewCache(String assetId) async {
    try {
      final dir = await presetCacheDir(assetId);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // кэш временный — ошибка очистки не критична
    }
  }

  /// Прямая привязка «пресет → маркет-ассет», сохранённая в момент публикации.
  /// Надёжнее матча по названию: имя публикации могло измениться.
  static String _bindingKey(String questId, String presetId) =>
      'preset_asset_${questId}_$presetId';

  static Future<void> savePublishedAssetId({
    required String questId,
    required String presetId,
    required String assetId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_bindingKey(questId, presetId), assetId);
    } catch (_) {}
  }

  static Future<String?> publishedAssetId(
    String questId,
    String presetId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_bindingKey(questId, presetId));
      return (id == null || id.isEmpty) ? null : id;
    } catch (_) {
      return null;
    }
  }

  static Future<void> forgetPublishedAssetId(
    String questId,
    String presetId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_bindingKey(questId, presetId));
    } catch (_) {}
  }

  /// Скачать ZIP из маркета, распаковать в квест и смержить пресет в config.json.
  /// Возвращает количество добавленных текстур.
  static Future<int> importToQuest({
    required MarketAsset asset,
    required String questId,
  }) async {
    final tmpDir = await Directory.systemTemp.createTemp('preset_import_');
    try {
      final zipFile = File(p.join(tmpDir.path, 'preset.zip'));
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token') ?? '';
      final req = http.Request('GET', Uri.parse(asset.downloadUrl));
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      final resp = await http.Client().send(req);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      await zipFile.writeAsBytes(await resp.stream.toBytes());

      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? jsonFile;
      final assetFiles = <ArchiveFile>[];
      for (final f in archive) {
        if (!f.isFile) continue;
        if (f.name.toLowerCase().endsWith('.json')) {
          jsonFile ??= f;
        } else {
          assetFiles.add(f);
        }
      }
      if (jsonFile == null) throw Exception(tr('В архиве нет presets.json'));

      final content = utf8.decode(List<int>.from(jsonFile.content as List));
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
      if (list == null) throw Exception(tr('В архиве нет пресетов'));

      final incoming = <ButtonStyleConfig>[];
      for (final item in list) {
        if (item is! Map) continue;
        final cfg = ButtonStyleConfig.fromJson(Map<String, dynamic>.from(item));
        final name = cfg.presetName?.trim();
        if (name == null || name.isEmpty) continue;
        incoming.add(cfg);
      }
      if (incoming.isEmpty) throw Exception(tr('В архиве нет пресетов'));

      final qs = await QuestStore.defaultInstance();
      final configPath = QuestPaths.config(questId);
      final config = await qs.readJson(configPath) ?? <String, dynamic>{};

      // Текстуры → res/ (пути из архива); существующие не перезаписываем.
      int importedAssets = 0;
      for (final f in assetFiles) {
        final normalized = _normalizePath(f.name);
        if (normalized.isEmpty) continue;
        final targetPath = await FileStorage.getFilePath(
          QuestPaths.questFile(questId, normalized),
        );
        final target = File(targetPath);
        if (await target.exists()) continue;
        await target.parent.create(recursive: true);
        await target.writeAsBytes(List<int>.from(f.content as List));
        importedAssets++;
      }

      // Мерж пресетов по имени.
      final existing = (config['buttonStylePresets'] is List)
          ? (config['buttonStylePresets'] as List)
                .whereType<Map>()
                .map(
                  (e) =>
                      ButtonStyleConfig.fromJson(Map<String, dynamic>.from(e)),
                )
                .toList()
          : <ButtonStyleConfig>[];
      final byName = <String, ButtonStyleConfig>{
        for (final preset in existing)
          if (preset.presetName?.trim().isNotEmpty ?? false)
            preset.presetName!.trim(): preset,
      };
      for (final preset in incoming) {
        byName[preset.presetName!.trim()] = preset;
      }
      config['buttonStylePresets'] = byName.values
          .map((e) => e.toJson())
          .toList();
      await qs.writeJson(configPath, config);
      return importedAssets;
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Скачать ZIP ассета из маркета и распаковать в кэш-каталог
  /// (для отрисовки живого превью кнопки в карточках маркета).
  /// Возвращает каталог с presets.json и текстурами либо null при ошибке.
  static Future<Directory?> unzipToCache(MarketAsset asset) async {
    final cacheDir = await presetCacheDir(asset.id);
    final doneMarker = File(p.join(cacheDir.path, '.done'));
    if (await doneMarker.exists()) return cacheDir;

    Directory? tmpDir;
    try {
      tmpDir = await Directory.systemTemp.createTemp('preset_preview_');
      final zipFile = File(p.join(tmpDir.path, 'preset.zip'));
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token') ?? '';
      final req = http.Request('GET', Uri.parse(asset.downloadUrl));
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      final resp = await http.Client().send(req);
      if (resp.statusCode != 200) return null;
      await zipFile.writeAsBytes(await resp.stream.toBytes());

      final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
      await cacheDir.create(recursive: true);
      for (final f in archive) {
        if (!f.isFile) continue;
        final normalized = _normalizePath(f.name);
        if (normalized.isEmpty || normalized.contains('..')) continue;
        final target = File(p.join(cacheDir.path, normalized));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(List<int>.from(f.content as List));
      }
      await doneMarker.writeAsString('ok');
      return cacheDir;
    } catch (_) {
      return null;
    } finally {
      try {
        tmpDir?.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  static Set<String> _collectAssetPaths(ButtonStyleConfig cfg) {
    return {
      if (cfg.cornerAsset?.trim().isNotEmpty ?? false) cfg.cornerAsset!.trim(),
      if (cfg.hAsset?.trim().isNotEmpty ?? false) cfg.hAsset!.trim(),
      if (cfg.vAsset?.trim().isNotEmpty ?? false) cfg.vAsset!.trim(),
      if (cfg.centerAsset?.trim().isNotEmpty ?? false) cfg.centerAsset!.trim(),
    };
  }

  static String _normalizePath(String raw) {
    var n = raw.replaceAll('\\', '/').trim();
    n = n.replaceAll(RegExp(r'^/+'), '');
    return n;
  }
}

// ============================================================================
//  UI: превью кнопки
// ============================================================================

/// Кнопка-превью из модулей или плоская (для маркета пресетов).
///
/// Пути текстур резолвятся по [questIdOrNull] (локальный квест) либо
/// по [basePath] (распакованный ZIP из маркета — абсолютный каталог).
class PresetButtonPreview extends StatelessWidget {
  final String? questIdOrNull;
  final String? basePath;
  final ButtonStyleConfig style;
  final String? text;

  const PresetButtonPreview({
    super.key,
    required this.style,
    this.questIdOrNull,
    this.basePath,
    this.text,
  });

  @override
  Widget build(BuildContext context) {
    final label = text ?? tr('Кнопка');
    if (style.hasModuleAssets && (questIdOrNull != null || basePath != null)) {
      return _ModuleButtonPreview(
        style: style,
        questId: questIdOrNull,
        basePath: basePath,
        text: label,
      );
    }
    return _FlatButtonPreview(style: style, text: label);
  }
}

/// Тёмный «игровой» фон, на котором красиво смотрится превью кнопки.
class PresetPreviewBackdrop extends StatelessWidget {
  final Widget child;

  const PresetPreviewBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF141B2B), Color(0xFF0D1220)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: child,
    );
  }
}

class _FlatButtonPreview extends StatelessWidget {
  final ButtonStyleConfig style;
  final String text;

  const _FlatButtonPreview({required this.style, required this.text});

  @override
  Widget build(BuildContext context) {
    final radius = style.borderRadius ?? 12.0;
    final border = Border.all(
      color: style.borderColor,
      width: style.borderWidth ?? 2.0,
    );
    final shadow = [
      BoxShadow(
        color: style.shadowColor.withOpacity(style.effectiveShadowOpacity),
        blurRadius: style.effectiveShadowBlur,
        offset: Offset(
          style.effectiveShadowOffsetX,
          style.effectiveShadowOffsetY,
        ),
      ),
    ];
    final decoration = style.useGradient
        ? BoxDecoration(
            gradient: LinearGradient(
              begin: style.gradientIsHorizontal
                  ? Alignment.centerLeft
                  : Alignment.topCenter,
              end: style.gradientIsHorizontal
                  ? Alignment.centerRight
                  : Alignment.bottomCenter,
              colors: [
                style.gradientStartColor.withOpacity(
                  style.effectiveFillOpacity,
                ),
                style.gradientEndColor.withOpacity(style.effectiveFillOpacity),
              ],
            ),
            borderRadius: BorderRadius.circular(radius),
            border: border,
            boxShadow: shadow,
          )
        : BoxDecoration(
            color: style.fillColor.withOpacity(style.effectiveFillOpacity),
            borderRadius: BorderRadius.circular(radius),
            border: border,
            boxShadow: shadow,
          );
    FontWeight? weight;
    if (style.textWeight != null) {
      final idx = (style.textWeight! / 100).round().clamp(0, 8);
      weight = FontWeight.values[idx];
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: decoration,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: style.textColor,
          fontSize: style.effectiveTextSize,
          fontWeight: weight ?? FontWeight.w600,
          letterSpacing: style.letterSpacing,
          fontFamily: style.fontFamily,
        ),
      ),
    );
  }
}

class _ModuleButtonPreview extends StatelessWidget {
  final String? questId;
  final String? basePath;
  final ButtonStyleConfig style;
  final String text;

  const _ModuleButtonPreview({
    required this.style,
    this.questId,
    this.basePath,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final module = style.moduleSize.clamp(10.0, 20.0);
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              children: [
                Positioned.fill(
                  child: _PresetTile(
                    questId: questId,
                    basePath: basePath,
                    path: style.centerAsset!,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: module,
                  child: _PresetTile(
                    questId: questId,
                    basePath: basePath,
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
                    child: _PresetTile(
                      questId: questId,
                      basePath: basePath,
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
                  child: _PresetTile(
                    questId: questId,
                    basePath: basePath,
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
                    child: _PresetTile(
                      questId: questId,
                      basePath: basePath,
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
                  child: _PresetTile(
                    questId: questId,
                    basePath: basePath,
                    path: style.cornerAsset!,
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  width: module,
                  height: module,
                  child: Transform.rotate(
                    angle: 1.5707963267,
                    child: _PresetTile(
                      questId: questId,
                      basePath: basePath,
                      path: style.cornerAsset!,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  bottom: 0,
                  width: module,
                  height: module,
                  child: Transform.rotate(
                    angle: -1.5707963267,
                    child: _PresetTile(
                      questId: questId,
                      basePath: basePath,
                      path: style.cornerAsset!,
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: module,
                  height: module,
                  child: Transform.rotate(
                    angle: 3.1415926535,
                    child: _PresetTile(
                      questId: questId,
                      basePath: basePath,
                      path: style.cornerAsset!,
                    ),
                  ),
                ),
              ],
            ),
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
              fontSize: 15,
            ),
          ),
        ),
      ],
    );
  }
}

class _PresetTile extends StatelessWidget {
  final String? questId;
  final String? basePath;
  final String path;
  final ImageRepeat repeat;

  const _PresetTile({
    required this.path,
    this.questId,
    this.basePath,
    this.repeat = ImageRepeat.noRepeat,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _resolve(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.expand();
        return DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: FileImage(File(snapshot.data!)),
              fit: BoxFit.fill,
              repeat: repeat,
            ),
          ),
        );
      },
    );
  }

  Future<String?> _resolve() async {
    try {
      if (basePath != null) {
        final normalized = path
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+'), '');
        final f = File(p.join(basePath!, normalized));
        return await f.exists() ? f.path : null;
      }
      if (questId != null) {
        // Резолвер библиотеки: путь в пресете мог быть записан именем файла.
        final full = await QuestImageSource.resolveOnDisk(questId!, path);
        return full.isEmpty ? null : full;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

// ============================================================================
//  Bottom sheet «Пресеты кнопок» в Хабе
// ============================================================================

Future<void> showPresetMarketSheet(
  BuildContext context, {
  ValueChanged<QuestPresetEntry>? onOpen,
}) {
  return showAdaptiveSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
    builder: (_) => _PresetMarketSheet(onOpen: onOpen),
  );
}

/// Пустое состояние списка пресетов. Гостю нельзя писать «пресетов нет» —
/// они у него как раз есть, просто публиковать их некому.
class _PresetEmptyState extends StatelessWidget {
  const _PresetEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 48,
              color: scheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Встроенный список пресетов (без шэита) — для вкладки «Пресеты» в Хабе.
/// Кнопка «Опубликовать» на каждой карточке — публикует выбранный пресет.
class PresetMarketListView extends ConsumerStatefulWidget {
  const PresetMarketListView({super.key});

  @override
  ConsumerState<PresetMarketListView> createState() =>
      _PresetMarketListViewState();
}

class _PresetMarketListViewState extends ConsumerState<PresetMarketListView> {
  String? _publishingKey;

  @override
  Widget build(BuildContext context) {
    final presetsAsync = ref.watch(allQuestPresetsProvider);
    final profileAsync = ref.watch(currentUserProfileProvider);
    // Без залогиненного профиля публиковать некому — даже пресеты,
    // формально помеченные isOwn, не должны предлагать публикацию.
    final loggedIn = profileAsync.value != null;
    return presetsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          Center(child: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))),
      data: (allPresets) {
        // Публиковать можно только свои пресеты: пресеты из скачанных
        // квестов принадлежат другим авторам.
        final presets = loggedIn
            ? allPresets.where((p) => p.isOwn).toList()
            : const <QuestPresetEntry>[];
        if (presets.isEmpty) {
          if (!loggedIn) {
            return _PresetEmptyState(
              icon: Icons.lock_person_rounded,
              title: tr('Войдите в аккаунт'),
              message: tr(
                'Публиковать пресеты можно только из-под своего профиля',
              ),
            );
          }
          return _PresetEmptyState(
            icon: Icons.smart_button_rounded,
            title: tr('Пресетов нет'),
            message: tr(
              'Создай свои пресеты в редакторе квеста: Настройки квеста → Кастомные кнопки',
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(allQuestPresetsProvider),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            itemCount: presets.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (ctx, i) {
              final entry = presets[i];
              final key = '${entry.questId}/${entry.presetId}';
              return _PresetCard(
                entry: entry,
                isPublishing: _publishingKey == key,
                onPublish: _publishingKey == null
                    ? () => _publish(entry)
                    : null,
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _publish(QuestPresetEntry entry) async {
    final key = '${entry.questId}/${entry.presetId}';
    setState(() => _publishingKey = key);
    try {
      await publishPresetFlow(context, entry);
    } finally {
      if (mounted) setState(() => _publishingKey = null);
    }
  }
}

class _PresetMarketSheet extends ConsumerStatefulWidget {
  final ValueChanged<QuestPresetEntry>? onOpen;

  const _PresetMarketSheet({this.onOpen});

  @override
  ConsumerState<_PresetMarketSheet> createState() => _PresetMarketSheetState();
}

class _PresetMarketSheetState extends ConsumerState<_PresetMarketSheet> {
  String? _publishingKey;

  Future<void> _publish(QuestPresetEntry entry) async {
    final key = '${entry.questId}/${entry.presetId}';
    setState(() => _publishingKey = key);
    try {
      await publishPresetFlow(context, entry);
    } finally {
      if (mounted) setState(() => _publishingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final presetsAsync = ref.watch(allQuestPresetsProvider);
    // Без залогиненного профиля публикация недоступна.
    final loggedIn = ref.watch(currentUserProfileProvider).valueOrNull != null;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.88,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Row(
              children: [
                Text(
                  tr('Пресеты кнопок'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => ref.invalidate(allQuestPresetsProvider),
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: tr('Обновить'),
                ),
              ],
            ),
          ),
          Expanded(
            child: presetsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
              ),
              data: (allPresets) {
                final presets = loggedIn
                    ? allPresets.where((p) => p.isOwn).toList()
                    : const <QuestPresetEntry>[];
                if (presets.isEmpty) {
                  if (!loggedIn) {
                    return _PresetEmptyState(
                      icon: Icons.lock_person_rounded,
                      title: tr('Войдите в аккаунт'),
                      message: tr(
                        'Публиковать пресеты можно только из-под своего профиля',
                      ),
                    );
                  }
                  return _PresetEmptyState(
                    icon: Icons.smart_button_rounded,
                    title: tr('Пресетов нет'),
                    message: tr(
                      'Создай пресеты в редакторе квеста: Настройки квеста → Кастомные кнопки',
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async =>
                      ref.invalidate(allQuestPresetsProvider),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    itemCount: presets.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (ctx, i) {
                      final entry = presets[i];
                      return _PresetCard(
                        entry: entry,
                        isPublishing:
                            _publishingKey ==
                            '${entry.questId}/${entry.presetId}',
                        onPublish: () => _publish(entry),
                        onOpen: widget.onOpen == null
                            ? null
                            : () => widget.onOpen!(entry),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  final QuestPresetEntry entry;
  final bool isPublishing;
  final VoidCallback? onPublish;
  final VoidCallback? onOpen;

  const _PresetCard({
    required this.entry,
    required this.isPublishing,
    required this.onPublish,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Превью на тёмном «игровом» фоне — во всю ширину карточки.
          // Тап по нему открывает страницу пресета, а не публикует сразу.
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
            child: InkWell(
              onTap: onOpen,
              child: PresetPreviewBackdrop(
                child: Center(
                  child: PresetButtonPreview(
                    style: entry.config,
                    questIdOrNull: entry.questId,
                    text: entry.presetName,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.presetName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.travel_explore_rounded,
                            size: 12,
                            color: scheme.onSurfaceVariant.withOpacity(0.7),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              entry.questTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (onPublish != null)
                  FilledButton.icon(
                    onPressed: isPublishing ? null : onPublish,
                    icon: isPublishing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_rounded, size: 16),
                    label: Text(
                      tr('Опубликовать'),
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  Публикация выбранного пресета (общий флоу для списка в Хабе и шита)
// ============================================================================

Future<void> publishPresetFlow(
  BuildContext context,
  QuestPresetEntry entry,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final overlayController = Overlay.of(context);

  // Гость мог собрать ZIP, заполнить форму и только в конце получить 401.
  if (!await ensurePublishAccount(context)) return;

  try {
    final zip = await PresetMarketService.buildPresetZip(entry: entry);

    final titleCtrl = TextEditingController(text: entry.presetName);
    final genreCtrl = TextEditingController();
    final licenseCtrl = TextEditingController(text: 'CC-BY');
    final descCtrl = TextEditingController();
    if (!context.mounted) return;
    final ok = await showAdaptiveSheet<bool>(
      context: context,
      scrollable: true,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          20 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              trf('Публикация «{p0}»', {'p0': entry.presetName}),
              style: Theme.of(
                ctx,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                labelText: tr('Название *'),
                border: OutlineInputBorder(),
                filled: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: genreCtrl,
              decoration: InputDecoration(
                labelText: tr('Жанр/тег'),
                hintText: 'Minimal, Fantasy...',
                border: OutlineInputBorder(),
                filled: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: licenseCtrl,
              decoration: InputDecoration(
                labelText: tr('Лицензия *'),
                helperText: tr('Например CC-BY, CC-BY-SA, MIT'),
                border: OutlineInputBorder(),
                filled: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              decoration: InputDecoration(
                labelText: tr('Описание'),
                border: OutlineInputBorder(),
                filled: true,
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                if (titleCtrl.text.trim().isEmpty ||
                    licenseCtrl.text.trim().isEmpty) {
                  messenger.showSnackBar(
                    SnackBar(content: Text(tr('Заполните обязательные поля'))),
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              label: Text(tr('Отправить на модерацию')),
              icon: const Icon(Icons.cloud_upload_rounded, size: 16),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (titleCtrl.text.trim().isEmpty || licenseCtrl.text.trim().isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('Заполните обязательные поля'))),
      );
      return;
    }

    // Рендер обложки через скрытый Overlay (RepaintBoundary вне экрана).
    final boundaryKey = GlobalKey();
    final overlayEntry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: -3000,
        top: -3000,
        width: 360,
        child: Material(
          type: MaterialType.transparency,
          child: RepaintBoundary(
            key: boundaryKey,
            child: PresetButtonPreview(
              style: entry.config,
              questIdOrNull: entry.questId,
              text: entry.presetName,
            ),
          ),
        ),
      ),
    );
    overlayController.insert(overlayEntry);
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    final cover = await PresetMarketService.renderCover(boundaryKey);
    overlayEntry.remove();

    final assetId = await PresetMarketService.publish(
      zipFile: zip,
      coverFile: cover,
      title: titleCtrl.text.trim(),
      genre: genreCtrl.text.trim(),
      license: licenseCtrl.text.trim(),
      description: descCtrl.text.trim(),
    );
    // Запоминаем связь «пресет → публикация», чтобы страница пресета
    // всегда знала свой маркет-ассет (матч по названию хрупкий).
    if (assetId != null) {
      await PresetMarketService.savePublishedAssetId(
        questId: entry.questId,
        presetId: entry.presetId,
        assetId: assetId,
      );
    }
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Отправлено на модерацию'))),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))),
    );
  }
}

// ============================================================================
//  «В квест» из общего маркета для button_preset (распаковка ZIP)
// ============================================================================

/// Добавить пресет кнопок из маркета в квест: скачивает ZIP, раскладывает
/// текстуры и мержит пресет в config.json. Вызывается из asset_market_screen.
Future<String?> addPresetToQuestFlow({
  required BuildContext context,
  required MarketAsset asset,
  required String questId,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Скачивание пресета...'))),
    );
    final imported = await PresetMarketService.importToQuest(
      asset: asset,
      questId: questId,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          trf(
            'Пресет добавлен (текстур: {imported}). Выбери его в настройках кнопки.',
            {'imported': imported},
          ),
        ),
      ),
    );
    return 'button_presets_ok';
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))),
    );
    return null;
  }
}

// ============================================================================
//  Живое превью пресета из маркета (ZIP → кэш → реальные модули кнопки)
// ============================================================================

/// Показывает настоящую кнопку пресета из маркета: скачивает ZIP в кэш,
/// парсит presets.json и рисует реальные модули. Фолбэк — обложка/иконка.
class RemotePresetPreview extends ConsumerStatefulWidget {
  final MarketAsset asset;
  final double? height; // null = занять всю высоту родителя (Expanded/сетка)

  const RemotePresetPreview({super.key, required this.asset, this.height});

  @override
  ConsumerState<RemotePresetPreview> createState() =>
      _RemotePresetPreviewState();
}

class _RemotePresetPreviewState extends ConsumerState<RemotePresetPreview> {
  Future<(ButtonStyleConfig?, String?)>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<(ButtonStyleConfig?, String?)> _load() async {
    final dir = await PresetMarketService.unzipToCache(widget.asset);
    if (dir == null) return (null, null);
    try {
      final jsonFile = File(p.join(dir.path, 'presets.json'));
      if (!await jsonFile.exists()) {
        // фолбэк: любой .json в корне
        final files = await dir.list().toList();
        for (final f in files) {
          if (f is File && p.basename(f.path).toLowerCase().endsWith('.json')) {
            return await _parse(f);
          }
        }
        return (null, dir.path);
      }
      return await _parse(jsonFile);
    } catch (_) {
      return (null, dir.path);
    }
  }

  Future<(ButtonStyleConfig?, String?)> _parse(File jsonFile) async {
    final decoded = jsonDecode(await jsonFile.readAsString());
    final basePath = jsonFile.parent.path;
    List list = const [];
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map<String, dynamic>) {
      if (decoded['presets'] is List)
        list = decoded['presets'] as List;
      else if (decoded['buttonStylePresets'] is List)
        list = decoded['buttonStylePresets'] as List;
    }
    for (final item in list) {
      if (item is! Map) continue;
      final cfg = ButtonStyleConfig.fromJson(Map<String, dynamic>.from(item));
      if (cfg.presetName?.trim().isNotEmpty ?? false) return (cfg, basePath);
    }
    return (null, basePath);
  }

  @override
  Widget build(BuildContext context) {
    Widget buildInner({required Widget child}) {
      final backdrop = PresetPreviewBackdrop(child: child);
      return widget.height == null
          ? SizedBox.expand(child: backdrop)
          : SizedBox(height: widget.height, child: backdrop);
    }

    return FutureBuilder<(ButtonStyleConfig?, String?)>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return buildInner(
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final (cfg, basePath) = snap.data ?? (null, null);
        if (cfg == null || basePath == null) {
          // Фолбэк: обложка из маркета или иконка.
          return buildInner(
            child: widget.asset.coverUrl != null
                ? Image.network(
                    widget.asset.coverUrl!,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.smart_button_rounded, size: 36),
                  )
                : const Icon(Icons.smart_button_rounded, size: 36),
          );
        }
        return buildInner(
          child: Center(
            child: PresetButtonPreview(
              style: cfg,
              basePath: basePath,
              text: cfg.presetName ?? widget.asset.title,
            ),
          ),
        );
      },
    );
  }
}
