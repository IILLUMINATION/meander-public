import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mnd_core/utils/bounded_image_provider.dart';
import 'package:mnd_player/utils/quest_image_source.dart';

class QuestInlineImage extends StatefulWidget {
  static double sideForStyle(TextStyle style) {
    final raw = (style.fontSize ?? 16.0) * (style.height ?? 1.2);
    return raw.isFinite ? raw.clamp(1.0, 1024.0) : 19.2;
  }

  final String questId;
  final String path;
  final TextStyle style;
  final bool outlineOnly;

  const QuestInlineImage({
    super.key,
    required this.questId,
    required this.path,
    this.style = const TextStyle(),
    this.outlineOnly = false,
  });

  @override
  State<QuestInlineImage> createState() => _QuestInlineImageState();
}

class _QuestInlineImageState extends State<QuestInlineImage> {
  String? _futureKey;
  int _resolverGeneration = -1;
  int _cachedGeneration = -1;
  File? _cachedFile;
  Future<File?>? _fileFuture;

  @override
  void didUpdateWidget(covariant QuestInlineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.questId != widget.questId || oldWidget.path != widget.path) {
      _futureKey = null;
      _fileFuture = null;
      _cachedFile = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final inherited = context
        .dependOnInheritedWidgetOfExactType<DefaultTextStyle>()
        ?.style;
    final style = (inherited ?? const TextStyle()).merge(widget.style);
    final side = QuestInlineImage.sideForStyle(style);

    Widget child;
    if (widget.outlineOnly) {
      child = const SizedBox.expand();
    } else {
      final key = '${widget.questId}|${widget.path}';
      if (_futureKey != key ||
          _resolverGeneration != QuestImageSource.generation) {
        final cached = QuestImageSource.cachedFile(widget.questId, widget.path);
        _futureKey = key;
        _resolverGeneration = QuestImageSource.generation;
        _cachedFile = cached?.file;
        _cachedGeneration = cached?.generation ?? _resolverGeneration;
        _fileFuture = QuestImageSource.resolve(widget.questId, widget.path);
      }
      child = FutureBuilder<File?>(
        future: _fileFuture,
        builder: (context, snapshot) {
          final done = snapshot.connectionState == ConnectionState.done;
          final file = done ? snapshot.data : _cachedFile;
          if (file == null) {
            return done ? _missing(style, side) : const SizedBox.expand();
          }
          final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1;
          final ratio = pixelRatio.isFinite && pixelRatio > 0
              ? pixelRatio
              : 1.0;
          final cacheSide = (side * ratio).round().clamp(1, 2048);
          return Image(
            image: BoundedImageProvider(
              _VersionedFileImage(
                file,
                generation: done ? _resolverGeneration : _cachedGeneration,
              ),
              maxSide: cacheSide,
            ),
            width: side,
            height: side,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) => _missing(style, side),
          );
        },
      );
    }

    return ExcludeSemantics(
      excluding: widget.outlineOnly,
      child: SizedBox.square(dimension: side, child: child),
    );
  }

  Widget _missing(TextStyle style, double side) => Icon(
    Icons.broken_image_outlined,
    size: side,
    color: style.color ?? Colors.white,
  );
}

class _VersionedFileImage extends FileImage {
  const _VersionedFileImage(super.file, {required this.generation});

  final int generation;

  @override
  bool operator ==(Object other) {
    return other.runtimeType == runtimeType &&
        other is _VersionedFileImage &&
        other.file.path == file.path &&
        other.scale == scale &&
        other.generation == generation;
  }

  @override
  int get hashCode => Object.hash(file.path, scale, generation);
}
