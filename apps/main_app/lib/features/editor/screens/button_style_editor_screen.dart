import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:mnd_core/models/content_item.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/services/font_service.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_player/widgets/content_display_factory.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

/// Полный редактор параметров стиля кнопки (текст, цвета, градиент, форма,
/// тень, отступы) с **закреплённым** живым превью — оно не уезжает при
/// прокрутке параметров. Модульные ассеты (угол/горизонт/вертикаль/центр)
/// этим экраном не редактируются — они остаются в редакторе пресетов.
///
/// [initialStyle] может быть `null` — тогда редактор стартует с **настоящего
/// дефолта игры** (стеклянная кнопка, GlassButton без styleConfig): превью
/// показывает её до первого изменения, а первый твик создаёт конфиг из
/// glass-подобных значений. Возвращает через `Navigator.pop` отредактированный
/// [ButtonStyleConfig] или `null`, если изменений не было.
class ButtonStyleEditorScreen extends StatefulWidget {
  final String questId;
  final ButtonStyleConfig? initialStyle;
  final String? sampleText;

  /// Автосохранение: каждая правка сразу уходит родительской вкладке.
  final ValueChanged<ButtonStyleConfig>? onChanged;

  const ButtonStyleEditorScreen({
    super.key,
    required this.questId,
    this.initialStyle,
    this.sampleText,
    this.onChanged,
  });

  @override
  State<ButtonStyleEditorScreen> createState() =>
      _ButtonStyleEditorScreenState();
}

class _ButtonStyleEditorScreenState extends State<ButtonStyleEditorScreen> {
  /// null = стиль ещё не создан (превью показывает настоящий дефолт-стекло).
  ButtonStyleConfig? _draft;

  /// Стартовый конфиг «из дефолта»: повторяет glass-вид обычной кнопки
  /// (белая заливка с низкой прозрачностью, белая граница, мягкая тень),
  /// чтобы при первом же изменении параметра кнопка не «прыгала» с дефолта.
  ButtonStyleConfig _glassBase() {
    return const ButtonStyleConfig(
      presetId: 'custom',
      fillColorValue: 0xFFFFFFFF,
      fillOpacity: 0.10,
      borderColorValue: 0xFFFFFFFF,
      borderWidth: 1.0,
      borderRadius: 16,
      textColorValue: 0xFFFFFFFF,
      shadowColorValue: 0xFF000000,
      shadowOpacity: 0.2,
      shadowBlur: 8,
      shadowOffsetY: 4,
      paddingH: 16,
      paddingV: 12,
    );
  }

  /// Текущий конфиг: созданный стиль или glass-база (для чтения слайдеров).
  ButtonStyleConfig get _current => _draft ?? _glassBase();

  @override
  void initState() {
    super.initState();
    _draft = widget.initialStyle;
  }

  /// Применяет изменение: при первом твике создаёт конфиг из glass-базы.
  void _mutate(ButtonStyleConfig Function(ButtonStyleConfig) change) {
    setState(() {
      final base = _draft ?? _glassBase();
      _draft = change(base);
    });
    final draft = _draft;
    if (draft != null) widget.onChanged?.call(draft);
  }

  void _update(ButtonStyleConfig next) => _mutate((_) => next);

  String get _sampleText => widget.sampleText?.trim().isNotEmpty == true
      ? widget.sampleText!.trim()
      : tr('Пример текста');

  bool get _isCustom => _draft != null;

  Future<void> _pickColor({
    required String title,
    required int value,
    required ValueChanged<int> onChanged,
  }) async {
    var picked = Color(value);
    final result = await showAppDialog<Color>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: picked,
              onColorChanged: (c) => setDialogState(() => picked = c),
              colorPickerWidth: 300,
              pickerAreaHeightPercent: 0.7,
              enableAlpha: true,
              displayThumbColor: true,
              paletteType: PaletteType.hsvWithHue,
              labelTypes: const [],
              pickerAreaBorderRadius: const BorderRadius.all(
                Radius.circular(12),
              ),
              hexInputBar: true,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, picked),
              child: Text(tr('Применить')),
            ),
          ],
        ),
      ),
    );
    if (result != null) onChanged(result.toARGB32());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Text(tr('Настройки кнопки'), style: textTheme.titleLarge),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton.filledTonal(
              onPressed: () => Navigator.pop(context, _draft),
              icon: const Icon(Icons.check_rounded),
              tooltip: tr('Сохранить'),
            ),
          ),
        ],
      ),
      body: AdaptiveContent(
        maxWidth: 760,
        child: SafeArea(
          child: Column(
            children: [
              // ── Закреплённое превью: всегда видно при прокрутке параметров ──
              _buildPinnedPreview(scheme, textTheme),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  children: [
                    // ── Текст ──────────────────────────────────────────────
                    _buildSectionLabel(tr('Текст'), scheme, textTheme),
                    _buildCard(
                      scheme: scheme,
                      child: Column(
                        children: [
                          _SliderRow(
                            label: tr('Размер шрифта'),
                            value: _current.textSize ?? 16,
                            min: 10,
                            max: 32,
                            divisions: 22,
                            display: (_current.textSize ?? 16).toStringAsFixed(
                              0,
                            ),
                            onChanged: (v) =>
                                _update(_current.copyWith(textSize: v)),
                          ),
                          _SliderRow(
                            label: tr('Насыщенность'),
                            value: (_current.textWeight ?? 400).toDouble(),
                            min: 100,
                            max: 900,
                            divisions: 8,
                            display: _weightLabel(_current.textWeight ?? 400),
                            onChanged: (v) => _update(
                              _current.copyWith(textWeight: v.round()),
                            ),
                          ),
                          _SliderRow(
                            label: tr('Разрядка букв'),
                            value: _current.letterSpacing ?? 0,
                            min: -1,
                            max: 4,
                            divisions: 50,
                            display: (_current.letterSpacing ?? 0)
                                .toStringAsFixed(1),
                            onChanged: (v) =>
                                _update(_current.copyWith(letterSpacing: v)),
                          ),
                          const SizedBox(height: 4),
                          // Шрифт — пикер из ресурсов квеста (res/fonts), а не
                          // ручной ввод: выбор сразу грузит шрифт для превью.
                          InkWell(
                            onTap: _pickFont,
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.text_fields_rounded,
                                    color: scheme.onSurfaceVariant,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _hasFont
                                          ? _fontLabel(_current.fontFamily!)
                                          : tr('Шрифт (пусто = как в квесте)'),
                                      style: TextStyle(
                                        color: _hasFont
                                            ? scheme.onSurface
                                            : scheme.onSurfaceVariant,
                                        fontWeight: _hasFont
                                            ? FontWeight.w500
                                            : FontWeight.normal,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (_hasFont)
                                    IconButton(
                                      onPressed: () => _update(
                                        _current.copyWith(fontFamily: null),
                                      ),
                                      icon: const Icon(Icons.close),
                                      tooltip: tr('Сбросить шрифт'),
                                    ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Цвета ──────────────────────────────────────────────
                    _buildSectionLabel(tr('Цвета'), scheme, textTheme),
                    _buildCard(
                      scheme: scheme,
                      child: Column(
                        children: [
                          _ColorRow(
                            label: tr('Заливка'),
                            color: _current.fillColor,
                            onTap: () => _pickColor(
                              title: tr('Цвет заливки'),
                              value: _current.fillColorValue,
                              onChanged: (v) =>
                                  _update(_current.copyWith(fillColorValue: v)),
                            ),
                          ),
                          _ColorRow(
                            label: tr('Граница'),
                            color: _current.borderColor,
                            onTap: () => _pickColor(
                              title: tr('Цвет границы'),
                              value: _current.borderColorValue,
                              onChanged: (v) => _update(
                                _current.copyWith(borderColorValue: v),
                              ),
                            ),
                          ),
                          _ColorRow(
                            label: tr('Текст'),
                            color: _current.textColor,
                            onTap: () => _pickColor(
                              title: tr('Цвет текста'),
                              value: _current.textColorValue,
                              onChanged: (v) =>
                                  _update(_current.copyWith(textColorValue: v)),
                            ),
                          ),
                          const Divider(height: 24),
                          _SliderRow(
                            label: tr('Прозрачность заливки'),
                            value: _current.effectiveFillOpacity,
                            min: 0.1,
                            max: 1,
                            divisions: 18,
                            display: _current.effectiveFillOpacity
                                .toStringAsFixed(2),
                            onChanged: (v) =>
                                _update(_current.copyWith(fillOpacity: v)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Градиент ───────────────────────────────────────────
                    _buildSectionLabel(tr('Градиент'), scheme, textTheme),
                    _buildCard(
                      scheme: scheme,
                      child: Column(
                        children: [
                          SwitchListTile(
                            value: _current.useGradient,
                            onChanged: (v) =>
                                _update(_current.copyWith(useGradient: v)),
                            contentPadding: EdgeInsets.zero,
                            title: Text(tr('Заливка градиентом')),
                            subtitle: Text(
                              tr('Вместо сплошного цвета — переход между двумя цветами.'),
                            ),
                          ),
                          if (_current.useGradient) ...[
                            const SizedBox(height: 4),
                            _ColorRow(
                              label: tr('Начальный цвет'),
                              color: _current.gradientStartColor,
                              onTap: () => _pickColor(
                                title: tr('Начальный цвет градиента'),
                                value:
                                    _current.gradientStartColorValue ??
                                    _current.fillColorValue,
                                onChanged: (v) => _update(
                                  _current.copyWith(gradientStartColorValue: v),
                                ),
                              ),
                            ),
                            _ColorRow(
                              label: tr('Конечный цвет'),
                              color: _current.gradientEndColor,
                              onTap: () => _pickColor(
                                title: tr('Конечный цвет градиента'),
                                value:
                                    _current.gradientEndColorValue ??
                                    _current.fillColorValue,
                                onChanged: (v) => _update(
                                  _current.copyWith(gradientEndColorValue: v),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SegmentedButton<String>(
                              segments: [
                                ButtonSegment(
                                  value: 'topBottom',
                                  label: Text(tr('Сверху вниз')),
                                ),
                                ButtonSegment(
                                  value: 'leftRight',
                                  label: Text(tr('Слева направо')),
                                ),
                              ],
                              selected: {
                                _current.gradientIsHorizontal
                                    ? 'leftRight'
                                    : 'topBottom',
                              },
                              onSelectionChanged: (s) => _update(
                                _current.copyWith(gradientDirection: s.first),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Форма ──────────────────────────────────────────────
                    _buildSectionLabel(tr('Форма'), scheme, textTheme),
                    _buildCard(
                      scheme: scheme,
                      child: Column(
                        children: [
                          _SliderRow(
                            label: tr('Скругление углов'),
                            value: _current.borderRadius ?? 16,
                            min: 0,
                            max: 40,
                            divisions: 40,
                            display: (_current.borderRadius ?? 16)
                                .toStringAsFixed(0),
                            onChanged: (v) =>
                                _update(_current.copyWith(borderRadius: v)),
                          ),
                          _SliderRow(
                            label: tr('Толщина границы'),
                            value: _current.borderWidth ?? 1,
                            min: 0,
                            max: 8,
                            divisions: 32,
                            display: (_current.borderWidth ?? 1)
                                .toStringAsFixed(1),
                            onChanged: (v) =>
                                _update(_current.copyWith(borderWidth: v)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Тень ───────────────────────────────────────────────
                    _buildSectionLabel(tr('Тень'), scheme, textTheme),
                    _buildCard(
                      scheme: scheme,
                      child: Column(
                        children: [
                          _ColorRow(
                            label: tr('Цвет тени'),
                            color: _current.shadowColor,
                            onTap: () => _pickColor(
                              title: tr('Цвет тени'),
                              value:
                                  _current.shadowColorValue ??
                                  _current.borderColorValue,
                              onChanged: (v) => _update(
                                _current.copyWith(shadowColorValue: v),
                              ),
                            ),
                          ),
                          _SliderRow(
                            label: tr('Прозрачность тени'),
                            value: _current.effectiveShadowOpacity,
                            min: 0,
                            max: 0.8,
                            divisions: 16,
                            display: _current.effectiveShadowOpacity
                                .toStringAsFixed(2),
                            onChanged: (v) =>
                                _update(_current.copyWith(shadowOpacity: v)),
                          ),
                          _SliderRow(
                            label: tr('Размытие тени'),
                            value: _current.effectiveShadowBlur,
                            min: 0,
                            max: 40,
                            divisions: 40,
                            display: _current.effectiveShadowBlur
                                .toStringAsFixed(0),
                            onChanged: (v) =>
                                _update(_current.copyWith(shadowBlur: v)),
                          ),
                          _SliderRow(
                            label: tr('Смещение по X'),
                            value: _current.effectiveShadowOffsetX,
                            min: -20,
                            max: 20,
                            divisions: 40,
                            display: _current.effectiveShadowOffsetX
                                .toStringAsFixed(0),
                            onChanged: (v) =>
                                _update(_current.copyWith(shadowOffsetX: v)),
                          ),
                          _SliderRow(
                            label: tr('Смещение по Y'),
                            value: _current.effectiveShadowOffsetY,
                            min: -20,
                            max: 20,
                            divisions: 40,
                            display: _current.effectiveShadowOffsetY
                                .toStringAsFixed(0),
                            onChanged: (v) =>
                                _update(_current.copyWith(shadowOffsetY: v)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Отступы ────────────────────────────────────────────
                    _buildSectionLabel(
                      tr('Отступы внутри кнопки'),
                      scheme,
                      textTheme,
                    ),
                    _buildCard(
                      scheme: scheme,
                      child: Column(
                        children: [
                          _SliderRow(
                            label: tr('По горизонтали'),
                            value: _current.paddingH ?? 16,
                            min: 0,
                            max: 80,
                            divisions: 40,
                            display: (_current.paddingH ?? 16).toStringAsFixed(
                              0,
                            ),
                            onChanged: (v) =>
                                _update(_current.copyWith(paddingH: v)),
                          ),
                          _SliderRow(
                            label: tr('По вертикали'),
                            value: _current.paddingV ?? 12,
                            min: 0,
                            max: 40,
                            divisions: 40,
                            display: (_current.paddingV ?? 12).toStringAsFixed(
                              0,
                            ),
                            onChanged: (v) =>
                                _update(_current.copyWith(paddingV: v)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _draft = widget.initialStyle;
                        }),
                        icon: const Icon(Icons.restart_alt_rounded),
                        label: Text(
                          _isCustom
                              ? tr('Сбросить к исходному')
                              : tr('Вернуть кнопку к дефолту'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _saveAsPreset,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: Text(tr('Сохранить как пресет')),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.pop(context, _draft),
                        icon: const Icon(Icons.check_rounded),
                        label: Text(tr('Применить')),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
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
  }

  Widget _buildPinnedPreview(ColorScheme scheme, TextTheme textTheme) {
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 3,
      shadowColor: Colors.black.withOpacity(0.2),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Превью (как в игре)'),
                    style: textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: GlassButton(
                        onPressed: null,
                        text: _sampleText,
                        wrapText: true,
                        // null = настоящий дефолт игры (стеклянная кнопка) —
                        // пока пользователь ничего не менял.
                        styleConfig: _draft,
                        fontFamily: null,
                        questId: widget.questId,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              _isCustom ? Icons.tune_rounded : Icons.layers_rounded,
              color: scheme.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  bool get _hasFont {
    final f = _current.fontFamily;
    return f != null && f.trim().isNotEmpty;
  }

  String _fontLabel(String path) {
    final base = path.contains('/')
        ? path.substring(path.lastIndexOf('/') + 1)
        : path;
    return base;
  }

  Future<void> _pickFont() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['font'],
        ),
      ),
    );
    if (result == null || !mounted) return;
    // Загружаем шрифт сейчас, чтобы превью показало его сразу (в игре шрифты
    // грузит GameScreenNotifier перед отрисовкой ноды).
    await FontService.loadQuestFont(widget.questId, result.path);
    if (!mounted) return;
    _update(_current.copyWith(fontFamily: result.path));
  }

  /// Сохраняет текущий стиль как пресет в config.json `buttonStylePresets`,
  /// чтобы его можно было применить к другим кнопкам.
  Future<void> _saveAsPreset() async {
    if (!_isCustom) {
      _showSnack(
        tr('Сначала измените хотя бы один параметр — дефолт сохранять нечего.'),
      );
      return;
    }
    final name = await _askPresetName();
    if (name == null || name.isEmpty || !mounted) return;

    final preset = _current.copyWith(
      presetId:
          'customPreset:${name.toLowerCase().replaceAll(RegExp(r'\s+'), '_')}',
      presetName: name,
    );
    try {
      final qs = await QuestStore.defaultInstance();
      final configPath = QuestPaths.config(widget.questId);
      final config = await qs.readJson(configPath) ?? <String, dynamic>{};
      final list = (config['buttonStylePresets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ButtonStyleConfig.fromJson)
          .toList();
      final index = list.indexWhere((p) => p.presetName == name);
      if (index >= 0) {
        list[index] = preset;
      } else {
        list.add(preset);
      }
      config['buttonStylePresets'] = list.map((p) => p.toJson()).toList();
      await qs.writeJson(configPath, config);
      if (mounted) _showSnack(trf('Стиль сохранён как пресет «{name}»', {'name': name}));
    } catch (e) {
      if (mounted) _showSnack(trf('Ошибка сохранения пресета: {p0}', {'p0': friendlyError(e)}));
    }
  }

  Future<String?> _askPresetName() {
    final controller = TextEditingController();
    return showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Название пресета')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('Например: «Красная опасность»'),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String _weightLabel(int weight) {
    return switch (weight) {
      100 => tr('Тонкий'),
      200 => tr('Сверхлёгкий'),
      300 => tr('Лёгкий'),
      400 => tr('Обычный'),
      500 => tr('Средний'),
      600 => tr('Полужирный'),
      700 => tr('Жирный'),
      800 => tr('Сверхжирный'),
      900 => tr('Максимальный'),
      _ => '$weight',
    };
  }

  Widget _buildSectionLabel(
    String title,
    ColorScheme scheme,
    TextTheme textTheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: textTheme.titleSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildCard({required ColorScheme scheme, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ),
            Text(
              display,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _ColorRow extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ColorRow({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
