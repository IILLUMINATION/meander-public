import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:canvas_app/core/theme/m3e_theme.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/features/hub/screens/hub_screen.dart';
import 'package:canvas_app/features/guides/guide_catalog.dart';
import 'package:canvas_app/features/guides/models/guide.dart';
import 'package:canvas_app/features/guides/screens/guide_screen.dart';
import 'package:canvas_app/features/guides/widgets/guide_prompt.dart';
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

class _MyLibraryScreenState extends ConsumerState<MyLibraryScreen> {
  int _tabIndex = 0;
  late M3EThemeData _m3eTheme;
  List<LibraryItem> _assets = [];
  List<MusicLibraryItem> _music = [];
  bool _loading = true;
  String? _filterKind;
  final Set<String> _removing = {};

  @override
  void initState() {
    super.initState();
    _filterKind = widget.initialKind;
    _load();
    if (!widget.pickerMode) {
      // Приглашение живёт поверх загрузки: гайд не ждёт библиотеку.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final guide = GuideCatalog.forSection(GuideSection.library);
        if (guide != null) GuidePrompt.maybeShow(context, guide);
      });
    }
  }

  void _openGuide() {
    final guide = GuideCatalog.forSection(GuideSection.library);
    if (guide == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GuideScreen(info: guide)),
    );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trf('Добавлено: {p0}', {'p0': item.title}))),
        );
        if (widget.pickerMode) Navigator.pop(context, dest);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('Ошибка добавления'))));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
          ),
        );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _m3eTheme = m3eThemeFrom(Theme.of(context));
  }

  @override
  Widget build(BuildContext context) {
    final m3e = _m3eTheme;
    final canPop = Navigator.canPop(context);
    return M3ETheme(
      data: m3e,
      child: Scaffold(
        backgroundColor: m3e.colorScheme.surface,
        appBar: M3EAppBar.top(
          automaticallyImplyLeading: false,
          leading: canPop
              ? M3EIconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: tr('Назад'),
                  variant: M3EIconButtonVariant.standard,
                  onPressed: () => Navigator.pop(context),
                )
              : null,
          titleText: tr('Моя библиотека'),
          variant: M3EAppBarVariant.small,
          actions: [
            if (!widget.pickerMode)
              M3EIconButton(
                icon: const Icon(Icons.help_outline_rounded),
                tooltip: tr('Как это работает'),
                variant: M3EIconButtonVariant.standard,
                onPressed: _openGuide,
              ),
            if (!widget.pickerMode)
              M3EIconButton(
                icon: const Icon(Icons.storefront_rounded),
                tooltip: tr('Библиотека ресурсов'),
                variant: M3EIconButtonVariant.tonal,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => HubScreen()),
                ),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: M3EProgressIndicator.circularWavy(size: 48))
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: M3ETabs(
                      selectedIndex: _tabIndex,
                      onTabSelected: (index) =>
                          setState(() => _tabIndex = index),
                      tabs: [
                        M3ETab(
                          label: tr('Ресурсы'),
                          icon: const Icon(Icons.collections_rounded),
                          badgeCount: _assets.isEmpty ? null : _assets.length,
                        ),
                        M3ETab(
                          label: tr('Музыка'),
                          icon: const Icon(Icons.music_note_rounded),
                          badgeCount: _music.isEmpty ? null : _music.length,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: M3ETabsView(
                      selectedIndex: _tabIndex,
                      onTabSelected: (index) =>
                          setState(() => _tabIndex = index),
                      children: [_buildAssetsTab(m3e), _buildMusicTab(m3e)],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildAssetsTab(M3EThemeData m3e) {
    List<LibraryItem> filtered = _assets;
    if (_filterKind != null) {
      // Map picker kinds: image->background, audio->sfx, font->font
      String target = _filterKind!;
      if (target == 'image') target = 'background';
      if (target == 'audio') target = 'sfx';
      filtered = filtered.where((e) => e.kind == target).toList();
    }

    if (filtered.isEmpty) {
      return _emptyState(
        m3e,
        icon: Icons.inventory_2_outlined,
        title: tr('Библиотека пуста'),
        subtitle: tr('Добавляйте ассеты из хаба кнопкой "В библиотеку"'),
      );
    }

    final filters = <Widget>[
      _filterChip(tr('Все'), null),
      _filterChip(tr('Фоны'), 'background'),
      _filterChip(tr('Звуки'), 'sfx'),
      _filterChip(tr('Шрифты'), 'font'),
      _filterChip(tr('Пресеты'), 'button_preset'),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < filters.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  filters[i],
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 300,
                mainAxisExtent: 280,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: filtered.length,
              itemBuilder: (ctx, i) {
                final item = filtered[i];
                return _assetCard(
                  m3e,
                  item,
                  isRemoving: _removing.contains(item.id),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, String? kind) {
    final selected = _filterKind == kind;
    return M3EChip(
      label: label,
      type: M3EChipType.filter,
      selected: selected,
      onPressed: () => setState(() {
        _filterKind = (selected && kind != null) ? null : kind;
      }),
    );
  }

  Widget _assetCard(
    M3EThemeData m3e,
    LibraryItem item, {
    required bool isRemoving,
  }) {
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _LibraryAssetPreview(item: item)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: m3e.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: m3e.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.kind,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: m3e.textTheme.bodySmall?.copyWith(
                    color: m3e.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (item.authorName != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.authorName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: m3e.textTheme.labelSmall?.copyWith(
                      color: m3e.colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    M3EIconButton(
                      icon: Icon(
                        widget.pickerMode
                            ? Icons.check_rounded
                            : Icons.add_rounded,
                      ),
                      variant: M3EIconButtonVariant.tonal,
                      size: M3EIconButtonSize.xs,
                      tooltip: widget.pickerMode
                          ? tr('Выбрать')
                          : tr('В квест'),
                      onPressed: () => _handleAssetTap(item),
                    ),
                    const Spacer(),
                    M3EIconButton(
                      icon: isRemoving
                          ? const M3EProgressIndicator.circularWavy(size: 18)
                          : const Icon(Icons.delete_outline_rounded),
                      variant: M3EIconButtonVariant.standard,
                      size: M3EIconButtonSize.xs,
                      tooltip: tr('Удалить'),
                      onPressed: isRemoving ? null : () => _removeAsset(item),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(
    M3EThemeData m3e, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: M3ECard(
          variant: M3ECardVariant.filled,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 40, color: m3e.colorScheme.primary),
                const SizedBox(height: 12),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: m3e.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: m3e.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: m3e.textTheme.bodyMedium?.copyWith(
                    color: m3e.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMusicTab(M3EThemeData m3e) {
    if (_music.isEmpty) {
      return _emptyState(
        m3e,
        icon: Icons.music_note_outlined,
        title: tr('Нет музыки'),
        subtitle: tr('Добавляйте треки из хаба'),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: M3EList.scrollable(
        itemCount: _music.length,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        gap: 8,
        itemBuilder: (ctx, i) {
          final item = _music[i];
          final isRemoving = _removing.contains(item.id);
          return M3EListItem(
            headline: item.title,
            supportingText: item.performer,
            largeLeading: true,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: item.coverUrl != null
                  ? Image.network(
                      item.coverUrl!,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 56,
                        height: 56,
                        color: m3e.colorScheme.secondaryContainer,
                        child: Icon(
                          Icons.music_note_rounded,
                          color: m3e.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    )
                  : Container(
                      width: 56,
                      height: 56,
                      color: m3e.colorScheme.secondaryContainer,
                      child: Icon(
                        Icons.music_note_rounded,
                        color: m3e.colorScheme.onSecondaryContainer,
                      ),
                    ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.pickerMode && widget.questId != null)
                  M3EButton(
                    label: Text(tr('Выбрать')),
                    style: M3EButtonStyle.tonal,
                    size: M3EButtonSize.xs,
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            tr(
                              'Музыка добавляется через библиотеку: пока только ресурсы',
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                M3EIconButton(
                  icon: isRemoving
                      ? const M3EProgressIndicator.circularWavy(size: 18)
                      : const Icon(Icons.delete_outline_rounded),
                  variant: M3EIconButtonVariant.standard,
                  size: M3EIconButtonSize.xs,
                  tooltip: tr('Удалить'),
                  onPressed: isRemoving ? null : () => _removeMusic(item),
                ),
              ],
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
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('Нет квестов'))));
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
              content: Text(
                dest != null ? tr('Добавлено в квест') : tr('Ошибка'),
              ),
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
    final scheme = M3ETheme.of(context).colorScheme;
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
        errorBuilder: (_, _, _) => Container(
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
