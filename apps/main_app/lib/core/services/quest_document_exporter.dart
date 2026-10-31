import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'quest_book_models.dart';
import 'quest_html_builder.dart';
import 'quest_pdf_builder.dart';
import 'quest_pdf_options.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';

/// Экспорт квестов Meander в HTML и PDF документы.
class QuestDocumentExporter {
  /// Самодостаточный HTML «как у плеера», оптимизированный для мобилок.
  static Future<bool> exportQuestAsHtml(
    String questId,
    String questTitle,
  ) async {
    try {
      final book = await _loadQuestBook(questId);
      final html = await QuestHtmlBuilder.build(book);
      final bytes = Uint8List.fromList(utf8.encode(html));
      return await _saveBytes(
        bytes: bytes,
        suggestedFileName: '${_sanitize(questTitle)}.html',
        dialogTitle: tr('Сохранить HTML'),
        extensions: const ['html'],
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('❌ [HTMLExport] Ошибка: $e\n$st');
      rethrow;
    }
  }

  /// PDF-книга. Скрипты полностью игнорируются по требованию.
  /// [options] определяет тему, размер шрифта и другие настройки оформления.
  static Future<bool> exportQuestAsPdf(
    String questId,
    String questTitle, {
    PdfExportOptions options = const PdfExportOptions(),
  }) async {
    try {
      final book = await _loadQuestBook(questId);
      final pdfBytes = await QuestPdfBuilder.build(book, options: options);
      return await _saveBytes(
        bytes: pdfBytes,
        suggestedFileName: '${_sanitize(questTitle)}.pdf',
        dialogTitle: tr('Сохранить PDF'),
        extensions: const ['pdf'],
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('❌ [PDFExport] Ошибка: $e\n$st');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  //  Загрузка структуры квеста
  // ---------------------------------------------------------------------------

  static Future<QuestBook> _loadQuestBook(String questId) async {
    final base = QuestPaths.questRoot(questId);

    if (!await FileStorage.exists('$base/config.json')) {
      throw Exception(tr('config.json не найден'));
    }

    final config = await FileStorage.readJsonFile('$base/config.json');

    Map<String, dynamic>? nodesData;
    if (await QuestNodesStore.hasPerNodeIndex(questId)) {
      nodesData = await QuestNodesStore.readAll(questId);
    } else {
      for (final rel in const ['nodes.json', 'nodes/nodes.json']) {
        if (await FileStorage.exists('$base/$rel')) {
          nodesData = await FileStorage.readJsonFile('$base/$rel');
          break;
        }
      }
    }
    nodesData ??= {'nodes': []};

    final rawNodes = (nodesData['nodes'] as List<dynamic>? ?? const [])
        .cast<dynamic>();
    final nodesById = <String, Map<String, dynamic>>{};
    for (final n in rawNodes) {
      if (n is Map) {
        final m = Map<String, dynamic>.from(n);
        final id = m['id']?.toString();
        if (id != null && id.isNotEmpty) {
          nodesById[id] = m;
        }
      }
    }

    final tagsList = (config['tags'] as List<dynamic>? ?? const [])
        .cast<dynamic>();
    final chapters = <QuestChapter>[];
    final usedChapterIds = <String>{};
    final startNodeId = config['startNodeId']?.toString();

    final nodesByChapter = <String, List<Map<String, dynamic>>>{};
    for (final entry in nodesById.entries) {
      final chId = entry.value['chapterId']?.toString() ?? '';
      nodesByChapter.putIfAbsent(chId, () => []).add(entry.value);
    }

    int cmpNodes(Map<String, dynamic> a, Map<String, dynamic> b) {
      if (startNodeId != null) {
        if (a['id'] == startNodeId) return -1;
        if (b['id'] == startNodeId) return 1;
      }
      final ay = (a['y'] as num?)?.toDouble() ?? 0;
      final by = (b['y'] as num?)?.toDouble() ?? 0;
      if (ay != by) return ay.compareTo(by);
      final ax = (a['x'] as num?)?.toDouble() ?? 0;
      final bx = (b['x'] as num?)?.toDouble() ?? 0;
      return ax.compareTo(bx);
    }

    String? startChapterId;
    if (startNodeId != null && nodesById[startNodeId] != null) {
      startChapterId = nodesById[startNodeId]!['chapterId']?.toString();
    }

    void addChapter(Map<String, dynamic> tag) {
      final id = tag['id']?.toString() ?? '';
      if (id.isEmpty || usedChapterIds.contains(id)) return;
      final name = tag['name']?.toString() ?? tr('Глава');
      final list = nodesByChapter[id] ?? const <Map<String, dynamic>>[];
      final sorted = [...list]..sort(cmpNodes);
      chapters.add(QuestChapter(id: id, name: name, nodes: sorted));
      usedChapterIds.add(id);
    }

    if (startChapterId != null && startChapterId.isNotEmpty) {
      for (final t in tagsList) {
        if (t is Map && t['id']?.toString() == startChapterId) {
          addChapter(Map<String, dynamic>.from(t));
          break;
        }
      }
    }
    for (final t in tagsList) {
      if (t is Map) addChapter(Map<String, dynamic>.from(t));
    }

    final orphanNodes = <Map<String, dynamic>>[];
    for (final entry in nodesByChapter.entries) {
      if (!usedChapterIds.contains(entry.key)) {
        orphanNodes.addAll(entry.value);
      }
    }
    if (orphanNodes.isNotEmpty) {
      final sorted = [...orphanNodes]..sort(cmpNodes);
      chapters.add(
        QuestChapter(id: '__orphan__', name: tr('Без главы'), nodes: sorted),
      );
    }

    // Preview
    Uint8List? previewBytes;
    String? previewMime;
    final previewFileName = config['previewFileName']?.toString();
    final previewCandidates = <String>[
      if (previewFileName != null && previewFileName.isNotEmpty)
        '$base/$previewFileName',
      '$base/preview.png',
      '$base/preview.jpg',
      '$base/preview.jpeg',
      '$base/preview.webp',
    ];
    for (final candidate in previewCandidates) {
      if (await FileStorage.exists(candidate)) {
        try {
          final file = File(await FileStorage.getFilePath(candidate));
          previewBytes = await file.readAsBytes();
          previewMime = _guessImageMime(candidate);
          break;
        } catch (_) {}
      }
    }

    // Кастомный шрифт
    Uint8List? customFontBytes;
    final customFontFileName = config['customFontFileName']?.toString();
    if (customFontFileName != null && customFontFileName.isNotEmpty) {
      final fontPath = '$base/res/fonts/$customFontFileName';
      if (await FileStorage.exists(fontPath)) {
        try {
          final file = File(await FileStorage.getFilePath(fontPath));
          customFontBytes = await file.readAsBytes();
        } catch (_) {}
      }
    }

    return QuestBook(
      id: questId,
      title: config['title']?.toString() ?? tr('Без названия'),
      author: config['author']?.toString(),
      description: config['description']?.toString(),
      startNodeId: startNodeId,
      nodesById: nodesById,
      chapters: chapters,
      previewBytes: previewBytes,
      previewMime: previewMime,
      customFontFileName: customFontFileName,
      customFontBytes: customFontBytes,
    );
  }

  // ---------------------------------------------------------------------------
  //  Сохранение
  // ---------------------------------------------------------------------------

  static Future<bool> _saveBytes({
    required Uint8List bytes,
    required String suggestedFileName,
    required String dialogTitle,
    required List<String> extensions,
  }) async {
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final result = await FilePicker.saveFile(
          dialogTitle: dialogTitle,
          fileName: suggestedFileName,
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: extensions,
        );
        return result != null;
      } else {
        final tempDir = await getTemporaryDirectory();
        final tempFile = File(p.join(tempDir.path, suggestedFileName));
        await tempFile.writeAsBytes(bytes);
        final params = SaveFileDialogParams(
          sourceFilePath: tempFile.path,
          fileName: suggestedFileName,
        );
        final result = await FlutterFileDialog.saveFile(params: params);
        try {
          await tempFile.delete();
        } catch (_) {}
        return result != null;
      }
    } catch (e) {
      // ignore: avoid_print
      print('❌ [DocExport] Не удалось сохранить файл: $e');
      rethrow;
    }
  }

  static String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_').trim();

  static String _guessImageMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    return 'image/png';
  }
}
