import 'dart:convert';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:flutter/foundation.dart';

import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';

/// Стиль баннера за шапкой профиля. Только пресеты (id из реестра).
@immutable
class ProfileBannerStyle {
  final String type; // 'preset'
  final String id;

  const ProfileBannerStyle({this.type = 'preset', required this.id});

  factory ProfileBannerStyle.fromJson(Map<String, dynamic> json) {
    return ProfileBannerStyle(
      type: json['type'] as String? ?? 'preset',
      id: json['id'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'type': type, 'id': id};
}

/// Ссылка на соцсеть пользователя.
@immutable
class SocialLink {
  final String platform; // telegram, youtube, vk, ...
  final String url;

  const SocialLink({required this.platform, required this.url});

  factory SocialLink.fromJson(Map<String, dynamic> json) => SocialLink(
    platform: (json['platform'] as String? ?? '').toLowerCase(),
    url: json['url'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'platform': platform, 'url': url};

  SocialLink copyWith({String? platform, String? url}) =>
      SocialLink(platform: platform ?? this.platform, url: url ?? this.url);
}

class UserProfile {
  final String id;
  final String fullName;

  /// @адрес профиля; null — ещё не задан или сервер старый.
  final String? username;
  final String? avatarUrl;
  final DateTime createdAt;
  final int followersCount;
  final int followingCount;
  final String? bio;
  final bool isVerified;
  final String role;

  // Новые поля для стрика
  final int streakCount;
  final DateTime? lastActivityDate;
  final DateTime? lastSeenAt;

  // Модерация и фильтры
  final bool showNsfw;

  // Тихие часы для пушей
  final bool quietHoursEnabled;
  final int? timezoneOffset; // минуты от UTC

  // Суммарные лайки и скачивания
  final int totalLikes;
  final int totalDownloads;
  final int totalPlaytimeSeconds;
  final int totalQuestsPlaytimeSeconds;

  // НОВОЕ: стиль баннера и соцсети
  final ProfileBannerStyle? bannerStyle;
  final List<SocialLink> socialLinks;

  /// Надетая косметика («Оформление профиля»). Пустой, если бэк ещё не
  /// присылает поле — старые версии сервера не должны ломать шапку.
  final EquippedCosmetics cosmetics;

  UserProfile({
    required this.id,
    required this.fullName,
    this.username,
    this.avatarUrl,
    required this.createdAt,
    required this.followersCount,
    required this.followingCount,
    this.bio,
    required this.isVerified,
    required this.role,
    this.streakCount = 0,
    this.lastActivityDate,
    this.lastSeenAt,
    this.showNsfw = false,
    this.quietHoursEnabled = true,
    this.timezoneOffset,
    this.totalLikes = 0,
    this.totalDownloads = 0,
    this.totalPlaytimeSeconds = 0,
    this.totalQuestsPlaytimeSeconds = 0,
    this.bannerStyle,
    this.socialLinks = const [],
    this.cosmetics = EquippedCosmetics.none,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    // Парсинг banner_style: PG отдаёт JSONB как объект напрямую
    final rawBanner = json['banner_style'];
    ProfileBannerStyle? bannerStyle;
    if (rawBanner is Map<String, dynamic>) {
      bannerStyle = ProfileBannerStyle.fromJson(rawBanner);
    } else if (rawBanner is String && rawBanner.trim().isNotEmpty) {
      // Строка вместо объекта: старые строки в БД и ответы без jsonb-декодирования.
      try {
        final decoded = jsonDecode(rawBanner);
        if (decoded is Map<String, dynamic>) {
          bannerStyle = ProfileBannerStyle.fromJson(decoded);
        }
      } catch (_) {}
    }

    // Парсинг social_links
    final rawSocials = json['social_links'];
    final socials = <SocialLink>[];
    if (rawSocials is List) {
      for (final item in rawSocials) {
        if (item is Map<String, dynamic>) {
          final link = SocialLink.fromJson(item);
          if (link.platform.isNotEmpty && link.url.isNotEmpty) {
            socials.add(link);
          }
        }
      }
    }

    return UserProfile(
      id: json['id'] as String,
      fullName: json['full_name'] as String? ?? tr('Пользователь'),
      username: switch (json['username']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      avatarUrl: json['avatar_url'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      followersCount: int.tryParse(json['followers_count'].toString()) ?? 0,
      followingCount: int.tryParse(json['following_count'].toString()) ?? 0,
      bio: json['bio'] as String?,
      isVerified: json['is_verified'] as bool? ?? false,
      role: json['role'] as String? ?? 'user',
      streakCount: int.tryParse(json['streak_count']?.toString() ?? '0') ?? 0,
      lastActivityDate: json['last_activity_date'] != null
          ? DateTime.tryParse(json['last_activity_date'] as String)
          : null,
      lastSeenAt: json['last_seen_at'] != null
          ? DateTime.tryParse(json['last_seen_at'] as String)
          : null,
      showNsfw: json['show_nsfw'] as bool? ?? false,
      quietHoursEnabled: json['quiet_hours_enabled'] as bool? ?? true,
      timezoneOffset: json['timezone_offset'] != null
          ? (json['timezone_offset'] as num).toInt()
          : null,
      totalLikes: int.tryParse(json['total_likes']?.toString() ?? '0') ?? 0,
      totalDownloads:
          int.tryParse(json['total_downloads']?.toString() ?? '0') ?? 0,
      totalPlaytimeSeconds: 
          int.tryParse(json['total_playtime_seconds']?.toString() ?? '0') ?? 0,
      totalQuestsPlaytimeSeconds:
          int.tryParse(json['total_quests_playtime_seconds']?.toString() ?? '0') ?? 0,
      bannerStyle: bannerStyle,
      socialLinks: socials,
      cosmetics: EquippedCosmetics.fromJson(json['cosmetics']),
    );
  }
}
