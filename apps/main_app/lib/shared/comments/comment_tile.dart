import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:flutter/material.dart';

import 'comment_view.dart';

/// Карточка комментария: одна на сообщество, каналы и всё, что появится
/// дальше.
///
/// Действия не зашиты внутрь: экран передаёт только те, которые его бэкенд
/// умеет. Нет `onLike` — нет сердечка; нет ни одного действия — нет кнопки
/// меню. Поэтому каналу не нужен второй список комментариев, а сообщество не
/// теряет лайки и ответы.
class CommentTile extends StatelessWidget {
  const CommentTile({
    super.key,
    required this.comment,
    this.depth = 0,
    this.onLike,
    this.onReply,
    this.onEdit,
    this.onDelete,
    this.onReport,
    this.onOpenAuthor,
  });

  final CommentView comment;

  /// Глубина в дереве ответов: 0 — корневой, дальше отступ и вертикальная
  /// линия слева.
  final int depth;

  final VoidCallback? onLike;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onReport;
  final VoidCallback? onOpenAuthor;

  bool get _hasMenu =>
      onReply != null || onEdit != null || onDelete != null || onReport != null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paddingLeft = 12.0 + (depth * 24.0);

    return Container(
      margin: EdgeInsets.only(left: depth > 0 ? paddingLeft : 0),
      decoration: depth > 0
          ? BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                  width: 2,
                ),
              ),
            )
          : null,
      child: Material(
        color: depth > 0
            ? scheme.surfaceContainerHigh.withValues(alpha: 0.6)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topRight: const Radius.circular(18),
          bottomRight: const Radius.circular(18),
          topLeft: Radius.circular(depth > 0 ? 4 : 18),
          bottomLeft: Radius.circular(depth > 0 ? 4 : 18),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: onOpenAuthor,
                borderRadius: BorderRadius.circular(100),
                child: CosmeticAvatar(
                  frame: cosmeticById(comment.cosmetics.avatarFrame),
                  radius: 18,
                  avatarUrl: comment.avatarUrl,
                  placeholderColor: scheme.primaryContainer,
                  fallback: CommentAvatarFallback(
                    name: comment.authorName,
                    color: scheme.primaryContainer,
                    textColor: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: CosmeticNameText(
                            name: comment.authorName,
                            def: cosmeticById(comment.nameStyle),
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatRelativeTime(comment.createdAt),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    MeanderEntityMarkdown(
                      data: comment.body,
                      config: AppMarkdown.getConfig(context),
                    ),
                    if (onLike != null || comment.likesCount > 0) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _CommentLikeButton(
                          liked: comment.likedByMe,
                          count: comment.likesCount,
                          onTap: onLike,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (_hasMenu)
                SizedBox(
                  width: 32,
                  height: 32,
                  child: Builder(
                    builder: (anchor) => IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      icon: Icon(
                        Icons.more_horiz_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
                      tooltip: tr('Действия'),
                      onPressed: () => _openMenu(anchor),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openMenu(BuildContext anchor) async {
    final scheme = Theme.of(anchor).colorScheme;

    PopupMenuItem<String> item(
      String value,
      IconData icon,
      String label,
      Color color,
    ) {
      return PopupMenuItem(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: color)),
          ],
        ),
      );
    }

    final result = await showMenu<String>(
      context: anchor,
      position: const RelativeRect.fromLTRB(1000, 200, 0, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: [
        if (onReply != null)
          item('reply', Icons.reply_rounded, tr('Ответить'), scheme.onSurface),
        if (onEdit != null)
          item('edit', Icons.edit_rounded, tr('Редактировать'), scheme.primary),
        if (onDelete != null)
          item(
            'delete',
            Icons.delete_outline_rounded,
            tr('Удалить'),
            scheme.error,
          ),
        if (onReport != null)
          item('report', Icons.flag_outlined, tr('Пожаловаться'), scheme.error),
      ],
    );

    switch (result) {
      case 'reply':
        onReply?.call();
      case 'edit':
        onEdit?.call();
      case 'delete':
        onDelete?.call();
      case 'report':
        onReport?.call();
    }
  }
}

class _CommentLikeButton extends StatefulWidget {
  const _CommentLikeButton({
    required this.liked,
    required this.count,
    required this.onTap,
  });

  final bool liked;
  final int count;
  final VoidCallback? onTap;

  @override
  State<_CommentLikeButton> createState() => _CommentLikeButtonState();
}

class _CommentLikeButtonState extends State<_CommentLikeButton> {
  bool _anim = false;

  Future<void> _tap() async {
    final onTap = widget.onTap;
    if (onTap == null) return;
    setState(() => _anim = true);
    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _anim = false);
    });
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const likedColor = Color(0xFFE91E63);
    final color = widget.liked ? likedColor : scheme.onSurfaceVariant;

    return InkWell(
      onTap: widget.onTap == null ? null : _tap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            AnimatedScale(
              scale: _anim ? 1.35 : 1.0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              child: Icon(
                widget.liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                size: 16,
                color: color,
              ),
            ),
            if (widget.count > 0) ...[
              const SizedBox(width: 4),
              Text(
                formatCompactCount(widget.count),
                style: TextStyle(
                  color: color,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Аватар без картинки: первая буква имени на цветной плашке.
class CommentAvatarFallback extends StatelessWidget {
  const CommentAvatarFallback({
    super.key,
    required this.name,
    required this.color,
    required this.textColor,
  });

  final String name;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        letter,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w800,
          fontSize: 15,
        ),
      ),
    );
  }
}
