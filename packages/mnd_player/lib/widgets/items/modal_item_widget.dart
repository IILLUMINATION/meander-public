import 'dart:async';

import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/services/trigger_pipeline.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';
import 'package:mnd_player/providers/game_session_scope.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/providers/quest_provider.dart';
import 'package:mnd_player/widgets/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_core/utils/quest_paths.dart';

typedef OnNavigateToNode = void Function(String nodeId);
typedef OnTransition = void Function(String nodeId);

/// Виджет всплывающего модального окна на базе AlertDialog
class ModalItemWidget extends ConsumerStatefulWidget {
  final ContentItem item;
  final String questId;
  final OnNavigateToNode? onNavigateToNode;
  final OnTransition? onTransition;
  final VoidCallback? onComplete;
  final String? fontFamily;
  final String scriptEngineMode;

  const ModalItemWidget({
    super.key,
    required this.item,
    required this.questId,
    this.onNavigateToNode,
    this.onTransition,
    this.onComplete,
    this.fontFamily,
    this.scriptEngineMode = 'new',
  });

  @override
  ConsumerState<ModalItemWidget> createState() => _ModalItemWidgetState();
}

class _ModalItemWidgetState extends ConsumerState<ModalItemWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  bool _hasShown = false;
  Timer? _autoCloseTimer;
  Timer? _timerUpdateTimer; // Таймер для обновления UI обратного отсчёта
  final ValueNotifier<int> _remainingSecondsNotifier = ValueNotifier<int>(0);
  bool _showTimer = false;
  int _totalSeconds = 0;

  /// Маршрут открытого диалога: `showGeneralDialog` его не возвращает, а без
  /// него окно не снять. Запоминаем именно маршрут, а не «верхний экран»,
  /// чтобы убирать своё окно, а не чужое: владелец-айтем живёт в списке ноды,
  /// и при смене ноды барьер с некликабельными кнопками остался бы поверх
  /// новой сцены — квест дальше не играется.
  Route? _dialogRoute;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _scaleAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutBack,
    );

    // Показываем модалку только один раз
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasShown) {
        _hasShown = true;
        _showModal();
      }
    });
  }

  Future<void> _showModal() async {
    final gameStateNotifier = ref.read(gameStateProvider.notifier);

    // Проверяем, является ли окно режимом автоматического закрытия
    final isAutoClose = widget.item.targetNodeId == '_CLOSE_MODAL';

    // Проверяем, нужно ли показывать таймер
    _showTimer = widget.item.showTimer;

    // Парсим заголовок с поддержкой формул
    final title = _parseTextWithVariables(
      widget.item.buttonText ?? 'Уведомление',
      gameStateNotifier,
    );

    // Содержимое хранится в поле contentMarkdown и отображается всегда
    final content = _parseTextWithVariables(
      widget.item.contentMarkdown ?? '',
      gameStateNotifier,
    );
    final allowTextCopy =
        ref.read(questProvider(widget.questId)).valueOrNull?.allowTextCopy ??
        false;

    if (!mounted) return;

    _animationController.forward();

    // Если режим автоматического закрытия, запускаем таймер
    if (isAutoClose) {
      final delaySeconds = int.tryParse(widget.item.text ?? '2') ?? 2;
      _totalSeconds = delaySeconds;
      _remainingSecondsNotifier.value = delaySeconds;

      // Запускаем таймер обновления UI
      if (_showTimer && mounted) {
        _timerUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_remainingSecondsNotifier.value > 0) {
            _remainingSecondsNotifier.value--;
          } else {
            timer.cancel();
          }
        });
      }

      _autoCloseTimer = Timer(Duration(seconds: delaySeconds), () {
        if (mounted) {
          unawaited(_closeModalAndRunDefaultAction());
        }
      });
    }

    // showGeneralDialog, а не showDialog: последний на каждой перестройке
    // маршрута читает тему/направления/MediaQuery из контекста вызвавшего
    // виджета. Наш контекст к моменту закрытия уже мёртв — в debug это
    // «Looking up a deactivated widget's ancestor is unsafe».
    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.7),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 200),
      transitionBuilder: (dialogContext, animation, _, child) => FadeTransition(
        opacity: animation,
        child: SafeArea(child: child),
      ),
      pageBuilder: (dialogContext, _, __) {
        // Маршрут нужен в dispose(): showGeneralDialog его наружу не отдаёт.
        _dialogRoute ??= ModalRoute.of(dialogContext);
        if (!mounted) return const SizedBox.shrink();
        return FadeTransition(
          opacity: _scaleAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: AlertDialog(
              backgroundColor: const Color(0xFF2D2D2D),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: Colors.white.withOpacity(0.15),
                  width: 1,
                ),
              ),
              title: title.isNotEmpty
                  ? Row(
                      children: [
                        if (widget.item.backgroundColor != null)
                          Container(
                            width: 4,
                            height: 24,
                            decoration: BoxDecoration(
                              color: widget.item.backgroundColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        if (widget.item.backgroundColor != null)
                          const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              fontFamily: widget.fontFamily,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  : null,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (content.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.of(dialogContext).size.height * 0.4,
                      ),
                      child: SingleChildScrollView(
                        child: allowTextCopy
                            ? SelectableText(
                                content,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 15,
                                  height: 1.5,
                                  fontFamily: widget.fontFamily,
                                ),
                              )
                            : Text(
                                content,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 15,
                                  height: 1.5,
                                  fontFamily: widget.fontFamily,
                                ),
                              ),
                      ),
                    ),
                  // Визуальный таймер
                  if (isAutoClose && _showTimer)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: ValueListenableBuilder<int>(
                        valueListenable: _remainingSecondsNotifier,
                        builder: (context, remainingSeconds, _) {
                          final progress = _totalSeconds > 0
                              ? remainingSeconds / _totalSeconds
                              : 0.0;
                          return Column(
                            children: [
                              LinearProgressIndicator(
                                value: progress,
                                backgroundColor: Colors.white24,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF00C853),
                                ),
                                minHeight: 8,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Закрытие через $remainingSeconds сек.',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  fontFamily: widget.fontFamily,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                ],
              ),
              actions: _buildModalActions(gameStateNotifier),
              actionsPadding: const EdgeInsets.all(16),
            ),
          ),
        );
      },
    );

    // После закрытия диалога
    if (mounted) {
      widget.onComplete?.call();
    }
  }

  /// Кнопки строятся внутри маршрута диалога, поэтому `GameStateNotifier`
  /// передаётся извне: `ref` после смерти виджета уже не читается.
  List<Widget> _buildModalActions(GameStateNotifier gameState) {
    final buttons = <Widget>[];

    // Если есть кнопки modalButtons, используем их
    if (widget.item.modalButtons != null &&
        widget.item.modalButtons!.isNotEmpty) {
      for (final button in widget.item.modalButtons!) {
        buttons.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: GlassSurface(
                radius: 12,
                blurSigma: 4,
                tintColor: button.isPrimary
                    ? const Color(0xFF00C853).withOpacity(0.15)
                    : Colors.white.withOpacity(0.08),
                borderColor: button.isPrimary
                    ? const Color(0xFF00C853).withOpacity(0.5)
                    : Colors.white.withOpacity(0.18),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _handleButtonTap(button),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 24,
                      ),
                      child: Text(
                        _parseTextWithVariables(button.text, gameState),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: button.isPrimary
                              ? const Color(0xFF00C853)
                              : Colors.white,
                          fontSize: 16,
                          fontFamily: widget.fontFamily,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    } else {
      // Старая логика с одной кнопкой
      final closeButtonText = _parseTextWithVariables(
        widget.item.placeholderText ?? 'Закрыть',
        gameState,
      );

      buttons.add(
        SizedBox(
          width: double.infinity,
          child: GlassSurface(
            radius: 12,
            blurSigma: 4,
            tintColor: Colors.white.withOpacity(0.08),
            borderColor: Colors.white.withOpacity(0.18),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => unawaited(_closeModalAndRunDefaultAction()),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 24,
                  ),
                  child: Text(
                    closeButtonText,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontFamily: widget.fontFamily,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return buttons;
  }

  Future<void> _handleButtonTap(ModalButtonConfig button) async {
    _closeModal();

    // Небольшая задержка перед выполнением действия
    await Future.delayed(const Duration(milliseconds: 100));

    if (!mounted) return;

    // Выполняем переход или скрипт
    if (button.targetNodeId != null && button.targetNodeId != '_CLOSE_MODAL') {
      widget.onTransition?.call(button.targetNodeId!);
    } else if (button.scriptAssetId != null) {
      await _executeScriptForButton(button.scriptAssetId!);
    }
  }

  Future<void> _executeScriptForButton(String scriptAssetId) async {
    try {
      final relativeScriptPath = await _resolveScriptPath(scriptAssetId);
      if (relativeScriptPath == null) {
        debugPrint('Скрипт не найден: $scriptAssetId');
        return;
      }

      final provider = ref.read(
        gameScreenProvider(
          GameSessionScope.of(context, widget.questId),
        ).notifier,
      );
      final engine = provider.engine;
      final pipeline = TriggerPipeline(
        questId: widget.questId,
        gameState: ref.read(gameStateProvider.notifier),
        engine: engine!,
      );
      final item = ContentItem(
        id: 'modal_btn',
        type: 'button',
        behaviours: [
          ContentTrigger(event: 'onPress', script: relativeScriptPath),
        ],
      );
      final nextNodeId = await pipeline.execute(item, 'onPress');
      await provider.syncEngineState();
      if (!mounted) return;
      if (nextNodeId != null && nextNodeId.isNotEmpty) {
        widget.onTransition?.call(nextNodeId);
      }
    } catch (e) {
      debugPrint('Ошибка выполнения скрипта: $e');
    }
  }

  Future<void> _closeModalAndRunDefaultAction() async {
    final targetNodeId = widget.item.targetNodeId;
    final scriptAssetId = widget.item.scriptAssetId;
    _closeModal();

    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;

    if (targetNodeId != null &&
        targetNodeId.isNotEmpty &&
        targetNodeId != '_CLOSE_MODAL') {
      widget.onTransition?.call(targetNodeId);
      return;
    }

    if (scriptAssetId != null && scriptAssetId.isNotEmpty) {
      await _executeScriptForButton(scriptAssetId);
    }
  }

  Future<String?> _resolveScriptPath(String scriptAssetId) async {
    final normalized = scriptAssetId.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) return null;

    final direct = QuestPaths.questFile(widget.questId, normalized);
    if (await FileStorage.exists(direct)) return normalized;

    if (!normalized.endsWith('.json') && !normalized.contains('/')) {
      final inScripts = 'scripts/$normalized.json';
      if (await FileStorage.exists(
        QuestPaths.questFile(widget.questId, inScripts),
      )) {
        return inScripts;
      }
      final inInternal = '_internal_scripts/$normalized.json';
      if (await FileStorage.exists(
        QuestPaths.questFile(widget.questId, inInternal),
      )) {
        return inInternal;
      }
    }
    return null;
  }

  void _closeModal() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = null;
    _timerUpdateTimer?.cancel();
    _timerUpdateTimer = null;
    _dialogRoute = null;
    Navigator.of(context, rootNavigator: true).pop();
  }

  String _parseTextWithVariables(String text, GameStateNotifier notifier) {
    return ScriptExecutor.substitutePlaceholders(
      ScriptExecutor.collapseDoubleBraces(text),
      (expression) => formatScriptValue(
        ScriptExecutor.evaluateExpression(expression, notifier),
      ),
    );
  }

  @override
  void dispose() {
    _autoCloseTimer?.cancel();
    _timerUpdateTimer?.cancel();
    final route = _dialogRoute;
    _dialogRoute = null;
    _remainingSecondsNotifier.dispose();
    _animationController.dispose();
    if (route != null) {
      final navigator = route.navigator;
      if (navigator != null) {
        // Нода сменилась, пока окно открыто: снимаем именно свой маршрут.
        // `pop()` чужого маршрута оставил бы висеть мёртвую модалку, а её
        // кнопки уже не работают — владелец уничтожен, барьер некликабельный.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (navigator.mounted && route.isActive) navigator.removeRoute(route);
        });
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Виджет ничего не рендерит, всё показывает через showDialog
    return const SizedBox.shrink();
  }
}
