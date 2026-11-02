import 'dart:async';
import 'package:canvas_app/core/services/refactoring_service.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/variable_selection_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:mnd_player/services/font_service.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:mnd_player/widgets/shared/markdown_color.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Результат редактора markdown: текст + шрифт айтема (путь ресурса res/fonts,
/// null = унаследовать от квеста/контейнера).
class MarkdownEditorResult {
  final String text;
  final String? fontFamily;
  final double? textSize;
  final String textReveal;
  final double revealSpeed;
  final Color? textOutlineColor;
  final double? textOutlineWidth;

  const MarkdownEditorResult({
    required this.text,
    this.fontFamily,
    this.textSize,
    this.textReveal = kTextRevealDefault,
    this.revealSpeed = kRevealSpeedDefault,
    this.textOutlineColor,
    this.textOutlineWidth,
  });
}

class MarkdownEditorScreen extends ConsumerStatefulWidget {
  final String initialText;
  final String questId;
  final String? initialFontFamily;
  final double? initialTextSize;
  final String initialTextReveal;
  final double initialRevealSpeed;
  final Color? initialTextOutlineColor;
  final double? initialTextOutlineWidth;

  /// Модальный редактор хранит только строку текста, ему ни размер, ни
  /// анимация появления применяться некуда — скрываем эти контролы.
  final bool supportsTextSize;

  const MarkdownEditorScreen({
    super.key,
    required this.initialText,
    required this.questId,
    this.initialFontFamily,
    this.initialTextSize,
    this.initialTextReveal = kTextRevealDefault,
    this.initialRevealSpeed = kRevealSpeedDefault,
    this.initialTextOutlineColor,
    this.initialTextOutlineWidth,
    this.supportsTextSize = true,
  });

  @override
  ConsumerState<MarkdownEditorScreen> createState() =>
      _MarkdownEditorScreenState();
}

class _MarkdownEditorScreenState extends ConsumerState<MarkdownEditorScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _controller;
  late final TabController _tabController;
  final FocusNode _focusNode = FocusNode();

  late final ValueNotifier<String> _textNotifier;

  /// Раздражитель для панели оформления: её контролы живут в отдельной
  /// поверхности (шит/диалог), а её перерисовку должен уметь запрашивать
  /// экран, который владеет значениями.
  final ValueNotifier<int> _styleVersion = ValueNotifier(0);

  // ============================================================
  //  ИСТОРИЯ UNDO/REDO
  // ============================================================
  // Свой стек снимков (текст + выделение). Нужен потому, что встроенный
  // UndoHistoryController у TextField не подхватывает программные изменения
  // (вставка переменной/цвета/форматирования, rename), а на телефоне
  // нет Ctrl+Z.
  final List<TextEditingValue> _undoStack = [];
  final List<TextEditingValue> _redoStack = [];
  // Флаг, чтобы изменения, выполненные самим undo/redo, не попадали обратно
  // в историю.
  bool _isApplyingHistory = false;
  // Момент последнего снимка — чтобы не плодить снимок на каждый символ.
  DateTime _lastSnapshotAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Уведомитель состояния кнопок undo/redo (доступность).
  final ValueNotifier<int> _historyVersion = ValueNotifier(0);
  static const Duration _snapshotInterval = Duration(milliseconds: 600);
  static const int _maxHistory = 200;

  Timer? _debounce;
  StreamSubscription<RefactorRenameEvent>? _renameSub;

  /// Шрифт всего айтема (путь ресурса res/fonts/...). null = как в квесте.
  String? _fontFamily;

  /// Размер шрифта айтема в px. null — движковый дефолт 16.
  double? _textSize;

  /// Режим анимации появления (`none` | `typewriter` | `fade`) и скорость в
  /// видимых символах в секунду. Дефолт в JSON не пишется, поэтому «Без
  /// анимации» не плодит поле у каждого текста квеста.
  String _textReveal = kTextRevealDefault;
  double _revealSpeed = kRevealSpeedDefault;

  /// Обводка: цвет контура и его толщина в px. Без цвета контура нет, поэтому
  /// «убрать» снимает оба поля — ровно как в настройках слоя стека.
  Color? _textOutlineColor;
  double? _textOutlineWidth;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _textNotifier = ValueNotifier(widget.initialText);
    _fontFamily = widget.initialFontFamily;
    _textSize = widget.initialTextSize;
    _textReveal = widget.initialTextReveal;
    _revealSpeed = widget.initialRevealSpeed;
    _textOutlineColor = widget.initialTextOutlineColor;
    _textOutlineWidth = widget.initialTextOutlineWidth;
    _tabController = TabController(length: 2, vsync: this);

    // Начальный снимок — чтобы можно было «отменить» первое же действие
    // до исходного состояния.
    _undoStack.add(_controller.value);

    _controller.addListener(() {
      _textNotifier.value = _controller.text;
      _captureSnapshotIfNeeded();
      if (_debounce?.isActive ?? false) _debounce!.cancel();
      _debounce = Timer(const Duration(seconds: 2), _saveChanges);
    });

    _renameSub = RefactoringService.renameEvents.listen((event) {
      if (!mounted) return;
      if (event.questId != widget.questId) return;

      final current = _controller.text;
      final replaced = _replaceRenameText(
        current,
        event.oldName,
        event.newName,
      );
      if (replaced == current) {
        return;
      }

      final selection = _controller.selection;
      _controller.value = TextEditingValue(
        text: replaced,
        selection: selection,
      );
    });
  }

  @override
  void dispose() {
    _renameSub?.cancel();
    _debounce?.cancel();
    _controller.dispose();
    _tabController.dispose();
    _focusNode.dispose();
    _textNotifier.dispose();
    _historyVersion.dispose();
    _styleVersion.dispose();
    super.dispose();
  }

  void _saveChanges() {
    // Логика автосохранения (если нужно)
  }

  // ============================================================
  //  UNDO / REDO
  // ============================================================

  /// Делает снимок текущего значения контроллера в undo-стек, если с прошлого
  /// снимка прошло достаточно времени (для печатания подряд) ИЛИ если текст
  /// изменился существенно (для программных вставок — AI, переменная, цвет).
  void _captureSnapshotIfNeeded() {
    if (_isApplyingHistory) return;
    final current = _controller.value;
    if (_undoStack.isNotEmpty && _undoStack.last.text == current.text) {
      // Тот же текст (изменилось только выделение) — не плодим снимки.
      return;
    }
    final now = DateTime.now();
    final since = now.difference(_lastSnapshotAt);
    final last = _undoStack.isNotEmpty ? _undoStack.last : null;
    final bigChange =
        last == null || (current.text.length - last.text.length).abs() >= 8;
    if (!bigChange && since < _snapshotInterval) {
      // Печатается подряд — заменяем верхний снимок, чтобы один Ctrl+Z откатил
      // целое «слово», а не один символ.
      if (_undoStack.isNotEmpty) {
        _undoStack[_undoStack.length - 1] = current;
      } else {
        _undoStack.add(current);
      }
    } else {
      _undoStack.add(current);
      if (_undoStack.length > _maxHistory) {
        _undoStack.removeAt(0);
      }
    }
    _lastSnapshotAt = now;
    if (_redoStack.isNotEmpty) {
      _redoStack.clear();
    }
    _historyVersion.value++;
  }

  bool get _canUndo => _undoStack.length > 1;
  bool get _canRedo => _redoStack.isNotEmpty;

  void _undo() {
    if (!_canUndo) return;
    _isApplyingHistory = true;
    try {
      // Верхний снимок — это текущее состояние; откатываем на предыдущий.
      final current = _undoStack.removeLast();
      _redoStack.add(current);
      final previous = _undoStack.last;
      _controller.value = previous;
      _textNotifier.value = previous.text;
      _lastSnapshotAt = DateTime.now();
      _historyVersion.value++;
    } finally {
      _isApplyingHistory = false;
    }
  }

  void _redo() {
    if (!_canRedo) return;
    _isApplyingHistory = true;
    try {
      final next = _redoStack.removeLast();
      _undoStack.add(next);
      _controller.value = next;
      _textNotifier.value = next.text;
      _lastSnapshotAt = DateTime.now();
      _historyVersion.value++;
    } finally {
      _isApplyingHistory = false;
    }
  }

  String _replaceRenameText(String input, String oldName, String newName) {
    String result = input.replaceAll('{$oldName}', '{$newName}');
    final escapedOld = RegExp.escape(oldName);
    final regExp = RegExp(
      r'(?<![\wа-яА-ЯёЁ])' + escapedOld + r'(?![\wа-яА-ЯёЁ])',
    );
    result = result.replaceAll(regExp, newName);
    return result;
  }

  // ============================================================
  //  MARKDOWN INSERTION
  // ============================================================

  void _insertMarkdown(String prefix, {String? suffix, int? offset}) {
    final text = _controller.text;
    final selection = _controller.selection;
    final selectedText = selection.textInside(text);

    if (selection.isCollapsed) {
      final finalOffset = offset ?? (prefix.length);
      final newText =
          text.substring(0, selection.start) +
          prefix +
          (suffix ?? '') +
          text.substring(selection.end);
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + finalOffset,
        ),
      );
    } else {
      final newText =
          text.substring(0, selection.start) +
          prefix +
          selectedText +
          (suffix ?? prefix) +
          text.substring(selection.end);
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + prefix.length + selectedText.length,
        ),
      );
    }
    _focusNode.requestFocus();
  }

  Future<void> _insertVariable() async {
    _focusNode.unfocus();

    final variableName = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            VariableSelectionScreen.forTextInsert(questId: widget.questId),
      ),
    );

    if (variableName != null && variableName.isNotEmpty) {
      _insertMarkdown('{$variableName}');
    } else {
      _focusNode.requestFocus();
    }
  }

  Future<void> _insertTableData() async {
    _focusNode.unfocus();

    final cellRef = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => VariableSelectionScreen.forTextInsert(
          questId: widget.questId,
          initialTabIndex: 2,
        ),
      ),
    );

    if (cellRef != null && cellRef.isNotEmpty) {
      _insertMarkdown(cellRef);
    } else {
      _focusNode.requestFocus();
    }
  }

  Future<void> _showColorPicker() async {
    _focusNode.unfocus();
    final scheme = Theme.of(context).colorScheme;

    Color currentColor = scheme.primary;

    await showAppDialog<Color>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(tr('Выбор цвета текста')),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: currentColor,
              onColorChanged: (color) => currentColor = color,
              colorPickerWidth: 300,
              pickerAreaHeightPercent: 0.7,
              enableAlpha: false,
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
              onPressed: () => Navigator.pop(ctx, currentColor),
              child: Text(tr('Применить')),
            ),
          ],
        );
      },
    ).then((result) {
      if (result != null) {
        final rgb = result.value & 0x00FFFFFF;
        final hex = '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
        _insertMarkdown('[color=$hex]', suffix: '[/color]');
      } else {
        _focusNode.requestFocus();
      }
    });
  }

  // ============================================================
  //  ШРИФТЫ
  // ============================================================

  String _fontLabel(String path) {
    final base = path.contains('/')
        ? path.substring(path.lastIndexOf('/') + 1)
        : path;
    return base;
  }

  /// Пикер шрифта всего айтема (блока текста). Путь — в item.fontFamily.
  Future<void> _pickItemFont() async {
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
    // Грузим сейчас, чтобы превью/редактор показали шрифт сразу (в игре
    // шрифты грузит GameScreenNotifier перед отрисовкой ноды).
    await FontService.loadQuestFont(widget.questId, result.path);
    if (!mounted) return;
    _updateStyle(() => _fontFamily = result.path);
  }

  /// Инлайн-тег [font=res/fonts/...] вокруг выделенного текста — шрифт
  /// отдельных слов/фраз внутри айтема.
  Future<void> _insertInlineFontTag() async {
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
    await FontService.loadQuestFont(widget.questId, result.path);
    if (!mounted) return;
    _insertMarkdown('[font=${result.path}]', suffix: '[/font]');
    _focusNode.requestFocus();
  }

  /// Инлайн-обводка выделенного куска: `[outline=#RRGGBB:N]…[/outline]`.
  /// В отличие от строки «Обводка» ниже, не трогает item-level поля и
  /// позволяет красить отдельные слова/фразы.
  Future<void> _insertInlineOutline() async {
    _focusNode.unfocus();
    final scheme = Theme.of(context).colorScheme;
    var picked = _textOutlineColor ?? scheme.onSurface;
    final color = await showAppDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Цвет обводки выделенного')),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: picked,
            onColorChanged: (c) => picked = c,
            colorPickerWidth: 300,
            pickerAreaHeightPercent: 0.7,
            enableAlpha: false,
            displayThumbColor: true,
            paletteType: PaletteType.hsvWithHue,
            labelTypes: const [],
            pickerAreaBorderRadius: const BorderRadius.all(Radius.circular(12)),
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
    );
    if (color == null || !mounted) return;

    var width = (_textOutlineWidth ?? kTextOutlineWidthDefault).clamp(
      1.0,
      kTextOutlineWidthMax,
    );
    final confirmed = await showAppDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('Толщина обводки')),
          content: Row(
            children: [
              Expanded(
                child: Slider(
                  value: width,
                  min: 1,
                  max: kTextOutlineWidthMax,
                  divisions: kTextOutlineWidthMax.round() - 1,
                  label: '${width.round()} px',
                  onChanged: (v) => setLocal(() => width = v),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '${width.round()} px',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, width),
              child: Text(tr('Вставить')),
            ),
          ],
        ),
      ),
    );
    if (confirmed == null || !mounted) return;
    final rgb = color.value & 0x00FFFFFF;
    final hex = '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
    _insertMarkdown(
      '[outline=$hex:${confirmed.round()}]',
      suffix: '[/outline]',
    );
    _focusNode.requestFocus();
  }

  // ============================================================
  //  BUILD
  // ============================================================

  /// Правит настройку оформления и перерисовывает всё, что её показывает:
  /// сам экран (превью, значок в шапке) и открытую панель оформления.
  void _updateStyle(VoidCallback mutate) {
    setState(() {
      mutate();
      _styleVersion.value++;
    });
  }

  /// Хоть одна настройка оформления отличается от движковой — по ней шапка
  /// подсвечивает кнопку, чтобы автор видел: оформление задано, оно спрятано
  /// здесь, а не пропало.
  bool get _appearanceChanged =>
      (_fontFamily != null && _fontFamily!.trim().isNotEmpty) ||
      _textSize != null ||
      _textReveal != kTextRevealDefault ||
      _textOutlineColor != null;

  /// Панель оформления — отдельно от поля ввода. Строки шрифта, размера и
  /// появления раньше стояли прямо над текстом и съедали треть экрана, из-за
  /// чего само поле было маленьким. Значения при этом живут в этом state:
  /// панель только читает и пишет их, поэтому `_result()` остаётся одним
  /// источником правды для обоих выходов из редактора.
  Future<void> _openAppearancePanel() async {
    await showAdaptiveSheet<void>(
      context: context,
      title: tr('Оформление текста'),
      maxWidth: 460,
      // Слайдеры внутри: жест «стянуть шит вниз» конфликтует с перетаскиванием
      // ползунка, поэтому закрываем по барьеру, ручке и кнопке.
      enableDrag: false,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      scrollable: true,
      builder: (sheetContext) => ValueListenableBuilder<int>(
        valueListenable: _styleVersion,
        builder: (context, _, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(4, 0, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildItemFontRow(context),
              if (widget.supportsTextSize) _buildTextSizeRow(context),
              if (widget.supportsTextSize) _buildRevealRow(context),
              if (widget.supportsTextSize) _buildOutlineRow(context),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: Text(tr('Готово')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Чем редактор отвечает наружу. Один метод на два выхода (аппбар и
  /// PopScope), чтобы новое поле не пришлось дописывать в оба.
  MarkdownEditorResult _result() => MarkdownEditorResult(
    text: _controller.text,
    fontFamily: _fontFamily,
    textSize: _textSize,
    textReveal: _textReveal,
    revealSpeed: _revealSpeed,
    textOutlineColor: _textOutlineColor,
    textOutlineWidth: _textOutlineWidth,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        Navigator.pop(context, _result());
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: _buildAppBar(context),
        body: AdaptiveContent(
          maxWidth: 1000,
          // Всё свободное место — полю ввода: настройки оформления уехали
          // в отдельную панель (`_openAppearancePanel`).
          child: Column(
            children: [
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  // Отключаем свайп между «Редактор» и «Предпросмотр» — иначе
                  // горизонтальный жест мешает выделению текста в редакторе.
                  // Переключение остаётся доступным через TabBar в шапке.
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _buildEditorTab(context),
                    _buildPreviewTab(context),
                  ],
                ),
              ),
              _buildBottomToolbar(context),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        tooltip: tr('Закрыть и сохранить'),
        onPressed: () => Navigator.pop(context, _result()),
      ),
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.edit_note_rounded,
              color: scheme.onPrimaryContainer,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('Редактор'),
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: Badge(
            isLabelVisible: _appearanceChanged,
            smallSize: 7,
            backgroundColor: scheme.primary,
            child: Icon(
              Icons.tune_rounded,
              color: _appearanceChanged
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
          ),
          tooltip: tr('Оформление текста'),
          onPressed: _openAppearancePanel,
        ),
        ValueListenableBuilder<String>(
          valueListenable: _textNotifier,
          builder: (context, text, _) {
            return Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${text.length}',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          },
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TabBar(
            controller: _tabController,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            indicatorPadding: EdgeInsets.zero,
            labelColor: scheme.onSecondaryContainer,
            unselectedLabelColor: scheme.onSurfaceVariant,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
            unselectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
            tabs: [
              _IconTextTab(icon: Icons.edit_rounded, label: tr('Редактор')),
              _IconTextTab(
                icon: Icons.visibility_rounded,
                label: tr('Предпросмотр'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  //  EDITOR TAB
  // ============================================================

  Widget _buildEditorTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          style: TextStyle(color: scheme.onSurface, fontSize: 15, height: 1.55),
          maxLines: null,
          expands: true,
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr('Начните писать историю…'),
            hintStyle: TextStyle(color: scheme.onSurfaceVariant),
            border: InputBorder.none,
            isCollapsed: true,
          ),
          keyboardType: TextInputType.multiline,
          cursorColor: scheme.primary,
        ),
      ),
    );
  }

  // ============================================================
  //  PREVIEW TAB
  // ============================================================

  /// Обводка в превью. Плеер кладёт под буквы штриховой слой того же текста,
  /// здесь тот же эффект дают восемь копий глифа со смещением на полтолщины и
  /// без размытия: буквы остаются поверх, поэтому `[color=#…]` и жирный не
  /// меняют цвета. Контур приблизительный — зато не стоит перепарсить весь
  /// markdown второй раз на каждое нажатие клавиши.
  List<BoxShadow>? get _previewOutlineShadows {
    final color = _textOutlineColor;
    if (color == null) return null;
    final half =
        (_textOutlineWidth ?? kTextOutlineWidthDefault).clamp(
          1.0,
          kTextOutlineWidthMax,
        ) /
        2.0;
    return [
      for (final dx in [-half, 0.0, half])
        for (final dy in [-half, 0.0, half])
          if (dx != 0.0 || dy != 0.0)
            BoxShadow(color: color, offset: Offset(dx, dy), blurRadius: 0),
    ];
  }

  Widget _buildPreviewTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String>(
      valueListenable: _textNotifier,
      builder: (context, text, child) {
        // Превью живёт по тем же правилам, что и плеер: базовый размер из
        // `item.textSize`, заголовки умножаются на тот же коэффициент.
        final base = (_textSize ?? 16.0).clamp(6.0, 200.0);
        final headingScale = base / 16.0;
        final outlineShadows = _previewOutlineShadows;
        final config = MarkdownConfig(
          configs: [
            PConfig(
              textStyle: TextStyle(
                color: scheme.onSurface,
                fontSize: base,
                height: 1.45,
                shadows: outlineShadows,
              ),
            ),
            ListConfig(
              marginLeft: 20.0,
              marginBottom: 0.0,
              marker: safeListMarker(scheme.onSurface),
            ),
            CheckBoxConfig(builder: safeCheckboxBuilder(scheme.onSurface)),
            H1Config(
              style: TextStyle(
                fontSize: 28 * headingScale,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
                height: 2,
                shadows: outlineShadows,
              ),
            ),
            H2Config(
              style: TextStyle(
                fontSize: 24 * headingScale,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
                height: 2,
                shadows: outlineShadows,
              ),
            ),
            H3Config(
              style: TextStyle(
                fontSize: 20 * headingScale,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
                height: 2,
                shadows: outlineShadows,
              ),
            ),
            LinkConfig(
              style: TextStyle(
                color: scheme.primary,
                decoration: TextDecoration.underline,
                shadows: outlineShadows,
              ),
            ),
            BlockquoteConfig(
              textColor: scheme.onSurfaceVariant,
              sideColor: scheme.primary,
            ),
            CodeConfig(
              style: TextStyle(
                backgroundColor: scheme.surfaceContainerHighest,
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
                shadows: outlineShadows,
              ),
            ),
          ],
        );

        final widgets =
            createColorMarkdownGenerator(
              linesMargin: const EdgeInsets.symmetric(vertical: 2),
              questId: widget.questId,
            ).buildWidgets(
              text.isEmpty
                  ? tr('Нет текста для предпросмотра')
                  : preserveMarkdownHardLineBreaks(text),
              config: config,
            );

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widgets,
              ),
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  //  BOTTOM TOOLBAR (Material 3)
  // ============================================================

  /// Строка выбора шрифта всего блока (айтема). Путь сохраняется в
  /// `item.fontFamily`; в игре применяется, если у текста нет инлайн-тегов.
  Widget _buildItemFontRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasFont = _fontFamily != null && _fontFamily!.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(
            Icons.font_download_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: _pickItemFont,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  hasFont
                      ? trf('Шрифт блока: {p0}', {
                          'p0': _fontLabel(_fontFamily!),
                        })
                      : tr('Шрифт блока: как в квесте'),
                  style: TextStyle(
                    color: hasFont ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: hasFont ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (hasFont)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: tr('Сбросить шрифт блока'),
              visualDensity: VisualDensity.compact,
              onPressed: () => _updateStyle(() => _fontFamily = null),
            ),
        ],
      ),
    );
  }

  /// Строка размера шрифта айтема. Пишется в `item.textSize`; в игре и в
  /// превью заголовки markdown масштабируются вместе с базовым размером.
  Widget _buildTextSizeRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasSize = _textSize != null;
    final size = _textSize ?? 16.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(
            Icons.format_size_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            tr('Размер'),
            style: TextStyle(
              color: hasSize ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: hasSize ? FontWeight.w600 : FontWeight.w400,
              fontSize: 13,
            ),
          ),
          Expanded(
            child: Slider(
              value: size.clamp(8.0, 64.0),
              min: 8,
              max: 64,
              divisions: 56,
              label: '${size.round()} px',
              onChanged: (v) => _updateStyle(() => _textSize = v),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              hasSize ? '${size.round()} px' : '16 px',
              textAlign: TextAlign.end,
              style: TextStyle(
                color: hasSize ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: hasSize ? FontWeight.w600 : FontWeight.w400,
                fontSize: 13,
              ),
            ),
          ),
          if (hasSize)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: tr('Сбросить размер'),
              visualDensity: VisualDensity.compact,
              onPressed: () => _updateStyle(() => _textSize = null),
            ),
        ],
      ),
    );
  }

  /// Строка анимации появления. Пишется в `item.textReveal`/`item.revealSpeed`.
  /// Скорость — в видимых символах в секунду: markdown-разметка (`**`, ссылки,
  /// `[color=…]`) в счёт не идёт, поэтому набор не «спотыкается» на служебных
  /// знаках и не показывает их игроку.
  Widget _buildRevealRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = _textReveal != kTextRevealDefault;
    // Не const: подписи чипов строятся под текущий язык.
    final labels = {
      'none': tr('Без анимации'),
      'typewriter': tr('Печать'),
      'fade': tr('Плавно'),
    };
    TextStyle chipStyle(bool selected) => TextStyle(
      color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      fontSize: 13,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.animation_rounded,
                size: 18,
                color: enabled ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                tr('Появление'),
                style: TextStyle(
                  color: enabled ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: enabled ? FontWeight.w600 : FontWeight.w400,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final value in kTextRevealValues)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: InkWell(
                          onTap: () => _updateStyle(() => _textReveal = value),
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _textReveal == value
                                  ? scheme.secondaryContainer
                                  : Colors.transparent,
                              border: Border.all(
                                color: _textReveal == value
                                    ? scheme.secondary
                                    : scheme.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              labels[value]!,
                              style: chipStyle(_textReveal == value),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (enabled)
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _revealSpeed.clamp(kRevealSpeedMin, kRevealSpeedMax),
                    min: kRevealSpeedMin,
                    max: kRevealSpeedMax,
                    divisions: (kRevealSpeedMax - kRevealSpeedMin).round(),
                    label: trf('{p0} симв/с', {'p0': _revealSpeed.round()}),
                    onChanged: (v) => _updateStyle(() => _revealSpeed = v),
                  ),
                ),
                SizedBox(
                  width: 74,
                  child: Text(
                    trf('{p0} симв/с', {'p0': _revealSpeed.round()}),
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: tr('Выключить анимацию появления'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      _updateStyle(() => _textReveal = kTextRevealDefault),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// Строка обводки. Пишется в `item.textOutlineColor`/`textOutlineWidth` —
  /// те же поля, что у текстового слоя стека, и рисуются тем же контуром под
  /// буквами. Толщина без цвета не имеет смысла, поэтому «убрать» снимает пару
  /// целиком, а ползунок показывается только при заданном цвете.
  Widget _buildOutlineRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasOutline = _textOutlineColor != null;
    final width = _textOutlineWidth ?? kTextOutlineWidthDefault;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.format_color_reset_rounded,
                size: 18,
                color: hasOutline ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                tr('Обводка'),
                style: TextStyle(
                  color: hasOutline ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: hasOutline ? FontWeight.w600 : FontWeight.w400,
                  fontSize: 13,
                ),
              ),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (hasOutline)
                        TextButton(
                          onPressed: () => _updateStyle(() {
                            _textOutlineColor = null;
                            _textOutlineWidth = null;
                          }),
                          child: Text(tr('убрать')),
                        ),
                      InkWell(
                        key: const ValueKey('md_outline_swatch'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: _pickOutlineColor,
                        child: Container(
                          width: 44,
                          height: 30,
                          decoration: BoxDecoration(
                            color: _textOutlineColor ?? Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: scheme.outline),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (hasOutline)
            Row(
              children: [
                Expanded(
                  child: Slider(
                    key: const ValueKey('md_outline_slider'),
                    value: width.clamp(1.0, kTextOutlineWidthMax),
                    min: 1,
                    max: kTextOutlineWidthMax,
                    divisions: kTextOutlineWidthMax.round() - 1,
                    label: '${width.round()} px',
                    onChanged: (v) => _updateStyle(() => _textOutlineWidth = v),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    '${width.round()} px',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// Тот же пикер, что и у инлайн-тега `[color=#…]`, только результат идёт в
  /// цвет контура, а не в цвет букв.
  Future<void> _pickOutlineColor() async {
    _focusNode.unfocus();
    final scheme = Theme.of(context).colorScheme;
    var currentColor = _textOutlineColor ?? scheme.onSurface;

    final picked = await showAppDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Цвет обводки')),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: currentColor,
            onColorChanged: (color) => currentColor = color,
            colorPickerWidth: 300,
            pickerAreaHeightPercent: 0.7,
            enableAlpha: false,
            displayThumbColor: true,
            paletteType: PaletteType.hsvWithHue,
            labelTypes: const [],
            pickerAreaBorderRadius: const BorderRadius.all(Radius.circular(12)),
            hexInputBar: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, currentColor),
            child: Text(tr('Применить')),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    _updateStyle(() => _textOutlineColor = picked);
  }

  Widget _buildBottomToolbar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Undo / Redo — состояние перерисовываем по изменению истории.
            ValueListenableBuilder<int>(
              valueListenable: _historyVersion,
              builder: (context, _, __) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ToolbarIconButton(
                      icon: Icons.undo_rounded,
                      tooltip: tr('Отменить'),
                      onPressed: _canUndo ? _undo : null,
                    ),
                    _ToolbarIconButton(
                      icon: Icons.redo_rounded,
                      tooltip: tr('Вернуть'),
                      onPressed: _canRedo ? _redo : null,
                    ),
                  ],
                );
              },
            ),
            _buildDivider(scheme),
            _ToolbarIconButton(
              icon: Icons.data_object_rounded,
              tooltip: tr('Вставить переменную'),
              onPressed: _insertVariable,
              tint: scheme.primary,
              background: scheme.primaryContainer,
            ),
            _ToolbarIconButton(
              icon: Icons.dataset_linked_rounded,
              tooltip: tr('Данные из таблицы'),
              onPressed: _insertTableData,
              tint: scheme.tertiary,
              background: scheme.tertiaryContainer,
            ),
            _buildDivider(scheme),
            _ToolbarIconButton(
              icon: Icons.palette_rounded,
              tooltip: tr('Цвет текста'),
              onPressed: _showColorPicker,
              tint: scheme.secondary,
              background: scheme.secondaryContainer,
            ),
            _ToolbarIconButton(
              icon: Icons.border_color_rounded,
              tooltip: tr('Обводка выделенного текста'),
              onPressed: _insertInlineOutline,
              tint: scheme.error,
              background: scheme.errorContainer,
            ),
            _ToolbarIconButton(
              icon: Icons.font_download_rounded,
              tooltip: tr('Шрифт выделенного текста'),
              onPressed: _insertInlineFontTag,
              tint: scheme.primary,
              background: scheme.primaryContainer,
            ),
            _buildDivider(scheme),
            _ToolbarIconButton(
              icon: Icons.format_bold_rounded,
              tooltip: tr('Жирный'),
              onPressed: () => _insertMarkdown('**', suffix: '**'),
            ),
            _ToolbarIconButton(
              icon: Icons.format_italic_rounded,
              tooltip: tr('Курсив'),
              onPressed: () => _insertMarkdown('*', suffix: '*'),
            ),
            _ToolbarIconButton(
              icon: Icons.format_strikethrough_rounded,
              tooltip: tr('Зачёркнутый'),
              onPressed: () => _insertMarkdown('~~', suffix: '~~'),
            ),
            _buildDivider(scheme),
            _ToolbarIconButton(
              icon: Icons.format_list_bulleted_rounded,
              tooltip: tr('Маркированный список'),
              onPressed: () => _insertMarkdown('\n- '),
            ),
            _ToolbarIconButton(
              icon: Icons.format_list_numbered_rounded,
              tooltip: tr('Нумерованный список'),
              onPressed: () => _insertMarkdown('\n1. '),
            ),
            _ToolbarIconButton(
              icon: Icons.format_quote_rounded,
              tooltip: tr('Цитата'),
              onPressed: () => _insertMarkdown('\n> '),
            ),
            _buildDivider(scheme),
            _ToolbarIconButton(
              icon: Icons.link_rounded,
              tooltip: tr('Ссылка'),
              onPressed: () => _insertMarkdown('[', suffix: ']()', offset: 1),
            ),
            _ToolbarIconButton(
              icon: Icons.code_rounded,
              tooltip: tr('Моноширинный код'),
              onPressed: () => _insertMarkdown('`', suffix: '`'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider(ColorScheme scheme) => Container(
    width: 1,
    height: 24,
    color: scheme.outlineVariant,
    margin: const EdgeInsets.symmetric(horizontal: 6),
  );
}

// ============================================================
//  WIDGETS
// ============================================================

/// Tab с иконкой и текстом в одной горизонтальной строке.
/// Стандартный `Tab(icon:, text:)` располагает их вертикально и требует
/// большой высоты — а нам нужен компактный pill-стиль M3.
class _IconTextTab extends StatelessWidget implements PreferredSizeWidget {
  final IconData icon;
  final String label;

  const _IconTextTab({required this.icon, required this.label});

  @override
  Size get preferredSize => const Size.fromHeight(40);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  // null = disabled (например, нечего отменять/вернуть).
  final VoidCallback? onPressed;
  final Color? tint;
  final Color? background;

  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.tint,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTonal = background != null;
    final disabled = onPressed == null;
    final disabledColor = scheme.onSurface.withOpacity(0.32);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: isTonal
              ? (disabled ? scheme.surfaceContainerHigh : background)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                icon,
                size: 20,
                color: disabled
                    ? disabledColor
                    : (tint ?? scheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
