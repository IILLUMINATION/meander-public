import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:canvas_app/features/asset_market/providers/asset_provider.dart';
import 'package:canvas_app/features/asset_market/screens/asset_upload_screen.dart';
import 'package:canvas_app/features/hub/screens/asset_details_screen.dart';
import 'package:canvas_app/features/hub/screens/music_details_screen.dart';
import 'package:canvas_app/features/hub/screens/preset_details_screen.dart';
import 'package:canvas_app/features/hub/widgets/background_preview.dart';
import 'package:canvas_app/features/hub/widgets/preset_market.dart';
import 'package:canvas_app/features/library/screens/my_library_screen.dart';
import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:canvas_app/features/market/widgets/market_widgets.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/music_library/providers/music_provider.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/widgets/catalog_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:mnd_core/mnd_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

// ============================================================================
//  ХАБ — ресурсы для квестов.
//
//  Экран повторяет структуру и визуальный язык маркета квестов
//  (market_screen.dart): левый рельс, поиск в SliverAppBar, секции,
//  сетка карточек и правая панель. Отличается только «начинкой»:
//  вместо квестов здесь ресурсы и пресеты.
//
//  Как и в маркете квестов, здесь лежит ТОЛЬКО серверный контент
//  (GET /assets, GET /music). Локальные пресеты из config.json квестов
//  на устройстве — отдельный экран, LocalPresetsScreen: у них нет id
//  публикации, поэтому в каталоге они были бы недостижимы для
//  модерации и репортов.
// ============================================================================

/// Категория левого рельса Хаба.
///
/// [value] == null — «Главная» (все подборки сразу).
class _HubCategory {
  final String? value;
  final String label;
  final IconData icon;

  const _HubCategory(this.value, this.label, this.icon);
}

// Функция, а не const-список: метки строятся под текущий язык, иначе
// переключение языка не перекрасило бы рубрику и рельс.
List<_HubCategory> _hubCategories() => [
  _HubCategory(null, tr('Главная'), Icons.home_rounded),
  _HubCategory('button_preset', tr('Пресеты маркета'), Icons.widgets_rounded),
  _HubCategory('music', tr('Музыка'), Icons.music_note_rounded),
  _HubCategory('sfx', tr('Звуки'), Icons.graphic_eq_rounded),
  _HubCategory('background', tr('Фоны'), Icons.wallpaper_rounded),
  _HubCategory('font', tr('Шрифты'), Icons.text_fields_rounded),
];

/// Типы ресурсов, которые можно отфильтровать в маркете ресурсов.
List<_HubCategory> _hubAssetKinds() => [
  _HubCategory('button_preset', tr('Пресеты кнопок'), Icons.widgets_rounded),
  _HubCategory('background', tr('Фоны'), Icons.wallpaper_rounded),
  _HubCategory('sfx', tr('Звуки'), Icons.graphic_eq_rounded),
  _HubCategory('font', tr('Шрифты'), Icons.text_fields_rounded),
];

/// Короткая подпись типа ресурса для бейджа на карточке
/// (в карточке маркета на этом месте короткая категория квеста).
String _shortKindLabel(String kind) {
  switch (kind) {
    case 'button_preset':
      return tr('ПРЕСЕТ');
    case 'background':
      return tr('ФОН');
    case 'sfx':
      return tr('ЗВУК');
    case 'font':
      return tr('ШРИФТ');
    case 'image':
      return tr('КАРТИНКА');
    default:
      return kind.toUpperCase();
  }
}

const double _kStripHeight = 215;
const double _kStripCardWidth = 170;

final hubCategoryProvider = StateProvider<String?>((_) => null);

class HubScreen extends ConsumerStatefulWidget {
  const HubScreen({super.key});

  @override
  ConsumerState<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends ConsumerState<HubScreen>
    with TickerProviderStateMixin {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollController = ScrollController();
  final _player = AudioPlayer();

  String? _playingId;
  MusicTrack? _playingTrack;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted)
        setState(() {
          _playingId = null;
          _playingTrack = null;
          _position = Duration.zero;
        });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  //  Состояние фильтров
  // ---------------------------------------------------------------------------

  void _refreshAll() {
    ref.invalidate(musicTracksProvider);
    ref.invalidate(assetListProvider);
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _searchFocus.unfocus();
    ref.read(musicSearchProvider.notifier).state = '';
    ref.read(assetSearchProvider.notifier).state = '';
  }

  void _clearFilters() {
    _clearSearch();
    ref.read(hubCategoryProvider.notifier).state = null;
  }

  void _openFiltersSheet() {
    showAdaptiveSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _HubFiltersSheet(),
    );
  }

  // ---------------------------------------------------------------------------
  //  Навигация и превью
  // ---------------------------------------------------------------------------

  void _openAssetDetails(MarketAsset a) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AssetDetailsScreen(asset: a)),
    );
  }

  void _openMusicDetails(MusicTrack t) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MusicDetailsScreen(track: t)),
    );
  }

  Future<void> _previewMusic(MusicTrack t) async {
    try {
      if (_playingId == t.id) {
        await _player.stop();
        if (!mounted) return;
        setState(() {
          _playingId = null;
          _playingTrack = null;
        });
        return;
      }
      await _player.stop();
      await _player.play(UrlSource(t.downloadUrl));
      if (!mounted) return;
      setState(() {
        _playingId = t.id;
        _playingTrack = t;
        _position = Duration.zero;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
    }
  }

  Future<void> _toggleMusic(MusicTrack t) => _previewMusic(t);

  Future<void> _stopPlayback() async {
    await _player.stop();
    if (!mounted) return;
    setState(() {
      _playingId = null;
      _playingTrack = null;
      _position = Duration.zero;
    });
  }

  Future<void> _previewAsset(MarketAsset a) async {
    if (a.kind == 'background' || a.kind == 'image') {
      await BackgroundPreviewService.openPreview(context, ref, a);
      return;
    }
    if (a.kind == 'sfx') {
      try {
        if (_playingId == a.id) {
          await _player.stop();
          if (!mounted) return;
          setState(() => _playingId = null);
          return;
        }
        await _player.stop();
        await _player.play(UrlSource(a.downloadUrl));
        if (!mounted) return;
        setState(() {
          _playingId = a.id;
          _playingTrack = null;
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
      }
      return;
    }
    _showAssetDialog(a);
  }

  void _showAssetDialog(MarketAsset a) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(a.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (a.coverUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    a.coverUrl!,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.image, size: 48),
                  ),
                ),
              const SizedBox(height: 8),
              Text(trf('Тип: {p0}', {'p0': assetKindLabel(a.kind)})),
              Text(trf('Лицензия: {p0}', {'p0': licenseLabel(a.license)})),
              if (a.description != null && a.description!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(a.description!),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Закрыть')),
          ),
        ],
      ),
    );
  }

  void _openPreset(QuestPresetEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PresetDetailsScreen(entry: entry)),
    );
  }

  // ---------------------------------------------------------------------------
  //  Загрузка ресурсов / публикация пресетов
  // ---------------------------------------------------------------------------

  Future<void> _upload() async {
    if (_isUploading) return;

    // Гость, зашедший на «Хаб», не может опубликовать ресурс: раньше он
    // открывал форму загрузки и узнавал об отказе только на «Опубликовать».
    // Проверка на месте, а не в initState: вкладка живёт в IndexedStack и
    // переживает вход в аккаунт.
    if (!await ensurePublishAccount(context)) return;
    if (!mounted) return;
    setState(() => _isUploading = true);
    try {
      final kind = await showAdaptiveSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
        builder: (sheetContext) => _HubUploadKindSheet(),
      );
      if (kind == null || !mounted) return;
      if (kind == 'button_preset') {
        await showPresetMarketSheet(context, onOpen: _openPreset);
        return;
      }
      final res = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => AssetUploadScreen(kind: kind)),
      );
      if (res == true) {
        ref.invalidate(musicTracksProvider);
        ref.invalidate(assetListProvider);
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final searchQuery = ref.watch(assetSearchProvider).trim();
    final selectedCategory = ref.watch(hubCategoryProvider);
    final isFiltering = searchQuery.isNotEmpty || selectedCategory != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isMedium = width >= kCatalogMediumBreakpoint;
        final isExpanded = width >= kCatalogExpandedBreakpoint;

        final mainColumnWidth = isExpanded
            ? width - kCatalogRailWidth - kCatalogAsideWidth
            : width - (isMedium ? kCatalogRailWidth : 0);

        return PopScope(
          canPop: !isFiltering,
          onPopInvoked: (didPop) {
            if (didPop) return;
            _clearFilters();
          },
          child: Scaffold(
            backgroundColor: scheme.surfaceContainerLowest,
            body: SafeArea(
              bottom: false,
              child: RefreshIndicator(
                onRefresh: () async => _refreshAll(),
                child: Row(
                  children: [
                    if (isMedium)
                      SizedBox(
                        width: kCatalogRailWidth,
                        child: _HubDesktopRail(
                          onCategorySelected: (key) =>
                              ref.read(hubCategoryProvider.notifier).state =
                                  key,
                        ),
                      ),
                    Expanded(
                      child: _buildMainColumn(
                        width: mainColumnWidth,
                        isFiltering: isFiltering,
                        selectedCategory: selectedCategory,
                      ),
                    ),
                    if (isExpanded) SizedBox(width: kCatalogAsideWidth, child: _HubRightAside()),
                  ],
                ),
              ),
            ),
            floatingActionButton: Padding(
              padding: EdgeInsets.only(bottom: _playingTrack != null ? 84 : 0),
              child: FloatingActionButton.extended(
                heroTag: null,
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                onPressed: _upload,
                icon: _isUploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded),
                label: Text(tr('Загрузить ресурс')),
              ),
            ),
            bottomSheet: _playingTrack != null
                ? _HubMiniPlayer(
                    track: _playingTrack!,
                    position: _position,
                    duration: _duration,
                    isPlaying: _playingId != null,
                    onPlayPause: () => _toggleMusic(_playingTrack!),
                    onStop: _stopPlayback,
                    onSeek: (d) => _player.seek(d),
                  )
                : null,
          ),
        );
      },
    );
  }

  Widget _buildMainColumn({
    required double width,
    required bool isFiltering,
    required String? selectedCategory,
  }) {
    final isCompact = width < kCatalogCompactBreakpoint;
    final searchQuery = ref.watch(assetSearchProvider).trim();
    final musicAsync = ref.watch(filteredMusicTracksProvider);
    final assetAsync = ref.watch(filteredAssetProvider);

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        _buildAppBar(),
        if (!isFiltering) ...[
          if (isCompact) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            const SliverToBoxAdapter(child: _HubCategoryChipsRow()),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 16)),

          // «Хаб» — слово, из которого непонятно, что тут лежит: пять
          // полосок с картинками. Одна строка на месте объясняет раздел
          // лучше, чем ссылка на сторонние видео в настройках.
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SectionHintBanner(hintId: SectionHints.hub),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),

          // Музыка
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Музыка'),
              icon: Icons.music_note_rounded,
              subtitle: tr('Саундтрек для вашей истории'),
              onSeeAll: () =>
                  ref.read(hubCategoryProvider.notifier).state = 'music',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(child: _buildMusicStrip(musicAsync)),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Звуки
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Звуки'),
              icon: Icons.graphic_eq_rounded,
              subtitle: tr('Интерфейсные и игровые эффекты'),
              onSeeAll: () =>
                  ref.read(hubCategoryProvider.notifier).state = 'sfx',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(child: _buildAssetStrip(assetAsync, 'sfx')),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Фоны
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Фоны'),
              icon: Icons.wallpaper_rounded,
              subtitle: tr('Атмосфера для сцен и диалогов'),
              onSeeAll: () =>
                  ref.read(hubCategoryProvider.notifier).state = 'background',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(child: _buildAssetStrip(assetAsync, 'background')),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Пресеты из маркета
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Пресеты кнопок'),
              icon: Icons.widgets_rounded,
              subtitle: tr('Кнопки, рамки и стили от авторов'),
              onSeeAll: () => ref.read(hubCategoryProvider.notifier).state =
                  'button_preset',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _buildAssetStrip(assetAsync, 'button_preset'),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Шрифты
          SliverToBoxAdapter(
            child: CatalogSectionHeader(
              title: tr('Шрифты'),
              icon: Icons.text_fields_rounded,
              subtitle: tr('Подписи и заголовки квестов'),
              onSeeAll: () =>
                  ref.read(hubCategoryProvider.notifier).state = 'font',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(child: _buildAssetStrip(assetAsync, 'font')),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],

        // Заголовок основной сетки
        SliverToBoxAdapter(
          child: CatalogSectionHeader(
            title: isFiltering
                ? _categoryTitle(selectedCategory, searchQuery.isNotEmpty)
                : tr('Библиотека ресурсов'),
            icon: isFiltering
                ? Icons.search_rounded
                : Icons.new_releases_outlined,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        _buildGrid(width, selectedCategory, musicAsync, assetAsync),
        const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
      ],
    );
  }

  SliverAppBar _buildAppBar() {
    final hasFilter = ref.watch(hubCategoryProvider) != null;
    return SliverAppBar(
      backgroundColor: Colors.transparent,
      floating: true,
      pinned: false,
      snap: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      toolbarHeight: 76,
      titleSpacing: 16,
      title: CatalogSearchField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        hintText: tr('Найти ресурс, пресет, автора…'),
        onChanged: (value) {
          ref.read(assetSearchProvider.notifier).state = value;
          ref.read(musicSearchProvider.notifier).state = value;
        },
        onClear: _clearSearch,
        onFilterTap: _openFiltersSheet,
      ),
      actions: [
        if (hasFilter)
          IconButton(
            icon: const Icon(Icons.filter_alt_off_rounded),
            tooltip: tr('Сбросить фильтры'),
            onPressed: _clearFilters,
          ),
        IconButton.filledTonal(
          tooltip: tr('Моя библиотека'),
          icon: const Icon(Icons.bookmarks_rounded),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => MyLibraryScreen()),
          ),
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  //  Секции
  // ---------------------------------------------------------------------------

  String _categoryTitle(String? category, bool hasSearch) {
    String? label;
    for (final c in _hubCategories()) {
      if (c.value == category) {
        label = c.label;
        break;
      }
    }
    if (hasSearch) {
      return label == null
          ? tr('Результаты поиска')
          : trf('Поиск: {label}', {'label': label});
    }
    return label ?? _hubCategories().first.label;
  }

  /// Ошибка загрузки ленты. Молчаливая пустота неотличима от «там ничего
  /// нет», поэтому показываем причину и кнопку повтора.
  Widget _stripLoadError(String text, {required VoidCallback onRetry}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: MarketInlineHint(text: text, onRetry: onRetry),
    );
  }

  Widget _buildMusicStrip(AsyncValue<List<MusicTrack>> async) {
    return SizedBox(
      height: _kStripHeight,
      child: async.when(
        loading: () => _stripShimmer(),
        error: (_, __) => _stripLoadError(
          tr('Музыку не удалось получить'),
          onRetry: () => ref.invalidate(filteredMusicTracksProvider),
        ),
        data: (list) {
          final items = list.take(10).toList();
          if (items.isEmpty) {
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: MarketInlineHint(text: tr('Пока нет треков в маркете')),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            scrollDirection: Axis.horizontal,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: false,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) => RepaintBoundary(
              child: _HubMusicCard(
                track: items[i],
                width: _kStripCardWidth,
                isPlaying: _playingId == items[i].id,
                onTap: () => _openMusicDetails(items[i]),
                onPlayPause: () => _toggleMusic(items[i]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAssetStrip(
    AsyncValue<List<MarketAsset>> async,
    String kind,
  ) {
    return SizedBox(
      height: _kStripHeight,
      child: async.when(
        loading: () => _stripShimmer(),
        error: (_, __) => _stripLoadError(
          tr('Ресурсы не удалось получить'),
          onRetry: () => ref.invalidate(filteredAssetProvider),
        ),
        data: (list) {
          final items = list.where((a) => a.kind == kind).take(10).toList();
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: MarketInlineHint(
                text: trf('Пока нет ресурсов типа «{p0}»', {'p0': assetKindLabel(kind)}),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            scrollDirection: Axis.horizontal,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: false,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) => RepaintBoundary(
              child: _HubAssetCard(
                asset: items[i],
                width: _kStripCardWidth,
                isPlaying: _playingId == items[i].id,
                onTap: () => _openAssetDetails(items[i]),
                onPlay: () => _previewAsset(items[i]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _stripShimmer() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 4,
      separatorBuilder: (_, __) => const SizedBox(width: 6),
      itemBuilder: (_, __) => const CatalogShimmerCard(
        width: _kStripCardWidth,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Основная сетка
  // ---------------------------------------------------------------------------

  Widget _buildGrid(
    double width,
    String? category,
    AsyncValue<List<MusicTrack>> musicAsync,
    AsyncValue<List<MarketAsset>> assetAsync,
  ) {
    if (category == 'music') {
      return musicAsync.when(
        loading: () => CatalogGridShimmer(width: width),
        error: (e, _) => SliverToBoxAdapter(
          child: MarketErrorBlock(error: e, onRetry: _refreshAll),
        ),
        data: (list) {
          if (list.isEmpty) {
            return SliverToBoxAdapter(
              child: MarketEmptyState(message: tr('Треков пока нет')),
            );
          }
          return CatalogSliverGrid(
            itemCount: list.length,
            width: width,
            itemBuilder: (context, i) => RepaintBoundary(
              child: _HubMusicCard(
                track: list[i],
                isPlaying: _playingId == list[i].id,
                onTap: () => _openMusicDetails(list[i]),
                onPlayPause: () => _toggleMusic(list[i]),
              ),
            ),
          );
        },
      );
    }

    return assetAsync.when(
      loading: () => CatalogGridShimmer(width: width),
      error: (e, _) => SliverToBoxAdapter(
        child: MarketErrorBlock(error: e, onRetry: _refreshAll),
      ),
      data: (list) {
        final items = category == null
            ? list
            : list.where((a) => a.kind == category).toList();
        if (items.isEmpty) {
          return const SliverToBoxAdapter(child: MarketEmptyState());
        }
        return CatalogSliverGrid(
          itemCount: items.length,
          width: width,
          itemBuilder: (context, i) => RepaintBoundary(
            child: _HubAssetCard(
              asset: items[i],
              isPlaying: _playingId == items[i].id,
              onTap: () => _openAssetDetails(items[i]),
              onPlay: () => _previewAsset(items[i]),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
//  ЛЕВАЯ НАВИГАЦИОННАЯ ПАНЕЛЬ
// ============================================================================

class _HubDesktopRail extends ConsumerWidget {
  final ValueChanged<String?> onCategorySelected;

  const _HubDesktopRail({required this.onCategorySelected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(hubCategoryProvider);

    return Container(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CatalogRailHeader(
            icon: Icons.inventory_2_rounded,
            title: tr('Хаб'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                ..._hubCategories().map(
                  (c) => CatalogRailTile(
                    label: c.label,
                    icon: c.icon,
                    isSelected: selected == c.value,
                    onTap: () => onCategorySelected(c.value),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  ПРАВАЯ БОКОВАЯ ПАНЕЛЬ
// ============================================================================

class _HubRightAside extends ConsumerWidget {
  const _HubRightAside();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            tr('Рекомендации'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          ..._hubCategories()
              .where((c) => c.value != null)
              .map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _HubAsideCard(
                    icon: c.icon,
                    title: c.label,
                    subtitle: _categoryHint(c.value),
                    onTap: () =>
                        ref.read(hubCategoryProvider.notifier).state = c.value,
                  ),
                ),
              ),
          const SizedBox(height: 16),
          Text(
            tr('Библиотека'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => MyLibraryScreen()),
              ),
              icon: const Icon(Icons.bookmarks_rounded, size: 18),
              label: Text(tr('Моя библиотека')),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _categoryHint(String? value) {
    switch (value) {
      case 'button_preset':
        return tr('Пресеты кнопок от авторов');
      case 'music':
        return tr('Саундтрек для историй');
      case 'sfx':
        return tr('Звуковые эффекты');
      case 'background':
        return tr('Фоны и атмосфера');
      case 'font':
        return tr('Шрифты для текста');
      default:
        return '';
    }
  }
}

class _HubAsideCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _HubAsideCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: scheme.onPrimaryContainer, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: scheme.onSurfaceVariant.withOpacity(0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  ЧИПЫ КАТЕГОРИЙ (компактный режим)
// ============================================================================

class _HubCategoryChipsRow extends ConsumerWidget {
  const _HubCategoryChipsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(hubCategoryProvider);
    return CatalogCategoryChipsRow(
      entries: _hubCategories()
          .map((c) => CatalogChipEntry(c.label, c.value, c.icon))
          .toList(),
      selected: selected,
      onSelected: (value) =>
          ref.read(hubCategoryProvider.notifier).state = value,
    );
  }
}

// ============================================================================
//  ФИЛЬТРЫ — BOTTOM SHEET
// ============================================================================

class _HubFiltersSheet extends ConsumerWidget {
  const _HubFiltersSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(hubCategoryProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, color: scheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  tr('Фильтры'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                if (selected != null)
                  TextButton(
                    onPressed: () =>
                        ref.read(hubCategoryProvider.notifier).state = null,
                    child: Text(tr('Сбросить')),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tr('Типы ресурсов'),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _hubAssetKinds()
                .map(
                  (k) => _HubFilterChipItem(
                    label: k.label,
                    value: k.value,
                    icon: k.icon,
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.check_rounded),
              label: Text(tr('Применить')),
            ),
          ),
        ],
      ),
    );
  }
}

class _HubFilterChipItem extends ConsumerWidget {
  final String label;
  final String? value;
  final IconData icon;

  const _HubFilterChipItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(hubCategoryProvider) == value;
    return FilterChip(
      label: Text(label),
      avatar: Icon(icon, size: 16),
      selected: selected,
      onSelected: (_) =>
          ref.read(hubCategoryProvider.notifier).state = selected ? null : value,
    );
  }
}

// ============================================================================
//  ВЫБОР ТИПА ЗАГРУЖАЕМОГО РЕСУРСА
// ============================================================================

class _HubUploadKindSheet extends StatelessWidget {
  const _HubUploadKindSheet();

  // Геттер, а не static const: подписи и подсказки зависят от языка.
  static List<(String, String, String)> get _kinds => [
    ('music', tr('Музыка'), tr('Аудио • MP3, WAV, OGG, M4A, FLAC, AAC')),
    ('sfx', tr('Звуки'), tr('Аудио • MP3, WAV, OGG, M4A, FLAC, AAC')),
    ('background', tr('Фоны'), 'JPG, PNG, WEBP'),
    ('button_preset', tr('Пресеты кнопок'), tr('Готовый пресет интерфейса')),
    ('font', tr('Шрифты'), 'TTF, OTF, WOFF, WOFF2'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Добавить ресурс'),
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            tr('Выбери тип — дальше откроется форма с подходящими форматами.'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          ..._kinds.map((k) {
            final (id, label, hint) = k;
            final icon = _hubCategories()
                .firstWhere((c) => c.value == id, orElse: () => _hubCategories()[0])
                .icon;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.pop(context, id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(
                            icon,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                              Text(
                                hint,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ============================================================================
//  КАРТОЧКА РЕСУРСА (те же пропорции, что у карточки квеста в маркете)
// ============================================================================

class _HubAssetCard extends StatelessWidget {
  final MarketAsset asset;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final double? width;

  const _HubAssetCard({
    required this.asset,
    required this.isPlaying,
    required this.onTap,
    this.onPlay,
    this.width,
  });

  IconData _iconFor(String kind) {
    switch (kind) {
      case 'button_preset':
        return Icons.widgets_rounded;
      case 'background':
        return Icons.wallpaper_rounded;
      case 'sfx':
        return Icons.graphic_eq_rounded;
      case 'font':
        return Icons.text_fields_rounded;
      case 'image':
        return Icons.image_rounded;
      default:
        return Icons.inventory_2_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = _iconFor(asset.kind);
    final preview =
        asset.coverUrl ??
        ((asset.kind == 'background' || asset.kind == 'image')
            ? asset.downloadUrl
            : null);

    return SizedBox(
      width: width,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 11,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (asset.kind == 'button_preset')
                      RemotePresetPreview(asset: asset, height: double.infinity)
                    else if (asset.kind == 'font')
                      _HubFontGridPreview(asset: asset)
                    else if (preview != null)
                      MarketCoverImage(
                        url: preview,
                        fallbackColor: scheme.surfaceContainerHighest,
                      )
                    else
                      _HubPreviewFallback(icon: icon),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: MarketBadge(
                        label: _shortKindLabel(asset.kind),
                        background: scheme.surface.withOpacity(0.88),
                        foreground: scheme.onSurface,
                      ),
                    ),
                    if (asset.kind == 'sfx')
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _HubPlayBadge(
                          isPlaying: isPlaying,
                          onTap: onPlay ?? onTap,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      asset.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (asset.authorName != null &&
                        asset.authorName!.isNotEmpty)
                      CosmeticNameText(
                        name: asset.authorName!,
                        def: cosmeticById(asset.authorNameStyle),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(icon, size: 14, color: scheme.primary),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            assetGenreDisplay(asset.genre, asset.kind),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(
                          Icons.verified_user_outlined,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            licenseLabel(asset.license),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  КАРТОЧКА ТРЕКА
// ============================================================================

class _HubMusicCard extends StatelessWidget {
  final MusicTrack track;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;
  final double? width;

  const _HubMusicCard({
    required this.track,
    required this.isPlaying,
    required this.onTap,
    required this.onPlayPause,
    this.width,
  });

  String _duration(int seconds) {
    if (seconds <= 0) return '';
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = _duration(track.durationSeconds);

    return SizedBox(
      width: width,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 11,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (track.coverUrl != null)
                      MarketCoverImage(
                        url: track.coverUrl,
                        fallbackColor: scheme.surfaceContainerHighest,
                      )
                    else
                      _HubMusicFallback(track: track),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: MarketBadge(
                        label: tr('МУЗЫКА'),
                        background: scheme.surface.withOpacity(0.88),
                        foreground: scheme.onSurface,
                      ),
                    ),
                    if (duration.isNotEmpty)
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: MarketBadge(
                          label: duration,
                          background: Colors.black.withOpacity(0.6),
                          foreground: Colors.white,
                        ),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _HubPlayBadge(
                        isPlaying: isPlaying,
                        onTap: onPlayPause,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      track.performer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.music_note_rounded,
                          size: 14,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            (track.genre?.trim().isNotEmpty ?? false)
                                ? track.genre!
                                : tr('Музыка'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (duration.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Icon(
                            Icons.schedule_rounded,
                            size: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            duration,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HubPlayBadge extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onTap;

  const _HubPlayBadge({required this.isPlaying, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withOpacity(0.92),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: scheme.primary,
            size: 16,
          ),
        ),
      ),
    );
  }
}

class _HubPreviewFallback extends StatelessWidget {
  final IconData icon;

  const _HubPreviewFallback({required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primaryContainer, scheme.secondaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          icon,
          size: 46,
          color: scheme.onPrimaryContainer.withOpacity(0.72),
        ),
      ),
    );
  }
}

class _HubMusicFallback extends StatelessWidget {
  final MusicTrack track;

  const _HubMusicFallback({required this.track});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primary, scheme.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.graphic_eq_rounded,
          size: 52,
          color: scheme.onPrimary.withOpacity(0.72),
        ),
      ),
    );
  }
}

// ============================================================================
//  ЖИВОЕ ПРЕВЬЮ ШРИФТА
// ============================================================================

class _HubFontGridPreview extends StatefulWidget {
  final MarketAsset asset;

  const _HubFontGridPreview({required this.asset});

  @override
  State<_HubFontGridPreview> createState() => _HubFontGridPreviewState();
}

class _HubFontGridPreviewState extends State<_HubFontGridPreview> {
  String? _family;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final family = 'hub_font_grid_${widget.asset.id}';
    try {
      final tmpDir = await getTemporaryDirectory();
      final ext = p.extension(widget.asset.downloadUrl.split('?').first);
      final file = File(
        p.join(tmpDir.path, 'hub_font_grid_${widget.asset.id}$ext'),
      );
      if (!await file.exists()) {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('jwt_token') ?? '';
        final req = http.Request('GET', Uri.parse(widget.asset.downloadUrl));
        if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
        final resp = await http.Client().send(req);
        if (resp.statusCode != 200) return;
        await file.writeAsBytes(await resp.stream.toBytes());
      }
      final bytes = await file.readAsBytes();
      final loader = FontLoader(family);
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      if (!mounted) return;
      setState(() {
        _family = family;
        _done = true;
      });
    } catch (_) {
      if (mounted) setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_family != null) {
      return Container(
        color: scheme.surfaceContainerLow,
        padding: const EdgeInsets.all(10),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              tr('Аа Бб Вв'),
              style: TextStyle(
                fontFamily: _family,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      color: scheme.secondaryContainer,
      child: Center(
        child: _done
            ? Icon(
                Icons.text_fields_rounded,
                size: 28,
                color: scheme.onSecondaryContainer,
              )
            : const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );
  }
}

// ============================================================================
//  МИНИ-ПЛЕЕР
// ============================================================================

class _HubMiniPlayer extends StatelessWidget {
  final MusicTrack track;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;
  final ValueChanged<Duration> onSeek;

  const _HubMiniPlayer({
    required this.track,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onStop,
    required this.onSeek,
  });

  String _fmt(Duration d) {
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inMinutes}:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withOpacity(0.2)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: track.coverUrl != null
                    ? Image.network(
                        track.coverUrl!,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 44,
                          height: 44,
                          color: scheme.secondaryContainer,
                          child: const Icon(Icons.music_note_rounded, size: 18),
                        ),
                      )
                    : Container(
                        width: 44,
                        height: 44,
                        color: scheme.secondaryContainer,
                        child: const Icon(Icons.music_note_rounded, size: 18),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      track.performer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onPlayPause,
                icon: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 28,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                ),
              ),
              IconButton(
                onPressed: onStop,
                icon: const Icon(Icons.close_rounded, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                _fmt(position),
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: scheme.primary,
                    inactiveTrackColor: scheme.outlineVariant.withOpacity(0.3),
                    thumbColor: scheme.primary,
                  ),
                  child: Slider(
                    value: progress.clamp(0.0, 1.0),
                    onChanged: (v) => onSeek(
                      Duration(
                        milliseconds: (v * duration.inMilliseconds).round(),
                      ),
                    ),
                  ),
                ),
              ),
              Text(
                _fmt(duration),
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
