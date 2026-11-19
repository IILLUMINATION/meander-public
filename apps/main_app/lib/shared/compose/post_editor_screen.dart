import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:flutter/material.dart';

/// Полноэкранный редактор поста: «Редактирование» и «Предпросмотр», поле с
/// Markdown, панель инструментов и кнопка «Отправить» в шапке.
///
/// Один на все места, где пишут пост: стена сообщества, канал, дальше — что
/// угодно. Внизу-композер у канала был отдельной жизнью: кнопка «написать»
/// висела над его полем, отправка уезжала под клавиатуру, а выглядел он не
/// так, как написание поста в сообществе. Экран отвечает только за текст и
/// раскладку; куда и как уходит пост, решает вызывающий через [onSubmit].
class PostEditorScreen extends StatefulWidget {
  const PostEditorScreen({
    super.key,
    required this.onSubmit,
    this.title,
    this.controller,
    this.initialText = '',
    this.hintText,
    this.submitLabel,
    this.preview = true,
    this.editorToolbar,
    this.previewBuilder,
    this.extraEditorContent,
    this.toolbarHint,
  });

  /// Отправка. Возвращает `true`, если пост ушёл: экран тогда закрывается.
  /// Ошибку показывает тот, кто умеет — поле при этом не чистится.
  final Future<bool> Function(String text) onSubmit;

  final String? title;

  /// Внешний контроллер нужен, когда вызывающий работает с текстом напрямую:
  /// стена вставляет картинку в позицию курсора.
  final TextEditingController? controller;
  final String initialText;
  final String? hintText;
  final String? submitLabel;

  /// Вкладка «Предпросмотр». Каналу она тоже нужна: Markdown в постах тот же.
  final bool preview;

  /// Кнопки слева в нижней панели («вставить картинку», «прикрепить фото»).
  final List<Widget>? editorToolbar;

  /// Свой предпросмотр: у стены в нём ещё старые картинки.
  final Widget Function(String text)? previewBuilder;

  /// Блок под полем ввода — вложения, уже добавленные в пост.
  final Widget? extraEditorContent;

  /// Строка-подсказка справа в нижней панели.
  final String? toolbarHint;

  @override
  State<PostEditorScreen> createState() => _PostEditorScreenState();
}

class _PostEditorScreenState extends State<PostEditorScreen> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController(text: widget.initialText);
  final FocusNode _focusNode = FocusNode();
  bool _isSubmitting = false;
  bool _isPreview = false;

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      final sent = await widget.onSubmit(text);
      if (sent && mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canSubmit = !_isSubmitting && _controller.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(widget.title ?? tr('Новый пост')),
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonal(
              key: const ValueKey('post-editor-submit'),
              onPressed: canSubmit ? _submit : null,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(widget.submitLabel ?? tr('Отправить')),
            ),
          ),
        ],
      ),
      body: AdaptiveContent(
        maxWidth: 760,
        child: Column(
          children: [
            if (widget.preview) _tabs(scheme),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _isPreview && widget.preview
                    ? (widget.previewBuilder?.call(_controller.text) ??
                          _defaultPreview(scheme))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            key: const ValueKey('post-editor-field'),
                            controller: _controller,
                            focusNode: _focusNode,
                            maxLines: null,
                            minLines: 5,
                            style: TextStyle(
                              fontSize: 16,
                              color: scheme.onSurface,
                            ),
                            decoration: InputDecoration(
                              hintText:
                                  widget.hintText ??
                                  tr(
                                    'Что у вас нового? (Поддерживается Markdown и #теги)',
                                  ),
                              hintStyle: TextStyle(
                                color: scheme.onSurfaceVariant,
                              ),
                              border: InputBorder.none,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          if (widget.extraEditorContent != null) ...[
                            const SizedBox(height: 16),
                            widget.extraEditorContent!,
                          ],
                        ],
                      ),
              ),
            ),
            if (!(_isPreview && widget.preview) &&
                (widget.editorToolbar != null || widget.toolbarHint != null))
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  border: Border(top: BorderSide(color: scheme.outlineVariant)),
                ),
                child: Row(
                  children: [
                    ...?widget.editorToolbar,
                    const Spacer(),
                    if (widget.toolbarHint != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          widget.toolbarHint!,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tabs(ColorScheme scheme) {
    Widget tab(String label, bool selected, VoidCallback onTap) {
      return Expanded(
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? scheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      color: scheme.surface,
      child: Row(
        children: [
          tab(
            tr('Редактирование'),
            !_isPreview,
            () => setState(() => _isPreview = false),
          ),
          tab(tr('Предпросмотр'), _isPreview, () {
            _focusNode.unfocus();
            setState(() => _isPreview = true);
          }),
        ],
      ),
    );
  }

  Widget _defaultPreview(ColorScheme scheme) {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Text(
            tr('Предпросмотр пуст'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: MeanderEntityMarkdown(
        data: text,
        config: AppMarkdown.getConfig(context),
      ),
    );
  }
}
