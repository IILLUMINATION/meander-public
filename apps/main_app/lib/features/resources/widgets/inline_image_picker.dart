import 'dart:math' as math;

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_core/models/inline_image.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/widgets/shared/quest_inline_image.dart';

Future<String?> showInlineImagePicker(
  BuildContext context, {
  required String questId,
}) {
  return showAdaptiveSheet<String>(
    context: context,
    maxWidth: 520,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => InlineImagePicker(questId: questId),
  );
}

class InlineImagePicker extends ConsumerStatefulWidget {
  final String questId;

  const InlineImagePicker({super.key, required this.questId});

  @override
  ConsumerState<InlineImagePicker> createState() => _InlineImagePickerState();
}

class _InlineImagePickerState extends ConsumerState<InlineImagePicker> {
  final TextEditingController _searchController = TextEditingController();
  final List<_InlineImageOption> _options = [];
  String _query = '';
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await ref
          .read(resourceServiceProvider(widget.questId))
          .loadResources();
      final root = '${QuestPaths.questRoot(widget.questId)}/';
      final options = <_InlineImageOption>[];
      for (final resource in data.resources) {
        if (resource.type != 'image') continue;
        final relative = resource.path.startsWith(root)
            ? resource.path.substring(root.length)
            : resource.path;
        final path = normalizeInlineImagePath(relative);
        if (path == null) continue;
        options.add(
          _InlineImageOption(
            path: path,
            label: resource.friendlyName.trim().isEmpty
                ? resource.name
                : resource.friendlyName,
          ),
        );
      }
      options.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _options
          ..clear()
          ..addAll(options);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _openResourceLibrary() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    if (result != null && mounted) Navigator.pop(context, result.path);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final availableHeight =
        media.size.height -
        media.viewInsets.bottom -
        media.padding.top -
        media.padding.bottom;
    final height = math.min(520.0, math.max(1.0, availableHeight * 0.62));
    final query = _query.trim().toLowerCase();
    final options = query.isEmpty
        ? _options
        : _options
              .where(
                (option) =>
                    option.label.toLowerCase().contains(query) ||
                    option.path.toLowerCase().contains(query),
              )
              .toList();

    return SizedBox(
      height: height,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Icon(Icons.emoji_emotions_rounded, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr('Сохранённые эмодзи'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('inline-image-picker-add'),
                    tooltip: tr('Вставить изображение из ресурсов'),
                    onPressed: _openResourceLibrary,
                    icon: const Icon(Icons.add_photo_alternate_rounded),
                  ),
                  IconButton(
                    key: const ValueKey('inline-image-picker-close'),
                    tooltip: tr('Закрыть'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: tr('Поиск...'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
          ),
          SliverFillRemaining(
            hasScrollBody: !_loading && !_failed && options.isNotEmpty,
            child: _buildContent(context, options),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, List<_InlineImageOption> options) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) {
      return Center(child: Text(tr('Не удалось загрузить эмодзи')));
    }
    if (options.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _query.isEmpty
                    ? Icons.emoji_emotions_outlined
                    : Icons.search_off_rounded,
                size: 42,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                _query.isEmpty
                    ? tr('Здесь пока пусто')
                    : tr('Ничего не найдено'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_query.isEmpty) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _openResourceLibrary,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(tr('Добавить эмодзи')),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return GridView.builder(
      key: const ValueKey('inline-image-picker-grid'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 104,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.82,
      ),
      itemCount: options.length,
      itemBuilder: (context, index) {
        final option = options[index];
        final scheme = Theme.of(context).colorScheme;
        return Semantics(
          button: true,
          label: option.label,
          child: Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('inline-image-${option.path}'),
              onTap: () => Navigator.pop(context, option.path),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Center(
                      child: QuestInlineImage(
                        questId: widget.questId,
                        path: option.path,
                        style: const TextStyle(fontSize: 48, height: 1),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                    child: Text(
                      option.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _InlineImageOption {
  final String path;
  final String label;

  const _InlineImageOption({required this.path, required this.label});
}
