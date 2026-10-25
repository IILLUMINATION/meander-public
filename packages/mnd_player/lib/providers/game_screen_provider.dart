import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:uuid/uuid.dart';

import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:mnd_player/providers/audio_volume_provider.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/providers/quest_provider.dart';
import 'package:mnd_player/services/font_service.dart';
import 'package:mnd_player/plugin/plugin_packages.dart';
import 'package:mnd_player/plugin/plugin_runtime.dart';
import 'package:mnd_player/services/save_game_provider.dart';
import 'package:mnd_core/utils/quest_paths.dart';

// ---------------------------------------------------------------------------
// Ключ игровой сессии: questId + идентификатор документа/вкладки.
// Один квест можно открыть в нескольких вкладках (симуляция, сейв-слот) —
// каждая получает независимый движок.
// ---------------------------------------------------------------------------

typedef GameSessionKey = ({String questId, String docKey});

// ---------------------------------------------------------------------------
// Хуки для main_app-специфичных зависимостей
// ---------------------------------------------------------------------------

/// Опциональные коллбеки, позволяющие `main_app` подключить свои сервисы
/// (crash-логи, watchdog, live-reload редактора, safety-аудит), не требуя их
/// в standalone-сборке `mnd_player`. Инжекция через
/// [gameScreenHooksProvider] (main_app переопределяет его в ProviderScope).
class GameScreenHooks {
  /// Вызывается при входе в ключевые этапы (аналог `HangWatchdog.mark`).
  final void Function(String step)? onStep;

  /// Вызывается при ошибке для логирования (аналог `CrashLogService.handle`).
  final void Function(Object error, StackTrace? stack, String context)? onError;

  /// Подписаться на изменения контента квеста (live-reload редактора).
  /// Передаётся коллбек — вызывается при изменении файлов на диске.
  final void Function(String questId, void Function() onChanged)?
  listenContentChanges;

  /// Отписаться от изменений контента.
  final void Function(String questId, void Function() onChanged)?
  unlistenContentChanges;

  /// Проверить URL на безопасность перед запуском квеста / открытием
  /// внешней ссылки (`open_link`). Возвращает false если URL запрещён.
  final bool Function(String url)? isUrlSafe;

  /// Сессия игры началась (после успешного старта).
  final void Function(String questId)? onGameSessionStarted;

  /// Сессия игры завершена (экран уничтожен).
  final void Function(String questId)? onGameSessionEnded;

  /// Каталоги активных плагинов (каждый с `plugin.json` + точкой входа из
  /// манифеста). main_app отдаёт их из своего реестра установленных плагинов,
  /// standalone-сборка — из каталога `<документы>/plugins/`. `null` или пустой
  /// список — плагинов нет, и хост вообще не дёргается.
  final Future<List<String>> Function()? listPluginPackages;

  const GameScreenHooks({
    this.onStep,
    this.onError,
    this.listenContentChanges,
    this.unlistenContentChanges,
    this.isUrlSafe,
    this.onGameSessionStarted,
    this.onGameSessionEnded,
    this.listPluginPackages,
  });

  /// Пустые хуки для standalone-сборки.
  static const empty = GameScreenHooks();
}

// ---------------------------------------------------------------------------
// Countdown (отдельный провайдер, чтобы тик 100 мс не пересобирал экран)
// ---------------------------------------------------------------------------

@immutable
class GameCountdownData {
  final double remainingSeconds;
  final double totalSeconds;

  const GameCountdownData({
    required this.remainingSeconds,
    required this.totalSeconds,
  });
}

class GameCountdownNotifier extends StateNotifier<GameCountdownData?> {
  GameCountdownNotifier() : super(null);

  void start(double total) {
    state = GameCountdownData(remainingSeconds: total, totalSeconds: total);
  }

  void tick(double remaining) {
    final current = state;
    if (current == null) return;
    state = GameCountdownData(
      remainingSeconds: remaining,
      totalSeconds: current.totalSeconds,
    );
  }

  void stop() => state = null;
}

/// Обратный отсчёт текущей ноды. Ключ — идентификатор игровой сессии
/// ([GameScreenNotifier.sessionKey]), чтобы разные вкладки одного квеста
/// имели независимые таймеры. Тикает каждые 100 мс — слушается только
/// виджетом таймера, а не всем экраном.
final gameCountdownProvider = StateNotifierProvider.autoDispose
    .family<GameCountdownNotifier, GameCountdownData?, String>((ref, key) {
      return GameCountdownNotifier();
    });

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@immutable
class GameScreenState {
  final bool isLoading;
  final String? error;
  final SavedNode? currentNode;
  final List<ContentItem> revealedItems;

  /// Закреплённые стеки текущей ноды (`stackPin` ≠ null). Движок отдаёт их в
  /// общем потоке раскрытия, но рисует не в списке контента, а слоем поверх
  /// прокрутки — поэтому они не попадают в [revealedItems].
  final List<ContentItem> pinnedStacks;

  /// Закреплённые слои, которые игрок закрыл тапом вне рамки. Живут до новой
  /// сцены: скрипт обязать нельзя, а игрок окно закрыть вправе.
  final Set<String> dismissedStacks;
  final String? backgroundImagePath;
  final String? backgroundVideoPath;
  final String presentationId;
  final String? fontFamily;

  /// Поколение ре-ривила: инкрементится при каждом сбросе revealedItems.
  final int revealEpoch;

  const GameScreenState({
    this.isLoading = true,
    this.error,
    this.currentNode,
    this.revealedItems = const [],
    this.pinnedStacks = const [],
    this.dismissedStacks = const {},
    this.backgroundImagePath,
    this.backgroundVideoPath,
    this.presentationId = '',
    this.fontFamily,
    this.revealEpoch = 0,
  });

  GameScreenState copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    SavedNode? currentNode,
    bool clearCurrentNode = false,
    List<ContentItem>? revealedItems,
    List<ContentItem>? pinnedStacks,
    Set<String>? dismissedStacks,
    String? backgroundImagePath,
    bool clearBackgroundImage = false,
    String? backgroundVideoPath,
    bool clearBackgroundVideo = false,
    String? presentationId,
    String? fontFamily,
    int? revealEpoch,
  }) {
    return GameScreenState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
      currentNode: clearCurrentNode ? null : (currentNode ?? this.currentNode),
      revealedItems: revealedItems ?? this.revealedItems,
      pinnedStacks: pinnedStacks ?? this.pinnedStacks,
      dismissedStacks: dismissedStacks ?? this.dismissedStacks,
      backgroundImagePath: clearBackgroundImage
          ? null
          : backgroundImagePath ?? this.backgroundImagePath,
      backgroundVideoPath: clearBackgroundVideo
          ? null
          : backgroundVideoPath ?? this.backgroundVideoPath,
      presentationId: presentationId ?? this.presentationId,
      fontFamily: fontFamily ?? this.fontFamily,
      revealEpoch: revealEpoch ?? this.revealEpoch,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class GameScreenNotifier extends StateNotifier<GameScreenState> {
  final Ref _ref;
  final String _questId;
  final GameScreenHooks _hooks;

  /// Идентификатор игровой сессии для провайдеров, ключуемых по сессии
  /// (countdown). По умолчанию равен questId (standalone-сборка);
  /// main_app передаёт `questId::docKey`, чтобы вкладки не конфликтовали.
  final String sessionKey;

  final AudioPlayer _backgroundAudioPlayer = AudioPlayer();
  final AudioPlayer _soundEffectPlayer = AudioPlayer();
  StreamSubscription<PlayerState>? _backgroundPlayerStateSub;
  StreamSubscription<PlayerState>? _soundEffectPlayerStateSub;
  ProviderSubscription<GameState>? _gameStateSub;
  String? _currentBackgroundAudioId;

  /// Громкость самого трека (ноды или `play_music`), без множителей. Держим,
  /// чтобы `_applyBackgroundVolumeFromState` пересчитывал громкость того, что
  /// сейчас играет, а не разворачивал её в 1.0.
  double _backgroundTrackVolume = 1.0;
  bool _isMusicPaused = false;

  /// Музыка приглушена нулевой глобальной громкостью (не скриптом):
  /// чтобы не путать со скриптовой паузой (_isMusicPaused) и уметь
  /// корректно возобновить при размьюте.
  bool _mutedByVolume = false;
  Timer? _countdownTimer;

  /// Подписка, удерживающая autoDispose countdown-провайдер живым, пока
  /// тикает таймер ноды. Раньше его единственным слушателем был виджет
  /// GameTimerWidget: когда таймер скрыт (timerHidden), виджет не строится,
  /// провайдер диспоузится, state сбрасывается в null — и следующий тик
  /// трактовал `?? 0` как «время вышло» и мгновенно дёргал переход.
  ProviderSubscription<GameCountdownData?>? _countdownKeepAlive;
  String? _loadingNodeId;
  bool _isAudioBroken = false;
  bool _isRevealing = false;
  bool _revealRequested = false;
  int _revealGeneration = 0;

  /// Инвариант: между сменой поколения (`_revealGeneration++`) и установкой
  /// списка айтемов новой ноды в state ни один цикл раскрытия не стартует.
  /// В этом окне виджеты ушедшей сцены ещё смонтированы и могут дёрнуть
  /// `revealNextItem()` через `onComplete` — а поколение уже увеличено,
  /// поэтому цикл несёт новое поколение, движок уже на новой ноде, и айтем
  /// #0 съедается до того, как `_applyNodeView` затрёт `revealedItems` (#219:
  /// верхний ряд ноды исчезает). Снимает флаг только `_applyNodeView` —
  /// атомарно с установкой списка.
  bool _revealSuspended = false;

  MeanderGameEngine? _engine;
  MeanderGameEngine? get engine => _engine;

  /// Текущая нода ('' — ещё не загружена). Контекст вызова Lua обязан её
  /// нести: `mnd.game.go` и плагиные хуки работают «из сцены».
  String get currentNodeId => _currentNodeId ?? '';

  Future<void> _engineQueue = Future<void>.value();
  String? _currentNodeId;
  final Set<String> _armedTimers = {};

  Timer? _contentReloadDebounce;
  DateTime? _lastReloadAt;

  /// Аудио при сворачивании приложения.
  ///
  /// По умолчанию (настройка квеста `musicInBackground` = false) при уходе
  /// приложения в фон музыка ставится на паузу и возобновляется при возврате.
  /// Если квест включил «музыку в фоне», паузы не делаем.
  bool _pausedByLifecycle = false;

  /// Кэш настройки квеста `musicInBackground`. Резолвится лениво в
  /// [_resolveMusicInBackground] (первый уход в фон): до этого значение
  /// `false` — безопасный дефолт (музыка ставится на паузу).
  bool? _musicInBackground;

  Future<bool> _resolveMusicInBackground() async {
    // Сначала пробуем синхронно из AsyncValue — самый свежий источник.
    // Это важно: кеш мог устареть, а провайдер уже держит новое значение (true/false).
    try {
      final async = _ref.read(questProvider(_questId));
      if (async.hasValue) {
        final v = async.value?.musicInBackground ?? false;
        if (_musicInBackground != v) {
          _audioLog(
            'resolve sync update cached $_musicInBackground -> $v (questId=$_questId)',
          );
        }
        _musicInBackground = v;
        return v;
      }
    } catch (_) {}
    final cached = _musicInBackground;
    if (cached != null) {
      _audioLog('resolve cached=$cached (questId=$_questId, async loading)');
      return cached;
    }
    try {
      final quest = await _ref.read(questProvider(_questId).future);
      final v = quest?.musicInBackground ?? false;
      _audioLog('resolve async loaded v=$v (questId=$_questId)');
      _musicInBackground = v;
      return v;
    } catch (e, st) {
      _audioLog('resolve async error $e -> false\n$st');
      _musicInBackground = false;
      return false;
    }
  }

  void _invalidateMusicInBackgroundCache(AsyncValue<Quest?> next) {
    final prev = _musicInBackground;
    if (next.hasValue) {
      _musicInBackground = next.value?.musicInBackground;
      _audioLog(
        'invalidate hasValue $prev -> $_musicInBackground (questId=$_questId id=${next.value?.id} musicInBackground=${next.value?.musicInBackground})',
      );
    } else if (next.hasError) {
      _musicInBackground = false;
      _audioLog('invalidate error $prev -> false err=${next.error}');
    } else {
      // loading — сбрасываем, чтобы _resolve перечитал свежие данные,
      // иначе останется старое значение (например true после выключения).
      _audioLog('invalidate loading $prev -> null');
      _musicInBackground = null;
    }
  }

  /// Уход приложения в фон: пауза аудио, если квест не разрешил играть в фоне.
  /// Вызывается для hidden/paused (inactive — промежуточное состояние, не сворачивание).
  Future<void> handleAppLifecyclePaused() async {
    try {
      if (_isAudioBroken || kIsWeb) return;
      final allowBackground = await _resolveMusicInBackground();
      _audioLog(
        'lifecycle check paused allowBackground=$allowBackground state=${_backgroundAudioPlayer.state} id=$_currentBackgroundAudioId pausedByLifecycle=$_pausedByLifecycle',
      );
      if (allowBackground) return;
      if (_pausedByLifecycle) return;
      // Паузим даже если state не строго playing — на некоторых платформах
      // loop-трек может быть в другом состоянии, но звук идёт.
      if (_backgroundAudioPlayer.state != PlayerState.paused &&
          _backgroundAudioPlayer.state != PlayerState.stopped &&
          _backgroundAudioPlayer.state != PlayerState.completed) {
        await _backgroundAudioPlayer.pause();
        _audioLog(
          'lifecycle paused bg (state was ${_backgroundAudioPlayer.state})',
        );
      } else if (_currentBackgroundAudioId != null) {
        // Трек загружен но state уже paused/stopped — всё равно помечаем,
        // чтобы не пытаться резюмить скриптовую паузу.
        try {
          await _backgroundAudioPlayer.pause();
        } catch (_) {}
      }
      // Помечаем как поставленную на паузу жизненным циклом, если есть что возобновлять.
      if (_currentBackgroundAudioId != null) {
        _pausedByLifecycle = true;
      }
    } catch (e) {
      _log('Lifecycle pause error: $e');
    }
  }

  /// Алиасы для AppLifecycleListener: hidden мапится на паузу, inactive — игнор.
  Future<void> handleAppLifecycleHidden() => handleAppLifecyclePaused();
  Future<void> handleAppLifecycleInactive() async {
    // inactive — не сворачивание (шторка, диалог). Не паузим, чтобы не дёргать аудио зря.
  }

  /// Возврат приложения: возобновляем только то, что сами поставили на паузу
  /// (скриптовые паузы (_isMusicPaused) и mute (_mutedByVolume) не трогаем).
  Future<void> handleAppLifecycleResumed() async {
    try {
      if (_isAudioBroken) return;
      if (!_pausedByLifecycle) return;
      _pausedByLifecycle = false;
      // Музыка могла быть остановлена/заменена скриптом, пока приложение
      // было свёрнуто — возобновляем только если трек жив (paused).
      if (_currentBackgroundAudioId != null &&
          _backgroundAudioPlayer.state == PlayerState.paused) {
        await _backgroundAudioPlayer.resume();
        _audioLog('lifecycle resumed bg');
      }
    } catch (e) {
      _log('Lifecycle resume error: $e');
    }
  }

  /// Алиасы для AppLifecycleListener: show/restart мапятся на резюм.
  Future<void> handleAppLifecycleShown() => handleAppLifecycleResumed();
  Future<void> handleAppLifecycleRestart() => handleAppLifecycleResumed();

  /// Жива ли игровая сессия на экране. Экран вызывает [markSessionEnded]
  /// синхронно в своём `dispose` — тогда незавершённые async-перезагрузки
  /// (reload после редактора, дебаунс live-reload) не успевают дёрнуть
  /// `state =` в уже размонтированный элемент (краш
  /// `_lifecycleState != defunct`). autoDispose диспоузит провайдер только
  /// в конце фрейма — без этого флага окно гонки остаётся.
  bool _sessionActive = true;
  bool _reloadInFlight = false;

  /// Вызывается из `dispose` игрового экрана. Запрещает дальнейшие эмиссии.
  void markSessionEnded() {
    // quest_end — пока ref/движок ещё живы (dispose провайдера будет позже).
    _emitPluginEventFireAndForget(
      'quest_end',
      payload: {'quest_id': _questId},
      nodeId: _currentNodeId ?? '',
    );
    _sessionActive = false;
    _contentReloadDebounce?.cancel();
  }

  bool get _alive => mounted && _sessionActive;

  static const Duration _engineCallTimeout = Duration(seconds: 30);

  GameScreenNotifier(
    this._ref,
    this._questId, {
    GameScreenHooks? hooks,
    String? sessionKey,
  }) : sessionKey = sessionKey ?? _questId,
       _hooks = hooks ?? GameScreenHooks.empty,
       super(const GameScreenState()) {
    // Детальный лог создания — чтобы поймать размножение провайдеров.
    if (kDebugMode) {
      final st = StackTrace.current.toString().split('\n').take(8).join(' | ');
      print(
        '🎮 [GameScreen] CREATING session=$sessionKey quest=$_questId hash=${hashCode} alive=$mounted stack=$st',
      );
    }
    // Также событие для HangWatchdog / CrashLog если подключены.
    _hooks.onStep?.call('create: $sessionKey');

    _gameStateSub = _ref.listen<GameState>(gameStateProvider, (prev, next) {
      final prevTagVol = prev?.variables['_internal_tag_volume'];
      final nextTagVol = next.variables['_internal_tag_volume'];
      if (prevTagVol != nextTagVol) {
        _applyBackgroundVolumeFromState();
      }
    });
    // Глобальная громкость (ползунок в UI) — множитель для всех аудио.
    _ref.listen<double>(globalAudioVolumeProvider, (prev, next) {
      if (prev != next) _applyGlobalVolumeToPlayers();
    });

    // Следим за изменением настройки квеста «Музыка при сворачивании» —
    // чтобы переключение в редакторе сразу отразилось на кэше.
    _ref.listen<AsyncValue<Quest?>>(
      questProvider(_questId),
      (prev, next) => _invalidateMusicInBackgroundCache(next),
    );

    _hooks.listenContentChanges?.call(_questId, _onQuestContentChanged);

    // Когда autoDispose сбросит провайдер — Riverpod дернет onDispose.
    _ref.onDispose(() {
      if (kDebugMode) {
        final st2 = StackTrace.current
            .toString()
            .split('\n')
            .take(8)
            .join(' | ');
        print(
          '🎮 [GameScreen] onDispose callback session=$sessionKey quest=$_questId hash=${hashCode} stack=$st2',
        );
      }
    });
  }

  // -------------------------------------------------------------------------
  // Logging
  // -------------------------------------------------------------------------

  void _log(String message) {
    if (kDebugMode) print('🎮 [GameScreen] $message');
  }

  void _step(String name) => _hooks.onStep?.call(name);
  void _err(Object e, StackTrace? s, String ctx) =>
      _hooks.onError?.call(e, s, ctx);

  // -------------------------------------------------------------------------
  // Engine serialisation
  // -------------------------------------------------------------------------

  Future<T> _engineCall<T>(String step, Future<T> Function() call) {
    return _serialized(() async {
      _step(step);
      try {
        return await call().timeout(_engineCallTimeout);
      } on TimeoutException {
        _log('⏱️ Engine call timed out: $step');
        _err(
          TimeoutException('Engine call timed out: $step'),
          null,
          'engineTimeout',
        );
        rethrow;
      } on GameEnginePoisonedException catch (e) {
        _log('☠️ Engine poisoned: $e');
        _err(e, null, 'enginePoisoned($step)');
        _disposeEngine();
        if (_alive)
          state = state.copyWith(isLoading: false, error: e.toString());
        rethrow;
      } on GameEngineHandleNotFoundError catch (e) {
        _log('⚠️ Engine handle gone: $e');
        _err(e, null, 'engineDisposed($step)');
        _disposeEngine();
        if (_alive)
          state = state.copyWith(isLoading: false, error: e.toString());
        rethrow;
      }
    });
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _engineQueue.then((_) => action());
    _engineQueue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  void _disposeEngine() {
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      try {
        engine.dispose();
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------------
  // Audio helpers
  // -------------------------------------------------------------------------

  void _audioLog(String message) => debugPrint('[QuestAudio][bg] $message');

  /// Авторский id звука без префикса каталога квеста:
  /// `quests/<id>/res/audio/x.mp3` → `res/audio/x.mp3`.
  ///
  /// Индекс каталога (`res/audio/`) тут больше не дописывается: это делает
  /// резолвер — по расширению или по библиотеке, — иначе имя ресурса
  /// («закат») превращалось в `res/audio/закат` и не находилось.
  String _normalizeBackgroundAudioId(String rawId) {
    final normalized = rawId.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) return normalized;
    final fullPrefix = '${QuestPaths.questRoot(_questId)}/';
    if (normalized.startsWith(fullPrefix)) {
      return _normalizeBackgroundAudioId(
        normalized.substring(fullPrefix.length),
      );
    }
    if (normalized.startsWith('/')) {
      return _normalizeBackgroundAudioId(normalized.substring(1));
    }
    return normalized;
  }

  // -------------------------------------------------------------------------
  // Engine lifecycle
  // -------------------------------------------------------------------------

  Future<MeanderGameEngine?> _createEngine() async {
    final appDir = await FileStorage.getAppDirectory();
    return await _engineCall(
      '_createEngine',
      () => MeanderGameEngine.create(questId: _questId, questRoot: appDir.path),
    );
  }

  /// Финальные значения переменных/таблиц, которые пейсинг «придерживает».
  ///
  /// Движок после `onNodeEnter` уже в финальном состоянии, а `wait` надо
  /// сыграть ПОСЛЕ отрисовки сцены. Пока очередь задержек не выбрана, эти
  /// ключи не попадают в Dart при синке дельты: сцена показывает кадр до
  /// первой задержки, а мутации после неё выходят, когда время придёт.
  Map<String, dynamic> _pacingHeldVars = const {};
  Map<String, dynamic> _pacingHeldTables = const {};

  Future<void> _syncStateFromEngine({bool holdPacing = false}) async {
    // Сессия могла завершиться, пока летела дельта (reload после редактора,
    // закрытие игры): эмиссия в gameStateProvider пересобрала бы подписчиков
    // уже мёртвого экрана или просто сделала бы лишнюю работу.
    if (!_alive) return;
    final engine = _engine;
    if (engine == null) return;
    final delta = await _engineCall(
      'syncStateFromEngine: drainStateDelta',
      engine.drainStateDelta,
    );
    var variables = delta['variables'] as Map<String, dynamic>? ?? const {};
    var tables = delta['tables'] as Map<String, dynamic>? ?? const {};
    if (holdPacing) {
      _pacingHeldVars = variables;
      _pacingHeldTables = tables;
      variables = const {};
      tables = const {};
    } else if (_pacingHeldVars.isNotEmpty || _pacingHeldTables.isNotEmpty) {
      // Держим ровно те значения, что движок отдал на входе в ноду. Значение,
      // записанное за время задержки заново (другое), пропускаем: придерживать
      // его — значит потерять запись таймера или onContentAppear.
      final heldVars = Map.of(_pacingHeldVars);
      final heldTables = Map.of(_pacingHeldTables);
      variables = Map.of(variables)
        ..removeWhere((k, v) {
          if (!heldVars.containsKey(k)) return false;
          if (heldVars[k] == v) return true;
          heldVars.remove(k);
          return false;
        });
      tables = Map.of(tables)
        ..removeWhere((k, v) {
          if (!heldTables.containsKey(k)) return false;
          if (heldTables[k] == v) return true;
          heldTables.remove(k);
          return false;
        });
      _pacingHeldVars = heldVars;
      _pacingHeldTables = heldTables;
    }
    _ref
        .read(gameStateProvider.notifier)
        .applyDelta(variables: variables, tablesJson: tables);
  }

  /// Отдать придерживанные финальные значения и вернуть движку реальное
  /// состояние вместо pacing-оверлея.
  Future<void> _releasePacingHold() async {
    final engine = _engine;
    if (engine != null && !engine.isDisposed) engine.restoreAfterPacing();
    final vars = _pacingHeldVars;
    final tables = _pacingHeldTables;
    _pacingHeldVars = const {};
    _pacingHeldTables = const {};
    if (!_alive) return;
    if (vars.isNotEmpty || tables.isNotEmpty) {
      _ref
          .read(gameStateProvider.notifier)
          .applyDelta(variables: vars, tablesJson: tables);
    }
    // Сверх захваченного — всё, что движок успел записать за время задержки
    // (таймер, onContentAppear): иначе свежие значения затёрты старыми.
    await _syncStateFromEngine();
  }

  /// Доиграть задержки входа в ноду в фоне: сцена уже отрисована, игрок видит
  /// кадр до `wait`, а мутации после него выходят по расписанию скрипта.
  Future<void> _paceNodeEnterInBackground(
    List<Map<String, dynamic>> steps,
    String nodeId,
  ) async {
    try {
      for (var i = 0; i < steps.length; i++) {
        final ms = ((steps[i]['ms'] ?? 0) as num).toInt();
        if (ms > 0) await Future.delayed(Duration(milliseconds: ms));
        if (!_alive || _currentNodeId != nodeId) return;
        if (i + 1 < steps.length) await _applyPacingStep(steps[i + 1]);
      }
    } catch (e, stack) {
      _err(e, stack, 'paceNodeEnter($nodeId)');
    } finally {
      try {
        await _releasePacingHold();
      } catch (e, stack) {
        _err(e, stack, 'releasePacingHold($nodeId)');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Плагины (L3B)
  // -------------------------------------------------------------------------

  PluginRuntime? _plugins;

  /// UI-состояние плагинов этой сессии: surface'ы слотов и айтемов, отмена
  /// переходов. `null` — плагинов нет (или сессия ещё не поднята).
  PluginRuntime? get plugins => _plugins;

  final StreamController<PluginToast> _pluginToasts =
      StreamController<PluginToast>.broadcast();

  /// Тосты `mnd.ui.toast` — экран показывает их как SnackBar.
  Stream<PluginToast> get pluginToasts => _pluginToasts.stream;

  /// Поставить активные пакеты в Rust-хост и поднять рантайм сессии.
  ///
  /// Вызывается до первой ноды: `quest_start` может нарисовать HUD, который
  /// обязан быть на месте к моменту рендера. Ошибки не фатальны — квест
  /// играется и без плагинов.
  Future<void> _installPlugins() async {
    try {
      final dirs =
          await (_hooks.listPluginPackages?.call() ??
              standalonePluginPackages());
      final report = await syncPluginPackages(dirs);
      for (final failure in report.failed) {
        _log('⚠️ плагин не установлен: $failure');
      }
      final runtime = _plugins ??= PluginRuntime(
        backend: const FfiPluginBackend(),
        questId: _questId,
        readVars: _pluginVarsSnapshot,
        onVarWrites: _applyPluginVarWrites,
        onNavigate: _pluginNavigate,
        onToast: _pluginToasts.add,
        onPlaySound: (asset, volume) =>
            unawaited(_playSoundEffect(asset, volume)),
        onStopSound: (asset) => _stopSoundEffect(asset ?? 'plugin'),
        onStorage: (pluginId, storage) =>
            unawaited(writePluginStorage(pluginId, storage)),
      );
      // Перезапуск сессии в том же нотификаторе: surface'ы прошлой игры
      // не должны доехать до новой.
      runtime.reset();
      await runtime.refresh();
      _log(
        '🔌 плагины: ${runtime.hasPlugins ? 'активны' : 'нет'} '
        '(${report.loaded.length}/${dirs.length})',
      );
    } catch (e, stack) {
      _log('⚠️ Plugin install failed: $e');
      _err(e, stack, 'installPlugins');
    }
  }

  /// Снапшот переменных для Lua. После Размонтирования экрана `ref` мёртв,
  /// а отложенный вызов хоста ещё возможен — отдаём пустой набор.
  Map<String, dynamic> _pluginVarsSnapshot() {
    if (!_alive) return const {};
    try {
      return Map<String, dynamic>.from(_ref.read(gameStateProvider).variables);
    } catch (_) {
      return const {};
    }
  }

  /// Запись переменной из плагина (`mnd.vars.set`): в движок — чтобы её
  /// видели условия видимости и сохранения, и в Dart-стейт — чтобы сразу
  /// увидели виджеты.
  void _applyPluginVarWrites(Map<String, dynamic> writes) {
    if (writes.isEmpty) return;
    final engine = _engine;
    if (engine != null && !engine.isDisposed) {
      writes.forEach((name, value) {
        try {
          engine.setStateVariable(name, value);
        } catch (e) {
          _log('⚠️ plugin var → engine failed ($name): $e');
        }
      });
      // У прямой мутации нет канала возврата: переход от подписки
      // `onDataChange` на переменную плагина иначе ждал бы следующего шага.
      try {
        final next = engine.takePendingTransition();
        if (next != null) _pluginNavigate(next);
      } catch (e) {
        _log('⚠️ plugin var → pending transition failed: $e');
      }
    }
    if (!_alive) return;
    // applyDelta ест «сырую» дельту движка: имя → JSON-строка.
    final encoded = writes.map(
      (name, value) => MapEntry(name, jsonEncode(value)),
    );
    _ref
        .read(gameStateProvider.notifier)
        .applyDelta(variables: encoded, tablesJson: const {});
  }

  void _pluginNavigate(String nodeId) {
    if (!_alive) return;
    unawaited(loadNode(nodeId));
  }

  /// Пройти событие контракта плагинами. Наблюдательные события (всё кроме
  /// `node_enter`) не могут сорвать гейм-луп: любая ошибка хоста — только лог.
  /// Возвращает `true`, если событие отменили (`cancel` у `node_enter`).
  Future<bool> _emitPluginEvent(
    String event, {
    Map<String, dynamic> payload = const {},
    String nodeId = '',
  }) async {
    final runtime = _plugins;
    if (runtime == null || !runtime.listensTo(event)) return false;
    try {
      final canceled = await runtime.dispatchEvent(
        event,
        payload: payload,
        nodeId: nodeId,
      );
      for (final notice in runtime.notices) {
        _log('🔌 [$event] $notice');
      }
      return canceled;
    } catch (e, stack) {
      _log('⚠️ plugin event $event failed: $e');
      _err(e, stack, 'pluginEvent($event)');
      return false;
    }
  }

  /// Отправить событие и не ждать: наблюдается для побочных эффектов
  /// (лог, тост, UI), а не для управления переходом.
  void _emitPluginEventFireAndForget(
    String event, {
    Map<String, dynamic> payload = const {},
    String nodeId = '',
  }) {
    unawaited(_emitPluginEvent(event, payload: payload, nodeId: nodeId));
  }

  // -------------------------------------------------------------------------
  // Timer scheduling
  // -------------------------------------------------------------------------
  void _armPendingTimers() {
    if (!_alive) return;
    final vars = _ref.read(gameStateProvider).variables;
    final schedule = vars['_internal_timer_schedule'];
    if (schedule is! List) return;
    final armedThisRound = <String>{};
    for (final raw in schedule) {
      if (raw is! Map) continue;
      final path = raw['script_path']?.toString();
      final entry = raw['entry']?.toString();
      final ms = (raw['ms'] as num?)?.toInt() ?? 0;
      if (path == null || entry == null || ms <= 0) continue;
      final key = '$path::$entry';
      if (armedThisRound.contains(key) || _armedTimers.contains(key)) continue;
      armedThisRound.add(key);
      _armedTimers.add(key);
      _log('⏱ Timer armed: $key in ${ms}ms');
      Future.delayed(
        Duration(milliseconds: ms),
        () => _fireTimer(key, path, entry),
      );
    }
  }

  Future<void> _fireTimer(String key, String path, String entry) async {
    _armedTimers.remove(key);
    try {
      final engine = _engine;
      if (engine == null || !_alive) return;
      final res = await _engineCall(
        'runScheduledTimer',
        () => engine.runScheduledTimer(path, entry),
      );
      if (!_alive) return;
      await _paceScriptDelays();
      if (!mounted) return;
      await _drainAudio();
      await _syncStateFromEngine();
      if (res?['ran'] == true) {
        final transition = res?['transition']?.toString();
        if (transition != null && transition.isNotEmpty) {
          loadNode(transition);
          return;
        }
      }
      _armPendingTimers();
    } catch (e, stack) {
      _log('⚠️ Timer tick failed ($key): $e');
      _err(e, stack, 'timerTick($key)');
      _armPendingTimers();
    }
  }

  // -------------------------------------------------------------------------
  // Pacing / audio drain
  // -------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _takePacingSteps() async {
    final engine = _engine;
    if (engine == null || !_alive) return const [];
    _step('paceScriptDelays: drainDelaySteps');
    final steps = await _engineCall(
      'paceScriptDelays: drainDelaySteps',
      engine.drainDelaySteps,
    );
    if (steps.isNotEmpty) _log('⏳ Pacing ${steps.length} wait step(s)');
    return steps;
  }

  /// Промежуточный кадр одного `wait`: накладывается поверх Dart-состояния и
  /// поверх движка (без dirty-трекинга), чтобы `evaluateVisibility` видел
  /// анимацию, а не только финальное значение.
  Future<void> _applyPacingStep(Map<String, dynamic> step) async {
    final engine = _engine;
    if (engine == null || !_alive) return;
    final variables = step['variables'] as Map<String, dynamic>? ?? const {};
    final tables = step['tables'] as Map<String, dynamic>? ?? const {};
    if (variables.isNotEmpty || tables.isNotEmpty) {
      _ref
          .read(gameStateProvider.notifier)
          .applyDelta(variables: variables, tablesJson: tables);
      if (variables.isNotEmpty) engine.applyExternalVariables(variables);
    }
    final audio = step['audio'] as List? ?? const [];
    if (audio.isNotEmpty) await _applyAudioCommands({'commands': audio});
  }

  Future<void> _runPacingSteps(List<Map<String, dynamic>> steps) async {
    if (steps.isEmpty) return;
    final engine = _engine;
    if (engine == null || !_alive) return;
    try {
      for (final step in steps) {
        if (!_alive) return;
        await _applyPacingStep(step);
        final ms = ((step['ms'] ?? 0) as num).toInt();
        if (ms > 0 && _alive) await Future.delayed(Duration(milliseconds: ms));
      }
    } finally {
      // Восстановить реальное состояние движка (до оверлея).
      // Без этого drainStateDelta вернёт искажённую дельту.
      if (!engine.isDisposed) engine.restoreAfterPacing();
    }
  }

  Future<void> _paceScriptDelays() async {
    await _runPacingSteps(await _takePacingSteps());
  }

  Future<void> _drainAudio() async {
    final engine = _engine;
    if (engine == null || _isAudioBroken) return;
    final cmd = await _engineCall('drainAudio', engine.drainAudio);
    await _applyAudioCommands(cmd);
  }

  /// Публичный метод синхронизации: слить из движка всё, что в нём осталось от
  /// последнего исполнения скрипта, и обновить Dart-стейт. Вызывается из UI
  /// после [TriggerPipeline.execute] и после прямых вызовов `executeBehaviour`
  /// виджетами, чтобы те видели актуальное состояние, а звук и ссылки
  /// доигрывались в своей сцене.
  Future<void> syncEngineState() async {
    if (!_alive) return;
    // Очередь `wait` — первой: её шаги несут и промежуточные кадры, и звуки
    // между задержками. Оставленная, она сливается на следующем входе в ноду
    // и показывает старой сценой по новой.
    await _paceScriptDelays();
    if (!_alive) return;
    await _drainAudio();
    await _drainExternal();
    await _syncStateFromEngine();
  }

  Future<void> _drainExternal() async {
    final engine = _engine;
    if (engine == null || !_alive) return;
    final cmd = await _engineCall('drainExternal', engine.drainExternal);
    await _applyExternalCommands(cmd);
  }

  Future<void> _applyExternalCommands(Map<String, dynamic> cmd) async {
    final commands = cmd['commands'] as List? ?? const [];
    for (final raw in commands) {
      if (raw is! Map) continue;
      final c = Map<String, dynamic>.from(raw);
      if (c['type'] == 'open_link') {
        await _openExternalLink(c['url'].toString());
      }
    }
  }

  Future<void> _openExternalLink(String url) async {
    if (url.isEmpty) return;
    if (_hooks.isUrlSafe != null && !_hooks.isUrlSafe!(url)) {
      _log('🛡️ open_link заблокирован');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _log('⚠️ open_link failed ($url): $e');
    }
  }

  Future<void> _applyAudioCommands(Map<String, dynamic> cmd) async {
    final commands = cmd['commands'] as List? ?? const [];
    for (final raw in commands) {
      if (raw is! Map) continue;
      final c = Map<String, dynamic>.from(raw);
      // Зеркало аудио-команд в плагины (`audio`, observe only): kind — сырой
      // тип AudioCommandDelta, чтобы словари команд не плодить в двух местах.
      _emitPluginEventFireAndForget(
        'audio',
        payload: {
          'kind': c['type'],
          'asset': c['id'] ?? c['target'],
          'volume': c['volume'],
        },
        nodeId: _currentNodeId ?? '',
      );
      switch (c['type']) {
        case 'playSound':
          await _playSoundEffect(
            c['id'].toString(),
            (c['volume'] as num?)?.toDouble() ?? 1.0,
          );
        case 'stopSound':
          _stopSoundEffect(c['target'].toString());
        case 'playMusic':
          await _playBackgroundMusic(
            c['id'].toString(),
            (c['volume'] as num?)?.toDouble() ?? 1.0,
            c['loop'] as bool? ?? true,
          );
        case 'stopMusic':
          _stopBackgroundMusic();
        case 'pauseResume':
          _pauseResumeAudio(c['target'].toString(), c['action'].toString());
        case 'fadeOut':
          await _crossfadeOut((c['ms'] as num).toInt());
        case 'fadeIn':
          await _crossfadeIn((c['ms'] as num).toInt());
      }
    }
  }

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  void invalidateQuestCaches() {
    _disposeEngine();
    _currentNodeId = null;
    _armedTimers.clear();
  }

  // --- Content change / live-reload ---

  void _onQuestContentChanged() {
    _contentReloadDebounce?.cancel();
    _contentReloadDebounce = Timer(const Duration(milliseconds: 700), () {
      _contentReloadDebounce = null;
      final lastReload = _lastReloadAt;
      if (lastReload != null &&
          DateTime.now().difference(lastReload) < const Duration(seconds: 2)) {
        return;
      }
      final nodeId = _currentNodeId;
      if (!_alive || nodeId == null || nodeId.isEmpty || _engine == null) {
        return;
      }
      unawaited(reloadNodeAfterEditor(nodeId));
    });
  }

  Future<void> reloadNodeAfterEditor(String nodeId) async {
    // Сериализация: и прямой вызов (возврат из редактора), и дебаунс
    // live-reload могут запустить reload одновременно — две гонки движков
    // и два `state =` подряд. Второй вызов, пока первый в полёте, пропускаем.
    if (_reloadInFlight) return;
    _reloadInFlight = true;
    _lastReloadAt = DateTime.now();
    final preservePresentation = _currentNodeId == nodeId;
    _revealGeneration++;
    _revealSuspended = true;
    final loadedGen = _revealGeneration;
    _isRevealing = false;
    _revealRequested = false;
    try {
      final engine = _engine;
      final saved = engine != null
          ? await _engineCall(
              'reload: toSaveSlot',
              () => engine.toSaveSlot('reload'),
            )
          : null;

      final newEngine = await _createEngine();
      if (newEngine == null) throw Exception('Не удалось пересоздать движок.');
      _engine = newEngine;

      if (saved != null) {
        final view = await _engineCall(
          'reload: startFromSave',
          () => newEngine.startFromSave(saved),
        );
        if (view != null) {
          await _paceScriptDelays();
          if (!_alive) return;
          await _drainAudio();
          await _syncStateFromEngine();
          await _applyNodeView(
            view,
            preservePresentation: preservePresentation,
          );
          _armPendingTimers();
          return;
        }
      }

      final view = await _engineCall(
        'reload: startNew',
        () => newEngine.startNew(startNodeId: nodeId),
      );
      if (view != null) {
        await _paceScriptDelays();
        if (!_alive) return;
        await _drainAudio();
        await _syncStateFromEngine();
        await _applyNodeView(view, preservePresentation: preservePresentation);
        _armPendingTimers();
      }
    } catch (e, stack) {
      _log('⚠️ reloadNodeAfterEditor error: $e');
      _err(e, stack, 'reloadNodeAfterEditor($nodeId)');
      if (_alive) state = state.copyWith(isLoading: false, error: e.toString());
    } finally {
      _reloadInFlight = false;
      _resumeReveal(loadedGen);
    }
  }

  Future<void> _ensureItemFonts(SavedNode node) async {
    final fontPaths = <String>{};

    void addPath(String? raw) {
      final p = raw?.trim();
      if (p != null && p.isNotEmpty) fontPaths.add(p);
    }

    // Обход по сырому JSON ноды, а не по полям ContentItem: шрифт лежит в
    // `buttonStyle` у вложенных слоёв стека и элементов модалки, до которых
    // типизированный обход не добирается. Плюс инлайн-теги `[font=…]` в
    // любом тексте.
    fontPaths.addAll(FontService.collectFontRefsFromJson(node.content));

    // Шрифт пресета по умолчанию (#159): кнопки без своего стиля ссылаются на
    // него, поэтому зарегистрировать шрифт нужно независимо от айтемов.
    final quest = await _ref.read(questProvider(_questId).future);
    addPath(quest?.defaultButtonStyle?.fontFamily);
    fontPaths.addAll(await _templateFontPaths());

    for (final path in fontPaths) {
      await FontService.loadQuestFont(_questId, path);
    }
  }

  Future<Set<String>>? _templateFontPathsCache;

  /// Шрифты мастеров из `res/templates.json`: нода хранит только `templateRef`,
  /// а `buttonStyle.fontFamily` живёт в шаблоне — без него кнопка из шаблона
  /// играется шрифтом по умолчанию.
  Future<Set<String>> _templateFontPaths() {
    return _templateFontPathsCache ??= () async {
      final path = QuestPaths.templates(_questId);
      if (!await FileStorage.exists(path)) return <String>{};
      try {
        return FontService.collectFontRefsFromJson(
          await FileStorage.readJsonFile(path),
        );
      } catch (e) {
        _log('⚠️ Шрифты шаблонов не прочитаны: $e');
        return <String>{};
      }
    }();
  }

  // --- Init ---

  Future<void> initializeGameSession() async {
    _log('Initializing session...');
    _step('initializeGameSession: start');
    try {
      try {
        await WakelockPlus.enable();
      } catch (_) {}
      _step('initializeGameSession: wakelock');

      // Аудио инициализируем на всех нативных платформах (Android/iOS/Windows/Linux/macOS).
      // kIsWeb ветка тоже инициализируется, но lifecycle-пауза для веба — no-op (см. handleAppLifecyclePaused).
      // Раньше для десктопа был early-return и skip инициализации (BISECT) — это ломало «Музыка при сворачивании» на Windows/Linux.
      if (kIsWeb) {
        await _backgroundAudioPlayer.setReleaseMode(ReleaseMode.loop);
        _backgroundPlayerStateSub = _backgroundAudioPlayer.onPlayerStateChanged
            .listen((state) => _audioLog('bg state=$state'));
        await _soundEffectPlayer.setReleaseMode(ReleaseMode.stop);
        _soundEffectPlayerStateSub = _soundEffectPlayer.onPlayerStateChanged
            .listen((state) => _audioLog('sfx state=$state'));
      } else {
        await _backgroundAudioPlayer.setReleaseMode(ReleaseMode.loop);
        _backgroundPlayerStateSub = _backgroundAudioPlayer.onPlayerStateChanged
            .listen((state) => _audioLog('bg state=$state'));
        await _soundEffectPlayer.setReleaseMode(ReleaseMode.stop);
        _soundEffectPlayerStateSub = _soundEffectPlayer.onPlayerStateChanged
            .listen((state) => _audioLog('sfx state=$state'));
        if (Platform.isAndroid || Platform.isIOS) {
          await _backgroundAudioPlayer.setAudioContext(
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
      }

      await _loadCustomFont();
      // Прогреваем кэш настройки фона, чтобы первый уход в фон не ждал future с гонкой.
      try {
        await _resolveMusicInBackground();
      } catch (_) {}
      _step('initializeGameSession: audio+font');
      _log('✅ Audio & Font initialized');
    } catch (e) {
      _log('⚠️ Init Error (Non-fatal): $e');
      _isAudioBroken = true;
    }
  }

  Future<void> _loadCustomFont() async {
    try {
      final quest = await _ref.read(questProvider(_questId).future);
      if (quest?.customFontFileName != null) {
        final fontFamily = await FontService.loadQuestFont(
          _questId,
          quest!.customFontFileName!,
        );
        if (_alive && fontFamily != null)
          state = state.copyWith(fontFamily: fontFamily);
      }
    } catch (e) {
      _log('Font load error: $e');
    }
  }

  // --- Load ---

  Future<void> loadInitialNode(
    String? startNodeId, {
    SaveSlot? saveSlot,
  }) async {
    _revealGeneration++;
    _revealSuspended = true;
    final loadedGen = _revealGeneration;
    _isRevealing = false;
    _revealRequested = false;
    // Новая игровая сессия: сбросить переменные/таблицы прошлой игры
    // (gameStateProvider не autoDispose, поэтому нужна явная очистка).
    _ref.read(gameStateProvider.notifier).clear();
    _pacingHeldVars = const {};
    _pacingHeldTables = const {};
    _step('loadInitialNode');
    try {
      state = state.copyWith(isLoading: true, clearError: true);
      final engine = await _createEngine();
      if (engine == null) throw Exception('Не удалось создать движок.');
      _engine = engine;

      await _installPlugins();

      Map<String, dynamic>? view;
      if (saveSlot != null) {
        view = await _engineCall(
          'loadInitialNode: startFromSave',
          () => engine.startFromSave(saveSlot.toJson()),
        );
      } else {
        view = await _engineCall(
          'loadInitialNode: startNew',
          () => engine.startNew(startNodeId: startNodeId),
        );
      }

      if (view == null) {
        throw Exception(
          'В квесте не задана стартовая нода — назначьте её в редакторе.',
        );
      }

      final pacingSteps = await _takePacingSteps();
      if (!_alive) return;
      await _drainExternal();
      if (!_isAudioBroken) await _drainAudio();
      await _syncStateFromEngine(holdPacing: pacingSteps.isNotEmpty);
      if (pacingSteps.isNotEmpty) await _applyPacingStep(pacingSteps.first);

      // Контракт событий (§2–§3 docs/event-contract.md): quest_load →
      // quest_start → node_enter первой ноды — всё до её рендера.
      final enteredNodeId = view['nodeId'] as String? ?? '';
      if (saveSlot != null) {
        await _emitPluginEvent(
          'quest_load',
          payload: {'slot_id': saveSlot.slotName, 'from_save': true},
          nodeId: enteredNodeId,
        );
      }
      await _emitPluginEvent(
        'quest_start',
        payload: {'quest_id': _questId},
        nodeId: enteredNodeId,
      );
      if (!_alive) return;
      if (await _emitPluginEvent(
        'node_enter',
        payload: {'node_id': enteredNodeId},
        nodeId: enteredNodeId,
      )) {
        _log('🔌 node_enter первой ноды отменён плагином: $enteredNodeId');
        return;
      }

      await _applyNodeView(view);
      _armPendingTimers();
      if (pacingSteps.isNotEmpty) {
        unawaited(_paceNodeEnterInBackground(pacingSteps, enteredNodeId));
      }
      _log('✅ loadInitialNode complete');
    } catch (e, stack) {
      _log('❌ Error in loadInitialNode: $e\n$stack');
      _err(e, stack, 'loadInitialNode');
      if (_alive) state = state.copyWith(isLoading: false, error: e.toString());
    } finally {
      _resumeReveal(loadedGen);
    }
  }

  Future<void> _applyNodeView(
    Map<String, dynamic> view, {
    bool preservePresentation = false,
  }) async {
    // Сессия могла завершиться, пока парсился view (reload после редактора +
    // закрытие игры): дальше идут эмиссии state= и reveal-цикл — только
    // при живом экране.
    if (!_alive) return;
    _step('applyNodeView: parse node');
    final nodeId = view['nodeId'] as String;
    _currentNodeId = nodeId;

    final rawNode = view['node'];
    final node = rawNode is Map<String, dynamic>
        ? SavedNode.fromJson(rawNode)
        : SavedNode.fromJson({
            'id': nodeId,
            'title': view['title'] as String? ?? '',
            'content': const <String, dynamic>{'items': <dynamic>[]},
          });

    // Фон — тот же резолв, что у картинки в сцене: путь, имя из библиотеки или
    // uuid. Раньше сюда был вшит `res/images/`, и значение «закат» или
    // «res/images/x.png» давало пустой фон.
    final bgImageId = view['backgroundImageId'] as String?;
    String? bgPath;
    if (bgImageId != null && bgImageId.isNotEmpty) {
      final full = await QuestImageSource.resolveOnDisk(_questId, bgImageId);
      if (full.isNotEmpty) bgPath = full;
    }
    final bgVideoId = view['backgroundVideoId'] as String?;
    String? bgVideoPath;
    if (bgVideoId != null && bgVideoId.isNotEmpty) {
      final full = await QuestImageSource.resolveOnDisk(_questId, bgVideoId);
      if (full.isNotEmpty) bgVideoPath = full;
    }

    // Шрифты айтемов (стили кнопок, item.fontFamily, инлайн-теги [font=])
    // должны быть загружены до отрисовки — family-имя резолвится
    // детерминированно, но FontLoader должен отработать, иначе текст упадёт
    // на дефолтный шрифт.
    await _ensureItemFonts(node);

    if (!_alive || _currentNodeId != nodeId) return;

    // Блокировка снимается и список ставится одним синхронным блоком: между
    // этими двумя строками не должно быть await, иначе чужой onComplete
    // успеет съесть айтем #0 новой ноды (#219).
    _revealSuspended = false;
    state = state.copyWith(
      isLoading: false,
      currentNode: node,
      revealedItems: const [],
      pinnedStacks: const [],
      dismissedStacks: const {},
      backgroundImagePath: bgPath,
      backgroundVideoPath: bgVideoPath,
      clearBackgroundVideo: bgVideoPath == null,
      presentationId: preservePresentation
          ? state.presentationId
          : view['presentationId'] as String? ?? const Uuid().v4(),
      revealEpoch: state.revealEpoch + 1,
    );

    _log('   UI State updated. Starting reveal...');
    revealNextItem();

    final audio = view['backgroundAudio'];
    if (audio is Map<String, dynamic>) {
      await _playBackgroundMusic(
        audio['audioId'].toString(),
        (audio['volume'] as num?)?.toDouble() ?? 1.0,
        true,
      );
    } else {
      // Музыки ноды/главы нет. Если ранее скрипт запускал `play_music`,
      // возобновляем этот трек после загрузки сохранения/возврате из редактора:
      // id+volume персистируются движком в сейве
      // (_internal_active_script_bgm_id/volume/loop).
      await _resumeScriptMusicFromState();
    }

    final timer = view['timer'];
    if (timer is Map<String, dynamic>) {
      _startTimer(
        (timer['duration'] as num).toDouble(),
        timer['defaultActionNodeId'].toString(),
      );
    }

    final transition = view['transition'] as String?;
    if (transition != null && transition.isNotEmpty) {
      await _paceScriptDelays();
      if (!mounted || _currentNodeId != nodeId) return;
      _log('🚀 Transition to: $transition');
      Future.microtask(() => loadNode(transition));
    }
  }

  Future<void> performAutosave() async {
    if (state.currentNode == null) return;
    try {
      final engine = _engine;
      if (engine == null) return;
      await _engineCall('performAutosave', engine.performAutosave);
      _ref.invalidate(saveSlotsProvider(_questId));
    } catch (e) {
      _log('⚠️ Autosave failed: $e');
    }
  }

  Future<bool> saveSlot(String slotName) async {
    final engine = _engine;
    if (engine == null) return false;
    try {
      final saved = await _engineCall(
        'saveSlot',
        () => engine.saveSlot(slotName),
      );
      if (saved == null) return false;
      _ref.invalidate(saveSlotsProvider(_questId));
      _emitPluginEventFireAndForget(
        'quest_save',
        payload: {
          'slot_id': slotName,
          'autosave': slotName == SaveGameService.autosaveId,
        },
        nodeId: _currentNodeId ?? '',
      );
      return true;
    } catch (e) {
      _log('⚠️ Save failed: $e');
      return false;
    }
  }

  Future<void> loadNode(String nodeId) async {
    _log(">>> START LOAD NODE: '$nodeId'");

    // Порядок контракта: transition (from→to) → node_exit (уходящей) →
    // node_enter (новой, может быть отменён) → дефолтная инициализация.
    final leftNodeId = _currentNodeId;
    if (leftNodeId != null && leftNodeId.isNotEmpty && leftNodeId != nodeId) {
      _emitPluginEventFireAndForget(
        'transition',
        payload: {'from': leftNodeId, 'to': nodeId},
        nodeId: leftNodeId,
      );
      _emitPluginEventFireAndForget(
        'node_exit',
        payload: {'node_id': leftNodeId},
        nodeId: leftNodeId,
      );
    }
    // UI айтемов живёт одну ноду; `screen` — модальный захват: он переживает
    // переход и снимается плагином (`mnd.ui.close`) или крестиком игрока.
    _plugins?.clearItemSurfaces();
    if (await _emitPluginEvent(
      'node_enter',
      payload: {'node_id': nodeId},
      nodeId: nodeId,
    )) {
      _log('🔌 node_enter отменён плагином: $nodeId');
      return;
    }

    _loadingNodeId = nodeId;
    _revealGeneration++;
    _revealSuspended = true;
    final loadedGen = _revealGeneration;
    _isRevealing = false;
    _revealRequested = false;
    _stopTimer();

    final isInitialLoad = state.currentNode == null;

    try {
      final engine = _engine;
      if (engine == null) throw Exception('Движок не инициализирован.');

      // До загрузки новой ноды отдаём то, что прошлая задержка придерживала,
      // и снимаем её pacing-оверлей: иначе промежуточные кадры ушедшей сцены
      // протекли бы в состояние этой.
      await _releasePacingHold();

      final view = await _engineCall(
        'loadNode: engine',
        () => engine.loadNode(nodeId),
      );
      if (view == null) {
        throw Exception('Нода «$nodeId» не найдена — квест повреждён.');
      }

      final pacingSteps = await _takePacingSteps();
      if (!_alive || _loadingNodeId != nodeId) return;
      await _drainAudio();
      await _syncStateFromEngine(holdPacing: pacingSteps.isNotEmpty);

      if (!_alive || _loadingNodeId != nodeId) return;

      // Кадр ДО первой задержки: wait в onNodeEnter не имеет права держать
      // splash — нода рисуется сразу, задержки доигрываются фоном.
      if (pacingSteps.isNotEmpty) await _applyPacingStep(pacingSteps.first);

      state = state.copyWith(
        isLoading: isInitialLoad,
        clearCurrentNode: isInitialLoad,
        revealedItems: const [],
        pinnedStacks: const [],
        dismissedStacks: const {},
      );

      await _applyNodeView(view);
      _armPendingTimers();
      if (pacingSteps.isNotEmpty) {
        unawaited(_paceNodeEnterInBackground(pacingSteps, nodeId));
      }
    } catch (e, stack) {
      _log('❌ CRITICAL ERROR in loadNode: $e\n$stack');
      _err(e, stack, 'loadNode($nodeId)');
      if (_alive) state = state.copyWith(isLoading: false, error: e.toString());
    } finally {
      _resumeReveal(loadedGen);
    }
  }

  /// Снять блокировку раскрытия, если загрузка этой же генерации завершилась.
  /// Страховка от заморозки: список новой ноды ставит `_applyNodeView`, а
  /// сюда приходим, когда нода не установлена вообще (отмена плагином,
  /// пустой view, исключение). Поколение сверяем, чтобы не снять блокировку,
  /// поднятую более свежей загрузкой.
  void _resumeReveal(int gen) {
    if (gen == _revealGeneration) _revealSuspended = false;
  }

  /// Игрок закрыл модальное окно тапом вне рамки. Это не команда движка:
  /// переменная видимости остаётся нетронутой, а блок «показать» (`visible`)
  /// окно вернёт — см. `PinnedStackLayer`.
  void dismissPinnedStack(String id) {
    if (state.dismissedStacks.contains(id)) return;
    state = state.copyWith(
      dismissedStacks: {...state.dismissedStacks, id},
    );
  }

  /// [fromPresentationId] — презентация, для которой собран виджет-источник
  /// шага. Уходящая сцена живёт в дереве всё время cross-fade (fade/page:
  /// 300–820 мс) и после того, как `loadNode` снял `_revealSuspended`: её
  /// таймеры догорают и зовут `onComplete` уже в новой ноде, съедая её айтем.
  /// Очередь обгоняет `wait_input`/`delay`, и нода показывается целиком сразу.
  /// Шаг из чужой презентации отбрасываем; шаги текущей (и `_applyNodeView`,
  /// который зовёт без тега) проходят как раньше.
  void revealNextItem({String? fromPresentationId}) {
    if (fromPresentationId != null &&
        fromPresentationId != state.presentationId) {
      return;
    }
    // Идёт смена ноды: цикл раскрытия имеет право запустить только
    // `_applyNodeView`, когда список новой ноды уже в state (#219).
    if (_revealSuspended) return;
    if (_isRevealing) {
      _revealRequested = true;
      return;
    }
    _isRevealing = true;
    final gen = _revealGeneration;
    Future.microtask(() async {
      try {
        do {
          _revealRequested = false;
          if (!_alive || gen != _revealGeneration) return;
          final engine = _engine;
          if (engine == null) return;
          // Нода, чей айтем собираемся взять: по ней трипwire различает
          // безобидный отброс ушедшей сцены и потерю ряда на экране (#219).
          final stepOwnerNodeId = _currentNodeId ?? '';

          final step = await _engineCall<NextItemStep?>(
            'revealNextItem: nextItem',
            () async {
              // Страховка на случай вызова мимо `_engineQueue` (виджеты,
              // TriggerPipeline): если движок уже ушёл на другую ноду, этот
              // цикл не имеет права брать у неё айтем.
              if (!_alive || gen != _revealGeneration) return null;
              _step('revealNextItem: nextItem');
              return engine.nextItem();
            },
          );
          if (step == null) return;

          if (step.isItem) {
            final ci = ContentItem.fromJson(step.item!);
            if (!_alive || gen != _revealGeneration) {
              _discardRevealedItem(ci.id, gen, stepOwnerNodeId);
              return;
            }
            await _paceScriptDelays();
            if (!_alive || gen != _revealGeneration) {
              _discardRevealedItem(ci.id, gen, stepOwnerNodeId);
              return;
            }
            state = ci.isPinnedStack
                ? state.copyWith(pinnedStacks: [...state.pinnedStacks, ci])
                : state.copyWith(revealedItems: [...state.revealedItems, ci]);
            await _drainAudio();
            await _syncStateFromEngine();
            _emitPluginEventFireAndForget(
              'item_reveal',
              payload: {
                'node_id': _currentNodeId ?? '',
                'item_id': ci.id,
                'item_json': ci.toJson(),
              },
              nodeId: _currentNodeId ?? '',
            );
            continue;
          } else if (step.isTransition) {
            final target = step.node!;
            if (target.isNotEmpty) {
              await _paceScriptDelays();
              if (!_alive || gen != _revealGeneration) {
                _log('⚠️ Переход → $target отброшен: поколение $gen больше не '
                    'текущее (${_revealGeneration}, alive=$_alive)');
                return;
              }
              loadNode(target);
              return;
            }
            continue;
          } else {
            return;
          }
        } while (_revealRequested);
      } catch (e, stack) {
        if (gen == _revealGeneration) {
          _log('❌ revealNextItem error: $e');
          _err(e, stack, 'revealNextItem');
        }
      } finally {
        if (gen == _revealGeneration) {
          _isRevealing = false;
          if (_revealRequested && _alive) revealNextItem();
        }
      }
    });
  }

  /// Движок уже выдал айтем (`revealed_count` увеличен), а показывать его
  /// некому — поколение сменилось. Если айтем принадлежит ноде, которая
  /// сейчас на экране, это ровно #219: ряд потерян, и запись уходит в
  /// crash_log. Отброс ушедшей сцены безобиден — только консоль.
  void _discardRevealedItem(String itemId, int gen, String ownerNodeId) {
    final current = _currentNodeId ?? '';
    final msg = 'Reveal-цикл поколения $gen съел айтем $itemId ноды '
        '$ownerNodeId, а сейчас нода $current, поколение '
        '$_revealGeneration, alive=$_alive';
    _log('⚠️ $msg');
    if (ownerNodeId == current) _err(StateError(msg), null, 'revealDiscard');
  }

  Future<String?> handleInteraction(ContentItem item, String triggerRef) async {
    try {
      final engine = _engine;
      if (engine == null) return null;
      _step('handleInteraction');
      // item_press — до обработки нажатия: записанные плагином переменные
      // движок должен увидеть в этом же шаге, поэтому ждём (без подписчиков
      // _emitPluginEvent не дёргает FFI вообще).
      await _emitPluginEvent(
        'item_press',
        payload: {
          'node_id': _currentNodeId ?? '',
          'item_id': item.id,
          'trigger': triggerRef,
        },
        nodeId: _currentNodeId ?? '',
      );
      final next = await _engineCall(
        'handleInteraction: engine',
        () => engine.handleInteraction(item.toJson(), triggerRef),
      );
      await _paceScriptDelays();
      if (!_alive) return null;
      await _drainAudio();
      await _syncStateFromEngine();
      return next;
    } catch (e, stack) {
      _err(e, stack, 'handleInteraction($triggerRef)');
      return null;
    }
  }

  Future<String?> resolveTarget(String rawTarget) async {
    final engine = _engine;
    if (engine == null) return null;
    return await _engineCall(
      'resolveTarget',
      () => engine.resolveTarget(rawTarget),
    );
  }

  // -------------------------------------------------------------------------
  // Timer
  // -------------------------------------------------------------------------

  void _startTimer(double duration, String defaultActionNodeId) {
    _stopTimer();
    if (duration < 0.1) duration = 0.1;
    // Держим autoDispose countdown-провайдер живым на всё время тиканья:
    // при скрытом таймере (timerHidden) виджет-слушатель отсутствует.
    // Ref.listen создаёт provider-зависимость (учитывается в hasListeners),
    // что удерживает провайдер от autoDispose; close() в _stopTimer.
    _countdownKeepAlive = _ref.listen<GameCountdownData?>(
      gameCountdownProvider(sessionKey),
      (_, __) {},
    );
    final countdown = _ref.read(gameCountdownProvider(sessionKey).notifier);
    countdown.start(duration);
    _countdownTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (!_alive) {
        timer.cancel();
        return;
      }
      final current = _ref.read(gameCountdownProvider(sessionKey));
      final newTime = (current?.remainingSeconds ?? 0) - 0.1;
      if (newTime > 0) {
        _ref.read(gameCountdownProvider(sessionKey).notifier).tick(newTime);
      } else {
        _log('⏰ Timer finished! Going to: $defaultActionNodeId');
        timer.cancel();
        loadNode(defaultActionNodeId);
      }
    });
  }

  void _stopTimer() {
    if (_countdownTimer?.isActive ?? false) _countdownTimer?.cancel();
    // Отпускаем keep-alive: провайдер может диспоузиться, когда таймер
    // больше не идёт (состояние countdown больше не нужно).
    _countdownKeepAlive?.close();
    _countdownKeepAlive = null;
    // Во время dispose контейнера (например, в тестах) _ref.read уже
    // недоступен — сбрасываем countdown тихо.
    try {
      _ref.read(gameCountdownProvider(sessionKey).notifier).stop();
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Audio playback
  // -------------------------------------------------------------------------

  Future<void> _playSoundEffect(String audioId, double volume) async {
    if (_isAudioBroken) return;
    try {
      final normalizedId = _normalizeBackgroundAudioId(audioId);
      final fullPath = await QuestImageSource.resolveOnDisk(
        _questId,
        normalizedId,
      );
      if (fullPath.isNotEmpty) {
        await _soundEffectPlayer.stop();
        final globalVol = _ref.read(globalAudioVolumeProvider);
        await _soundEffectPlayer.setVolume(
          (volume * globalVol).clamp(0.0, 1.0),
        );
        await _soundEffectPlayer.play(DeviceFileSource(fullPath));
      }
    } catch (e) {
      _log('Sound effect error: $e');
    }
  }

  void _stopSoundEffect(String target) {
    if (_isAudioBroken) return;
    try {
      if (target == 'all') {
        _soundEffectPlayer.stop();
        _backgroundAudioPlayer.stop();
        _currentBackgroundAudioId = null;
        _isMusicPaused = false;
        _mutedByVolume = false;
        // stop_sound all глушит и музыку: после загрузки сейва её возобновлять
        // не надо (автор явно всё остановил).
        _ref
            .read(gameStateProvider.notifier)
            .setVariable('_internal_active_script_bgm_id', null);
      } else {
        _soundEffectPlayer.stop();
      }
    } catch (e) {
      _log('Stop sound error: $e');
    }
  }

  /// Итоговая громкость фоновой музыки: сам трек × множители сессии (блоки
  /// `set_volume` для главы и для контента ноды) × ползунок игрока.
  ///
  /// Формула одна на все пути. Раньше вход в ноду умножал только на ползунок,
  /// а `_applyBackgroundVolumeFromState` — только на множители и вовсе без
  /// громкости трека: переход по ноде сбрасывал `set_volume`, а любая смена
  /// громкости — громкость самой ноды.
  double _bgmVolume([double? trackVolume]) {
    final vars = _ref.read(gameStateProvider).variables;
    final tagVolume = (vars['_internal_tag_volume'] as num?)?.toDouble() ?? 1.0;
    final contentVolume =
        (vars['_internal_node_content_volume'] as num?)?.toDouble() ?? 1.0;
    final globalVolume = _ref.read(globalAudioVolumeProvider);
    return ((trackVolume ?? _backgroundTrackVolume) *
            tagVolume *
            contentVolume *
            globalVolume)
        .clamp(0.0, 1.0);
  }

  Future<void> _playBackgroundMusic(
    String audioId,
    double volume,
    bool loop,
  ) async {
    if (_isAudioBroken) return;
    try {
      final normalizedId = _normalizeBackgroundAudioId(audioId);
      _backgroundTrackVolume = volume;
      final effectiveVol = _bgmVolume(volume);
      if (_currentBackgroundAudioId == normalizedId &&
          _backgroundAudioPlayer.state == PlayerState.playing) {
        await _backgroundAudioPlayer.setVolume(effectiveVol);
        return;
      }
      await _backgroundAudioPlayer.setReleaseMode(
        loop ? ReleaseMode.loop : ReleaseMode.stop,
      );
      // Идентичность трека — по нормализованному id, а файл ищем резолвером:
      // блок play_music может дать имя из библиотеки или uuid, а не путь.
      final fullPath = await QuestImageSource.resolveOnDisk(
        _questId,
        normalizedId,
      );
      if (fullPath.isNotEmpty) {
        _currentBackgroundAudioId = normalizedId;
        _isMusicPaused = false;
        _mutedByVolume = false;
        await _backgroundAudioPlayer.stop();
        await _backgroundAudioPlayer.setVolume(effectiveVol);
        await _backgroundAudioPlayer.play(DeviceFileSource(fullPath));
      }
    } catch (e) {
      _log('Background music error: $e');
    }
  }

  /// Возобновить скриптовую музыку из gameState после загрузки сохранения.
  ///
  /// Движок пишет id/громкость/loop последнего `play_music` в
  /// `_internal_active_script_bgm_*` (попадают в сейв и восстанавливаются в
  /// переменные). Вызывается, когда на ноде нет своей/главовой музыки:
  /// скриптовый трек продолжает играть как до сохранения.
  Future<void> _resumeScriptMusicFromState() async {
    if (_isAudioBroken) return;
    try {
      final vars = _ref.read(gameStateProvider).variables;
      final id = vars['_internal_active_script_bgm_id']?.toString();
      if (id == null || id.isEmpty) {
        // Скриптовая музыка не была запущена (или остановлена stop_music) —
        // но если что-то играло, а в сейве пусто, значит трек был остановлен:
        // глушим (сейв «знает лучше»).
        if (_currentBackgroundAudioId != null) {
          _stopBackgroundMusic();
        }
        return;
      }
      // Ещё играет тот же трек (например, возврат из редактора) — не рестартуем.
      final normalizedId = _normalizeBackgroundAudioId(id);
      if (_currentBackgroundAudioId == normalizedId &&
          _backgroundAudioPlayer.state == PlayerState.playing) {
        return;
      }
      final volume =
          (vars['_internal_active_script_bgm_volume'] as num?)?.toDouble() ??
          1.0;
      final loop =
          vars['_internal_active_script_bgm_loop']?.toString() != 'false';
      await _playBackgroundMusic(id, volume, loop);
    } catch (e) {
      _log('Resume script music error: $e');
    }
  }

  void _stopBackgroundMusic() {
    if (_isAudioBroken) return;
    try {
      _backgroundAudioPlayer.stop();
      _currentBackgroundAudioId = null;
      _isMusicPaused = false;
      _mutedByVolume = false;
    } catch (e) {
      _log('Stop music error: $e');
    }
  }

  void _pauseResumeAudio(String target, String action) {
    if (_isAudioBroken) return;
    try {
      final shouldPause =
          action == 'pause' || (action == 'toggle' && !_isMusicPaused);
      final shouldResume =
          action == 'resume' || (action == 'toggle' && _isMusicPaused);
      if (target == 'all' || target == 'music') {
        if (shouldPause) {
          _backgroundAudioPlayer.pause();
          _isMusicPaused = true;
        } else if (shouldResume) {
          _backgroundAudioPlayer.resume();
          _isMusicPaused = false;
        }
      }
      if (target == 'all' || target == 'sound') {
        if (shouldPause)
          _soundEffectPlayer.pause();
        else if (shouldResume)
          _soundEffectPlayer.resume();
      }
    } catch (e) {
      _log('Pause/resume error: $e');
    }
  }

  Future<void> _crossfadeOut(int durationMs) async {
    if (_isAudioBroken) return;
    final from = _bgmVolume();
    try {
      final steps = 20;
      final stepDuration = Duration(milliseconds: (durationMs / steps).round());
      for (int i = 0; i <= steps; i++) {
        await _backgroundAudioPlayer.setVolume(
          ((1.0 - (i / steps)) * from).clamp(0.0, 1.0),
        );
        await Future.delayed(stepDuration);
      }
    } catch (e) {
      _log('Crossfade fade-out error: $e');
    }
  }

  Future<void> _crossfadeIn(int durationMs) async {
    if (_isAudioBroken) return;
    final to = _bgmVolume();
    try {
      final steps = 20;
      final stepDuration = Duration(milliseconds: (durationMs / steps).round());
      for (int i = 0; i <= steps; i++) {
        await _backgroundAudioPlayer.setVolume(
          ((i / steps) * to).clamp(0.0, 1.0),
        );
        await Future.delayed(stepDuration);
      }
    } catch (e) {
      _log('Crossfade fade-in error: $e');
    }
  }

  Future<void> _applyBackgroundVolumeFromState() async {
    if (_isAudioBroken) return;
    try {
      final clamped = _bgmVolume();
      if (_currentBackgroundAudioId == null) return;
      if (clamped <= 0.0001) {
        // Mute: пауза, а не stop — иначе после размьюта трек не возобновить
        // (позиция теряется, а скриптовые команды уже отработали).
        if (_backgroundAudioPlayer.state == PlayerState.playing) {
          await _backgroundAudioPlayer.pause();
          _mutedByVolume = true;
        }
        return;
      }
      if (_mutedByVolume) {
        // Размьют: возвращаем трек, который мы сами приглушили.
        // Скриптовая пауза (_isMusicPaused) здесь не трогается.
        _mutedByVolume = false;
        await _backgroundAudioPlayer.setVolume(clamped);
        if (!_isMusicPaused) await _backgroundAudioPlayer.resume();
        return;
      }
      await _backgroundAudioPlayer.setVolume(clamped);
    } catch (e) {
      _log('Audio volume error: $e');
    }
  }

  Future<void> _applyGlobalVolumeToPlayers() async {
    // Фоновая музыка: пере-применяем громкость с новым глобальным множителем
    // (внутри также обрабатывается mute/unmute через pause/resume).
    await _applyBackgroundVolumeFromState();
    // Короткие эффекты не обновляем — живут секунды, следующий запуск
    // умножит на актуальную громкость. Инлайн-аудио контента слушает
    // globalAudioVolumeProvider сам (_AudioItemPlayer, listenManual).
  }

  // -------------------------------------------------------------------------
  // Dispose
  // -------------------------------------------------------------------------

  @override
  void dispose() {
    if (kDebugMode) {
      final st = StackTrace.current.toString().split('\n').take(14).join('\n');
      // print даёт одну строку — режем, но оставляем читаемость.
      print(
        '🎮 [GameScreen] DISPOSING GAME SCREEN. session=$sessionKey quest=$_questId currentNode=$_currentNodeId engine=${_engine?.handle} hash=${hashCode} alive=$mounted sessionActive=$_sessionActive\nStack:\n$st',
      );
    }
    _hooks.onStep?.call('dispose: $sessionKey');
    try {
      try {
        // disable() на Linux — это DBus-вызов Close по request-объекту
        // xdg-desktop-portal, а портал успевает закрыть его сам. Ошибка
        // прилетает в асинхронной паузе, поэтому внешний try её не видит:
        // без catchError выход из ноды давал UNCAUGHT ERROR и crash_log.
        unawaited(WakelockPlus.disable().catchError((Object _) {}));
      } catch (_) {}
      _stopTimer();
      _contentReloadDebounce?.cancel();
      _hooks.unlistenContentChanges?.call(_questId, _onQuestContentChanged);
      _gameStateSub?.close();
      _backgroundPlayerStateSub?.cancel();
      _soundEffectPlayerStateSub?.cancel();
      _backgroundAudioPlayer.stop();
      _soundEffectPlayer.stop();
      _backgroundAudioPlayer.dispose();
      _soundEffectPlayer.dispose();
      _disposeEngine();
      _plugins?.dispose();
      _plugins = null;
      unawaited(_pluginToasts.close());
    } catch (e, stack) {
      _log('⚠️ Dispose warning: $e\n$stack');
    }
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Хуки по умолчанию (пустые). main_app переопределяет этот провайдер в
/// корневом ProviderScope — тогда единый [gameScreenProvider] автоматически
/// использует app-сервисы, и виджеты (HUD, контент, таймер) обращаются
/// к тому же нотификатору, что и экран.
final gameScreenHooksProvider = Provider<GameScreenHooks>((ref) {
  return GameScreenHooks.empty;
});

final gameScreenProvider = StateNotifierProvider.autoDispose
    .family<GameScreenNotifier, GameScreenState, GameSessionKey>((ref, key) {
      return GameScreenNotifier(
        ref,
        key.questId,
        sessionKey: '${key.questId}::${key.docKey}',
        hooks: ref.watch(gameScreenHooksProvider),
      );
    });
