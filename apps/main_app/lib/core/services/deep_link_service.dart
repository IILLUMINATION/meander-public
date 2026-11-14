import 'dart:async';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:canvas_app/core/services/async_import_service.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/features/quests/screens/quest_details_screen.dart';
import 'package:canvas_app/features/community/screens/post_comments_screen.dart';
import 'package:canvas_app/models/wall_post_model.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:canvas_app/features/channels/screens/channel_screen.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class DeepLinkService {
  static final DeepLinkService _instance = DeepLinkService._internal();
  factory DeepLinkService() => _instance;
  DeepLinkService._internal();

  final AppLinks _appLinks = AppLinks();
  static const MethodChannel _fileResolverChannel = MethodChannel(
    'meander/file_resolver',
  );
  StreamSubscription<Uri>? _sub;
  Uri? _pendingUri;
  bool _isReady = false;
  bool _initialLinkChecked = false;

  void init() {
    debugPrint('📱 DeepLinkService: Initializing...');
    _sub = _appLinks.uriLinkStream.listen(
      (uri) {
        debugPrint('📱 DeepLinkService: Stream received link: $uri');
        _handleLink(uri);
      },
      onError: (err) {
        debugPrint("DeepLinkService Error: $err");
      },
    );
    _checkInitialLink();
  }

  Future<void> _checkInitialLink() async {
    try {
      debugPrint('📱 DeepLinkService: Checking initial link...');
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        debugPrint('📱 DeepLinkService: Found initial link: $uri');
        _handleLink(uri);
      } else {
        debugPrint('📱 DeepLinkService: No initial link found');
      }
    } catch (e) {
      debugPrint('📱 DeepLinkService: Error checking initial link: $e');
    } finally {
      _initialLinkChecked = true;
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  void signalReady() {
    debugPrint('📱 DeepLinkService: Signal ready called');
    _isReady = true;
    if (_pendingUri != null) {
      debugPrint('📱 DeepLinkService: Processing pending URI: $_pendingUri');
      final uri = _pendingUri!;
      _pendingUri = null;
      _navigateTo(uri);
    } else if (!_initialLinkChecked) {
      debugPrint(
        '📱 DeepLinkService: No pending URI to process yet; waiting for initial link check',
      );
    } else {
      debugPrint('📱 DeepLinkService: No pending URI to process');
    }
  }

  void _handleLink(Uri uri) {
    debugPrint('📱 DeepLinkService: Received link: $uri');
    if (!_isReady) {
      debugPrint('📱 DeepLinkService: App not ready, storing pending URI');
      _pendingUri = uri;
      return;
    }
    debugPrint('📱 DeepLinkService: Navigating to link');
    _navigateTo(uri);
  }

  /// Ссылка, нажатая внутри приложения (markdown в посте, описании квеста).
  /// Тот же маршрут, что у системного deep link: своя страница должна
  /// открываться здесь, а не уезжать в браузер.
  void openUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    _navigateTo(uri);
  }

  void _navigateTo(Uri uri) {
    void performNavigation() async {
      final nav = navigatorKey.currentState;
      if (nav == null) {
        // Navigator not ready yet, retry shortly
        Future.delayed(const Duration(milliseconds: 100), performNavigation);
        return;
      }

      // Local/shared .mnd import links (Android file/content intents, desktop file links)
      if (await _tryHandleQuestImportUri(nav, uri)) {
        return;
      }

      // Normalize path segments
      List<String> segments = List.of(uri.pathSegments);
      if (segments.isEmpty && uri.host.isNotEmpty) {
        segments = [uri.host];
      }

      if (segments.isNotEmpty && segments[0] == 'share') {
        segments = segments.sublist(1);
      }

      String? type;
      String? id;

      if (segments.isNotEmpty) {
        type = segments[0];
        if (segments.length > 1) id = segments[1];
      }

      // Handle custom scheme like meander://profile/{id} or meander://quest/{id}
      if (uri.host == 'profile' || uri.host == 'quest' || uri.host == 'post') {
        type = uri.host;
        if (uri.pathSegments.isNotEmpty) {
          id = uri.pathSegments[0];
        }
      }

      // If type is not recognized but host is, prefer host
      if (type != 'quest' && type != 'profile' && type != 'post') {
        if (uri.host == 'profile' || uri.host == 'quest' || uri.host == 'post') {
          type = uri.host;
          if (uri.pathSegments.isNotEmpty) {
            id = uri.pathSegments[0];
          }
        }
      }

      // Fallback to query params
      id ??= uri.queryParameters['id'];

      if (type == 'quest' && id != null && id.isNotEmpty) {
        nav.push(
          MaterialPageRoute(
            builder: (_) => MarketQuestLoaderScreen(questId: id!),
          ),
        );
        return;
      }

      if (type == 'profile' && id != null && id.isNotEmpty) {
        nav.push(MaterialPageRoute(builder: (_) => ProfileScreen(userId: id!)));
        return;
      }
      
      if (type == 'post' && id != null && id.isNotEmpty) {
        nav.push(
          MaterialPageRoute(builder: (_) => PostLinkLoaderScreen(postId: id!)),
        );
        return;
      }

      // Канал живёт по адресу `/channels/<id>`; в шаринге он приходит так же,
      // как пост и профиль, — без этого ссылка открывалась в браузере.
      if ((type == 'channel' || type == 'channels') &&
          id != null &&
          id.isNotEmpty) {
        nav.push(MaterialPageRoute(builder: (_) => ChannelScreen(channelId: id!)));
        return;
      }

      // Ни один свой маршрут не подошёл. Раньше тап проваливался в пустоту:
      // pointsToMeander забирает у браузера любой адрес на нашем хосте, а
      // разбирает из них только /share/<тип>/<uuid> — ссылка на главную сайта
      // или на любой другой путь выглядела живой, но не делала ничего.
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('📱 DeepLinkService: external launch failed: $e');
        }
      }
    }

    // Start navigation
    performNavigation();
  }

  Future<bool> _tryHandleQuestImportUri(NavigatorState nav, Uri uri) async {
    if (!_looksLikeImportUri(uri)) return false;

    try {
      final localPath = await _resolveImportFilePath(uri);
      if (localPath == null || localPath.isEmpty) {
        _showMessage(nav, tr('Не удалось получить доступ к файлу .mnd'));
        return true;
      }

      final importedQuestId = await AsyncImportService.importFromFile(
        localPath,
      );
      if (importedQuestId == null || importedQuestId.isEmpty) {
        _showMessage(nav, tr('Импорт отменён'));
        return true;
      }

      _showMessage(nav, tr('Квест импортирован'));
      nav.push(
        MaterialPageRoute(
          builder: (_) => QuestDetailsScreen(questId: importedQuestId),
        ),
      );
      return true;
    } catch (e) {
      _showMessage(nav, trf('Ошибка импорта: {p0}', {'p0': friendlyError(e)}));
      return true;
    }
  }

  bool _looksLikeImportUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final asString = uri.toString().toLowerCase();
    if (asString.endsWith('.mnd')) return true;
    if (uri.path.toLowerCase().endsWith('.mnd')) return true;
    if (scheme == 'content' || scheme == 'file') return true;
    return false;
  }

  Future<String?> _resolveImportFilePath(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();

    if (scheme == 'file') {
      return uri.toFilePath();
    }

    if (scheme == 'content') {
      final resolved = await _fileResolverChannel.invokeMethod<String>(
        'resolveSharedFile',
        {'uri': uri.toString()},
      );
      return resolved;
    }

    final rawPath = uri.path;
    if (rawPath.isNotEmpty) {
      final candidate = File(rawPath);
      if (await candidate.exists()) return candidate.path;
    }
    return null;
  }

  void _showMessage(NavigatorState nav, String text) {
    final messenger = ScaffoldMessenger.maybeOf(nav.context);
    messenger?.showSnackBar(
      SnackBar(content: Text(text), backgroundColor: const Color(0xFF2A2A2A)),
    );
  }
}

final _communityPostProvider = FutureProvider.family<WallPost, String>((ref, postId) async {
  final api = ref.read(apiServiceProvider);
  final prefs = await SharedPreferences.getInstance();
  final viewerId = prefs.getString('user_id') ?? '';
  final response = await api.get(
    'api/community/post/$postId',
    queryParams: {'viewer_id': viewerId},
  );
  return WallPost.fromJson(response);
});

class PostLinkLoaderScreen extends ConsumerWidget {
  final String postId;
  const PostLinkLoaderScreen({super.key, required this.postId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postAsync = ref.watch(_communityPostProvider(postId));
    final scheme = Theme.of(context).colorScheme;

    return postAsync.when(
      loading: () => Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(backgroundColor: scheme.surface),
        body: Center(child: CircularProgressIndicator(color: scheme.primary)),
      ),
      error: (err, stack) => Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(backgroundColor: scheme.surface),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 48, color: scheme.error),
                const SizedBox(height: 16),
                Text(
                  tr('Не удалось загрузить пост'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.tonal(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr('Назад')),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: () => ref.invalidate(_communityPostProvider(postId)),
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr('Повторить')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      data: (post) => PostCommentsScreen(post: post),
    );
  }
}
