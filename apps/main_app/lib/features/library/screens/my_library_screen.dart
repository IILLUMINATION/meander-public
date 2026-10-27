import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/features/hub/screens/hub_screen.dart';
import 'package:canvas_app/features/library/services/my_library_service.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

class MyLibraryScreen extends ConsumerStatefulWidget {
  final String? questId;
  final bool pickerMode;
  final String? initialKind; // for picker filtering
  const MyLibraryScreen({
    super.key,
    this.questId,
    this.pickerMode = false,
    this.initialKind,
  });

  @override
  ConsumerState<MyLibraryScreen> createState() => _MyLibraryScreenState();
}

class _MyLibraryScreenState extends ConsumerState<MyLibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  List<LibraryItem> _assets = [];
  List<MusicLibraryItem> _music = [];
  bool _loading = true;
  String? _filterKind;
  final Set<String> _removing = {};

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _filterKind = widget.initialKind;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final assets = await MyLibraryService.loadAssets();
    final music = await MyLibraryService.loadMusic();
    if (!mounted) return;
    // Filter by initialKind if pickerMode
    setState(() {
      _assets = assets;
      _music = music;
      _loading = false;
    });
  }

  Future<void> _removeAsset(LibraryItem item) async {
    setState(() => _removing.add(item.id));
    await MyLibraryService.removeAsset(item.id);
    await _load();
    if (mounted) setState(() => _removing.remove(item.id));
  }

  Future<void> _removeMusic(MusicLibraryItem item) async {
    setState(() => _removing.add(item.id));
    await MyLibraryService.removeMusic(item.id);
    await _load();
    if (mounted) setState(() => _removing.remove(item.id));
  }

  Future<void> _addToQuest(LibraryItem item) async {
    final questId = widget.questId;
    if (questId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Выберите квест через редактор'))),
      );
      return;
    }
    try {
      final dest = await MyLibraryService.copyAssetToQuest(item, questId);
      if (!mounted) return;
      if (dest != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(trf('Добавлено: {p0}', {'p0': item.title}))));
        if (widget.pickerMode) Navigator.pop(context, dest);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Ошибка добавления'))));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickerMode ? tr('Моя библиотека') : tr('Моя библиотека')),
        actions: [
          if (!widget.pickerMode)
            IconButton(
              icon: const Icon(Icons.storefront_rounded),
              tooltip: tr('Библиотека ресурсов'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => HubScreen()),
              ),
            ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: [
            Tab(icon: Icon(Icons.collections_rounded), text: tr('Ресурсы')),
            Tab(icon: Icon(Icons.music_note_rounded), text: tr('Музыка')),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabCtrl,
              children: [_buildAssetsTab(scheme), _buildMusicTab(scheme)],
            ),
    );
  }

  Widget _buildAssetsTab(ColorScheme scheme) {
    List<LibraryItem> filtered = _assets;
    if (_filterKind != null) {
      // Map picker kinds: image->background, audio->sfx, font->font
      String target = _filterKind!;
      if (target == 'image') target = 'background';
      if (target == 'audio') target = 'sfx';
      filtered = filtered.where((e) => e.kind == target).toList();
    } else if (widget.pickerMode && widget.initialKind != null) {
      // already handled
    }

    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.inventory_2_outlined,
                size: 48,
                color: scheme.onSurfaceVariant.withOpacity(0.5),
              ),
              const SizedBox(height: 12),
              Text(
                tr('Библиотека пуста'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                tr('Добавляйте ассеты из хаба кнопкой "В библиотеку"'),
                style: TextStyle(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                FilterChip(
                  label: Text(tr('Все')),
                  selected: _filterKind == null,
                  onSelected: (_) => setState(() => _filterKind = null),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(tr('Фоны')),
                  selected: _filterKind == 'background',
                  onSelected: (_) => setState(
                    () => _filterKind = _filterKind == 'background'
                        ? null
                        : 'background',
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(tr('Звуки')),
                  selected: _filterKind == 'sfx',
                  onSelected: (_) => setState(
                    () => _filterKind = _filterKind == 'sfx' ? null : 'sfx',
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(tr('Шрифты')),
                  selected: _filterKind == 'font',
                  onSelected: (_) => setState(
                    () => _filterKind = _filterKind == 'font' ? null : 'font',
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(tr('Пресеты')),
                  selected: _filterKind == 'button_preset',
                  onSelected: (_) => setState(
                    () => _filterKind = _filterKind == 'button_preset'
                        ? null
                        : 'button_preset',
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 280,
                childAspectRatio: 0.85,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: filtered.length,
              itemBuilder: (ctx, i) {
                final item = filtered[i];
                final isRemoving = _removing.contains(item.id);
                return Material(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _LibraryAssetPreview(item: item)),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              item.kind,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            if (item.authorName != null)
                              Text(
                                item.authorName!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.primary,
                                ),
                              ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.tonal(
                                    onPressed: () => _handleAssetTap(item),
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 6,
                                      ),
                                      minimumSize: const Size(0, 32),
                                    ),
                                    child: Text(
                                      widget.pickerMode ? tr('Выбрать') : tr('В квест'),
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                IconButton(
                                  onPressed: isRemoving
                                      ? null
                                      : () => _removeAsset(item),
                                  icon: isRemoving
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 18,
                                        ),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMusicTab(ColorScheme scheme) {
    if (_music.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.music_note_outlined,
                size: 48,
                color: scheme.onSurfaceVariant.withOpacity(0.5),
              ),
              const SizedBox(height: 12),
              Text(
                tr('Нет музыки'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                tr('Добавляйте треки из хаба'),
                style: TextStyle(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        itemCount: _music.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) {
          final item = _music[i];
          final isRemoving = _removing.contains(item.id);
          return Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            child: ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: item.coverUrl != null
                    ? Image.network(
                        item.coverUrl!,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 48,
                          height: 48,
                          color: scheme.secondaryContainer,
                          child: const Icon(Icons.music_note_rounded),
                        ),
                      )
                    : Container(
                        width: 48,
                        height: 48,
                        color: scheme.secondaryContainer,
                        child: const Icon(Icons.music_note_rounded),
                      ),
              ),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              subtitle: Text(
                item.performer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.pickerMode && widget.questId != null)
                    FilledButton.tonal(
                      onPressed: () async {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr('Музыка добавляется через библиотеку: пока только ресурсы'),
                            ),
                          ),
                        );
                      },
                      child: Text(tr('Выбрать')),
                    ),
                  IconButton(
                    onPressed: isRemoving ? null : () => _removeMusic(item),
                    icon: isRemoving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_outline_rounded, size: 18),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleAssetTap(LibraryItem item) async {
    if (widget.pickerMode && widget.questId != null) {
      await _addToQuest(item);
    } else if (widget.pickerMode) {
      // No questId, just return MarketAsset?
      Navigator.pop(context, item.toMarketAsset());
    } else {
      // Standalone: pick quest to add
      final quests = await ref.read(questsProvider.future);
      if (quests.isEmpty) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(tr('Нет квестов'))));
        return;
      }
      if (!mounted) return;
      final selected = await showAdaptiveSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: quests
                .map(
                  (q) => ListTile(
                    title: Text(q.title),
                    subtitle: Text(q.id.substring(0, 8)),
                    onTap: () => Navigator.pop(ctx, q.id),
                  ),
                )
                .toList(),
          ),
        ),
      );
      if (selected != null) {
        final dest = await MyLibraryService.copyAssetToQuest(item, selected);
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(dest != null ? tr('Добавлено в квест') : tr('Ошибка')),
            ),
          );
      }
    }
  }
}

class _LibraryAssetPreview extends StatelessWidget {
  final LibraryItem item;
  const _LibraryAssetPreview({required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (item.kind == 'font') {
      return Container(
        color: scheme.secondaryContainer,
        child: const Center(child: Icon(Icons.text_fields_rounded, size: 28)),
      );
    }
    if (item.kind == 'button_preset') {
      // Try to show preset preview if local zip exists? fallback to icon
      return Container(
        color: scheme.secondaryContainer,
        child: const Center(child: Icon(Icons.smart_button_rounded, size: 28)),
      );
    }
    final preview = item.coverUrl;
    if (preview != null) {
      return Image.network(
        preview,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: scheme.secondaryContainer,
          child: const Center(child: Icon(Icons.image_rounded, size: 28)),
        ),
      );
    }
    // Try local file preview for images/backgrounds
    if (item.localPath != null &&
        (item.kind == 'background' || item.kind == 'image')) {
      return FutureBuilder<String>(
        future: FileStorage.getFilePath(item.localPath!),
        builder: (ctx, snap) {
          if (snap.hasData) {
            final file = File(snap.data!);
            if (file.existsSync()) return Image.file(file, fit: BoxFit.cover);
          }
          return Container(
            color: scheme.secondaryContainer,
            child: const Center(child: Icon(Icons.image_rounded, size: 28)),
          );
        },
      );
    }
    IconData icon;
    switch (item.kind) {
      case 'background':
        icon = Icons.wallpaper_rounded;
        break;
      case 'sfx':
        icon = Icons.music_note_rounded;
        break;
      case 'font':
        icon = Icons.text_fields_rounded;
        break;
      default:
        icon = Icons.widgets_rounded;
    }
    return Container(
      color: scheme.secondaryContainer,
      child: Center(
        child: Icon(icon, size: 28, color: scheme.onSecondaryContainer),
      ),
    );
  }
}
