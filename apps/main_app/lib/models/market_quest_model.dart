import 'package:flutter/foundation.dart';

/// Уровни каталога. 1 — лучшие, отобраны вручную; 2 — прошедшие модерацию;
/// 3 — демо. Числа совпадают с бэкендом и constraint'ом в БД.
const int kMarketTierBest = 1;
const int kMarketTierModerated = 2;
const int kMarketTierDemo = 3;

@immutable
class MarketQuest {
  final String id;
  final String title;
  final String downloadUrl;
  final String? previewImageUrl;
  final String? description;
  final String? authorName;
  final String? authorId;

  /// id стиля ника автора из каталога оформления профиля.
  final String? authorNameStyle;
  final int downloadsCount;

  /// Суммарные просмотры страницы квеста (без просмотров автора).
  final int viewsCount;
  final int likeCount;
  final int dislikeCount;
  final double averageRating;
  final String version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? status;
  final String? moderatorComment;
  final String? category; // Оставляем для совместимости (основной жанр)
  final List<String> genres; // НОВОЕ: Список жанров
  final bool? isFeatured;
  final int? questSizeBytes;
  final int? estimatedPlaytime; // в минутах
  final bool authorIsVerified;
  final bool isDemo;
  final bool isNsfw;

  /// Уровень каталога: [kMarketTierBest], [kMarketTierModerated] или
  /// [kMarketTierDemo]. Сервер присылает `market_tier`; старый бэкенд поля не
  /// знает, и тогда уровень выводится из флага демо — так клиент не показывает
  /// пустой раздел «Лучшие» до выкатки серверной части.
  final int marketTier;

  /// Язык, на котором написан квест (`config.language`), или `null`, если автор
  /// его не указал. Маркет первыми показывает квесты на языке игрока.
  final String? language;

  const MarketQuest({
    required this.id,
    required this.title,
    required this.downloadUrl,
    this.previewImageUrl,
    this.description,
    this.authorName,
    this.authorId,
    this.authorNameStyle,
    required this.downloadsCount,
    this.viewsCount = 0,
    required this.likeCount,
    required this.dislikeCount,
    required this.averageRating,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.status,
    this.moderatorComment,
    this.category,
    this.genres = const [], // НОВОЕ
    this.isFeatured,
    this.questSizeBytes,
    this.estimatedPlaytime,
    this.authorIsVerified = false,
    this.isDemo = false,
    this.isNsfw = false,
    this.marketTier = kMarketTierModerated,
    this.language,
  });

  bool get isBest => marketTier == kMarketTierBest;

  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  static String? _parseLanguage(dynamic value) {
    if (value == null) return null;
    final result = value.toString().trim();
    return result.isEmpty ? null : result;
  }

  static bool _parseBool(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.toLowerCase().trim();
      return v == 'true' || v == '1' || v == 'yes';
    }
    return false;
  }

  /// Уровень из ответа сервера. Инвариант тот же, что у constraint'а в БД:
  /// демо всегда третий, не-демо — первый или второй. Значения вне 1..3
  /// (старый сервер, мусор) не роняют карточку, а дают безопасный второй.
  static int _parseMarketTier(dynamic value, {required bool isDemo}) {
    if (isDemo) return kMarketTierDemo;
    final raw = value is num
        ? value.toInt()
        : int.tryParse(value?.toString().trim() ?? '');
    return raw == kMarketTierBest ? kMarketTierBest : kMarketTierModerated;
  }

  factory MarketQuest.fromJson(Map<String, dynamic> json) {
    DateTime? safeParseDate(String? dateString) {
      if (dateString == null) return null;
      return DateTime.tryParse(dateString);
    }

    // Парсинг жанров из JSON (массив строк)
    List<String> parsedGenres = [];
    if (json['genres'] != null) {
      if (json['genres'] is List) {
        parsedGenres = (json['genres'] as List)
            .map((e) => e.toString())
            .toList();
      } else if (json['genres'] is String) {
        // На случай если пришла строка '{Fantasy,Horror}' от Postgres
        final str = json['genres'] as String;
        parsedGenres = str
            .replaceAll('{', '')
            .replaceAll('}', '')
            .split(',')
            .map((e) => e.trim().replaceAll('"', ''))
            .where((e) => e.isNotEmpty)
            .toList();
      }
    }

    // Если жанров нет, но есть старая категория - используем её
    if (parsedGenres.isEmpty && json['category'] != null) {
      parsedGenres.add(json['category'].toString());
    }

    final isDemo = _parseBool(json['is_demo'] ?? json['demo']);

    return MarketQuest(
      id: json['id'] as String,
      title: json['title'] as String,
      downloadUrl: json['download_url'] as String,
      previewImageUrl: json['preview_image_url'] as String?,
      description: json['description'] as String?,
      authorName: json['author_name'] as String?,
      authorId: json['author_id'] as String?,
      authorNameStyle: json['author_name_style'] as String?,
      downloadsCount: _parseInt(json['downloads_count']),
      viewsCount: _parseInt(json['views_count']),
      likeCount: _parseInt(json['like_count']),
      dislikeCount: _parseInt(json['dislike_count']),
      averageRating: _parseDouble(json['average_rating']),
      version: json['version'] as String? ?? '1.0.0',
      createdAt: safeParseDate(json['created_at'] as String) ?? DateTime(1970),
      updatedAt: safeParseDate(json['updated_at'] as String) ?? DateTime(1970),
      status: json['status'] as String?,
      moderatorComment: json['moderator_comment'] as String?,
      category: json['category'] as String?,
      genres: parsedGenres, // НОВОЕ
      isFeatured: json['is_featured'] as bool?,
      questSizeBytes: _parseInt(json['quest_size_bytes']),
      estimatedPlaytime: _parseInt(json['estimated_playtime']),
      authorIsVerified: _parseBool(json['author_is_verified']),
      isDemo: isDemo,
      isNsfw: _parseBool(json['is_nsfw']),
      marketTier: _parseMarketTier(json['market_tier'], isDemo: isDemo),
      language: _parseLanguage(json['language']),
    );
  }
}
