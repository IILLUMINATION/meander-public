import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/guide.dart';

/// Загрузка гайда из ассетов. Сеть не участвует: всё лежит в бандле, поэтому
/// гайд открывается в самолёте и не зависит от бэкенда.
///
/// Язык ищется по цепочке: точный код (`pt_br`), базовый (`pt`), английский,
/// русский. Так же работает словарь интерфейса: недопереведённый гайд
/// показывается по-английски, а не пропадает.
class GuideContentLoader {
  GuideContentLoader._();

  static final Map<String, Future<GuideContent?>> _cache = {};

  static Future<GuideContent?> load(GuideInfo info, String languageCode) {
    final key = '${info.id}|${languageCode.toLowerCase()}';
    return _cache.putIfAbsent(key, () => _load(info, languageCode));
  }

  static List<String> candidateCodes(String languageCode) {
    final normalized = languageCode.trim().toLowerCase().replaceAll('_', '-');
    final codes = <String>[];
    void add(String value) {
      if (value.isNotEmpty && !codes.contains(value)) codes.add(value);
    }

    if (normalized.isNotEmpty) {
      add(normalized.replaceAll('-', '_'));
      add(normalized.split('-').first);
    }
    add('en');
    add('ru');
    return codes;
  }

  static Future<GuideContent?> _load(
    GuideInfo info,
    String languageCode,
  ) async {
    for (final code in candidateCodes(languageCode)) {
      final base = 'assets/guides/${info.id}/$code';
      final rawJson = await _readString('$base.json');
      if (rawJson == null) continue;

      final article = await _readString('$base.md') ?? '';
      try {
        final decoded = jsonDecode(rawJson);
        if (decoded is! Map) continue;
        final content = GuideContent.fromJson(
          Map<String, dynamic>.from(decoded),
          languageCode: code,
          article: article,
        );
        if (content != null) return content;
      } catch (_) {
        // Битый файл не должен ронять экран: пробуем следующий язык.
      }
    }
    return null;
  }

  static Future<String?> _readString(String path) async {
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      return null;
    }
  }

  /// Для тестов и горячей перезагрузки контента.
  static void clearCache() => _cache.clear();
}
