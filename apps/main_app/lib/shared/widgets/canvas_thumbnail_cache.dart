import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mnd_player/utils/quest_image_source.dart';

/// Миниатюры карточек канваса: источник ресурса → декодированная картинка.
///
/// Художник канваса синхронный, поэтому картинки грузятся заранее и живут в
/// этом кэше. Пока картинки нет, карточка рисуется как раньше — без подложки.
/// Кэш ограничен: на большом квесте держать все фоны в памяти нельзя.
class CanvasThumbnailCache extends ChangeNotifier {
  CanvasThumbnailCache({
    this.maxEntries = 64,
    Future<String?> Function(String questId, String source)? resolver,
  }) : _resolve = resolver ?? QuestImageSource.resolveOnDisk;

  /// Сколько миниатюр держим расшифрованными одновременно.
  final int maxEntries;

  final Future<String?> Function(String questId, String source) _resolve;

  final Map<String, ui.Image> _images = <String, ui.Image>{};
  final Set<String> _pending = <String>{};
  final Set<String> _missing = <String>{};

  /// Декодированная картинка для источника, если уже загружена.
  ui.Image? imageFor(String? source) =>
      source == null ? null : _images[source];

  /// Запросить загрузку. Повторные вызовы на кадр бесплатны: источник либо
  /// уже в кэше, либо ждёт загрузки, либо помечен отсутствующим.
  void ensure(String questId, String? source) {
    if (source == null || source.isEmpty) return;
    if (_images.containsKey(source) ||
        _pending.contains(source) ||
        _missing.contains(source)) {
      return;
    }
    _pending.add(source);
    unawaited(_load(questId, source));
  }

  Future<void> _load(String questId, String source) async {
    try {
      final path = await _resolve(questId, source);
      if (path == null || path.isEmpty) {
        // Файла нет: повторные кадры не должны снова стучаться в ФС.
        _missing.add(source);
        return;
      }
      final bytes = await File(path).readAsBytes();
      // Миниатюра нужна размером с карточку в 2×, а не в исходном разрешении:
      // фон квеста бывает 1920 px, и держать его в памяти на ноду незачем.
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 480);
      final frame = await codec.getNextFrame();
      codec.dispose();
      _put(source, frame.image);
    } catch (_) {
      _missing.add(source);
    } finally {
      _pending.remove(source);
    }
  }

  void _put(String source, ui.Image image) {
    if (_images.length >= maxEntries) {
      final oldest = _images.keys.first;
      _images.remove(oldest)?.dispose();
    }
    _images[source] = image;
    notifyListeners();
  }

  /// Забыть всё: контент квеста изменился или ресурс переименован.
  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _pending.clear();
    _missing.clear();
  }

  @override
  void dispose() {
    clear();
    super.dispose();
  }
}