import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/asset_market/providers/asset_provider.dart';
import 'package:canvas_app/features/hub/widgets/background_preview.dart';
import 'package:canvas_app/features/hub/widgets/market_resource_actions.dart';
import 'package:canvas_app/features/hub/widgets/preset_market.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/features/shell/screens/menu_screen.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/library/services/my_library_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/catalog_shell.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';

class AssetDetailsScreen extends ConsumerStatefulWidget {
  final MarketAsset asset;
  const AssetDetailsScreen({super.key, required this.asset});

  @override
  ConsumerState<AssetDetailsScreen> createState() => _AssetDetailsScreenState();
}

class _AssetDetailsScreenState extends ConsumerState<AssetDetailsScreen> {
  final _player = AudioPlayer();
  bool _isPlaying = false;
  bool _isLiked = false;
  bool _isLikeLoading = false;
  int _likeCount = 0;
  int _dislikeCount = 0;
  final _reviewCtrl = TextEditingController();
  List<dynamic> _reviews = [];
  bool _reviewsLoading = true;
  bool _sendingReview = false;
  String? _fontFamily;
  bool _fontLoading = false;
  bool _inLibrary = false;
  bool _libraryLoading = true;
  late MarketAsset _asset;
  String? _currentUserId;
  bool _isCurrentUserAdminFlag = false;
  bool _isDeleting = false;
  bool _isAdminProcessing = false;

  /// Пользователь — автор этого ресурса (значит, может удалить из маркета).
  bool get _isAuthor =>
      _currentUserId != null && _currentUserId == _asset.authorId;

  @override
  void initState() {
    super.initState();
    _asset = widget.asset;
    _loadFont();
    _loadCurrentUser();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
    _loadAll();
  }

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final localId = prefs.getString('user_id');
    bool isAdmin = false;
    if (localId != null && localId.isNotEmpty) {
      try {
        final profile = await ref.read(userProfileProvider(localId).future);
        isAdmin = profile.role == 'admin';
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _currentUserId = localId;
        _isCurrentUserAdminFlag = isAdmin;
      });
    }
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadAssetDetails(),
      _loadMyVote(),
      _loadReviews(),
      _checkLibrary(),
    ]);
  }

  Future<void> _checkLibrary() async {
    final inLib = await MyLibraryService.isInLibrary(_asset.id);
    if (mounted)
      setState(() {
        _inLibrary = inLib;
        _libraryLoading = false;
      });
  }

  Future<void> _loadAssetDetails() async {
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.get('assets/${_asset.id}');
      if (data is Map<String, dynamic> && mounted) {
        final updated = MarketAsset.fromJson(data);
        setState(() {
          _asset = updated;
          _likeCount =
              (data['like_count'] ?? data['likeCount'] ?? _likeCount) is int
              ? data['like_count'] as int
              : int.tryParse('${data['like_count'] ?? 0}') ?? _likeCount;
          _dislikeCount =
              (data['dislike_count'] ?? data['dislikeCount'] ?? _dislikeCount)
                  is int
              ? data['dislike_count'] as int
              : int.tryParse('${data['dislike_count'] ?? 0}') ?? _dislikeCount;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadMyVote() async {
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.get('assets/${_asset.id}/my-vote');
      if (data is Map && data['is_like'] != null && mounted) {
        setState(() => _isLiked = data['is_like'] == true);
      }
    } catch (_) {}
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.get('assets/${_asset.id}');
      if (data is Map<String, dynamic>) {
        final lc = data['like_count'];
        final dc = data['dislike_count'];
        if (lc != null && mounted)
          setState(
            () => _likeCount = lc is int ? lc : int.tryParse('$lc') ?? 0,
          );
        if (dc != null && mounted)
          setState(
            () => _dislikeCount = dc is int ? dc : int.tryParse('$dc') ?? 0,
          );
      }
    } catch (_) {}
  }

  Future<void> _loadReviews() async {
    setState(() => _reviewsLoading = true);
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.get('assets/${_asset.id}/reviews');
      if (data is List && mounted) setState(() => _reviews = data);
    } catch (e) {
      if (mounted) setState(() => _reviews = []);
    } finally {
      if (mounted) setState(() => _reviewsLoading = false);
    }
  }

  Future<void> _toggleLike() async {
    if (_isLikeLoading) return;
    if (_currentUserId == null) {
      _showAuthRequiredDialog();
      return;
    }
    setState(() => _isLikeLoading = true);
    try {
      final api = ref.read(apiServiceProvider);
      final wasLiked = _isLiked;
      final body = wasLiked ? {'action': 'remove'} : {'is_like': true};
      final res = await api.post('assets/${_asset.id}/vote', body: body);
      if (res is Map) {
        setState(() {
          _isLiked = !wasLiked;
          _likeCount = res['likes'] is int
              ? res['likes']
              : int.tryParse('${res['likes'] ?? _likeCount}') ?? _likeCount;
          _dislikeCount = res['dislikes'] is int
              ? res['dislikes']
              : int.tryParse('${res['dislikes'] ?? _dislikeCount}') ??
                    _dislikeCount;
        });
      } else {
        setState(() => _isLiked = !wasLiked);
        _loadAssetDetails();
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(trf('Ошибка лайка: {p0}', {'p0': friendlyError(e)}))));
    } finally {
      if (mounted) setState(() => _isLikeLoading = false);
    }
  }

  void _showAuthRequiredDialog() {
    showAppDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Войдите в аккаунт')),
        content: Text(tr('Для голосования необходимо войти в систему.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              // Идём по контексту экрана, а не диалога: после pop маршрут
              // окна уже не жив, и `Navigator.of` по нему в debug бросает
              // assertion на мёртвый виджет.
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => MenuScreen()),
              );
            },
            child: Text(tr('Войти')),
          ),
        ],
      ),
    );
  }

  void _showReportDialog() {
    showAppDialog(
      context: context,
      builder: (context) => ReportDialog(
        reportedType: 'asset',
        reportedId: _asset.id,
        reportedTitle: _asset.title,
      ),
    );
  }

  Future<void> _deleteFromMarket() async {
    setState(() => _isDeleting = true);
    final ok = await MarketResourceActions.confirmDelete(
      context,
      ref,
      endpoint: 'assets',
      id: _asset.id,
      title: _asset.title,
    );
    if (!mounted) return;
    setState(() => _isDeleting = false);
    if (!ok) return;
    ref.invalidate(assetListProvider);
    Navigator.pop(context);
  }

  Future<void> _showAdminActions() async {
    setState(() => _isAdminProcessing = true);
    await MarketResourceActions.showAdminSheet(
      context,
      ref,
      endpoint: 'assets',
      id: _asset.id,
      title: _asset.title,
      currentStatus: _asset.status,
      onChanged: () {
        ref.invalidate(assetListProvider);
        _loadAssetDetails();
      },
      onDeleted: (_) {
        ref.invalidate(assetListProvider);
        if (mounted) Navigator.pop(context);
      },
    );
    if (mounted) setState(() => _isAdminProcessing = false);
  }

  Future<void> _loadFont() async {
    if (_asset.kind != 'font') return;
    setState(() => _fontLoading = true);
    try {
      final family = 'asset_detail_font_${_asset.id}';
      final tmpDir = await getTemporaryDirectory();
      final file = File(
        p.join(
          tmpDir.path,
          'asset_detail_font_${_asset.id}${p.extension(_asset.downloadUrl.split('?').first)}',
        ),
      );
      if (!await file.exists()) {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('jwt_token') ?? '';
        final req = http.Request('GET', Uri.parse(_asset.downloadUrl));
        if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
        final resp = await http.Client().send(req);
        if (resp.statusCode == 200)
          await file.writeAsBytes(await resp.stream.toBytes());
      }
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final loader = FontLoader(family);
        loader.addFont(Future.value(ByteData.view(bytes.buffer)));
        await loader.load();
        if (mounted) setState(() => _fontFamily = family);
      }
    } catch (_) {}
    if (mounted) setState(() => _fontLoading = false);
  }

  Future<void> _playSfx() async {
    if (_isPlaying) {
      await _player.stop();
      setState(() => _isPlaying = false);
      return;
    }
    await _player.play(UrlSource(_asset.downloadUrl));
    setState(() => _isPlaying = true);
  }

  Future<void> _toggleLibrary() async {
    if (_inLibrary) {
      await MyLibraryService.removeAsset(_asset.id);
      if (mounted) setState(() => _inLibrary = false);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Удалено из библиотеки')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    try {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Сохранение в библиотеку...')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      final failure = await MyLibraryService.addAsset(_asset);
      // Библиотека без файла выглядит как «добавлено», но в квест такой
      // ассет не поставишь — сначала причина, статус меняем только на успехе.
      if (failure != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(failure),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      if (mounted) setState(() => _inLibrary = true);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Future<void> _addReview() async {
    final text = _reviewCtrl.text.trim();
    if (text.isEmpty) return;
    if (text.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Отзыв слишком короткий')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_currentUserId == null) {
      _showAuthRequiredDialog();
      return;
    }
    setState(() => _sendingReview = true);
    try {
      final api = ref.read(apiServiceProvider);
      await api.post(
        'assets/${_asset.id}/review',
        body: {'text_content': text},
      );
      _reviewCtrl.clear();
      await _loadReviews();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Отзыв опубликован')),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } finally {
      if (mounted) setState(() => _sendingReview = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes < 1024 * 1024) return trf('{p0} КБ', {'p0': (bytes / 1024).toStringAsFixed(1)});
    if (bytes < 1024 * 1024 * 1024)
      return trf('{p0} МБ', {'p0': (bytes / (1024 * 1024)).toStringAsFixed(1)});
    return trf('{p0} ГБ', {'p0': (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)});
  }

  String _formatUpdated(DateTime? date) {
    if (date == null) return '—';
    final diff = DateTime.now().difference(date);
    if (diff.inDays < 1) return tr('сегодня');
    if (diff.inDays < 30) return trf('{p0} дн', {'p0': diff.inDays});
    final months = (diff.inDays / 30).floor();
    if (months < 12) return trf('{p0} мес', {'p0': months});
    return trf('{p0} г', {'p0': (diff.inDays / 365).floor()});
  }

  /// Крупный CTA — тот же приём, что «Скачать / Играть» на странице квеста.
  Widget _buildLibraryCta(ColorScheme scheme, TextTheme textTheme) {
    final busy = _libraryLoading;
    return Material(
      color: scheme.primary,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : _toggleLibrary,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: scheme.onPrimary,
                  ),
                )
              else
                Icon(
                  _inLibrary
                      ? Icons.check_rounded
                      : Icons.bookmark_add_rounded,
                  color: scheme.onPrimary,
                  size: 24,
                ),
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _inLibrary ? tr('В библиотеке') : tr('В библиотеку'),
                    style: textTheme.titleMedium?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    _inLibrary
                        ? tr('нажмите, чтобы убрать')
                        : tr('сохранить в свою библиотеку'),
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimary.withOpacity(0.82),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _player.dispose();
    _reviewCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final a = _asset;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 340,
            pinned: true,
            stretch: true,
            backgroundColor: scheme.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: CatalogGlassIconButton(
              icon: Icons.arrow_back_rounded,
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              if (_isAuthor)
                CatalogGlassIconButton(
                  icon: Icons.delete_forever_rounded,
                  tooltip: tr('Удалить из маркета'),
                  color: Colors.redAccent,
                  loading: _isDeleting,
                  onPressed: _isDeleting ? null : _deleteFromMarket,
                )
              else
                CatalogGlassIconButton(
                  icon: Icons.flag_outlined,
                  tooltip: tr('Пожаловаться'),
                  color: Colors.redAccent,
                  onPressed: _showReportDialog,
                ),
              if (_isCurrentUserAdminFlag)
                CatalogGlassIconButton(
                  icon: Icons.admin_panel_settings_rounded,
                  tooltip: tr('Админ-действия'),
                  color: Colors.greenAccent,
                  loading: _isAdminProcessing,
                  onPressed: _isAdminProcessing ? null : _showAdminActions,
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [
                StretchMode.zoomBackground,
                StretchMode.blurBackground,
              ],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (a.kind == 'button_preset')
                    Container(
                      color: const Color(0xFF0D1220),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 150),
                          child: RemotePresetPreview(asset: a, height: 140),
                        ),
                      ),
                    )
                  else if (a.kind == 'font')
                    Container(
                      color: scheme.surfaceContainerHigh,
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 150),
                      child: _fontFamily == null
                          ? Center(
                              child: _fontLoading
                                  ? const CircularProgressIndicator()
                                  : const Icon(
                                      Icons.text_fields_rounded,
                                      size: 48,
                                    ),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  tr('Съешь ещё этих мягких французских булок'),
                                  style: TextStyle(
                                    fontFamily: _fontFamily,
                                    fontSize: 22,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'ABC 123',
                                  style: TextStyle(
                                    fontFamily: _fontFamily,
                                    fontSize: 16,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                    )
                  else if (a.coverUrl != null ||
                      a.kind == 'background' ||
                      a.kind == 'image')
                    CachedNetworkImage(
                      imageUrl: a.coverUrl ?? a.downloadUrl,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: scheme.surfaceContainerHigh,
                        child: const Icon(Icons.image_rounded, size: 48),
                      ),
                    )
                  else
                    Container(
                      color: scheme.surfaceContainerHigh,
                      child: Icon(
                        a.kind == 'sfx'
                            ? Icons.music_note_rounded
                            : Icons.widgets_rounded,
                        size: 48,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          scheme.surface.withOpacity(0.6),
                          scheme.surface,
                        ],
                        stops: const [0.45, 0.85, 1.0],
                      ),
                    ),
                  ),
                  // Заголовок и метки — тот же приём, что на странице квеста.
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            CatalogGenreChip(label: assetKindLabel(a.kind)),
                            if (a.genre != null && a.genre!.trim().isNotEmpty)
                              CatalogGenreChip(label: a.genre!),
                            CatalogGenreChip(label: licenseLabel(a.license)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          a.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.headlineMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            shadows: const [
                              Shadow(blurRadius: 12, color: Colors.black54),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (a.kind == 'sfx')
                    Center(
                      child: Material(
                        color: scheme.primary,
                        shape: const CircleBorder(),
                        elevation: 6,
                        child: InkWell(
                          onTap: _playSfx,
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 64,
                            height: 64,
                            alignment: Alignment.center,
                            child: Icon(
                              _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: CatalogStatTile(
                              value: '$_likeCount',
                              label: tr('Лайков'),
                              icon: Icons.favorite_rounded,
                              container: scheme.errorContainer,
                              onContainer: scheme.onErrorContainer,
                              accent: scheme.error,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: CatalogStatTile(
                              value: _formatBytes(a.fileSizeBytes),
                              label: tr('Размер'),
                              icon: Icons.sd_storage_rounded,
                              container: scheme.tertiaryContainer,
                              onContainer: scheme.onTertiaryContainer,
                              accent: scheme.tertiary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: CatalogStatTile(
                              value: _formatUpdated(a.updatedAt),
                              label: tr('Обновлён'),
                              icon: Icons.update_rounded,
                              container: scheme.secondaryContainer,
                              onContainer: scheme.onSecondaryContainer,
                              accent: scheme.secondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildLibraryCta(scheme, textTheme),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: a.authorId == null
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ProfileScreen(userId: a.authorId!),
                                ),
                              ),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CosmeticAvatar(
                                frame: cosmeticById(a.authorAvatarFrame),
                                radius: 14,
                                placeholderColor: scheme.primary,
                                fallback: Text(
                                  (a.authorName?.isNotEmpty ?? false)
                                      ? a.authorName![0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: CosmeticNameText(
                                  name: a.authorName ?? tr('Неизвестный автор'),
                                  def: cosmeticById(a.authorNameStyle),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                              if (a.authorIsVerified)
                                const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(
                                    Icons.verified_rounded,
                                    size: 16,
                                    color: Color(0xFF1976D2),
                                  ),
                                ),
                              if (a.authorId != null)
                                const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(
                                    Icons.chevron_right_rounded,
                                    size: 16,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (a.description != null &&
                          a.description!.trim().isNotEmpty) ...[
                        CatalogSectionLabel(text: tr('Описание')),
                        const SizedBox(height: 8),
                        Text(
                          a.description!,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      Row(
                        children: [
                          IconButton.filledTonal(
                            onPressed: _isLikeLoading ? null : _toggleLike,
                            icon: _isLikeLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    _isLiked
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    color: _isLiked ? scheme.error : null,
                                  ),
                          ),
                          const SizedBox(width: 8),
                          if (a.kind == 'sfx')
                            FilledButton.tonalIcon(
                              onPressed: _playSfx,
                              icon: Icon(
                                _isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 18,
                              ),
                              label: Text(_isPlaying ? tr('Пауза') : tr('Прослушать')),
                            ),
                          if (a.kind == 'background')
                            FilledButton.tonalIcon(
                              onPressed: () =>
                                  BackgroundPreviewService.openPreview(
                                    context,
                                    ref,
                                    a,
                                  ),
                              icon: const Icon(
                                Icons.visibility_rounded,
                                size: 18,
                              ),
                              label: Text(tr('Открыть фон')),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      CatalogSectionLabel(text: trf('Отзывы ({p0})', {'p0': _reviews.length})),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _reviewCtrl,
                              decoration: InputDecoration(
                                hintText: tr('Написать отзыв...'),
                                filled: true,
                                fillColor: scheme.surfaceContainerHigh,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              minLines: 1,
                              maxLines: 3,
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _sendingReview ? null : _addReview,
                            child: _sendingReview
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(tr('Отправить')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_reviewsLoading)
                        const Center(child: CircularProgressIndicator())
                      else if (_reviews.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Center(
                            child: Text(
                              tr('Пока нет отзывов — станьте первым!'),
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        )
                      else
                        ..._reviews.map((r) {
                          final author =
                              (r['author_name'] ?? r['authorName'] ?? tr('Аноним'))
                                  .toString();
                          final text = (r['text_content'] ?? r['text'] ?? '')
                              .toString();
                          final avatar =
                              r['author_avatar_url'] ?? r['authorAvatarUrl'];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CosmeticAvatar(
                                  frame: cosmeticById(
                                    equippedOf(r).avatarFrame,
                                  ),
                                  radius: 16,
                                  avatarUrl: avatar?.toString(),
                                  placeholderColor: scheme.primaryContainer,
                                  fallback: Text(
                                    author.isNotEmpty
                                        ? author[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                      color: scheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      CosmeticNameText(
                                        name: author,
                                        def: cosmeticById(nameStyleOf(r)),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        text,
                                        style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

