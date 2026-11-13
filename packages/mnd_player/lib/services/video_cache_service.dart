import 'dart:async';
import 'package:media_kit/media_kit.dart';

/// Простой кэш плееров: повторное появление того же видео не грузит файл
/// заново./// Держит до трёх плееров и ещё 5 минут после того, как виджет отпустил последний.
class VideoCacheService {
  static final Map<String, Player> _players = {};
  static final Map<String, DateTime> _lastUsed = {};
  static final Map<String, Timer> _timers = {};

  /// Сколько виджетов сейчас висит на плеере. Закрывать можно только дошедший
  /// до нуля: `dispose()` у attached-плеера гасит картинку у того, кто её
  /// прямо сейчас смотрит, — видео становится чёрным кадром до ревизита ноды.
  static final Map<String, int> _attached = {};
  static const int _maxSize = 3;
  static const Duration _expire = Duration(minutes: 5);

  static Player? get(String key) {
    final p = _players[key];
    if (p == null) return null;
    _lastUsed[key] = DateTime.now();
    _attached[key] = (_attached[key] ?? 0) + 1;
    // cancel pending dispose
    _timers[key]?.cancel();
    _timers.remove(key);
    return p;
  }

  static void put(String key, Player player) {
    _attached[key] = (_attached[key] ?? 0) + 1;
    // evict oldest if over limit
    if (_players.length >= _maxSize && !_players.containsKey(key)) {
      final live = _players.keys.where((k) => (_attached[k] ?? 0) == 0);
      // Все три заняты — значит в кэше живут именно те видео, что на экране.
      // Резать их нельзя, так что временно терпим превышение лимита.
      if (live.isNotEmpty) {
        final oldest = live.reduce(
          (a, b) => _lastUsed[a]!.isBefore(_lastUsed[b]!) ? a : b,
        );
        _players[oldest]?.dispose();
        _players.remove(oldest);
        _lastUsed.remove(oldest);
        _attached.remove(oldest);
        _timers[oldest]?.cancel();
        _timers.remove(oldest);
      }
    }
    _players[key] = player;
    _lastUsed[key] = DateTime.now();
    _timers[key]?.cancel();
    _timers.remove(key);
  }

  static void release(String key) {
    final left = (_attached[key] ?? 1) - 1;
    _attached[key] = left < 0 ? 0 : left;
    _lastUsed[key] = DateTime.now();
    if (_attached[key]! > 0) return;
    _timers[key]?.cancel();
    _timers[key] = Timer(_expire, () {
      final last = _lastUsed[key];
      if (last != null &&
          (_attached[key] ?? 0) == 0 &&
          DateTime.now().difference(last) >= _expire) {
        _players[key]?.dispose();
        _players.remove(key);
        _lastUsed.remove(key);
        _attached.remove(key);
        _timers.remove(key);
      }
    });
  }

  static void clear() {
    for (final p in _players.values) {
      p.dispose();
    }
    _players.clear();
    _lastUsed.clear();
    _attached.clear();
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}
