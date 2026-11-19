import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/hub/widgets/market_resource_actions.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/library/services/my_library_service.dart';
import 'package:canvas_app/features/music_library/providers/music_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/widgets/catalog_shell.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

class MusicDetailsScreen extends ConsumerStatefulWidget {
  final MusicTrack track;
  const MusicDetailsScreen({super.key, required this.track});

  @override
  ConsumerState<MusicDetailsScreen> createState() => _MusicDetailsScreenState();
}

class _MusicDetailsScreenState extends ConsumerState<MusicDetailsScreen> {
  final _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isLiked = false;
  bool _isLikeLoading = false;
  int _likeCount = 0;
  int _dislikeCount = 0;
  bool _inLibrary = false;
  bool _libraryLoading = true;
  final _reviewCtrl = TextEditingController();
  List<dynamic> _reviews = [];
  bool _reviewsLoading = true;
  bool _sendingReview = false;
  late MusicTrack _track;
  String? _currentUserId;
  bool _isAdmin = false;
  bool _isDeleting = false;
  bool _isAdminProcessing = false;

  /// Пользователь — автор трека (значит, может удалить его из маркета).
  bool get _isAuthor =>
      _currentUserId != null && _currentUserId == _track.authorId;

  @override
  void initState() {
    super.initState();
    _track = widget.track;
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted)
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
    });
    _loadAll();
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadMusicDetails(),
      _loadMyVote(),
      _loadReviews(),
      _checkLibrary(),
      _loadCurrentUser(),
    ]);
  }

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');
    var isAdmin = false;
    if (userId != null && userId.isNotEmpty) {
      try {
        final profile = await ref.read(userProfileProvider(userId).future);
        isAdmin = profile.role == 'admin';
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _currentUserId = userId;
      _isAdmin = isAdmin;
    });
  }

  void _showReportDialog() {
    showAppDialog(
      context: context,
      builder: (context) => ReportDialog(
        reportedType: 'music',
        reportedId: _track.id,
        reportedTitle: _track.title,
      ),
    );
  }

  Future<void> _deleteFromMarket() async {
    setState(() => _isDeleting = true);
    final ok = await MarketResourceActions.confirmDelete(
      context,
      ref,
      endpoint: 'music',
      id: _track.id,
      title: _track.title,
    );
    if (!mounted) return;
    setState(() => _isDeleting = false);
    if (!ok) return;
    ref.invalidate(musicTracksProvider);
    Navigator.pop(context);
  }

  Future<void> _showAdminActions() async {
    setState(() => _isAdminProcessing = true);
    await MarketResourceActions.showAdminSheet(
      context,
      ref,
      endpoint: 'music',
      id: _track.id,
      title: _track.title,
      currentStatus: _track.status,
      onChanged: () {
        ref.invalidate(musicTracksProvider);
        _loadMusicDetails();
      },
      onDeleted: (_) {
        ref.invalidate(musicTracksProvider);
        if (mounted) Navigator.pop(context);
      },
    );
    if (mounted) setState(() => _isAdminProcessing = false);
  }

  Future<void> _checkLibrary() async {
    final inLib = await MyLibraryService.isMusicInLibrary(_track.id);
    if (mounted)
      setState(() {
        _inLibrary = inLib;
        _libraryLoading = false;
      });
  }

  Future<void> _toggleLibrary() async {
    if (_inLibrary) {
      await MyLibraryService.removeMusic(_track.id);
      if (mounted) setState(() => _inLibrary = false);
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Удалено из библиотеки'))));
      return;
    }
    try {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Сохранение в библиотеку...'))),
        );
      final failure = await MyLibraryService.addMusic(_track);
      // Трек без файла в библиотеке молчит вместо игры: это неудача, не успех.
      if (failure != null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(failure)));
        }
        return;
      }
      if (mounted) setState(() => _inLibrary = true);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
    }
  }

  Future<void> _loadMusicDetails() async {
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.get('music/${_track.id}');
      if (data is Map<String, dynamic> && mounted) {
        final updated = MusicTrack.fromJson(data);
        setState(() {
          _track = updated;
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
      final data = await api.get('music/${_track.id}/my-vote');
      if (data is Map && data['is_like'] != null && mounted)
        setState(() => _isLiked = data['is_like'] == true);
    } catch (_) {}
  }

  Future<void> _loadReviews() async {
    setState(() => _reviewsLoading = true);
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.get('music/${_track.id}/reviews');
      if (data is List && mounted) setState(() => _reviews = data);
    } catch (_) {
      if (mounted) setState(() => _reviews = []);
    } finally {
      if (mounted) setState(() => _reviewsLoading = false);
    }
  }

  Future<void> _toggleLike() async {
    if (_isLikeLoading) return;
    // Без сессии POST /vote отдаёт 401, и гость читал «Сессия истекла —
    // войдите заново» про вход, которого у него никогда не было.
    if (
      !await ensureAccount(
        context,
        why:
            tr('Оценивать чужие треки могут авторы с аккаунтом. Войдите на вкладке «Вход» — и лайк сработает.'),
      )
    ) {
      return;
    }
    if (!mounted) return;
    setState(() => _isLikeLoading = true);
    try {
      final api = ref.read(apiServiceProvider);
      final wasLiked = _isLiked;
      final body = wasLiked ? {'action': 'remove'} : {'is_like': true};
      final res = await api.post('music/${_track.id}/vote', body: body);
      if (!mounted) return;
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
        _loadMusicDetails();
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

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.stop();
      if (!mounted) return;
      setState(() => _isPlaying = false);
      return;
    }
    await _player.play(UrlSource(_track.downloadUrl));
    if (!mounted) return;
    setState(() => _isPlaying = true);
  }

  Future<void> _addReview() async {
    final text = _reviewCtrl.text.trim();
    if (text.isEmpty) return;
    if (text.length < 3) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Отзыв слишком короткий'))));
      return;
    }
    // Форма отзыва была доступна гостю: текст терялся вместе с 401-ом в
    // конце. Проверяем сессию до отправки.
    if (
      !await ensureAccount(
        context,
        why:
            tr('Отзывы видят только авторы с аккаунтом — иначе модерация не знает, от кого он. Войдите на вкладке «Вход».'),
      )
    ) {
      return;
    }
    if (!mounted) return;
    setState(() => _sendingReview = true);
    try {
      final api = ref.read(apiServiceProvider);
      await api.post('music/${_track.id}/review', body: {'text_content': text});
      _reviewCtrl.clear();
      await _loadReviews();
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Отзыв опубликован'))));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)}))));
    } finally {
      if (mounted) setState(() => _sendingReview = false);
    }
  }

  String _fmt(Duration d) {
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inMinutes}:$s';
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
    final t = _track;
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      body: AdaptiveContent(
        maxWidth: 900,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 420,
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
                if (_isAdmin)
                  CatalogGlassIconButton(
                    icon: Icons.admin_panel_settings_rounded,
                    tooltip: tr('Админ-действия'),
                    color: Colors.greenAccent,
                    loading: _isAdminProcessing,
                    onPressed: _isAdminProcessing ? null : _showAdminActions,
                  ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (t.coverUrl != null)
                      CachedNetworkImage(
                        imageUrl: t.coverUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: scheme.surfaceContainerHigh,
                          child: const Icon(Icons.music_note_rounded, size: 48),
                        ),
                      )
                    else
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              scheme.primaryContainer,
                              scheme.secondaryContainer,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.music_note_rounded,
                            size: 64,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            scheme.surface.withOpacity(0.85),
                            scheme.surface,
                          ],
                          stops: const [0.4, 0.85, 1.0],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('МУЗЫКА ДЛЯ КВЕСТА'),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t.title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.performer,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _Chip(
                          icon: Icons.category_rounded,
                          label: t.genre ?? '—',
                        ),
                        _Chip(
                          icon: Icons.timer_rounded,
                          label: t.durationSeconds > 0
                              ? '${t.durationSeconds ~/ 60}:${(t.durationSeconds % 60).toString().padLeft(2, '0')}'
                              : '—',
                        ),
                        _Chip(
                          icon: Icons.verified_user_rounded,
                          label: t.license,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: t.authorId == null
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    ProfileScreen(userId: t.authorId!),
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
                              frame: cosmeticById(t.authorAvatarFrame),
                              radius: 14,
                              placeholderColor: scheme.primary,
                              fallback: Text(
                                (t.authorName?.isNotEmpty ?? false)
                                    ? t.authorName![0].toUpperCase()
                                    : t.performer[0].toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: CosmeticNameText(
                                name: t.authorName ?? t.performer,
                                def: cosmeticById(t.authorNameStyle),
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                            if (t.authorIsVerified)
                              const Padding(
                                padding: EdgeInsets.only(left: 6),
                                child: Icon(
                                  Icons.verified_rounded,
                                  size: 16,
                                  color: Color(0xFF1976D2),
                                ),
                              ),
                            if (t.authorId != null)
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
                    if (t.description != null &&
                        t.description!.trim().isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        t.description!,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              IconButton.filled(
                                onPressed: _togglePlay,
                                icon: Icon(
                                  _isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 3,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6,
                                    ),
                                    activeTrackColor: scheme.primary,
                                    inactiveTrackColor: scheme.outlineVariant
                                        .withOpacity(0.3),
                                  ),
                                  child: Slider(
                                    value: progress.clamp(0.0, 1.0),
                                    onChanged: (v) => _player.seek(
                                      Duration(
                                        milliseconds:
                                            (v * _duration.inMilliseconds)
                                                .round(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                _fmt(_duration),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Text(
                                _fmt(_position),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _fmt(_duration),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _libraryLoading ? null : _toggleLibrary,
                        icon: Icon(
                          _inLibrary
                              ? Icons.check_rounded
                              : Icons.bookmark_add_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _inLibrary ? tr('В библиотеке') : tr('В библиотеку'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
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
                                  color: _isLiked ? Colors.red : null,
                                ),
                        ),
                        Text(
                          '$_likeCount',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          tr('Отзывы'),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Divider(color: scheme.outlineVariant.withOpacity(0.3)),
                    const SizedBox(height: 16),
                    Text(
                      trf('Отзывы ({p0})', {'p0': _reviews.length}),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
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
                            (r['author_name'] ??
                                r['authorName'] ??
                                tr('Аноним'))
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
