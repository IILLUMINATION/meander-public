/// Экран игры в браузере: фон ноды, очередь раскрытия, закреплённые стеки.
///
/// Компоновка повторяет нативный `GameScreen._buildBodyContent`: фон рисуется
/// в общий `Stack`, контент — колонкой не шире 720 px, стеки с `stackPin` —
/// слоем поверх прокрутки. Клиентская логика минимальна: видимость, числа и
/// переходы решает движок, здесь только раскладка и анимации.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:mnd_core/engine/item_visibility.dart';
import 'package:mnd_core/models/content_item.dart';

import 'item_view.dart';
import 'player.dart';
import 'quest_source.dart';

class PlayScreen extends StatefulWidget {
  const PlayScreen({super.key, required this.player});

  final QuestPlayer player;

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  /// Та же шапка колонки, что у нативного плеера: на широком окне игра
  /// центрируется, а не растягивается во весь браузер.
  static const double _columnCap = kContentColumnMaxWidth;
  static const Color _fallbackBackground = Color(0xFF0B0D10);

  String? _questFont;
  String? _timerNodeId;
  int _remainingMs = 0;
  Timer? _tick;

  QuestPlayer get player => widget.player;

  @override
  void initState() {
    super.initState();
    player.addListener(_onPlayerChanged);
    _loadQuestFonts();
  }

  @override
  void dispose() {
    player.removeListener(_onPlayerChanged);
    _tick?.cancel();
    super.dispose();
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    _syncNodeTimer();
    setState(() {});
  }

  /// Бар таймера ноды: отсчёт ведёт клиент, а решение о переходе по истечении
  /// принимает движок (`_startNodeTimer` в [QuestPlayer]).
  void _syncNodeTimer() {
    final node = player.node;
    final duration = node?.timerDuration ?? 0;
    final running = duration > 0 && node?.timerHidden != true;
    final id = running ? '${player.nodeId}:${player.presentationId}' : null;
    if (id == _timerNodeId) return;
    _timerNodeId = id;
    _tick?.cancel();
    _tick = null;
    if (id == null) return;
    _remainingMs = (duration * 1000).round();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      setState(() {
        if (_remainingMs > 0) _remainingMs -= 250;
      });
    });
  }

  /// Шрифты квеста лежат в архиве, а не в `pubspec`: регистрируем их из байтов
  /// под теми же family-именами, что даёт нативный `FontService`, — тогда
  /// инлайн-тег `[font=res/fonts/x.ttf]` из текста находит шрифт без правок.
  Future<void> _loadQuestFonts() async {
    final bundle = player.bundle;
    currentQuestId = bundle.questId;
    final loaded = <String>{};
    for (final path in bundle.fontPaths) {
      final bytes = bundle.assets[path];
      if (bytes == null) continue;
      final family = questFontFamily(path);
      if (family == null || !loaded.add(family)) continue;
      try {
        final loader = FontLoader(family);
        loader.addFont(
          Future.value(
            ByteData.view(
              bytes.buffer,
              bytes.offsetInBytes,
              bytes.lengthInBytes,
            ),
          ),
        );
        await loader.load();
      } catch (e) {
        debugPrint('[web-player] шрифт $path не загрузился: $e');
      }
    }
    final custom = bundle.config['customFontFileName']?.toString().trim();
    String? questFont;
    if (custom != null && custom.isNotEmpty) {
      questFont = questFontFamily(
        custom.contains('/') ? custom : 'res/fonts/$custom',
      );
    }
    if (!mounted) return;
    setState(() => _questFont = questFont);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: player.backgroundColor ?? _fallbackBackground,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _background(player.bundle, player),
              SafeArea(child: _body(player)),
              ..._pinnedLayers(player),
              // Мёртвое нажатие без этой плашки неотличимо от «кнопка не
              // кликабельна»: ошибка движка есть, а игроку ничего не видно.
              if (player.phase == PlayPhase.playing &&
                  player.errorMessage != null)
                _errorBanner(player),
            ],
          ),
        );
      },
    );
  }

  Widget _background(QuestAssets bundle, QuestPlayer player) {
    final bytes = player.backgroundImageId == null
        ? null
        : player.assetBytes(player.backgroundImageId);
    final dims = bundle.config['dimBackground'] != false;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: player.backgroundColor ?? _fallbackBackground),
        if (bytes != null)
          Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          ),
        // Без затемнения белый текст квеста сливается с яркой фотографией.
        if (bytes != null && dims) const ColoredBox(color: Color(0x66000000)),
      ],
    );
  }

  /// Плашка ошибки во время игры: тап, который ничего не сделал, обязан быть
  /// виден. Исключение движка, паника в wasm или «движок молчит» иначе
  /// оседают только в `debugPrint`, а игроку кажется, что кнопка сломана.
  Widget _errorBanner(QuestPlayer player) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: Material(
          color: const Color(0xFF3B1D22),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    player.errorMessage!,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white54,
                    size: 18,
                  ),
                  onPressed: player.clearError,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(QuestPlayer player) {
    if (player.phase == PlayPhase.loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Загрузка квеста…', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    if (player.phase == PlayPhase.failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                player.errorMessage ?? 'Квест не открылся',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => player.start(),
                child: const Text('Попробовать снова'),
              ),
            ],
          ),
        ),
      );
    }

    final node = player.node;
    final items = player.revealed;
    // Внутренний отступ между корневыми элементами ноды: null → 24 px,
    // 0 → стык без зазоров (как в нативном плеере).
    final double? nodeSpacing = node?.itemSpacing;
    final hideTitle = player.bundle.config['hideNodeTitles'] == true;

    return Column(
      children: [
        if (!hideTitle && (node?.title ?? '').isNotEmpty) _header(node!.title),
        if (node != null &&
            node.timerDuration != null &&
            node.timerHidden != true &&
            node.timerDuration! > 0)
          _timerBar(),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _columnCap),
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final pad = nodeSpacing != null
                      ? (index == items.length - 1 ? 0.0 : nodeSpacing)
                      : 24.0;
                  return RepaintBoundary(
                    child: ItemView(
                      // Ключ с поколением: вход в ту же ноду заново обязан
                      // перезапустить анимации, как новый `presentationId`.
                      key: ValueKey('game_${player.presentationId}_${item.id}'),
                      player: player,
                      item: item,
                      onComplete: player.revealNext,
                      bottomPadding: pad,
                      imageRounded: node?.imageRoundedCorners,
                      fontFamily: _questFont,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        player.resolveText(title),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 18,
          fontFamily: _questFont,
          shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
    );
  }

  Widget _timerBar() {
    final seconds = (_remainingMs / 1000).ceil();
    final text = seconds >= 3600
        ? '${seconds ~/ 3600}:${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
        : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.timer_outlined, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Стеки с `stackPin` поверх прокрутки: не уезжают при скролле, модалка
  /// дополнительно затемняет ноду и не пропускает к ней тапы.
  List<Widget> _pinnedLayers(QuestPlayer player) {
    if (player.pinned.isEmpty) return const [];
    final visible = <ContentItem>[
      for (final item in player.pinned)
        if (!player.dismissedStacks.contains(item.id) ||
            player.visibilityOf(item) == EngineVisibility.visible)
          item,
    ];
    if (visible.isEmpty) return const [];
    return [
      Positioned.fill(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final vw = constraints.maxWidth;
              final vh = constraints.maxHeight;
              final columnWidth = vw < _columnCap ? vw : _columnCap;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final item in visible)
                    PinnedStackLayer(
                      key: ValueKey(
                        'pinned_stack_${player.presentationId}_${item.id}',
                      ),
                      player: player,
                      item: item,
                      viewport: Size(columnWidth, vh),
                      offset: Offset((vw - columnWidth) / 2, 0),
                      onDismiss: () => player.dismissPinnedStack(item.id),
                      imageRounded: player.node?.imageRoundedCorners,
                      fontFamily: _questFont,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ];
  }
}
