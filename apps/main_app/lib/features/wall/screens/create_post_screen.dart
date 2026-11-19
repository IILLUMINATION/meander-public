import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/post_media_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/wall/providers/wall_paginated_provider.dart';
import 'package:canvas_app/models/wall_post_model.dart';
import 'package:canvas_app/providers/wall_provider.dart';
import 'package:canvas_app/shared/compose/post_editor_screen.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Новый пост или правка поста на стене сообщества.
///
/// Вёрстка — общий [PostEditorScreen]: тот же экран пишет пост в канал, и
/// поэтому «написать пост» выглядит одинаково везде. Здесь остаётся только
/// то, что принадлежит стене: адрес `api/author-walls/:id/posts`, вставка
/// картинки в Markdown и старые изображения при редактировании.
class CreatePostScreen extends ConsumerStatefulWidget {
  final WallPost? postToEdit;

  const CreatePostScreen({super.key, this.postToEdit});

  @override
  ConsumerState<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends ConsumerState<CreatePostScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.postToEdit?.content ?? '',
  );
  final List<String> _existingImages = [];
  bool _isUploadingImage = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refresh);
    final post = widget.postToEdit;
    if (post != null) _existingImages.addAll(post.mediaUrls);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadImage() async {
    setState(() => _isUploadingImage = true);
    try {
      final url = await PostMediaUpload.pickAndUpload();
      if (url != null) insertImageAtCursor(_controller, url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Ошибка загрузки фото: {p0}', {'p0': friendlyError(e)}),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Future<bool> _submit(String content) async {
    final post = widget.postToEdit;
    if (content.isEmpty && _existingImages.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final authorId = prefs.getString('user_id');
      if (authorId == null) throw Exception('Not authorized');

      if (post != null) {
        await ref
            .read(wallNotifierProvider.notifier)
            .editPost(post.authorId, post.id, content, _existingImages);
        final updatedPost = post.copyWith(
          content: content,
          mediaUrls: _existingImages,
        );
        ref
            .read(wallPaginatedProvider(post.authorId).notifier)
            .updatePostLocally(updatedPost);
      } else {
        final api = ref.read(apiServiceProvider);
        await api.post(
          'api/author-walls/$authorId/posts',
          body: {
            'content': content,
            'media_urls': [], // Новые посты хранят фото только в Markdown
          },
        );
        ref.read(wallPaginatedProvider(authorId).notifier).loadPosts();
      }
      return true;
    } catch (e) {
      if (mounted) {
        final scheme = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: scheme.errorContainer,
          ),
        );
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PostEditorScreen(
      title: widget.postToEdit != null
          ? tr('Редактирование')
          : tr('Новый пост'),
      controller: _controller,
      onSubmit: _submit,
      editorToolbar: [
        IconButton(
          onPressed: _isUploadingImage ? null : _pickAndUploadImage,
          icon: _isUploadingImage
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                )
              : const Icon(Icons.image_outlined),
          color: scheme.primary,
          tooltip: tr('Вставить картинку'),
        ),
      ],
      toolbarHint: tr('Поддерживается Markdown'),
      extraEditorContent: _existingImages.isEmpty
          ? null
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final url in _existingImages)
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          url,
                          width: 100,
                          height: 100,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: InkWell(
                          onTap: () =>
                              setState(() => _existingImages.remove(url)),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
      previewBuilder: (text) =>
          _WallPreview(text: text, images: _existingImages),
    );
  }
}

class _WallPreview extends StatelessWidget {
  const _WallPreview({required this.text, required this.images});

  final String text;
  final List<String> images;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = text.trim();
    if (body.isEmpty && images.isEmpty) {
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
          MeanderEntityMarkdown(
            data: body,
            config: AppMarkdown.getConfig(context),
          ),
        if (images.isNotEmpty) ...[
          if (body.isNotEmpty) const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final url in images)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    url,
                    width: 100,
                    height: 100,
                    fit: BoxFit.cover,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
