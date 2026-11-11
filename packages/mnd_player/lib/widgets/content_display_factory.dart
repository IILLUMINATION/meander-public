import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/services/font_service.dart';
import 'package:mnd_player/services/trigger_pipeline.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:mnd_player/utils/text_variable_resolver.dart';
import 'package:mnd_player/providers/audio_volume_provider.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';
import 'package:mnd_player/providers/text_reveal_preference.dart';
import 'package:mnd_player/providers/game_session_scope.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/providers/quest_provider.dart';
import 'package:mnd_player/widgets/items/game_container_widget.dart';
import 'package:mnd_player/widgets/items/game_stack_widget.dart';
import 'package:mnd_player/widgets/items/game_video_widget.dart';
import 'package:mnd_player/widgets/items/modal_item_widget.dart';
import 'package:mnd_player/widgets/plugin_slot_layer.dart';
import 'package:mnd_player/widgets/glass.dart';
import 'package:mnd_player/widgets/shared/markdown_color.dart';
import 'package:mnd_player/widgets/shared/module_asset_frame.dart';
import 'package:mnd_player/widgets/shared/text_reveal_plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher.dart';

typedef OnInputSubmitted = void Function(String variableName, String value);
typedef OnTransition = void Function(String nodeId);
typedef OnNavigateToNode = void Function(String nodeId);
typedef OnItemInteract = void Function(ContentItem item);

class ContentDisplayFactory {
  static Widget build({
    required ContentItem item,
    required String questId,
    required OnItemInteract onInteract,
    required OnInputSubmitted onInputSubmitted,
    required VoidCallback onComplete,
    required OnTransition onTransition,
    required OnNavigateToNode onNavigateToNode,
    double? audioVolume,
    bool isInsideRow = false,
    bool parentIsInteractable = false,
    String textFit = 'auto',
    String rowTextAlign = 'center',
    double bottomPadding = 0.0,
    String? fontFamily,
    String scriptEngineMode = kScriptEngineModeNew,
    bool? imageRoundedCornersOverride,
    BoxFit? imageBoxFit,
    MeanderGameEngine? engine,
  }) {
    double effectiveBottomPadding = bottomPadding;
    if (item.type == 'audio') {
      effectiveBottomPadding = 0.0;
    }

    // Молчаливые айтемы — те, что ничего не рисуют и потому отдают шаг очереди
    // раскрытия сами. Шаг обязан быть ровно один на раскрытие: список ноды
    // пересобирается при каждом новом ряде, а каждый лишний шаг прокручивает
    // очередь вперёд — настолько, что она обгоняет `wait_input` и `delay`, и
    // нода показывается целиком сразу. `InstantItem` отдаёт `onCompleted` из
    // `initState`, который на живущий элемент не повторяется.
    if (item.isHidden) {
      if (item.type == 'timer' || item.type == 'delay') {
        return _timedItem(item, questId, onComplete);
      }
      return InstantItem(
        onCompleted: onComplete,
        child: const SizedBox.shrink(),
      );
    }
    if (item.type == 'script') {
      return InstantItem(
        onCompleted: onComplete,
        child: const SizedBox.shrink(),
      );
    }
    // hud_panel — мёртвый тип: панель заменена стеком и больше нигде не
    // рендерится. Пропуск оставляем как надгробие, иначе старые квесты
    // покажут красный `Unknown: hud_panel`.
    if (item.type == 'hud_panel') {
      return InstantItem(
        onCompleted: onComplete,
        child: const SizedBox.shrink(),
      );
    }
    // Spacer: фиксированный отступ, не схлопывается. Высота/ширина в padding.
    // Внутри ряда трактуем как ширину, иначе — как высоту. Формулу размера
    // (`numericExprs['padding']`) считает движок, а состояние живёт в сессии,
    // поэтому значение получаем внутри Consumer: ref у фабрики нет.
    if (item.type == 'spacer') {
      return InstantItem(
        onCompleted: onComplete,
        child: Consumer(
          builder: (context, ref, _) {
            final size = resolveItemNumeric(
              ref,
              item,
              'padding',
              questId,
              staticValue: item.padding ?? 16.0,
            ).clamp(0.0, 999.0);
            return isInsideRow ? SizedBox(width: size) : SizedBox(height: size);
          },
        ),
      );
    }

    // Эффективный шрифт айтема: переопределение на самом айтеме (путь
    // ресурса res/fonts/...) — иначе унаследованный от квеста/родителя.
    final String? inheritedFont =
        FontService.resolveFamily(questId, item.fontFamily) ?? fontFamily;

    Widget content;

    switch (item.type) {
      case 'row':
      case 'column':
        content = GameContainerWidget(
          item: item,
          questId: questId,
          onInteract: onInteract,
          onInputSubmitted: onInputSubmitted,
          onComplete: onComplete,
          onTransition: onTransition,
          onNavigateToNode: onNavigateToNode,
          audioVolume: audioVolume,
          parentIsInteractable: parentIsInteractable,
          fontFamily: inheritedFont,
          scriptEngineMode: scriptEngineMode,
          imageRoundedCornersOverride: imageRoundedCornersOverride,
          engine: engine,
        );
        break;

      case 'stack':
        content = GameStackWidget(
          item: item,
          questId: questId,
          onInteract: onInteract,
          onInputSubmitted: onInputSubmitted,
          onComplete: onComplete,
          onTransition: onTransition,
          onNavigateToNode: onNavigateToNode,
          audioVolume: audioVolume,
          parentIsInteractable: parentIsInteractable,
          fontFamily: inheritedFont,
          scriptEngineMode: scriptEngineMode,
          imageRoundedCornersOverride: imageRoundedCornersOverride,
          engine: engine,
        );
        break;

      case 'text':
        content = TextRevealHost(
          item: item,
          questId: questId,
          onNavigateToNode: onNavigateToNode,
          isInsideRow: isInsideRow,
          suppressInteractions: parentIsInteractable,
          textFit: textFit,
          rowTextAlign: rowTextAlign,
          fontFamily: inheritedFont,
        );
        break;

      case 'button':
        content = ButtonItemWidget(
          item: item,
          questId: questId,
          onPressed: onInteract,
          fontFamily: inheritedFont,
        );
        break;

      case 'image':
        content = ImageItemWidget(
          item: item,
          questId: questId,
          onInteract: onInteract,
          // Со своим скриптом/переходом картинка отдаёт тап движку, а не
          // открывает просмотр — иначе триггер на фото недостижим.
          suppressInteractions:
              parentIsInteractable ||
              TriggerPipeline.takesPressOverOwnAction(item),
          roundedCornersOverride: imageRoundedCornersOverride,
          boxFit: imageBoxFit,
        );
        break;

      case 'audio':
        final combinedVolume = ((audioVolume ?? 1.0) * item.volume).clamp(
          0.0,
          1.0,
        );
        content = _AudioItemPlayer(
          questId: questId,
          item: item,
          onComplete: onComplete,
          initialVolume: combinedVolume,
        );
        break;

      case 'input':
        content = InputItemWidget(
          item: item,
          questId: questId,
          onSubmitted: onInputSubmitted,
          onInteract: onInteract,
          onComplete: onComplete,
          onNavigateToNode: onNavigateToNode,
          fontFamily: inheritedFont,
        );
        break;

      case 'timer':
      case 'delay':
        content = _timedItem(item, questId, onComplete);
        break;

      case 'wait_input':
        content = WaitInputItemWidget(
          item: item,
          questId: questId,
          onComplete: onComplete,
          fontFamily: inheritedFont,
        );
        break;

      case 'modal':
        content = ModalItemWidget(
          item: item,
          questId: questId,
          onNavigateToNode: onNavigateToNode,
          onTransition: onTransition,
          onComplete: onComplete,
          fontFamily: inheritedFont,
          scriptEngineMode: scriptEngineMode,
        );
        break;

      case 'chat':
        content = ChatItemWidget(
          item: item,
          questId: questId,
          fontFamily: inheritedFont,
        );
        break;

      case 'video':
        final combinedVolume = ((audioVolume ?? 1.0) * item.volume).clamp(
          0.0,
          1.0,
        );
        content = GameVideoWidget(
          item: item,
          questId: questId,
          onComplete: onComplete,
          onInteract: onInteract,
          onTransition: onTransition,
          initialVolume: combinedVolume,
          engine: engine,
        );
        break;

      case 'plugin':
        // Контент плагина: рисует то, что плагин выставил в цель `item:<id>`
        // (обычно в ответ на событие `item_reveal`).
        content = PluginContentWidget(item: item, questId: questId);
        break;

      default:
        content = Text(
          'Unknown: ${item.type}',
          style: TextStyle(color: Colors.red, fontFamily: inheritedFont),
        );
    }

    if (!parentIsInteractable) {
      if (item.type != 'button' &&
          item.type != 'input' &&
          item.type != 'wait_input' &&
          (TriggerPipeline.takesPressOverOwnAction(item) ||
              (item.scriptAssetId != null && item.scriptAssetId!.isNotEmpty))) {
        content = InkWell(
          onTap: () => onInteract(item),
          borderRadius: BorderRadius.circular(12),
          child: content,
        );
      }
    }

    bool isSelfManaging =
        item.type == 'audio' ||
        item.type == 'video' ||
        item.type == 'timer' ||
        item.type == 'delay' ||
        item.type == 'row' ||
        item.type == 'column' ||
        item.type == 'stack' ||
        item.type == 'input' ||
        item.type == 'wait_input' ||
        item.type == 'modal';

    if (isInsideRow) {
      if (engine == null) return content;
      return ConditionalContentWrapper(
        key: ValueKey(item.id),
        item: item,
        questId: questId,
        bottomPadding: effectiveBottomPadding,
        onComplete: () {},
        onTransition: onTransition,
        onNavigateToNode: onNavigateToNode,
        allowTargetMismatchFallback: scriptEngineMode == kScriptEngineModeNew,
        engine: engine,
        child: content,
      );
    }

    if (engine == null) {
      return isSelfManaging
          ? content
          : InstantItem(onCompleted: onComplete, child: content);
    }
    return ConditionalContentWrapper(
      key: ValueKey(item.id),
      item: item,
      questId: questId,
      bottomPadding: effectiveBottomPadding,
      onComplete: onComplete,
      onTransition: onTransition,
      onNavigateToNode: onNavigateToNode,
      allowTargetMismatchFallback: scriptEngineMode == kScriptEngineModeNew,
      engine: engine,
      child: isSelfManaging
          ? content
          : InstantItem(onCompleted: onComplete, child: content),
    );
  }

  /// Задержка/таймер: длительность может считать движок
  /// (`numericExprs['duration']`). Значение берётся один раз, когда отсчёт
  /// появляется, — пересчёт на середине перезапустил бы таймер с нуля, а этого
  /// автор не просил.
  static Widget _timedItem(
    ContentItem item,
    String questId,
    VoidCallback onComplete,
  ) {
    final staticSeconds = _staticDelaySeconds(item);
    return Consumer(
      builder: (context, ref, _) => TimerItemWidget(
        item: item,
        seconds: resolveItemNumeric(
          ref,
          item,
          'duration',
          questId,
          staticValue: staticSeconds,
        ).clamp(0.1, 86400.0),
        onComplete: onComplete,
      ),
    );
  }

  /// Секунды из `text` — как было до формул: `1,5` и `1.5`; меньше 0,1 или
  /// нерабочее значение → 0,1, «не задано» → 1.
  static double _staticDelaySeconds(ContentItem item) {
    final seconds =
        double.tryParse((item.text ?? '').trim().replaceAll(',', '.')) ?? 1.0;
    return seconds < 0.1 ? 0.1 : seconds;
  }
}

class InstantItem extends StatefulWidget {
  final Widget child;
  final VoidCallback? onCompleted;
  const InstantItem({super.key, required this.child, this.onCompleted});
  @override
  State<InstantItem> createState() => _InstantItemState();
}

class _InstantItemState extends State<InstantItem> {
  @override
  void initState() {
    super.initState();
    if (widget.onCompleted != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onCompleted!();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class ConditionalContentWrapper extends ConsumerStatefulWidget {
  final ContentItem item;
  final String questId;
  final Widget child;
  final VoidCallback onComplete;
  final Function(String) onTransition;
  final Function(String) onNavigateToNode;
  final double bottomPadding;
  final bool allowTargetMismatchFallback;
  final MeanderGameEngine engine;

  const ConditionalContentWrapper({
    super.key,
    required this.item,
    required this.questId,
    required this.child,
    required this.onComplete,
    required this.onTransition,
    required this.onNavigateToNode,
    required this.allowTargetMismatchFallback,
    required this.engine,
    this.bottomPadding = 0.0,
  });

  @override
  ConsumerState<ConditionalContentWrapper> createState() =>
      _ConditionalContentWrapperState();
}

class _ConditionalContentWrapperState
    extends ConsumerState<ConditionalContentWrapper>
    with AutomaticKeepAliveClientMixin {
  Future<(bool, String?)>? _processingFuture;
  bool _isTransitionScheduled = false;

  /// Ребёнок собирался хоть раз — значит свой onComplete он уже отдал (или
  /// отдаст сам), и пропускающим шагом очереди его не надо трогать.
  bool _childBuilt = false;
  bool _revealStepSkipped = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (_onAppearScript(widget.item) != null) {
      _processingFuture = _processOnAppearScript();
    }
  }

  /// Скрипт onAppear в обоих форматах: legacy `scriptTriggers` и новый
  /// `behaviours`. Чтение только legacy молча лишало реактивной видимости
  /// все айтемы, подключённые новым форматом.
  static String? _onAppearScript(ContentItem item) =>
      item.scriptForEvent('onAppear');

  @override
  void didUpdateWidget(covariant ConditionalContentWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPath = _onAppearScript(oldWidget.item);
    final newPath = _onAppearScript(widget.item);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.questId != widget.questId ||
        oldPath != newPath) {
      _isTransitionScheduled = false;
      if (newPath != null) {
        _processingFuture = _processOnAppearScript();
      } else {
        _processingFuture = null;
      }
    }
  }

  Future<(bool, String?)> _processOnAppearScript() async {
    final engine = widget.engine;

    try {
      final visible = engine.evaluateVisibility(
        widget.item.toJson(),
        allowMutation: true,
      );
      if (!visible && !_goneByEngine()) {
        _skipRevealStep();
      }
      return (visible, null);
    } catch (_) {
      return (true, null);
    }
  }

  /// Убран ли айтем блоком `set_visible` — то, что пишет в состояние сама
  /// модель квеста, здесь ни при чём.
  bool _goneByEngine() =>
      engineVisibilityOf(
        ref.read(gameStateProvider).variables,
        widget.item.id,
      ) ==
      EngineVisibility.gone;

  /// Очередь раскрытия ждёт onComplete от каждого айтема. Если движок спрятал
  /// айтем раньше, чем тот успел собраться, ребёнок не отработает никогда —
  /// шагаем сами, как фабрика делает для статически скрытых. Если айтем уже
  /// показывался, onComplete от него уже был, и второй раз шагать нельзя.
  void _skipRevealStep() {
    if (_childBuilt || _revealStepSkipped) return;
    _revealStepSkipped = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onComplete();
    });
  }

  /// Содержимое айтема. [keepPlace] — «скрыть» из `set_visible`: не видно и
  /// нажать нельзя, но место в раскладке остаётся, и соседи не уезжают.
  ///
  /// Обёртка стоит на месте в обоих случаях: если добавлять её только когда
  /// айтем скрыт, поддерево при переходе пересоздастся, и ребёнок отдаст шаг
  /// очереди раскрытия ещё раз.
  Widget _showChild({bool keepPlace = false}) {
    _childBuilt = true;
    final content = _wrapWithBottomPadding(widget.child);
    return IgnorePointer(
      ignoring: keepPlace,
      child: Opacity(opacity: keepPlace ? 0 : 1, child: content),
    );
  }

  void _scheduleImmediateTransition(String nodeId) {
    if (_isTransitionScheduled) return;
    _isTransitionScheduled = true;
    Future.microtask(() {
      if (mounted) {
        widget.onTransition(nodeId);
      }
    });
  }

  Widget _wrapWithBottomPadding(Widget child) {
    if (widget.bottomPadding <= 0) return child;
    return Padding(
      padding: EdgeInsets.only(bottom: widget.bottomPadding),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // Проверка до всего остального: у айтема без onAppear-скрипта другой точки,
    // где посмотреть в состояние движка, просто нет. Select-подписка — чтобы
    // перерисовываться только когда изменилась именно эта картинка/кнопка, а
    // не любое значение переменной в квесте.
    final visibility = ref.watch(
      gameStateProvider.select(
        (state) => engineVisibilityOf(state.variables, widget.item.id),
      ),
    );
    // «Убрать»: айтема нет ни на экране, ни в раскладке — ряд схлопывается.
    if (visibility == EngineVisibility.gone) {
      _skipRevealStep();
      return const SizedBox.shrink();
    }
    // «Скрыть»: не видно, но место занято, и ребёнок собирается как обычно —
    // иначе он не отдал бы шаг очереди раскрытия.
    final keepPlace = visibility == EngineVisibility.hidden;

    if (_onAppearScript(widget.item) == null) {
      return _showChild(keepPlace: keepPlace);
    }

    return FutureBuilder<(bool, String?)>(
      future: _processingFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        final transitionNodeId = (snapshot.data ?? (true, null)).$2;
        if (transitionNodeId != null) {
          _scheduleImmediateTransition(transitionNodeId);
          return const SizedBox.shrink();
        }

        // Реактивная переоценка при изменении переменных в движке.
        ref.watch(gameStateProvider);
        final currentShouldShow = widget.engine.evaluateVisibility(
          widget.item.toJson(),
          allowMutation: false,
        );

        return currentShouldShow
            ? _showChild(keepPlace: keepPlace)
            : const SizedBox.shrink();
      },
    );
  }
}

class TextItemWidget extends ConsumerWidget {
  final ContentItem item;
  final String questId;
  final OnNavigateToNode onNavigateToNode;
  final bool isInsideRow;
  final bool suppressInteractions;
  final String textFit;
  final String rowTextAlign;
  final String? fontFamily;

  /// Доля набранного текста для анимации появления: 0 — пусто, 1 — всё.
  /// `null` (обычный случай) — анимации нет, рендер ровно как раньше.
  /// Все решения о вёрстке (fit, выравнивание, списки, ASCII-арт) принимаются
  /// по ПОЛНОМУ тексту, по префиксу рисуется только содержимое — иначе блок
  /// прыгал бы по мере набора.
  final double? revealFraction;

  const TextItemWidget({
    super.key,
    required this.item,
    required this.questId,
    required this.onNavigateToNode,
    this.isInsideRow = false,
    this.suppressInteractions = false,
    this.textFit = 'auto',
    this.rowTextAlign = 'center',
    this.fontFamily,
    this.revealFraction,
  });

  String _extractNodeId(Uri uri) {
    String candidate = '';
    if (uri.host.isNotEmpty && uri.path.isNotEmpty) {
      candidate = '${uri.host}${uri.path}';
    } else if (uri.host.isNotEmpty) {
      candidate = uri.host;
    } else {
      candidate = uri.path;
    }
    if (candidate.startsWith('/')) {
      candidate = candidate.substring(1);
    }
    return Uri.decodeComponent(candidate);
  }

  Future<void> _handleLinkTap(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (uri.scheme.toLowerCase() == 'node') {
      final nodeId = _extractNodeId(uri);
      if (nodeId.isNotEmpty) {
        onNavigateToNode(nodeId);
      }
      return;
    }

    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _parseTextWithVariables(
    WidgetRef ref,
    String text,
    String questId,
    GameStateNotifier notifier,
  ) {
    final key = GameSessionScope.maybeOf(ref.context);
    return resolveTextVariables(ref, text, questId, notifier, sessionKey: key);
  }

  String _normalizeMarkdownListLayout(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final out = <String>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final bulletOnly = RegExp(r'^\s*[•\-*+]\s*$').hasMatch(line);
      if (bulletOnly) {
        int next = i + 1;
        while (next < lines.length && lines[next].trim().isEmpty) {
          next++;
        }
        if (next < lines.length) {
          final nextLine = lines[next].trim();
          final nextIsList = RegExp(
            r'^\s*(?:[•\-*+]|\d+\.)\s+',
          ).hasMatch(lines[next]);
          if (!nextIsList && nextLine.isNotEmpty) {
            out.add('- $nextLine');
            i = next;
          }
        }
        continue;
      }

      final bulletText = RegExp(r'^\s*•\s+(.+)$').firstMatch(line);
      if (bulletText != null) {
        out.add('- ${bulletText.group(1)!.trimRight()}');
      } else {
        out.add(line);
      }
    }

    return out.join('\n');
  }

  bool _looksLikeAsciiArt(String sourceTemplate, String renderedText) {
    final normalized = renderedText
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final lines = normalized
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 3) return false;

    final hasTemplateVariables = RegExp(r'\{[^}]+\}').hasMatch(sourceTemplate);
    final hasBacktickFence = renderedText.contains('```');
    int asciiLikeLines = 0;

    for (final line in lines) {
      final symbolCount = RegExp(
        r'''[\\/\[\]()<>{}|`~_=.\-'"^:;,]''',
      ).allMatches(line).length;
      final letterCount = RegExp(r'[A-Za-zА-Яа-яЁё]').allMatches(line).length;
      if (symbolCount >= 4 && symbolCount > letterCount) {
        asciiLikeLines++;
      }
    }

    final mostlyAscii = asciiLikeLines >= (lines.length * 0.6).ceil();
    return hasBacktickFence || (hasTemplateVariables && mostlyAscii);
  }

  static final RegExp _textColorExp = RegExp(
    r'\[color=(#[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{8})\](.*?)\[\/color\]',
    dotAll: true,
  );

  /// Фрагментная обводка: `[outline=#RRGGBB]…[/outline]` или
  /// `[outline=#RRGGBB:4]…[/outline]`. Шаблон общий с markdown-генератором
  /// (`inlineOutlineTag`), толщина необязательна — без неё берётся дефолт.
  static final RegExp _textOutlineExp = inlineOutlineTag;

  TextSpan _parseSimpleMarkdown(
    String text,
    String? fontFamily, {
    Paint? outlineLayer,
  }) {
    return TextSpan(
      children: _parseRichSpans(text, fontFamily, outlineLayer: outlineLayer),
    );
  }

  Paint _spanStroke(Paint? outlineLayer, Paint? fragmentStroke) =>
      fragmentStroke ?? outlineLayer!;

  /// Рекурсивный разбор инлайн-разметки: `[font=...]` → `[color=...]` →
  /// **жирный**/*курсив*. Вложенность тегов работает в любом порядке:
  /// и `[font=X][color=red]…[/color][/font]`, и `[color=red][font=X]…[/font][/color]`.
  List<TextSpan> _parseRichSpans(
    String text,
    String? fontFamily, {
    Color? color,
    Paint? outlineLayer,
    Paint? fragmentStroke,
  }) {
    final outlineMatches = _textOutlineExp.allMatches(text).toList();
    if (outlineMatches.isNotEmpty) {
      final out = <TextSpan>[];
      int start = 0;
      for (final m in outlineMatches) {
        if (m.start > start) {
          out.addAll(
            _parseRichSpans(
              text.substring(start, m.start),
              fontFamily,
              color: color,
              outlineLayer: outlineLayer,
              fragmentStroke: fragmentStroke,
            ),
          );
        }
        final outlineColor = _parseColor(m.group(1)!);
        out.addAll(
          _parseRichSpans(
            m.group(3)!,
            fontFamily,
            color: color,
            outlineLayer: outlineLayer,
            fragmentStroke: textOutlineStroke(
              outlineColor,
              width: double.tryParse(m.group(2) ?? ''),
            ),
          ),
        );
        start = m.end;
      }
      if (start < text.length) {
        out.addAll(
          _parseRichSpans(
            text.substring(start),
            fontFamily,
            color: color,
            outlineLayer: outlineLayer,
            fragmentStroke: fragmentStroke,
          ),
        );
      }
      return out;
    }

    final fontMatches = FontService.inlineFontTag.allMatches(text).toList();
    if (fontMatches.isNotEmpty) {
      final out = <TextSpan>[];
      int start = 0;
      for (final m in fontMatches) {
        if (m.start > start) {
          out.addAll(
            _parseRichSpans(
              text.substring(start, m.start),
              fontFamily,
              color: color,
              outlineLayer: outlineLayer,
              fragmentStroke: fragmentStroke,
            ),
          );
        }
        final family = FontService.resolveFamily(questId, m.group(1)?.trim());
        out.addAll(
          _parseRichSpans(
            m.group(2)!,
            family,
            color: color,
            outlineLayer: outlineLayer,
            fragmentStroke: fragmentStroke,
          ),
        );
        start = m.end;
      }
      if (start < text.length) {
        out.addAll(
          _parseRichSpans(
            text.substring(start),
            fontFamily,
            color: color,
            outlineLayer: outlineLayer,
            fragmentStroke: fragmentStroke,
          ),
        );
      }
      return out;
    }

    final colorMatches = _textColorExp.allMatches(text).toList();
    if (colorMatches.isNotEmpty) {
      final out = <TextSpan>[];
      int start = 0;
      for (final m in colorMatches) {
        if (m.start > start) {
          out.addAll(
            _parseRichSpans(
              text.substring(start, m.start),
              fontFamily,
              color: color,
              outlineLayer: outlineLayer,
              fragmentStroke: fragmentStroke,
            ),
          );
        }
        final c = _parseColor(m.group(1)!);
        out.addAll(
          _parseRichSpans(
            m.group(2)!,
            fontFamily,
            color: c,
            outlineLayer: outlineLayer,
            fragmentStroke: fragmentStroke,
          ),
        );
        start = m.end;
      }
      if (start < text.length) {
        out.addAll(
          _parseRichSpans(
            text.substring(start),
            fontFamily,
            color: color,
            outlineLayer: outlineLayer,
            fragmentStroke: fragmentStroke,
          ),
        );
      }
      return out;
    }

    return _parseMarkdownSegment(
      text,
      fontFamily,
      color: color,
      outlineLayer: outlineLayer,
      fragmentStroke: fragmentStroke,
    );
  }

  List<TextSpan> _parseMarkdownSegment(
    String segment,
    String? fontFamily, {
    Color? color,
    Paint? outlineLayer,
    Paint? fragmentStroke,
  }) {
    // Стиль одного куска: в слое заливки — цвет, в штриховом слое — кисть.
    // Собственная обводка фрагмента (`[outline=…]`) важнее обводки айтема.
    final Paint? spanStroke = outlineLayer == null
        ? null
        : _spanStroke(outlineLayer, fragmentStroke);
    TextStyle spanStyle({FontWeight? fontWeight, FontStyle? fontStyle}) =>
        TextStyle(
          color: spanStroke == null ? (color ?? Colors.white) : null,
          foreground: spanStroke,
          fontSize: 16,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontFamily: fontFamily,
        );

    // Инлайн-теги шрифта: [font=res/fonts/x.ttf]текст[/font]. Разворачиваем
    // рекурсивно — работают и внутри [color=...], и с **жирным**/*курсивом*.
    final fontMatches = FontService.inlineFontTag.allMatches(segment).toList();
    if (fontMatches.isNotEmpty) {
      final out = <TextSpan>[];
      int fontStart = 0;
      for (final m in fontMatches) {
        if (m.start > fontStart) {
          out.addAll(
            _parseMarkdownSegment(
              segment.substring(fontStart, m.start),
              fontFamily,
              color: color,
              outlineLayer: outlineLayer,
              fragmentStroke: fragmentStroke,
            ),
          );
        }
        final family = FontService.resolveFamily(questId, m.group(1)?.trim());
        out.addAll(
          _parseMarkdownSegment(
            m.group(2)!,
            family,
            color: color,
            outlineLayer: outlineLayer,
            fragmentStroke: fragmentStroke,
          ),
        );
        fontStart = m.end;
      }
      if (fontStart < segment.length) {
        out.addAll(
          _parseMarkdownSegment(
            segment.substring(fontStart),
            fontFamily,
            color: color,
            outlineLayer: outlineLayer,
            fragmentStroke: fragmentStroke,
          ),
        );
      }
      return out;
    }

    List<TextSpan> spans = [];
    final RegExp exp = RegExp(r'(\*\*(.*?)\*\*)|(\*(.*?)\*)');
    int start = 0;

    for (final match in exp.allMatches(segment)) {
      if (match.start > start) {
        spans.add(
          TextSpan(
            text: segment.substring(start, match.start),
            style: spanStyle(),
          ),
        );
      }
      if (match.group(1) != null) {
        spans.add(
          TextSpan(
            text: match.group(2),
            style: spanStyle(fontWeight: FontWeight.w900),
          ),
        );
      } else if (match.group(3) != null) {
        spans.add(
          TextSpan(
            text: match.group(4),
            style: spanStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      start = match.end;
    }
    if (start < segment.length) {
      spans.add(TextSpan(text: segment.substring(start), style: spanStyle()));
    }
    if (spans.isEmpty && segment.isNotEmpty) {
      return [TextSpan(text: segment, style: spanStyle())];
    }
    return spans;
  }

  Color _parseColor(String colorStr) {
    if (colorStr.startsWith('#')) {
      String hex = colorStr.substring(1);
      if (hex.length == 6) {
        hex = 'FF$hex';
      }
      return Color(int.parse(hex, radix: 16));
    }
    return Colors.white;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourceTemplate = item.text ?? '';
    final _ = ref.watch(gameStateProvider);
    final gameStateNotifier = ref.read(gameStateProvider.notifier);
    final parsedText = _normalizeMarkdownListLayout(
      _parseTextWithVariables(ref, sourceTemplate, questId, gameStateNotifier),
    );
    // Что реально рисуется при анимации появления. План построения префикса
    // кешируется по тексту, поэтому на кадр приходится только поиск по
    // границам, а не разбор markdown.
    final revealed = revealFraction;
    final bool isRevealing = revealed != null && revealed < 1.0;
    final String shownText;
    if (revealed == null) {
      shownText = parsedText;
    } else {
      final plan = TextRevealPlan.of(parsedText);
      shownText = plan.prefixFor(plan.visibleAt(revealed));
    }
    final backgroundColor = item.backgroundColor;
    // Кисть одна на плеер и редактор — см. ContentItem.textOutlinePaint.
    final outlineStroke = item.textOutlinePaint;
    String effectiveFit = textFit;

    if (effectiveFit == 'auto') {
      if (isInsideRow) {
        final questAsync = ref.watch(questProvider(questId));
        effectiveFit = questAsync.value?.defaultTextFit ?? 'scale';
      } else {
        effectiveFit = 'wrap';
      }
    }

    final bool hasForcedMultiline =
        parsedText.contains('\n') ||
        RegExp(r'^\s*[-*+]\s+', multiLine: true).hasMatch(parsedText);
    if (effectiveFit == 'scale' && hasForcedMultiline) {
      effectiveFit = 'wrap';
    }

    final bool hasMarkdownList = RegExp(
      r'^\s*(?:[-*+]|•|\d+\.)\s+',
      multiLine: true,
    ).hasMatch(parsedText);

    TextAlign textAlign;
    if (isInsideRow) {
      if (hasMarkdownList) {
        textAlign = TextAlign.start;
      } else {
        switch (rowTextAlign) {
          case 'start':
            textAlign = TextAlign.start;
            break;
          case 'end':
            textAlign = TextAlign.end;
            break;
          default:
            textAlign = TextAlign.center;
        }
      }
    } else {
      textAlign = DefaultTextStyle.of(context).textAlign ?? TextAlign.start;
    }

    if (_looksLikeAsciiArt(sourceTemplate, parsedText)) {
      final resolvedBackground = backgroundColor ?? Colors.black;
      Widget textContent = Container(
        width: isInsideRow ? null : double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: resolvedBackground,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Align(
          alignment: textAlign == TextAlign.start
              ? Alignment.centerLeft
              : (textAlign == TextAlign.end
                    ? Alignment.centerRight
                    : Alignment.center),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              shownText,
              textAlign: textAlign,
              softWrap: false,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                height: 1.2,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      );

      if (suppressInteractions) {
        return IgnorePointer(child: textContent);
      }
      return textContent;
    }

    if (effectiveFit == 'scale') {
      final scaleAlign = textAlign == TextAlign.start
          ? Alignment.centerLeft
          : (textAlign == TextAlign.end
                ? Alignment.centerRight
                : Alignment.center);
      final span = _parseSimpleMarkdown(shownText, fontFamily);
      // RichText не лезет в DefaultTextStyle, поэтому слой обводки — это то же
      // самое дерево span'ов, у которого цвет заменён штриховой кистью.
      Widget scaleLayer(TextSpan text) => RichText(
        text: text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        textAlign: textAlign,
      );
      final fillLayer = scaleLayer(span);
      // Фрагментная `[outline=…]` тоже рисуется штрихом: копии глифа со
      // сдвигом давали раздвоенный контур, отличный от игры и редактора.
      final needsOutlineLayer =
          outlineStroke != null || hasInlineOutline(shownText);
      final strokeLayer = !needsOutlineLayer
          ? null
          : scaleLayer(
              _parseSimpleMarkdown(
                shownText,
                fontFamily,
                outlineLayer: outlineStroke ?? transparentTextOutlineStroke,
              ),
            );
      return Container(
        width: double.infinity,
        padding: backgroundColor != null
            ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2)
            : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: scaleAlign,
          // Clip.none: контур на полтолщины торчит за метрики глифов, и рамка
          // Stack'а срезала бы его по краю текста.
          child: strokeLayer == null
              ? fillLayer
              : Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: strokeLayer,
                      ),
                    ),
                    fillLayer,
                  ],
                ),
        ),
      );
    }

    // Базовый размер текста. 16 — то, что было вечно зашитым; `item.textSize`
    // задаётся в редакторе, `numericExprs['textSize']` считает движок.
    // Заголовки markdown множатся на тот же коэффициент, чтобы иерархия не
    // съеживалась вместе с базой. В 'scale' режиме размер считает FittedBox,
    // поэтому там поле не применяется.
    final baseFontSize = resolveItemNumeric(
      ref,
      item,
      'textSize',
      questId,
      staticValue: item.textSize ?? 16.0,
    ).clamp(6.0, 200.0);
    final headingScale = baseFontSize / 16.0;

    final baseMarkdownTextStyle = TextStyle(
      color: Colors.white,
      fontSize: baseFontSize,
      height: 1.35,
      fontFamily: fontFamily,
    );

    // Стили markdown-слоя. При `stroke == null` и `outlineOnly: false` это
    // обычный слой с заливкой; с кистью каждый цвет заменяется штрихом —
    // `copyWith(foreground:)` гасит `color`, а раз `ColorNode`/`EmphasisNode`
    // мёржатся поверх этих стилей, то и `[color=#…]`, и жирный, и ссылки уходят
    // в контур, не меняя вёрстку. `outlineOnly` — слой, где у айтема обводки
    // нет: базовый текст прозрачен, рисуются только `[outline=…]`-фрагменты.
    MarkdownConfig markdownConfigFor(
      Paint? stroke, {
      bool outlineOnly = false,
    }) {
      TextStyle layerStyle(TextStyle style) {
        if (stroke != null) return style.copyWith(foreground: stroke);
        if (outlineOnly)
          return style.copyWith(foreground: transparentTextOutlineStroke);
        return style;
      }

      return MarkdownConfig(
        configs: [
          PConfig(textStyle: layerStyle(baseMarkdownTextStyle)),
          ListConfig(
            marginLeft: 20.0,
            marginBottom: 0.0,
            marker: safeListMarker(Colors.white),
          ),
          CheckBoxConfig(builder: safeCheckboxBuilder(Colors.white)),
          H1Config(
            style: layerStyle(
              TextStyle(
                color: Colors.white,
                fontSize: 24 * headingScale,
                fontWeight: FontWeight.bold,
                fontFamily: fontFamily,
              ),
            ),
          ),
          H2Config(
            style: layerStyle(
              TextStyle(
                color: Colors.white,
                fontSize: 22 * headingScale,
                fontWeight: FontWeight.bold,
                fontFamily: fontFamily,
              ),
            ),
          ),
          H3Config(
            style: layerStyle(
              TextStyle(
                color: Colors.white,
                fontSize: 20 * headingScale,
                fontWeight: FontWeight.bold,
                fontFamily: fontFamily,
              ),
            ),
          ),
          LinkConfig(
            style: layerStyle(
              TextStyle(
                color: Colors.cyanAccent,
                decoration: TextDecoration.underline,
                fontFamily: fontFamily,
              ),
            ),
            onTap: (url) => _handleLinkTap(url),
          ),
          const BlockquoteConfig(
            textColor: Colors.white70,
            sideColor: Colors.white70,
          ),
          CodeConfig(
            style: layerStyle(
              TextStyle(
                fontFamily: 'monospace',
                color: Colors.white,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
        ],
      );
    }

    CrossAxisAlignment crossAlign = CrossAxisAlignment.start;
    if (textAlign == TextAlign.center) {
      crossAlign = CrossAxisAlignment.center;
    } else if (textAlign == TextAlign.end) {
      crossAlign = CrossAxisAlignment.end;
    }

    Widget renderMarkdown(
      String shown, {
      Paint? stroke,
      bool outlineOnly = false,
    }) {
      final isStrokeLayer = stroke != null || outlineOnly;
      return Container(
        width: isInsideRow ? null : double.infinity,
        padding: backgroundColor != null
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
            : EdgeInsets.zero,
        decoration: BoxDecoration(
          // Подложку рисует только верхний слой, иначе полупрозрачный фон
          // складывался бы дважды.
          color: isStrokeLayer ? null : backgroundColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: DefaultTextStyle.merge(
          textAlign: textAlign,
          style: switch ((stroke, outlineOnly)) {
            (final Paint paint, _) => baseMarkdownTextStyle.copyWith(
              foreground: paint,
            ),
            (_, true) => baseMarkdownTextStyle.copyWith(
              foreground: transparentTextOutlineStroke,
            ),
            _ => baseMarkdownTextStyle,
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: crossAlign,
            children:
                createColorMarkdownGenerator(
                  linesMargin: const EdgeInsets.symmetric(vertical: 2),
                  questId: questId,
                  // Обводку рисует только штриховой слой: у заливки её нет, иначе
                  // контур задвоился бы. Цвет/толщина тега важнее обводки айтема.
                  outlineMode: isStrokeLayer
                      ? TextOutlineMode.stroke
                      : TextOutlineMode.none,
                ).buildWidgets(
                  preserveMarkdownHardLineBreaks(shown),
                  config: markdownConfigFor(stroke, outlineOnly: outlineOnly),
                ),
          ),
        ),
      );
    }

    final fillLayer = renderMarkdown(shownText);
    final needsOutlineLayer =
        outlineStroke != null || hasInlineOutline(shownText);
    Widget textContent = !needsOutlineLayer
        ? fillLayer
        : Stack(
            // Clip.none — см. комментарий в 'scale'-ветке: контур выступает за
            // метрики глифов ровно на полтолщины.
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: outlineStroke != null
                      ? renderMarkdown(shownText, stroke: outlineStroke)
                      : renderMarkdown(shownText, outlineOnly: true),
                ),
              ),
              fillLayer,
            ],
          );
    if (isRevealing) {
      // Под набираемым текстом лежит целый блок, невидимый: он держит габарит,
      // поэтому всё, что ниже по колонке, не скачет на каждый символ.
      final reserved = renderMarkdown(parsedText);
      textContent = Stack(
        children: [
          IgnorePointer(
            ignoring: true,
            child: Opacity(opacity: 0, child: reserved),
          ),
          Positioned.fill(
            child: Align(alignment: Alignment.topLeft, child: textContent),
          ),
        ],
      );
    }

    if (suppressInteractions) {
      return IgnorePointer(child: textContent);
    }
    return textContent;
  }
}

/// Обёртка над текстовым элементом, которая крутит анимацию появления.
///
/// Отделена от [TextItemWidget] намеренно: тот остаётся stateless и при
/// `textReveal == 'none'` рисует ровно то же дерево, что и до анимации. Хост
/// решает только «сколько уже видно» и с какой скоростью, а ребёнок по этой
/// доле строит префикс.
class TextRevealHost extends ConsumerStatefulWidget {
  final ContentItem item;
  final String questId;
  final OnNavigateToNode onNavigateToNode;
  final bool isInsideRow;
  final bool suppressInteractions;
  final String textFit;
  final String rowTextAlign;
  final String? fontFamily;

  const TextRevealHost({
    super.key,
    required this.item,
    required this.questId,
    required this.onNavigateToNode,
    this.isInsideRow = false,
    this.suppressInteractions = false,
    this.textFit = 'auto',
    this.rowTextAlign = 'center',
    this.fontFamily,
  });

  @override
  ConsumerState<TextRevealHost> createState() => _TextRevealHostState();
}

class _TextRevealHostState extends ConsumerState<TextRevealHost>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  /// Доля набранного текста. 1.0 — анимации нет или она завершилась.
  double _fraction = 1.0;

  /// Сколько видимых символов было на последнем перерисованном кадре. Набор
  /// перерисовывается только когда это число меняется, а не на каждый тик.
  int _lastVisibleChars = -1;

  @override
  void initState() {
    super.initState();
    _maybeStart();
  }

  @override
  void didUpdateWidget(TextRevealHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.item.id != widget.item.id ||
        oldWidget.item.text != widget.item.text ||
        oldWidget.item.textReveal != widget.item.textReveal ||
        oldWidget.item.revealSpeed != widget.item.revealSpeed;
    if (!changed) return;
    _disposeController();
    _fraction = 1.0;
    _lastVisibleChars = -1;
    _maybeStart();
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    _controller?.dispose();
    _controller = null;
  }

  bool get _isFade => widget.item.textReveal == 'fade';

  void _maybeStart() {
    // Симуляция в редакторе обязана остаться статичной: автор смотрит вёрстку,
    // а не представление.
    if (widget.suppressInteractions) return;
    if (widget.item.textReveal == kTextRevealDefault) return;
    final notifier = ref.read(textRevealPreferenceProvider.notifier);
    if (!notifier.isLoaded) {
      notifier.loaded.then((_) {
        if (mounted) _maybeStart();
      });
      return;
    }
    final preference = ref.read(textRevealPreferenceProvider);
    if (!preference.isEnabled) return;

    // Длительность считаем по шаблону автора. Переменные подставляются внутри
    // TextItemWidget и могут чуть изменить число видимых символов — на долю
    // это не влияет, а скорость остаётся заявленной.
    final chars = TextRevealPlan.of(widget.item.text ?? '').totalVisible;
    if (chars == 0) return;

    final ms = (1000 * chars / (widget.item.revealSpeed * preference.factor))
        .round();
    final duration = Duration(
      milliseconds: _isFade ? ms.clamp(250, 1200) : ms.clamp(120, 60000),
    );

    final controller = AnimationController(vsync: this, duration: duration);
    controller.addListener(() {
      if (!_isFade) {
        final visible = TextRevealPlan.of(
          widget.item.text ?? '',
        ).visibleAt(controller.value);
        if (visible == _lastVisibleChars) return;
        _lastVisibleChars = visible;
      }
      setState(() => _fraction = controller.value);
    });
    controller.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      // После последнего кадра хост расклеивается: дальше дерево такое же,
      // как без анимации.
      setState(() => _fraction = 1.0);
    });
    _controller = controller;
    _fraction = 0.0;
    controller.forward();
  }

  void _skip() {
    final controller = _controller;
    if (controller != null) controller.value = 1.0;
  }

  @override
  Widget build(BuildContext context) {
    // Игрок мог выключить анимацию в настройках, а предпочтение доезжает из
    // SharedPreferences уже после того, как хост собрался, — сверяемся и тут.
    final preference = ref.watch(textRevealPreferenceProvider);
    final child = TextItemWidget(
      item: widget.item,
      questId: widget.questId,
      onNavigateToNode: widget.onNavigateToNode,
      isInsideRow: widget.isInsideRow,
      suppressInteractions: widget.suppressInteractions,
      textFit: widget.textFit,
      rowTextAlign: widget.rowTextAlign,
      fontFamily: widget.fontFamily,
      // Плавное появление затемняет весь блок целиком, текст внутри уже
      // полный — префикс нужен только посимвольному набору.
      revealFraction: (_isFade || !preference.isEnabled) ? null : _fraction,
    );

    if (!preference.isEnabled || _fraction >= 1.0) return child;

    final revealed = _isFade
        ? Opacity(opacity: Curves.easeOut.transform(_fraction), child: child)
        : child;

    // Тап по набираемому тексту = «показать сразу». Он же гасит ссылки внутри
    // до конца набора: иначе первый тап по ссылке спрятал бы половину
    // сообщения.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _skip,
      child: revealed,
    );
  }
}

class ButtonItemWidget extends ConsumerWidget {
  final ContentItem item;
  final String questId;
  final Function(ContentItem) onPressed;
  final String? fontFamily;

  const ButtonItemWidget({
    super.key,
    required this.item,
    required this.questId,
    required this.onPressed,
    this.fontFamily,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quest = ref.watch(questProvider(questId)).valueOrNull;

    bool useWrapText = item.wrapTextOverride ?? item.wrapText;
    if (item.wrapTextOverride == null && quest != null) {
      useWrapText = quest.wrapButtonText;
    }

    return GlassButton(
      onPressed: () => onPressed(item),
      text: item.text ?? 'Кнопка',
      wrapText: useWrapText,
      fontFamily: fontFamily,
      // Стиль самой кнопки сильнее стиля квеста: пресет по умолчанию (#159)
      // подхватывается только там, где автор ничего не назначил вручную.
      styleConfig: item.buttonStyle ?? quest?.defaultButtonStyle,
      questId: questId,
    );
  }
}

class GlassButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String text;
  final bool wrapText;
  final String? fontFamily;
  final ButtonStyleConfig? styleConfig;
  final String? questId;

  const GlassButton({
    super.key,
    required this.onPressed,
    required this.text,
    this.wrapText = true,
    this.fontFamily,
    this.styleConfig,
    this.questId,
  });

  TextStyle _buttonTextStyle({
    required double textSize,
    required int? textWeight,
    double? letterSpacing,
    String? fontFamily,
    Color? color,
    FontStyle? fontStyle,
    FontWeight? fontWeight,
  }) {
    return TextStyle(
      fontSize: textSize,
      color: color,
      letterSpacing: letterSpacing,
      fontFamily: fontFamily,
      fontStyle: fontStyle,
      fontWeight:
          fontWeight ??
          (textWeight == null
              ? null
              : FontWeight.values[((textWeight ~/ 100) - 1).clamp(0, 8)]),
    );
  }

  /// Шрифт кнопки: если в стиле задан путь ресурса (например,
  /// `res/fonts/xx.ttf`) — превращаем его в детерминированное family-имя
  /// (то же, что загружает FontService); иначе трактуем как family-имя
  /// напрямую. null → шрифт квеста.
  String? _resolveButtonFont(String? styleFont, String? questFont) {
    final raw = styleFont?.trim();
    if (raw == null || raw.isEmpty) return questFont;
    if (raw.contains('/') && questId != null && questId!.trim().isNotEmpty) {
      return FontService.familyNameFor(questId!, raw);
    }
    return raw;
  }

  TextSpan _parseSimpleMarkdown(
    String value, {
    double textSize = 16,
    int? textWeight,
    double? letterSpacing,
    String? fontFamily,
  }) {
    final RegExp colorExp = RegExp(
      r'\[color=(#[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{8})\](.*?)\[\/color\]',
      dotAll: true,
    );
    final List<TextSpan> spans = [];
    final RegExp exp = RegExp(r'(\*\*(.*?)\*\*)|(\*(.*?)\*)');
    int start = 0;

    final colorMatches = colorExp.allMatches(value).toList();

    if (colorMatches.isNotEmpty) {
      int colorStart = 0;
      for (final colorMatch in colorMatches) {
        if (colorMatch.start > colorStart) {
          final segment = value.substring(colorStart, colorMatch.start);
          spans.addAll(
            _parseMarkdownSegment(
              segment,
              fontFamily,
              textSize: textSize,
              textWeight: textWeight,
              letterSpacing: letterSpacing,
            ),
          );
        }
        final colorStr = colorMatch.group(1)!;
        final content = colorMatch.group(2)!;
        final color = _parseColor(colorStr);
        spans.addAll(
          _parseMarkdownSegment(
            content,
            fontFamily,
            color: color,
            textSize: textSize,
            textWeight: textWeight,
            letterSpacing: letterSpacing,
          ),
        );
        colorStart = colorMatch.end;
      }
      if (colorStart < value.length) {
        final segment = value.substring(colorStart);
        spans.addAll(
          _parseMarkdownSegment(
            segment,
            fontFamily,
            textSize: textSize,
            textWeight: textWeight,
            letterSpacing: letterSpacing,
          ),
        );
      }
    } else {
      for (final match in exp.allMatches(value)) {
        if (match.start > start) {
          spans.add(
            TextSpan(
              text: value.substring(start, match.start),
              style: _buttonTextStyle(
                textSize: textSize,
                textWeight: textWeight,
                letterSpacing: letterSpacing,
                fontFamily: fontFamily,
              ),
            ),
          );
        }
        if (match.group(1) != null) {
          spans.add(
            TextSpan(
              text: match.group(2),
              style: _buttonTextStyle(
                textSize: textSize,
                textWeight: textWeight,
                letterSpacing: letterSpacing,
                fontFamily: fontFamily,
                fontWeight: FontWeight.w900,
              ),
            ),
          );
        } else if (match.group(3) != null) {
          spans.add(
            TextSpan(
              text: match.group(4),
              style: _buttonTextStyle(
                textSize: textSize,
                textWeight: textWeight,
                letterSpacing: letterSpacing,
                fontFamily: fontFamily,
                fontStyle: FontStyle.italic,
              ),
            ),
          );
        }
        start = match.end;
      }
      if (start < value.length) {
        spans.add(
          TextSpan(
            text: value.substring(start),
            style: _buttonTextStyle(
              textSize: textSize,
              textWeight: textWeight,
              letterSpacing: letterSpacing,
              fontFamily: fontFamily,
            ),
          ),
        );
      }
      if (spans.isEmpty && value.isNotEmpty) {
        return TextSpan(
          text: value,
          style: _buttonTextStyle(
            textSize: textSize,
            textWeight: textWeight,
            letterSpacing: letterSpacing,
            fontFamily: fontFamily,
          ),
        );
      }
    }
    return TextSpan(children: spans);
  }

  List<TextSpan> _parseMarkdownSegment(
    String segment,
    String? fontFamily, {
    Color? color,
    double textSize = 16,
    int? textWeight,
    double? letterSpacing,
  }) {
    // Инлайн-теги шрифта: [font=res/fonts/x.ttf]текст[/font] (как в тексте
    // айтемов) — разворачиваем рекурсивно с теми же параметрами кнопки.
    final fontMatches = FontService.inlineFontTag.allMatches(segment).toList();
    if (fontMatches.isNotEmpty) {
      final out = <TextSpan>[];
      int fontStart = 0;
      for (final m in fontMatches) {
        if (m.start > fontStart) {
          out.addAll(
            _parseMarkdownSegment(
              segment.substring(fontStart, m.start),
              fontFamily,
              color: color,
              textSize: textSize,
              textWeight: textWeight,
              letterSpacing: letterSpacing,
            ),
          );
        }
        final rawFont = m.group(1)?.trim();
        final family =
            (rawFont != null &&
                rawFont.contains('/') &&
                questId != null &&
                questId!.trim().isNotEmpty)
            ? FontService.familyNameFor(questId!, rawFont)
            : rawFont;
        out.addAll(
          _parseMarkdownSegment(
            m.group(2)!,
            family,
            color: color,
            textSize: textSize,
            textWeight: textWeight,
            letterSpacing: letterSpacing,
          ),
        );
        fontStart = m.end;
      }
      if (fontStart < segment.length) {
        out.addAll(
          _parseMarkdownSegment(
            segment.substring(fontStart),
            fontFamily,
            color: color,
            textSize: textSize,
            textWeight: textWeight,
            letterSpacing: letterSpacing,
          ),
        );
      }
      return out;
    }

    final List<TextSpan> spans = [];
    final RegExp exp = RegExp(r'(\*\*(.*?)\*\*)|(\*(.*?)\*)');
    int start = 0;
    final defaultColor = color ?? Colors.white;

    for (final match in exp.allMatches(segment)) {
      if (match.start > start) {
        spans.add(
          TextSpan(
            text: segment.substring(start, match.start),
            style: _buttonTextStyle(
              textSize: textSize,
              textWeight: textWeight,
              letterSpacing: letterSpacing,
              fontFamily: fontFamily,
              color: defaultColor,
            ),
          ),
        );
      }
      if (match.group(1) != null) {
        spans.add(
          TextSpan(
            text: match.group(2),
            style: _buttonTextStyle(
              textSize: textSize,
              textWeight: textWeight,
              letterSpacing: letterSpacing,
              fontFamily: fontFamily,
              color: defaultColor,
              fontWeight: FontWeight.w900,
            ),
          ),
        );
      } else if (match.group(3) != null) {
        spans.add(
          TextSpan(
            text: match.group(4),
            style: _buttonTextStyle(
              textSize: textSize,
              textWeight: textWeight,
              letterSpacing: letterSpacing,
              fontFamily: fontFamily,
              color: defaultColor,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      }
      start = match.end;
    }
    if (start < segment.length) {
      spans.add(
        TextSpan(
          text: segment.substring(start),
          style: _buttonTextStyle(
            textSize: textSize,
            textWeight: textWeight,
            letterSpacing: letterSpacing,
            fontFamily: fontFamily,
            color: defaultColor,
          ),
        ),
      );
    }
    if (spans.isEmpty && segment.isNotEmpty) {
      return [
        TextSpan(
          text: segment,
          style: _buttonTextStyle(
            textSize: textSize,
            textWeight: textWeight,
            letterSpacing: letterSpacing,
            fontFamily: fontFamily,
            color: defaultColor,
          ),
        ),
      ];
    }
    return spans;
  }

  Color _parseColor(String colorStr) {
    if (colorStr.startsWith('#')) {
      String hex = colorStr.substring(1);
      if (hex.length == 6) {
        hex = 'FF$hex';
      }
      return Color(int.parse(hex, radix: 16));
    }
    return Colors.white;
  }

  TextSpan _withTextColor(TextSpan span, Color color) {
    final children = span.children?.map<InlineSpan>((child) {
      if (child is TextSpan) {
        return _withTextColor(child, color);
      }
      return child;
    }).toList();
    final existingColor = span.style?.color;
    return TextSpan(
      text: span.text,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
      spellOut: span.spellOut,
      style: (span.style ?? const TextStyle()).copyWith(
        color: existingColor ?? color,
      ),
      children: children,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, child) {
        final _ = ref.watch(gameStateProvider);
        final gameStateNotifier = ref.read(gameStateProvider.notifier);
        final parsedText = resolveTextVariables(
          ref,
          text,
          questId,
          gameStateNotifier,
          sessionKey: GameSessionScope.maybeOf(context),
        );

        if (styleConfig != null) {
          final config = styleConfig!;
          final double module = config.moduleSize.clamp(6.0, 32.0);
          final int centerModules = config.autoCenterByText
              ? (config.centerModules + (parsedText.length / 14).ceil()).clamp(
                  config.centerModules,
                  30,
                )
              : config.centerModules.clamp(4, 30);
          final bool hasModuleAssets =
              config.hasModuleAssets &&
              questId != null &&
              questId!.trim().isNotEmpty;
          final double horizontalPadding =
              config.paddingH ??
              (hasModuleAssets
                  ? (module * 0.6).clamp(10.0, 80.0)
                  : (config.horizontalModules.clamp(2, 20) * module * 0.38)
                        .clamp(10.0, 80.0));
          final double verticalPadding =
              config.paddingV ??
              (hasModuleAssets
                  ? (module * 0.4).clamp(8.0, 34.0)
                  : (config.verticalModules.clamp(2, 10) * module * 0.20).clamp(
                      8.0,
                      34.0,
                    ));
          final double textSize = config.textSize ?? 16.0;
          final int? textWeight = config.textWeight;
          final double? letterSpacing = config.letterSpacing;
          final String? buttonFont = _resolveButtonFont(
            config.fontFamily,
            fontFamily,
          );
          final double minHeight =
              (config.verticalModules.clamp(2, 10) * module * 1.4).clamp(
                40.0,
                120.0,
              );
          final double minWidth = (centerModules * module * 1.15).clamp(
            120.0,
            720.0,
          );
          int assetWidthModules = config.horizontalModules.clamp(2, 40);
          int assetHeightModules = config.verticalModules.clamp(2, 20);
          if (hasModuleAssets && config.autoCenterByText) {
            final maxTotalWidth = (MediaQuery.of(context).size.width * 0.9)
                .clamp(240.0, 900.0);
            final maxCenterModulesRaw = ((maxTotalWidth / module).floor() - 2)
                .clamp(1, 40);
            final minCenterModules = config.horizontalModules.clamp(2, 40);
            final maxCenterModules = maxCenterModulesRaw < minCenterModules
                ? minCenterModules
                : maxCenterModulesRaw;
            final textSpan = _parseSimpleMarkdown(
              parsedText,
              textSize: textSize,
              textWeight: textWeight,
              letterSpacing: letterSpacing,
              fontFamily: buttonFont,
            );
            final painter = TextPainter(
              text: textSpan,
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
              maxLines: wrapText ? null : 1,
            );
            final maxTextWidth = wrapText
                ? (maxTotalWidth - 2 * horizontalPadding).clamp(
                    40.0,
                    maxTotalWidth,
                  )
                : double.infinity;
            painter.layout(maxWidth: maxTextWidth);
            final contentWidth = painter.width + (2 * horizontalPadding);
            final contentHeight = painter.height + (2 * verticalPadding);
            assetWidthModules = (contentWidth / module).ceil().clamp(
              minCenterModules,
              maxCenterModules,
            );
            final minHeightModulesBase = config.verticalModules.clamp(2, 20);
            final lineCount = painter.computeLineMetrics().length;
            final rawHeightModules = (contentHeight / module).ceil().clamp(
              minHeightModulesBase,
              20,
            );
            if (lineCount <= 1) {
              final minHeightModules = math.min(
                minHeightModulesBase,
                assetWidthModules,
              );
              final maxHeightModules = assetWidthModules;
              assetHeightModules = rawHeightModules.clamp(
                minHeightModules,
                maxHeightModules,
              );
            } else {
              assetHeightModules = rawHeightModules;
            }
          }
          final double moduleFrameHeight =
              (assetHeightModules * module) + (module * 2);
          final double moduleFrameWidth =
              (assetWidthModules * module) + (module * 2);
          final double radius =
              config.borderRadius ?? (module * 1.1).clamp(10.0, 40.0);
          final double borderWidth =
              config.borderWidth ?? (module * 0.12).clamp(1.2, 3.5);
          final BoxDecoration buttonDecoration = config.useGradient
              ? BoxDecoration(
                  gradient: LinearGradient(
                    begin: config.gradientIsHorizontal
                        ? Alignment.centerLeft
                        : Alignment.topCenter,
                    end: config.gradientIsHorizontal
                        ? Alignment.centerRight
                        : Alignment.bottomCenter,
                    colors: [
                      config.gradientStartColor.withOpacity(
                        config.effectiveFillOpacity,
                      ),
                      config.gradientEndColor.withOpacity(
                        config.effectiveFillOpacity,
                      ),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: config.borderColor,
                    width: borderWidth,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: config.shadowColor.withOpacity(
                        config.effectiveShadowOpacity,
                      ),
                      blurRadius: config.effectiveShadowBlur,
                      spreadRadius: 0,
                      offset: Offset(
                        config.effectiveShadowOffsetX,
                        config.effectiveShadowOffsetY,
                      ),
                    ),
                  ],
                )
              : BoxDecoration(
                  color: config.fillColor.withOpacity(
                    config.effectiveFillOpacity,
                  ),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: config.borderColor,
                    width: borderWidth,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: config.shadowColor.withOpacity(
                        config.effectiveShadowOpacity,
                      ),
                      blurRadius: config.effectiveShadowBlur,
                      spreadRadius: 0,
                      offset: Offset(
                        config.effectiveShadowOffsetX,
                        config.effectiveShadowOffsetY,
                      ),
                    ),
                  ],
                );
          final content = wrapText
              ? RichText(
                  text: _withTextColor(
                    _parseSimpleMarkdown(
                      parsedText,
                      textSize: textSize,
                      textWeight: textWeight,
                      letterSpacing: letterSpacing,
                      fontFamily: buttonFont,
                    ),
                    config.textColor,
                  ),
                  textAlign: TextAlign.center,
                  softWrap: true,
                  maxLines: null,
                )
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: RichText(
                    text: _withTextColor(
                      _parseSimpleMarkdown(
                        parsedText,
                        textSize: textSize,
                        textWeight: textWeight,
                        letterSpacing: letterSpacing,
                        fontFamily: buttonFont,
                      ),
                      config.textColor,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                );

          if (hasModuleAssets) {
            return LayoutBuilder(
              builder: (context, box) {
                final maxTotalWidth = box.maxWidth.isFinite
                    ? box.maxWidth
                    : (MediaQuery.of(context).size.width * 0.9).clamp(
                        240.0,
                        900.0,
                      );
                final maxPossibleModules =
                    ((maxTotalWidth / module).floor() - 2).clamp(1, 40);
                final configuredMinModules = config.horizontalModules.clamp(
                  2,
                  40,
                );
                final minCenterModules =
                    maxPossibleModules < configuredMinModules
                    ? maxPossibleModules
                    : configuredMinModules;
                final maxCenterModules = maxPossibleModules;

                int widthModules = minCenterModules;
                int heightModules = config.verticalModules.clamp(2, 20);

                if (config.autoCenterByText) {
                  final textSpan = _parseSimpleMarkdown(
                    parsedText,
                    textSize: textSize,
                    textWeight: textWeight,
                    letterSpacing: letterSpacing,
                    fontFamily: buttonFont,
                  );
                  final painter = TextPainter(
                    text: textSpan,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    maxLines: wrapText ? null : 1,
                  );
                  final maxTextWidth = wrapText
                      ? (maxTotalWidth - 2 * horizontalPadding).clamp(
                          40.0,
                          maxTotalWidth,
                        )
                      : double.infinity;
                  painter.layout(maxWidth: maxTextWidth);
                  final contentWidth = painter.width + (2 * horizontalPadding);
                  final contentHeight = painter.height + (2 * verticalPadding);
                  widthModules = (contentWidth / module).ceil().clamp(
                    minCenterModules,
                    maxCenterModules,
                  );
                  final lineCount = painter.computeLineMetrics().length;
                  final rawHeightModules = (contentHeight / module)
                      .ceil()
                      .clamp(1, 20);
                  if (lineCount <= 1) {
                    heightModules = rawHeightModules.clamp(1, widthModules);
                  } else {
                    heightModules = rawHeightModules;
                  }
                }

                final frameWidth = (widthModules * module) + (module * 2);
                final frameHeight = (heightModules * module) + (module * 2);
                final hasBoxW = box.maxWidth.isFinite;
                final hasBoxH = box.maxHeight.isFinite;
                final scaleW = hasBoxW ? (box.maxWidth / frameWidth) : 1.0;
                final scaleH = hasBoxH ? (box.maxHeight / frameHeight) : 1.0;
                final scale = math.min(
                  scaleW.isFinite ? scaleW : 1.0,
                  scaleH.isFinite ? scaleH : 1.0,
                );
                final needsScaleDown = scale < 1.0;
                if (kDebugMode) {
                  final boxW = box.maxWidth.isFinite
                      ? box.maxWidth.toStringAsFixed(1)
                      : 'inf';
                  debugPrint(
                    '[ModuleButton] textLen=${parsedText.length} '
                    'module=${module.toStringAsFixed(1)} '
                    'hModules=${config.horizontalModules} vModules=${config.verticalModules} '
                    'auto=${config.autoCenterByText} '
                    'widthModules=$widthModules heightModules=$heightModules '
                    'frame=${frameWidth.toStringAsFixed(1)}x${frameHeight.toStringAsFixed(1)} '
                    'maxW=${maxTotalWidth.toStringAsFixed(1)} boxW=$boxW '
                    'maxPossible=$maxPossibleModules minCfg=$configuredMinModules '
                    'pad=${horizontalPadding.toStringAsFixed(1)}x${verticalPadding.toStringAsFixed(1)} '
                    'scale=${scale.toStringAsFixed(2)}',
                  );
                  debugPrint(
                    '[ModuleButton] assets corner=${config.cornerAsset} '
                    'h=${config.hAsset} v=${config.vAsset} c=${config.centerAsset}',
                  );
                }
                final frame = _ModuleAssetButtonFrame(
                  questId: questId!,
                  style: config,
                  onTap: onPressed,
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                    vertical: verticalPadding,
                  ),
                  constraints: BoxConstraints.tightFor(
                    width: frameWidth,
                    height: frameHeight,
                  ),
                  child: content,
                );
                if (!needsScaleDown) return frame;
                return FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: frameWidth,
                    height: frameHeight,
                    child: frame,
                  ),
                );
              },
            );
          }

          return DecoratedBox(
            decoration: buttonDecoration,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onPressed,
                borderRadius: BorderRadius.circular(radius),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: minHeight,
                    minWidth: minWidth,
                  ),
                  // Как в ModuleAssetFrame: Center внутри Padding. Без него
                  // RenderPadding вычитает паддинги из минимума высоты и
                  // растягивает подпись на всю плашку — глифы остаются вверху.
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                      vertical: verticalPadding,
                    ),
                    child: Center(child: content),
                  ),
                ),
              ),
            ),
          );
        }

        return GlassSurface(
          radius: 16,
          blurSigma: 6,
          tintColor: Colors.white.withOpacity(0.08),
          borderColor: Colors.white.withOpacity(0.18),
          shadows: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 16,
                ),
                child: wrapText
                    ? RichText(
                        text: _parseSimpleMarkdown(parsedText),
                        textAlign: TextAlign.center,
                        softWrap: true,
                        maxLines: null,
                      )
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        child: RichText(
                          text: _parseSimpleMarkdown(parsedText),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ModuleAssetButtonFrame extends StatelessWidget {
  final String questId;
  final ButtonStyleConfig style;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final BoxConstraints constraints;
  final Widget child;

  const _ModuleAssetButtonFrame({
    required this.questId,
    required this.style,
    required this.onTap,
    required this.padding,
    required this.constraints,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final module = style.moduleSize.clamp(6.0, 32.0);
    return ModuleAssetFrame(
      questId: questId,
      style: style,
      module: module,
      onTap: onTap,
      padding: padding,
      constraints: constraints,
      child: child,
    );
  }
}

class ImageItemWidget extends ConsumerStatefulWidget {
  final ContentItem item;
  final String questId;
  final Function(ContentItem) onInteract;
  final bool suppressInteractions;

  /// Переопределение скругления, приходящее от родительского ряда
  /// через `row.childImageRoundedCorners`. `null` — использовать
  /// дефолт (скруглять).
  final bool? roundedCornersOverride;

  /// Fit для контекстов с фиксированным боксом (например, ребёнок в
  /// «стеке»). `null` — обычное поведение: BoxFit.cover на всю ширину.
  /// Заданный fit рендерит картинку внутри [SizedBox.expand] — пропорции
  /// сохраняются, ничего не обрезается/не плющится.
  final BoxFit? boxFit;

  const ImageItemWidget({
    super.key,
    required this.item,
    required this.questId,
    required this.onInteract,
    this.suppressInteractions = false,
    this.roundedCornersOverride,
    this.boxFit,
  });

  @override
  ConsumerState<ImageItemWidget> createState() => _ImageItemWidgetState();
}

class _ImageItemWidgetState extends ConsumerState<ImageItemWidget> {
  /// Файл резолвится асинхронно и кешируется по пути. Иначе `FutureBuilder`
  /// пересоздавал future на каждую пересборку: картинка мигала и заново
  /// читалась с диска (на слабом устройстве это заметно).
  String? _futureFor;
  Future<File?>? _fileFuture;

  void _openFullScreen(BuildContext context, File imageFile) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: const BackButton(color: Colors.white),
          ),
          body: PhotoView(
            imageProvider: FileImage(imageFile),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 2.5,
            heroAttributes: PhotoViewHeroAttributes(tag: widget.item.id),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final path = resolveItemResourcePath(ref, item, widget.questId);
    if (path != _futureFor) {
      _futureFor = path;
      _fileFuture = QuestImageSource.resolve(widget.questId, path);
    }

    return FutureBuilder<File?>(
      future: _fileFuture,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file != null) {
          // Углы по умолчанию скругляем; ряд отключает это через
          // `row.childImageRoundedCorners`.
          final bool rounded = widget.roundedCornersOverride ?? true;
          final Widget rawImage = widget.boxFit != null
              ? SizedBox.expand(child: Image.file(file, fit: widget.boxFit))
              : Image.file(file, fit: BoxFit.cover, width: double.infinity);
          final imageWidget = Hero(
            tag: item.id,
            child: rounded
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: rawImage,
                  )
                : rawImage,
          );

          if (widget.suppressInteractions) return imageWidget;

          return GestureDetector(
            onTap: () => _openFullScreen(context, file),
            child: imageWidget,
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}

class _AudioItemPlayer extends ConsumerStatefulWidget {
  final String questId;
  final ContentItem item;
  final double? initialVolume;
  final VoidCallback onComplete;

  const _AudioItemPlayer({
    required this.questId,
    required this.item,
    required this.onComplete,
    this.initialVolume,
  });

  @override
  ConsumerState<_AudioItemPlayer> createState() => _AudioItemPlayerState();
}

class _AudioItemPlayerState extends ConsumerState<_AudioItemPlayer> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _playerStateSub;

  void _log(String message) {
    debugPrint('[QuestAudio][content][${widget.item.id}] $message');
  }

  /// Итоговая громкость: айтемная (item.volume × node-громкость) ×
  /// глобальный множитель игрока (ползунок в игровом UI).
  double _effectiveVolume() {
    final global = ref.read(globalAudioVolumeProvider);
    return ((widget.initialVolume ?? 1.0) * global).clamp(0.0, 1.0);
  }

  @override
  void initState() {
    super.initState();
    // Глобальная громкость — live-регулировка играющего инлайн-аудио без
    // пересоздания плеера (подписка закрывается автоматически при unmount).
    ref.listenManual(globalAudioVolumeProvider, (prev, next) {
      if (prev == next || _player == null) return;
      _player!.setVolume(_effectiveVolume());
    });
    _play();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onComplete());
  }

  Future<void> _play() async {
    if (widget.item.resourcePath == null) return;
    try {
      // Резолвер, а не прямая склейка: автор мог написать имя из библиотеки
      // или uuid вместо `res/audio/<uuid>.mp3`.
      final path = await QuestImageSource.resolveOnDisk(
        widget.questId,
        widget.item.resourcePath,
      );
      if (path.isEmpty) {
        _log('missing file: ${widget.item.resourcePath}');
        return;
      }

      if (!mounted) return;
      final volume = _effectiveVolume();
      _player = AudioPlayer();
      _playerStateSub = _player!.onPlayerStateChanged.listen((state) {
        _log('state=$state');
      });

      // lowLatency on Android maps to SoundPool and can truncate long tracks.
      // Content audio in quests may include full-length ambiance/music, so use mediaPlayer.
      if (Platform.isAndroid) {
        await _player!.setPlayerMode(PlayerMode.mediaPlayer);
      }
      if (Platform.isAndroid || Platform.isIOS) {
        await _player!.setAudioContext(
          AudioContext(
            android: AudioContextAndroid(
              usageType: AndroidUsageType.game,
              contentType: AndroidContentType.music,
              audioFocus: AndroidAudioFocus.none,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.playback,
              options: {AVAudioSessionOptions.mixWithOthers},
            ),
          ),
        );
      }
      await _player!.setVolume(volume);
      _log('play start path=$path volume=${volume.toStringAsFixed(3)}');
      await _player!.play(DeviceFileSource(path));
    } catch (e) {
      _log('play error: $e');
    }
  }

  @override
  void dispose() {
    _log('dispose');
    _playerStateSub?.cancel();
    _player?.stop();
    _player?.dispose();
    _player = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class TimerItemWidget extends StatefulWidget {
  final ContentItem item;

  /// Секунды отсчёта: их посчитал вызывающий (формула движком либо `text`).
  /// Меняются только вместе с пересозданием виджета — таймер не перезапускается
  /// на середине.
  final double seconds;
  final VoidCallback onComplete;
  const TimerItemWidget({
    super.key,
    required this.item,
    required this.seconds,
    required this.onComplete,
  });
  @override
  State<TimerItemWidget> createState() => _TimerItemWidgetState();
}

class _TimerItemWidgetState extends State<TimerItemWidget>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late AnimationController _controller;
  bool _isCompleted = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (widget.seconds * 1000).toInt()),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_isCompleted) {
        _isCompleted = true;
        if (mounted) widget.onComplete();
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.item.isHidden || _isCompleted) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return LinearProgressIndicator(
            value: _controller.value,
            backgroundColor: Colors.white10,
            color: Colors.white30,
          );
        },
      ),
    );
  }
}

class WaitInputItemWidget extends StatefulWidget {
  final ContentItem item;
  final String questId;
  final VoidCallback onComplete;
  final String? fontFamily;

  const WaitInputItemWidget({
    super.key,
    required this.item,
    required this.questId,
    required this.onComplete,
    this.fontFamily,
  });
  @override
  State<WaitInputItemWidget> createState() => _WaitInputItemWidgetState();
}

class _WaitInputItemWidgetState extends State<WaitInputItemWidget>
    with AutomaticKeepAliveClientMixin {
  bool _isCompleted = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_isCompleted) return const SizedBox.shrink();

    return Consumer(
      builder: (context, ref, child) {
        final _ = ref.watch(gameStateProvider);
        final gameStateNotifier = ref.read(gameStateProvider.notifier);
        final rawText = widget.item.text ?? "Нажмите для продолжения";
        final parsedText = resolveTextVariables(
          ref,
          rawText,
          widget.questId,
          gameStateNotifier,
          sessionKey: GameSessionScope.maybeOf(context),
        );

        return GestureDetector(
          onTap: () {
            setState(() => _isCompleted = true);
            widget.onComplete();
          },
          child: Container(
            height: 60,
            alignment: Alignment.center,
            child: Text(
              parsedText,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontFamily: widget.fontFamily,
              ),
            ),
          ),
        );
      },
    );
  }
}

class InputItemWidget extends StatefulWidget {
  final ContentItem item;
  final String questId;
  final Function(String, String) onSubmitted;
  final Function(ContentItem) onInteract;
  final VoidCallback onComplete;
  final OnNavigateToNode onNavigateToNode;
  final String? fontFamily;

  const InputItemWidget({
    super.key,
    required this.item,
    required this.questId,
    required this.onSubmitted,
    required this.onInteract,
    required this.onComplete,
    required this.onNavigateToNode,
    this.fontFamily,
  });
  @override
  State<InputItemWidget> createState() => _InputItemWidgetState();
}

class _InputItemWidgetState extends State<InputItemWidget>
    with AutomaticKeepAliveClientMixin {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  bool _showError = false;
  String? _submittedValue;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submittedValue != null) return;
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() => _showError = true);
      return;
    }

    if (widget.item.variableName != null) {
      widget.onSubmitted(widget.item.variableName!, text);
    }

    setState(() => _submittedValue = text);

    widget.onInteract(widget.item);

    bool hasAction =
        widget.item.targetNodeId != null ||
        widget.item.scriptForEvent('onSubmit') != null;

    if (!hasAction) {
      widget.onComplete();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_submittedValue != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.green.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.item.text != null)
              Consumer(
                builder: (context, ref, _) {
                  final gameStateNotifier = ref.watch(
                    gameStateProvider.notifier,
                  );
                  final parsed = resolveTextVariables(
                    ref,
                    widget.item.text!,
                    widget.questId,
                    gameStateNotifier,
                    sessionKey: GameSessionScope.maybeOf(context),
                  );
                  return Text(
                    parsed,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontFamily: widget.fontFamily,
                    ),
                  );
                },
              ),
            const SizedBox(height: 4),
            Text(
              _submittedValue!,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
                fontFamily: widget.fontFamily,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.item.text != null && widget.item.text!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextItemWidget(
              item: widget.item,
              questId: "",
              onNavigateToNode: widget.onNavigateToNode,
              fontFamily: widget.fontFamily,
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _showError ? Colors.redAccent : Colors.white24,
            ),
          ),
          child: TextField(
            controller: _textController,
            focusNode: _focusNode,
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
          child: Consumer(
            builder: (context, ref, child) {
              final quest = widget.questId.isEmpty
                  ? null
                  : ref.watch(questProvider(widget.questId)).valueOrNull;

              bool useWrapText =
                  widget.item.wrapTextOverride ?? widget.item.wrapText;
              if (widget.item.wrapTextOverride == null && quest != null) {
                useWrapText = quest.wrapButtonText;
              }

              return GlassButton(
                onPressed: _submit,
                text: widget.item.buttonText ?? 'OK',
                wrapText: useWrapText,
                fontFamily: widget.fontFamily,
                // Кнопка ввода — тоже кнопка квеста (#159).
                styleConfig: quest?.defaultButtonStyle,
                questId: widget.questId,
              );
            },
          ),
        ),
      ],
    );
  }
}

class ChatItemWidget extends ConsumerStatefulWidget {
  final ContentItem item;
  final String questId;
  final String? fontFamily;

  const ChatItemWidget({
    super.key,
    required this.item,
    required this.questId,
    this.fontFamily,
  });

  @override
  ConsumerState<ChatItemWidget> createState() => _ChatItemWidgetState();
}

class _ChatItemWidgetState extends ConsumerState<ChatItemWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
        );
    if (widget.item.animateIn) {
      _animationController.forward();
    } else {
      _animationController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  String _parseTextWithVariables(
    WidgetRef ref,
    String text,
    String questId,
    GameStateNotifier notifier,
  ) {
    final key = GameSessionScope.maybeOf(ref.context);
    return resolveTextVariables(ref, text, questId, notifier, sessionKey: key);
  }

  Widget _buildMessageContent() {
    final _ = ref.watch(gameStateProvider);
    final gameStateNotifier = ref.read(gameStateProvider.notifier);
    final parsedText = _parseTextWithVariables(
      ref,
      widget.item.text ?? '',
      widget.questId,
      gameStateNotifier,
    );
    final rawSenderName = widget.item.senderName?.trim();
    final senderName = rawSenderName == null || rawSenderName.isEmpty
        ? 'Отправитель'
        : _parseTextWithVariables(
            ref,
            rawSenderName,
            widget.questId,
            gameStateNotifier,
          );
    final avatarColor = Color(widget.item.avatarColor ?? 0xFF26C6DA);
    final isIncoming = widget.item.isIncoming;

    if (isIncoming) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildAvatar(avatarColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    senderName,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: widget.fontFamily,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.zero,
                        topRight: Radius.circular(14),
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      ),
                    ),
                    child: _buildMessageText(parsedText),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    senderName,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontFamily: widget.fontFamily,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00C853).withOpacity(0.15),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(14),
                        topRight: Radius.zero,
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      ),
                    ),
                    child: _buildMessageText(parsedText),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildAvatar(Color color) {
    if (widget.item.avatarPath != null) {
      return FutureBuilder<File?>(
        future: QuestImageSource.resolve(
          widget.questId,
          widget.item.avatarPath,
        ),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return CircleAvatar(
              radius: 18,
              backgroundImage: FileImage(snapshot.data!),
            );
          }
          return CircleAvatar(
            radius: 18,
            backgroundColor: color,
            child: const Icon(Icons.person, size: 18, color: Colors.white),
          );
        },
      );
    }
    return CircleAvatar(
      radius: 18,
      backgroundColor: color,
      child: const Icon(Icons.person, size: 18, color: Colors.white),
    );
  }

  Widget _buildMessageText(String text) {
    final config = MarkdownConfig(
      configs: [
        PConfig(
          textStyle: TextStyle(
            color: Colors.white,
            fontSize: 14,
            height: 1.3,
            fontFamily: widget.fontFamily,
          ),
        ),
        ListConfig(
          marginLeft: 18.0,
          marginBottom: 0.0,
          marker: safeListMarker(Colors.white),
        ),
        CheckBoxConfig(builder: safeCheckboxBuilder(Colors.white)),
        const BlockquoteConfig(
          textColor: Colors.white70,
          sideColor: Colors.white70,
        ),
      ],
    );

    final markdownText = preserveMarkdownHardLineBreaks(text);
    final generator = createColorMarkdownGenerator(
      linesMargin: const EdgeInsets.symmetric(vertical: 2),
      questId: widget.questId,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: generator.buildWidgets(markdownText, config: config),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.animateIn) {
      return FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: _buildMessageContent(),
        ),
      );
    }
    return _buildMessageContent();
  }
}
