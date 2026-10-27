import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';

import '../models/guide.dart';
import '../screens/guide_screen.dart';

/// Приглашение в гайд при входе в раздел.
///
/// Показывается один раз за запуск и не возвращается после «Больше не
/// спрашивать» или после открытия гайда. «Позже» — только до следующего
/// запуска: человек не обязан решать прямо сейчас.
class GuidePrompt {
  GuidePrompt._();

  static const String hintId = 'guide_prompt_library';

  static final Set<String> _shownThisSession = <String>{};

  /// Чистое правило, чтобы его можно было проверить без виджетов.
  static bool shouldShow({
    required bool dismissed,
    required bool alreadyShown,
  }) => !dismissed && !alreadyShown;

  /// Сброс — из настроек («Показать объяснения заново»).
  static void resetSession() => _shownThisSession.clear();

  static Future<void> maybeShow(BuildContext context, GuideInfo info) async {
    final dismissed = await SectionHintService.isDismissed(hintId);
    if (!shouldShow(
      dismissed: dismissed,
      alreadyShown: _shownThisSession.contains(info.id),
    )) {
      return;
    }
    if (!context.mounted) return;
    _shownThisSession.add(info.id);

    final open = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => _GuidePromptDialog(info: info),
    );
    if (open != true) return;

    await SectionHintService.dismiss(hintId);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GuideScreen(info: info)),
    );
  }
}

class _GuidePromptDialog extends StatelessWidget {
  final GuideInfo info;

  const _GuidePromptDialog({required this.info});

  Future<void> _dismissForever(BuildContext context) async {
    await SectionHintService.dismiss(GuidePrompt.hintId);
    if (context.mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: info.accent.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: Icon(info.icon, color: info.accent, size: 28),
      ),
      title: Text(tr('Хотите узнать, как создать квест?')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Короткий офлайн-гайд: статья, видео и схемы с подсказками.'),
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PromptChip(icon: Icons.menu_book_rounded, text: tr('Статья')),
              _PromptChip(
                icon: Icons.play_circle_outline_rounded,
                text: tr('Видео'),
              ),
              _PromptChip(icon: Icons.touch_app_rounded, text: tr('Схемы')),
            ],
          ),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _dismissForever(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 36),
                foregroundColor: scheme.onSurfaceVariant,
              ),
              child: Text(tr('Больше не спрашивать')),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('Позже')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('Открыть гайд')),
        ),
      ],
    );
  }
}

class _PromptChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _PromptChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
