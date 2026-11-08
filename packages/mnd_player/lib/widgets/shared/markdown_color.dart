import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_widget/markdown_widget.dart';
import 'package:mnd_core/models/content_item.dart';
import 'package:mnd_player/services/font_service.dart';

class ColorTagSyntax extends md.InlineSyntax {
  static const String tag = 'color';

  ColorTagSyntax()
    : super(
        r'\[color=(#[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{8})\]([\s\S]*?)\[\/color\]',
        startCharacter: 0x5B, // [
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final colorValue = match.group(1);
    final content = match.group(2) ?? '';
    final children = parser.document.parseInline(content);
    final element = md.Element(tag, children);
    if (colorValue != null) {
      element.attributes['value'] = colorValue;
    }
    parser.addNode(element);
    return true;
  }
}

class ColorNode extends ElementNode {
  final Color color;

  ColorNode(this.color);

  @override
  TextStyle get style =>
      parentStyle?.merge(TextStyle(color: color)) ?? TextStyle(color: color);
}

/// Инлайн-тег шрифта `[font=res/fonts/x.ttf]…[/font]` в markdown-пути.
class FontTagSyntax extends md.InlineSyntax {
  static const String tag = 'font';

  FontTagSyntax()
    : super(
        r'\[font=([^\]]+)\]([\s\S]*?)\[\/font\]',
        startCharacter: 0x5B, // [
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final path = match.group(1)?.trim();
    final content = match.group(2) ?? '';
    final children = parser.document.parseInline(content);
    final element = md.Element(tag, children);
    if (path != null && path.isNotEmpty) {
      element.attributes['value'] = path;
    }
    parser.addNode(element);
    return true;
  }
}

class FontNode extends ElementNode {
  final String? fontFamily;

  FontNode(this.fontFamily);

  @override
  TextStyle get style =>
      parentStyle?.merge(TextStyle(fontFamily: fontFamily)) ??
      TextStyle(fontFamily: fontFamily);
}

/// Как слой markdown обращается с фрагментной обводкой `[outline=…]`.
///
/// Обводку рисует ОТДЕЛЬНЫЙ штриховой слой под заливкой: `[none]` — слой
/// заливки, обводку не трогает; `[stroke]` — слой контура, каждый фрагмент
/// рисуется своей кистью (цвет и толщина тега). Копий глифа со сдвигом здесь
/// нет намеренно: они давали раздвоенный контур и расходились с игрой.
class OutlineTagSyntax extends md.InlineSyntax {
  static const String tag = 'outline';

  OutlineTagSyntax()
    : super(
        r'\[outline=(#[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{8})(?::([0-9]+(?:\.[0-9]+)?))?\]([\s\S]*?)\[\/outline\]',
        startCharacter: 0x5B, // [
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final content = match.group(3) ?? '';
    final children = parser.document.parseInline(content);
    final element = md.Element(tag, children);
    final color = match.group(1);
    final width = match.group(2);
    if (color != null) element.attributes['color'] = color;
    if (width != null) element.attributes['width'] = width;
    parser.addNode(element);
    return true;
  }
}

enum TextOutlineMode {
  /// Слой заливки: обводку не рисуем, её кладёт нижний слой.
  none,

  /// Штриховой слой: фрагмент рисуется кистью своего тега.
  stroke,
}

class OutlineNode extends ElementNode {
  final Color color;
  final double width;
  final TextOutlineMode mode;

  OutlineNode(this.color, this.width, {this.mode = TextOutlineMode.none});

  @override
  TextStyle get style {
    final parent = parentStyle;
    if (mode == TextOutlineMode.none) return parent ?? const TextStyle();
    // Кисть одна на все поверхности: толщина трактуется и клэмпится ядром.
    final paint = textOutlineStroke(color, width: width);
    return parent?.merge(TextStyle(foreground: paint)) ??
        TextStyle(foreground: paint);
  }
}

class EmphasisNode extends ElementNode {
  @override
  TextStyle get style =>
      parentStyle?.merge(
        const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic),
      ) ??
      const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic);
}

MarkdownGenerator createColorMarkdownGenerator({
  EdgeInsets linesMargin = const EdgeInsets.symmetric(vertical: 2),
  RegExp? splitRegExp,
  String? questId,
  TextOutlineMode outlineMode = TextOutlineMode.none,
}) {
  return MarkdownGenerator(
    inlineSyntaxList: [
      OutlineTagSyntax(),
      ColorTagSyntax(),
      // [font=] резолвится в family-имя только зная квест; без questId
      // тег остаётся буквальным текстом (редакторы без игрового контекста).
      if (questId != null) FontTagSyntax(),
    ],
    linesMargin: linesMargin,
    splitRegExp: splitRegExp,
    generators: [
      SpanNodeGeneratorWithTag(
        tag: OutlineTagSyntax.tag,
        generator: (e, config, visitor) {
          final color = _parseColor(e.attributes['color'] ?? '');
          final width = double.tryParse(e.attributes['width'] ?? '');
          return OutlineNode(
            color,
            width ?? kTextOutlineWidthDefault,
            mode: outlineMode,
          );
        },
      ),
      SpanNodeGeneratorWithTag(
        tag: ColorTagSyntax.tag,
        generator: (e, config, visitor) {
          final colorValue = e.attributes['value'];
          return ColorNode(_parseColor(colorValue));
        },
      ),
      if (questId != null)
        SpanNodeGeneratorWithTag(
          tag: FontTagSyntax.tag,
          generator: (e, config, visitor) {
            final path = e.attributes['value'];
            return FontNode(FontService.resolveFamily(questId, path));
          },
        ),
      SpanNodeGeneratorWithTag(
        tag: 'em',
        generator: (e, config, visitor) => EmphasisNode(),
      ),
    ],
  );
}

/// Безопасный маркер списка: дефолтный маркер markdown_widget считает
/// `EdgeInsets.only(top: paddingTop - 1.5)`, где paddingTop = fontSize*height/2.
/// При малом размере шрифта получается отрицательный padding →
/// assertion `padding.isNonNegative`. Наш маркер использует неотрицательные
/// отступы и повторяет внешний вид дефолтного маркера.
Widget? Function(bool isOrdered, int depth, int index) safeListMarker(
  Color color,
) {
  return (isOrdered, depth, index) {
    if (isOrdered) {
      return Text(
        '${index + 1}.',
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 5, right: 6),
      child: Container(
        width: 6,
        height: 6,
        decoration: depth % 3 == 0
            ? BoxDecoration(shape: BoxShape.circle, color: color)
            : depth % 3 == 1
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color),
              )
            : BoxDecoration(color: color),
      ),
    );
  };
}

/// Безопасный чекбокс: дефолтный builder markdown_widget считает
/// `EdgeInsets.fromLTRB(2, parentStyleHeight/2 - 12, 2, 0)`, что отрицательно
/// при fontSize*height < 24 → assertion `padding.isNonNegative`.
Widget Function(bool checked) safeCheckboxBuilder(Color color) {
  return (checked) => Padding(
    padding: const EdgeInsets.only(top: 2, right: 4),
    child: Icon(
      checked ? Icons.check_box : Icons.check_box_outline_blank,
      size: 20,
      color: color,
    ),
  );
}

String preserveMarkdownHardLineBreaks(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  if (lines.length <= 1) return normalized;

  bool isBlockMarkdownLine(String line) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty) return false;
    return RegExp(
      r'^(#{1,6}\s|[-*+]\s|\d+\.\s|>\s|```|~~~|\|)',
    ).hasMatch(trimmed);
  }

  final out = <String>[];
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    final isLast = i == lines.length - 1;
    if (isLast) {
      out.add(line);
      continue;
    }

    final isBlank = line.trim().isEmpty;
    final nextBlank = lines[i + 1].trim().isEmpty;
    final currentIsBlock = isBlockMarkdownLine(line);
    final nextIsBlock = isBlockMarkdownLine(lines[i + 1]);

    if (!isBlank && !nextBlank && !currentIsBlock && !nextIsBlock) {
      // Don't add hard break if line ends with a URL (causes visible backslash)
      final trimmedEnd = line.trimRight();
      final isUrl = RegExp(
        r'(https?://|www\.)[^\s]+$',
        caseSensitive: false,
      ).hasMatch(trimmedEnd);
      if (isUrl) {
        out.add(line);
      } else {
        out.add('$line\\');
      }
    } else {
      out.add(line);
    }
  }

  return out.join('\n');
}

Color _parseColor(String? colorStr) {
  if (colorStr == null) return Colors.white;
  if (colorStr.startsWith('#')) {
    String hex = colorStr.substring(1);
    if (hex.length == 6) {
      hex = 'FF$hex';
    }
    final value = int.tryParse(hex, radix: 16);
    if (value != null) {
      return Color(value);
    }
  }
  return Colors.white;
}
