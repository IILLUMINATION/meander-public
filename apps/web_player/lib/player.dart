/// Игровой цикл веб-плеера: движок в wasm + состояние, которое видит UI.
///
/// Контракт скопирован с нативного `GameScreenNotifier` (`mnd_player`), потому
/// что цель — идентичное поведение: тот же порядок событий, та же очередь
/// раскрытия, то же пейсинг-«придержание» значений вокруг `wait`. Отличия
/// два, и оба диктованы браузером:
///
///  * состояние квеста живёт в движке, аFS-хранилища нет — картинку и текст
///    клиент берёт из `QuestBundle` (байты архива в памяти);
///  * нет Riverpod/`gameStateProvider`: вместо него этот класс держит зеркало
///    переменных (`variables`) и зовёт `notifyListeners()`, поэтому текстовые
///    виджеты пересобираются на каждую мутацию движка, как в приложении.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:mnd_core/engine/game_engine.dart';
import 'package:mnd_core/engine/item_image_source.dart';
import 'package:mnd_core/engine/item_visibility.dart';
import 'package:mnd_core/engine/script_executor.dart';
import 'package:mnd_core/models/content_item.dart';
import 'package:mnd_core/models/saved_node.dart';
import 'package:mnd_core/models/value_format.dart';
import 'package:mnd_core/rust_bootstrap.dart';
import 'package:url_launcher/url_launcher.dart';

import 'quest_bundle.dart';

/// Нода ещё не выбрана, квест грузится.
enum PlayPhase { loading, playing, failed }

class QuestPlayer extends ChangeNotifier {
  QuestPlayer(this.bundle);

  final QuestBundle bundle;

  MeanderGameEngine? _engine;

  PlayPhase phase = PlayPhase.loading;
  String? errorMessage;

  SavedNode? node;
  String? get nodeId => node?.id;

  /// Поколение сцены: растёт на каждом входе в ноду. UI использует его в
  /// ключах виджетов, чтобы повторный вход в ту же ноду не переиспользовал
  /// состояние анимаций (нативный `presentationId`).
  int get presentationId => _gen;

  /// Раскрытые айтемы текущей ноды (в порядке `next_item`).
  List<ContentItem> revealed = const [];

  /// Закреплённые стеки (`stack` с `stackPin`): живут поверх сцены.
  List<ContentItem> pinned = const [];

  /// Стеки, которые игрок закрыл тапом вне рамки. Жёст-игрока, а не команда
  /// движка — поэтому живёт на клиенте и сбрасывается при смене ноды.
  final Set<String> dismissedStacks = {};

  void dismissPinnedStack(String id) {
    if (dismissedStacks.contains(id)) return;
    dismissedStacks.add(id);
    _safeNotify();
  }

  /// Плашка ошибки в UI: игрок закрыл её сам, движение не трогаем.
  void clearError() {
    if (errorMessage == null) return;
    errorMessage = null;
    _safeNotify();
  }

  /// Синхронный FFI (`evaluate`, `resolveTarget`, `evaluateVisibility`) идёт
  /// из главного потока браузера, а async-шаги движок исполняет на worker-потоке
  /// Rust и держит при этом мьютекс движка. Если пересборка сцены попала на
  /// такой шаг, `lock()` паркуется через `Atomics.wait` — а главному потоку это
  /// запрещено, и вызов выстреливает `EXECUTE_SYNC_ABORT`.
  ///
  /// Это не битая формула, а минутное «ядро занято»: даём очереди движка
  /// доработать, зовём `_safeNotify()` и пересчитываем кадр. Если же ни одна
  /// попытка не увенчалась (браузер не отдаёт синхронный FFI в принципе), после
  /// нескольких раундов отстаиваемся совсем — иначе каждый кадр сборки сцены
  /// строил бы JS-стектрейс.
  void _noteSyncBlocked(Object error, [String expression = '']) {
    final text = '$error';
    if (!text.contains('EXECUTE_SYNC_ABORT') &&
        !text.contains('Atomics.wait')) {
      // Обычная опечатка автора в формуле: текст показываем как есть, но
      // под счётчик раундов она не попадает.
      return;
    }
    if (_syncGivenUp || _syncRetryScheduled) return;
    _syncBlockedRounds++;
    if (_syncBlockedRounds >= _kSyncRoundsBeforeGiveUp) {
      _syncGivenUp = true;
      debugPrint(
        '[web-player] синхронный FFI не отвечает ни в одном раунде — формулы '
        'больше не зовём, текст показываем как есть. Последняя формула: '
        '«$expression». Причина: ${text.split('\n').first}',
      );
      return;
    }
    _syncRetryScheduled = true;
    debugPrint(
      '[web-player] синхронный FFI упёрся в занятое ядро (раунд '
      '$_syncBlockedRounds), повторю после очереди. Формула: «$expression»',
    );
    unawaited(_retrySyncAfterCore());
  }

  Future<void> _retrySyncAfterCore() async {
    try {
      await _queue;
    } catch (_) {
      // Очередь свои ошибки уже логирует; здесь нам важен только факт,
      // что движок больше ничего не считает.
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _syncRetryScheduled = false;
    _safeNotify();
  }

  /// Синхронный вызов прошёл — значит отказами это было временное наложение,
  /// счётчик раундов обнуляем.
  void _noteSyncOk() {
    _syncBlockedRounds = 0;
  }

  bool get _syncUsable => !_syncGivenUp;

  /// Зеркало переменных движка — нужно чистым хелперам видимости и картинки
  /// (`engineVisibilityOf`, `itemSourceOverride`), которые работают по карте
  /// значений, а не по живому движку.
  Map<String, dynamic> variables = const {};

  /// Музыка/звуки текущей сцены. Браузер разрешает запуск только после
  /// действия игрока, поэтому ошибки autoplay глушим в лог, а не в сцену.
  AudioPlayer? _musicPlayer;
  final Map<String, AudioPlayer> _soundPlayers = {};

  String? backgroundImageId;
  String? backgroundAudioId;
  Color? backgroundColor;

  int _gen = 0;
  bool _revealing = false;
  bool _revealRequested = false;
  bool _revealSuspended = true;

  /// Синхронный FFI (`evaluate`, `resolveTarget`, `evaluateVisibility`) в
  /// браузере может упереться в занятое ядро — см. [_noteSyncBlocked].
  int _syncBlockedRounds = 0;
  bool _syncRetryScheduled = false;
  bool _syncGivenUp = false;
  static const int _kSyncRoundsBeforeGiveUp = 5;
  Map<String, dynamic> _heldVars = const {};
  final Set<String> _armedTimers = {};
  final List<Timer> _timers = [];
  Future<void> _queue = Future<void>.value();

  bool get isReady => _engine != null && _engine!.isDisposed == false;

  // ---------------------------------------------------------------------------
  // Запуск
  // ---------------------------------------------------------------------------

  Future<void> start({String? startNodeId}) async {
    try {
      await initRustCore();
      // Повторный вызов — это «попробовать снова» после падения: старый
      // движок обязан освободиться, иначе handle останется в реестре навсегда.
      _engine?.dispose();
      _engine = await MeanderGameEngine.create(
        questId: bundle.questId,
        platformOs: 'web',
        isWeb: true,
        config: bundle.config,
        nodesJson: bundle.nodesJson,
        templates: bundle.templates,
        embeddedScripts: bundle.embeddedScripts,
      );
      final view = await _engine!.startNew(startNodeId: startNodeId);
      if (view == null) {
        throw StateError('У квеста нет стартовой ноды — пустой nodes.json.');
      }
      await _openNode(view);
    } catch (e, stack) {
      debugPrint('[web-player] start failed: $e\n$stack');
      phase = PlayPhase.failed;
      errorMessage = _explainWebFailure('$e');
      _safeNotify();
    }
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _engine?.dispose();
    _engine = null;
    for (final p in _soundPlayers.values) {
      p.dispose();
    }
    _soundPlayers.clear();
    _musicPlayer?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Переходы
  // ---------------------------------------------------------------------------

  Future<void> loadNode(String id) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      final view = await _call('loadNode', () => engine.loadNode(id));
      if (view == null) {
        throw StateError('Нода «$id» не найдена — квест повреждён.');
      }
      await _openNode(view);
    } catch (e, stack) {
      debugPrint('[web-player] loadNode($id) failed: $e\n$stack');
      errorMessage = '$e';
      phase = PlayPhase.failed;
      _safeNotify();
    }
  }

  /// Кадр до первой задержки + фон + очередь раскрытия. Порядок — как в
  /// `_applyNodeView`: список ставится синхронно с снятием блокировки, иначе
  /// чужой `onComplete` съедает первый айтем новой ноды (#219).
  Future<void> _openNode(Map<String, dynamic> view) async {
    final engine = _engine!;
    _gen++;
    final gen = _gen;

    _releaseTimers();
    _heldVars = const {};
    engine.restoreAfterPacing();

    final rawNode = view['node'];
    node = rawNode is Map<String, dynamic>
        ? SavedNode.fromJson(rawNode)
        : SavedNode.fromJson({
            'id': view['nodeId'] as String? ?? '',
            'title': view['title'] as String? ?? '',
            'content': const <String, dynamic>{'items': <dynamic>[]},
          });
    revealed = const [];
    pinned = const [];
    dismissedStacks.clear();
    backgroundImageId = (view['backgroundImageId'] as String?)?.ifEmptyOrNull;
    backgroundAudioId = ((view['backgroundAudio'] as Map?)?['audioId'])
        ?.toString()
        .ifEmptyOrNull;
    backgroundColor = node?.color == null ? null : Color(node!.color!);
    final bgAudio = view['backgroundAudio'];
    if (bgAudio is Map) {
      final id = bgAudio['audioId']?.toString();
      if (id != null && id.isNotEmpty) {
        unawaited(
          _playMusic(id, (bgAudio['volume'] as num?)?.toDouble() ?? 1.0, true),
        );
      }
    } else {
      unawaited(_stopMusic());
    }
    phase = PlayPhase.playing;
    errorMessage = null;
    _revealSuspended = false;
    _safeNotify();

    await _drainAudio();
    await _drainExternal();

    final pacingSteps = await _call('takePacingSteps', engine.drainDelaySteps);
    if (gen != _gen) return;
    await _syncState(holdPacing: pacingSteps.isNotEmpty);
    if (gen != _gen) return;
    _armPendingTimers();

    if (pacingSteps.isNotEmpty) {
      // Первый кадр задержки уже отражён в сцене; остальные доигрывает фон.
      unawaited(_paceInBackground(pacingSteps, gen));
    }

    final timer = view['timer'];
    if (timer is Map<String, dynamic>) {
      _startNodeTimer(
        (timer['duration'] as num?)?.toDouble() ?? 0,
        timer['defaultActionNodeId']?.toString() ?? '',
      );
    }

    revealNext();

    final transition = view['transition'] as String?;
    if (transition != null && transition.isNotEmpty) {
      await _paceScriptDelays();
      if (gen != _gen) return;
      unawaited(loadNode(transition));
    }
  }

  // ---------------------------------------------------------------------------
  // Очередь раскрытия
  // ---------------------------------------------------------------------------

  /// Следующий айтем. Вызывается и из `_openNode`, и из `onComplete` виджета
  /// (как в нативном плеере): айтем без анимации отдаёт шаг на следующем
  /// кадре, «самостоятельный» (аудио/таймер/видео) — когда отработает.
  void revealNext() {
    if (_revealSuspended) return;
    if (_revealing) {
      _revealRequested = true;
      return;
    }
    _revealing = true;
    final gen = _gen;
    Future.microtask(() async {
      final engine = _engine;
      if (engine == null) return;
      try {
        do {
          _revealRequested = false;
          if (gen != _gen) return;
          final step = await _call('nextItem', engine.nextItem);
          if (gen != _gen) {
            if (step.isItem) {
              debugPrint(
                '[web-player] айтем ${step.item?['id']} съеден ушедшим '
                'поколением $gen',
              );
            }
            return;
          }
          if (step.isItem) {
            final item = ContentItem.fromJson(step.item!);
            if (item.isPinnedStack) {
              pinned = [...pinned, item];
            } else {
              revealed = [...revealed, item];
            }
            await _call('drainAudio', engine.drainAudio);
            await _syncState();
            _safeNotify();
            continue;
          }
          if (step.isTransition) {
            final target = step.node ?? '';
            if (target.isEmpty) continue;
            await _paceScriptDelays();
            if (gen != _gen) return;
            unawaited(loadNode(target));
            return;
          }
          return;
        } while (_revealRequested);
      } catch (e, stack) {
        if (gen == _gen) {
          debugPrint('[web-player] reveal failed: $e\n$stack');
          errorMessage = '$e';
          _safeNotify();
        }
      } finally {
        if (gen == _gen) {
          _revealing = false;
          if (_revealRequested) revealNext();
        }
      }
    });
  }

  /// «Скрыть»/«убрать» до того, как айтем собрался: шаг очереди отдаём сами,
  /// иначе раскрытие встаёт на пустом месте (нативный `_skipRevealStep`).
  void skipRevealStep() {
    if (_revealSuspended) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => revealNext());
  }

  // ---------------------------------------------------------------------------
  // Взаимодействие
  // ---------------------------------------------------------------------------

  Future<void> tapItem(ContentItem item) async {
    final engine = _engine;
    if (engine == null) return;
    final triggerRef =
        item.scriptForEvent(item.type == 'input' ? 'onSubmit' : 'onPress') ??
        item.scriptForEvent('onPress');
    // Хлебные крошечки: в браузере «нажатие не работает» — это три разных
    // случая (не дошёл тап, у айтема нет ни скрипта ни цели, движок ошибся).
    debugPrint(
      '[web-player] tap ${item.type}/${item.id} '
      'trigger=${triggerRef ?? 'none'} target=${item.targetNodeId ?? 'none'}',
    );
    try {
      if (triggerRef != null) {
        final next = await _call(
          'handleInteraction',
          () => engine.handleInteraction(item.toJson(), triggerRef),
        );
        await _afterEngineStep();
        debugPrint('[web-player] tap ${item.id} → ${next ?? 'без перехода'}');
        if (next != null && next.isNotEmpty) {
          await loadNode(next);
          return;
        }
      }
      final target = item.targetNodeId;
      if (target != null && target.isNotEmpty) {
        final resolved = await _call(
          'resolveTarget',
          () => engine.resolveTarget(target),
        );
        if (resolved == null || resolved.isEmpty) return;
        await loadNode(resolved);
      } else {
        // Ни скрипта, ни цели: DecoratedBox с onTap=null — тап есть, действия
        // нет. Молча: у декоративных кнопок это норма, а не поломка.
        debugPrint('[web-player] tap ${item.id}: не на что отвечать');
      }
    } catch (e, stack) {
      debugPrint('[web-player] tap(${item.id}) failed: $e\n$stack');
      errorMessage = '$e';
      _safeNotify();
    }
  }

  /// Отправка поля ввода: значение уходит в движок как переменная, затем
  /// отрабатывает `onSubmit`-скрипт и переход, если они навешаны.
  Future<void> submitInput(ContentItem item, String value) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      final name = item.variableName;
      if (name != null && name.isNotEmpty) {
        engine.setStateVariable(name, value);
        final pending = engine.takePendingTransition();
        if (pending != null && pending.isNotEmpty) {
          await loadNodeByTarget(pending);
          return;
        }
      }
      final trigger = item.scriptForEvent('onSubmit');
      String? next;
      if (trigger != null) {
        next = await _call(
          'handleInteraction',
          () => engine.handleInteraction(item.toJson(), trigger),
        );
      }
      await _afterEngineStep();
      if (next == null || next.isEmpty) {
        next = item.targetNodeId;
      }
      if (next != null && next.isNotEmpty) {
        final resolved = await _call(
          'resolveTarget',
          () => engine.resolveTarget(next!),
        );
        if (resolved != null && resolved.isNotEmpty) await loadNode(resolved);
      }
    } catch (e, stack) {
      debugPrint('[web-player] submit(${item.id}) failed: $e\n$stack');
      errorMessage = '$e';
      _safeNotify();
    }
  }

  /// Поведение ребёнка ряда/колонки/стека: ядро исполняет `next_item` только
  /// для верхнего уровня, детей прогоняем здесь (нативный
  /// `GameContainerWidget._runChildAppearScripts`). Возвращает ноду для
  /// перехода, если скрипт ребёнка её задал.
  Future<String?> childAppearResult(ContentItem child) async {
    final engine = _engine;
    if (engine == null) return null;
    if (child.isHidden || child.scriptForEvent('onAppear') == null) return null;
    try {
      final next = await _call(
        'executeBehaviour',
        () => engine.executeBehaviour(child.toJson(), 'onReveal'),
      );
      await _afterEngineStep();
      return next;
    } catch (e) {
      debugPrint('[web-player] child onAppear(${child.id}) failed: $e');
      return null;
    }
  }

  /// Первый проход условия `onAppear`: разрешает запись (условие могло
  /// posчитать и сохранить значение), как `allowMutation: true` в нативном
  /// `ConditionalContentWrapper`.
  bool evaluateAppearOnce(ContentItem item) {
    final engine = _engine;
    if (engine == null) return true;
    try {
      return engine.evaluateVisibility(item.toJson(), allowMutation: true);
    } catch (_) {
      return true;
    }
  }

  /// Переход по «сырой» цели: движок понимает и id ноды, и её заголовок, и
  /// выражение с переменной — клиент не угадывает сам.
  Future<void> loadNodeByTarget(String rawTarget) async {
    final engine = _engine;
    if (engine == null) return;
    final resolved = await _call(
      'resolveTarget',
      () => engine.resolveTarget(rawTarget),
    );
    if (resolved == null || resolved.isEmpty) return;
    await loadNode(resolved);
  }

  /// Кнопка модалки со своим скриптом: `resourceId`/путь → путь в `scripts/`,
  /// затем то же `onPress`, что выполняет нативный `_executeScriptForButton`.
  Future<void> runScriptById(String scriptAssetId) async {
    final engine = _engine;
    final path = resolveScriptPath(scriptAssetId);
    if (engine == null || path == null) {
      debugPrint('[web-player] скрипт не найден: $scriptAssetId');
      return;
    }
    final item = ContentItem(
      id: 'modal_btn',
      type: 'button',
      behaviours: [ContentTrigger(event: 'onPress', script: path)],
    );
    try {
      final next = await _call(
        'handleInteraction',
        () => engine.handleInteraction(item.toJson(), path),
      );
      await _afterEngineStep();
      if (next != null && next.isNotEmpty) await loadNode(next);
    } catch (e) {
      debugPrint('[web-player] runScriptById($scriptAssetId) failed: $e');
    }
  }

  /// Три те же формы, что у нативного резолвера модалки: путь как есть,
  /// `scripts/<id>.json`, `_internal_scripts/<id>.json`. «Диск» здесь — карта
  /// скриптов бандла, поэтому проверка дешёвая и детерминированная.
  String? resolveScriptPath(String raw) {
    final normalized = raw.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) return null;
    if (bundle.embeddedScripts.containsKey(normalized)) return normalized;
    if (!normalized.endsWith('.json') && !normalized.contains('/')) {
      for (final dir in const ['scripts', '_internal_scripts']) {
        final candidate = '$dir/$normalized.json';
        if (bundle.embeddedScripts.containsKey(candidate)) return candidate;
      }
    }
    return null;
  }

  Future<void> _drainAudio() async {
    final engine = _engine;
    if (engine == null) return;
    final cmd = await _call('drainAudio', engine.drainAudio);
    final commands = cmd['commands'] as List? ?? const [];
    for (final raw in commands) {
      if (raw is! Map) continue;
      final c = Map<String, dynamic>.from(raw);
      final type = c['type']?.toString() ?? '';
      switch (type) {
        case 'playSound':
          await _playSound(
            c['id']?.toString() ?? '',
            (c['volume'] as num?)?.toDouble() ?? 1.0,
          );
        case 'stopSound':
          await _stopSound(c['target']?.toString() ?? '');
        case 'playMusic':
          await _playMusic(
            c['id']?.toString() ?? '',
            (c['volume'] as num?)?.toDouble() ?? 1.0,
            c['loop'] as bool? ?? true,
          );
        case 'stopMusic':
          await _stopMusic();
        case 'pauseResume':
          await _pauseResumeAudio(
            c['target']?.toString() ?? '',
            c['action']?.toString() ?? '',
          );
      }
    }
  }

  Future<AudioPlayer?> _audioFor(String id, {bool music = false}) async {
    final bytes = bundle.assetBytes(id);
    if (bytes == null || bytes.isEmpty) {
      debugPrint('[web-player] аудио не найдено: $id');
      return null;
    }
    final player = music
        ? (_musicPlayer ??= AudioPlayer())
        : (_soundPlayers[id] ??= AudioPlayer());
    try {
      await player.stop();
      await player.setReleaseMode(
        music ? ReleaseMode.loop : ReleaseMode.release,
      );
      await player.play(BytesSource(bytes));
      return player;
    } catch (e) {
      debugPrint('[web-player] аудио $id не запустилось: $e');
      return null;
    }
  }

  Future<void> _playMusic(String id, double volume, bool loop) async {
    if (id.isEmpty) return;
    final player = await _audioFor(id, music: true);
    if (player == null) return;
    await player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.release);
    await player.setVolume(volume.clamp(0.0, 1.0));
    await player.resume();
  }

  Future<void> _stopMusic() async {
    final player = _musicPlayer;
    if (player == null) return;
    try {
      await player.stop();
    } catch (_) {}
  }

  Future<void> _playSound(String id, double volume) async {
    if (id.isEmpty) return;
    final player = await _audioFor(id);
    if (player == null) return;
    await player.setVolume(volume.clamp(0.0, 1.0));
    await player.resume();
  }

  Future<void> _stopSound(String id) async {
    final player = _soundPlayers.remove(id);
    if (player == null) return;
    try {
      await player.stop();
      await player.dispose();
    } catch (_) {}
  }

  Future<void> _pauseResumeAudio(String target, String action) async {
    final player = _musicPlayer;
    if (player == null) return;
    try {
      if (action == 'pause') await player.pause();
      if (action == 'resume') await player.resume();
    } catch (_) {}
  }

  Future<void> _drainExternal() async {
    final engine = _engine;
    if (engine == null) return;
    final cmd = await _call('drainExternal', engine.drainExternal);
    final commands = cmd['commands'] as List? ?? const [];
    for (final raw in commands) {
      if (raw is! Map) continue;
      final c = Map<String, dynamic>.from(raw);
      if (c['type'] != 'open_link') continue;
      final uri = Uri.tryParse(c['url']?.toString() ?? '');
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https'))
        continue;
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        debugPrint('[web-player] open_link failed: $e');
      }
    }
  }

  Future<void> _afterEngineStep() async {
    await _paceScriptDelays();
    await _drainAudio();
    await _drainExternal();
    await _syncState();
    _armPendingTimers();
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // Текст, картинки, числа
  // ---------------------------------------------------------------------------

  /// Подставить `{переменная}` в текст: считает движок, клиент ничего не
  /// вычисляет сам (engine-mode из `text_variable_resolver.dart`).
  String resolveText(String text) {
    final engine = _engine;
    final collapsed = ScriptExecutor.collapseDoubleBraces(text);
    if (engine == null || !_syncUsable) return collapsed;
    var lastExpression = '';
    try {
      final result = ScriptExecutor.substitutePlaceholders(collapsed, (
        expression,
      ) {
        lastExpression = expression;
        return formatScriptValue(engine.evaluateSync(expression));
      });
      _noteSyncOk();
      return result;
    } catch (e) {
      // Сломанная формула не роняет сцену — показываем текст как есть.
      _noteSyncBlocked(e, lastExpression);
      return collapsed;
    }
  }

  dynamic evaluateExpression(String expression) {
    final engine = _engine;
    if (engine == null || !_syncUsable) return null;
    try {
      final value = engine.evaluateSync(expression);
      _noteSyncOk();
      return value;
    } catch (e) {
      _noteSyncBlocked(e, expression);
      return null;
    }
  }

  /// Число поля из формулы (`numericExprs[field]`), иначе [staticValue].
  double numeric(ContentItem item, String field, double staticValue) {
    final formula = item.numericExpr(field);
    if (formula == null) return staticValue;
    final engine = _engine;
    if (engine == null || !_syncUsable) return staticValue;
    final expression = ScriptExecutor.collapseDoubleBraces(
      formula,
    ).replaceAll(RegExp('[{}]'), '').trim();
    if (expression.isEmpty) return staticValue;
    try {
      final value = engine.evaluateSync(expression);
      _noteSyncOk();
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value.trim()) ?? staticValue;
    } catch (e) {
      _noteSyncBlocked(e, expression);
    }
    return staticValue;
  }

  /// Байты картинки: сначала то, что назначил скрипт (`set_image`), затем
  /// формула пути, затем статический `resourcePath`.
  Uint8List? imageBytesFor(ContentItem item) {
    final overridden = itemSourceOverride(variables, item.id);
    if (overridden != null) return bundle.assetBytes(overridden);
    if (!item.hasResourceExpr) return bundle.assetBytes(item.resourcePath);
    final resolved = resolveText(item.resourceExpr!);
    return bundle.assetBytes(resolved) ?? bundle.assetBytes(item.resourcePath);
  }

  Uint8List? assetBytes(String? source) => bundle.assetBytes(source);

  /// Итоговая видимость айтема: команда скрипта (`set_visible`) важнее
  /// условия `onAppear`, ровно как в нативном `ConditionalContentWrapper`.
  EngineVisibility visibilityOf(ContentItem item, {bool firstPass = false}) {
    final byScript = engineVisibilityOf(variables, item.id);
    if (byScript == EngineVisibility.gone) return byScript;
    final engine = _engine;
    if (engine == null || !_syncUsable) return byScript;
    if (item.scriptForEvent('onAppear') == null) return byScript;
    try {
      final shown = engine.evaluateVisibility(
        item.toJson(),
        allowMutation: firstPass,
      );
      _noteSyncOk();
      if (shown) return byScript;
      return EngineVisibility.gone;
    } catch (e) {
      _noteSyncBlocked(e, 'onAppear ${item.id}');
      return byScript;
    }
  }

  // ---------------------------------------------------------------------------
  // Состояние и пейсинг
  // ---------------------------------------------------------------------------

  /// Слить дельту движка в зеркало. [holdPacing] — вход в ноду с `wait`:
  /// финальные значения придерживаем до конца задержки (см. `_heldVars`).
  Future<void> _syncState({bool holdPacing = false}) async {
    final engine = _engine;
    if (engine == null) return;
    final delta = await _call('drainStateDelta', engine.drainStateDelta);
    final raw =
        (delta['variables'] as Map?)?.cast<String, dynamic>() ?? const {};
    var incoming = decodeDeltaVariables(raw);
    if (holdPacing) {
      _heldVars = incoming;
      incoming = const {};
    } else if (_heldVars.isNotEmpty) {
      final split = splitDeltaAgainstHold(incoming: incoming, held: _heldVars);
      _heldVars = split.held;
      incoming = split.publish;
    }
    if (incoming.isEmpty) return;
    variables = {...variables, ...incoming};
  }

  /// Промежуточный кадр `wait`: оверлей в движок (чтобы `evaluateVisibility`
  /// и текст видели анимацию) + в зеркало (чтобы `set_image`/`set_visible`).
  Future<void> _applyPacingStep(Map<String, dynamic> step) async {
    final engine = _engine;
    if (engine == null) return;
    final raw =
        (step['variables'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (raw.isNotEmpty) {
      final vars = decodeDeltaVariables(raw);
      variables = {...variables, ...vars};
      engine.applyExternalVariables(raw);
    }
    _safeNotify();
  }

  Future<void> _paceScriptDelays() async {
    final engine = _engine;
    if (engine == null) return;
    final steps = await _call('drainDelaySteps', engine.drainDelaySteps);
    if (steps.isEmpty) return;
    try {
      for (final step in steps) {
        await _applyPacingStep(step);
        final ms = ((step['ms'] ?? 0) as num).toInt();
        if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
      }
    } finally {
      engine.restoreAfterPacing();
    }
  }

  /// Задержки входа в ноду доигрываются фоном: сцена рисуется сразу, мутации
  /// после `wait` выходят по расписанию скрипта (#68).
  Future<void> _paceInBackground(
    List<Map<String, dynamic>> steps,
    int gen,
  ) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      for (var i = 0; i < steps.length; i++) {
        final ms = ((steps[i]['ms'] ?? 0) as num).toInt();
        if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
        if (gen != _gen || _engine == null) return;
        if (i + 1 < steps.length) await _applyPacingStep(steps[i + 1]);
      }
    } finally {
      if (gen == _gen) {
        engine.restoreAfterPacing();
        final held = _heldVars;
        _heldVars = const {};
        if (held.isNotEmpty) variables = {...variables, ...held};
        await _syncState();
        _safeNotify();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Таймеры
  // ---------------------------------------------------------------------------

  void _startNodeTimer(double seconds, String defaultActionNodeId) {
    if (seconds <= 0 || defaultActionNodeId.isEmpty) return;
    _timers.add(
      Timer(Duration(milliseconds: (seconds * 1000).round()), () async {
        if (phase != PlayPhase.playing) return;
        await loadNode(defaultActionNodeId);
      }),
    );
  }

  /// Отложенные вызовы скриптов (`schedule`-блоки): движок хранит расписание в
  /// служебной переменной, клиент только заводит `Timer` на каждый ключ.
  void _armPendingTimers() {
    final engine = _engine;
    final schedule = variables['_internal_timer_schedule'];
    if (engine == null || schedule is! List) return;
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
      _timers.add(
        Timer(Duration(milliseconds: ms), () async {
          _armedTimers.remove(key);
          if (_engine == null) return;
          try {
            final res = await _call(
              'runScheduledTimer',
              () => engine.runScheduledTimer(path, entry),
            );
            await _afterEngineStep();
            final transition = res?['transition']?.toString();
            if (res?['ran'] == true &&
                transition != null &&
                transition.isNotEmpty) {
              await loadNode(transition);
              return;
            }
          } catch (e) {
            debugPrint('[web-player] timer tick failed ($key): $e');
          }
          _armPendingTimers();
        }),
      );
    }
  }

  void _releaseTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _armedTimers.clear();
  }

  // ---------------------------------------------------------------------------
  // Служебное
  // ---------------------------------------------------------------------------

  /// Все вызовы движка — по очереди: нативный клиент делает то же
  /// (`_engineQueue`), иначе `next_item` и `execute_behaviour` из виджетов
  /// перемешиваются и ряд отдаётся дважды (#211).
  Future<T> _call<T>(String step, Future<T> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then<void>((_) {}, onError: (_) {});
    return run.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw StateError('Движок молчит на шаге «$step»'),
    );
  }

  void _safeNotify() {
    try {
      notifyListeners();
    } catch (_) {
      /* диспоунутый listener — не беда игрока */
    }
  }
}

/// Расшифровка плоской дельты движка: `имя → JSON-строка` → `имя → значение`.
///
/// Та же логика, что в `GameStateNotifier._decodeVariables`: число из движка
/// приходит строкой `"15"`, строка — `"\"текст\""`, а битое значение оставляем
/// как есть, иначе текст квеста теряется целиком.
Map<String, dynamic> decodeDeltaVariables(Map<String, dynamic> raw) {
  final out = <String, dynamic>{};
  raw.forEach((k, v) {
    final rawJson = v.toString();
    try {
      out[k] = rawJson == 'null' ? null : jsonDecode(rawJson);
    } catch (_) {
      out[k] = rawJson;
    }
  });
  return out;
}

/// Какие из пришедших значений можно уже показать, а какие держим дальше.
///
/// Держим ровно то, что движок отдал на входе в ноду и что с тех пор НЕ
/// менялось: новое значение (таймер или `onContentAppear` за время `wait`)
/// обязано выйти сразу, иначе его затрёт старым кадром задержки. Те же ключи
/// из удержания при этом убираем — второй раз их публиковать нельзя.
({Map<String, dynamic> publish, Map<String, dynamic> held})
splitDeltaAgainstHold({
  required Map<String, dynamic> incoming,
  required Map<String, dynamic> held,
}) {
  final stillHeld = Map.of(held);
  final publish = Map.of(incoming)
    ..removeWhere((k, v) {
      if (!stillHeld.containsKey(k)) return false;
      if (stillHeld[k] == v) return true;
      stillHeld.remove(k);
      return false;
    });
  return (publish: publish, held: stillHeld);
}

extension on String {
  String? get ifEmptyOrNull => isEmpty ? null : this;
}

/// Ошибка старта движка на вебе: `RuntimeError: unreachable` — это не текст
/// для игрока, а wasm-ловушка. Чаще всего страницу отдали без COOP/COEP, и
/// FRB не смог поднять worker pool через SharedArrayBuffer; без подсказки
/// автор видит голую строку и не понимает, что чинить.
String _explainWebFailure(String raw) {
  final wasmTrap = raw.contains('RuntimeError') || raw.contains('unreachable');
  if (!wasmTrap) return raw;
  return '$raw\n\nДвижок не запустился: странице нужны заголовки '
      'Cross-Origin-Opener-Policy: same-origin и '
      'Cross-Origin-Embedder-Policy: require-corp. Без них браузер не даёт '
      'SharedArrayBuffer. Для локальной раздачи: '
      'python3 scripts/serve_web_export.py --dir <папка экспорта>.';
}
