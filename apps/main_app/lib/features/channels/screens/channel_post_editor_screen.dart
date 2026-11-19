import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/channels/providers/channels_provider.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/services/chat_media_service.dart';
import 'package:canvas_app/features/messages/widgets/chat_attachments.dart';
import 'package:canvas_app/shared/compose/post_editor_screen.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Новый пост в канале: тот же полноэкранный редактор, что у поста
/// сообщества.
///
/// Раньше пост в канале писали в поле, прижатом к низу ленты: кнопка
/// «написать» висела над этим полем, а при открытой клавиатуре отправка
/// уезжала под неё. Полноэкранный редактор одинаков для обоих мест, а канал
/// добавляет только альбом фотографий — их принимает эндпоинт канала.
class ChannelPostEditorScreen extends ConsumerStatefulWidget {
  const ChannelPostEditorScreen({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<ChannelPostEditorScreen> createState() =>
      _ChannelPostEditorScreenState();
}

class _ChannelPostEditorScreenState
    extends ConsumerState<ChannelPostEditorScreen> {
  final List<DmAttachment> _draft = [];
  bool _uploading = false;

  Future<void> _pickPhotos() async {
    if (_uploading || _draft.length >= ChatMediaService.albumLimit) return;
    try {
      final picked = await ChatMediaService.pickAlbum(
        remaining: ChatMediaService.albumLimit - _draft.length,
      );
      if (picked.isEmpty || !mounted) return;
      for (final file in picked) {
        if (await file.length() > ChatMediaService.maxBytes) continue;
        if (!mounted) return;
        setState(() => _uploading = true);
        final attachment = await ChatMediaService.upload(file);
        if (!mounted) return;
        setState(() => _draft.add(attachment));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<bool> _submit(String text) async {
    final error = await ref
        .read(channelProvider(widget.channelId).notifier)
        .publish(text, attachments: List<DmAttachment>.of(_draft));
    if (!mounted) return false;
    if (error == null) return true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PostEditorScreen(
      onSubmit: _submit,
      hintText: tr('Пост для подписчиков…'),
      toolbarHint: tr('Поддерживается Markdown'),
      extraEditorContent: AlbumDraftStrip(
        previews: _draft,
        isUploading: _uploading,
        onRemove: (index) => setState(() => _draft.removeAt(index)),
      ),
      editorToolbar: [
        IconButton(
          key: const ValueKey('channel-post-attach'),
          onPressed: _uploading ? null : _pickPhotos,
          icon: _uploading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                )
              : const Icon(Icons.add_photo_alternate_outlined),
          color: scheme.primary,
          tooltip: tr('Прикрепить фото'),
        ),
      ],
      previewBuilder: (text) => _PostPreview(text: text, attachments: _draft),
    );
  }
}

class _PostPreview extends StatelessWidget {
  const _PostPreview({required this.text, required this.attachments});

  final String text;
  final List<DmAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = text.trim();
    if (body.isEmpty && attachments.isEmpty) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (body.isNotEmpty)
          AppMarkdownBlock(
            data: body,
            config: AppMarkdown.getConfig(context),
            selectable: false,
          ),
        if (attachments.isNotEmpty) ...[
          if (body.isNotEmpty) const SizedBox(height: 12),
          ChatAttachmentGrid(attachments: attachments, width: 320),
        ],
      ],
    );
  }
}
