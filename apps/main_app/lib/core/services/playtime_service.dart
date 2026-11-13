import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final playtimeServiceProvider = Provider((ref) => PlaytimeService(ref));

/// Часы этого устройства. Настоящий учёт ведёт сервер (туда доезжает всё
/// синхизированное с любого устройства), а эти значения — подстраховка для
/// случая, когда сервер ещё ничего не знает: свежий аккаунт или офлайн.
/// Профиль, который берёт только их, на втором компьютере выглядит как
/// «ни разу не играл».
///
/// Провайдеры не autoDispose: счётчик меняется раз в 10 секунд, и вешать на
/// каждое перерисовывание профиля новый Future смысла нет.
final localAppPlaytimeProvider = FutureProvider<int>(
  (ref) => ref.watch(playtimeServiceProvider).getTotalAppPlaytime(),
);

final localQuestPlaytimeProvider = FutureProvider<int>(
  (ref) => ref.watch(playtimeServiceProvider).getTotalQuestsPlaytime(),
);

class PlaytimeService with WidgetsBindingObserver {
  static const String _kTotalAppTime = 'total_app_time_seconds';
  static const String _kQuestTimePrefix = 'quest_playtime_';
  static const String _kUnsyncedTotalTime = 'unsynced_total_app_time';
  static const String _kUnsyncedQuestTimes = 'unsynced_quest_times';

  final Ref ref;
  Timer? _trackingTimer;
  Timer? _syncTimer;
  DateTime? _lastTickTime;
  DateTime? _lastInteractionTime;
  String? _activeQuestId;
  bool _isAppActive = true;
  bool _isSyncing = false;

  PlaytimeService(this.ref);

  void init() {
    WidgetsBinding.instance.addObserver(this);
    _lastInteractionTime = DateTime.now();
    _startTracking();
    _startSyncTimer();
  }

  void registerInteraction() {
    _lastInteractionTime = DateTime.now();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trackingTimer?.cancel();
    _syncTimer?.cancel();
  }

  void setActiveQuest(String? questId) {
    _activeQuestId = questId;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isAppActive = true;
      _lastTickTime = DateTime.now();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      _isAppActive = false;
      _tickPlaytime(); // Save immediately on pause
    }
  }

  void _startTracking() {
    _lastTickTime = DateTime.now();
    // Раз в 30 секунд, а не раз в 10: каждый тик — это 3-4 записи в
    // SharedPreferences (то есть в файл) на eMMC, и на слабом устройстве этот
    // ровный фоновый I/O мешает кадрам. Точность не страдает: при уходе в фон
    // остаток дописывается тем же `_tickPlaytime` из lifecycle-хука.
    _trackingTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      // Allow max 5 minutes of AFK tracking
      final isAfk = _lastInteractionTime != null && 
                    DateTime.now().difference(_lastInteractionTime!).inMinutes >= 5;
                    
      if (_isAppActive && !isAfk) {
        _tickPlaytime();
      } else {
        // If we're AFK but still ticking, we need to reset lastTickTime 
        // so we don't calculate a huge chunk when they come back.
        _lastTickTime = DateTime.now();
      }
    });
  }

  Future<void> _tickPlaytime() async {
    if (_lastTickTime == null) return;
    
    final now = DateTime.now();
    final deltaSeconds = now.difference(_lastTickTime!).inSeconds;
    _lastTickTime = now;

    if (deltaSeconds <= 0 || deltaSeconds > 300) return; // Ignore large jumps (e.g. time changes)

    final prefs = await SharedPreferences.getInstance();

    // 1. Update total app time
    final currentAppTime = prefs.getInt(_kTotalAppTime) ?? 0;
    await prefs.setInt(_kTotalAppTime, currentAppTime + deltaSeconds);
    
    final unsyncedAppTime = prefs.getInt(_kUnsyncedTotalTime) ?? 0;
    await prefs.setInt(_kUnsyncedTotalTime, unsyncedAppTime + deltaSeconds);

    // 2. Update active quest time
    if (_activeQuestId != null) {
      final qKey = '$_kQuestTimePrefix$_activeQuestId';
      final currentQuestTime = prefs.getInt(qKey) ?? 0;
      await prefs.setInt(qKey, currentQuestTime + deltaSeconds);

      final unsyncedQuestJson = prefs.getString(_kUnsyncedQuestTimes) ?? '{}';
      final unsyncedQuestMap = Map<String, dynamic>.from(jsonDecode(unsyncedQuestJson));
      final qUnsynced = (unsyncedQuestMap[_activeQuestId] as int?) ?? 0;
      unsyncedQuestMap[_activeQuestId!] = qUnsynced + deltaSeconds;
      await prefs.setString(_kUnsyncedQuestTimes, jsonEncode(unsyncedQuestMap));
    }
  }

  void _startSyncTimer() {
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      syncWithBackend();
    });
  }

  Future<void> syncWithBackend() async {
    if (_isSyncing) return;

    final prefs = await SharedPreferences.getInstance();
    
    final unsyncedAppTime = prefs.getInt(_kUnsyncedTotalTime) ?? 0;
    final unsyncedQuestJson = prefs.getString(_kUnsyncedQuestTimes) ?? '{}';
    final unsyncedQuestMap = Map<String, dynamic>.from(jsonDecode(unsyncedQuestJson));
    
    if (unsyncedAppTime == 0 && unsyncedQuestMap.isEmpty) return;

    _isSyncing = true;
    try {
      final api = ref.read(apiServiceProvider);
      await api.post('profiles/playtime-sync', body: {
        'total_app_time': unsyncedAppTime,
        'quest_times': unsyncedQuestMap,
      });

      // Clear ONLY the amount we synced, to avoid race conditions with ongoing tracking
      final currentAppTime = prefs.getInt(_kUnsyncedTotalTime) ?? 0;
      await prefs.setInt(_kUnsyncedTotalTime, (currentAppTime - unsyncedAppTime).clamp(0, double.maxFinite).toInt());
      
      final currentQuestJson = prefs.getString(_kUnsyncedQuestTimes) ?? '{}';
      final currentQuestMap = Map<String, dynamic>.from(jsonDecode(currentQuestJson));
      for (final key in unsyncedQuestMap.keys) {
        final current = (currentQuestMap[key] as int?) ?? 0;
        final synced = (unsyncedQuestMap[key] as int?) ?? 0;
        final remaining = current - synced;
        if (remaining <= 0) {
          currentQuestMap.remove(key);
        } else {
          currentQuestMap[key] = remaining;
        }
      }
      await prefs.setString(_kUnsyncedQuestTimes, jsonEncode(currentQuestMap));
    } catch (e) {
      debugPrint('Failed to sync playtime: $e');
    } finally {
      _isSyncing = false;
    }
  }

  Future<int> getQuestPlaytime(String questId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_kQuestTimePrefix$questId') ?? 0;
  }

  Future<int> getTotalAppPlaytime() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kTotalAppTime) ?? 0;
  }

  Future<int> getTotalQuestsPlaytime() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_kQuestTimePrefix));
    int total = 0;
    for (final key in keys) {
      total += prefs.getInt(key) ?? 0;
    }
    return total;
  }
}
