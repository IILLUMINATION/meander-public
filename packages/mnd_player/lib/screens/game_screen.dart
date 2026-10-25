import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/utils/platform_performance.dart';
import 'package:mnd_player/utils/background_blur.dart';
import 'package:mnd_player/utils/text_variable_resolver.dart';
import 'package:mnd_player/providers/audio_volume_provider.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/providers/game_session_scope.dart';
import 'package:mnd_player/providers/quest_provider.dart';
import 'package:mnd_player/providers/text_reveal_preference.dart';
import 'package:mnd_player/widgets/game_timer_widget.dart';
import 'package:mnd_player/widgets/plugin_slot_layer.dart';
import 'package:mnd_player/widgets/pinned_stack_layer.dart';
import 'package:mnd_player/widgets/node_transition_switcher.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mnd_player/widgets/content_display_factory.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';
import 'package:mnd_player/screens/load_game_screen.dart';
import 'package:mnd_player/screens/table_viewer_screen.dart';
import 'package:mnd_player/services/save_game_provider.dart';
import 'package:mnd_player/utils/locale_fix.dart';

/// Есть ли в ноде хоть один текст с включённой анимацией появления.
/// Глубокий обход сырого JSON контента: elements уже разобраны только у
/// отрисовываемых веток, а решение «показывать кнопку или нет» нужно до
/// сборки дерева.
bool _nodeUsesTextReveal(Map<String, dynamic>? content) {
  if (content == null) return false;
  final pending = <Object?>[content];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node is Map) {
      final reveal = node['textReveal'];
      if (reveal is String && reveal != kTextRevealDefault) return true;
      pending.addAll(node.values);
    } else if (node is List) {
      pending.addAll(node);
    }
  }
  return false;
}

/// Единый игровой экран (канон для standalone-плеера и main_app).
///
/// main_app-специфика (safety-аудит, плагины, playtime, workspace-выход)
/// подключается через [GameScreenHooks] ([gameScreenHooksProvider]) и
/// колбэки [onEditNode]/[onExit]/[onFinish], поэтому рендер и движковая
/// логика живут в одном месте.
class GameScreen extends ConsumerStatefulWidget {
  final String questId;

  /// Идентификатор вкладки/документа (main_app workspace). Разные docKey
  /// одного квеста получают независимые движки. Standalone: не задан.
  final String? docKey;
  final String? startNodeId;
  final bool isOnboarding;
  final SaveSlot? saveSlot;
  final bool isTesting;
  final VoidCallback? onEditNode;
  final VoidCallback? onFinish;

  /// Асинхронная очистка при выходе из игры (например, закрыть вкладку
  /// workspace). По умолчанию — autosave + `Navigator.pop`.
  final Future<void> Function()? onExit;

  /// Префлайт перед стартом сессии (safety-аудит, проверка плагинов).
  /// Возвращает `false`, если запуск следует отменить.
  final Future<bool> Function()? preflight;
  final List<Widget>? additionalAppBarActions;

  const GameScreen({
    super.key,
    required this.questId,
    this.docKey,
    this.startNodeId,
    this.isOnboarding = false,
    this.saveSlot,
    this.isTesting = false,
    this.onEditNode,
    this.onFinish,
    this.onExit,
    this.preflight,
    this.additionalAppBarActions,
  });

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

/// Режим сортировки списка переменных в отладчике.
enum _VarsSort { alpha, alphaDesc, changed }

class _GameScreenState extends ConsumerState<GameScreen> {
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _varsSearchController = TextEditingController();
  String _varsSearchQuery = '';
  _VarsSort _varsSort = _VarsSort.alpha;

  /// Lifecycle-хук: пауза/резюм музыки при сворачивании/разворачивании
  /// приложения (если квест не включил `musicInBackground`).
  AppLifecycleListener? _lifecycleListener;

  /// Служебные переменные движка (`_internal_*`) по умолчанию скрыты.
  bool _showInternalVars = false;

  /// Порядковый номер последнего изменения переменной — для сортировки
  /// «по изменениям» и подсветки тронутых скриптами значений.
  final Map<String, int> _varChangeSeq = {};
  int _varChangeCounter = 0;
  late final Future<bool> _disableBlurFuture;
  bool _disableHeavyEffects = false;

  /// Порог именно для фонового размытия (картинка и видео): он мягче, чем
  /// [_disableHeavyEffects], и не режет фон на десктопе (см.
  /// `shouldDisableBackgroundBlur`).
  bool _disableBackgroundBlur = false;

  // Сохранение позиции скролла при live-перезагрузке той же ноды: offset
  // запоминается по presentationId (он сохраняется при перезагрузке), и
  // восстанавливается после повторного reveal-цикла айтемов.
  final ScrollController _listController = ScrollController();
  final LinkedHashMap<String, double> _scrollByPresentation = LinkedHashMap();
  String? _currentPresentationId;

  /// Ключ игровой сессии: questId + docKey (вкладка).
  late final GameSessionKey _sessionKey;

  GameSessionKey get _key => _sessionKey;

  /// Хуки и нотификатор сессии, захваченные в initState. В dispose() НЕЛЬЗЯ
  /// использовать ref: dispose вызывается из unmount, когда элемент уже
  /// defunct (`context.mounted == false`), и любой ref.read бросает
  /// «Cannot use ref after the widget was disposed» — это исключение прерывает
  /// ConsumerStatefulElement.unmount ДО закрытия подписок riverpod, провайдер
  /// не диспоузится, нотификатор и FFI-движок текут, а поздние эмиссии
  /// падают в мёртвый элемент (`_lifecycleState != defunct`).
  late final GameScreenHooks _hooks;
  late final GameScreenNotifier _sessionNotifier;

  @override
  void initState() {
    super.initState();
    _sessionKey = (
      questId: widget.questId,
      docKey: widget.docKey ?? 'standalone',
    );
    _disableBlurFuture = PlatformPerformance.instance.shouldDisableBlur();
    _disableBlurFuture.then((disabled) {
      if (mounted && _disableHeavyEffects != disabled) {
        setState(() => _disableHeavyEffects = disabled);
      }
    });
    PlatformPerformance.instance.shouldDisableBackgroundBlur().then((disabled) {
      if (mounted && _disableBackgroundBlur != disabled) {
        setState(() => _disableBackgroundBlur = disabled);
      }
    });
    if (kDebugMode) {
      final st = StackTrace.current.toString().split('\n').take(10).join(' | ');
      print(
        '🎮 [GameScreen][Widget] initState session=$_sessionKey quest=${widget.questId} widgetStart=${widget.startNodeId} hash=${hashCode} stack=$st',
      );
    }
    _listController.addListener(_onListScroll);
    _hooks = ref.read(gameScreenHooksProvider);
    _sessionNotifier = ref.read(gameScreenProvider(_key).notifier);

    // Пересборка по изменению состояния сессии — через listenManual с guard'ом
    // context.mounted, а НЕ ref.watch: riverpod 2.6.1 в колбэке watch вызывает
    // markNeedsBuild() безусловно, и при гонке «нотификатор эмитит, а элемент
    // экрана уже размонтирован» это падало с `_lifecycleState != defunct`
    // (ошибка уходит в zone через runBinaryGuarded и не ловится try/catch).
    // `mounted` (State) не годится как guard: во время state.dispose() элемент
    // уже defunct, а state._element ещё не обнулён — setState улетит в
    // мёртвый элемент. context.mounted отражает жизненный цикл элемента точно.
    ref.listenManual(gameScreenProvider(_key), (prev, next) {
      if (context.mounted) setState(() {});
    });
    // Игровые переменные слушают только зависимые дочерние виджеты через
    // select. Не подписываем весь экран: частые изменения из скриптов больше
    // не пересобирают фон, AppBar, переход и весь список целиком.
    // Для отладчика сохраняем журнал изменений, но без setState всего экрана.
    ref.listenManual<GameState>(gameStateProvider, (prev, next) {
      if (prev == null) return;
      for (final entry in next.variables.entries) {
        if (prev.variables[entry.key] != entry.value) {
          _varChangeSeq[entry.key] = ++_varChangeCounter;
        }
      }
    });
    // Иконка громкости в AppBar реагирует на ползунок из bottom-sheet:
    // sheet-виджет watch'ит провайдер сам, экрану достаточно слушать.
    ref.listenManual(globalAudioVolumeProvider, (prev, next) {
      if (prev == next) return;
      if (context.mounted) setState(() {});
    });

    // Ждем окончания анимации перехода, прежде чем грузить тяжелые данные.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _startGameSession();
    });

    // Сворачивание приложения: по умолчанию ставим музыку на паузу, если
    // квест не разрешил играть в фоне (настройка «Музыка при сворачивании»).
    // На Android смена приложения даёт hidden/paused; inactive — шторка/диалог, не считаем сворачиванием.
    _lifecycleListener = AppLifecycleListener(
      onPause: () => _sessionNotifier.handleAppLifecyclePaused(),
      onHide: () => _sessionNotifier.handleAppLifecycleHidden(),
      onInactive: () => _sessionNotifier.handleAppLifecycleInactive(),
      onResume: () => _sessionNotifier.handleAppLifecycleResumed(),
      onShow: () => _sessionNotifier.handleAppLifecycleShown(),
      onRestart: () => _sessionNotifier.handleAppLifecycleRestart(),
    );
  }

  Future<void> _startGameSession() async {
    if (!mounted) return;

    // Префлайт (safety-аудит, проверка плагинов) — main_app передаёт колбэк.
    final canStart = await widget.preflight?.call() ?? true;
    if (!canStart || !mounted) return;

    final notifier = ref.read(gameScreenProvider(_key).notifier);
    await notifier.initializeGameSession();
    if (!mounted) return;
    await notifier.loadInitialNode(
      widget.startNodeId,
      saveSlot: widget.saveSlot,
    );
    ref
        .read(gameScreenHooksProvider)
        .onGameSessionStarted
        ?.call(widget.questId);
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    if (kDebugMode) {
      final st = StackTrace.current.toString().split('\n').take(14).join('\n');
      print(
        '🎮 [GameScreen][Widget] dispose widgetSession=$_sessionKey quest=${widget.questId} notifier=${_sessionNotifier.hashCode} hash=${hashCode}\nStack:\n$st',
      );
    }
    // Без ref — см. комментарий у _hooks/_sessionNotifier. Обёрнуто в
    // try/catch на всякий случай: исключение из dispose прервало бы очистку
    // подписок riverpod в unmount (утечка провайдера + краши defunct).
    try {
      _hooks.onGameSessionEnded?.call(widget.questId);
      // Синхронно гасим нотификатор: незавершённые async-перезагрузки после
      // этого не смогут дёрнуть `state =` в уже размонтированный элемент
      // (краш `_lifecycleState != defunct`).
      _sessionNotifier.markSessionEnded();
    } catch (e, stack) {
      if (kDebugMode)
        print(
          '🎮 [GameScreen][Widget] dispose markSessionEnded error: $e\n$stack',
        );
    }
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _listController.removeListener(_onListScroll);
    _listController.dispose();
    _focusNode.dispose();
    _varsSearchController.dispose();
    super.dispose();
  }

  // Флаг для предотвращения лишних вызовов stop(), которые крашат Windows

  bool _shouldHideVariable(String key) => key == '_SYS_HISTORY';

  String _formatVariableValue(dynamic value) {
    if (value == null) return 'null';
    if (value is String) {
      if (value.length <= 120) return value;
      return '${value.substring(0, 120)}…';
    }
    if (value is num || value is bool) return value.toString();
    // Компактный JSON-превью для контейнеров, если помещается.
    try {
      final encoded = jsonEncode(value);
      if (encoded.length <= 80) return encoded;
    } catch (_) {}
    if (value is List) return 'List(${value.length})';
    if (value is Map) return 'Map(${value.length})';
    return value.toString();
  }

  int _alphaCmp(String a, String b) =>
      a.toLowerCase().compareTo(b.toLowerCase());

  int _compareVariables(
    MapEntry<String, dynamic> a,
    MapEntry<String, dynamic> b,
  ) {
    if (_varsSort == _VarsSort.changed) {
      final byChanged = (_varChangeSeq[b.key] ?? 0).compareTo(
        _varChangeSeq[a.key] ?? 0,
      );
      if (byChanged != 0) return byChanged;
    }
    if (_varsSort == _VarsSort.alphaDesc) return -_alphaCmp(a.key, b.key);
    return _alphaCmp(a.key, b.key);
  }

  void _showVariableDetails(BuildContext context, String key, dynamic value) {
    String content;
    try {
      const encoder = JsonEncoder.withIndent('  ');
      if (value is Map || value is List) {
        content = encoder.convert(value);
      } else {
        content = value?.toString() ?? 'null';
      }
    } catch (_) {
      content = value?.toString() ?? 'null';
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(key, style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: SelectableText(
            content,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Значение скопировано'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: const Text('Копировать'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  void _onItemInteract(ContentItem item) async {
    // Триггер ищем в обоих форматах: редактор пишет legacy `scriptTriggers`,
    // новый формат — `behaviours`. Отсюда «нажимаю, скрипт не работает».
    final triggerRefRaw =
        item.scriptForEvent(item.type == 'input' ? 'onSubmit' : 'onPress') ??
        item.scriptForEvent('onPress');

    final notifier = ref.read(gameScreenProvider(_key).notifier);

    if (triggerRefRaw != null) {
      final nextNodeId = await notifier.handleInteraction(item, triggerRefRaw);
      if (!mounted) return;
      if (nextNodeId != null && nextNodeId.isNotEmpty) {
        notifier.loadNode(nextNodeId);
        return;
      }
    }

    if (!mounted) return;

    if (item.targetNodeId != null) {
      final resolvedTarget = await notifier.resolveTarget(item.targetNodeId!);
      if (resolvedTarget == null || resolvedTarget.isEmpty) {
        return;
      }
      if (widget.isOnboarding && resolvedTarget == '_FINISH_ONBOARDING') {
        _handleOnboardingFinish();
      } else {
        notifier.loadNode(resolvedTarget);
      }
    }
  }

  void _onInputSubmitted(String variableName, String value) {
    final notifier = ref.read(gameScreenProvider(_key).notifier);
    final engine = notifier.engine;
    if (engine != null && !engine.isDisposed) {
      engine.setStateVariable(variableName, value);
      // Подписка «При изменении данных» на введённое значение могла выдать
      // переход, а у прямой мутации канала возврата нет — забираем его здесь,
      // иначе нода не сменится, пока игрок снова ничего не нажмёт.
      final next = engine.takePendingTransition();
      if (next != null && mounted) notifier.loadNode(next);
    }
  }

  void _handleOnboardingFinish() async {
    if (widget.onFinish != null) {
      widget.onFinish!();
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('has_completed_onboarding', true);
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      } catch (_) {}
    }
  }

  void _showVariablesDebug() {
    _varsSearchController.text = _varsSearchQuery;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          // Локальные режимы (сортировка, служебные переменные) — в State
          // шита; данные — через Consumer: маршрут шита не пересобирается
          // setState'ом экрана, поэтому watch на gameStateProvider нужен
          // здесь, чтобы список жил во время игры.
          Widget sortChip(_VarsSort mode, String label, IconData icon) {
            final selected = _varsSort == mode;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 15,
                      color: selected ? Colors.black : Colors.white54,
                    ),
                    const SizedBox(width: 5),
                    Text(label),
                  ],
                ),
                selected: selected,
                showCheckmark: false,
                labelStyle: TextStyle(
                  color: selected ? Colors.black : Colors.white70,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                selectedColor: Colors.greenAccent,
                backgroundColor: Colors.white.withValues(alpha: 0.06),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setSheetState(() => _varsSort = mode),
              ),
            );
          }

          Widget varTile(MapEntry<String, dynamic> e) {
            final changed = _varChangeSeq.containsKey(e.key);
            return ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(
                e.key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: changed
                      ? Colors.greenAccent
                      : Colors.greenAccent.withValues(alpha: 0.75),
                  fontSize: 13,
                  fontWeight: changed ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              trailing: Text(
                _formatVariableValue(e.value),
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: changed ? Colors.white : Colors.white60,
                  fontSize: 12,
                  fontWeight: changed ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              onTap: () => _showVariableDetails(sheetContext, e.key, e.value),
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: '${e.key} = ${e.value}'));
                ScaffoldMessenger.of(sheetContext).showSnackBar(
                  const SnackBar(
                    content: Text('Скопировано: имя = значение'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            );
          }

          return Consumer(
            builder: (context, ref, _) {
              // Живые данные: пересчитываются на каждую эмиссию
              // gameStateProvider во время игры.
              final gameState = ref.watch(gameStateProvider);
              final vars = gameState.variables;
              final tables = gameState.tables;

              final query = _varsSearchQuery.trim().toLowerCase();

              final filteredVars =
                  vars.entries
                      .where((e) => !_shouldHideVariable(e.key))
                      .where(
                        (e) =>
                            _showInternalVars ||
                            !e.key.startsWith('_internal_'),
                      )
                      .where(
                        (e) =>
                            query.isEmpty ||
                            e.key.toLowerCase().contains(query) ||
                            _formatVariableValue(
                              e.value,
                            ).toLowerCase().contains(query),
                      )
                      .toList()
                    ..sort(_compareVariables);

              final filteredTables =
                  tables.entries
                      .where(
                        (e) =>
                            query.isEmpty ||
                            e.key.toLowerCase().contains(query),
                      )
                      .toList()
                    ..sort((a, b) => _alphaCmp(a.key, b.key));

              final hiddenInternalCount = vars.keys
                  .where(
                    (k) =>
                        k.startsWith('_internal_') && !_shouldHideVariable(k),
                  )
                  .length;

              return Material(
                color: const Color(0xFF1E1E1E),
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: MediaQuery.of(sheetContext).size.height * 0.85,
                    child: Column(
                      children: [
                        // ── Шапка ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Отладчик',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Служебные переменные (_internal_*)',
                                icon: Icon(
                                  Icons.settings_suggest_outlined,
                                  size: 20,
                                  color: _showInternalVars
                                      ? Colors.amberAccent
                                      : Colors.white38,
                                ),
                                onPressed: () => setSheetState(() {
                                  _showInternalVars = !_showInternalVars;
                                }),
                              ),
                              IconButton(
                                tooltip: 'Закрыть',
                                icon: const Icon(
                                  Icons.close,
                                  size: 20,
                                  color: Colors.white54,
                                ),
                                onPressed: () =>
                                    Navigator.of(sheetContext).pop(),
                              ),
                            ],
                          ),
                        ),
                        // ── Поиск ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _varsSearchController,
                            builder: (context, value, _) => TextField(
                              controller: _varsSearchController,
                              onChanged: (val) => setSheetState(() {
                                _varsSearchQuery = val;
                              }),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: 'Поиск по имени или значению…',
                                hintStyle: const TextStyle(
                                  color: Colors.white38,
                                ),
                                prefixIcon: const Icon(
                                  Icons.search,
                                  color: Colors.white38,
                                  size: 20,
                                ),
                                suffixIcon: value.text.isEmpty
                                    ? null
                                    : IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(
                                          Icons.close,
                                          size: 16,
                                          color: Colors.white38,
                                        ),
                                        onPressed: () {
                                          _varsSearchController.clear();
                                          setSheetState(
                                            () => _varsSearchQuery = '',
                                          );
                                        },
                                      ),
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                        // ── Сортировка и счётчик ──
                        if (filteredVars.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        sortChip(
                                          _VarsSort.alpha,
                                          'А–Я',
                                          Icons.sort_by_alpha,
                                        ),
                                        sortChip(
                                          _VarsSort.alphaDesc,
                                          'Я–А',
                                          Icons.sort_by_alpha,
                                        ),
                                        sortChip(
                                          _VarsSort.changed,
                                          'По изменениям',
                                          Icons.bolt,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${filteredVars.length} перем.',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                        // ── Список ──
                        Expanded(
                          child:
                              (filteredVars.isEmpty && filteredTables.isEmpty)
                              ? Center(
                                  child: Text(
                                    query.isEmpty
                                        ? 'Пока пусто'
                                        : 'Ничего не найдено',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                    ),
                                  ),
                                )
                              : ListView(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  children: [
                                    if (filteredVars.isNotEmpty) ...[
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          4,
                                          16,
                                          4,
                                        ),
                                        child: Text(
                                          'ПЕРЕМЕННЫЕ',
                                          style: TextStyle(
                                            color: Colors.grey.shade500,
                                            fontSize: 11,
                                            letterSpacing: 1.1,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      ...filteredVars.map(varTile),
                                    ],
                                    if (filteredTables.isNotEmpty) ...[
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          12,
                                          16,
                                          4,
                                        ),
                                        child: Text(
                                          'ТАБЛИЦЫ',
                                          style: TextStyle(
                                            color: Colors.grey.shade500,
                                            fontSize: 11,
                                            letterSpacing: 1.1,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      ...filteredTables.map(
                                        (e) => ListTile(
                                          dense: true,
                                          visualDensity: VisualDensity.compact,
                                          leading: const Icon(
                                            Icons.dataset,
                                            color: Colors.orangeAccent,
                                            size: 20,
                                          ),
                                          title: Text(
                                            e.key,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.orangeAccent,
                                              fontSize: 13,
                                            ),
                                          ),
                                          subtitle: Text(
                                            '${e.value.rows.length} строк'
                                            '${e.value.data.isNotEmpty ? ' · ${e.value.data.length} ключ.' : ''}',
                                            style: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 11,
                                            ),
                                          ),
                                          trailing: const Icon(
                                            Icons.chevron_right,
                                            color: Colors.white24,
                                            size: 18,
                                          ),
                                          onTap: () {
                                            Navigator.push(
                                              sheetContext,
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    TableViewerScreen(
                                                      tableName: e.key,
                                                      table: e.value,
                                                    ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                    if (hiddenInternalCount > 0 &&
                                        !_showInternalVars)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          8,
                                          16,
                                          0,
                                        ),
                                        child: Text(
                                          'Скрыто служебных: '
                                          '$hiddenInternalCount (⚙ в шапке)',
                                          style: const TextStyle(
                                            color: Colors.white24,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _editCurrentNode() {
    widget.onEditNode?.call();
  }

  void _showVolumeDialog() {
    // Центральное всплывающее окно (не bottom-sheet): не перекрывает низ
    // экрана, где HUD и кнопки ноды. Цвета — из темы приложения (M3),
    // корректно работают с любым пресетом (beige/forest/кастом); в
    // standalone-плеере без ThemeData отработает Material-задефолт.
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Consumer(
        builder: (context, ref, _) {
          final scheme = Theme.of(dialogContext).colorScheme;
          final vol = ref.watch(globalAudioVolumeProvider);
          final volPct = (vol * 100).toInt();
          return Dialog(
            backgroundColor: scheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(switch (vol) {
                          0.0 => Icons.volume_off_rounded,
                          < 0.5 => Icons.volume_down_rounded,
                          _ => Icons.volume_up_rounded,
                        }, color: scheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Громкость',
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '$volPct%',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(dialogContext).copyWith(
                        trackHeight: 6,
                        thumbColor: scheme.primary,
                        activeTrackColor: scheme.primary,
                        inactiveTrackColor: scheme.surfaceContainerHighest,
                        valueIndicatorColor: scheme.primary,
                      ),
                      child: Slider(
                        value: vol,
                        min: 0.0,
                        max: 1.0,
                        divisions: 20,
                        label: '$volPct%',
                        onChanged: (v) => ref
                            .read(globalAudioVolumeProvider.notifier)
                            .setVolume(v),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: () => ref
                              .read(globalAudioVolumeProvider.notifier)
                              .setVolume(0),
                          icon: const Icon(Icons.volume_off, size: 18),
                          label: const Text('Выкл'),
                        ),
                        TextButton.icon(
                          onPressed: () => ref
                              .read(globalAudioVolumeProvider.notifier)
                              .setVolume(1.0),
                          icon: const Icon(Icons.volume_up, size: 18),
                          label: const Text('Макс'),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: Text(
                          'Готово',
                          style: TextStyle(color: scheme.primary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Появление текста — авторская задумка, но игрок имеет право её не
  /// смотреть. Те же четыре значения, что у громкости: окно, а не bottom-sheet,
  /// чтобы не закрывать кнопки ноды.
  void _showTextRevealDialog() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Consumer(
        builder: (context, ref, _) {
          final scheme = Theme.of(dialogContext).colorScheme;
          final current = ref.watch(textRevealPreferenceProvider);
          return Dialog(
            backgroundColor: scheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.animation_rounded,
                          color: Colors.blueAccent,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Появление текста',
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Скорость анимации, которую включил автор квеста. '
                      'Можно выключить — надписи появятся сразу.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in TextRevealPreference.values)
                          ChoiceChip(
                            label: Text(option.label),
                            selected: current == option,
                            onSelected: (_) => ref
                                .read(textRevealPreferenceProvider.notifier)
                                .setPreference(option),
                          ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: Text(
                          'Готово',
                          style: TextStyle(color: scheme.primary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _exitGame() async {
    // Автосейв bounded: сломанный/зависший движок не должен удерживать выход.
    try {
      await ref
          .read(gameScreenProvider(_key).notifier)
          .performAutosave()
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    if (!mounted) return;
    if (widget.onExit != null) {
      await widget.onExit!();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Чтение без подписки: пересборку обеспечивает listenManual в initState.
    final screenState = ref.read(gameScreenProvider(_key));
    _currentPresentationId = screenState.presentationId;

    // После live-перезагрузки той же ноды айтемы ре-ривилятся заново —
    // восстанавливаем сохранённый скролл, как только список появился.
    ref.listen(gameScreenProvider(_key).select((s) => s.revealedItems.length), (
      previous,
      next,
    ) {
      // Элемент может быть inactive/defunct (переход маршрута, unmount):
      // ref.read ниже бросит, а setState улетит в мёртвый элемент.
      if (!context.mounted) return;
      if (next > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) _restoreScroll();
        });
      }
    });

    ref.listen(gameScreenProvider(_key).select((s) => s.currentNode), (
      previous,
      next,
    ) {
      if (!context.mounted) return;
      if (next != null && next.id != previous?.id) {
        final gameStateNotifier = ref.read(gameStateProvider.notifier);
        List<dynamic> currentHistory = [];
        final rawHistory = gameStateNotifier.getVariable('_SYS_HISTORY');
        if (rawHistory is List) {
          currentHistory = List.from(rawHistory);
        }
        currentHistory.add(next.id);
        // Ограничиваем историю последними 100 нодами: без ограничения она
        // растёт всю сессию, и deepEquals в GameState на каждую эмиссию
        // становится всё дороже — длинные сессии постепенно лагают.
        const historyCap = 100;
        if (currentHistory.length > historyCap) {
          currentHistory = currentHistory.sublist(
            currentHistory.length - historyCap,
          );
        }
        final engine = ref.read(gameScreenProvider(_key).notifier).engine;
        if (engine != null && !engine.isDisposed) {
          engine.setStateVariable('_SYS_HISTORY', currentHistory);
        }

        // --- БЕЗОПАСНОЕ ОБНОВЛЕНИЕ АУДИО ---
        _updateBackgrounds(next);
      }
    });

    return GameSessionScope(
      sessionKey: _key,
      child: PopScope(
        canPop: false,
        onPopInvoked: (didPop) async {
          if (didPop) return;
          await _exitGame();
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: DefaultTextStyle(
            style: TextStyle(
              fontFamily: screenState.fontFamily,
              color: Colors.white,
            ),
            child: Scaffold(
              backgroundColor: Colors.transparent,
              extendBodyBehindAppBar: true,
              appBar: _buildAppBar(context, screenState),
              body: _buildBody(screenState),
            ),
          ),
        ),
      ),
    );
  }

  // --- ИСПРАВЛЕННАЯ ЛОГИКА АУДИО ---
  Future<void> _updateBackgrounds(SavedNode node) async {
    // Background updates are handled in GameScreenNotifier.
  }

  AppBar _buildAppBar(BuildContext context, GameScreenState screenState) {
    final quest = ref.watch(questProvider(widget.questId)).value;
    final bool hideTitle = quest?.hideNodeTitles ?? false;
    final gameStateNotifier = ref.read(gameStateProvider.notifier);
    final vol = ref.read(globalAudioVolumeProvider);
    // Настройка анимации появляется только там, где автор её действительно
    // включил: шапка не обрастает кнопкой «на всякий случай».
    final revealEnabled = ref.watch(
      gameScreenProvider(_key)
          .select((s) => _nodeUsesTextReveal(s.currentNode?.content)),
    );

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      title: hideTitle
          ? null
          : Consumer(
              builder: (context, ref, _) {
                // Только заголовок зависит от произвольных переменных квеста.
                // Не заставляем из-за него пересобирать весь игровой экран.
                ref.watch(gameStateProvider);
                return Text(
                  _parseTextWithVariables(
                    screenState.currentNode?.title ?? '...',
                    gameStateNotifier,
                  ),
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
                    fontFamily: screenState.fontFamily,
                  ),
                );
              },
            ),
      leading: widget.isTesting || widget.docKey != null
          ? IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: _exitGame,
              tooltip: 'Назад',
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withOpacity(0.3),
              ),
            )
          : const SizedBox.shrink(),
      actions: [
        // Внутренняя громкость квеста: чтобы приглушить/выключить звук,
        // не трогая системную громкость (музыка может играть параллельно).
        // ref.watch безопасен: подписка закрывается до unmount элемента.
        IconButton(
          icon: Icon(switch (vol) {
            0.0 => Icons.volume_off_rounded,
            < 0.5 => Icons.volume_down_rounded,
            _ => Icons.volume_up_rounded,
          }, color: Colors.white),
          onPressed: _showVolumeDialog,
          tooltip: 'Громкость',
          style: IconButton.styleFrom(
            backgroundColor: Colors.black.withOpacity(0.3),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.save_alt_rounded),
          onPressed: _showSaveDialog,
          tooltip: 'Сохранить',
          style: IconButton.styleFrom(
            backgroundColor: Colors.black.withOpacity(0.3),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.folder_open_rounded),
          onPressed: _showLoadGame,
          tooltip: 'Загрузить',
          style: IconButton.styleFrom(
            backgroundColor: Colors.black.withOpacity(0.3),
          ),
        ),
        // Редкие кнопки — в подменю. Все вместе они не влезают в узкую
        // шапку телефона, и AppBar начинает рисовать их поверх «назад».
        if (revealEnabled || widget.isTesting || widget.onEditNode != null)
          _MoreMenu(
            reveal: revealEnabled,
            debug: widget.isTesting,
            edit: widget.onEditNode != null,
            onReveal: _showTextRevealDialog,
            onDebug: _showVariablesDebug,
            onEdit: _editCurrentNode,
          ),
        ...?widget.additionalAppBarActions,
      ],
      flexibleSpace: FutureBuilder<bool>(
        future: _disableBlurFuture,

        initialData: false,
        builder: (context, snapshot) {
          final shouldDisableBlur = snapshot.data ?? false;

          if (shouldDisableBlur) {
            // Без blur - просто полупрозрачный фон
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.7),
                    Colors.black.withOpacity(0.3),
                  ],
                ),
              ),
            );
          }

          // С blur
          return ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Container(color: Colors.transparent),
            ),
          );
        },
      ),
    );
  }

  String _parseTextWithVariables(String text, GameStateNotifier notifier) {
    return resolveTextVariables(
      ref,
      text,
      widget.questId,
      notifier,
      sessionKey: _key,
    );
  }

  Widget _buildBody(GameScreenState screenState) {
    // Только тело игры подписано на конкретные переменные, которые ему
    // действительно нужны. Остальной экран не реагирует на каждый тик скрипта.
    return Consumer(
      builder: (context, ref, _) {
        final blurValue = ref.watch(
          gameStateProvider.select(
            (state) => state.variables['_internal_background_blur'],
          ),
        );
        final contentVolume = ref.watch(
          gameStateProvider.select(
            (state) => state.variables['_internal_node_content_volume'],
          ),
        );
        final quest = ref.watch(questProvider(widget.questId)).value;
        return _buildBodyContent(
          screenState,
          quest,
          // null — скрипт размытие не трогал: тогда решает поле ноды.
          parseBackgroundBlur(blurValue),
          (contentVolume as num?)?.toDouble(),
        );
      },
    );
  }

  Widget _buildBodyContent(
    GameScreenState screenState,
    Quest? quest,
    double? scriptBlur,
    double? contentVolume,
  ) {
    // Стиль перехода: переопределение конкретной ноды (вход в неё) имеет
    // приоритет над глобальным стилем квеста.
    final requestedTransitionMode = resolveNodeTransitionMode(
      screenState.currentNode?.transitionMode ?? quest?.nodeTransitionMode,
    );
    // Сохраняем сам переход ноды, но заменяем самые дорогие визуальные
    // эффекты на дешёвый fade/none на слабых Android/Linux устройствах.
    final transitionMode =
        _disableHeavyEffects &&
            const {
              'flip',
              'blur',
              'zoom',
              'page',
            }.contains(requestedTransitionMode)
        ? (requestedTransitionMode == 'page' ? 'fade' : 'none')
        : requestedTransitionMode;
    final scriptEngineMode = normalizeScriptEngineMode(quest?.scriptEngineMode);

    // Фон строится один раз: рисуется в общем Stack И передаётся в переход
    // (для flip-эффекта он захватывается вместе с контентом уходящей ноды,
    // чтобы лист был непрозрачным, с фоном).
    final background = _buildBackground(
      screenState,
      scriptBlur,
      quest?.dimBackground ?? true,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        background,
        SafeArea(
          child: Builder(
            builder: (context) {
              if (screenState.error != null) {
                return Center(
                  child: Text(
                    screenState.error!,
                    style: TextStyle(color: Colors.red[300]),
                  ),
                );
              }

              if (screenState.isLoading || screenState.currentNode == null) {
                return const _NodeLoadingView();
              }

              final itemsToDisplay = screenState.revealedItems;
              // Шаг из виджета помечаем его сценой: уходящая нода живёт в
              // дереве всё время cross-fade, и её таймеры не должны двигать
              // очередь уже следующей ноды (см. `revealNextItem`).
              final presentationId = screenState.presentationId;
              // Внутренний отступ между корневыми элементами ноды.
              // null → старое поведение (24 px), 0 → стык без зазоров.
              final double? nodeSpacing = screenState.currentNode?.itemSpacing;
              final double rootBottomPad = nodeSpacing ?? 24.0;
              final listView = ListView.builder(
                controller: _listController,
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                itemCount: itemsToDisplay.length,
                key: ValueKey(
                  'game_list_${screenState.presentationId}_${screenState.revealEpoch}',
                ),
                itemBuilder: (context, index) {
                  final item = itemsToDisplay[index];
                  // Если spacing задан явно — отступ только между детьми,
                  // чтобы 0 действительно давал стык без зазоров.
                  final double effectivePad;
                  if (nodeSpacing != null) {
                    effectivePad = index == itemsToDisplay.length - 1
                        ? 0.0
                        : rootBottomPad;
                  } else {
                    effectivePad = 24.0;
                  }
                  return RepaintBoundary(
                    child: ContentDisplayFactory.build(
                      item: item,
                      questId: widget.questId,
                      onInteract: _onItemInteract,
                      onInputSubmitted: _onInputSubmitted,
                      onComplete: () => ref
                          .read(gameScreenProvider(_key).notifier)
                          .revealNextItem(fromPresentationId: presentationId),
                      onTransition: (id) => ref
                          .read(gameScreenProvider(_key).notifier)
                          .loadNode(id),
                      onNavigateToNode: (id) => ref
                          .read(gameScreenProvider(_key).notifier)
                          .loadNode(id),
                      audioVolume: contentVolume,
                      bottomPadding: effectivePad,
                      fontFamily: screenState.fontFamily,
                      scriptEngineMode: scriptEngineMode,
                      imageRoundedCornersOverride:
                          screenState.currentNode?.imageRoundedCorners,
                      engine: ref
                          .read(gameScreenProvider(_key).notifier)
                          .engine,
                    ),
                  );
                },
              );

              final content = NodeTransitionSwitcher(
                mode: transitionMode,
                presentationId: screenState.presentationId,
                background: background,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: listView,
                  ),
                ),
              );

              return Column(
                children: [
                  if (screenState.currentNode!.timerDuration != null &&
                      screenState.currentNode!.timerHidden != true)
                    GameTimerWidget(
                      sessionKey: '${_key.questId}::${_key.docKey}',
                      totalSeconds: screenState.currentNode!.timerDuration!,
                    ),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
        // ---- Закреплённые стеки (stackPin): слой поверх прокрутки ноды ----
        // Поверх контента и ниже плагинов: автор сам решает, куда встать
        // (якоря рамки), служебные отступы под панель больше не нужны.
        ..._buildPinnedStacks(
          screenState,
          contentVolume,
          scriptEngineMode,
          screenState.fontFamily,
        ),
        // ---- UI плагинов (L3B): слоты hud/overlay/drawer + тосты ----
        ..._buildPluginLayers(),
        PluginToastLayer(questId: widget.questId),
      ],
    );
  }

  /// Стеки с `stackPin` рисуются поверх прокрутки ноды и не уезжают при
  /// скролле. Где именно — решает рамка закрепления ([ContentItem.stackPinRect]):
  /// ярлык `top`/`bottom`/`left`/`right`/`center`/`fill` даёт положение по
  /// умолчанию, а якоря со смещениями — любую верстку, вплоть до ряда панелей
  /// (0..0.5 и 0.5..1 по X). Модальное окно (`stackModal`) дополнительно
  /// затемняет ноду и не пропускает к ней тапы.
  ///
  /// Движок отдаёт закреплённые слои в общем потоке раскрытия, поэтому
  /// [onComplete] обязан сработать и здесь — иначе цепочка ре-ривила встанет
  /// на закреплённом слое и остальной контент ноды не появится.
  ///
  /// Окно считается закрытым, если автор тапнул вне рамки ([_dismiss]) либо
  /// скрипт сказал `set_visible: gone/hidden`. Блок «показать» (`visible`)
  /// возвращает окно: тап вне — не команда движка, а жест игрока, он не должен
  /// отменять сценарий.
  List<Widget> _buildPinnedStacks(
    GameScreenState screenState,
    double? contentVolume,
    String scriptEngineMode,
    String? fontFamily,
  ) {
    if (screenState.pinnedStacks.isEmpty) return const [];
    final notifier = ref.read(gameScreenProvider(_key).notifier);
    final overrides = ref.watch(
      gameStateProvider.select((s) => s.variables[kItemHiddenVar]),
    );
    Widget content(ContentItem item) => ContentDisplayFactory.build(
      item: item,
      questId: widget.questId,
      onInteract: _onItemInteract,
      onInputSubmitted: _onInputSubmitted,
      onComplete: () =>
          notifier.revealNextItem(fromPresentationId: screenState.presentationId),
      onTransition: (id) => notifier.loadNode(id),
      onNavigateToNode: (id) => notifier.loadNode(id),
      audioVolume: contentVolume,
      fontFamily: fontFamily,
      scriptEngineMode: scriptEngineMode,
      imageRoundedCornersOverride: screenState.currentNode?.imageRoundedCorners,
      engine: notifier.engine,
    );

    final visible = [
      for (final item in screenState.pinnedStacks)
        if (!screenState.dismissedStacks.contains(item.id) ||
            (overrides is Map && overrides[item.id] == 'visible'))
          item,
    ];
    if (visible.isEmpty) return const [];

    return [
      Positioned.fill(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Вьюпорт рамок — та же колонка в 720 px, что и у списка
              // контента: иначе на ПК «прижать слева» означало бы прижать к
              // краю окна, а не к краю игры, и автор видел бы в редакторе
              // одно, а получал другое.
              final vw = constraints.maxWidth;
              final vh = constraints.maxHeight;
              const columnCap = 720.0;
              final columnWidth = vw < columnCap ? vw : columnCap;
              final viewport = Size(columnWidth, vh);
              final dx = (vw - columnWidth) / 2;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final item in visible)
                    PinnedStackLayer(
                      key: ValueKey(
                        'pinned_stack_${screenState.presentationId}_${item.id}',
                      ),
                      item: item,
                      viewport: viewport,
                      offset: Offset(dx, 0),
                      onDismiss: () => notifier.dismissPinnedStack(item.id),
                      engine: notifier.engine,
                      child: content(item),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ];
  }

  /// Слоты плагинов поверх контента + полноэкранный surface поверх слотов.
  ///
  /// Рантайма нет (квест без плагинов) — возвращаем пустой список, и экран
  /// даже не подписывается на `gameStateProvider` ради их переменных.
  /// Перерисовка — по `ListenableBuilder` внутри [PluginSlotLayer].
  List<Widget> _buildPluginLayers() {
    final notifier = ref.watch(gameScreenProvider(_key).notifier);
    final runtime = notifier.plugins;
    if (runtime == null || !runtime.hasPlugins) return const [];
    final vars = ref.watch(gameStateProvider).variables;
    final nodeId = notifier.currentNodeId;
    return [
      for (final area in const ['hud', 'drawer', 'overlay', 'menu'])
        PluginSlotLayer(
          key: ValueKey('plugin_slot_$area'),
          runtime: runtime,
          area: area,
          questId: widget.questId,
          vars: vars,
          nodeId: nodeId,
        ),
      // Поверх слотов: плагин, взявший `screen`, перекрывает игру целиком.
      Positioned.fill(
        child: PluginScreenLayer(
          key: const ValueKey('plugin_screen'),
          runtime: runtime,
          questId: widget.questId,
          vars: vars,
          nodeId: nodeId,
        ),
      ),
    ];
  }

  Widget _buildBackground(
    GameScreenState screenState,
    double? scriptBlur,
    bool dimBackground,
  ) {
    // Скрипт (`set_blur`) перекрывает поле ноды, поле ноды — дефолт:
    // см. `resolveBackgroundBlur`.
    final nodeBlur = screenState.currentNode?.backgroundBlur;
    final blurValue = resolveBackgroundBlur(
      scriptBlur: scriptBlur,
      nodeBlur: nodeBlur,
    );

    // Prioritize video background over image
    final hasVideo =
        screenState.backgroundVideoPath != null &&
        screenState.backgroundVideoPath!.isNotEmpty;
    final hasImage =
        screenState.backgroundImagePath != null &&
        screenState.backgroundImagePath!.isNotEmpty;
    final blurSigma = gateBackgroundBlur(
      blurValue,
      disabled: _disableBackgroundBlur,
    );
    final bool useBlur = shouldApplyBackgroundBlur(blurSigma);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasVideo)
          _BackgroundVideo(
            path: screenState.backgroundVideoPath!,
            // Сигму берём тот же гейт, что и для картинки. Дальше она уходит
            // не в `ImageFiltered`, а в фильтр mpv: видео-кадр — внешняя
            // текстура, и поверх неё движок фильтр не рисует (#206).
            blurValue: blurSigma,
            muted: screenState.currentNode?.backgroundVideoMuted ?? true,
            loop: screenState.currentNode?.backgroundVideoLoop ?? true,
            fit: _videoFitOf(screenState.currentNode?.backgroundVideoFit),
            volume:
                (screenState.currentNode?.backgroundVideoVolume ?? 1.0) *
                ref.watch(globalAudioVolumeProvider),
          )
        else if (hasImage)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: useBlur
                ? ImageFiltered(
                    key: ValueKey(screenState.backgroundImagePath),
                    imageFilter: ImageFilter.blur(
                      sigmaX: blurSigma,
                      sigmaY: blurSigma,
                    ),
                    child: Image.file(
                      File(screenState.backgroundImagePath!),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      cacheWidth:
                          MediaQuery.of(context).size.width.toInt() *
                          (MediaQuery.of(context).devicePixelRatio.toInt()),
                      gaplessPlayback: true,
                    ),
                  )
                : Image.file(
                    key: ValueKey(screenState.backgroundImagePath),
                    File(screenState.backgroundImagePath!),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    cacheWidth:
                        MediaQuery.of(context).size.width.toInt() *
                        (MediaQuery.of(context).devicePixelRatio.toInt()),
                    gaplessPlayback: true,
                  ),
          )
        else
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0a0a0f), Color(0xFF1a1a2e)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        if (dimBackground) Container(color: Colors.black.withOpacity(0.5)),
      ],
    );
  }

  void _onListScroll() {
    final controller = _listController;
    if (!controller.hasClients) return;
    // Во время перехода между нодами (flip/page) в дереве живут две ноды
    // на одном контроллере — offset/position assert'ят при нескольких
    // позициях, поэтому скролл в это время не сохраняем.
    if (controller.positions.length != 1) return;
    final presentationId = _currentPresentationId;
    if (presentationId == null || presentationId.isEmpty) return;
    // Во время ре-ривила список пуст (maxScrollExtent == 0) — не затираем
    // сохранённый offset нулём.
    if (controller.position.maxScrollExtent <= 0) return;
    _scrollByPresentation[presentationId] = controller.offset;
    if (_scrollByPresentation.length > 64) {
      _scrollByPresentation.remove(_scrollByPresentation.keys.first);
    }
  }

  void _restoreScroll() {
    final controller = _listController;
    if (!controller.hasClients) return;
    // См. _onListScroll: во время перехода между нодами две позиции —
    // восстановление не требуется (новая нода стартует сверху).
    if (controller.positions.length != 1) return;
    final presentationId = _currentPresentationId;
    if (presentationId == null) return;
    final target = _scrollByPresentation[presentationId];
    if (target == null || target <= 0) return;
    final position = controller.position;
    final maxExtent = position.maxScrollExtent;
    if (maxExtent <= 0) return;
    final desired = target.clamp(0.0, maxExtent);
    if ((position.pixels - desired).abs() < 0.5) return;
    controller.jumpTo(desired);
  }

  Future<void> _showLoadGame() async {
    final slot = await Navigator.of(context).push<SaveSlot>(
      MaterialPageRoute(
        builder: (_) =>
            LoadGameScreen(questId: widget.questId, isTesting: false),
      ),
    );

    if (slot != null && mounted) {
      ref
          .read(gameScreenProvider(_key).notifier)
          .loadInitialNode(slot.currentNodeId, saveSlot: slot);
    }
  }

  Future<void> _showSaveDialog() async {
    if (!mounted) return;

    final slots = await ref.read(saveSlotsProvider(widget.questId).future);
    if (!mounted) return;
    final manualSlots = slots
        .where((s) => s.id != SaveGameService.autosaveId)
        .length;

    final nameController = TextEditingController(
      text: 'Сохранение ${manualSlots + 1}',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text(
          'Сохранить игру',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(labelText: 'Имя сохранения'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text(
              'Сохранить',
              style: TextStyle(color: Colors.green),
            ),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && mounted) {
      final saved = await ref
          .read(gameScreenProvider(_key).notifier)
          .saveSlot(result);
      if (!saved) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сохранено!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }
}

/// Редкие кнопки игровой шапки — в одном «⋮» вместо трёх пилюль в ряд.
///
/// Шапка лежит поверх фона квеста и не резиновая: вместе с «Громкостью»,
/// «Сохранить» и «Загрузить» дополнительные кнопки не влезают в узкий
/// телефон, и AppBar рисует их поверх «назад».
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.reveal,
    required this.debug,
    required this.edit,
    required this.onReveal,
    required this.onDebug,
    required this.onEdit,
  });

  final bool reveal;
  final bool debug;
  final bool edit;
  final VoidCallback onReveal;
  final VoidCallback onDebug;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final items = <PopupMenuEntry<String>>[
      if (reveal) _item('reveal', Icons.animation_rounded, 'Появление текста'),
      if (debug)
        _item('debug', Icons.bug_report, 'Переменные', color: Colors.amber),
      if (edit)
        _item(
          'edit',
          Icons.edit,
          'Редактировать ноду',
          color: Colors.blueAccent,
        ),
    ];

    return PopupMenuButton<String>(
      tooltip: 'Ещё',
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withOpacity(0.3),
      ),
      itemBuilder: (context) => items,
      onSelected: (value) {
        switch (value) {
          case 'reveal':
            onReveal();
          case 'debug':
            onDebug();
          case 'edit':
            onEdit();
        }
      },
    );
  }

  static PopupMenuItem<String> _item(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _NodeLoadingView extends StatelessWidget {
  const _NodeLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          SizedBox(height: 14),
          Text(
            'Загрузка сцены...',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// `backgroundVideoFit` ноды → [BoxFit]. Имена пишутся как в Flutter, но
/// регистр и `_` в квестах гуляют, поэтому сравниваем нормализованно.
/// Неизвестное значение — cover, как было до появления настройки.
BoxFit _videoFitOf(String? name) {
  switch (name?.toLowerCase().replaceAll('_', '')) {
    case 'contain':
      return BoxFit.contain;
    case 'fill':
      return BoxFit.fill;
    case 'fitwidth':
      return BoxFit.fitWidth;
    case 'fitheight':
      return BoxFit.fitHeight;
    case 'none':
      return BoxFit.none;
    case 'scaledown':
      return BoxFit.scaleDown;
    default:
      return BoxFit.cover;
  }
}

class _BackgroundVideo extends StatefulWidget {
  final String path;
  final double blurValue;

  /// Флаги ноды: `backgroundVideoMuted`/`backgroundVideoVolume` (громкость уже
  /// умножена на глобальную множитель игрока). Раньше фон был заглушён намертво.
  final bool muted;
  final double volume;

  /// `backgroundVideoLoop` ноды. false — проиграть один раз и остановиться.
  final bool loop;

  /// `backgroundVideoFit` ноды.
  final BoxFit fit;
  const _BackgroundVideo({
    required this.path,
    required this.blurValue,
    required this.muted,
    required this.volume,
    required this.loop,
    required this.fit,
  });

  @override
  State<_BackgroundVideo> createState() => _BackgroundVideoState();
}

class _BackgroundVideoState extends State<_BackgroundVideo> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errorSub;
  bool _unavailable = false;

  /// `Video` монтируем только после успешного `open`: controller без медиа
  /// ещё не имеет кадра, а Linux-бэкенд media_kit в этот момент шлёт
  /// `VideoOutput.Resize` 1×1. На программном пути это кончалось крашем
  /// всего процесса (см. `texture_sw_copy_pixels`).
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  bool _isLinuxMpAvailable() {
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

  Future<void> _init() async {
    if (Platform.isLinux && !_isLinuxMpAvailable()) {
      if (mounted) setState(() => _unavailable = true);
      return;
    }
    try {
      ensureCNumericLocale();
      MediaKit.ensureInitialized();
    } catch (_) {}
    try {
      final player = Player(
        configuration: const PlayerConfiguration(title: 'bg_video'),
      );
      final controller = VideoController(
        player,
        // Аппаратный рендер (OpenGL-текстура). На false media_kit на Linux
        // уходит в программный путь, где расчёт размера текстуры делит целые
        // и для вертикального ролика получает 0, а copy_pixels отвечает
        // «успех» без кадра — Flutter регистрирует текстуру с мусорными
        // габаритами. Контентное видео в плеере давно на true, и с ним
        // крашей не наблюдаем.
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
        ),
      );
      _player = player;
      _controller = controller;
      _errorSub = player.stream.error.listen((e) {
        if (!mounted) return;
        if (kDebugMode) {
          debugPrint('Фоновое видео ноды: $e');
        }
        setState(() => _unavailable = true);
      });
      await player.setVolume(_targetVolume());
      // single = гонять по кругу текущий файл, none = остановиться в конце.
      await player.setPlaylistMode(_playlistMode);
      await player.open(Media('file://${widget.path}'), play: true);
      // Фильтр ставим до первого показа: иначе кадр-два фон резкий.
      await _applyMpvBlur();
      if (mounted) setState(() => _opened = true);
    } catch (_) {
      if (mounted) setState(() => _unavailable = true);
    }
  }

  /// Размытие кадра на десктопе делает mpv, а не `ImageFiltered` вокруг `Video`:
  /// кадр приходит внешней GL-текстурой, и движок не прогоняет её через
  /// offscreen-пасс — фильтр молча не применялся (#206: сигма доходила,
  /// размытия не было). Мобильная libmpv ffmpeg-фильтров не несёт, там
  /// размывает слой поверх кадра — см. `backgroundVideoBlurRoute` (#223).
  /// `setProperty` есть только у нативной реализации, в web-стабе этого
  /// метода нет, поэтому вызов через dynamic.
  Future<void> _applyMpvBlur() async {
    final platform = _player?.platform;
    if (kIsWeb || platform is! NativePlayer) return;
    final filter = mpvBackgroundBlurFilter(
      defaultTargetPlatform.name,
      widget.blurValue,
    );
    try {
      await (platform as dynamic).setProperty('vf', filter ?? '');
    } catch (e) {
      // Молча проглоченный отказ — это ровно то, из-за чего #206 и #223
      // ловились вслепую: сигма есть, фильтра нет, в логе пусто.
      if (kDebugMode) {
        debugPrint(
          'Фоновое видео ноды: mpv не принял фильтр '
          '"${filter ?? 'снят'}" — $e',
        );
      }
    }
  }

  PlaylistMode get _playlistMode =>
      widget.loop ? PlaylistMode.single : PlaylistMode.none;

  /// Шкала media_kit — 0..100, наш множитель 0..1.
  double _targetVolume() => widget.muted ? 0 : (widget.volume * 100).clamp(
    0.0,
    100.0,
  );

  @override
  void didUpdateWidget(covariant _BackgroundVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _player?.open(Media('file://${widget.path}'), play: true);
    }
    if (oldWidget.loop != widget.loop) {
      _player?.setPlaylistMode(_playlistMode);
    }
    if (oldWidget.muted != widget.muted || oldWidget.volume != widget.volume) {
      _player?.setVolume(_targetVolume());
    }
    // `set_blur` посреди ноды меняет сигму — меняем и фильтр mpv.
    if (oldWidget.path != widget.path || oldWidget.blurValue != widget.blurValue) {
      _applyMpvBlur();
    }
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable || !_opened || _controller == null) {
      return Container(color: Colors.black);
    }
    // Размытие кадра — не `ImageFiltered` (поверх внешней текстуры движок его
    // не применяет), а выбор по платформе: на десктопе фильтр делает mpv до
    // того, как кадр стал текстурой, на мобильных — слой над кадром.
    // `controls` по умолчанию — `AdaptiveVideoControls`: тап по фону вызывал
    // панель плеера поверх игры. `wakelock: true` — фоновый ролик держал бы
    // экран включённым отдельно от того, что уже делает сессия игры.
    final video = Video(
      controller: _controller!,
      fit: widget.fit,
      controls: null,
      wakelock: false,
    );
    final frame = KeyedSubtree(key: ValueKey(widget.path), child: video);
    final blurRoute = backgroundVideoBlurRoute(
      defaultTargetPlatform.name,
      widget.blurValue,
    );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: blurRoute == VideoBlurRoute.backdrop
          // Мобильный libmpv ffmpeg-фильтров не несёт (#223), а `ImageFiltered`
          // вокруг `Texture` движок не применяет. Работает обратный порядок:
          // кадр рисуется первым, а поверх него — `BackdropFilter`, который
          // берёт уже накопленный под ним backdrop.
          ? Stack(
              fit: StackFit.expand,
              children: [
                frame,
                Positioned.fill(
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: mobileBackdropBlurSigma(widget.blurValue),
                        sigmaY: mobileBackdropBlurSigma(widget.blurValue),
                      ),
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                ),
              ],
            )
          : frame,
    );
  }
}
