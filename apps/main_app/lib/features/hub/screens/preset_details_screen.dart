import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/asset_market/providers/asset_provider.dart';
import 'package:canvas_app/features/hub/widgets/market_resource_actions.dart';
import 'package:canvas_app/features/hub/widgets/preset_market.dart';
import 'package:canvas_app/features/library/services/my_library_service.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/models/user_profile_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/shared/widgets/catalog_shell.dart';
import 'package:canvas_app/shared/widgets/report_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

// ============================================================================
//  СТРАНИЦА ПРЕСЕТА
//
//  Повторяет принцип страницы квеста в маркете
//  (quest_market_details_screen.dart): hero-шапка с живым превью,
//  стеклянные кнопки поверх, полоса характеристик, CTA и действия автора.
//
//  Главное отличие от квеста: пресет — это локальная сущность из config.json
//  квеста. Поэтому CTA зависит от того, кто автор:
//   • свой пресет и он уже в маркете  → «Уже в маркете» + удаление из маркета;
//   • свой пресет, ещё не опубликован → «Опубликовать»;
//   • чужой пресет (из скачанного или импортированного квеста)
//                                      → «В библиотеку» (публиковать чужое нельзя).
// ============================================================================

String _hex(int value) =>
    '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Подписи демо-кнопок в превью пресета. Геттер, а не const-список: строки
/// строятся под текущий язык.
List<String> get _previewButtonLabels => [
  tr('Начать историю'),
  tr('Продолжить'),
  tr('В меню'),
];

class PresetDetailsScreen extends ConsumerStatefulWidget {
  final QuestPresetEntry entry;

  const PresetDetailsScreen({super.key, required this.entry});

  @override
  ConsumerState<PresetDetailsScreen> createState() =>
      _PresetDetailsScreenState();
}

class _PresetDetailsScreenState extends ConsumerState<PresetDetailsScreen> {
  bool _publishing = false;
  bool _libraryBusy = false;
  bool _loading = true;

  String? _userId;
  bool _isAdmin = false;
  UserProfile? _currentUser;

  /// Опубликованный ресурс в маркете с тем же названием (если он есть).
  MarketAsset? _marketAsset;
  bool _inLibrary = false;

  QuestPresetEntry get _entry => widget.entry;

  ButtonStyleConfig get _config => widget.entry.config;

  /// Автор опубликованного ресурса — текущий пользователь.
  bool get _isMyPublication =>
      _marketAsset != null && _userId != null && _marketAsset!.authorId == _userId;

  /// Пресет действительно принадлежит текущему пользователю.
  /// Недостаточно флага «квест не из маркета»: у квестов, установленных вручную
  /// из ZIP, его нет, а authorId никто не пишет. Поэтому сверяем по-ID, когда
  /// он есть, иначе — по имени автора квеста с профилем. Ошибка сети/незалогиненность
  /// НЕ дают права публикации: чужой пресет в этом случае остаётся чужим.
  bool get _isMine {
    final user = _currentUser;
    // Не залогинен (или профиль недоступен) — публиковать некому.
    if (user == null) return false;
    if (!_entry.isOwn) return false;

    final author = _entry.authorId;
    if (author != null && author.isNotEmpty) return author == user.id;

    final authorName = _entry.authorName;
    if (authorName == null || authorName.isEmpty) {
      // Автор в конфиге не указан — не считаем пресет своим, пока владелец
      // не впишет своё имя в настройках квеста.
      return false;
    }
    return authorName.trim().toLowerCase() == user.fullName.trim().toLowerCase();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');

    UserProfile? currentUser;
    if (userId != null && userId.isNotEmpty) {
      try {
        currentUser = await ref.read(currentUserProfileProvider.future);
      } catch (_) {}
    }

    var isAdmin = false;
    if (userId != null && userId.isNotEmpty) {
      try {
        final profile = await ref.read(userProfileProvider(userId).future);
        isAdmin = profile.role == 'admin';
      } catch (_) {}
    }

    MarketAsset? match;
    try {
      // Приоритет — сохранённая при публикации привязка «пресет → ассет».
      // Она надёжна даже если название публикации отличается от имени пресета.
      final boundId = await PresetMarketService.publishedAssetId(
        _entry.questId,
        _entry.presetId,
      );
      if (boundId != null && boundId.isNotEmpty) {
        try {
          final bound = await ref.read(apiServiceProvider).get('assets/$boundId');
          if (bound is Map<String, dynamic>) match = MarketAsset.fromJson(bound);
        } catch (_) {
          // 404: публикацию удалили — привязка протухла, забываем её.
          await PresetMarketService.forgetPublishedAssetId(
            _entry.questId,
            _entry.presetId,
          );
        }
      }

      // Фолбэк: матч по названию среди опубликованных.
      if (match == null) {
        final assets = await ref.read(assetListProvider.future);
        final name = _entry.presetName.trim().toLowerCase();
        for (final a in assets) {
          if (a.kind != 'button_preset') continue;
          if (a.title.trim().toLowerCase() == name) {
            match = a;
            break;
          }
        }
      }
    } catch (_) {}

    var inLibrary = false;
    if (match != null) {
      try {
        inLibrary = await MyLibraryService.isInLibrary(match.id);
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _userId = userId;
      _isAdmin = isAdmin;
      _currentUser = currentUser;
      _marketAsset = match;
      _inLibrary = inLibrary;
      _loading = false;
    });
  }

  // ---------------------------------------------------------------------------
  //  Действия
  // ---------------------------------------------------------------------------

  Future<void> _publish() async {
    if (_publishing) return;
    setState(() => _publishing = true);
    try {
      await publishPresetFlow(context, _entry);
      await _load();
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _deleteFromMarket() async {
    final asset = _marketAsset;
    if (asset == null) return;
    final ok = await MarketResourceActions.confirmDelete(
      context,
      ref,
      endpoint: 'assets',
      id: asset.id,
      title: asset.title,
    );
    if (!ok) return;
    ref.invalidate(assetListProvider);
    // Превью удалённого пресета больше не нужно — чистим кэш и привязку.
    await PresetMarketService.clearPreviewCache(asset.id);
    await PresetMarketService.forgetPublishedAssetId(
      _entry.questId,
      _entry.presetId,
    );
    if (!mounted) return;
    setState(() {
      _marketAsset = null;
      _inLibrary = false;
    });
  }

  void _report() {
    final asset = _marketAsset;
    if (asset == null) return;
    showAppDialog(
      context: context,
      builder: (context) => ReportDialog(
        reportedType: 'asset',
        reportedId: asset.id,
        reportedTitle: asset.title,
      ),
    );
  }

  Future<void> _showAdminActions() async {
    final asset = _marketAsset;
    if (asset == null) return;
    await MarketResourceActions.showAdminSheet(
      context,
      ref,
      endpoint: 'assets',
      id: asset.id,
      title: asset.title,
      currentStatus: asset.status,
      onChanged: () {
        ref.invalidate(assetListProvider);
        _load();
      },
      onDeleted: (deletedId) async {
        // Как при удалении автором: чистим кэш превью и привязку пресета.
        await PresetMarketService.clearPreviewCache(deletedId);
        await PresetMarketService.forgetPublishedAssetId(
          _entry.questId,
          _entry.presetId,
        );
        ref.invalidate(assetListProvider);
        if (mounted) _load();
      },
    );
  }

  Future<void> _toggleLibrary() async {
    final asset = _marketAsset;
    if (asset == null || _libraryBusy) return;
    setState(() => _libraryBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_inLibrary) {
        await MyLibraryService.removeAsset(asset.id);
        if (mounted) setState(() => _inLibrary = false);
        messenger.showSnackBar(
          SnackBar(
            content: Text(tr('Удалено из библиотеки')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        final failure = await MyLibraryService.addAsset(asset);
        // Пресет без файла в библиотеке не применить к квесту — не врать про успех.
        if (failure != null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(failure),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        if (mounted) setState(() => _inLibrary = true);
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _libraryBusy = false);
    }
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final config = _config;
    final hasModules = config.hasModuleAssets;
    final radius =
        config.borderRadius ?? (hasModules ? config.moduleSize : 12.0);
    final fillValue = config.useGradient
        ? config.gradientStartColorValue ?? config.fillColorValue
        : config.fillColorValue;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: AdaptiveContent(maxWidth: 900, child: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── HERO HEADER ──────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 300,
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
              if (_marketAsset != null)
                _isMyPublication
                    ? CatalogGlassIconButton(
                        icon: Icons.delete_forever_rounded,
                        tooltip: tr('Удалить из маркета'),
                        color: Colors.redAccent,
                        onPressed: _deleteFromMarket,
                      )
                    : CatalogGlassIconButton(
                        icon: Icons.flag_outlined,
                        tooltip: tr('Пожаловаться'),
                        color: Colors.redAccent,
                        onPressed: _report,
                      ),
              // Модерировать можно только публикацию: у локального пресета
              // нет id в маркете, и админ-действий здесь быть не должно.
              if (_isAdmin && _marketAsset != null)
                CatalogGlassIconButton(
                  icon: Icons.admin_panel_settings_rounded,
                  tooltip: tr('Админ-действия'),
                  color: Colors.greenAccent,
                  onPressed: _showAdminActions,
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
                  // Тёмный «игровой» фон — тот же, что у превью пресетов.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF141B2B), Color(0xFF0D1220)],
                      ),
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 116),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: PresetButtonPreview(
                          style: config,
                          questIdOrNull: _entry.questId,
                          text: _entry.presetName,
                        ),
                      ),
                    ),
                  ),
                  DecoratedBox(
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
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CatalogGenreChip(
                          label: _isMine
                              ? tr('Ваш пресет')
                              : tr('Пресет другого автора'),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _entry.presetName,
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
                ],
              ),
            ),
          ),

          // ── BODY ────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),

                  // Полоса характеристик
                  Row(
                    children: [
                      Expanded(
                        child: CatalogStatTile(
                          value: hasModules ? tr('Модули') : tr('Плоская'),
                          label: tr('Основа'),
                          icon: Icons.widgets_rounded,
                          container: scheme.primaryContainer,
                          onContainer: scheme.onPrimaryContainer,
                          accent: scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CatalogStatTile(
                          value: radius.round().toString(),
                          label: tr('Радиус'),
                          icon: Icons.rounded_corner_rounded,
                          container: scheme.secondaryContainer,
                          onContainer: scheme.onSecondaryContainer,
                          accent: scheme.secondary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CatalogStatTile(
                          value: config.effectiveTextSize.round().toString(),
                          label: tr('Текст'),
                          icon: Icons.text_fields_rounded,
                          container: scheme.tertiaryContainer,
                          onContainer: scheme.onTertiaryContainer,
                          accent: scheme.tertiary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CatalogStatTile(
                          value: '${config.textWeight ?? 600}',
                          label: tr('Вес'),
                          icon: Icons.format_bold_rounded,
                          container: Colors.amber.withOpacity(0.18),
                          onContainer: Colors.amber.shade700,
                          accent: Colors.amber,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  if (_loading)
                    const SizedBox(
                      height: 60,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else
                    _buildCta(scheme, textTheme),

                  const SizedBox(height: 24),

                  CatalogSectionLabel(text: tr('Как выглядит')),
                  const SizedBox(height: 12),
                  PresetPreviewBackdrop(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (i, label) in _previewButtonLabels.indexed)
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: i == _previewButtonLabels.length - 1
                                  ? 0
                                  : 16,
                            ),
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: PresetButtonPreview(
                                  style: config,
                                  questIdOrNull: _entry.questId,
                                  text: label,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  CatalogSectionLabel(text: tr('Цвета')),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _ColorTile(
                          label: tr('Заливка'),
                          hex: _hex(fillValue),
                          color: Color(fillValue),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ColorTile(
                          label: tr('Обводка'),
                          hex: _hex(config.borderColorValue),
                          color: config.borderColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ColorTile(
                          label: tr('Текст'),
                          hex: _hex(config.textColorValue),
                          color: config.textColor,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      )),
    );
  }

  // ---------------------------------------------------------------------------
  //  CTA — зависит от того, чей пресет и опубликован ли он
  // ---------------------------------------------------------------------------

  Widget _buildCta(ColorScheme scheme, TextTheme textTheme) {
    // Свой пресет уже опубликован — публиковать снова нечего.
    if (_isMyPublication) {
      return _CtaTile(
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer,
        icon: Icons.check_circle_rounded,
        title: tr('Уже в маркете'),
        subtitle: tr('удалить можно кнопкой в шапке'),
      );
    }

    // Не залогинен — публиковать некому, даже если пресет создан здесь.
    if (_currentUser == null) {
      return _CtaTile(
        background: scheme.surfaceContainerHigh,
        foreground: scheme.onSurfaceVariant,
        icon: Icons.login_rounded,
        title: tr('Войдите в аккаунт'),
        subtitle: tr('публикация доступна после входа'),
      );
    }

    // Пресет пришёл вместе с чужим квестом — публиковать его нельзя.
    if (!_isMine) {
      if (_marketAsset == null) {
        return _CtaTile(
          background: scheme.surfaceContainerHigh,
          foreground: scheme.onSurfaceVariant,
          icon: Icons.inventory_2_rounded,
          title: tr('Пресет из квеста'),
          subtitle: tr('уже на устройстве'),
        );
      }
      return Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _libraryBusy ? null : _toggleLibrary,
          child: SizedBox(
            height: 60,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_libraryBusy)
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
                      tr('пресет другого автора'),
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

    // Свой пресет, ещё не в маркете.
    return Material(
      color: scheme.primary,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _publishing ? null : _publish,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_publishing)
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
                  Icons.cloud_upload_rounded,
                  color: scheme.onPrimary,
                  size: 24,
                ),
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Опубликовать'),
                    style: textTheme.titleMedium?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    tr('в маркете сообщества'),
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
}

// ============================================================================
//  ИНФОРМАЦИОННАЯ ПЛИТКА CTA (когда действие недоступно)
// ============================================================================

class _CtaTile extends StatelessWidget {
  final Color background;
  final Color foreground;
  final IconData icon;
  final String title;
  final String subtitle;

  const _CtaTile({
    required this.background,
    required this.foreground,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: foreground, size: 24),
          const SizedBox(width: 10),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: textTheme.titleMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                subtitle,
                style: textTheme.labelSmall?.copyWith(
                  color: foreground.withOpacity(0.82),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  ПЛИТКА ЦВЕТА
// ============================================================================

class _ColorTile extends StatelessWidget {
  final String label;
  final String hex;
  final Color color;

  const _ColorTile({
    required this.label,
    required this.hex,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              hex,
              maxLines: 1,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
