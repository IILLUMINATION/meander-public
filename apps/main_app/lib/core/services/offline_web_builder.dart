import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class WebExportResult {
  final String fileName;

  const WebExportResult(this.fileName);
}

/// Сборка веб-версии квеста прямо на устройстве.
///
/// Аналог [OfflineApkBuilder]: в приложение при сборке вшивается готовая
/// оболочка веб-плеера (`assets/web_player/quest_web_template.zip`), сюда же
/// кладётся `quest.mnd` — получается папка-сайт в zip. Ни сети, ни Flutter
/// SDK: движок и рендерер те же, что в нативном плеере, поэтому экспорт
/// занимает секунды.
///
/// Почему zip, а не папка: на Android нет удобного способа отдать папку
/// наружу, а один файл можно перекинуть на хостинг как есть.
class OfflineWebBuilder {
  OfflineWebBuilder._();

  static const String templateAsset =
      'assets/web_player/quest_web_template.zip';

  /// Оболочку кладёт CI (или `scripts/build_web_template.sh`) — в git её нет:
  /// это ~10 МБ собранного wasm-движка.
  static Future<bool> isAvailable() async {
    if (kIsWeb) return false;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      return manifest.listAssets().contains(templateAsset);
    } catch (_) {
      return false;
    }
  }

  static String sanitizeFileName(String value) {
    var name = value.replaceAll(RegExp(r'[\\/*?:"<>|\x00-\x1F]'), '_').trim();
    if (name.toLowerCase().endsWith('.zip')) {
      name = name.substring(0, name.length - 4).trim();
    }
    if (name.toLowerCase().endsWith('-web')) {
      name = name.substring(0, name.length - 4).trim();
    }
    return name.isEmpty ? 'quest' : name;
  }

  /// Собирает zip и отдаёт его на сохранение. `null` — пользователь отменил
  /// диалог.
  static Future<WebExportResult?> buildAndSave(
    String questId, {
    required String questTitle,
  }) async {
    final fileName = '${sanitizeFileName(questTitle)}-web';
    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final workDir = await Directory(
      p.join(tempDir.path, 'webbuild_$stamp'),
    ).create(recursive: true);
    final zipFile = File(p.join(tempDir.path, 'webbuild_$stamp.zip'));

    // perNode-формат не кладёт nodes.json, а оболочка читает именно его —
    // без legacy-формата получился бы квест без единой ноды.
    final questFile = await ExportService.createMndTempFile(
      questId,
      nodesFormat: QuestArchiveNodesFormat.legacy,
    );

    try {
      final template = await rootBundle.load(templateAsset);
      final siteDir = await unpackTemplate(
        template.buffer.asUint8List(),
        p.join(workDir.path, 'site'),
      );
      await composeSite(shellDir: siteDir, questMnd: questFile);
      await zipSite(siteDir, zipFile);

      final saved = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          sourceFilePath: zipFile.path,
          fileName: '$fileName.zip',
        ),
      );
      if (saved == null) return null;
      return WebExportResult('$fileName.zip');
    } finally {
      for (final path in [workDir, zipFile, questFile]) {
        try {
          if (path is Directory) {
            if (await path.exists()) await path.delete(recursive: true);
          } else if (path is File) {
            if (await path.exists()) await path.delete();
          }
        } catch (_) {}
      }
    }
  }

  /// Распаковка оболочки на диск: держать 10 МБ архива и распакованные файлы в
  /// памяти незачем, а `quest.mnd` с ресурсами может быть куда больше.
  @visibleForTesting
  static Future<Directory> unpackTemplate(
    Uint8List bytes,
    String targetPath,
  ) async {
    final siteDir = Directory(targetPath);
    await siteDir.create(recursive: true);
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final out = File(p.join(targetPath, file.name));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(file.readBytes() ?? Uint8List(0));
    }
    return siteDir;
  }

  /// Кладёт квест и памятку в распакованную оболочку и чинит `<base href>`,
  /// если оболочку собрали не с `--base-href /`: со страницы в подпапке
  /// абсолютный `/` уводит запросы к `canvaskit` мимо неё.
  @visibleForTesting
  static Future<void> composeSite({
    required Directory shellDir,
    required File questMnd,
  }) async {
    final indexFile = File(p.join(shellDir.path, 'index.html'));
    if (await indexFile.exists()) {
      final html = await indexFile.readAsString();
      final fixed = html.replaceAllMapped(
        RegExp(r'(<base\s+href=")([^"]*)(")', caseSensitive: false),
        (m) => '${m[1]}./${m[3]}',
      );
      if (fixed != html) await indexFile.writeAsString(fixed);
    }

    await questMnd.copy(p.join(shellDir.path, 'quest.mnd'));
    await File(
      p.join(shellDir.path, 'README.txt'),
    ).writeAsString(_readme, flush: true);
  }

  @visibleForTesting
  static Future<void> zipSite(Directory siteDir, File zipFile) async {
    final encoder = ZipFileEncoder();
    encoder.create(zipFile.path, level: ZipFileEncoder.gzip);
    await encoder.addDirectory(siteDir, includeDirName: false);
    await encoder.close();
  }

  static const String _readme = '''
Веб-версия квеста Meander
=========================

index.html открывать с сервера, а не двойным щелчком: при открытии из файла
браузер не даёт движку модули wasm.

Главное: страница обязана отдаваться с заголовками

  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp

Без них браузер не даёт SharedArrayBuffer, и движок не запускается.
Локально это делает scripts/serve_web_export.py из репозитория:

  python3 scripts/serve_web_export.py --dir <эта папка>
  открыть http://127.0.0.1:8000/

Для nginx:

  add_header Cross-Origin-Opener-Policy same-origin always;
  add_header Cross-Origin-Embedder-Policy require-corp always;

Хостинги без своих заголовков (например, GitHub Pages) не подойдут.

quest.mnd — сам квест. Замените его на другой — получится другая веб-версия.
''';
}
