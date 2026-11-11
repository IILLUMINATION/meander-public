/// Рендереры контента квеста в браузере.
///
/// Это тонкая копия `ContentDisplayFactory` из `packages/mnd_player`: те же
/// решения по типам, та же трактовка `isHidden` / `set_visible` / `onAppear`,
/// та же раскладка ряда-колонки-стека. Отличия диктует браузер:
///
///  * картинок с диска нет — байты берём из `QuestBundle` (`Image.memory`);
///  * вместо Riverpod-подписки на состояние — `QuestPlayer`, который
///    пересобирает сцену через `notifyListeners()`;
///  * markdown-разбор свой, компактный (заголовки, списки, `**жирный**`,
///    `*курсив*, `[color=…]`, `[font=…]`, ссылки `node://`), без зависимости
///    от `markdown_widget`.
///
/// Клиент по-прежнему тупой: видимость, числа по формулам и вся логика
/// нажатий живут в движке.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mnd_core/engine/item_visibility.dart';
import 'package:mnd_core/models/content_item.dart';
import 'package:url_launcher/url_launcher.dart';

import 'player.dart';

/// Один айтем контента: видимость → рендер по типу → обёртка интерактива →
/// шаг очереди раскрытия.
class ItemView extends StatefulWidget {
  const ItemView({
    super.key,
    required this.player,
    required this.item,
    this.onComplete,
    this.insideRow = false,
    this.suppress = false,
    this.textFit = 'auto',
    this.rowTextAlign = 'center',
    this.bottomPadding = 0,
    this.imageRounded,
    this.fontFamily,
    this.stackFixedSize,
  });

  final QuestPlayer player;
  final ContentItem item;
  final VoidCallback? onComplete;
  final bool insideRow;

  /// Родитель забрал тап себе — дети не кликабельны.
  final bool suppress;
  final String textFit;
  final String rowTextAlign;
  final double bottomPadding;
  final bool? imageRounded;
  final String? fontFamily;

  /// Жёсткий габарит для стека: рамка закрепления ([ContentItem.stackPinRect])
  /// задаёт size, и холст обязан растянуться по ней, а не по проектным px.
  final Size? stackFixedSize;

  @override
  State<ItemView> createState() => _ItemViewState();
}

class _ItemViewState extends State<ItemView> {
  bool _childBuilt = false;
  bool _revealStepSkipped = false;

  /// Типы, которые сами говорят «я закончил» (звук, видео, таймер, контейнер,
  /// поле ввода, модалка). Остальные освобождают очередь сразу, как в
  /// нативной фабрике.
  static const Set<String> _selfManaging = {
    'audio',
    'video',
    'timer',
    'delay',
    'row',
    'column',
    'input',
    'wait_input',
    'modal',
  };

  QuestPlayer get player => widget.player;
  ContentItem get item => widget.item;

  void _completeNextFrame() {
    final onComplete = widget.onComplete;
    if (onComplete == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => onComplete());
  }

  /// Очередь раскрытия ждёт шаг от каждого айтема. Если движок спрятал айтем
  /// раньше, чем он собрался, ребёнок не отработает никогда — шагаем сами.
  void _skipRevealStep() {
    if (_childBuilt || _revealStepSkipped || widget.onComplete == null) return;
    _revealStepSkipped = true;
    _completeNextFrame();
  }

  @override
  void initState() {
    super.initState();
    // Первый проход with mutation — как `evaluateVisibility(allowMutation: true)`
    // в нативном `ConditionalContentWrapper`: условие могло записать значение.
    if (!_silentType && item.scriptForEvent('onAppear') != null) {
      final shown = player.evaluateAppearOnce(item);
      if (!shown) _skipRevealStep();
    }
  }

  bool get _silentType =>
      item.isHidden ||
      item.type == 'script' ||
      item.type == 'hud_panel' ||
      item.type == 'spacer';

  @override
  Widget build(BuildContext context) {
    // Статически скрытый: без звука и таймера — пустое место и шаг очереди.
    if (item.isHidden) {
      if (item.type == 'timer' || item.type == 'delay') return _timed();
      if (!_childBuilt) {
        _childBuilt = true;
        _completeNextFrame();
      }
      return const SizedBox.shrink();
    }
    if (item.type == 'script' || item.type == 'hud_panel') {
      if (!_childBuilt) {
        _childBuilt = true;
        _completeNextFrame();
      }
      return const SizedBox.shrink();
    }
    if (item.type == 'spacer') {
      if (!_childBuilt) {
        _childBuilt = true;
        _completeNextFrame();
      }
      final size = player
          .numeric(item, 'padding', item.padding ?? 16.0)
          .clamp(0.0, 999.0);
      return SizedBox(
        width: widget.insideRow ? size : null,
        height: widget.insideRow ? null : size,
      );
    }

    final visibility = player.visibilityOf(item);
    if (visibility == EngineVisibility.gone) {
      _skipRevealStep();
      return const SizedBox.shrink();
    }
    // «Скрыть»: место занято, ребёнок собирается как обычно — иначе он не
    // отдал бы шаг очереди раскрытия.
    final keepPlace = visibility == EngineVisibility.hidden;

    _childBuilt = true;
    Widget content = _content();
    if (!_selfManaging.contains(item.type)) {
      content = _Instant(onCompleted: widget.onComplete, child: content);
    }
    if (keepPlace) {
      content = IgnorePointer(
        ignoring: true,
        child: Opacity(opacity: 0, child: content),
      );
    }
    if (widget.bottomPadding > 0) {
      content = Padding(
        padding: EdgeInsets.only(bottom: widget.bottomPadding),
        child: content,
      );
    }
    return content;
  }

  Widget _timed() {
    return _TimerView(
      player: player,
      item: item,
      onComplete: widget.onComplete ?? () {},
    );
  }

  Widget _content() {
    final suppress = widget.suppress || _containerSuppresses(item);
    // Шрифт айтема (путь ресурса `res/fonts/…`) важнее унаследованного от
    // квеста — та же цепочка, что у нативной фабрики.
    final font = questFontFamily(item.fontFamily) ?? widget.fontFamily;
    Widget content;
    switch (item.type) {
      case 'row':
      case 'column':
        content = _ContainerView(
          player: player,
          item: item,
          onComplete: widget.onComplete ?? () {},
          suppress: suppress,
          textFit: item.textFit,
          rowTextAlign: item.rowTextAlignment,
          imageRounded: item.childImageRoundedCorners ?? widget.imageRounded,
          fontFamily: font,
        );
        break;
      case 'stack':
        content = StackLayerView(
          player: player,
          item: item,
          suppress: suppress,
          imageRounded: widget.imageRounded,
          fontFamily: font,
          stretchWidth:
              widget.stackFixedSize != null && item.stackPinStretchesWidth,
          stretchHeight:
              widget.stackFixedSize != null && item.stackPinStretchesHeight,
          fixedSize: widget.stackFixedSize,
        );
        break;
      case 'text':
        content = _TextView(
          player: player,
          item: item,
          insideRow: widget.insideRow,
          suppress: widget.suppress,
          textFit: widget.textFit,
          rowTextAlign: widget.rowTextAlign,
          fontFamily: font,
        );
        break;
      case 'button':
        content = _ButtonView(
          player: player,
          item: item,
          suppress: widget.suppress,
          fontFamily: font,
        );
        break;
      case 'image':
        content = _ImageView(
          player: player,
          item: item,
          suppress: widget.suppress,
          rounded: widget.imageRounded ?? true,
        );
        break;
      case 'input':
      case 'wait_input':
        content = _InputView(
          player: player,
          item: item,
          onComplete: widget.onComplete ?? () {},
          fontFamily: widget.fontFamily,
        );
        break;
      case 'chat':
        content = _ChatView(player: player, item: item, fontFamily: font);
        break;
      case 'modal':
        content = _ModalHost(
          player: player,
          item: item,
          onComplete: widget.onComplete ?? () {},
          fontFamily: font,
        );
        break;
      case 'timer':
      case 'delay':
        content = _TimerView(
          player: player,
          item: item,
          onComplete: widget.onComplete ?? () {},
        );
        break;
      case 'audio':
      case 'video':
        // Веб-плеер v1 не играет медиа: очередь освобождаем сразу, иначе
        // цепочка раскрытия встанет на первом же звуке.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onComplete?.call();
        });
        content = _MediaPlaceholder(player: player, item: item);
        break;
      case 'plugin':
        content = const SizedBox.shrink();
        break;
      default:
        content = Text(
          'Unknown: ${item.type}',
          style: TextStyle(color: Colors.red, fontFamily: widget.fontFamily),
        );
    }

    if (widget.suppress || item.type == 'button' || item.type == 'input') {
      return content;
    }
    final takesPress =
        itemHasInteraction(item) ||
        (item.targetNodeId?.trim().isNotEmpty ?? false) ||
        (item.scriptAssetId?.trim().isNotEmpty ?? false);
    if (!takesPress) return content;
    return InkWell(
      onTap: () => player.tapItem(item),
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }

  /// Контейнер с собственным onPress перехватывает тап: дети не кликабельны
  /// (нативный `suppressChildrenInteraction`).
  static bool _containerSuppresses(ContentItem item) =>
      item.type == 'row' || item.type == 'column' || item.type == 'stack'
      ? itemHasInteraction(item) || (item.scriptAssetId?.isNotEmpty ?? false)
      : false;
}

/// Есть ли у айтем поведение onPress/onSubmit со скриптом.
bool itemHasInteraction(ContentItem item) => item.resolvedBehaviours.any(
  (b) =>
      (b.event == 'onPress' || b.event == 'onSubmit') &&
      b.script.trim().isNotEmpty,
);

/// Освобождает шаг очереди на следующем кадре (нативный `InstantItem`).
class _Instant extends StatefulWidget {
  const _Instant({required this.child, this.onCompleted});
  final Widget child;
  final VoidCallback? onCompleted;

  @override
  State<_Instant> createState() => _InstantState();
}

class _InstantState extends State<_Instant> {
  @override
  void initState() {
    super.initState();
    final callback = widget.onCompleted;
    if (callback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) callback();
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ---------------------------------------------------------------------------
// Текст
// ---------------------------------------------------------------------------

class _TextView extends StatefulWidget {
  const _TextView({
    required this.player,
    required this.item,
    required this.insideRow,
    required this.suppress,
    required this.textFit,
    required this.rowTextAlign,
    required this.fontFamily,
  });

  final QuestPlayer player;
  final ContentItem item;
  final bool insideRow;
  final bool suppress;
  final String textFit;
  final String rowTextAlign;
  final String? fontFamily;

  @override
  State<_TextView> createState() => _TextViewState();
}

class _TextViewState extends State<_TextView>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  double _fraction = 1.0;

  @override
  void initState() {
    super.initState();
    _maybeStart();
  }

  @override
  void didUpdateWidget(covariant _TextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.item.id != widget.item.id ||
        oldWidget.item.text != widget.item.text ||
        oldWidget.item.textReveal != widget.item.textReveal ||
        oldWidget.item.revealSpeed != widget.item.revealSpeed;
    if (!changed) return;
    _controller?.dispose();
    _controller = null;
    _fraction = 1.0;
    _maybeStart();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  bool get _isFade => widget.item.textReveal == 'fade';

  void _maybeStart() {
    final mode = widget.item.textReveal;
    if (mode == kTextRevealDefault || widget.suppress) return;
    final chars = _visibleChars(widget.item.text ?? '');
    if (chars == 0) return;
    final ms = (1000 * chars / widget.item.revealSpeed).round();
    final duration = Duration(
      milliseconds: _isFade ? ms.clamp(250, 1200) : ms.clamp(120, 60000),
    );
    final controller = AnimationController(vsync: this, duration: duration);
    controller.addListener(() => setState(() => _fraction = controller.value));
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _fraction = 1.0);
      }
    });
    _controller = controller;
    _fraction = 0;
    controller.forward();
  }

  static final RegExp _inlineTag = RegExp(
    r'\[(?:color=#[0-9A-Fa-f]{6,8}|outline=#[0-9A-Fa-f]{6,8}(?::[0-9.]+)?|font=[^\]]+|/(?:color|outline|font))\]',
  );

  static int _visibleChars(String text) =>
      text.replaceAll(_inlineTag, '').replaceAll(RegExp(r'\s'), '').length;

  /// Доля набранного текста: префикс по числу видимых символов. Теги
  /// копируются целиком, а открытые на момент обрыва закрываются, поэтому
  /// `[outline=…]` не показывается куском и не ломает разбор.
  String _prefix(String text, double fraction) {
    if (fraction >= 1) return text;
    final target = (_visibleChars(text) * fraction).round();
    final out = StringBuffer();
    final open = <String>[];
    var seen = 0;
    var i = 0;
    while (i < text.length) {
      final tag = _inlineTag.matchAsPrefix(text, i);
      if (tag != null) {
        final value = tag.group(0)!;
        out.write(value);
        if (value.startsWith('[/')) {
          final name = value.substring(2, value.length - 1);
          final index = open.lastIndexOf(name);
          if (index >= 0) open.removeAt(index);
        } else {
          final eq = value.indexOf('=');
          open.add(value.substring(1, eq < 0 ? value.length - 1 : eq));
        }
        i = tag.end;
        continue;
      }
      if (!RegExp(r'\s').hasMatch(text[i])) {
        if (seen >= target) break;
        seen++;
      }
      out.write(text[i]);
      i++;
    }
    for (final name in open.reversed) {
      out.write('[/$name]');
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.item.text ?? '';
    final parsed = widget.player.resolveText(raw);
    final shown = (_isFade || _fraction >= 1)
        ? parsed
        : _prefix(parsed, _fraction);

    Widget body = _MarkdownBlock(
      text: shown,
      player: widget.player,
      item: widget.item,
      insideRow: widget.insideRow,
      textFit: widget.textFit,
      rowTextAlign: widget.rowTextAlign,
      fontFamily: widget.fontFamily,
    );

    if (_isFade && _fraction < 1) {
      body = Opacity(opacity: Curves.easeOut.transform(_fraction), child: body);
    }
    if (_fraction < 1) {
      // Тап по набираемому тексту = «показать сразу».
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final controller = _controller;
          if (controller != null) controller.value = 1.0;
        },
        child: body,
      );
    }
    return widget.suppress ? IgnorePointer(child: body) : body;
  }
}

/// Блочный разбор: заголовки, списки, цитаты, код-блоки и абзацы.
class _MarkdownBlock extends StatelessWidget {
  const _MarkdownBlock({
    required this.text,
    required this.player,
    required this.item,
    required this.insideRow,
    required this.textFit,
    required this.rowTextAlign,
    required this.fontFamily,
  });

  final String text;
  final QuestPlayer player;
  final ContentItem item;
  final bool insideRow;
  final String textFit;
  final String rowTextAlign;
  final String? fontFamily;

  static final RegExp _heading = RegExp(r'^(#{1,3})\s+(.*)$');
  static final RegExp _bullet = RegExp(r'^\s*(?:[-*•]|\d+\.)\s+(.*)$');
  static final RegExp _quote = RegExp(r'^>\s?(.*)$');

  @override
  Widget build(BuildContext context) {
    final baseSize = item.textFit == 'scale'
        ? 16.0
        : player
              .numeric(item, 'textSize', item.textSize ?? 16.0)
              .clamp(6.0, 200.0);
    final base = TextStyle(
      color: item.backgroundColor == null ? Colors.white : null,
      fontSize: baseSize,
      height: 1.35,
      fontFamily: fontFamily,
    );

    final align = _alignment(context);
    final blocks = <Widget>[];
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    var paragraph = <String>[];
    var inFence = false;
    final fence = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(_rich(paragraph.join('\n'), base, align));
      paragraph = [];
    }

    for (final line in lines) {
      if (line.trim().startsWith('```')) {
        if (inFence) {
          blocks.add(_codeBlock(fence.join('\n'), baseSize));
          fence.clear();
          inFence = false;
        } else {
          flushParagraph();
          inFence = true;
        }
        continue;
      }
      if (inFence) {
        fence.add(line);
        continue;
      }

      final heading = _heading.firstMatch(line);
      if (heading != null) {
        flushParagraph();
        final level = heading.group(1)!.length;
        final scale = switch (level) {
          1 => 1.5,
          2 => 1.35,
          _ => 1.2,
        };
        blocks.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _rich(
              heading.group(2)!,
              base.copyWith(
                fontSize: baseSize * scale,
                fontWeight: FontWeight.bold,
              ),
              align,
            ),
          ),
        );
        continue;
      }

      final quote = _quote.firstMatch(line);
      if (quote != null) {
        flushParagraph();
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 3, color: Colors.white38),
                const SizedBox(width: 8),
                Expanded(
                  child: _rich(
                    quote.group(1)!,
                    base.copyWith(color: Colors.white70),
                    align,
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }

      final bullet = _bullet.firstMatch(line);
      if (bullet != null) {
        flushParagraph();
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: base),
                Expanded(child: _rich(bullet.group(1)!, base, TextAlign.start)),
              ],
            ),
          ),
        );
        continue;
      }

      if (line.trim().isEmpty && paragraph.isNotEmpty) {
        flushParagraph();
        blocks.add(SizedBox(height: baseSize * 0.5));
      } else if (line.trim().isNotEmpty) {
        paragraph.add(line);
      }
    }
    flushParagraph();
    if (inFence && fence.isNotEmpty) {
      blocks.add(_codeBlock(fence.join('\n'), baseSize));
    }
    if (blocks.isEmpty) return const SizedBox.shrink();

    Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: switch (align) {
        TextAlign.center => CrossAxisAlignment.center,
        TextAlign.end => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.start,
      },
      children: blocks,
    );

    if (item.textFit == 'scale') {
      body = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: body,
      );
    }

    final background = item.backgroundColor;
    if (background != null) {
      body = Container(
        width: insideRow ? null : double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: body,
      );
    }
    return DefaultTextStyle.merge(textAlign: align, style: base, child: body);
  }

  TextAlign _alignment(BuildContext context) {
    if (insideRow) {
      return switch (rowTextAlign) {
        'start' => TextAlign.start,
        'end' => TextAlign.end,
        _ => TextAlign.center,
      };
    }
    final inherited = DefaultTextStyle.of(context).textAlign;
    return inherited ?? TextAlign.start;
  }

  Widget _codeBlock(String code, double size) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          code,
          softWrap: false,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.9,
            height: 1.2,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  Widget _rich(String value, TextStyle base, TextAlign align) {
    final fill = RichText(
      text: buildInlineSpan(value, base, player: player),
      textAlign: align,
      softWrap: true,
    );
    // Кисть одна на плеер, редактор и веб — см. ContentItem.textOutlinePaint.
    final stroke = item.textOutlinePaint;
    // Фрагментная `[outline=…]` тоже штриховая: копии глифа со сдвигом давали
    // раздвоенный контур, отличный от игры.
    if (stroke == null && !hasInlineOutline(value)) return fill;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Align(
            alignment: Alignment.topLeft,
            child: RichText(
              text: buildInlineSpan(
                value,
                base,
                player: player,
                outlineLayer: stroke ?? transparentTextOutlineStroke,
              ),
              textAlign: align,
              softWrap: true,
            ),
          ),
        ),
        fill,
      ],
    );
  }
}

/// Инлайн-разбор: `[font=…]` → `[color=…]` → `**жирный**` / `*курсив*` /
/// `` `код` `` / `[текст](ссылка)`. Ссылки `node://<id>` ведут в ноду.
InlineSpan buildInlineSpan(
  String text,
  TextStyle base, {
  QuestPlayer? player,
  String? fontFamily,
  Paint? outlineLayer,
}) {
  final children = _inline(
    text,
    base,
    player: player,
    fontFamily: fontFamily,
    outlineLayer: outlineLayer,
  );
  return TextSpan(
    children: children,
    style: outlineLayer == null
        ? base
        : base.copyWith(foreground: outlineLayer),
  );
}

List<InlineSpan> _inline(
  String text,
  TextStyle base, {
  QuestPlayer? player,
  String? fontFamily,
  Paint? outlineLayer,
  Paint? fragmentStroke,
}) {
  TextStyle styled(TextStyle from) {
    final withFamily = from.copyWith(fontFamily: fontFamily ?? base.fontFamily);
    final stroke = fragmentStroke ?? outlineLayer;
    return stroke == null
        ? withFamily
        : withFamily.copyWith(foreground: stroke);
  }

  final style = styled(base);
  if (text.isEmpty) return const [];

  final font = RegExp(
    r'\[font=([^\]]+)\](.*?)\[/font\]',
    dotAll: true,
  ).firstMatch(text);
  if (font != null) {
    final family = questFontFamily(font.group(1)?.trim());
    return [
      ..._inline(
        text.substring(0, font.start),
        base,
        player: player,
        fontFamily: fontFamily,
        outlineLayer: outlineLayer,
        fragmentStroke: fragmentStroke,
      ),
      ..._inline(
        font.group(2) ?? '',
        base,
        player: player,
        fontFamily: family ?? fontFamily,
        outlineLayer: outlineLayer,
        fragmentStroke: fragmentStroke,
      ),
      ..._inline(
        text.substring(font.end),
        base,
        player: player,
        fontFamily: fontFamily,
        outlineLayer: outlineLayer,
        fragmentStroke: fragmentStroke,
      ),
    ];
  }

  final outline = RegExp(
    r'\[outline=(#[0-9A-Fa-f]{6,8})(?::([0-9]+(?:\.[0-9]+)?))?\](.*?)\[/outline\]',
    dotAll: true,
  ).firstMatch(text);
  if (outline != null) {
    final parsed = _parseHexColor(outline.group(1)!);
    if (parsed != null) {
      final fragmentPaint = textOutlineStroke(
        parsed,
        width: double.tryParse(outline.group(2) ?? ''),
      );
      return [
        ..._inline(
          text.substring(0, outline.start),
          base,
          player: player,
          fontFamily: fontFamily,
          outlineLayer: outlineLayer,
          fragmentStroke: fragmentStroke,
        ),
        ..._inline(
          outline.group(3) ?? '',
          base,
          player: player,
          fontFamily: fontFamily,
          outlineLayer: outlineLayer,
          fragmentStroke: fragmentPaint,
        ),
        ..._inline(
          text.substring(outline.end),
          base,
          player: player,
          fontFamily: fontFamily,
          outlineLayer: outlineLayer,
          fragmentStroke: fragmentStroke,
        ),
      ];
    }
  }

  final color = RegExp(
    r'\[color=(#[0-9A-Fa-f]{6,8})\](.*?)\[/color\]',
    dotAll: true,
  ).firstMatch(text);
  if (color != null) {
    final parsed = _parseHexColor(color.group(1)!);
    if (parsed != null) {
      return [
        ..._inline(
          text.substring(0, color.start),
          base,
          player: player,
          fontFamily: fontFamily,
          outlineLayer: outlineLayer,
          fragmentStroke: fragmentStroke,
        ),
        ..._inline(
          color.group(2) ?? '',
          base.copyWith(color: parsed),
          player: player,
          fontFamily: fontFamily,
          outlineLayer: outlineLayer,
          fragmentStroke: fragmentStroke,
        ),
        ..._inline(
          text.substring(color.end),
          base,
          player: player,
          fontFamily: fontFamily,
          outlineLayer: outlineLayer,
          fragmentStroke: fragmentStroke,
        ),
      ];
    }
  }

  final link = RegExp(r'\[([^\]\n]*)\]\(([^)\n]+)\)').firstMatch(text);
  final bold = RegExp(r'\*\*(.+?)\*\*', dotAll: true).firstMatch(text);
  final italic = RegExp(
    r'(?<!\*)\*([^*\n]+)\*(?!\*)',
    dotAll: true,
  ).firstMatch(text);
  final code = RegExp(r'`([^`\n]+)`').firstMatch(text);

  final candidates =
      <RegExpMatch?>[link, bold, italic, code].whereType<RegExpMatch>().toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  final first = candidates.isEmpty ? null : candidates.first;

  if (first == null) return [TextSpan(text: text, style: style)];

  final spans = <InlineSpan>[
    ..._inline(
      text.substring(0, first.start),
      base,
      player: player,
      fontFamily: fontFamily,
      outlineLayer: outlineLayer,
      fragmentStroke: fragmentStroke,
    ),
  ];
  if (first == link) {
    spans.add(
      TextSpan(
        text: first.group(1) ?? '',
        style: style.copyWith(
          color: Colors.cyanAccent,
          decoration: TextDecoration.underline,
        ),
        // В нижнем слое ссылки не ловят тап: срабатывает верхний, заливочный.
        recognizer: outlineLayer != null
            ? null
            : (TapGestureRecognizer()
                ..onTap = () {
                  final raw = first.group(2) ?? '';
                  final node = _nodeIdFromLink(raw);
                  if (node != null) {
                    player?.loadNode(node);
                  } else {
                    final uri = Uri.tryParse(raw);
                    if (uri != null &&
                        (uri.scheme == 'http' || uri.scheme == 'https')) {
                      launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  }
                }),
      ),
    );
  } else if (first == bold) {
    spans.add(
      TextSpan(
        text: first.group(1),
        style: style.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  } else if (first == italic) {
    spans.add(
      TextSpan(
        text: first.group(1),
        style: style.copyWith(fontStyle: FontStyle.italic),
      ),
    );
  } else {
    spans.add(
      TextSpan(
        text: first.group(1),
        style: style.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
  spans.addAll(
    _inline(
      text.substring(first.end),
      base,
      player: player,
      fontFamily: fontFamily,
      outlineLayer: outlineLayer,
      fragmentStroke: fragmentStroke,
    ),
  );
  return spans;
}

/// Та же схема имени, что у нативного `FontService.familyNameFor`, — квестовый
/// шрифт, загруженный из архива, находится по тому же family.
String? questFontFamily(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  if (!value.contains('/')) return value;
  final base = value.substring(value.lastIndexOf('/') + 1);
  return 'Font_${_safeId(currentQuestId)}_${_safeId(base)}';
}

String _safeId(String value) => value.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

/// Квест, чьи шрифты сейчас загружены: нужен для тех же имён family, что и у
/// нативного FontService. Ставит его `PlayScreen` при открытии бандла.
String currentQuestId = 'web';

Color? _parseHexColor(String raw) {
  var hex = raw.replaceFirst('#', '');
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final value = int.tryParse(hex, radix: 16);
  return value == null ? null : Color(value);
}

String? _nodeIdFromLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme.toLowerCase() != 'node') return null;
  final candidate = uri.host.isNotEmpty && uri.path.isNotEmpty
      ? '${uri.host}${uri.path}'
      : (uri.host.isNotEmpty ? uri.host : uri.path);
  final id = candidate.startsWith('/') ? candidate.substring(1) : candidate;
  return id.isEmpty ? null : Uri.decodeComponent(id);
}

// ---------------------------------------------------------------------------
// Кнопка
// ---------------------------------------------------------------------------

class _ButtonView extends StatelessWidget {
  const _ButtonView({
    required this.player,
    required this.item,
    required this.suppress,
    required this.fontFamily,
  });

  final QuestPlayer player;
  final ContentItem item;
  final bool suppress;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final config = item.buttonStyle;
    final label = player.resolveText(item.text ?? 'Кнопка');
    final wrap = item.wrapTextOverride ?? item.wrapText;
    final font = questFontFamily(config?.fontFamily) ?? fontFamily;
    final textSize = config?.effectiveTextSize ?? 16.0;

    final textStyle = TextStyle(
      color: config?.textColor ?? Colors.white,
      fontSize: textSize,
      fontFamily: font,
      fontWeight: config?.textWeight == null
          ? null
          : FontWeight.values[((config!.textWeight! ~/ 100) - 1).clamp(0, 8)],
      letterSpacing: config?.letterSpacing,
    );

    final Widget text = wrap
        ? RichText(
            text: buildInlineSpan(label, textStyle, player: player),
            textAlign: TextAlign.center,
          )
        : FittedBox(
            fit: BoxFit.scaleDown,
            child: RichText(
              text: buildInlineSpan(label, textStyle, player: player),
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
            ),
          );

    final radius = BorderRadius.circular(config?.borderRadius ?? 16);
    final decoration = BoxDecoration(
      gradient: config != null && config.useGradient
          ? LinearGradient(
              begin: config.gradientIsHorizontal
                  ? Alignment.centerLeft
                  : Alignment.topCenter,
              end: config.gradientIsHorizontal
                  ? Alignment.centerRight
                  : Alignment.bottomCenter,
              colors: [
                config.gradientStartColor.withValues(
                  alpha: config.effectiveFillOpacity,
                ),
                config.gradientEndColor.withValues(
                  alpha: config.effectiveFillOpacity,
                ),
              ],
            )
          : null,
      color: config == null
          ? Colors.white.withValues(alpha: 0.08)
          : (config.useGradient
                ? null
                : config.fillColor.withValues(
                    alpha: config.effectiveFillOpacity,
                  )),
      borderRadius: radius,
      border: Border.all(
        color: config?.borderColor ?? Colors.white.withValues(alpha: 0.18),
        width: config?.borderWidth ?? 1,
      ),
      boxShadow: [
        BoxShadow(
          color: (config?.shadowColor ?? Colors.black).withValues(
            alpha: config?.effectiveShadowOpacity ?? 0.2,
          ),
          blurRadius: config?.effectiveShadowBlur ?? 8,
          offset: Offset(
            config?.effectiveShadowOffsetX ?? 0,
            config?.effectiveShadowOffsetY ?? 4,
          ),
        ),
      ],
    );

    final child = Material(
      color: Colors.transparent,
      borderRadius: radius,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: suppress ? null : () => player.tapItem(item),
        borderRadius: radius,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: config?.paddingH ?? 16,
            vertical: config?.paddingV ?? 12,
          ),
          child: text,
        ),
      ),
    );

    return suppress
        ? IgnorePointer(
            child: DecoratedBox(
              decoration: decoration,
              child: SizedBox(
                width: double.infinity,
                child: Center(child: child),
              ),
            ),
          )
        : DecoratedBox(
            decoration: decoration,
            child: SizedBox(width: double.infinity, child: child),
          );
  }
}

// ---------------------------------------------------------------------------
// Картинка
// ---------------------------------------------------------------------------

class _ImageView extends StatelessWidget {
  const _ImageView({
    required this.player,
    required this.item,
    required this.suppress,
    required this.rounded,
  });

  final QuestPlayer player;
  final ContentItem item;
  final bool suppress;
  final bool rounded;

  @override
  Widget build(BuildContext context) {
    final bytes = player.imageBytesFor(item);
    if (bytes == null) return const SizedBox.shrink();

    final takesPress =
        itemHasInteraction(item) ||
        (item.targetNodeId?.trim().isNotEmpty ?? false) ||
        (item.scriptAssetId?.trim().isNotEmpty ?? false);

    Widget image = Image.memory(
      bytes,
      fit: BoxFit.cover,
      width: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    );
    if (rounded) {
      image = ClipRRect(borderRadius: BorderRadius.circular(12), child: image);
    }
    if (suppress || takesPress) return image;
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        barrierColor: Colors.black87,
        builder: (context) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: InteractiveViewer(child: Image.memory(bytes)),
          ),
        ),
      ),
      child: image,
    );
  }
}

// ---------------------------------------------------------------------------
// Ряд / колонка
// ---------------------------------------------------------------------------

class _ContainerView extends StatefulWidget {
  const _ContainerView({
    required this.player,
    required this.item,
    required this.onComplete,
    required this.suppress,
    required this.textFit,
    required this.rowTextAlign,
    required this.imageRounded,
    required this.fontFamily,
  });

  final QuestPlayer player;
  final ContentItem item;
  final VoidCallback onComplete;
  final bool suppress;
  final String textFit;
  final String rowTextAlign;
  final bool? imageRounded;
  final String? fontFamily;

  @override
  State<_ContainerView> createState() => _ContainerViewState();
}

class _ContainerViewState extends State<_ContainerView> {
  final Set<String> _startedAppear = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onComplete();
      unawaited(_runChildAppear());
    });
  }

  /// Ядро исполняет `onReveal` только для верхнего уровня ноды — детей ряда,
  /// колонки и стека прогоняем здесь.
  Future<void> _runChildAppear() async {
    var ranAny = false;
    String? transitionTo;
    for (final child in widget.item.children ?? const <ContentItem>[]) {
      if (child.isHidden || !_startedAppear.add(child.id)) continue;
      if (child.scriptForEvent('onAppear') == null) continue;
      ranAny = true;
      final next = await widget.player.childAppearResult(child);
      if (next != null && next.isNotEmpty && transitionTo == null) {
        transitionTo = next;
      }
    }
    if (!ranAny || !mounted) return;
    if (transitionTo != null) await widget.player.loadNode(transitionTo);
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.item.children;
    if (children == null || children.isEmpty) return const SizedBox.shrink();

    final align = switch (widget.item.crossAxisAlignment) {
      'start' => CrossAxisAlignment.start,
      'end' => CrossAxisAlignment.end,
      _ => CrossAxisAlignment.center,
    };

    final hasSpacing =
        widget.item.itemSpacing != null ||
        widget.item.numericExpr('itemSpacing') != null;
    final customSpacing = hasSpacing
        ? widget.player.numeric(
            widget.item,
            'itemSpacing',
            widget.item.itemSpacing ?? (widget.item.type == 'row' ? 4.0 : 8.0),
          )
        : null;

    if (widget.item.type == 'row') {
      final half = (customSpacing ?? 8.0) / 2.0;
      return Row(
        crossAxisAlignment: align,
        children: List.generate(children.length, (i) {
          final child = children[i];
          final pad = customSpacing != null
              ? EdgeInsets.only(
                  left: i == 0 ? 0 : half,
                  right: i == children.length - 1 ? 0 : half,
                )
              : const EdgeInsets.symmetric(horizontal: 4);
          final view = Padding(
            padding: pad,
            child: _child(child, insideRow: true),
          );
          return child.type == 'spacer'
              ? view
              : Expanded(
                  key: ValueKey('row_${child.id}'),
                  flex: child.flex,
                  child: view,
                );
        }),
      );
    }

    return DefaultTextStyle.merge(
      textAlign: TextAlign.center,
      style: TextStyle(fontFamily: widget.fontFamily),
      child: Column(
        crossAxisAlignment: align,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++)
            _child(
              children[i],
              insideRow: false,
              bottomPad: customSpacing != null && i == children.length - 1
                  ? 0.0
                  : (customSpacing ?? 8.0),
            ),
        ],
      ),
    );
  }

  Widget _child(
    ContentItem child, {
    required bool insideRow,
    double bottomPad = 0,
  }) {
    return ItemView(
      key: ValueKey(child.id),
      player: widget.player,
      item: child,
      insideRow: insideRow,
      suppress: widget.suppress,
      textFit: insideRow ? widget.textFit : 'wrap',
      rowTextAlign: widget.rowTextAlign,
      bottomPadding: insideRow ? 0 : bottomPad,
      imageRounded: widget.imageRounded,
      fontFamily: widget.fontFamily,
    );
  }
}

// ---------------------------------------------------------------------------
// Стек (холст в px дизайна)
// ---------------------------------------------------------------------------

/// Холст `type == 'stack'`: дети разложены по якорям в пикселях дизайна и
/// масштабируются целиком — ровно как в `GameStackWidget`.
class StackLayerView extends StatefulWidget {
  const StackLayerView({
    super.key,
    required this.player,
    required this.item,
    required this.suppress,
    required this.imageRounded,
    required this.fontFamily,
    this.stretchWidth = false,
    this.stretchHeight = false,
    this.fixedSize,
  });

  final QuestPlayer player;
  final ContentItem item;
  final bool suppress;
  final bool? imageRounded;
  final String? fontFamily;
  final bool stretchWidth;
  final bool stretchHeight;
  final Size? fixedSize;

  @override
  State<StackLayerView> createState() => _StackLayerViewState();
}

class _StackLayerViewState extends State<StackLayerView> {
  final Set<String> _startedAppear = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runChildAppear());
  }

  Future<void> _runChildAppear() async {
    var ranAny = false;
    String? transitionTo;
    for (final child in widget.item.children ?? const <ContentItem>[]) {
      if (child.isHidden || !_startedAppear.add(child.id)) continue;
      if (child.scriptForEvent('onAppear') == null) continue;
      ranAny = true;
      final next = await widget.player.childAppearResult(child);
      if (next != null && next.isNotEmpty && transitionTo == null) {
        transitionTo = next;
      }
    }
    if (!ranAny || !mounted) return;
    if (transitionTo != null) await widget.player.loadNode(transitionTo);
  }

  @override
  Widget build(BuildContext context) {
    final designWidth = widget.item.stackCanvasWidth;
    final designHeight = widget.item.stackCanvasHeight;
    final children = widget.item.children ?? const <ContentItem>[];
    final bg = widget.item.backgroundColor;
    final bgBytes = widget.item.hasStackBackgroundImage
        ? widget.player.assetBytes(widget.item.stackBackgroundPath)
        : null;

    final radius = widget.item.borderRadius == null
        ? null
        : BorderRadius.circular(
            widget.player
                .numeric(widget.item, 'borderRadius', widget.item.borderRadius!)
                .clamp(0, 999),
          );

    Widget canvas = LayoutBuilder(
      builder: (context, constraints) {
        final available =
            widget.fixedSize?.width ??
            (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : designWidth);
        final w = widget.stretchWidth
            ? available
            : (widget.fixedSize?.width ?? available).clamp(1.0, designWidth);
        final scale = w / designWidth;
        final availableHeight =
            widget.fixedSize?.height ??
            (constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : double.infinity);
        final canvasHeight = widget.stretchHeight && availableHeight.isFinite
            ? (availableHeight / scale).clamp(1.0, 20000.0)
            : designHeight;

        return Align(
          widthFactor: 1,
          heightFactor: 1,
          child: SizedBox(
            width: w,
            height: canvasHeight * scale,
            child: FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(
                width: designWidth,
                height: canvasHeight,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    if (bgBytes != null)
                      Positioned.fill(
                        child: Image.memory(
                          bgBytes,
                          fit: _stackFit(widget.item.stackBackgroundFit),
                        ),
                      ),
                    for (final child in children)
                      _child(child, designWidth, canvasHeight),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (bg != null || bgBytes != null) {
      canvas = Container(
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          clipBehavior: Clip.hardEdge,
          child: canvas,
        ),
      );
    }
    return canvas;
  }

  static BoxFit _stackFit(String fit) => switch (fit) {
    'cover' => BoxFit.cover,
    'fill' => BoxFit.fill,
    'none' => BoxFit.none,
    _ => BoxFit.contain,
  };

  Widget _child(ContentItem child, double w, double h) {
    if (child.isHidden) return const SizedBox.shrink();
    final rect = child.stackChildRect(w, h);
    if (rect.width <= 0 || rect.height <= 0) return const SizedBox.shrink();
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Opacity(
        opacity: child.opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: child.rotation * 3.1415926535 / 180,
          child: Transform.scale(
            scale: child.scale,
            child: ClipRect(
              child: ItemView(
                key: ValueKey('stack_${child.id}'),
                player: widget.player,
                item: child,
                suppress: widget.suppress,
                textFit: 'wrap',
                imageRounded: widget.imageRounded,
                fontFamily: widget.fontFamily,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Закреплённый стек поверх прокрутки
// ---------------------------------------------------------------------------

/// Слой одного стека с `stackPin`: копия нативного `PinnedStackLayer`.
///
/// Рамку считает [ContentItem.stackPinRect] по якорям закрепления, поэтому
/// панель стоит там, где её нарисовал автор. Модальное окно (`stackModal`)
/// кладёт под себя стекло на весь вьюпорт: без него «модалка» была бы
/// картинкой поверх играбельной сцены.
///
/// [onComplete] обязан сработать и для закреплённого слоя: движок отдаёт их в
/// общей очереди раскрытия, иначе цепочка встанет на слое, а остальной контент
/// ноды не появится.
class PinnedStackLayer extends StatelessWidget {
  const PinnedStackLayer({
    super.key,
    required this.player,
    required this.item,
    required this.viewport,
    required this.onDismiss,
    this.offset = Offset.zero,
    this.imageRounded,
    this.fontFamily,
  });

  final QuestPlayer player;
  final ContentItem item;

  /// Вьюпорт ноды без системных вырезов: от него считаются доли якорей.
  final Size viewport;
  final VoidCallback onDismiss;

  /// Сдвиг рамки: на широком окне игра центрируется в колонку 720 px, и
  /// панель обязана стоять в этой колонке, а не у края окна.
  final Offset offset;
  final bool? imageRounded;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final rect = item.stackPinRect(viewport).shift(offset);
    final showScrim = item.isModalStack && _windowIsShown();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (showScrim)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: item.stackDismissesOnTapOutside ? onDismiss : () {},
              child: ColoredBox(
                color: Color.fromRGBO(0, 0, 0, item.stackScrimOpacity),
              ),
            ),
          ),
        Positioned.fromRect(
          rect: rect,
          child: ItemView(
            key: ValueKey('pinned_${item.id}'),
            player: player,
            item: item,
            onComplete: player.revealNext,
            imageRounded: imageRounded,
            fontFamily: fontFamily,
            stackFixedSize: rect.size,
          ),
        ),
      ],
    );
  }

  /// Стекло живёт ровно столько, сколько окно: при `hidden`/`gone` оно ни к
  /// чему — игрок остался бы на потемневшей ноде без единого объекта.
  bool _windowIsShown() {
    if (item.isHidden) return false;
    return player.visibilityOf(item) == EngineVisibility.visible;
  }
}

// ---------------------------------------------------------------------------
// Ввод
// ---------------------------------------------------------------------------

class _InputView extends StatefulWidget {
  const _InputView({
    required this.player,
    required this.item,
    required this.onComplete,
    required this.fontFamily,
  });

  final QuestPlayer player;
  final ContentItem item;
  final VoidCallback onComplete;
  final String? fontFamily;

  @override
  State<_InputView> createState() => _InputViewState();
}

class _InputViewState extends State<_InputView>
    with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  bool _showError = false;
  String? _submitted;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submitted != null) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _showError = true);
      return;
    }
    final hasAction =
        (widget.item.targetNodeId?.isNotEmpty ?? false) ||
        widget.item.scriptForEvent('onSubmit') != null;
    setState(() => _submitted = text);
    unawaited(widget.player.submitInput(widget.item, text));
    if (!hasAction) widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_submitted != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.item.text != null)
              Text(
                widget.player.resolveText(widget.item.text!),
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            const SizedBox(height: 4),
            Text(
              _submitted!,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if ((widget.item.text ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              widget.player.resolveText(widget.item.text!),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _showError ? Colors.redAccent : Colors.white24,
            ),
          ),
          child: TextField(
            controller: _controller,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontFamily: widget.fontFamily,
            ),
            decoration: InputDecoration(
              hintText: widget.item.placeholderText ?? '...',
              hintStyle: const TextStyle(color: Colors.white38),
              border: InputBorder.none,
            ),
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_showError) setState(() => _showError = false);
            },
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: _ButtonView(
            player: widget.player,
            item: widget.item.copyWith(
              type: 'button',
              text: widget.item.buttonText ?? 'OK',
            ),
            suppress: false,
            fontFamily: widget.fontFamily,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Чат
// ---------------------------------------------------------------------------

class _ChatView extends StatelessWidget {
  const _ChatView({
    required this.player,
    required this.item,
    required this.fontFamily,
  });

  final QuestPlayer player;
  final ContentItem item;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final text = player.resolveText(item.text ?? '');
    final rawSender = item.senderName?.trim();
    final sender = (rawSender == null || rawSender.isEmpty)
        ? 'Отправитель'
        : player.resolveText(rawSender);
    final avatarColor = Color(item.avatarColor ?? 0xFF26C6DA);
    final style = TextStyle(
      color: Colors.white,
      fontSize: 15,
      fontFamily: fontFamily,
    );

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: item.isIncoming
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFF00C853).withValues(alpha: 0.15),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(item.isIncoming ? 0 : 14),
          topRight: Radius.circular(item.isIncoming ? 14 : 0),
          bottomLeft: const Radius.circular(14),
          bottomRight: const Radius.circular(14),
        ),
      ),
      child: RichText(text: buildInlineSpan(text, style, player: player)),
    );

    final avatar = _avatar(avatarColor);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: item.isIncoming
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                avatar,
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sender,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFamily: fontFamily,
                        ),
                      ),
                      const SizedBox(height: 4),
                      bubble,
                    ],
                  ),
                ),
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        sender,
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontFamily: fontFamily,
                        ),
                      ),
                      const SizedBox(height: 4),
                      bubble,
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _avatar(Color color) {
    final bytes = player.assetBytes(item.avatarPath);
    if (bytes == null) {
      return CircleAvatar(
        radius: 16,
        backgroundColor: color,
        child: Text(
          (item.senderName?.isNotEmpty ?? false)
              ? player.resolveText(item.senderName!)[0].toUpperCase()
              : '?',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      );
    }
    return CircleAvatar(radius: 16, backgroundImage: MemoryImage(bytes));
  }
}

// ---------------------------------------------------------------------------
// Модалка (type == 'modal')
// ---------------------------------------------------------------------------

class _ModalHost extends StatefulWidget {
  const _ModalHost({
    required this.player,
    required this.item,
    required this.onComplete,
    required this.fontFamily,
  });

  final QuestPlayer player;
  final ContentItem item;
  final VoidCallback onComplete;
  final String? fontFamily;

  @override
  State<_ModalHost> createState() => _ModalHostState();
}

class _ModalHostState extends State<_ModalHost> {
  bool _shown = false;

  /// Маршрут открытого диалога: `showGeneralDialog` его наружу не отдаёт, а без
  /// него окно не снять. Снимаем именно свой маршрут — при смене ноды владеющий
  /// айтем умирает, и чужой `pop()` оставил бы висеть мёртвый барьер поверх
  /// новой сцены.
  Route<dynamic>? _route;
  Timer? _autoClose;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_shown) {
        _shown = true;
        unawaited(_show());
      }
    });
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    final route = _route;
    _route = null;
    if (route != null) {
      final navigator = route.navigator;
      if (navigator != null) {
        // Нода сменилась, пока окно открыто: снимаем именно свой маршрут и
        // только после кадра — в самом dispose менять дерево навигатора нельзя.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (navigator.mounted && route.isActive) navigator.removeRoute(route);
        });
      }
    }
    super.dispose();
  }

  Future<void> _show() async {
    final context = this.context;
    final isAutoClose = widget.item.targetNodeId == '_CLOSE_MODAL';
    final seconds = int.tryParse((widget.item.text ?? '').trim()) ?? 2;

    if (isAutoClose) {
      _autoClose = Timer(Duration(seconds: seconds), _closeAndDefault);
    }

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        _route ??= ModalRoute.of(dialogContext);
        final style = TextStyle(
          fontSize: 15,
          height: 1.5,
          fontFamily: widget.fontFamily,
        );
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: AlertDialog(
              backgroundColor: const Color(0xFF1C1F24),
              title: Text(
                widget.player.resolveText(
                  widget.item.buttonText ?? 'Уведомление',
                ),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontFamily: widget.fontFamily,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if ((widget.item.contentMarkdown ?? '').isNotEmpty)
                    RichText(
                      text: buildInlineSpan(
                        widget.player.resolveText(widget.item.contentMarkdown!),
                        style.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                        player: widget.player,
                      ),
                    ),
                ],
              ),
              actions: _actions(),
            ),
          ),
        );
      },
      routeSettings: RouteSettings(name: 'modal_${widget.item.id}'),
    );

    // Диалог закрыт (кнопкой, автозакрытием или снятием маршрута) — очередь
    // раскрытия идёт дальше.
    _route = null;
    if (mounted) widget.onComplete();
  }

  List<Widget> _actions() {
    final buttons = widget.item.modalButtons;
    if (buttons == null || buttons.isEmpty) {
      return [
        TextButton(
          onPressed: _closeAndDefault,
          child: Text(
            widget.player.resolveText(widget.item.placeholderText ?? 'Закрыть'),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ];
    }
    return [
      for (final button in buttons)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => unawaited(_tapButton(button)),
              style: OutlinedButton.styleFrom(
                foregroundColor: button.isPrimary
                    ? const Color(0xFF00C853)
                    : Colors.white,
                side: BorderSide(
                  color:
                      (button.isPrimary
                              ? const Color(0xFF00C853)
                              : Colors.white)
                          .withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                widget.player.resolveText(button.text),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
    ];
  }

  Future<void> _tapButton(ModalButtonConfig button) async {
    _close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final target = button.targetNodeId;
    if (target != null && target.isNotEmpty && target != '_CLOSE_MODAL') {
      await widget.player.loadNodeByTarget(target);
      return;
    }
    final script = button.scriptAssetId;
    if (script != null && script.isNotEmpty) {
      await widget.player.runScriptById(script);
    }
  }

  Future<void> _closeAndDefault() async {
    _close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final target = widget.item.targetNodeId;
    if (target != null && target.isNotEmpty && target != '_CLOSE_MODAL') {
      await widget.player.loadNodeByTarget(target);
      return;
    }
    final script = widget.item.scriptAssetId;
    if (script != null && script.isNotEmpty) {
      await widget.player.runScriptById(script);
    }
  }

  void _close() {
    _autoClose?.cancel();
    _autoClose = null;
    if (_route == null) return;
    _route = null;
    Navigator.of(context, rootNavigator: true).pop();
  }

  /// Айтем-владелец модалки ничего не рисует в списке ноды: окно живёт в
  /// маршруте диалога.
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ---------------------------------------------------------------------------
// Таймер / задержка
// ---------------------------------------------------------------------------

class _TimerView extends StatefulWidget {
  const _TimerView({
    required this.player,
    required this.item,
    required this.onComplete,
  });

  final QuestPlayer player;
  final ContentItem item;
  final VoidCallback onComplete;

  @override
  State<_TimerView> createState() => _TimerViewState();
}

class _TimerViewState extends State<_TimerView> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final staticSeconds =
        double.tryParse((widget.item.text ?? '').trim().replaceAll(',', '.')) ??
        1.0;
    final seconds = widget.player
        .numeric(
          widget.item,
          'duration',
          staticSeconds < 0.1 ? 0.1 : staticSeconds,
        )
        .clamp(0.1, 86400.0);
    _timer = Timer(Duration(milliseconds: (seconds * 1000).round()), () {
      if (mounted) widget.onComplete();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Заглушка медиа: в v1 звук и видео не играются, но айтем не должен выглядеть
/// сломанным — показываем подпись, чтобы игрок понял, чего не хватает.
class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.player, required this.item});

  final QuestPlayer player;
  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    if (item.type == 'video') {
      final poster = player.assetBytes(item.videoPosterPath);
      if (poster != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            poster,
            fit: BoxFit.cover,
            width: double.infinity,
          ),
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            item.type == 'audio' ? Icons.volume_up : Icons.movie_outlined,
            color: Colors.white38,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.type == 'audio'
                  ? 'Звук в веб-плеере ещё не играется'
                  : 'Видео в веб-плеере ещё не играется',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
