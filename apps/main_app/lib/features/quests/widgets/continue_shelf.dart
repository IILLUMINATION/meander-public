import 'dart:io';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:flutter/material.dart';

/// Горизонтальная полка «продолжить»: последние открытые квесты.
///
/// Новый элемент библиотеки: раньше свежую сессию приходилось искать в общем
/// списке. Полка показывает до шести квестов и исчезает, когда включён
/// поиск или фильтр — тогда человек явно ищет другое.
class ContinueShelf extends StatelessWidget {
  final List<Quest> quests;
  final ValueChanged<Quest> onOpen;

  const ContinueShelf({super.key, required this.quests, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (quests.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 116,
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
    final scheme = Theme.of(context).colorScheme;
    final lastOpened = quest.lastOpened;
    return SizedBox(
      width: 258,
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                _Cover(quest: quest),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        quest.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        lastOpened == null
                            ? tr('Продолжить')
                            : trf('Открыт {p0}', {
                                'p0': formatRelativeTime(lastOpened),
                              }),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.play_arrow_rounded, size: 20, color: scheme.primary),
              ],
            ),
          ),
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
    final scheme = Theme.of(context).colorScheme;
    final path = quest.localPreviewPath;
    Widget child;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      child = Image.file(
        File(path),
        fit: BoxFit.cover,
        width: 56,
        height: 84,
        cacheWidth: 112,
        errorBuilder: (_, _, _) => _placeholder(scheme),
      );
    } else {
      child = _placeholder(scheme);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(width: 56, height: 84, child: child),
    );
  }

  Widget _placeholder(ColorScheme scheme) => ColoredBox(
    color: scheme.surfaceContainerHighest,
    child: Icon(
      Icons.menu_book_rounded,
      size: 22,
      color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
    ),
  );
}
