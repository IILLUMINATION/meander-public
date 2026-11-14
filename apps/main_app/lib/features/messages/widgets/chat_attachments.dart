import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/shared/entity_links/meander_entity.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Текст реплики: markdown для обычных сообщений, ссылки на сущности — если
/// автор написал `@профиль` или `quest:<id>`.
///
/// Разбор на карточки-ссылки и markdown — разные парсеры, и смешивать их в
/// одном абзаце нечем: если в тексте есть сущности Меандра, показываем их
/// (там же inline-ссылки), иначе — markdown. Так новость с `**жирным**` и
/// списком читается как документ, а `@ник` остаётся кликабельным.
class ChatMessageText extends StatelessWidget {
  const ChatMessageText({
    super.key,
    required this.text,
    this.style,
    this.maxLines,
  });

  final String text;
  final TextStyle? style;

  /// Предел строк для превью в ленте (последнее сообщение треда).
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final hasEntities = splitMeanderEntities(
      text,
    ).any((segment) => segment.isEntity);
    if (hasEntities || maxLines != null) {
      return MeanderEntityLinkText(data: text, style: style);
    }
    return DefaultTextStyle.merge(
      style: style,
      child: AppMarkdownBlock(
        data: text,
        config: AppMarkdown.getConfig(context),
        selectable: false,
      ),
    );
  }
}

/// Сетка фото в пузыре: одно фото — крупный кадр, несколько — плитка.
class ChatAttachmentGrid extends StatelessWidget {
  const ChatAttachmentGrid({
    super.key,
    required this.attachments,
    this.mine = false,
    this.width = 260,
  });

  final List<DmAttachment> attachments;
  final bool mine;

  /// Ширина плитки: пузырь ограничен долей экрана, иначе крупный кадр
  /// растягивал бы его на всю ленту.
  final double width;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    if (attachments.length == 1) {
      final only = attachments.first;
      return _Tile(
        attachment: only,
        width: width,
        height: (width / (only.aspectRatio ?? 1.3)).clamp(120.0, 340.0),
        radius: 14,
      );
    }

    // Плитка 2×2 на четыре кадра и «2×N» на остальное: ровная сетка читается
    // быстрее, чем лента разной высоты.
    final cell = (width - 6) / 2;
    return SizedBox(
      width: width,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final attachment in attachments)
            _Tile(
              attachment: attachment,
              width: cell,
              height: cell,
              radius: 12,
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.attachment,
    required this.width,
    required this.height,
    required this.radius,
  });

  final DmAttachment attachment;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (width * dpr).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: () => _openViewer(context),
        child: Container(
          width: width,
          height: height,
          color: scheme.surfaceContainerHighest,
          child: CachedNetworkImage(
            imageUrl: attachment.url,
            fit: BoxFit.cover,
            memCacheWidth: cacheWidth,
            placeholder: (context, _) => Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            errorWidget: (context, _, _) => Icon(
              Icons.broken_image_outlined,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  void _openViewer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PhotoViewer(url: attachment.url),
      ),
    );
  }
}

/// Полноэкранный просмотр: чёрный фон, пинч-зум, «назад» по тапу.
class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        child: SafeArea(
          child: Center(
            child: InteractiveViewer(
              maxScale: 4,
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                placeholder: (context, _) => const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
                errorWidget: (context, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Лента выбранных, но ещё не отправленных фото: человек видит, что уйдёт.
class AlbumDraftStrip extends StatelessWidget {
  const AlbumDraftStrip({
    super.key,
    required this.previews,
    required this.isUploading,
    required this.onRemove,
  });

  final List<DmAttachment> previews;

  /// Пока идёт загрузка, показать место под ещё один кадр.
  final bool isUploading;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    if (previews.isEmpty && !isUploading) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 68,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (var i = 0; i < previews.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CachedNetworkImage(
                      imageUrl: previews[i].url,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      memCacheWidth: 160,
                    ),
                  ),
                  Positioned(
                    right: -6,
                    top: -6,
                    child: IconButton(
                      key: ValueKey('album-remove-$i'),
                      onPressed: () => onRemove(i),
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.surfaceContainerHighest,
                        minimumSize: const Size(22, 22),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (isUploading)
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }
}

/// Подпись для пустой реплики из одних фото — в ленте вместо текста.
String chatAttachmentPreview(List<DmAttachment> attachments) {
  if (attachments.isEmpty) return '';
  if (attachments.length == 1) return tr('Фото');
  return trf('{p0} фото', {'p0': attachments.length});
}
