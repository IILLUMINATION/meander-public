import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

class BoundedImageProvider extends ImageProvider<BoundedImageProviderKey> {
  const BoundedImageProvider(this.imageProvider, {required this.maxSide})
    : assert(maxSide > 0);

  final ImageProvider<Object> imageProvider;
  final int maxSide;

  @override
  Future<BoundedImageProviderKey> obtainKey(ImageConfiguration configuration) {
    Completer<BoundedImageProviderKey>? completer;
    SynchronousFuture<BoundedImageProviderKey>? result;
    imageProvider
        .obtainKey(configuration)
        .then(
          (Object key) {
            final boundedKey = BoundedImageProviderKey(key, maxSide);
            if (completer == null) {
              result = SynchronousFuture<BoundedImageProviderKey>(boundedKey);
            } else {
              completer.complete(boundedKey);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            completer?.completeError(error, stackTrace);
          },
        );
    if (result != null) return result!;
    completer = Completer<BoundedImageProviderKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(
    BoundedImageProviderKey key,
    ImageDecoderCallback decode,
  ) {
    final completer = imageProvider.loadImage(key.providerKey, (
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(
        getTargetSize == null,
        'BoundedImageProvider cannot be composed with another ImageProvider '
        'that applies getTargetSize.',
      );
      return decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final scale = math.min(
            1.0,
            math.min(maxSide / intrinsicWidth, maxSide / intrinsicHeight),
          );
          return ui.TargetImageSize(
            width: (intrinsicWidth * scale).round().clamp(1, maxSide),
            height: (intrinsicHeight * scale).round().clamp(1, maxSide),
          );
        },
      );
    });
    completer.addEphemeralErrorListener((
      Object exception,
      StackTrace? stackTrace,
    ) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is BoundedImageProvider &&
            imageProvider == other.imageProvider &&
            maxSide == other.maxSide;
  }

  @override
  int get hashCode => Object.hash(imageProvider, maxSide);
}

class BoundedImageProviderKey {
  const BoundedImageProviderKey(this.providerKey, this.maxSide);

  final Object providerKey;
  final int maxSide;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is BoundedImageProviderKey &&
            providerKey == other.providerKey &&
            maxSide == other.maxSide;
  }

  @override
  int get hashCode => Object.hash(providerKey, maxSide);
}
