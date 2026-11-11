import 'package:flutter/material.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:canvas_app/core/l10n/l10n.dart';

/// Настройка рамки закрепления стека: где он стоит на экране, растянут ли по
/// оси, и модальное ли это окно.
///
/// Все поля пишут одно и то же, что понимает плеер: якоря + смещения
/// ([ContentItem.stackPinAnchors]) через [ContentItem.stackPinWithAnchors] и
/// [ContentItem.stackPinWithRect]. Слайдеров здесь нет намеренно — автора
/// интересуют пиксели экрана, а не условные единицы.
class StackPinBoxEditor extends StatelessWidget {
  const StackPinBoxEditor({
    super.key,
    required this.stack,
    required this.viewport,
    required this.onChanged,
  });

  final ContentItem stack;

  /// Вьюпорт, как его видит плеер: колонка не шире 720 px, без системных
  /// вырезов. От него считаются и доли якорей, и px смещений.
  final Size viewport;

  /// Новый документ стека — коммит (и undo/шаг истории) делает вызывающий код.
  final ValueChanged<ContentItem> onChanged;

  /// То же правило, что в `game_screen`: закреплённые слои лежат в SafeArea и
  /// не шире колонки контента.
  static Size viewportOf(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    const cap = kContentColumnMaxWidth;
    return Size(
      size.width < cap ? size.width : cap,
      (size.height - pad.top - pad.bottom).clamp(160.0, 4000.0),
    );
  }

  bool _isAt(double fx, double fy) {
    final a = stack.stackPinAnchors;
    final collapsedX = (a[2] - a[0]).abs() < 1e-6;
    final collapsedY = (a[3] - a[1]).abs() < 1e-6;
    return collapsedX &&
        collapsedY &&
        (a[0] - fx).abs() < 1e-6 &&
        (a[1] - fy).abs() < 1e-6;
  }

  void _applyAnchors(List<double> anchors) =>
      onChanged(stack.stackPinWithAnchors(anchors, viewport));

  void _applyRect(Rect rect) =>
      onChanged(stack.stackPinWithRect(rect, viewport));

  /// Переключение растяжения: включив — якорь уезжает к краю оси, выключив —
  /// пара схлопывается в долю, где сейчас стоит центр рамки.
  void _toggleStretch({required bool width}) {
    final a = stack.stackPinAnchors;
    final center = stack.stackPinCenterFractions(viewport);
    if (width) {
      final on = stack.stackPinStretchesWidth;
      _applyAnchors([on ? center[0] : 0.0, a[1], on ? center[0] : 1.0, a[3]]);
    } else {
      final on = stack.stackPinStretchesHeight;
      _applyAnchors([a[0], on ? center[1] : 0.0, a[2], on ? center[1] : 1.0]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rect = stack.stackPinRect(viewport);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PositionGrid(
              boxSize: Size(rect.width, rect.height),
              viewport: viewport,
              active: _isAt,
              onTap: (fx, fy) => _applyAnchors([fx, fy, fx, fy]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StretchChip(
                    label: tr('по ширине'),
                    selected: stack.stackPinStretchesWidth,
                    onToggle: () => _toggleStretch(width: true),
                  ),
                  const SizedBox(height: 6),
                  _StretchChip(
                    label: tr('по высоте'),
                    selected: stack.stackPinStretchesHeight,
                    onToggle: () => _toggleStretch(width: false),
                  ),
                  const SizedBox(height: 8),
                  _ScreenPreview(rect: rect, viewport: viewport),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _PxField(
                key: const ValueKey('pin_x'),
                label: 'X',
                value: rect.left,
                onCommit: (v) => _applyRect(
                  Rect.fromLTWH(v, rect.top, rect.width, rect.height),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PxField(
                key: const ValueKey('pin_y'),
                label: 'Y',
                value: rect.top,
                onCommit: (v) => _applyRect(
                  Rect.fromLTWH(rect.left, v, rect.width, rect.height),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PxField(
                key: const ValueKey('pin_w'),
                label: tr('Ш'),
                value: rect.width,
                onCommit: (v) => _applyRect(
                  Rect.fromLTWH(rect.left, rect.top, v, rect.height),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PxField(
                key: const ValueKey('pin_h'),
                label: tr('В'),
                value: rect.height,
                onCommit: (v) => _applyRect(
                  Rect.fromLTWH(rect.left, rect.top, rect.width, v),
                ),
              ),
            ),
          ],
        ),
        Text(
          trf(
            'px экрана {p0}×{p1}: на другом телефоне рамка поедет вместе с долями якорей, а поля останутся такими же. Ш и В схлопнутой оси = размер холста, он же правится в полях холста.',
            {'p0': viewport.width.round(), 'p1': viewport.height.round()},
          ),
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          key: const ValueKey('pin_modal_switch'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: stack.isModalStack,
          onChanged: (v) => onChanged(
            v
                ? stack.copyWith(stackModal: true)
                : stack.copyWith(clearStackModal: true),
          ),
          title: Text(
            tr('Модальное окно'),
            style: TextStyle(color: scheme.onSurface, fontSize: 14),
          ),
          subtitle: Text(
            tr('Нода под стек затемняется, тапы до неё не доходят'),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
        if (stack.isModalStack) ...[
          Row(
            children: [
              Expanded(
                child: _PxField(
                  key: const ValueKey('pin_scrim'),
                  label: tr('Затемнение, %'),
                  value: stack.stackScrimOpacity * 100,
                  onCommit: (v) => onChanged(
                    stack.copyWith(stackScrim: (v / 100).clamp(0.0, 1.0)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SwitchListTile(
                  key: const ValueKey('pin_dismiss_switch'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: stack.stackDismissesOnTapOutside,
                  onChanged: (v) =>
                      onChanged(stack.copyWith(stackDismissOnTapOutside: v)),
                  title: Text(
                    tr('Тап вне закрывает'),
                    style: TextStyle(color: scheme.onSurface, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
          Text(
            tr(
              'Закрыть может и скрипт: блок «показать/скрыть» этого стека перехватывает окно, а явное «показать» возвращает его даже после тапа игрока.',
            ),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

/// Сетка 3×3: девять схлопнутых позиций рамки. Каждая ячейка показывает,
/// где встанет панель, — в тех же долях, что и на мини-карте экрана, поэтому
/// широкая панель и узкая полоса выглядят по-разному.
class _PositionGrid extends StatelessWidget {
  const _PositionGrid({
    required this.boxSize,
    required this.viewport,
    required this.active,
    required this.onTap,
  });

  /// Текущий схлопнутый размер рамки в px вьюпорта.
  final Size boxSize;
  final Size viewport;
  final bool Function(double fx, double fy) active;
  final void Function(double fx, double fy) onTap;

  static const double _cell = 30;
  static const double _pad = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inner = Size(_cell - 2 * _pad, _cell - 2 * _pad);
    return SizedBox(
      width: 108,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < 3; row++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var col = 0; col < 3; col++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final fx = col * 0.5, fy = row * 0.5;
                        final on = active(fx, fy);
                        final w = (inner.width * boxSize.width / viewport.width)
                            .clamp(3.0, inner.width);
                        final h =
                            (inner.height * boxSize.height / viewport.height)
                                .clamp(3.0, inner.height);
                        return GestureDetector(
                          key: ValueKey('pin_pos_${col}_$row'),
                          onTap: () => onTap(fx, fy),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            height: _cell,
                            margin: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: on
                                  ? scheme.primaryContainer
                                  : scheme.surfaceContainerHighest.withValues(
                                      alpha: 0.4,
                                    ),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: on
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(_pad),
                              child: Align(
                                alignment: Alignment(fx * 2 - 1, fy * 2 - 1),
                                child: Container(
                                  width: w,
                                  height: h,
                                  decoration: BoxDecoration(
                                    color: on
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _StretchChip extends StatelessWidget {
  const _StretchChip({
    required this.label,
    required this.selected,
    required this.onToggle,
  });

  final String label;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              size: 16,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              trf('Растянуть {label}', {'label': label}),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Мини-карта экрана: рамка стека там, где её увидит плеер.
class _ScreenPreview extends StatelessWidget {
  const _ScreenPreview({required this.rect, required this.viewport});

  final Rect rect;
  final Size viewport;

  static const double _width = 90;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = _width * viewport.height / viewport.width;
    final scale = _width / viewport.width;
    return SizedBox(
      width: _width,
      height: height + 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: _width,
            height: height,
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outline),
              borderRadius: BorderRadius.circular(6),
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned(
                  left: rect.left * scale,
                  top: rect.top * scale,
                  width: rect.width * scale,
                  height: rect.height * scale,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${rect.width.round()}×${rect.height.round()}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// Числовое поле px: пишет значение по потере фокуса и по Enter, а если
/// модель его поправила (пределы, масштаб) — показывает исправленное.
class _PxField extends StatefulWidget {
  const _PxField({
    super.key,
    required this.label,
    required this.value,
    required this.onCommit,
  });

  final String label;
  final double value;
  final ValueChanged<double> onCommit;

  @override
  State<_PxField> createState() => _PxFieldState();
}

class _PxFieldState extends State<_PxField> {
  late final TextEditingController _ctl = TextEditingController(
    text: _fmt(widget.value),
  );
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChange);

  /// Enter тоже сбрасывает фокус, поэтому без флага один ввод дал бы два
  /// одинаковых шага истории.
  bool _committedForThisFocus = false;

  static String _fmt(double v) => v.roundToDouble().toStringAsFixed(0);

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _committedForThisFocus = false;
      return;
    }
    if (!_committedForThisFocus) _commit();
  }

  void _commit() {
    if (_committedForThisFocus) return;
    _committedForThisFocus = true;
    final v = double.tryParse(_ctl.text.replaceAll(',', '.'));
    if (v == null) {
      setState(() => _ctl.text = _fmt(widget.value));
      return;
    }
    widget.onCommit(v);
  }

  @override
  void didUpdateWidget(covariant _PxField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && _ctl.text != _fmt(widget.value)) {
      _ctl.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
        ),
        TextField(
          controller: _ctl,
          focusNode: _focus,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          style: TextStyle(color: scheme.onSurface, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 8,
            ),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _commit(),
        ),
      ],
    );
  }
}
