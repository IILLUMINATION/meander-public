import 'dart:io';

import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'quest_book_models.dart';
import 'quest_pdf_options.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';

/// Сборка PDF-документа для экспортированного квеста.
///
/// — каждая нода на отдельной странице (без спойлеров);
/// — кнопки выбора без раскрытия имени целевой ноды;
/// — кастомизируемая тема (light / dark / sepia / parchment);
/// — конфигурируемый размер шрифта;
/// — обложка с превью без обрезки + плашка «Сделано в Meander» со ссылками
///   на Google Play и сайт;
/// — скрипты полностью игнорируются.
class QuestPdfBuilder {
  static const String _googlePlayUrl =
      'https://play.google.com/store/apps/details?id=com.IILLUMINAT.meadner';
  static const String _websiteUrl = 'https://meander.illuminat.dev/';

  static Future<Uint8List> build(
    QuestBook book, {
    PdfExportOptions options = const PdfExportOptions(),
  }) async {
    final regularFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
    );
    final italicFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Italic.ttf'),
    );

    final colors = options.theme.colors;
    final baseFont = options.textSize.basePt;

    final doc = pw.Document(
      title: book.title,
      author: book.author ?? 'Meander',
      creator: 'Meander',
      theme: pw.ThemeData.withFont(
        base: regularFont,
        bold: boldFont,
        italic: italicFont,
      ),
    );

    final imageCache = <String, pw.MemoryImage>{};
    Future<pw.MemoryImage?> loadImage(String relPath) async {
      if (relPath.isEmpty) return null;
      if (imageCache.containsKey(relPath)) return imageCache[relPath];
      try {
        // Тот же резолвер, что и в плеере: в поле фона или картинки автор мог
        // оставить имя из библиотеки либо uuid, а не точный путь.
        final relative =
            await QuestImageSource.resolveRelative(book.id, relPath) ?? relPath;
        final fullPath = await FileStorage.getFilePath(
          QuestPaths.questFile(book.id, relative),
        );
        final file = File(fullPath);
        if (!await file.exists()) return null;
        final bytes = await file.readAsBytes();
        final img = pw.MemoryImage(bytes);
        imageCache[relPath] = img;
        return img;
      } catch (_) {
        return null;
      }
    }

    pw.MemoryImage? previewImage;
    if (book.previewBytes != null) {
      try {
        previewImage = pw.MemoryImage(book.previewBytes!);
      } catch (_) {}
    }

    // === Титульная страница ===
    if (options.includeCover) {
      doc.addPage(
        _buildCoverPage(book, previewImage, colors, baseFont, options),
      );
    }

    // === Главы и ноды ===
    final showChapterDividers = book.chapters.length > 1;

    for (var c = 0; c < book.chapters.length; c++) {
      final chapter = book.chapters[c];

      if (showChapterDividers) {
        doc.addPage(
          _buildChapterDivider(
            chapter,
            chapterIndex: c + 1,
            colors: colors,
            baseFont: baseFont,
          ),
        );
      }

      for (final node in chapter.nodes) {
        final widgets = await _buildNodeBody(
          node,
          book,
          loadImage,
          colors,
          baseFont,
          options,
        );
        doc.addPage(_buildNodePage(node, widgets, colors, baseFont, options));
      }
    }

    return doc.save();
  }

  // ---------------------------------------------------------------------------
  //  Титульная страница
  // ---------------------------------------------------------------------------

  static pw.Page _buildCoverPage(
    QuestBook book,
    pw.MemoryImage? preview,
    PdfThemeColors c,
    double baseFont,
    PdfExportOptions options,
  ) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(0),
      build: (ctx) => pw.Stack(
        children: [
          pw.Positioned.fill(child: pw.Container(color: c.background)),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(60, 70, 60, 50),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (preview != null)
                  // ВАЖНО: BoxFit.contain + ограничение по высоте, чтобы
                  // картинка вписывалась без обрезки. ClipRRect c hairline
                  // обрамлением для визуальной аккуратности.
                  pw.Container(
                    width: double.infinity,
                    margin: const pw.EdgeInsets.only(bottom: 36),
                    child: pw.Center(
                      child: pw.ClipRRect(
                        horizontalRadius: 6,
                        verticalRadius: 6,
                        child: pw.Container(
                          decoration: pw.BoxDecoration(
                            border: pw.Border.all(
                              color: c.hairline,
                              width: 0.5,
                            ),
                            borderRadius: const pw.BorderRadius.all(
                              pw.Radius.circular(6),
                            ),
                          ),
                          child: pw.Image(
                            preview,
                            fit: pw.BoxFit.contain,
                            height: 280,
                          ),
                        ),
                      ),
                    ),
                  ),
                pw.Text(
                  book.title,
                  style: pw.TextStyle(
                    fontSize: 34,
                    fontWeight: pw.FontWeight.bold,
                    color: c.ink,
                    height: 1.15,
                    letterSpacing: -0.5,
                  ),
                ),
                if ((book.author ?? '').isNotEmpty) ...[
                  pw.SizedBox(height: 12),
                  pw.Text(
                    book.author!,
                    style: pw.TextStyle(
                      fontSize: 14,
                      color: c.inkSoft,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
                pw.SizedBox(height: 24),
                pw.Container(width: 60, height: 2, color: c.accent),
                if ((book.description ?? '').isNotEmpty) ...[
                  pw.SizedBox(height: 24),
                  pw.Text(
                    book.description!,
                    style: pw.TextStyle(
                      fontSize: baseFont,
                      color: c.inkSoft,
                      lineSpacing: 4,
                      fontStyle: pw.FontStyle.italic,
                    ),
                  ),
                ],
                pw.Spacer(),
                // Брендинг присутствует всегда (часть условий использования).
                _meanderBanner(c),
                pw.SizedBox(height: 10),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      trf('Экспортировано: {p0}', {'p0': _formatDate(DateTime.now())}),
                      style: pw.TextStyle(fontSize: 8.5, color: c.mutedSoft),
                    ),
                    pw.Text(
                      'meander.illuminat.dev',
                      style: pw.TextStyle(fontSize: 8.5, color: c.mutedSoft),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Брендинговая плашка для обложки: «Сделано в Meander» + ссылки.
  static pw.Widget _meanderBanner(PdfThemeColors c) {
    return pw.Container(
      width: double.infinity,
      decoration: pw.BoxDecoration(
        color: c.surface,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10)),
        border: pw.Border.all(color: c.hairline, width: 0.6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // Верхняя часть: лого + текст
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                // Лого-знак: квадрат с буквой M, мягкий радиус
                pw.Container(
                  width: 44,
                  height: 44,
                  decoration: pw.BoxDecoration(
                    color: c.accent,
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(10),
                    ),
                  ),
                  child: pw.Center(
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 2),
                      child: pw.Text(
                        'M',
                        style: pw.TextStyle(
                          fontSize: 26,
                          fontWeight: pw.FontWeight.bold,
                          color: c.surface,
                          letterSpacing: -1,
                        ),
                      ),
                    ),
                  ),
                ),
                pw.SizedBox(width: 16),
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'MEANDER',
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                          color: c.muted,
                          letterSpacing: 3,
                        ),
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(
                        tr('Сделано в Meander'),
                        style: pw.TextStyle(
                          fontSize: 15,
                          fontWeight: pw.FontWeight.bold,
                          color: c.ink,
                          letterSpacing: -0.2,
                          height: 1.1,
                        ),
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(
                        tr('Конструктор и плеер текстовых квестов'),
                        style: pw.TextStyle(
                          fontSize: 10,
                          color: c.muted,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Разделитель
          pw.Container(height: 0.6, color: c.hairline),
          // Нижняя часть: кнопки-ссылки
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: _bannerLink(
                    c,
                    'Скачать в Google Play',
                    _googlePlayUrl,
                    primary: true,
                  ),
                ),
                pw.SizedBox(width: 10),
                pw.Expanded(
                  child: _bannerLink(
                    c,
                    'meander.illuminat.dev',
                    _websiteUrl,
                    primary: false,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Кнопка-ссылка для плашки. [primary] — залитая акцентом / outline.
  static pw.Widget _bannerLink(
    PdfThemeColors c,
    String label,
    String url, {
    required bool primary,
  }) {
    return pw.UrlLink(
      destination: url,
      child: pw.Container(
        height: 30,
        decoration: pw.BoxDecoration(
          color: primary ? c.accent : c.surface,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          border: primary ? null : pw.Border.all(color: c.accent, width: 0.7),
        ),
        child: pw.Center(
          child: pw.Text(
            label,
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: primary ? c.surface : c.accent,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Разделитель главы
  // ---------------------------------------------------------------------------

  static pw.Page _buildChapterDivider(
    QuestChapter chapter, {
    required int chapterIndex,
    required PdfThemeColors colors,
    required double baseFont,
  }) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(0),
      build: (ctx) => pw.Stack(
        children: [
          pw.Positioned.fill(child: pw.Container(color: colors.background)),
          pw.Padding(
            padding: const pw.EdgeInsets.all(72),
            child: pw.Center(
              child: pw.Column(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text(
                    trf('ГЛАВА {p0}', {'p0': _romanize(chapterIndex)}),
                    style: pw.TextStyle(
                      fontSize: 11,
                      color: colors.muted,
                      letterSpacing: 4,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 24),
                  pw.Container(width: 40, height: 1, color: colors.hairline),
                  pw.SizedBox(height: 24),
                  pw.Text(
                    chapter.name,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(
                      fontSize: 28,
                      fontWeight: pw.FontWeight.bold,
                      color: colors.ink,
                      letterSpacing: -0.3,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Страница одной ноды
  // ---------------------------------------------------------------------------

  static pw.MultiPage _buildNodePage(
    Map<String, dynamic> node,
    List<pw.Widget> body,
    PdfThemeColors c,
    double baseFont,
    PdfExportOptions options,
  ) {
    final id = node['id']?.toString() ?? '';
    final title = node['title']?.toString() ?? '';

    return pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(64, 72, 64, 64),
        buildBackground: (ctx) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Container(color: c.background),
        ),
      ),
      footer: (ctx) => _pageFooter(ctx, c),
      build: (ctx) => [
        pw.Anchor(
          name: 'node_$id',
          child: pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 24),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  title.isEmpty ? tr('Без названия') : title,
                  style: pw.TextStyle(
                    fontSize: baseFont + 9,
                    fontWeight: pw.FontWeight.bold,
                    color: c.ink,
                    height: 1.2,
                    letterSpacing: -0.2,
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Container(width: 32, height: 1.5, color: c.accent),
              ],
            ),
          ),
        ),
        ...body,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  //  Содержимое ноды
  // ---------------------------------------------------------------------------

  static Future<List<pw.Widget>> _buildNodeBody(
    Map<String, dynamic> node,
    QuestBook book,
    Future<pw.MemoryImage?> Function(String) loadImage,
    PdfThemeColors c,
    double baseFont,
    PdfExportOptions options,
  ) async {
    final content = node['content'] as Map<String, dynamic>?;
    final items = (content?['items'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    final isEnding = !items.any((i) => i['type'] == 'button');

    final widgets = <pw.Widget>[];

    for (final item in items) {
      await _appendItem(item, widgets, loadImage, c, baseFont, options);
    }

    if (isEnding) {
      widgets.add(pw.SizedBox(height: 24));
      widgets.add(_endingMarker(c));
    }

    return widgets;
  }

  static Future<void> _appendItem(
    Map<String, dynamic> item,
    List<pw.Widget> widgets,
    Future<pw.MemoryImage?> Function(String) loadImage,
    PdfThemeColors c,
    double baseFont,
    PdfExportOptions options,
  ) async {
    final type = item['type']?.toString() ?? '';
    if (type == 'script') return;

    if (type == 'text') {
      widgets.add(
        _pdfTextBlock(item['text']?.toString() ?? '', c, baseFont, options),
      );
      widgets.add(pw.SizedBox(height: 6));
    } else if (type == 'image') {
      if (!options.includeImages) return;
      final path = item['resourcePath']?.toString() ?? '';
      final img = await loadImage(path);
      if (img != null) {
        widgets.add(
          pw.Container(
            margin: const pw.EdgeInsets.symmetric(vertical: 10),
            child: pw.Center(
              child: pw.ClipRRect(
                horizontalRadius: 4,
                verticalRadius: 4,
                child: pw.Image(img, fit: pw.BoxFit.contain, height: 280),
              ),
            ),
          ),
        );
      }
    } else if (type == 'audio') {
      final path = item['resourcePath']?.toString() ?? '';
      widgets.add(
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(vertical: 6),
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: c.hairline, width: 0.5),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(2)),
          ),
          child: pw.Text(
            trf('Аудио · {p0}', {'p0': _basename(path)}),
            style: pw.TextStyle(
              fontSize: baseFont - 2.5,
              color: c.muted,
              letterSpacing: 0.5,
            ),
          ),
        ),
      );
    } else if (type == 'button') {
      final targetId = item['targetNodeId']?.toString();
      final text = item['text']?.toString() ?? '';
      widgets.add(
        _choiceBlock(text, targetId, c, baseFont, options.linkChoices),
      );
    } else if (type == 'input') {
      widgets.add(
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(vertical: 6),
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: c.hairline, width: 0.5),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
            color: c.surface,
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if ((item['text']?.toString() ?? '').isNotEmpty)
                pw.Text(
                  item['text']!.toString(),
                  style: pw.TextStyle(fontSize: baseFont - 0.5, color: c.ink),
                ),
              pw.SizedBox(height: 6),
              pw.Container(
                height: 22,
                decoration: pw.BoxDecoration(
                  border: pw.Border(
                    bottom: pw.BorderSide(color: c.hairline, width: 1),
                  ),
                ),
                child: pw.Align(
                  alignment: pw.Alignment.bottomLeft,
                  child: pw.Text(
                    item['placeholderText']?.toString() ?? tr('поле для ввода'),
                    style: pw.TextStyle(
                      fontSize: baseFont - 1.5,
                      color: c.mutedSoft,
                      fontStyle: pw.FontStyle.italic,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (type == 'chat') {
      final isIncoming = item['isIncoming'] as bool? ?? true;
      final sender = item['senderName']?.toString() ?? '';
      widgets.add(
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(vertical: 4),
          alignment: isIncoming
              ? pw.Alignment.centerLeft
              : pw.Alignment.centerRight,
          child: pw.ConstrainedBox(
            constraints: const pw.BoxConstraints(maxWidth: 380),
            child: pw.Container(
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: pw.BoxDecoration(
                color: isIncoming ? c.chatIn : c.chatOut,
                borderRadius: pw.BorderRadius.only(
                  topLeft: pw.Radius.circular(10),
                  topRight: pw.Radius.circular(10),
                  bottomLeft: pw.Radius.circular(isIncoming ? 2.0 : 10.0),
                  bottomRight: pw.Radius.circular(isIncoming ? 10.0 : 2.0),
                ),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (sender.isNotEmpty)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 4),
                      child: pw.Text(
                        sender,
                        style: pw.TextStyle(
                          fontSize: baseFont - 2.5,
                          fontWeight: pw.FontWeight.bold,
                          color: c.inkSoft,
                        ),
                      ),
                    ),
                  pw.Text(
                    item['text']?.toString() ?? '',
                    style: pw.TextStyle(
                      fontSize: baseFont - 0.5,
                      color: c.ink,
                      lineSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } else if (type == 'row' || type == 'column') {
      final children = (item['children'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      for (final ch in children) {
        await _appendItem(ch, widgets, loadImage, c, baseFont, options);
      }
    }
  }

  static pw.Widget _choiceBlock(
    String text,
    String? targetNodeId,
    PdfThemeColors c,
    double baseFont,
    bool linkEnabled,
  ) {
    final inner = pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.symmetric(vertical: 4),
      padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: pw.BoxDecoration(
        color: c.choiceFill,
        border: pw.Border.all(color: c.hairline, width: 0.7),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(2)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            margin: const pw.EdgeInsets.only(top: 1, right: 10),
            child: pw.Text(
              '>',
              style: pw.TextStyle(
                fontSize: baseFont - 0.5,
                fontWeight: pw.FontWeight.bold,
                color: c.accent,
              ),
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              text,
              style: pw.TextStyle(
                fontSize: baseFont,
                color: c.ink,
                fontWeight: pw.FontWeight.bold,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );

    if (!linkEnabled || targetNodeId == null || targetNodeId.isEmpty) {
      return inner;
    }
    return pw.Link(destination: 'node_$targetNodeId', child: inner);
  }

  /// Брендинговый футер на каждой странице ноды.
  /// Содержит ссылку на сайт и название — формирует «защиту» брендинга
  /// (присутствует в нескольких местах документа).
  static pw.Widget _pageFooter(pw.Context ctx, PdfThemeColors c) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 12),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.UrlLink(
            destination: _websiteUrl,
            child: pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Container(
                  width: 10,
                  height: 10,
                  decoration: pw.BoxDecoration(
                    color: c.accent,
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(2),
                    ),
                  ),
                  child: pw.Center(
                    child: pw.Text(
                      'M',
                      style: pw.TextStyle(
                        fontSize: 7,
                        fontWeight: pw.FontWeight.bold,
                        color: c.surface,
                      ),
                    ),
                  ),
                ),
                pw.SizedBox(width: 6),
                pw.Text(
                  'Meander · meander.illuminat.dev',
                  style: pw.TextStyle(
                    fontSize: 8,
                    color: c.mutedSoft,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          pw.Spacer(),
          pw.Text(
            '${ctx.pageNumber}',
            style: pw.TextStyle(fontSize: 9, color: c.mutedSoft),
          ),
        ],
      ),
    );
  }

  static pw.Widget _endingMarker(PdfThemeColors c) {
    return pw.Center(
      child: pw.Column(
        children: [
          pw.Container(width: 40, height: 1, color: c.hairline),
          pw.SizedBox(height: 12),
          pw.Text(
            tr('К О Н Е Ц'),
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: c.muted,
              letterSpacing: 5,
            ),
          ),
          pw.SizedBox(height: 12),
          pw.Container(width: 40, height: 1, color: c.hairline),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Markdown → PDF
  // ---------------------------------------------------------------------------

  static pw.Widget _pdfTextBlock(
    String raw,
    PdfThemeColors c,
    double baseFont,
    PdfExportOptions options,
  ) {
    if (raw.trim().isEmpty) return pw.SizedBox(height: 6);
    final lines = raw.split('\n');
    final blocks = <pw.Widget>[];
    bool inCode = false;
    final codeBuf = StringBuffer();

    void flushCode() {
      if (codeBuf.isEmpty) return;
      blocks.add(
        pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.symmetric(vertical: 6),
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: c.codeBg,
            border: pw.Border(left: pw.BorderSide(color: c.hairline, width: 2)),
          ),
          child: pw.Text(
            codeBuf.toString().trimRight(),
            style: pw.TextStyle(
              fontSize: baseFont - 2.0,
              color: c.inkSoft,
              lineSpacing: 1.5,
            ),
          ),
        ),
      );
      codeBuf.clear();
    }

    for (final line in lines) {
      if (line.trimLeft().startsWith('```')) {
        if (inCode) {
          flushCode();
          inCode = false;
        } else {
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        codeBuf.writeln(line);
        continue;
      }
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('### ')) {
        blocks.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 10, bottom: 4),
            child: pw.Text(
              trimmed.substring(4),
              style: pw.TextStyle(
                fontSize: baseFont + 2,
                fontWeight: pw.FontWeight.bold,
                color: c.ink,
              ),
            ),
          ),
        );
      } else if (trimmed.startsWith('## ')) {
        blocks.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 12, bottom: 5),
            child: pw.Text(
              trimmed.substring(3),
              style: pw.TextStyle(
                fontSize: baseFont + 4,
                fontWeight: pw.FontWeight.bold,
                color: c.ink,
              ),
            ),
          ),
        );
      } else if (trimmed.startsWith('# ')) {
        blocks.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
            child: pw.Text(
              trimmed.substring(2),
              style: pw.TextStyle(
                fontSize: baseFont + 6,
                fontWeight: pw.FontWeight.bold,
                color: c.ink,
              ),
            ),
          ),
        );
      } else if (trimmed.startsWith('> ')) {
        blocks.add(
          pw.Container(
            width: double.infinity,
            margin: const pw.EdgeInsets.symmetric(vertical: 4),
            padding: const pw.EdgeInsets.only(left: 12, top: 2, bottom: 2),
            decoration: pw.BoxDecoration(
              border: pw.Border(left: pw.BorderSide(color: c.accent, width: 2)),
            ),
            child: pw.RichText(
              text: _parseInline(
                trimmed.substring(2),
                c,
                base: pw.TextStyle(
                  fontSize: baseFont,
                  color: c.inkSoft,
                  fontStyle: pw.FontStyle.italic,
                  lineSpacing: 1.5,
                ),
              ),
            ),
          ),
        );
      } else if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        blocks.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 14, top: 2, bottom: 2),
            child: pw.RichText(
              text: pw.TextSpan(
                children: [
                  pw.TextSpan(
                    text: '•   ',
                    style: pw.TextStyle(
                      fontSize: baseFont,
                      color: c.accent,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  _parseInline(
                    trimmed.substring(2),
                    c,
                    base: pw.TextStyle(
                      fontSize: baseFont,
                      color: c.ink,
                      lineSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      } else if (RegExp(r'^\d+\.\s').hasMatch(trimmed)) {
        blocks.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 14, top: 2, bottom: 2),
            child: pw.RichText(
              text: _parseInline(
                trimmed,
                c,
                base: pw.TextStyle(
                  fontSize: baseFont,
                  color: c.ink,
                  lineSpacing: 1.5,
                ),
              ),
            ),
          ),
        );
      } else if (trimmed.isEmpty) {
        blocks.add(pw.SizedBox(height: 6));
      } else {
        blocks.add(
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.RichText(
              text: _parseInline(
                line,
                c,
                base: pw.TextStyle(
                  fontSize: baseFont,
                  color: c.ink,
                  lineSpacing: 1.5,
                ),
              ),
              textAlign: options.justifyText
                  ? pw.TextAlign.justify
                  : pw.TextAlign.left,
            ),
          ),
        );
      }
    }
    if (inCode) flushCode();
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: blocks,
    );
  }

  static pw.TextSpan _parseInline(
    String input,
    PdfThemeColors c, {
    required pw.TextStyle base,
  }) {
    final children = <pw.TextSpan>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isEmpty) return;
      children.add(pw.TextSpan(text: buf.toString(), style: base));
      buf.clear();
    }

    int i = 0;
    while (i < input.length) {
      final rest = input.substring(i);

      final colorMatch = RegExp(
        r'^\[color=#([0-9A-Fa-f]{6})\](.*?)\[/color\]',
      ).firstMatch(rest);
      if (colorMatch != null) {
        flush();
        final hex = colorMatch.group(1)!;
        final r = int.parse(hex.substring(0, 2), radix: 16);
        final g = int.parse(hex.substring(2, 4), radix: 16);
        final b = int.parse(hex.substring(4, 6), radix: 16);
        children.add(
          pw.TextSpan(
            text: colorMatch.group(2),
            style: base.copyWith(
              color: PdfColor.fromInt(0xFF000000 | (r << 16) | (g << 8) | b),
            ),
          ),
        );
        i += colorMatch.end;
        continue;
      }

      final linkMatch = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)').firstMatch(rest);
      if (linkMatch != null) {
        flush();
        children.add(
          pw.TextSpan(
            text: linkMatch.group(1),
            style: base.copyWith(
              color: c.accent,
              decoration: pw.TextDecoration.underline,
            ),
            annotation: pw.AnnotationUrl(linkMatch.group(2) ?? ''),
          ),
        );
        i += linkMatch.end;
        continue;
      }

      if (rest.startsWith('**')) {
        final end = rest.indexOf('**', 2);
        if (end > 2) {
          flush();
          children.add(
            pw.TextSpan(
              text: rest.substring(2, end),
              style: base.copyWith(fontWeight: pw.FontWeight.bold),
            ),
          );
          i += end + 2;
          continue;
        }
      }
      if (rest.startsWith('*') && !rest.startsWith('**')) {
        final end = rest.indexOf('*', 1);
        if (end > 1) {
          flush();
          children.add(
            pw.TextSpan(
              text: rest.substring(1, end),
              style: base.copyWith(fontStyle: pw.FontStyle.italic),
            ),
          );
          i += end + 1;
          continue;
        }
      }
      if (rest.startsWith('`')) {
        final end = rest.indexOf('`', 1);
        if (end > 1) {
          flush();
          children.add(
            pw.TextSpan(
              text: rest.substring(1, end),
              style: base.copyWith(
                color: c.inkSoft,
                background: pw.BoxDecoration(color: c.codeBg),
              ),
            ),
          );
          i += end + 1;
          continue;
        }
      }
      buf.write(input[i]);
      i++;
    }
    flush();
    return pw.TextSpan(text: '', children: children);
  }

  // ---------------------------------------------------------------------------
  //  Утилиты
  // ---------------------------------------------------------------------------

  static String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}';
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  static String _romanize(int n) {
    if (n <= 0 || n > 3999) return n.toString();
    const vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const syms = [
      'M',
      'CM',
      'D',
      'CD',
      'C',
      'XC',
      'L',
      'XL',
      'X',
      'IX',
      'V',
      'IV',
      'I',
    ];
    final out = StringBuffer();
    var v = n;
    for (var i = 0; i < vals.length; i++) {
      while (v >= vals[i]) {
        out.write(syms[i]);
        v -= vals[i];
      }
    }
    return out.toString();
  }
}
