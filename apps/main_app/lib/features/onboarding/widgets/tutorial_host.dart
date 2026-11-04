import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/onboarding/controllers/tutorial_controller.dart';

/// Корневой оверлей обучения. Должен быть смонтирован поверх всей навигации
/// (внутри `MaterialApp.builder`), чтобы оставаться видимым при переходах
/// между экранами.
///
/// Сам по себе пустой Stack. Когда обучение активно — поверх child
/// рисует затемнение с «вырезом» вокруг подсвечиваемого виджета и карточку
/// с подсказкой.
class TutorialHost extends ConsumerStatefulWidget {
  final Widget child;
  const TutorialHost({super.key, required this.child});

  @override
  ConsumerState<TutorialHost> createState() => _TutorialHostState();
}

class _TutorialHostState extends ConsumerState<TutorialHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  /// Тикер, который раз в кадр триггерит перерисовку — нужен, чтобы
  /// подсветка следовала за виджетом, когда тот меняет геометрию
  /// (например, после открытия клавиатуры или анимации).
  late final _Ticker _ticker = _Ticker(_onTick);

  Rect? _lastTargetRect;
  TutorialStep? _lastStep;
  String? _lastTargetId;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    // Тикер и пульсацию запускаем только на время активного обучения:
    // вечно висящий repeat()-контроллер гнал кадры (и ~ядро CPU) даже на
    // экранах, где туториала нет и подсветка не рисуется вовсе.
    ref.listenManual(
      tutorialControllerProvider.select((s) => s.isActive),
      (previous, next) => _setTutorialActive(next),
      fireImmediately: true,
    );
  }

  void _setTutorialActive(bool active) {
    if (active) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
      _ticker.start();
    } else {
      _pulseController.stop();
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    final tutorialState = ref.read(tutorialControllerProvider);
    if (!tutorialState.isActive) return;

    // При смене шага или цели — пытаемся доскроллить экран до подсветки.
    final ctrl = ref.read(tutorialControllerProvider.notifier);
    final currentTargetId = ctrl.currentTargetId();
    if (tutorialState.step != _lastStep || currentTargetId != _lastTargetId) {
      _lastStep = tutorialState.step;
      _lastTargetId = currentTargetId;
      _scheduleScrollToTarget(tutorialState, currentTargetId);
    }

    final newRect = _computeTargetRect(tutorialState);
    if (newRect != _lastTargetRect) {
      setState(() => _lastTargetRect = newRect);
    }
  }

  /// Если у текущей цели зарегистрирован GlobalKey и она находится внутри
  /// скроллящегося контейнера — скроллим до неё, чтобы пользователь
  /// увидел подсветку целиком.
  void _scheduleScrollToTarget(TutorialState s, String? id) {
    if (id == null) return;
    final key = s.targets[id];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key?.currentContext;
      if (ctx == null) return;
      try {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: 0.4,
        );
      } catch (_) {
        // Виджет может не быть внутри Scrollable — это нормально.
      }
    });
  }

  Rect? _computeTargetRect(TutorialState s) {
    final id = ref.read(tutorialControllerProvider.notifier).currentTargetId();
    if (id == null) return null;
    final key = s.targets[id];
    final ctx = key?.currentContext;
    if (ctx == null) return null;
    final renderObject = ctx.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return null;
    final offset = renderObject.localToGlobal(Offset.zero);
    return offset & renderObject.size;
  }

  @override
  Widget build(BuildContext context) {
    final tutorialState = ref.watch(tutorialControllerProvider);

    return Stack(
      children: [
        widget.child,
        if (tutorialState.isActive)
          Positioned.fill(
            child: _TutorialOverlay(
              state: tutorialState,
              targetRect: _lastTargetRect,
              pulse: _pulseController,
            ),
          ),
      ],
    );
  }
}

// ============================================================================
//  TICKER
// ============================================================================

/// Простой тикер на каждый кадр — `SchedulerBinding.addPostFrameCallback`
/// в цикле.
class _Ticker {
  final void Function(Duration) onTick;
  bool _running = false;
  Duration _last = Duration.zero;

  _Ticker(this.onTick);

  void start() {
    if (_running) return;
    _running = true;
    WidgetsBinding.instance.addPostFrameCallback(_step);
  }

  void stop() {
    _running = false;
  }

  void _step(Duration ts) {
    if (!_running) return;
    onTick(ts - _last);
    _last = ts;
    WidgetsBinding.instance.addPostFrameCallback(_step);
  }

  void dispose() {
    _running = false;
  }
}

// ============================================================================
//  OVERLAY
// ============================================================================

class _TutorialOverlay extends ConsumerWidget {
  final TutorialState state;
  final Rect? targetRect;
  final Animation<double> pulse;

  const _TutorialOverlay({
    required this.state,
    required this.targetRect,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = state.step;
    final scheme = Theme.of(context).colorScheme;

    // Модальные шаги — без подсветки виджета
    if (step == TutorialStep.welcome) {
      return _ModalStep(
        icon: Icons.school_rounded,
        title: tr('Добро пожаловать!'),
        body: tr('Я покажу, как создать твой первый квест. Это займёт около минуты — просто следуй подсказкам.'),
        primaryLabel: tr('Поехали'),
        onPrimary: () => ref.read(tutorialControllerProvider.notifier).next(),
        secondaryLabel: tr('Я уже знаю'),
        onSecondary: () => ref.read(tutorialControllerProvider.notifier).skip(),
      );
    }

    if (step == TutorialStep.editorIntroModal) {
      return _ModalStep(
        icon: Icons.account_tree_rounded,
        title: tr('Это редактор твоей истории'),
        body: tr('Каждый прямоугольник — это нода: страница с текстом и кнопками выбора. Линии между нодами — переходы. Тапни «+» снизу, чтобы создать новую ноду.'),
        primaryLabel: tr('Понятно'),
        onPrimary: () => ref.read(tutorialControllerProvider.notifier).next(),
        secondaryLabel: tr('Я уже знаю'),
        onSecondary: () => ref.read(tutorialControllerProvider.notifier).skip(),
      );
    }

    if (step == TutorialStep.openChapterModal) {
      return _ModalStep(
        icon: Icons.menu_book_rounded,
        title: tr('Глава создана!'),
        body: tr('Главы группируют ноды по разделам сюжета. Тапни по своей новой главе — откроется визуальный редактор, где ты будешь рисовать историю.'),
        primaryLabel: tr('Понятно'),
        onPrimary: () => ref.read(tutorialControllerProvider.notifier).next(),
        secondaryLabel: tr('Я уже знаю'),
        onSecondary: () => ref.read(tutorialControllerProvider.notifier).skip(),
      );
    }

    if (step == TutorialStep.editTextModal) {
      return _ModalStep(
        icon: Icons.touch_app_rounded,
        title: tr('Редактирование ноды'),
        body: tr('Двойной тап по любой ноде открывает редактор: добавляй текст, картинки, кнопки выбора. Двойной тап по стрелке — настройка условия перехода.'),
        primaryLabel: tr('Понятно'),
        onPrimary: () => ref.read(tutorialControllerProvider.notifier).next(),
        secondaryLabel: tr('Я уже знаю'),
        onSecondary: () => ref.read(tutorialControllerProvider.notifier).skip(),
      );
    }

    if (step == TutorialStep.finished) {
      return _ModalStep(
        icon: Icons.celebration_rounded,
        title: tr('Готово! 🎉'),
        body: tr('Теперь ты знаешь основы. Создавай ноды, рисуй связи, добавляй тексты — твоя история готова. Когда захочешь поделиться — опубликуй квест в маркете. Повторить обучение можно в Настройки → Помощь.'),
        primaryLabel: tr('Отлично!'),
        onPrimary: () => ref.read(tutorialControllerProvider.notifier).finish(),
      );
    }

    // Шаги с подсветкой
    final rect = targetRect;
    if (rect == null) {
      // Цель ещё не зарегистрирована — показываем мягкое затемнение
      // без выреза, чтобы пользователь видел, что обучение активно.
      return _WaitingForTargetOverlay(
        message: _waitingMessage(step),
        onSkip: () => ref.read(tutorialControllerProvider.notifier).skip(),
      );
    }

    return Stack(
      children: [
        _HighlightStep(
          step: step,
          targetRect: rect,
          pulse: pulse,
          scheme: scheme,
          onNext: () => ref.read(tutorialControllerProvider.notifier).next(),
          onSkip: () => ref.read(tutorialControllerProvider.notifier).skip(),
        ),
        // На шаге «включи режим связей» дополнительно показываем
        // анимацию жеста «перетяни от ноды к ноде».
        if (step == TutorialStep.connectModeHighlight)
          const Positioned.fill(
            child: IgnorePointer(child: _DragGestureHint()),
          ),
      ],
    );
  }

  String _waitingMessage(TutorialStep step) {
    switch (step) {
      case TutorialStep.highlightCreateButton:
        return tr('Перейди в библиотеку квестов…');
      case TutorialStep.fillTitle:
      case TutorialStep.fillAuthor:
      case TutorialStep.fillDescription:
      case TutorialStep.pressCreate:
        return tr('Открой экран «Создать квест»…');
      case TutorialStep.openQuestCard:
        return tr('Вернись в библиотеку квестов…');
      case TutorialStep.openEditor:
        return tr('Открой экран квеста…');
      case TutorialStep.highlightCreateChapter:
        return tr('Открой «Сценарий и Главы»…');
      case TutorialStep.addNodeHighlight:
      case TutorialStep.connectModeHighlight:
      case TutorialStep.runQuestHighlight:
        return tr('Открой главу — там встретимся в редакторе…');
      default:
        return tr('Подождите…');
    }
  }
}

// ============================================================================
//  МОДАЛЬНЫЙ ШАГ (welcome / finished)
// ============================================================================

class _ModalStep extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  const _ModalStep({
    required this.icon,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Colors.black.withOpacity(0.72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Material(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            scheme.primaryContainer,
                            scheme.tertiaryContainer,
                          ],
                        ),
                      ),
                      child: Icon(
                        icon,
                        size: 36,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      body,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        if (secondaryLabel != null)
                          Expanded(
                            child: OutlinedButton(
                              onPressed: onSecondary,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: Text(secondaryLabel!),
                            ),
                          ),
                        if (secondaryLabel != null) const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: onPrimary,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Text(primaryLabel),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  ОЖИДАНИЕ ЦЕЛИ
// ============================================================================

class _WaitingForTargetOverlay extends StatelessWidget {
  final String message;
  final VoidCallback onSkip;

  const _WaitingForTargetOverlay({required this.message, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: false,
      child: Stack(
        children: [
          // Прозрачный слой — клики проходят к приложению.
          const Positioned.fill(child: SizedBox()),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: SafeArea(
              child: Material(
                color: scheme.inverseSurface,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.school_rounded,
                        color: scheme.onInverseSurface,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          message,
                          style: TextStyle(
                            color: scheme.onInverseSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: onSkip,
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.inversePrimary,
                        ),
                        child: Text(tr('Пропустить')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  ШАГ С ПОДСВЕТКОЙ
// ============================================================================

class _HighlightStep extends StatelessWidget {
  final TutorialStep step;
  final Rect targetRect;
  final Animation<double> pulse;
  final ColorScheme scheme;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const _HighlightStep({
    required this.step,
    required this.targetRect,
    required this.pulse,
    required this.scheme,
    required this.onNext,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context).size;
    final tipPosition = _calcTooltipPlacement(mq, targetRect);

    final padding = 12.0;
    final hole = Rect.fromLTRB(
      targetRect.left - padding,
      targetRect.top - padding,
      targetRect.right + padding,
      targetRect.bottom + padding,
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 1. Подсвечивающий слой. Поглощает все клики, кроме области цели.
        Positioned.fill(
          child: _SpotlightLayer(hole: hole, pulse: pulse, scheme: scheme),
        ),

        // 2. Карточка-подсказка.
        Positioned(
          left: tipPosition.left,
          right: tipPosition.right,
          top: tipPosition.top,
          bottom: tipPosition.bottom,
          child: _TutorialTooltip(
            text: _tooltipText(step),
            actionLabel: _actionLabel(step),
            onNext: onNext,
            onSkip: onSkip,
            requiresUserAction: _requiresUserAction(step),
          ),
        ),
      ],
    );
  }

  String _tooltipText(TutorialStep step) {
    switch (step) {
      case TutorialStep.highlightCreateButton:
        return tr('Жми сюда, чтобы создать свой первый квест.');
      case TutorialStep.fillTitle:
        return tr('Введи название квеста — например, «Моё первое приключение».');
      case TutorialStep.fillAuthor:
        return tr('Укажи своё имя или псевдоним автора.');
      case TutorialStep.fillDescription:
        return tr('Опиши, о чём твоя история. Можно одной строкой.');
      case TutorialStep.pressCreate:
        return tr('Нажми «Создать проект», чтобы сохранить квест.');
      case TutorialStep.openQuestCard:
        return tr('Тапни по своему новому квесту, чтобы его открыть.');
      case TutorialStep.openEditor:
        return tr('Открой «Сценарий и Главы» — это редактор твоей истории.');
      case TutorialStep.highlightCreateChapter:
        return tr('Создай первую главу — это раздел сюжета с нодами.');
      case TutorialStep.addNodeHighlight:
        return tr('Жми «+», чтобы добавить первую ноду истории.');
      case TutorialStep.connectModeHighlight:
        return tr('Включи режим связей. Затем проведи жест от одной ноды к другой — это создаст связь между ними.');
      case TutorialStep.runQuestHighlight:
        return tr('Жми «Играть», чтобы протестировать свой квест.');
      default:
        return '';
    }
  }

  String _actionLabel(TutorialStep step) {
    switch (step) {
      case TutorialStep.highlightCreateButton:
      case TutorialStep.pressCreate:
      case TutorialStep.openQuestCard:
      case TutorialStep.openEditor:
      case TutorialStep.highlightCreateChapter:
      case TutorialStep.addNodeHighlight:
      case TutorialStep.connectModeHighlight:
      case TutorialStep.runQuestHighlight:
        return tr('Жду нажатия…');
      case TutorialStep.fillTitle:
      case TutorialStep.fillAuthor:
      case TutorialStep.fillDescription:
        return tr('Печатай в поле…');
      default:
        return tr('Дальше');
    }
  }

  /// Все шаги с подсветкой ждут реального действия пользователя:
  /// нажатия на кнопку или ввода текста в поле.
  /// Никаких кнопок «Дальше» в подсказке не показываем — это
  /// провоцировало ложные клики.
  bool _requiresUserAction(TutorialStep step) => true;

  /// Подбирает позицию tooltip-карточки: над целью или под ней,
  /// в зависимости от того где больше места.
  _TooltipPlacement _calcTooltipPlacement(Size screen, Rect target) {
    const margin = 16.0;
    final spaceBelow = screen.height - target.bottom;
    final spaceAbove = target.top;

    if (spaceBelow >= 220 || spaceBelow >= spaceAbove) {
      // Под целью
      return _TooltipPlacement(
        left: margin,
        right: margin,
        top: target.bottom + 18,
        bottom: null,
      );
    } else {
      // Над целью
      return _TooltipPlacement(
        left: margin,
        right: margin,
        top: null,
        bottom: screen.height - target.top + 18,
      );
    }
  }
}

class _TooltipPlacement {
  final double? left;
  final double? right;
  final double? top;
  final double? bottom;
  const _TooltipPlacement({this.left, this.right, this.top, this.bottom});
}

// ============================================================================
//  SPOTLIGHT (затемнение с «дыркой»)
// ============================================================================

class _SpotlightLayer extends StatelessWidget {
  final Rect hole;
  final Animation<double> pulse;
  final ColorScheme scheme;

  const _SpotlightLayer({
    required this.hole,
    required this.pulse,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(pulse.value);
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;

            // Кропим «дырку» в размеры экрана, на случай если виджет
            // частично за пределами.
            final clipped = Rect.fromLTRB(
              hole.left.clamp(0.0, w),
              hole.top.clamp(0.0, h),
              hole.right.clamp(0.0, w),
              hole.bottom.clamp(0.0, h),
            );

            return Stack(
              children: [
                // 1. Слой с рисованием — НЕ ловит клики (IgnorePointer).
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SpotlightPainter(
                        hole: hole,
                        glow: t,
                        glowColor: scheme.primary,
                      ),
                    ),
                  ),
                ),

                // 2. Четыре прозрачных «глушителя» по периметру дырки —
                //    они поглощают клики (AbsorbPointer), но не закрывают
                //    саму подсвеченную область. Так клик внутри дырки
                //    проходит сквозь Stack до подсвечиваемого виджета.

                // Сверху
                if (clipped.top > 0)
                  Positioned(
                    left: 0,
                    top: 0,
                    right: 0,
                    height: clipped.top,
                    child: const _TutorialClickBlocker(),
                  ),
                // Снизу
                if (clipped.bottom < h)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: clipped.bottom,
                    bottom: 0,
                    child: const _TutorialClickBlocker(),
                  ),
                // Слева от дырки
                if (clipped.left > 0)
                  Positioned(
                    left: 0,
                    top: clipped.top,
                    width: clipped.left,
                    height: clipped.height,
                    child: const _TutorialClickBlocker(),
                  ),
                // Справа от дырки
                if (clipped.right < w)
                  Positioned(
                    left: clipped.right,
                    right: 0,
                    top: clipped.top,
                    height: clipped.height,
                    child: const _TutorialClickBlocker(),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Прозрачная зона, которая ловит клики и ничего с ними не делает —
/// нужна, чтобы пользователь не мог нажимать на UI вне подсветки.
class _TutorialClickBlocker extends StatelessWidget {
  const _TutorialClickBlocker();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {}, // съедаем тап
      child: const SizedBox.expand(),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect hole;
  final double glow;
  final Color glowColor;

  _SpotlightPainter({
    required this.hole,
    required this.glow,
    required this.glowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final radius = 18.0;
    final rrect = RRect.fromRectAndRadius(hole, Radius.circular(radius));

    // Затемнение
    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final holePath = Path()..addRRect(rrect);
    final combined = Path.combine(
      PathOperation.difference,
      overlayPath,
      holePath,
    );
    final dimPaint = Paint()..color = Colors.black.withOpacity(0.72);
    canvas.drawPath(combined, dimPaint);

    // Пульсирующее свечение по контуру выреза
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 + glow * 5
      ..color = glowColor.withOpacity(0.35 + 0.45 * glow)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + glow * 8);
    canvas.drawRRect(rrect, glowPaint);

    // Тонкая обводка для чёткости
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = glowColor.withOpacity(0.95);
    canvas.drawRRect(rrect, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter old) {
    return old.hole != hole || old.glow != glow || old.glowColor != glowColor;
  }
}

// ============================================================================
//  АНИМАЦИЯ ЖЕСТА: «перетяни от ноды к ноде»
// ============================================================================

/// Полупрозрачный «палец», который циклически двигается слева направо
/// над центром экрана, имитируя жест drag между узлами. Используется
/// только во время шага `connectModeHighlight`, чтобы наглядно объяснить
/// как создаётся связь между узлами.
class _DragGestureHint extends StatefulWidget {
  const _DragGestureHint();

  @override
  State<_DragGestureHint> createState() => _DragGestureHintState();
}

class _DragGestureHintState extends State<_DragGestureHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SizedBox(
        width: 280,
        height: 160,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            // Жест: первые 70% времени двигаемся слева направо
            // с курсивом easeInOut; последние 30% — пауза с исчезновением.
            final t = _controller.value;
            final move = t < 0.7 ? Curves.easeInOut.transform(t / 0.7) : 1.0;
            final opacity = t < 0.1
                ? t / 0.1
                : (t > 0.7 ? (1 - (t - 0.7) / 0.3).clamp(0.0, 1.0) : 1.0);

            return CustomPaint(
              painter: _DragHintPainter(
                progress: move,
                opacity: opacity,
                color: scheme.primary,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DragHintPainter extends CustomPainter {
  final double progress; // 0..1 — позиция «пальца» вдоль траектории
  final double opacity;
  final Color color;

  _DragHintPainter({
    required this.progress,
    required this.opacity,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final w = size.width;

    // Две «ноды»-плейсхолдера: слева и справа, на одной высоте.
    final cy = h * 0.5;
    final leftNode = Rect.fromCenter(
      center: Offset(w * 0.16, cy),
      width: 70,
      height: 50,
    );
    final rightNode = Rect.fromCenter(
      center: Offset(w * 0.84, cy),
      width: 70,
      height: 50,
    );

    final nodePaint = Paint()
      ..color = color.withOpacity(0.25 * opacity)
      ..style = PaintingStyle.fill;
    final nodeBorder = Paint()
      ..color = color.withOpacity(0.75 * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(leftNode, const Radius.circular(10)),
      nodePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(leftNode, const Radius.circular(10)),
      nodeBorder,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rightNode, const Radius.circular(10)),
      nodePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rightNode, const Radius.circular(10)),
      nodeBorder,
    );

    // Траектория жеста — изогнутая (для красоты).
    final start = Offset(leftNode.right, cy);
    final end = Offset(rightNode.left, cy);
    final control = Offset((start.dx + end.dx) / 2, cy - 30);

    // Рисуем уже пройденную часть стрелки (от start до текущего курсора).
    final currentX = start.dx + (end.dx - start.dx) * progress;
    final currentY =
        cy - 30 * (1 - (2 * progress - 1) * (2 * progress - 1)); // парабола
    final currentPos = Offset(currentX, currentY);

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(control.dx, control.dy, currentPos.dx, currentPos.dy);

    final linePaint = Paint()
      ..color = color.withOpacity(0.85 * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, linePaint);

    // «Палец» — кружок с двумя кольцами вокруг.
    final fingerPaint = Paint()
      ..color = color.withOpacity(0.95 * opacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(currentPos, 14, fingerPaint);

    final ringPaint = Paint()
      ..color = color.withOpacity(0.35 * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(currentPos, 22, ringPaint);
    canvas.drawCircle(
      currentPos,
      30,
      ringPaint..color = color.withOpacity(0.18 * opacity),
    );
  }

  @override
  bool shouldRepaint(covariant _DragHintPainter old) {
    return old.progress != progress ||
        old.opacity != opacity ||
        old.color != color;
  }
}

// ============================================================================
//  TOOLTIP-КАРТОЧКА С ПОДСКАЗКОЙ
// ============================================================================

class _TutorialTooltip extends StatelessWidget {
  final String text;
  final String actionLabel;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final bool requiresUserAction;

  const _TutorialTooltip({
    required this.text,
    required this.actionLabel,
    required this.onNext,
    required this.onSkip,
    required this.requiresUserAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.35),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 16,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  onPressed: onSkip,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: Text(tr('Я уже знаю')),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (requiresUserAction)
                  Text(
                    actionLabel,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  )
                else
                  FilledButton.icon(
                    onPressed: onNext,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: Text(actionLabel),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
