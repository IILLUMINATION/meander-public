import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Пусто, ошибка и загрузка списка комментариев — общие для любого экрана,
/// где есть комментарии.

class CommentsEmpty extends StatelessWidget {
  const CommentsEmpty({super.key, this.title, this.subtitle});

  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.mode_comment_outlined,
                size: 32,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title ?? tr('Пока нет комментариев'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle ?? tr('Будьте первым, кто оставит мнение'),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class CommentsError extends StatelessWidget {
  const CommentsError({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              tr('Не удалось загрузить'),
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr('Повторить')),
            ),
          ],
        ),
      ),
    );
  }
}

class CommentsShimmer extends StatelessWidget {
  const CommentsShimmer({super.key, this.count = 5});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, _) {
        return Shimmer.fromColors(
          baseColor: scheme.surfaceContainerHigh,
          highlightColor: scheme.surfaceContainerHighest,
          child: Container(
            height: 78,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        );
      },
    );
  }
}