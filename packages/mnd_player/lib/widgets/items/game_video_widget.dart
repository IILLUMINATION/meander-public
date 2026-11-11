import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mnd_player/utils/quest_shot.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/audio_volume_provider.dart';
import 'package:mnd_player/services/trigger_pipeline.dart';
import 'package:mnd_player/services/video_cache_service.dart';
import 'package:mnd_player/utils/locale_fix.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:mnd_player/utils/text_variable_resolver.dart';
import 'package:url_launcher/url_launcher.dart';

class GameVideoWidget extends ConsumerStatefulWidget {
  final ContentItem item;
  final String questId;
  final VoidCallback onComplete;
  final Function(ContentItem) onInteract;

  /// Переход по результату поведения `onVideoEnded` — тот же канал, что у
  /// стека и HUD (грузит ноду).
  final void Function(String nodeId)? onTransition;
  final double? initialVolume;
  final MeanderGameEngine? engine;

  const GameVideoWidget({
    super.key,
    required this.item,
    required this.questId,
    required this.onComplete,
    required this.onInteract,
    this.onTransition,
    this.initialVolume,
    this.engine,
  });

  @override
  ConsumerState<GameVideoWidget> createState() => _GameVideoWidgetState();
}

class _GameVideoWidgetState extends ConsumerState<GameVideoWidget> {
  Player? _player;
  VideoController? _controller;
  String? _cacheKey;
  bool _ready = false;
  bool _error = false;
  String? _errorMsg;
  bool _completedFired = false;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<dynamic>? _errorSub;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  DateTime _lastPositionUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isPlaying = false;

  bool get _isNetwork {
    final url = widget.item.videoUrl?.trim() ?? '';
    if (url.isEmpty) return false;
    return url.startsWith('http://') || url.startsWith('https://');
  }

  bool get _isYoutube => widget.item.isYoutubeVideo;

  String? get _poster => widget.item.videoPosterPath;

  @override
  void initState() {
    super.initState();
    _initPlayer();
    // volume listener
    ref.listenManual<double>(globalAudioVolumeProvider, (prev, next) {
      _applyVolume();
    });
  }

  bool _isLinuxMpAvailable() {
    if (!Platform.isLinux) return true;
    const candidates = [
      '/usr/lib/libmpv.so',
      '/usr/lib/libmpv.so.2',
      '/usr/lib/libmpv.so.1',
      '/usr/lib64/libmpv.so',
      '/usr/lib/x86_64-linux-gnu/libmpv.so.1',
      '/usr/lib/x86_64-linux-gnu/libmpv.so',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return true;
    }
    return false;
  }

  Future<void> _initPlayer() async {
    final item = widget.item;

    // Linux: media_kit needs system mpv. Check file existence to avoid native crash on dummy.
    if (Platform.isLinux && !_isLinuxMpAvailable()) {
      if (!mounted) return;
      // Youtube/network still show their own placeholders
      if (_isYoutube || _isNetwork) {
        setState(() {
          _error = false;
          _ready = true;
        });
        if (!(item.videoBlockProgress ?? false)) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => widget.onComplete(),
          );
        }
        return;
      }
      setState(() {
        _error = true;
        _errorMsg =
            'Видео на Linux: предпросмотр. Для инлайн-воспроизведения установите mpv: sudo pacman -S mpv libepoxy и пересоберите';
      });
      _safeComplete();
      return;
    }

    // Youtube fallback: don't even try media_kit playback, show external
    if (_isYoutube && _isNetwork) {
      setState(() {
        _ready = true;
        _error = false;
      });
      // Not blocking unless videoBlockProgress
      if (!(item.videoBlockProgress ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onComplete(),
        );
      }
      return;
    }

    String? source;
    bool isNetwork = false;

    final videoUrl = item.videoUrl?.trim();
    if (videoUrl != null && videoUrl.isNotEmpty) {
      source = videoUrl;
      isNetwork =
          videoUrl.startsWith('http://') || videoUrl.startsWith('https://');
    } else if (item.resourcePath != null &&
        item.resourcePath!.trim().isNotEmpty) {
      final rp = item.resourcePath!.trim();
      // Один резолвер на все типы ресурсов: путь, `x.mp4` без каталога, имя из
      // библиотеки или uuid. Раньше здесь была своя ветка на каждый случай, и
      // `quests/...` в одной из них удваивал префикс.
      final full = await QuestImageSource.resolveOnDisk(widget.questId, rp);
      if (full.isEmpty) {
        setState(() {
          _error = true;
          _errorMsg = 'Файл не найден: $rp';
        });
        _safeComplete();
        return;
      }
      source = full;
    }

    if (source == null || source.isEmpty) {
      setState(() {
        _error = true;
        _errorMsg = 'Источник видео не задан';
      });
      _safeComplete();
      return;
    }

    try {
      try {
        ensureCNumericLocale();
        MediaKit.ensureInitialized();
      } catch (_) {}
      final cacheKey = source;
      _cacheKey = cacheKey;
      final cached = VideoCacheService.get(cacheKey);
      Player player;
      VideoController controller;
      bool isCached = false;
      if (cached != null) {
        player = cached;
        controller = VideoController(
          player,
          // Используем аппаратный декодер: программный режим заметно
          // блокирует слабые телефоны при видео поверх сложной сцены.
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
          ),
        );
        _player = player;
        _controller = controller;
        isCached = true;
      } else {
        player = Player(
          configuration: const PlayerConfiguration(title: 'mnd_video'),
        );
        controller = VideoController(
          player,
          // Используем аппаратный декодер: программный режим заметно
          // блокирует слабые телефоны при видео поверх сложной сцены.
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
          ),
        );
        _player = player;
        _controller = controller;
        VideoCacheService.put(cacheKey, player);
      }

      await _applyVolumeTo(player);

      _completedSub = player.stream.completed.listen((completed) {
        if (completed && !_completedFired) {
          _completedFired = true;
          _handleEnded();
        }
      });
      _posSub = player.stream.position.listen((pos) {
        // Проверки времени должны идти на каждом событии, но прогресс-бару
        // не нужна пересборка виджета 10+ раз в секунду. Ограничиваем только
        // UI-обновления, не меняя семантику trim/таймеров.
        if (!_isPlaying) return;
        _checkTrimEnd(pos);
        _checkTimedBehaviours(pos);
        if (!mounted) return;
        final now = DateTime.now();
        if (now.difference(_lastPositionUiUpdate).inMilliseconds < 200) return;
        _lastPositionUiUpdate = now;
        setState(() => _position = pos);
      });
      _durSub = player.stream.duration.listen((d) {
        if (!mounted) return;
        setState(() => _duration = d);
        final startMs = item.videoStartMs;
        if (startMs != null && startMs > 0) {
          player.seek(Duration(milliseconds: startMs));
        }
      });
      _playingSub = player.stream.playing.listen((p) {
        if (!mounted || _isPlaying == p) return;
        setState(() => _isPlaying = p);
      });
      _errorSub = player.stream.error.listen((e) {
        if (!mounted) return;
        setState(() {
          _error = true;
          _errorMsg = e.toString();
        });
      });

      if (isCached) {
        // Reuse cached player - seek to start and play/pause as needed
        final startMs = item.videoStartMs;
        if (startMs != null && startMs > 0) {
          await player.seek(Duration(milliseconds: startMs));
        } else {
          await player.seek(Duration.zero);
        }
        if (item.videoLoop ?? false) {
          await player.setPlaylistMode(PlaylistMode.single);
        }
        if (item.videoMuted ?? false) {
          await player.setVolume(0);
        } else {
          await _applyVolumeTo(player);
        }
        // Офскрин-копия для снимка не должна звучать и играть.
        if ((item.videoAutoplay ?? true) && !QuestShot.renderingShot) {
          await player.play();
        } else {
          await player.pause();
        }
      } else {
        final media = isNetwork ? Media(source) : Media('file://$source');
        await player.open(
          media,
          play: (item.videoAutoplay ?? true) && !QuestShot.renderingShot,
        );
        if (item.videoLoop ?? false) {
          await player.setPlaylistMode(PlaylistMode.single);
        }
        if (item.videoMuted ?? false) {
          await player.setVolume(0);
        }
      }

      if (!mounted) return;
      setState(() => _ready = true);
      if (!(item.videoBlockProgress ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onComplete(),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _errorMsg = e.toString();
      });
      _safeComplete();
    }
  }

  Future<void> _applyVolume() async {
    final p = _player;
    if (p == null) return;
    await _applyVolumeTo(p);
  }

  Future<void> _applyVolumeTo(Player p) async {
    if (widget.item.videoMuted ?? false) {
      await p.setVolume(0);
      return;
    }
    final global = ref.read(globalAudioVolumeProvider);
    final vol = ((widget.initialVolume ?? widget.item.volume) * global).clamp(
      0.0,
      1.0,
    );
    // media_kit оперирует шкалой 0..100 (100 = норма), множитель у нас 0..1.
    await p.setVolume(vol * 100);
  }

  void _checkTrimEnd(Duration pos) {
    final endMs = widget.item.videoEndMs;
    if (endMs != null && endMs > 0 && pos.inMilliseconds >= endMs) {
      _player?.pause();
      _handleEnded();
    }
  }

  void _checkTimedBehaviours(Duration pos) {
    // fire onVideoTime behaviours — we just set variable + re-evaluate visibility centrally?
    // For v1 we rely on author using script that sets variable; we don't auto-trigger here.
    // Placeholder for future: parse behaviours with event onVideoTime:<ms>
    final engine = widget.engine;
    if (engine == null) return;
    final item = widget.item;
    for (final bh in item.resolvedBehaviours) {
      if (bh.event.startsWith('onVideoTime:')) {
        final msStr = bh.event.substring('onVideoTime:'.length);
        final target = int.tryParse(msStr);
        if (target != null &&
            pos.inMilliseconds >= target &&
            pos.inMilliseconds < target + 500) {
          // debounce via variable flag not to retrigger repeatedly
          // execute once per reveal
          // we use engine.executeBehaviour with synthetic event
          // For now just fire via trigger pipeline if not already fired
        }
      }
    }
  }

  Future<void> _handleEnded() async {
    final item = widget.item;
    final engine = widget.engine;
    String? transitionTo;
    if (engine != null) {
      try {
        transitionTo = await engine.executeBehaviour(
          item.toJson(),
          'onVideoEnded',
        );
      } catch (_) {
        // Сломанный скрипт не должен ронять ноду: доигрываем как без него.
      }
      if (!mounted) return;
      // Ядро меняет переменные у себя — без слива дельты UI их не увидит.
      // Сливается всё, что осталось от скрипта (звуки, ссылки, кадры `wait`),
      // а не только дельта: иначе они доиграют уже в следующей ноде.
      await TriggerPipeline.syncAfterWidgetBehaviour(
        ref: ref,
        context: context,
        engine: engine,
      );
    }
    if (transitionTo != null && transitionTo.isNotEmpty) {
      // Переход важнее «показать следующий элемент»: иначе revealNextItem
      // сдвинул бы курс уже в новой ноде.
      widget.onTransition?.call(transitionTo);
      return;
    }
    if (mounted) {
      widget.onComplete();
    }
  }

  void _safeComplete() {
    if (!(widget.item.videoBlockProgress ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onComplete());
    } else {
      // blocking but error: still complete to not soft-lock
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onComplete());
    }
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _errorSub?.cancel();
    if (_cacheKey != null && _player != null) {
      // Ставим плеер на паузу, но оставляем в кэше: декодер не крутится
      // впустую, а ревизит ноды не требует перезагрузки.
      _player!.pause();
      VideoCacheService.release(_cacheKey!);
    } else {
      _player?.dispose();
    }
    super.dispose();
  }

  BoxFit _parseFit(String? raw) {
    switch (raw) {
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'contain':
        return BoxFit.contain;
      default:
        return BoxFit.contain;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final showControls = item.videoShowControls ?? true;
    final allowFullscreen = item.videoAllowFullscreen ?? true;
    final allowSeek = item.videoAllowSeek ?? true;
    final fit = _parseFit(item.videoFit);
    // Скругление может считать движок; `Radius` не терпит отрицательных и
    // безумных значений, поэтому рамка как у остальных числовых полей.
    final borderRadius = resolveItemNumeric(
      ref,
      item,
      'borderRadius',
      widget.questId,
      staticValue: item.borderRadius ?? 12.0,
    ).clamp(0.0, 999.0);

    Widget content;

    if (_error) {
      content = _buildError();
    } else if (_isYoutube && _isNetwork) {
      content = _buildYoutubePlaceholder();
    } else if (!_ready || _controller == null || _player == null) {
      content = _buildPosterOrLoader(borderRadius);
    } else {
      final videoFit = fit == BoxFit.contain
          ? BoxFit.contain
          : fit == BoxFit.cover
          ? BoxFit.cover
          : BoxFit.fill;
      // Custom theme to raise seek bar a bit to avoid bottom clipping inside ClipRRect
      // «Разрешить перемотку» гасит не только полосу, но и жесты: свайп
      // горизонталью и двойной тап по краям перематывают сами по себе,
      // поэтому без этого флага настройка оставалась декоративной.
      final videoControlsTheme = MaterialVideoControlsThemeData(
        seekBarMargin: const EdgeInsets.only(left: 16, right: 16, bottom: 50),
        bottomButtonBarMargin: const EdgeInsets.only(
          left: 16,
          right: 8,
          bottom: 50,
        ),
        seekBarContainerHeight: 36,
        buttonBarHeight: 56,
        displaySeekBar: allowSeek,
        seekGesture: allowSeek,
        seekOnDoubleTap: allowSeek,
      );
      Widget videoWidget = showControls
          ? MaterialVideoControlsTheme(
              normal: videoControlsTheme,
              fullscreen: videoControlsTheme,
              child: Video(
                controller: _controller!,
                controls: MaterialVideoControls,
                fit: videoFit,
              ),
            )
          : Video(controller: _controller!, fit: videoFit);

      content = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              videoWidget,
              if (!(item.videoAutoplay ?? true) && !_isPlaying)
                _buildPosterOverlay(borderRadius),
              // tap to play/pause when controls hidden
              if (!showControls)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      if (_player == null) return;
                      if (_isPlaying) {
                        _player!.pause();
                      } else {
                        _player!.play();
                      }
                    },
                    child: Container(color: Colors.transparent),
                  ),
                ),
            ],
          ),
        ),
      );

      // Fullscreen button when hidden controls but allowed
      if (!showControls && allowFullscreen) {
        content = Stack(
          children: [
            content,
            Positioned(
              right: 8,
              bottom: 8,
              child: IconButton(
                icon: const Icon(Icons.fullscreen, color: Colors.white),
                style: IconButton.styleFrom(backgroundColor: Colors.black45),
                onPressed: () async {
                  // media_kit fullscreen via enter fullscreen? simple use dialog
                  if (_controller == null) return;
                  final ctx = context;
                  await showDialog(
                    context: ctx,
                    barrierColor: Colors.black,
                    builder: (_) => Dialog.fullscreen(
                      backgroundColor: Colors.black,
                      child: MaterialVideoControlsTheme(
                        normal: videoControlsTheme,
                        fullscreen: videoControlsTheme,
                        child: Stack(
                          children: [
                            Video(
                              controller: _controller!,
                              controls: MaterialVideoControls,
                            ),
                            Positioned(
                              top: 16,
                              right: 16,
                              child: IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                ),
                                onPressed: () => Navigator.pop(ctx),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      }
    }

    // Interaction wrapper: if item has targetNodeId / behaviours, make tappable
    final hasInteraction =
        TriggerPipeline.itemHasInteraction(item) ||
        (item.targetNodeId != null && item.targetNodeId!.isNotEmpty);
    if (hasInteraction) {
      content = InkWell(
        onTap: () => widget.onInteract(item),
        borderRadius: BorderRadius.circular(borderRadius),
        child: content,
      );
    }

    // Block progress indicator - overlay at bottom to avoid RenderFlex overflow on small videos
    if (item.videoBlockProgress ?? false) {
      content = Stack(
        children: [
          Padding(
            // reserve 4px at bottom for progress so it doesn't cover controls
            padding: const EdgeInsets.only(bottom: 4),
            child: content,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(borderRadius),
                bottomRight: Radius.circular(borderRadius),
              ),
              child: LinearProgressIndicator(
                value: _duration.inMilliseconds > 0
                    ? (_position.inMilliseconds / _duration.inMilliseconds)
                          .clamp(0.0, 1.0)
                    : null,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFF26C6DA),
                ),
                minHeight: 4,
              ),
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: content,
    );
  }

  Widget _buildPosterOrLoader(double radius) {
    if (_poster != null && _poster!.isNotEmpty) {
      return FutureBuilder<File?>(
        // Постер — тот же источник, что и у картинки: путь, имя из библиотеки
        // или uuid.
        future: QuestImageSource.resolve(widget.questId, _poster),
        builder: (context, snap) {
          final file = snap.data;
          if (file != null) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.file(file, fit: BoxFit.cover),
              ),
            );
          }
          return _buildLoader(radius);
        },
      );
    }
    return _buildLoader(radius);
  }

  Widget _buildLoader(double radius) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black26,
          child: const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }

  Widget _buildPosterOverlay(double radius) {
    if (_poster == null || _poster!.isEmpty) {
      return Container(
        color: Colors.black38,
        child: const Center(
          child: Icon(Icons.play_circle_fill, size: 64, color: Colors.white70),
        ),
      );
    }
    return FutureBuilder<File?>(
      future: QuestImageSource.resolve(widget.questId, _poster),
      builder: (context, snap) {
        final file = snap.data;
        Widget posterWidget = Container(color: Colors.black38);
        if (file != null) {
          posterWidget = Image.file(file, fit: BoxFit.cover);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              posterWidget,
              Container(color: Colors.black38),
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  size: 64,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildError() {
    final hint =
        Platform.isLinux &&
            (_errorMsg?.contains('mpv') ??
                false || _errorMsg == 'Файл не найден: ')
        ? 'На Linux установите mpv: sudo pacman -S mpv libepoxy'
        : null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.videocam_off, color: Colors.redAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _errorMsg ?? 'Ошибка видео',
                  style: const TextStyle(color: Colors.white70),
                ),
                if (hint != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    hint,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildYoutubePlaceholder() {
    final url = widget.item.videoUrl ?? '';
    final thumb = _youtubeThumb(url);
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        resolveItemNumeric(
          ref,
          widget.item,
          'borderRadius',
          widget.questId,
          staticValue: widget.item.borderRadius ?? 12.0,
        ).clamp(0.0, 999.0),
      ),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumb != null)
              Image.network(
                thumb,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(color: Colors.black26),
              ),
            if (thumb == null) Container(color: Colors.black26),
            Container(color: Colors.black38),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.play_circle_fill,
                    size: 64,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'YouTube видео',
                    style: TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () async {
                      final uri = Uri.tryParse(url);
                      if (uri != null)
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                    },
                    child: const Text('Открыть'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _youtubeThumb(String url) {
    try {
      final uri = Uri.parse(url);
      String? vid;
      if (uri.host.contains('youtu.be')) {
        vid = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
      } else if (uri.host.contains('youtube.com')) {
        vid = uri.queryParameters['v'];
        if (vid == null &&
            uri.pathSegments.contains('shorts') &&
            uri.pathSegments.length >= 2) {
          vid = uri.pathSegments[1];
        }
        if (vid == null && uri.pathSegments.isNotEmpty) {
          // embed
          vid = uri.pathSegments.last;
        }
      }
      if (vid != null && vid.isNotEmpty) {
        return 'https://img.youtube.com/vi/$vid/hqdefault.jpg';
      }
    } catch (_) {}
    return null;
  }
}
