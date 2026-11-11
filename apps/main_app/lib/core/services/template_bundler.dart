import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/features/editor/utils/template_applier.dart';
import 'package:canvas_app/core/utils/archive_entry_paths.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';

/// Результат применения бандла к квесту.
class TemplateBundleApplyReport {
  /// Сколько файлов скопировано в квест.
  final int copied;

  /// Сколько файлов уже было в квесте (с тем же sha256) — пропущено.
  final int skippedExisting;

  /// Относительные пути, которые не удалось распаковать.
  final List<String> failed;

  /// Маппинг старых относительных путей -> новых (на случай переименований
  /// при коллизиях). Если маппинг пустой, путь не менялся.
  final Map<String, String> remappedPaths;

  const TemplateBundleApplyReport({
    required this.copied,
    required this.skippedExisting,
    required this.failed,
    required this.remappedPaths,
  });

  bool get isEmpty => copied == 0 && skippedExisting == 0;
}

/// Утилита упаковки/распаковки шаблонов с ресурсами в ZIP-архив (`.mndtpl`).
///
/// Формат файла:
/// ```
/// <root>/
///   manifest.json     — {"format":"meander.template.bundle","version":1}
///   template.json     — TemplateItem.toJson() с актуальным списком assets
///   res/...           — фактические ресурсы (картинки, аудио, шрифты)
///   scripts/...
///   _internal_scripts/...
/// ```
///
/// Также используется для хранения «глобальных» шаблонов в
/// `app/templates/assets/<sha256>` с дедупликацией.
class TemplateBundler {
  static const String formatTag = 'meander.template.bundle';
  static const int formatVersion = 1;

  /// Папка локального хранилища глобальных ассетов.
  static const String globalAssetsDir = 'app/templates/assets';

  // ============================================================
  // ПОДГОТОВКА АССЕТОВ ДЛЯ ШАБЛОНА (без архивирования)
  // ============================================================

  /// Считывает все ассеты, на которые ссылается [template], из квеста
  /// [questId] и возвращает обновлённый `TemplateItem` с заполненным
  /// `assets[]` + словарь `{sha256: bytes}` для использования
  /// в [buildBundle] / сохранении в глобальное хранилище.
  ///
  /// Если файл не найден в квесте — он не добавляется в assets[].
  static Future<TemplateAssetsCollection> collectAssetsForTemplate({
    required TemplateItem template,
    required String? questId,
  }) async {
    final paths = TemplateApplier.collectResourcePaths(template);

    final assets = <TemplateAsset>[];
    final bytesBySha = <String, Uint8List>{};
    final seenSha = <String>{};

    for (final relPath in paths) {
      Uint8List? data;

      // 1. Пытаемся прочесть из квеста.
      if (questId != null) {
        final fullPath = QuestPaths.questFile(questId, relPath);
        if (await FileStorage.exists(fullPath)) {
          try {
            final file = File(await FileStorage.getFilePath(fullPath));
            data = await file.readAsBytes();
          } catch (_) {}
        }
      }

      // 2. Если файла не было в квесте — пытаемся из существующих ассетов
      //    шаблона (хранилища).
      if (data == null) {
        final existing = template.assets
            .where((a) => a.relativePath == relPath)
            .toList();
        if (existing.isNotEmpty &&
            existing.first.storageFileName != null &&
            existing.first.storageFileName!.isNotEmpty) {
          final storagePath =
              '$globalAssetsDir/${existing.first.storageFileName}';
          if (await FileStorage.exists(storagePath)) {
            try {
              final f = File(await FileStorage.getFilePath(storagePath));
              data = await f.readAsBytes();
            } catch (_) {}
          }
        }
      }

      if (data == null) {
        // Ассет не найден — пропускаем.
        continue;
      }

      final hex = sha256.convert(data).toString();
      if (!seenSha.contains(hex)) {
        seenSha.add(hex);
        bytesBySha[hex] = data;
      }

      assets.add(
        TemplateAsset(
          relativePath: relPath,
          sha256: hex,
          size: data.length,
          storageFileName: '$hex${p.extension(relPath)}',
        ),
      );
    }

    final updated = template.copyWith(assets: assets);
    return TemplateAssetsCollection(template: updated, bytesBySha: bytesBySha);
  }

  // ============================================================
  // ЗАПИСЬ АССЕТОВ В ГЛОБАЛЬНОЕ ХРАНИЛИЩЕ
  // ============================================================

  /// Копирует все ассеты в `app/templates/assets/` под именами sha-deduped.
  static Future<void> writeAssetsToGlobalStore({
    required List<TemplateAsset> assets,
    required Map<String, Uint8List> bytesBySha,
  }) async {
    await FileStorage.createFolder(globalAssetsDir);
    for (final asset in assets) {
      final fileName = asset.storageFileName;
      if (fileName == null || fileName.isEmpty) continue;
      final storagePath = '$globalAssetsDir/$fileName';
      if (await FileStorage.exists(storagePath)) {
        continue; // уже лежит, не перезаписываем
      }
      final data = bytesBySha[asset.sha256];
      if (data == null) continue;
      try {
        final file = File(await FileStorage.getFilePath(storagePath));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data, flush: true);
      } catch (_) {}
    }
  }

  // ============================================================
  // СБОРКА БАНДЛА (.mndtpl)
  // ============================================================

  /// Собрать байты `.mndtpl` ZIP-архива.
  ///
  /// [questId] — для подтягивания ассетов из квеста (если они там есть).
  /// Если null — используются уже упакованные/глобальные ассеты.
  static Future<List<int>> buildBundle({
    required TemplateItem template,
    required String? questId,
  }) async {
    // Сначала собираем актуальные ассеты (на случай, если шаблон ещё
    // не имел упакованных).
    final collection = await collectAssetsForTemplate(
      template: template,
      questId: questId,
    );
    final tpl = collection.template;

    final archive = Archive();

    // manifest.json
    final manifest = {
      'format': formatTag,
      'version': formatVersion,
      'templateId': tpl.id,
      'createdAt': DateTime.now().toIso8601String(),
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );

    // template.json (без storageFileName, чтобы не светить локальные пути)
    final templateForFile = tpl.copyWith(
      assets: tpl.assets.map((a) => a.copyWith(storageFileName: null)).toList(),
    );
    final tplBytes = utf8.encode(jsonEncode(templateForFile.toJson()));
    archive.addFile(ArchiveFile('template.json', tplBytes.length, tplBytes));

    // Ассеты
    for (final asset in tpl.assets) {
      final data = collection.bytesBySha[asset.sha256];
      if (data == null) continue;
      archive.addFile(ArchiveFile(asset.relativePath, data.length, data));
    }

    return ZipEncoder().encode(archive);
  }

  // ============================================================
  // РАЗБОР БАНДЛА (.mndtpl)
  // ============================================================

  /// Прочитать `.mndtpl`: вернуть TemplateItem и байты ассетов.
  /// Возвращает null, если файл не похож на наш формат.
  static Future<TemplateAssetsCollection?> readBundle(
    Uint8List zipBytes,
  ) async {
    try {
      final archive = ZipDecoder().decodeBytes(zipBytes);

      // Найти manifest.json и template.json
      ArchiveFile? manifestFile;
      ArchiveFile? templateFile;
      for (final f in archive.files) {
        if (f.name == 'manifest.json') manifestFile = f;
        if (f.name == 'template.json') templateFile = f;
      }
      if (manifestFile == null || templateFile == null) {
        return null;
      }

      final tplJson = jsonDecode(
        utf8.decode(templateFile.content as List<int>),
      );
      if (tplJson is! Map) return null;
      final tpl = TemplateItem.fromJson(Map<String, dynamic>.from(tplJson));

      // Собираем bytesBySha из архива
      final bytesBySha = <String, Uint8List>{};
      for (final asset in tpl.assets) {
        for (final f in archive.files) {
          if (f.name == asset.relativePath) {
            final raw = Uint8List.fromList(f.content as List<int>);
            bytesBySha[asset.sha256] = raw;
            break;
          }
        }
      }

      return TemplateAssetsCollection(template: tpl, bytesBySha: bytesBySha);
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // ПРИМЕНЕНИЕ АССЕТОВ К КВЕСТУ
  // ============================================================

  /// Копирует все ассеты [template] в квест [questId].
  ///
  /// Стратегия коллизий:
  /// * Если в квесте уже есть файл с тем же путём И тем же sha256 →
  ///   пропускаем (`skippedExisting`).
  /// * Если в квесте есть файл с тем же путём, но другим sha256 →
  ///   копируем под уникальным именем (`bg__<short_sha>.png`) и пишем
  ///   в `remappedPaths`. Вызывающий код может использовать его, чтобы
  ///   обновить ссылки в payload.
  /// * Если файл отсутствует — копируем как есть.
  ///
  /// [bytesBySha] — карта sha→содержимое. Может быть пустой, если шаблон
  /// сохранён локально в глобальном ассет-кеше (тогда мы читаем из
  /// `app/templates/assets/<storageFileName>`).
  static Future<TemplateBundleApplyReport> applyAssetsToQuest({
    required String questId,
    required List<TemplateAsset> assets,
    Map<String, Uint8List>? bytesBySha,
  }) async {
    var copied = 0;
    var skipped = 0;
    final failed = <String>[];
    final remap = <String, String>{};

    for (final asset in assets) {
      try {
        // Путь ассета приходит из манифеста шаблона (он же ездит по сети):
        // `../<чужой квест>/config.json` записался бы в чужую папку.
        final relativePath = sanitizeArchiveEntryPath(asset.relativePath);
        if (relativePath == null) {
          failed.add(asset.relativePath);
          continue;
        }

        // Получаем содержимое
        Uint8List? data;
        if (bytesBySha != null && bytesBySha.containsKey(asset.sha256)) {
          data = bytesBySha[asset.sha256];
        } else if (asset.storageFileName != null &&
            asset.storageFileName!.isNotEmpty) {
          final storagePath = '$globalAssetsDir/${asset.storageFileName}';
          if (await FileStorage.exists(storagePath)) {
            try {
              final f = File(await FileStorage.getFilePath(storagePath));
              data = await f.readAsBytes();
            } catch (_) {}
          }
        }

        if (data == null) {
          failed.add(asset.relativePath);
          continue;
        }

        final questFile = QuestPaths.questFile(questId, relativePath);
        if (await FileStorage.exists(questFile)) {
          // Сравниваем sha
          try {
            final f = File(await FileStorage.getFilePath(questFile));
            final existing = await f.readAsBytes();
            final existingHex = sha256.convert(existing).toString();
            if (existingHex == asset.sha256) {
              skipped++;
              continue;
            }
          } catch (_) {}

          // Конфликт — нужно переименовать
          final dir = p.dirname(relativePath);
          final base = p.basenameWithoutExtension(relativePath);
          final ext = p.extension(relativePath);
          final shortSha = asset.sha256.substring(0, 8);
          final newRel = dir == '.' || dir.isEmpty
              ? '${base}__$shortSha$ext'
              : '$dir/${base}__$shortSha$ext';
          final newFull = QuestPaths.questFile(questId, newRel);
          await _writeBytes(newFull, data);
          remap[relativePath] = newRel;
          copied++;
        } else {
          await _writeBytes(questFile, data);
          copied++;
        }
      } catch (e) {
        failed.add(asset.relativePath);
      }
    }

    return TemplateBundleApplyReport(
      copied: copied,
      skippedExisting: skipped,
      failed: failed,
      remappedPaths: remap,
    );
  }

  /// Применяет [remappedPaths] из отчёта к payload шаблона:
  /// заменяет все упоминания старых путей на новые.
  static Map<String, dynamic> remapPayloadPaths(
    Map<String, dynamic> payload,
    Map<String, String> remap,
  ) {
    if (remap.isEmpty) return payload;
    final encoded = jsonEncode(payload);
    var result = encoded;
    for (final entry in remap.entries) {
      result = result.replaceAll('"${entry.key}"', '"${entry.value}"');
      // Также обрабатываем имя файла без папки (поле может содержать
      // только имя — например, backgroundAssetId).
      final oldBase = p.basename(entry.key);
      final newBase = p.basename(entry.value);
      if (oldBase != newBase) {
        result = result.replaceAll('"$oldBase"', '"$newBase"');
      }
    }
    final decoded = jsonDecode(result);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return payload;
  }

  static Future<void> _writeBytes(String relPath, Uint8List data) async {
    final fullPath = await FileStorage.getFilePath(relPath);
    final file = File(fullPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data, flush: true);
  }
}

/// Шаблон + его ассеты в памяти (один блок данных).
class TemplateAssetsCollection {
  final TemplateItem template;

  /// Содержимое ассетов по sha256.
  final Map<String, Uint8List> bytesBySha;

  const TemplateAssetsCollection({
    required this.template,
    required this.bytesBySha,
  });
}
