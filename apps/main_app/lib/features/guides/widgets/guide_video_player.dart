import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'package:canvas_app/core/l10n/l10n.dart';

/// Видео гайда из бандла. media_kit не читает `asset://`, поэтому файл один
/// раз копируется во временный каталог и открывается как обычный локальный
/// файл. Сеть не нужна, после первого показа работает и без интернета.
///
/// Плеер создаётся только по нажатию «Смотреть»: экран гайда не тянет
/// нативные библиотеки, пока видео действительно не понадобилось.
class GuideVideoPlayer extends StatefulWidget {
  final String assetPath;
  final String? posterAsset;

  const GuideVideoPlayer({
    super.key,
    required this.assetPath,
    this.posterAsset,
  });

  @override
  State<GuideVideoPlayer> createState() => _GuideVideoPlayerState();
}

class _GuideVideoPlayerState extends State<GuideVideoPlayer> {
  Player? _player;
  VideoController? _controller;

  bool _starting = false;
  bool _started = false;
  String? _error;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  bool _hasLinuxMpv() {
    if (!Platform.isLinux) return true;
    const candidates = [
      '/usr/lib/libmpv.so',
      '/usr/lib/libmpv.so.2',
      '/usr/lib/libmpv.so.1',
      '/usr/lib64/libmpv.so',
      '/usr/lib64/libmpv.so.2',
      '/usr/lib/x86_64-linux-gnu/libmpv.so.1',
      '/usr/lib/x86_64-linux-gnu/libmpv.so',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return true;
    }
    return false;
  }

  Future<File> _localCopy() async {
    final temp = await getTemporaryDirectory();
    final dir = Directory('${temp.path}/mnd_guides');
    if (!await dir.exists()) await dir.create(recursive: true);

    final safeName = widget.assetPath.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File('${dir.path}/$safeName');
    if (await file.exists() && await file.length() > 0) return file;

    final data = await rootBundle.load(widget.assetPath);
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return file;
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });

    Player? player;
    try {
      if (!_hasLinuxMpv()) {
        throw const _VideoUnavailable();
      }
      final file = await _localCopy();
      MediaKit.ensureInitialized();
      player = Player(
        configuration: const PlayerConfiguration(title: 'Meander guide'),
      );
      final controller = VideoController(player);
      _player = player;
      _controller = controller;
      player.stream.error.listen((message) {
        if (!mounted || message.isEmpty) return;
        setState(() {
          _error = tr('Видео недоступно на этом устройстве');
          _started = false;
        });
      });
      await player.open(Media(file.uri.toString()), play: true);
      if (!mounted) return;
      setState(() {
        _starting = false;
        _started = true;
      });
    } on _VideoUnavailable {
      await player?.dispose();
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = tr('Видео недоступно на этом устройстве');
      });
    } catch (_) {
      await player?.dispose();
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = tr('Видео недоступно на этом устройстве');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: _started && _controller != null
              ? Video(controller: _controller!)
              : _buildCover(scheme),
        ),
      ),
    );
  }

  Widget _buildCover(ColorScheme scheme) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.posterAsset != null)
          Image.asset(
            widget.posterAsset!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x22000000), Color(0xCC000000)],
            ),
          ),
        ),
        Positioned(
          left: 12,
          top: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.offline_bolt_rounded,
                  size: 14,
                  color: Colors.white,
                ),
                const SizedBox(width: 5),
                Text(
                  tr('Офлайн'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: _starting ? null : _start,
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                icon: _starting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(tr('Смотреть')),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _VideoUnavailable implements Exception {
  const _VideoUnavailable();
}
