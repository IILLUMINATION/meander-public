import 'dart:io';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/shared/adwaita/adw.dart';
import 'package:flutter/material.dart';

/// Горизонтальная полка «продолжить»: последние открытые квесты.
///
/// Новый элемент библиотеки: раньше свежую сессию приходилось искать в общем
/// списке. Полка показывает до шести квестов и исчезает, когда включён
/// поиск или фильтр — тогда человек явно ищет другое.
///
/// Карточка — Adwaita card 12 px: обложка-корешок, title-3, приглушённое
/// «Открыт …» и круглая кнопка воспроизведения в акценте.
class ContinueShelf extends StatelessWidget {
  final List<Quest> quests;
  final ValueChanged<Quest> onOpen;

  const ContinueShelf({super.key, required this.quests, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (quests.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 112,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: quests.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final quest = quests[index];
          return _ContinueCard(quest: quest, onTap: () => onOpen(quest));
        },
      ),
    );
  }
}

class _ContinueCard extends StatelessWidget {
  final Quest quest;
  final VoidCallback onTap;

  const _ContinueCard({required this.quest, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final lastOpened = quest.lastOpened;
    return SizedBox(
      width: 258,
      child: AdwCard(
        onTap: onTap,
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            _Cover(quest: quest),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    quest.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.adw.bodyStrong,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    lastOpened == null
                        ? tr('Продолжить')
                        : trf('Открыт {p0}', {
                            'p0': formatRelativeTime(lastOpened),
                          }),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.adw.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: context.adw.accent,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: AdwIcon(
                  AdwIcons.play,
                  size: 14,
                  color: context.adw.fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  final Quest quest;

  const _Cover({required this.quest});

  @override
  Widget build(BuildContext context) {
    final path = quest.localPreviewPath;
    Widget child;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      child = Image.file(
        File(path),
        fit: BoxFit.cover,
        width: 56,
        height: 84,
        cacheWidth: 112,
        errorBuilder: (_, _, _) => placeholder(context),
      );
    } else {
      child = placeholder(context);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AdwRadius.control),
      child: SizedBox(width: 56, height: 84, child: child),
    );
  }

  Widget placeholder(BuildContext context) => ColoredBox(
    color: context.adw.active,
    child: Center(
      child: AdwIcon(
        AdwIcons.library,
        size: 20,
        color: context.adw.fgDim,
      ),
    ),
  );
}