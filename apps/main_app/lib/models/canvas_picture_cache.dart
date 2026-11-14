import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:canvas_app/models/canvas_models.dart';

/// Кеш отрисовки нод: каждый элемент рисуется в `ui.Picture` один раз.
///
/// Кадр канваса раньше заново считал геометрию, тон, чипы и текст каждой
/// видимой ноды — 184 мс на кадр при 600 нодах, 123 мс на одной ноде с
/// timer/script-рёбрами. Пикчер — это записанный список команд: пока нода
/// не менялась, кадр сводится к `canvas.drawPicture`, а вся работа с текстом
/// и раскладкой остаётся в прошлом.
///
/// Запись идёт в мировых координатах, поэтому масштаб не важен: канвас
/// холста применяет трансформацию сам, а текст в пикче остаётся векторным и
/// растеризуется на финальном масштабе.
class CanvasNodePictureCache {
  CanvasNodePictureCache({this.maxEntries = 2000});

  /// Сколько нод держим в памяти. Лента канваса редко выходит за сотни, но
  /// при прокрутке больших квестов кеш растёт — старые вытесняем.
  final int maxEntries;

  final Map<String, _NodeFrames> _frames = <String, _NodeFrames>{};
  int _themeRevision = -1;

  /// Номер кадра: по нему считаем, сколько кадров нода не появлялась.
  int _frame = 0;

  int get length => _frames.length;

  /// Тело карточки для ноды [id] с подписью [signature].
  ///
  /// [record] вызывается только когда пикчи нет или подпись изменилась.
  ui.Picture body(String id, int signature, void Function(Canvas) record) =>
      _picture(id, signature, record, title: false);

  /// Подпись ноды — отдельный проход: она рисуется поверх всех тел.
  ui.Picture title(String id, int signature, void Function(Canvas) record) =>
      _picture(id, signature, record, title: true);

  ui.Picture _picture(
    String id,
    int signature,
    void Function(Canvas) record, {
    required bool title,
  }) {
    _syncTheme();
    final frames = _frames.putIfAbsent(id, _NodeFrames.new);
    frames.lastFrame = _frame;

    final cachedSignature = title
        ? frames.titleSignature
        : frames.bodySignature;
    final cached = title ? frames.title : frames.body;
    if (cached != null && cachedSignature == signature) return cached;

    final recorder = ui.PictureRecorder();
    record(Canvas(recorder));
    final picture = recorder.endRecording();
    if (title) {
      frames.title?.dispose();
      frames.title = picture;
      frames.titleSignature = signature;
    } else {
      frames.body?.dispose();
      frames.body = picture;
      frames.bodySignature = signature;
    }
    return picture;
  }

  /// Выкидывает ноды, которых давно не было в кадре.
  ///
  /// Вызывается один раз за кадр. Пикчи освобождаются явно: `ui.Picture`
  /// держит нативную память, и сборщик мусора её не торопится отдавать.
  void retainOnly(Set<String> alive) {
    _frame++;
    if (_frames.length <= maxEntries) {
      _frames.removeWhere((id, frames) {
        if (alive.contains(id)) return false;
        // Пару кадров держим и выпавшие ноды: один шаг прокрутки не должен
        // заставлять записывать их заново.
        return _frame - frames.lastFrame > 2;
      });
      return;
    }
    final ordered = _frames.entries.toList()
      ..sort((a, b) => b.value.lastFrame.compareTo(a.value.lastFrame));
    final dropped = <String>{};
    for (var i = maxEntries; i < ordered.length; i++) {
      dropped.add(ordered[i].key);
    }
    for (final id in dropped) {
      _frames.remove(id)?.dispose();
    }
  }

  /// Тема сменилась — цвета в пикчах старые.
  void _syncTheme() {
    if (_themeRevision == CanvasTheme.revision) return;
    _themeRevision = CanvasTheme.revision;
    clear();
  }

  void clear() {
    for (final frames in _frames.values) {
      frames.dispose();
    }
    _frames.clear();
  }
}

class _NodeFrames {
  ui.Picture? body;
  int bodySignature = 0;
  ui.Picture? title;
  int titleSignature = 0;
  int lastFrame = 0;

  void dispose() {
    body?.dispose();
    title?.dispose();
    body = null;
    title = null;
  }
}
