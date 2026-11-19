import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Поле комментария, прижатое к низу экрана.
///
/// Одно на все комментарии: счётчик символов, предел ввода, строка «ответ
/// пользователю» и кнопка отправки выглядят одинаково и в сообществе, и в
/// канале. Экран отвечает только за то, куда уходит текст.
class CommentComposer extends StatelessWidget {
  const CommentComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isSubmitting,
    required this.onSubmit,
    required this.onChanged,
    this.maxLength = 500,
    this.replyingToUserName,
    this.onCancelReply,
    this.hintText,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isSubmitting;
  final VoidCallback onSubmit;
  final ValueChanged<String> onChanged;
  final int maxLength;
  final String? replyingToUserName;
  final VoidCallback? onCancelReply;
  final String? hintText;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = controller.text.trim().isNotEmpty;
    final length = controller.text.runes.length;
    final overLimit = length > maxLength;
    final canSubmit = hasText && !isSubmitting && !overLimit;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (replyingToUserName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Row(
                  children: [
                    Icon(Icons.reply_rounded, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        trf('Ответ пользователю {replyingToUserName}', {
                          'replyingToUserName': replyingToUserName,
                        }),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: onCancelReply,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Material(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: TextField(
                        key: const ValueKey('comment-input'),
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: autofocus,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 14.5,
                          height: 1.4,
                        ),
                        maxLines: 5,
                        minLines: 1,
                        maxLength: maxLength,
                        maxLengthEnforcement: MaxLengthEnforcement.enforced,
                        textCapitalization: TextCapitalization.sentences,
                        onChanged: onChanged,
                        onSubmitted: (_) {
                          if (canSubmit) onSubmit();
                        },
                        buildCounter:
                            (
                              _, {
                              required currentLength,
                              required isFocused,
                              maxLength,
                            }) => null,
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: hintText ?? tr('Написать комментарий…'),
                          hintStyle: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 14.5,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: canSubmit
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  shape: const CircleBorder(),
                  child: InkWell(
                    key: const ValueKey('comment-send'),
                    customBorder: const CircleBorder(),
                    onTap: canSubmit ? onSubmit : null,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: isSubmitting
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onPrimary,
                                ),
                              )
                            : Icon(
                                Icons.send_rounded,
                                size: 20,
                                color: canSubmit
                                    ? scheme.onPrimary
                                    : scheme.onSurfaceVariant,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (length > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 56),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '$length / $maxLength',
                    style: TextStyle(
                      color: overLimit ? scheme.error : scheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}