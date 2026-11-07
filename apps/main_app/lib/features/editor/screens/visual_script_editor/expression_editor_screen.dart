import 'package:canvas_app/features/editor/providers/formula_clipboard_provider.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/variable_selection_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mnd_core/engine/quest_resource_index.dart';
import 'package:mnd_core/utils/quest_paths.dart';

// ============================================================================
//  РЕДАКТОР ФОРМУЛ — Material 3 редизайн
// ============================================================================
//
//  Концепция:
//   • AppBar и фон — через ColorScheme.
//   • Дисплей формулы — крупный шрифт SourceCodePro на surfaceContainer.
//   • Клавиатура: M3 палитра, но «класс» клавиши кодируется тоном
//     (цифры — нейтральные surfaceContainerHighest; операторы —
//     secondaryContainer; акцент = / scope — primary; удалить —
//     errorContainer).
//   • Логические операторы (==, !=, &&, ||, true, false…) — семантические
//     акценты, но взяты из мягкой палитры (`shade400`) с opacity 0.18.
//   • Tab-бар «123 / ЛОГИКА / ФУНКЦИИ» — стандартный M3.
//
// ============================================================================

class ExpressionEditorScreen extends StatefulWidget {
  final String initialValue;
  final String questId;

  /// Контекстный заголовок (что редактируем). Если не задан —
  /// нейтральный «Редактор формул».
  final String? title;

  /// Поле хранит шаблон строки, а не формулу: `{переменная}` подставляется
  /// движком, всё остальное идёт как есть (`set_image` источник, `resourceExpr`
  /// картинки). Кавычки здесь автор не уберёт, и путь `'cat.png'` перестал бы
  /// резолвиться — поэтому в шаблонном поле пикеры вставляют токен без кавычек.
  final bool isTemplate;

  const ExpressionEditorScreen({
    super.key,
    required this.initialValue,
    required this.questId,
    this.title,
    this.isTemplate = false,
  });

  @override
  State<ExpressionEditorScreen> createState() => _ExpressionEditorScreenState();
}

/// Как вставить токен ресурса в поле с данной грамматикой: шаблон строки
/// (`set_image` источник, `resourceExpr`) идёт дословно, формула — строковым
/// литералом в кавычках.
@visibleForTesting
String resourceLiteral(String token, {required bool isTemplate}) {
  if (isTemplate) return token;
  return "'${token.replaceAll("'", "\\'")}'";
}

class _ExpressionEditorScreenState extends State<ExpressionEditorScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  late final TabController _tabController;
  final ScrollController _editorScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _tabController = TabController(length: 3, vsync: this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      if (_controller.text.isNotEmpty) {
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _tabController.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }

  TextSelection _getValidSelection() {
    final selection = _controller.selection;
    final textLength = _controller.text.length;
    if (!selection.isValid || selection.start < 0) {
      return TextSelection.collapsed(offset: textLength);
    }
    return selection;
  }

  void _insertText(String textToInsert, {int? cursorOffset}) {
    final currentText = _controller.text;
    final selection = _getValidSelection();

    final newText = currentText.replaceRange(
      selection.start,
      selection.end,
      textToInsert,
    );
    final newCursorPos =
        selection.start + (cursorOffset ?? textToInsert.length);

    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );
    _focusNode.requestFocus();
    _scrollEditorToBottom();
  }

  void _backspace() {
    final text = _controller.text;
    if (text.isEmpty) return;

    final selection = _getValidSelection();
    if (selection.isCollapsed && selection.start == 0) return;

    final start = selection.start;
    final end = selection.end;

    String newText;
    int newCursorPos;

    if (!selection.isCollapsed) {
      newText = text.replaceRange(start, end, '');
      newCursorPos = start;
    } else {
      newText = text.replaceRange(start - 1, start, '');
      newCursorPos = start - 1;
    }

    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );
    _focusNode.requestFocus();
    _scrollEditorToBottom();
  }

  void _moveCursor(int offset) {
    final text = _controller.text;
    final selection = _getValidSelection();
    final newOffset = (selection.baseOffset + offset).clamp(0, text.length);
    _controller.selection = TextSelection.collapsed(offset: newOffset);
    _focusNode.requestFocus();
  }

  void _clearAll() {
    _controller.clear();
    _focusNode.requestFocus();
    _scrollEditorToBottom();
  }

  void _scrollEditorToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_editorScrollController.hasClients) return;
      _editorScrollController.animateTo(
        _editorScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _insertVariable() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            VariableSelectionScreen.forTextInsert(questId: widget.questId),
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      _insertText(bracedVariableToken(result));
    }
  }

  Future<void> _insertCustomText() async {
    final textController = TextEditingController();
    final text = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Вставить текст')),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr('Введите значение…'),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, textController.text),
            child: Text(tr('Вставить')),
          ),
        ],
      ),
    );

    if (text != null) {
      _insertText(_literal(text));
    }
  }

  /// Литерал для текущего поля: в формуле — в кавычках, в шаблоне — как есть.
  String _literal(String token) =>
      resourceLiteral(token, isTemplate: widget.isTemplate);

  /// Пикер картинки: вместо пути из библиотеки вставляется короткий токен
  /// (`cat.png`), который резолвер разворачивает в `res/images/…`. Так автору
  /// не нужно помнить, в какой папке лежит файл.
  Future<void> _insertImageResource() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (context) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    if (result == null || !mounted) return;
    final token = resourceReference(
      fileName: result.name,
      // `ResourceSelectionScreen` отдаёт путь от корня документов
      // (`quests/<id>/res/…`), а резолверу нужен путь относительно квеста.
      path: _questRelative(result.path),
    );
    if (token.isEmpty) return;
    _insertText(_literal(token));
  }

  String _questRelative(String path) {
    final root = '${QuestPaths.questRoot(widget.questId)}/';
    return path.startsWith(root) ? path.substring(root.length) : path;
  }

  void _copyFormula(WidgetRef ref) {
    final formula = _controller.text.trim();
    if (formula.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: formula));
      ref.read(formulaClipboardProvider.notifier).state = formula;
      _showSnack(tr('Формула скопирована'), success: true);
    }
  }

  Future<void> _pasteFormula(WidgetRef ref) async {
    final clipboardData = await Clipboard.getData('text/plain');
    final clipboardText = clipboardData?.text ?? '';
    if (clipboardText.isEmpty) return;

    final currentFormula = ref.read(formulaClipboardProvider);
    if (currentFormula != null && currentFormula.isNotEmpty) {
      _insertText(currentFormula);
      _showSnack(tr('Формула вставлена из буфера'), info: true);
    } else {
      _insertText(clipboardText);
      _showSnack(tr('Текст вставлен из буфера'), info: true);
    }
  }

  void _saveAndExit() {
    Navigator.pop(context, _controller.text.trim());
  }

  void _showSnack(String text, {bool success = false, bool info = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    Color? bg;
    Color? fg;
    if (success) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
    } else if (info) {
      bg = scheme.secondaryContainer;
      fg = scheme.onSecondaryContainer;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        closeIconColor: fg,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, child) {
        final scheme = Theme.of(context).colorScheme;

        // Поле формулы и палитра: на ПК они живут рядом, на телефоне —
        // стопкой. Одной колонкой на мониторе кнопки разъезжались на всю
        // ширину, а формула оставалась узкой строкой внизу экрана.
        // Поле на ПК набирают с клавиатуры — read-only только на телефоне.
        final wide = isDesktopWidth(context);
        final displayCard = Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _focusNode.requestFocus(),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      // На телефоне набирают палитрой, и поле специально
                      // закрыто от системной клавиатуры. На ПК в нём печатают.
                      readOnly: !wide,
                      showCursor: true,
                      autofocus: true,
                      scrollController: _editorScrollController,
                      maxLines: null,
                      minLines: 3,
                      textAlign: TextAlign.left,
                      textAlignVertical: TextAlignVertical.top,
                      cursorColor: scheme.primary,
                      style: GoogleFonts.sourceCodePro(
                        color: scheme.onSurface,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: '0',
                        hintStyle: TextStyle(
                          color: scheme.onSurfaceVariant.withOpacity(0.4),
                        ),
                        isCollapsed: true,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _ChipBtn(
                        icon: Icons.image_rounded,
                        label: tr('Картинка'),
                        tone: _ChipTone.secondary,
                        onTap: _insertImageResource,
                      ),
                      const SizedBox(width: 10),
                      _ChipBtn(
                        icon: Icons.data_object_rounded,
                        label: tr('Переменная'),
                        tone: _ChipTone.primary,
                        onTap: _insertVariable,
                      ),
                      const SizedBox(width: 10),
                      _ChipBtn(
                        icon: Icons.text_fields_rounded,
                        label: tr('Текст'),
                        tone: _ChipTone.tertiary,
                        onTap: _insertCustomText,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
        final keypadPane = Column(
          children: [
            TabBar(
              controller: _tabController,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.label,
              labelColor: scheme.primary,
              unselectedLabelColor: scheme.onSurfaceVariant,
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
              unselectedLabelStyle: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
              tabs: [
                Tab(text: '123'),
                Tab(text: tr('Логика')),
                Tab(text: tr('Функции')),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: SafeArea(
                  top: false,
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _NumericPad(
                        onInsert: _insertText,
                        onBackspace: _backspace,
                        onClearAll: _clearAll,
                        onMoveCursor: _moveCursor,
                      ),
                      _LogicPad(onInsert: _insertText, onBackspace: _backspace),
                      _FunctionsPad(onInsert: _insertText),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );

        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            title: Text(
              widget.title ?? tr('Редактор формул'),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            actions: [
              IconButton(
                onPressed: () => _copyFormula(ref),
                icon: Icon(
                  Icons.content_copy_rounded,
                  color: scheme.onSurfaceVariant,
                ),
                tooltip: tr('Копировать формулу'),
              ),
              IconButton(
                onPressed: () => _pasteFormula(ref),
                icon: Icon(
                  Icons.content_paste_rounded,
                  color: scheme.onSurfaceVariant,
                ),
                tooltip: tr('Вставить формулу'),
              ),
              IconButton(
                onPressed: _saveAndExit,
                icon: Icon(Icons.check_rounded, color: scheme.primary),
                tooltip: tr('Готово'),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: AdaptiveContent(
            maxWidth: wide ? 1180 : 760,
            child: wide
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: displayCard),
                        const SizedBox(width: 12),
                        SizedBox(width: 430, child: keypadPane),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      Expanded(flex: 3, child: displayCard),
                      Expanded(flex: 4, child: keypadPane),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

// ============================================================================
//  ЧИП-КНОПКА ВЫШЕ КЛАВИАТУРЫ
// ============================================================================

enum _ChipTone { secondary, primary, tertiary }

class _ChipBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final _ChipTone tone;
  final VoidCallback onTap;

  const _ChipBtn({
    required this.icon,
    required this.label,
    required this.tone,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    late final Color bg;
    late final Color fg;
    switch (tone) {
      case _ChipTone.secondary:
        bg = scheme.secondaryContainer;
        fg = scheme.onSecondaryContainer;
        break;
      case _ChipTone.primary:
        bg = scheme.primaryContainer;
        fg = scheme.onPrimaryContainer;
        break;
      case _ChipTone.tertiary:
        bg = scheme.tertiaryContainer;
        fg = scheme.onTertiaryContainer;
        break;
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  NUMERIC PAD
// ============================================================================

class _NumericPad extends StatelessWidget {
  final void Function(String text, {int? cursorOffset}) onInsert;
  final VoidCallback onBackspace;
  final VoidCallback onClearAll;
  final void Function(int offset) onMoveCursor;

  const _NumericPad({
    required this.onInsert,
    required this.onBackspace,
    required this.onClearAll,
    required this.onMoveCursor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final numBg = scheme.surfaceContainerHighest;
    final numFg = scheme.onSurface;
    final opBg = scheme.secondaryContainer;
    final opFg = scheme.onSecondaryContainer;
    final brBg = scheme.tertiaryContainer;
    final brFg = scheme.onTertiaryContainer;
    final delBg = scheme.errorContainer;
    final delFg = scheme.onErrorContainer;

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              _Key('7', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('8', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('9', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('÷', val: '/', bg: opBg, fg: opFg, onInsert: onInsert),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _Key('4', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('5', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('6', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('×', val: '*', bg: opBg, fg: opFg, onInsert: onInsert),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _Key('1', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('2', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('3', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('−', val: '-', bg: opBg, fg: opFg, onInsert: onInsert),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _Key('.', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('0', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key(',', bg: numBg, fg: numFg, onInsert: onInsert),
              _Key('+', bg: opBg, fg: opFg, onInsert: onInsert),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _Key('(', bg: brBg, fg: brFg, onInsert: onInsert),
              _Key(')', bg: brBg, fg: brFg, onInsert: onInsert),
              _IconKey(
                Icons.arrow_back_rounded,
                bg: opBg,
                fg: opFg,
                onTap: () => onMoveCursor(-1),
              ),
              _IconKey(
                Icons.arrow_forward_rounded,
                bg: opBg,
                fg: opFg,
                onTap: () => onMoveCursor(1),
              ),
              _IconKey(
                Icons.backspace_outlined,
                bg: delBg,
                fg: delFg,
                onTap: onBackspace,
                onLongPress: onClearAll,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
//  LOGIC PAD
// ============================================================================

class _LogicPad extends StatelessWidget {
  final void Function(String text, {int? cursorOffset}) onInsert;
  final VoidCallback onBackspace;

  const _LogicPad({required this.onInsert, required this.onBackspace});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Семантические акценты для разных групп операторов (мягкие пастельные).
    Color softBg(Color base) => base.withOpacity(0.18);

    final neutralBg = scheme.surfaceContainerHighest;
    final neutralFg = scheme.onSurface;
    final brBg = scheme.tertiaryContainer;
    final brFg = scheme.onTertiaryContainer;
    final delBg = scheme.errorContainer;
    final delFg = scheme.onErrorContainer;

    final eqAccent = Colors.indigo.shade400;
    final boolAccent = Colors.orange.shade400;
    final nullAccent = Colors.deepPurple.shade300;
    final trueAccent = Colors.green.shade400;
    final falseAccent = Colors.red.shade400;
    final bracketAccent = Colors.teal.shade400;
    final quoteAccent = Colors.pink.shade300;
    final notAccent = Colors.red.shade400;

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              _Key(
                '==',
                bg: softBg(eqAccent),
                fg: eqAccent,
                onInsert: onInsert,
              ),
              _Key(
                '!=',
                bg: softBg(eqAccent),
                fg: eqAccent,
                onInsert: onInsert,
              ),
              _Key(
                '&&',
                val: ' && ',
                bg: softBg(boolAccent),
                fg: boolAccent,
                onInsert: onInsert,
              ),
              _Key(
                '||',
                val: ' || ',
                bg: softBg(boolAccent),
                fg: boolAccent,
                onInsert: onInsert,
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _Key('>', bg: neutralBg, fg: neutralFg, onInsert: onInsert),
              _Key('<', bg: neutralBg, fg: neutralFg, onInsert: onInsert),
              _Key('>=', bg: neutralBg, fg: neutralFg, onInsert: onInsert),
              _Key('<=', bg: neutralBg, fg: neutralFg, onInsert: onInsert),
              _Key(
                'in',
                // Вставляем " in (…)" и ставим курсор внутрь скобок,
                // чтобы можно было сразу перечислять значения: {A} in (1, 2, 3)
                val: ' in ()',
                cursorOffset: -1,
                bg: softBg(boolAccent),
                fg: boolAccent,
                onInsert: onInsert,
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _Key(
                'null',
                bg: softBg(nullAccent),
                fg: nullAccent,
                onInsert: onInsert,
              ),
              _Key(
                'true',
                bg: softBg(trueAccent),
                fg: trueAccent,
                onInsert: onInsert,
              ),
              _Key(
                'false',
                bg: softBg(falseAccent),
                fg: falseAccent,
                onInsert: onInsert,
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _Key(
                '[',
                bg: softBg(bracketAccent),
                fg: bracketAccent,
                onInsert: onInsert,
              ),
              _Key(
                ']',
                bg: softBg(bracketAccent),
                fg: bracketAccent,
                onInsert: onInsert,
              ),
              _Key(
                '"',
                bg: softBg(quoteAccent),
                fg: quoteAccent,
                onInsert: onInsert,
              ),
              _Key(
                "'",
                bg: softBg(quoteAccent),
                fg: quoteAccent,
                onInsert: onInsert,
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _Key(
                '!',
                bg: softBg(notAccent),
                fg: notAccent,
                onInsert: onInsert,
              ),
              _Key('(', bg: brBg, fg: brFg, onInsert: onInsert),
              _Key(')', bg: brBg, fg: brFg, onInsert: onInsert),
              _IconKey(
                Icons.backspace_outlined,
                bg: delBg,
                fg: delFg,
                onTap: onBackspace,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
//  FUNCTIONS PAD
// ============================================================================

class _FunctionsPad extends StatelessWidget {
  final void Function(String text, {int? cursorOffset}) onInsert;
  const _FunctionsPad({required this.onInsert});

  // Мини-справка при каждой функции: без подписи аргументов список превращается
  // в угадывание «а что там вторым аргументом и с какой единицы считается».
  // Геттер, а не static final: список строится под текущий язык. Кэшированный
  // final показал бы русский справочник и после переключения на английский.
  static List<_FuncGroup> get _groups => <_FuncGroup>[
    _FuncGroup(tr('Числа'), [
      _FuncEntry(
        tr('Случайное число'),
        'random(1, 100)',
        tr('random(от, до) — целые границы дают целое, иначе дробь'),
      ),
      _FuncEntry(
        tr('Остаток от деления'),
        'mod(i, 3)',
        tr('mod(a, b) — всегда ≥ 0 при b > 0, т. е. mod(-1, 3) = 2'),
      ),
      _FuncEntry(
        tr('Округление (round)'),
        'round(x)',
        tr('round(x, знаков) — знаков по умолчанию 0'),
      ),
      _FuncEntry(
        tr('Округление вниз (floor)'),
        'floor(x)',
        tr('floor(x) — к меньшему целому'),
      ),
      _FuncEntry(
        tr('Округление вверх (ceil)'),
        'ceil(x)',
        tr('ceil(x) — к большему целому'),
      ),
      _FuncEntry(
        tr('Отбросить дробь (trunc)'),
        'trunc(x)',
        tr('trunc(x) — к нулю: trunc(-2.7) = -2'),
      ),
      _FuncEntry(tr('Модуль (abs)'), 'abs(x)', tr('abs(x) — |x|')),
      _FuncEntry(tr('Знак (sign)'), 'sign(x)', tr('sign(x) — -1, 0 или 1')),
      _FuncEntry(
        tr('Минимум (min)'),
        'min(a, b, c)',
        tr('min(…аргументы) — меньше всех, массивы считаются целиком'),
      ),
      _FuncEntry(
        tr('Максимум (max)'),
        'max(a, b, c)',
        tr('max(…аргументы) — больше всех'),
      ),
      _FuncEntry(
        tr('Сумма (sum)'),
        'sum(1, 2, scores)',
        tr('sum(…аргументы) — массив складывается по элементам'),
      ),
      _FuncEntry(
        tr('Среднее (avg)'),
        'avg(scores)',
        tr('avg(…аргументы) — сумма / количество'),
      ),
      _FuncEntry(
        tr('Ограничитель (clamp)'),
        'clamp(v, 0, 100)',
        tr('clamp(значение, min, max) — не выпускает за границы'),
      ),
      _FuncEntry(
        tr('В диапазоне? (between)'),
        'between(v, 1, 10)',
        tr('between(значение, от, до) — границы включительно'),
      ),
      _FuncEntry(tr('Корень (sqrt)'), 'sqrt(x)', tr('sqrt(x) — √x')),
      _FuncEntry(tr('Степень (pow)'), 'pow(x, 2)', tr('pow(основание, показатель)')),
      _FuncEntry(
        tr('Логарифм (log)'),
        'log(x, 2)',
        tr('log(x) — десятичный, log(x, основание) — по основанию'),
      ),
      _FuncEntry(tr('Натуральный логарифм'), 'ln(x)', tr('ln(x) — log по основанию e')),
      _FuncEntry(
        tr('Гипотенуза (hypot)'),
        'hypot(dx, dy)',
        tr('hypot(a, b) — √(a² + b²), расстояние без корней'),
      ),
      _FuncEntry(tr('Синус (sin)'), 'sin(x)', tr('sin(x) — аргумент в радианах')),
      _FuncEntry(tr('Косинус (cos)'), 'cos(x)', tr('cos(x) — аргумент в радианах')),
      _FuncEntry(tr('Тангенс (tan)'), 'tan(x)', tr('tan(x) — аргумент в радианах')),
      _FuncEntry(tr('Градусы → радианы'), 'rad(90)', tr('rad(градусы) — для sin/cos')),
      _FuncEntry(
        tr('Радианы → градусы'),
        'deg(x)',
        tr('deg(радианы) — обратно в градусы'),
      ),
      _FuncEntry(tr('Число π'), 'pi()', tr('pi() — 3.14159…')),
    ]),
    _FuncGroup(tr('Текст'), [
      _FuncEntry(
        tr('Заглавные (upper)'),
        'upper(name)',
        tr('upper(текст) — «привет» → «ПРИВЕТ», кириллицу тоже'),
      ),
      _FuncEntry(
        tr('Строчные (lower)'),
        'lower(name)',
        tr('lower(текст) — → «привет»'),
      ),
      _FuncEntry(
        tr('Убрать пробелы (trim)'),
        'trim(answer)',
        tr('trim(текст) — срезает пробелы по краям'),
      ),
      _FuncEntry(
        tr('С большой буквы'),
        'capitalize(name)',
        tr('capitalize(текст) — первую букву в верхний регистр'),
      ),
      _FuncEntry(
        tr('Длина (length)'),
        'length(str)',
        tr('length(текст | массив | таблица) — символов или элементов'),
      ),
      _FuncEntry(
        tr('Кусок текста (substr)'),
        'substr(text, 0, 5)',
        tr('substr(текст, от, длина) — счёт с 0; длину пропустить = до конца'),
      ),
      _FuncEntry(
        tr('Найти подстроку'),
        'index_of(text, "а")',
        tr('index_of(текст, что) — позиция с 0, если нет → -1'),
      ),
      _FuncEntry(
        tr('Содержит текст?'),
        'contains(str, "abc")',
        tr('contains(текст, подстрока) — true/false'),
      ),
      _FuncEntry(
        tr('Начинается с…'),
        'starts_with(code, "№")',
        tr('starts_with(текст, префикс) — true/false'),
      ),
      _FuncEntry(
        tr('Заканчивается на…'),
        'ends_with(file, ".png")',
        tr('ends_with(текст, суффикс) — true/false'),
      ),
      _FuncEntry(
        tr('Заменить (replace)'),
        'replace(text, "-", " ")',
        tr('replace(текст, что, на_что) — все вхождения; 3-й аргумент пропустить = удалить'),
      ),
      _FuncEntry(tr('Повторить (repeat)'), 'repeat("-", 10)', tr('repeat(текст, раз)')),
      _FuncEntry(
        tr('Дополнить слева (pad_left)'),
        'pad_left(n, 3, "0")',
        tr('pad_left(текст, ширина, чем) — 007 из 7; чем по умолчанию пробел'),
      ),
      _FuncEntry(
        tr('Разбить на части (split)'),
        'split(line, ",")[1]',
        tr('split(текст, разделитель) → массив; берётся элементом [0]'),
      ),
      _FuncEntry(
        tr('Собрать из частей (join)'),
        'join(scores, " / ")',
        tr('join(массив, разделитель) → текст'),
      ),
      _FuncEntry(
        tr('Текст из числа (to_str)'),
        'to_str(gold)',
        tr('to_str(значение) — строка, удобно для «+»'),
      ),
      _FuncEntry(
        tr('Склонение (plural)'),
        "plural(n, 'строка', 'строки', 'строк')",
        tr('plural(число, 1, 2-4, 5+) — правильная русская форма'),
      ),
    ]),
    _FuncGroup(tr('Логика'), [
      _FuncEntry(
        tr('Если (if)'),
        'if(hp > 0, "жив", "мёртв")',
        tr('if(условие, то, иначе) — обе ветки считаются, делить на ноль нельзя'),
      ),
      _FuncEntry(
        tr('Первое непустое'),
        'coalesce(name, "безымянный")',
        tr('coalesce(…аргументы) — первое не null и не пустая строка'),
      ),
      _FuncEntry(
        tr('Пусто? (is_empty)'),
        'is_empty(answer)',
        tr('is_empty(значение) — null, пробел или пустой массив'),
      ),
      _FuncEntry(
        tr('Это число? (is_num)'),
        'is_num(answer)',
        tr('is_num(значение) — «42» и 42 → true'),
      ),
      _FuncEntry(
        tr('В число (num)'),
        'num(answer)',
        tr('num(текст) — «42» → 42, иначе null'),
      ),
      _FuncEntry(
        tr('Истина (bool)'),
        'bool(flag)',
        tr('bool(значение) — по правилу «пусто → false»'),
      ),
      _FuncEntry(
        tr('Не (not)'),
        'not(visited)',
        tr('not(значение) — разворот условия'),
      ),
    ]),
    _FuncGroup(
      tr('Таблицы'),
      [
        _FuncEntry(
          tr('Ячейка таблицы'),
          'shop["цена"][1]',
          tr('таблица[колонка][строка] — строка с 1; ссылка отдельной фигурной скобкой, внутри формулы берите table_cell'),
        ),
        _FuncEntry(
          tr('Ключ хранилища скриптов'),
          "shop['открыто']",
          tr("лавка['ключ'] — то же хранилище, с которым работает блок «Данные»"),
        ),
      _FuncEntry(
        tr('Строка таблицы'),
        'shop.rows[1].цена',
        tr('таблица.rows[номер].колонка, таблица.columns[номер]'),
      ),
      _FuncEntry(
        tr('Сколько строк (table_rows)'),
        'table_rows(shop)',
        tr('table_rows(таблица) — число строк сетки'),
      ),
      _FuncEntry(
        tr('Колонки (table_columns)'),
        'table_columns(shop)',
        tr('table_columns(таблица) — массив имён колонок'),
      ),
      _FuncEntry(
        tr('Значения колонки (table_column)'),
        'table_column(shop, "цена")',
        tr('массив значений — дальше в sum(), join(), length()'),
      ),
      _FuncEntry(
        tr('Ячейка функцией (table_cell)'),
        'table_cell(shop, "цена", 2)',
        tr('table_cell(таблица, колонка, строка) — строка с 1'),
      ),
      _FuncEntry(
        tr('Строка целиком (table_row)'),
        'table_row(shop, 2)["товар"]',
        tr('table_row(таблица, номер) — строка как объект'),
      ),
      _FuncEntry(
        tr('Сумма колонки (table_sum)'),
        'table_sum(shop, "цена")',
        tr('нечисловые ячейки пропускаются, как в sum()'),
      ),
      _FuncEntry(
        tr('Среднее по колонке (table_avg)'),
        'table_avg(shop, "цена")',
        tr('table_avg(таблица, колонка)'),
      ),
      _FuncEntry(
        tr('Минимум колонки (table_min)'),
        'table_min(shop, "цена")',
        tr('есть ещё table_max(таблица, колонка)'),
      ),
      _FuncEntry(
        tr('Найти строку (table_find)'),
        'table_find(shop, "товар", "ключ")',
        tr('номер строки с 1, 0 если не нашлось'),
      ),
      _FuncEntry(
        tr('Все подходящие строки (table_where)'),
        'table_where(shop, "тип", "еда")',
        tr('массив номеров; length(table_where(…)) — сколько их'),
      ),
      _FuncEntry(
        tr('Есть такой value? (table_has)'),
        'table_has(shop, "товар", "ключ")',
        tr('true/false; сравнивает «30» и 30 как равные'),
      ),
      _FuncEntry(
        tr('Таблица текстом (table_text)'),
        'table_text(shop)',
        tr('строки через перевод строки; sep-аргумент меняет разделитель колонок'),
      ),
      ],
      note:
          tr('У таблицы два содержимого: сетка (функции ниже) и ключи хранилища скриптов — лавка[\'ключ\'], его же читает и пишет блок «Данные». Функцию оставляем в поле целиком: {table_cell(лавка, "цена", 1)} не вычисляется, а {лавка["цена"][1] + 5} теряет «+ 5».'),
    ),
    _FuncGroup(tr('Переменные'), [
      _FuncEntry(
        tr('Значение по имени'),
        "get_var('item_' + n)",
        tr("get_var(имя) — значение переменной, имя можно собрать"),
      ),
      _FuncEntry(
        tr('Переменная задана?'),
        "has_var('name')",
        tr('has_var(имя) — true/false'),
      ),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final g in _groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  g.title,
                  style: TextStyle(
                    color: scheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (g.note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      g.note!,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (final f in g.funcs) ...[
            _FuncCard(entry: f, onInsert: onInsert),
            const SizedBox(height: 6),
          ],
        ],
      ],
    );
  }
}

class _FuncGroup {
  final String title;
  final List<_FuncEntry> funcs;

  /// Одна строка про группу: где подвох, его видно сразу, а не после прогона.
  final String? note;
  const _FuncGroup(this.title, this.funcs, {this.note});
}

class _FuncEntry {
  final String label;
  final String insert;
  final String doc;
  const _FuncEntry(this.label, this.insert, this.doc);
}

class _FuncCard extends StatelessWidget {
  final _FuncEntry entry;
  final void Function(String text, {int? cursorOffset}) onInsert;
  const _FuncCard({required this.entry, required this.onInsert});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onInsert(entry.insert),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.label,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.insert,
                      style: GoogleFonts.sourceCodePro(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.doc,
                      style: TextStyle(
                        color: scheme.outline,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.add_circle_outline_rounded, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  KEY PRIMITIVES
// ============================================================================

class _Key extends StatelessWidget {
  final String label;
  final String? val;
  final int? cursorOffset;
  final Color bg;
  final Color fg;
  final void Function(String text, {int? cursorOffset}) onInsert;

  const _Key(
    this.label, {
    this.val,
    this.cursorOffset,
    required this.bg,
    required this.fg,
    required this.onInsert,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              final text = val ?? label;
              if (cursorOffset != null) {
                onInsert(text, cursorOffset: text.length + cursorOffset!);
              } else {
                onInsert(text);
              }
            },
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconKey extends StatelessWidget {
  final IconData icon;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _IconKey(
    this.icon, {
    required this.bg,
    required this.fg,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              onTap();
            },
            onLongPress: onLongPress == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onLongPress!();
                  },
            child: Center(child: Icon(icon, color: fg, size: 22)),
          ),
        ),
      ),
    );
  }
}
