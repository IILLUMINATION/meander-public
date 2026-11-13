import 'package:flutter/material.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';

class ExpandablePostText extends StatefulWidget {
  final String text;
  final int maxLines;

  const ExpandablePostText({
    super.key,
    required this.text,
    this.maxLines = 10,
  });

  @override
  State<ExpandablePostText> createState() => _ExpandablePostTextState();
}

class _ExpandablePostTextState extends State<ExpandablePostText> {
  bool _isExpanded = false;

  // Результат замера «помещается ли текст» переиспользуется между
  // перестройками: `TextPainter.layout` по всему тексту на каждый `build`
  // (а лента перестраивается на каждое событие сокета и каждый скролл) — это
  // десятки лишних раскладок в секунду.
  String? _measuredText;
  double? _measuredWidth;
  int? _measuredMaxLines;
  Object? _measuredStyle;
  TextScaler? _measuredScaler;
  double _measuredHeight = 0;
  bool _measuredOverflow = false;

  double _measureOverflow(
    BuildContext context,
    String text,
    double maxWidth,
    TextStyle? baseStyle,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    // Ключ — базовый стиль темы (стабильный объект на ThemeData), а не
    // результат `copyWith`: тот создаётся заново на каждый build.
    if (_measuredText == text &&
        _measuredWidth == maxWidth &&
        _measuredMaxLines == widget.maxLines &&
        identical(_measuredStyle, baseStyle) &&
        _measuredScaler == scaler) {
      return _measuredHeight;
    }

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: baseStyle?.copyWith(height: 1.45, fontSize: 14),
      ),
      maxLines: widget.maxLines,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: maxWidth);

    _measuredText = text;
    _measuredWidth = maxWidth;
    _measuredMaxLines = widget.maxLines;
    _measuredStyle = baseStyle;
    _measuredScaler = scaler;
    _measuredOverflow = textPainter.didExceedMaxLines;
    _measuredHeight = textPainter.height;
    return _measuredHeight;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final baseStyle = Theme.of(context).textTheme.bodyMedium;

        final textHeight = _measureOverflow(
          context,
          widget.text,
          constraints.maxWidth,
          baseStyle,
        );

        final isOverflowing = _measuredOverflow;

        final markdownConfig = AppMarkdown.getConfig(context);

        if (!isOverflowing || _isExpanded) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MeanderEntityMarkdown(data: widget.text, config: markdownConfig),
              if (_isExpanded)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: GestureDetector(
                    onTap: () => setState(() => _isExpanded = false),
                    child: Text(
                      tr('Свернуть'),
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                SizedBox(
                  height: textHeight,
                  child: ClipRect(
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: MeanderEntityMarkdown(
                        data: widget.text,
                        config: markdownConfig,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          scheme.surfaceContainerHigh.withOpacity(0.0),
                          scheme.surfaceContainerHigh.withOpacity(0.9),
                          scheme.surfaceContainerHigh,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            GestureDetector(
              onTap: () => setState(() => _isExpanded = true),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  tr('Читать далее...'),
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
