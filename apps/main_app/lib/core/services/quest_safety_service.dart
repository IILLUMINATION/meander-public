import 'dart:io';
import 'package:flutter/foundation.dart';


import 'package:canvas_app/core/services/api_service.dart';
import 'package:mnd_core/models/quest_descriptor.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_core/utils/quest_paths.dart';

/// Результат локальной проверки URL перед открытием ссылки или запросом.
class NetworkUrlDecision {
  final bool allowed;
  final String? reason;

  const NetworkUrlDecision._(this.allowed, this.reason);

  const NetworkUrlDecision.allow() : this._(true, null);
  const NetworkUrlDecision.block(String reason) : this._(false, reason);
}

/// Локальная политика безопасности сетевых блоков.
///
/// Список намеренно поставляется вместе с приложением: он работает без сети
/// и не зависит от того, что вернул автор квеста.
class QuestNetworkSafety {
  static const _blockedHostMarkers = <String>[
    'iplogger',
    'iplog.co',
    '2no.co',
    'yip.su',
    'grabify',
    'webhook.site',
    'requestbin',
    'requestcatcher',
    'burpcollaborator',
    'interactsh',
    'oast.',
    'canarytokens',
    'dnslog',
    'ceye.io',
  ];

  static NetworkUrlDecision checkUrl(String raw) {
    final value = raw.trim();
    final uri = Uri.tryParse(value);
    if (uri == null) {
      return const NetworkUrlDecision.block('некорректный URL');
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return NetworkUrlDecision.block('схема «${uri.scheme}» запрещена');
    }
    if (uri.userInfo.isNotEmpty) {
      return const NetworkUrlDecision.block('URL с учётными данными запрещён');
    }

    final host = uri.host.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.isEmpty) {
      return const NetworkUrlDecision.block('URL без хоста');
    }

    if (_isBlockedHost(host)) {
      return const NetworkUrlDecision.block(
        'локальный или служебный хост запрещён',
      );
    }

    if (_blockedHostMarkers.any(host.contains)) {
      return const NetworkUrlDecision.block('хост в локальном blacklist');
    }

    final ip = InternetAddress.tryParse(host);
    if (ip != null && _isBlockedIp(ip)) {
      return const NetworkUrlDecision.block(
        'приватный или служебный IP-адрес запрещён',
      );
    }

    return const NetworkUrlDecision.allow();
  }

  static bool _isBlockedHost(String host) {
    return host == 'localhost' ||
        host == 'localhost.localdomain' ||
        host == 'metadata.google.internal' ||
        host == 'metadata.google.com' ||
        host == 'instance-data.ec2.internal' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.test');
  }

  static bool _isBlockedIp(InternetAddress ip) {
    final bytes = ip.rawAddress;
    if (bytes.length == 4) {
      final a = bytes[0];
      final b = bytes[1];
      final c = bytes[2];
      return a == 0 ||
          a == 10 ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 127) ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 0 && c == 0) ||
          (a == 192 && b == 0 && c == 2) ||
          (a == 192 && b == 168) ||
          (a == 198 && b >= 18 && b <= 19) ||
          (a == 198 && b == 51 && c == 100) ||
          (a == 203 && b == 0 && c == 113) ||
          (a >= 224);
    }
    if (bytes.length == 16) {
      final isLoopback =
          bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
      final isUnspecified = bytes.every((byte) => byte == 0);
      final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
      final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
      final isMulticast = bytes[0] == 0xff;
      return isLoopback ||
          isUnspecified ||
          isUniqueLocal ||
          isLinkLocal ||
          isMulticast;
    }
    return false;
  }
}

class QuestSafetyReport {
  final int internetBlockCount;
  final int blockedUrlCount;
  final DateTime? lastEditedAt;
  final String? questVersion;

  /// Информационный флаг; verified-статус не отключает предупреждение.
  final bool authorIsVerified;

  const QuestSafetyReport({
    this.internetBlockCount = 0,
    this.blockedUrlCount = 0,
    this.lastEditedAt,
    this.questVersion,
    this.authorIsVerified = false,
  });

  bool get hasInternetBlocks => internetBlockCount > 0;
  bool get hasBlockedUrls => blockedUrlCount > 0;

  bool get isStale {
    final date = lastEditedAt;
    if (date == null) return false;
    final age = DateTime.now().toUtc().difference(date.toUtc());
    return age >= const Duration(days: 180);
  }

  bool get shouldWarnAboutInternet => hasInternetBlocks;
  bool get shouldShowWarning => shouldWarnAboutInternet || isStale;
}

/// Анализирует локальный квест до запуска игровой сессии.
///
/// Отчёт кэшируется по отпечатку квеста (mtime `config.json` + mtime и
/// размер списков `scripts/` и `_internal_scripts/`): повторный запуск
/// того же квеста не перечитывает сотни файлов с диска. Любая правка в
/// редакторе меняет mtime — отпечаток меняется — кэш инвалидируется.
class QuestSafetyService {
  const QuestSafetyService();

  /// questId → (отпечаток, отчёт). Readonly-кэш в памяти процесса.
  static final Map<String, (String, QuestSafetyReport)> _reportCache = {};

  Future<QuestSafetyReport> inspect({
    required Quest quest,
    required ApiService api,
  }) async {
    final inspectStart = DateTime.now();
    void stageLog(String stage) => debugPrint(
          '[Perf][Safety] $stage: '
          '${DateTime.now().difference(inspectStart).inMilliseconds}ms',
        );

    final fingerprint = await _questFingerprint(quest.id);
    final cached = _reportCache[quest.id];
    if (cached != null && cached.$1 == fingerprint) {
      stageLog('cache hit');
      return cached.$2;
    }

    final documents = <Map<String, dynamic>>[];
    final config = await _readJsonIfExists(QuestPaths.config(quest.id));
    stageLog('config');
    if (config != null) documents.add(config);

    for (final path in [
      QuestPaths.nodesLegacy(quest.id),
      QuestPaths.nodesCanonical(quest.id),
    ]) {
      final nodes = await _readJsonIfExists(path);
      if (nodes != null) documents.add(nodes);
    }
    stageLog('nodes');

    for (final folder in const ['scripts', '_internal_scripts']) {
      final files = await _listJsonFiles(
        QuestPaths.questFile(quest.id, folder),
      );
      for (final file in files) {
        final script = await _readJsonIfExists(
          QuestPaths.questFile(quest.id, '$folder/$file'),
        );
        if (script != null) documents.add(script);
      }
    }
    stageLog('scripts loaded (${documents.length} docs)');

    var internetBlocks = 0;
    var blockedUrls = 0;
    for (final document in documents) {
      final counts = _inspectValue(document);
      internetBlocks += counts.$1;
      blockedUrls += counts.$2;
    }
    stageLog('visited: internetBlocks=$internetBlocks');

    final verified = internetBlocks > 0
        ? await _resolveAuthorVerification(quest, api)
        : false;
    stageLog('verification resolved: $verified');

    final configDate = _parseDate(
      config?['marketUpdatedAt'] ??
          config?['market_updated_at'] ??
          config?['updatedAt'] ??
          config?['updated_at'] ??
          config?['lastEditedAt'] ??
          config?['last_edited_at'] ??
          config?['updated'] ??
          config?['created'] ??
          config?['created_at'],
    );

    final report = QuestSafetyReport(
      internetBlockCount: internetBlocks,
      blockedUrlCount: blockedUrls,
      // Для локальных квестов серверной даты нет: дата создания —
      // безопасный fallback, чтобы старый квест тоже получил предупреждение.
      lastEditedAt:
          configDate ??
          quest.lastEditedAt ??
          quest.marketUpdatedAt ??
          quest.created,
      questVersion: quest.marketVersion ?? quest.version,
      authorIsVerified: verified,
    );
    // Проверенный по отпечатку отчёт годен до следующей правки квеста.
    if (fingerprint != null) {
      _reportCache[quest.id] = (fingerprint, report);
    }
    return report;
  }

  /// Отпечаток состояния квеста на диске: mtime/size `config.json`,
  /// mtime/size/состав каталогов `scripts` и `_internal_scripts`.
  /// `null` — если каталога квеста нет (кэш не используем).
  Future<String?> _questFingerprint(String questId) async {
    try {
      final parts = <String>[];
      final configPath = await FileStorage.getFilePath(
        QuestPaths.config(questId),
      );
      final configFile = File(configPath);
      if (await configFile.exists()) {
        final stat = await configFile.stat();
        parts.add('config:${stat.modified.millisecondsSinceEpoch}:${stat.size}');
      } else {
        return null;
      }
      for (final folder in const ['scripts', '_internal_scripts']) {
        final folderStat =
            await _dirStat(await FileStorage.getFilePath(
          QuestPaths.questFile(questId, folder),
        ));
        parts.add('$folder:${folderStat ?? 'missing'}');
      }
      return parts.join('|');
    } catch (_) {
      return null;
    }
  }

  /// mtime каталога + отсортированный (имя, mtime, size) его .json-файлов.
  /// Точечные правки файлов видны без чтения содержимого.
  Future<String?> _dirStat(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return null;
      final dirStat = await dir.stat();
      final entries = <String>[];
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final stat = await entity.stat();
        entries.add(
          '${entity.uri.pathSegments.last}'
          ':${stat.modified.millisecondsSinceEpoch}:${stat.size}',
        );
      }
      return '${dirStat.modified.millisecondsSinceEpoch};'
          '${entries.length};${entries.join(',')}';
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _readJsonIfExists(String path) async {
    try {
      if (!await FileStorage.exists(path)) return null;
      return await FileStorage.readJsonFile(path);
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _listJsonFiles(String path) async {
    try {
      return await FileStorage.listFiles(path, extension: '.json');
    } catch (_) {
      return const [];
    }
  }

  (int, int) _inspectValue(dynamic value) {
    var internetBlocks = 0;
    var blockedUrls = 0;

    void visit(dynamic current) {
      if (current is List) {
        for (final item in current) {
          visit(item);
        }
        return;
      }
      if (current is! Map) return;

      final type = current['type']?.toString().toLowerCase();
      if (type == 'open_link' || type == 'http_request') {
        internetBlocks++;
        final rawUrl = current['url']?.toString().trim();
        if (rawUrl != null &&
            rawUrl.isNotEmpty &&
            !QuestNetworkSafety.checkUrl(rawUrl).allowed) {
          blockedUrls++;
        }
      }
      for (final child in current.values) {
        visit(child);
      }
    }

    visit(value);
    return (internetBlocks, blockedUrls);
  }

  Future<bool> _resolveAuthorVerification(Quest quest, ApiService api) async {
    try {
      String? authorId = quest.authorId;
      if (authorId == null || authorId.trim().isEmpty) {
        final marketId = quest.marketQuestId;
        if (marketId == null || marketId.trim().isEmpty) return false;
        final market = await api
            .get('quests/$marketId')
            .timeout(const Duration(seconds: 4));
        if (market is Map) {
          authorId = market['author_id']?.toString();
        }
      }
      if (authorId == null || authorId.trim().isEmpty) return false;

      final profile = await api
          .get('profiles/${authorId.trim()}')
          .timeout(const Duration(seconds: 4));
      return profile is Map && _parseBool(profile['is_verified']);
    } catch (_) {
      // Онлайн-ошибка не меняет локальную политику и не ломает запуск.
      return false;
    }
  }

  static bool _parseBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1' || normalized == 'yes';
    }
    return false;
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed;

    final localized = RegExp(
      r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$',
    ).firstMatch(raw);
    if (localized == null) return null;
    return DateTime.tryParse(
      '${localized.group(3)}-${localized.group(2)}-${localized.group(1)}',
    );
  }
}
