import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/async_import_service.dart';
import 'package:canvas_app/core/services/cloud_sync_state.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mnd_core/models/quest_descriptor.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/core/utils/error_text.dart';

/// =============================================================================
///   Meander Cloud Sync — клиент.
/// =============================================================================
///   Заменяет (или дополняет) GitHub-синхронизацию. Использует серверный API
///   `/cloud-sync/*` и не требует пользовательского токена/репозитория.
/// =============================================================================

/// Уровень доступа к облаку, выдаваемый сервером.
enum CloudSyncTier { none, starter, free, creator, pro, admin }

CloudSyncTier _parseTier(String? raw) {
  switch (raw) {
    case 'starter':
      return CloudSyncTier.starter;
    case 'free':
      return CloudSyncTier.free;
    case 'creator':
      return CloudSyncTier.creator;
    case 'pro':
      return CloudSyncTier.pro;
    case 'admin':
      return CloudSyncTier.admin;
    default:
      return CloudSyncTier.none;
  }
}

class CloudUpgradeHint {
  final CloudSyncTier target;
  final String text;
  final double? progress;

  const CloudUpgradeHint({
    required this.target,
    required this.text,
    this.progress,
  });

  factory CloudUpgradeHint.fromJson(Map<String, dynamic> json) {
    return CloudUpgradeHint(
      target: _parseTier(json['target']?.toString()),
      text: (json['text'] ?? '').toString(),
      progress: (json['progress'] is num)
          ? (json['progress'] as num).toDouble()
          : null,
    );
  }
}

class CloudQuotaInfo {
  final CloudSyncTier tier;
  final int usedBytes;
  final int usedQuests;
  final int usedRefs;
  final int maxBytes;
  final int maxQuests;
  final int maxQuestBytes;
  final int maxRefs;
  final String? grantedReason;
  final DateTime? expiresAt;
  final List<CloudUpgradeHint> upgradeHints;

  const CloudQuotaInfo({
    required this.tier,
    required this.usedBytes,
    required this.usedQuests,
    required this.usedRefs,
    required this.maxBytes,
    required this.maxQuests,
    required this.maxQuestBytes,
    required this.maxRefs,
    required this.grantedReason,
    required this.expiresAt,
    required this.upgradeHints,
  });

  factory CloudQuotaInfo.fromJson(Map<String, dynamic> json) {
    return CloudQuotaInfo(
      tier: _parseTier(json['tier']?.toString()),
      usedBytes: (json['usedBytes'] as num?)?.toInt() ?? 0,
      usedQuests: (json['usedQuests'] as num?)?.toInt() ?? 0,
      usedRefs: (json['usedRefs'] as num?)?.toInt() ?? 0,
      maxBytes: (json['maxBytes'] as num?)?.toInt() ?? 0,
      maxQuests: (json['maxQuests'] as num?)?.toInt() ?? 0,
      maxQuestBytes: (json['maxQuestBytes'] as num?)?.toInt() ?? 0,
      maxRefs: (json['maxRefs'] as num?)?.toInt() ?? 0,
      grantedReason: json['grantedReason']?.toString(),
      expiresAt: DateTime.tryParse(json['expiresAt']?.toString() ?? ''),
      upgradeHints: (json['upgradeHints'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CloudUpgradeHint.fromJson)
          .toList(),
    );
  }

  bool get hasAccess => maxBytes > 0 || maxQuests > 0;
  double get bytesUsage =>
      maxBytes <= 0 ? 0 : (usedBytes / maxBytes).clamp(0.0, 1.0);
}

/// Запись о квесте на сервере.
class CloudQuestEntry {
  final String questId;
  final String title;

  /// 'user' или 'market_ref'.
  final String source;
  final int size;
  final String? fingerprint;
  final DateTime? updatedAt;
  final String? marketQuestId;
  final String? marketVersion;
  final String? marketCurrentVersion;
  final bool marketAvailable;

  const CloudQuestEntry({
    required this.questId,
    required this.title,
    required this.source,
    required this.size,
    required this.fingerprint,
    required this.updatedAt,
    required this.marketQuestId,
    required this.marketVersion,
    required this.marketCurrentVersion,
    required this.marketAvailable,
  });

  bool get isMarketRef => source == 'market_ref';

  /// Декодирует название, если сервер вернул percent-кодированную строку.
  ///
  /// Из-за бага старые записи могли сохраниться в БД как `%D0%A0%D0%B0...`
  /// (percent-encoded UTF-8). Если строка похожа на percent-encoding —
  /// пытаемся декодировать; при неудаче возвращаем исходную.
  static String _decodeTitle(String raw) {
    if (!raw.contains('%')) return raw;
    // Эвристика: percent-кодирование выглядит как %XX, где XX — hex.
    if (!RegExp(r'%[0-9A-Fa-f]{2}').hasMatch(raw)) return raw;
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  factory CloudQuestEntry.fromJson(Map<String, dynamic> json) {
    return CloudQuestEntry(
      questId: (json['questId'] ?? '').toString(),
      title: _decodeTitle((json['title'] ?? '').toString()),
      source: (json['source'] ?? 'user').toString(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      fingerprint: json['fingerprint']?.toString(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
      marketQuestId: json['marketQuestId']?.toString(),
      marketVersion: json['marketVersion']?.toString(),
      marketCurrentVersion: json['marketCurrentVersion']?.toString(),
      marketAvailable: json['marketAvailable'] == true,
    );
  }
}

class CloudCheckResult {
  final bool exists;
  final bool sameFingerprint;
  final bool wouldExceedQuota;
  final bool supportsMarketRef;

  /// 'skip' | 'market_ref' | 'upload' | 'none'
  final String recommendation;
  final String? reason;
  final String? remoteFingerprint;
  final DateTime? remoteUpdatedAt;

  const CloudCheckResult({
    required this.exists,
    required this.sameFingerprint,
    required this.wouldExceedQuota,
    required this.supportsMarketRef,
    required this.recommendation,
    required this.reason,
    required this.remoteFingerprint,
    required this.remoteUpdatedAt,
  });

  factory CloudCheckResult.fromJson(Map<String, dynamic> json) {
    return CloudCheckResult(
      exists: json['exists'] == true,
      sameFingerprint: json['sameFingerprint'] == true,
      wouldExceedQuota: json['wouldExceedQuota'] == true,
      supportsMarketRef: json['supportsMarketRef'] == true,
      recommendation: (json['recommendation'] ?? 'none').toString(),
      reason: json['reason']?.toString(),
      remoteFingerprint: json['remoteFingerprint']?.toString(),
      remoteUpdatedAt: DateTime.tryParse(
        json['remoteUpdatedAt']?.toString() ?? '',
      ),
    );
  }
}

class CloudSyncException implements Exception {
  final String message;
  final int? status;
  CloudSyncException(this.message, {this.status});
  @override
  String toString() => 'CloudSyncException($status): $message';
}

class CloudSyncProgress {
  final String message;
  final double progress;
  const CloudSyncProgress({required this.message, required this.progress});
}

class CloudSyncSummary {
  final int uploaded;
  final int refLinked;
  final int downloaded;
  final int skipped;

  /// Квесты, для которых не хватило квоты (мягкий статус, не ошибка).
  final int quotaFull;
  final List<String> failed;

  const CloudSyncSummary({
    required this.uploaded,
    required this.refLinked,
    required this.downloaded,
    required this.skipped,
    required this.quotaFull,
    required this.failed,
  });

  bool get noChanges =>
      uploaded == 0 &&
      refLinked == 0 &&
      downloaded == 0 &&
      failed.isEmpty &&
      quotaFull == 0;
}

class CloudSyncService {
  static const _ua = 'MeanderCloudClient/1.0';

  String get _base => AppConfig.apiUrl;

  Future<String?> _token() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('jwt_token');
  }

  Map<String, String> _authHeaders(String token, {Map<String, String>? extra}) {
    return {
      HttpHeaders.authorizationHeader: 'Bearer $token',
      HttpHeaders.userAgentHeader: _ua,
      if (extra != null) ...extra,
    };
  }

  /// Выполняет HTTP-запрос с повторными попытками при 429 (Too many requests).
  ///
  /// Сервер ограничивает частоту запросов (rate limit). При массовой
  /// синхронизации мы можем упереться в лимит — вместо мгновенной ошибки
  /// ждём и повторяем, учитывая заголовки `Retry-After` / `RateLimit-Reset`,
  /// если они присутствуют, иначе используем экспоненциальный backoff.
  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() send, {
    int maxAttempts = 4,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      final resp = await send();
      if (resp.statusCode != 429 || attempt >= maxAttempts) {
        return resp;
      }
      final waitSeconds = _retryDelaySeconds(resp.headers, attempt);
      await Future<void>.delayed(Duration(seconds: waitSeconds));
    }
  }

  /// Вычисляет задержку перед повтором по заголовкам ответа либо backoff.
  int _retryDelaySeconds(Map<String, String> headers, int attempt) {
    // Retry-After: либо число секунд, либо HTTP-дата.
    final retryAfter = headers['retry-after'];
    if (retryAfter != null) {
      final asInt = int.tryParse(retryAfter.trim());
      if (asInt != null && asInt >= 0) {
        return asInt.clamp(1, 60);
      }
      final asDate = HttpDate.parse(retryAfter).difference(DateTime.now());
      if (asDate.inSeconds > 0) {
        return asDate.inSeconds.clamp(1, 60);
      }
    }
    // RateLimit-Reset (standardHeaders) — секунды до сброса окна.
    final reset = headers['ratelimit-reset'];
    if (reset != null) {
      final asInt = int.tryParse(reset.trim());
      if (asInt != null && asInt > 0) {
        return asInt.clamp(1, 60);
      }
    }
    // Экспоненциальный backoff: 2, 4, 8 секунд.
    return (1 << attempt).clamp(2, 30);
  }

  // ---------------------------------------------------------------------------
  //  Quota
  // ---------------------------------------------------------------------------

  Future<CloudQuotaInfo> fetchQuota() async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw CloudSyncException(tr('Не авторизованы'), status: 401);
    }
    final resp = await http.get(
      Uri.parse('$_base/cloud-sync/quota'),
      headers: _authHeaders(token),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CloudSyncException(
        trf('Ошибка получения квоты: {p0}', {'p0': resp.body}),
        status: resp.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    return CloudQuotaInfo.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  // ---------------------------------------------------------------------------
  //  List
  // ---------------------------------------------------------------------------

  Future<List<CloudQuestEntry>> listRemoteQuests() async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw CloudSyncException(tr('Не авторизованы'), status: 401);
    }
    final resp = await http.get(
      Uri.parse('$_base/cloud-sync/quests'),
      headers: _authHeaders(token),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CloudSyncException(
        trf('Ошибка списка: {p0}', {'p0': resp.body}),
        status: resp.statusCode,
      );
    }
    final list = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
    return list
        .whereType<Map<String, dynamic>>()
        .map(CloudQuestEntry.fromJson)
        .toList();
  }

  // ---------------------------------------------------------------------------
  //  Check
  // ---------------------------------------------------------------------------

  Future<CloudCheckResult> check({
    required String questId,
    required String fingerprint,
    required int size,
    String? marketQuestId,
    String? marketVersion,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw CloudSyncException(tr('Не авторизованы'), status: 401);
    }
    final body = <String, dynamic>{
      'fingerprint': fingerprint,
      'size': size,
      if (marketQuestId != null)
        'marketRef': {
          'marketQuestId': marketQuestId,
          if (marketVersion != null) 'version': marketVersion,
        },
    };
    final resp = await _sendWithRetry(
      () => http.post(
        Uri.parse('$_base/cloud-sync/quests/$questId/check'),
        headers: _authHeaders(
          token,
          extra: {
            HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          },
        ),
        body: jsonEncode(body),
      ),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CloudSyncException(
        'check failed: ${resp.body}',
        status: resp.statusCode,
      );
    }
    final json = jsonDecode(utf8.decode(resp.bodyBytes));
    return CloudCheckResult.fromJson(Map<String, dynamic>.from(json as Map));
  }

  // ---------------------------------------------------------------------------
  //  Upload binary .mnd
  // ---------------------------------------------------------------------------

  Future<void> uploadBinary({
    required String questId,
    required String title,
    required Uint8List bytes,
    required String fingerprint,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw CloudSyncException(tr('Не авторизованы'), status: 401);
    }
    final resp = await _sendWithRetry(
      () => http.put(
        Uri.parse('$_base/cloud-sync/quests/$questId'),
        headers: _authHeaders(
          token,
          extra: {
            HttpHeaders.contentTypeHeader: 'application/octet-stream',
            'x-title': _safeHeader(title),
            'x-title-encoding': 'percent',
            'x-fingerprint': fingerprint,
          },
        ),
        body: bytes,
      ),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CloudSyncException(
        'upload failed: ${resp.body}',
        status: resp.statusCode,
      );
    }
  }

  /// Стримит готовый `.mnd` файл на сервер, не загружая его целиком в RAM.
  ///
  /// Используется для слабых устройств: тело запроса читается из файла чанками
  /// через [http.StreamedRequest], а не держится в памяти как [Uint8List].
  Future<void> uploadFromFile({
    required String questId,
    required String title,
    required File file,
    required String fingerprint,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw CloudSyncException(tr('Не авторизованы'), status: 401);
    }
    final length = await file.length();

    Future<http.Response> doSend() async {
      final client = http.Client();
      try {
        final req = http.StreamedRequest(
          'PUT',
          Uri.parse('$_base/cloud-sync/quests/$questId'),
        );
        req.headers.addAll(
          _authHeaders(
            token,
            extra: {
              HttpHeaders.contentTypeHeader: 'application/octet-stream',
              HttpHeaders.contentLengthHeader: length.toString(),
              'x-title': _safeHeader(title),
              'x-title-encoding': 'percent',
              'x-fingerprint': fingerprint,
            },
          ),
        );
        // Подкачиваем файл в sink стрима по мере чтения.
        unawaited(
          file
              .openRead()
              .forEach(req.sink.add)
              .whenComplete(() => req.sink.close()),
        );
        final streamed = await client
            .send(req)
            .timeout(const Duration(minutes: 5));
        // await обязателен: без него finally закрывает client, пока тело
        // ответа ещё не дочитано, и загрузка обрывалась на середине ответа.
        return await http.Response.fromStream(streamed);
      } finally {
        client.close();
      }
    }

    final resp = await _sendWithRetry(doSend);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CloudSyncException(
        'upload failed: ${resp.body}',
        status: resp.statusCode,
      );
    }
  }

  /// Потоковый SHA-256 файла без загрузки целиком в память.
  Future<String> _fileSha256(File file) async {
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    final digest = output.events.single;
    output.close();
    return digest.toString();
  }

  // ---------------------------------------------------------------------------
  //  Upload market_ref
  // ---------------------------------------------------------------------------

  Future<void> uploadMarketRef({
    required String questId,
    required String title,
    required String marketQuestId,
    String? marketVersion,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw CloudSyncException(tr('Не авторизованы'), status: 401);
    }
    final resp = await _sendWithRetry(
      () => http.put(
        Uri.parse('$_base/cloud-sync/quests/$questId'),
        headers: _authHeaders(
          token,
          extra: {
            HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          },
        ),
        body: jsonEncode({
          'title': title,
          'marketQuestId': marketQuestId,
          if (marketVersion != null) 'marketVersion': marketVersion,
        }),
      ),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CloudSyncException(
        'ref upload failed: ${resp.body}',
        status: resp.statusCode,
      );
    }
  }

  // ---------------------------------------------------------------------------
  //  Авто-регистрация квеста из маркета
  // ---------------------------------------------------------------------------

  /// Привязывает только что установленный маркет-квест к облаку (ref, не байты).
  ///
  /// «Синк для квестов из маркета по умолчанию»: библиотека должна догонять
  /// облако без нажатия кнопки. Делается молча — отсутствие доступа, гость или
  /// нет сети это штатный режим, а не ошибка, которую надо показывать.
  /// Ref ничего не стоит по байтам квоты, поэтому риск для пользователя нулевой.
  Future<void> publishMarketRefQuietly({
    required String questId,
    required String title,
    required String marketQuestId,
    String? marketVersion,
  }) async {
    try {
      final refCheck = await check(
        questId: questId,
        fingerprint: 'mref:$marketQuestId:${marketVersion ?? '0'}',
        size: 0,
        marketQuestId: marketQuestId,
        marketVersion: marketVersion,
      );
      if (refCheck.sameFingerprint) return;
      if (refCheck.recommendation != 'market_ref') return;
      await uploadMarketRef(
        questId: questId,
        title: title,
        marketQuestId: marketQuestId,
        marketVersion: marketVersion,
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  //  Download (стрим)
  // ---------------------------------------------------------------------------

  /// Качает .mnd с сервера и возвращает путь к временному файлу.
  /// Для market_ref сервер вернёт 302 redirect — http клиент пройдёт по нему.
  Future<File> downloadToTempFile(String questId) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw CloudSyncException(tr('Не авторизованы'), status: 401);
    }
    final client = http.Client();
    try {
      final req = http.Request(
        'GET',
        Uri.parse('$_base/cloud-sync/quests/$questId'),
      )..followRedirects = true;
      req.headers.addAll(_authHeaders(token));

      final streamed = await client
          .send(req)
          .timeout(const Duration(minutes: 5));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw CloudSyncException(
          'download failed: ${streamed.statusCode}',
          status: streamed.statusCode,
        );
      }
      final tempDir = await getTemporaryDirectory();
      final file = File(
        p.join(
          tempDir.path,
          'cloud_${questId}_${DateTime.now().millisecondsSinceEpoch}.mnd',
        ),
      );
      final sink = file.openWrite();
      await streamed.stream.pipe(sink);
      await sink.close();
      return file;
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  //  Delete
  // ---------------------------------------------------------------------------

  Future<void> deleteRemote(String questId) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw CloudSyncException(tr('Не авторизованы'), status: 401);
    }
    final resp = await http.delete(
      Uri.parse('$_base/cloud-sync/quests/$questId'),
      headers: _authHeaders(token),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CloudSyncException(
        'delete failed: ${resp.body}',
        status: resp.statusCode,
      );
    }
    // Кэш не должен утверждать, что эти байты всё ещё в облаке: иначе
    // повторная загрузка квеста «уже там».
    final syncState = await CloudSyncCache.load();
    syncState.forget(questId);
    await syncState.save();
  }

  // ===========================================================================
  //  Высокоуровневый syncAll: загружает локальные, тащит чужие
  // ===========================================================================

  Future<CloudSyncSummary> syncAll({
    required List<Quest> localQuests,
    required void Function(CloudSyncProgress) onProgress,
  }) async {
    onProgress(
      CloudSyncProgress(message: tr('Получение квоты…'), progress: 0.02),
    );
    final quota = await fetchQuota();
    if (!quota.hasAccess) {
      throw CloudSyncException(
        tr(
          'Нет доступа к облачному хранилищу. Получите хотя бы starter-уровень.',
        ),
      );
    }

    onProgress(
      CloudSyncProgress(
        message: tr('Получение списка облака…'),
        progress: 0.05,
      ),
    );
    final remote = await listRemoteQuests();
    final remoteIds = remote.map((e) => e.questId).toSet();
    final remoteUserIds = remote
        .where((r) => r.source == 'user')
        .map((r) => r.questId)
        .toSet();
    final remoteRefIds = remote
        .where((r) => r.source == 'market_ref')
        .map((r) => r.questId)
        .toSet();
    final localIds = localQuests
        .where((q) => !q.isCorrupted)
        .map((q) => q.id)
        .toSet();

    // Кэш «эти байты уже на сервере»: без него каждый пользовательский квест
    // пакуется в .mnd и хешуется целиком (включая ассеты) на каждом прогоне,
    // даже когда ответ сервера — sameFingerprint. Сервер тут ни при чём:
    // тормозит локальная паковка.
    final syncState = await CloudSyncCache.load();
    final remoteFingerprints = <String, String>{
      for (final r in remote)
        if (r.source == 'user' && r.fingerprint != null)
          r.questId: r.fingerprint!,
    };

    int uploaded = 0;
    int refLinked = 0;
    int downloaded = 0;
    int skipped = 0;
    int quotaFull = 0;
    final failed = <String>[];

    // ===== Локальный «бюджет» (opportunistic sync) =====
    // Не отправляем заведомо проигрышные запросы — экономим трафик и UX.
    int remainingBytes = (quota.maxBytes - quota.usedBytes).clamp(
      0,
      quota.maxBytes,
    );
    int remainingUserSlots = (quota.maxQuests - quota.usedQuests).clamp(
      0,
      quota.maxQuests,
    );
    int remainingRefSlots = (quota.maxRefs - quota.usedRefs).clamp(
      0,
      quota.maxRefs,
    );

    final syncable = localQuests.where((q) => !q.isCorrupted).toList();
    // Маркет-квесты идут вперёд (бесплатные refs), потом обычные — мелкие сначала,
    // чтобы максимально использовать слоты при ограниченном starter-tier.
    syncable.sort((a, b) {
      final aRef = a.isMarketDownloaded && a.marketQuestId != null;
      final bRef = b.isMarketDownloaded && b.marketQuestId != null;
      if (aRef != bRef) return aRef ? -1 : 1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    final total = syncable.length + (remoteIds.difference(localIds).length);
    int done = 0;
    double progressFor(int d) => 0.1 + 0.85 * (total == 0 ? 1 : d / total);

    // ===== Загрузка/связывание локальных =====
    for (final q in syncable) {
      done++;
      onProgress(
        CloudSyncProgress(
          message: trf('Проверка: {p0}', {'p0': q.title}),
          progress: progressFor(done),
        ),
      );

      try {
        // ----- market_ref ветка -----
        if (q.isMarketDownloaded && q.marketQuestId != null) {
          // Если эта запись уже есть как ref — пропускаем (бесплатно)
          if (remoteRefIds.contains(q.id)) {
            skipped++;
            continue;
          }
          // Локальный бюджет refs
          if (remainingRefSlots <= 0) {
            quotaFull++;
            continue;
          }
          final refCheck = await check(
            questId: q.id,
            fingerprint: 'mref:${q.marketQuestId}:${q.version ?? '0'}',
            size: 0,
            marketQuestId: q.marketQuestId,
            marketVersion: q.version,
          );
          if (refCheck.sameFingerprint) {
            skipped++;
            continue;
          }
          if (refCheck.recommendation == 'market_ref') {
            await uploadMarketRef(
              questId: q.id,
              title: q.title,
              marketQuestId: q.marketQuestId!,
              marketVersion: q.version,
            );
            refLinked++;
            remainingRefSlots--;
            continue;
          }
          if (refCheck.wouldExceedQuota) {
            quotaFull++;
            continue;
          }
          // Маркет недоступен — попробуем обычный upload ниже
        }

        // ----- user upload ветка -----
        // Если запись уже user — обновим через check (может, sameFingerprint).
        // Если новой записи место уже нет — отметим quotaFull без обращения к серверу.
        final isExisting = remoteUserIds.contains(q.id);
        if (!isExisting && remainingUserSlots <= 0) {
          quotaFull++;
          continue;
        }

        // Подпись каталога считаем всегда (это обход файлов + хеш только
        // config/nodes, не паковка), чтобы и пропустить неизменённый квест, и
        // законсервировать результат после загрузки.
        final localSignature = await questSignatureById(q.id);
        if (syncState.confirmedFingerprint(
              questId: q.id,
              signature: localSignature,
              remoteFingerprint: remoteFingerprints[q.id],
            ) !=
            null) {
          skipped++;
          continue;
        }

        // Собираем .mnd потоково во временный файл (не держим архив в RAM —
        // критично для слабых устройств и больших квестов).
        final mndFile = await ExportService.createMndTempFile(
          q.id,
          // Облако/каталог ещё читают legacy-монолит.
          nodesFormat: QuestArchiveNodesFormat.legacy,
        );
        try {
          final size = await mndFile.length();
          if (size > quota.maxQuestBytes) {
            quotaFull++;
            continue;
          }
          // Прикинем место по байтам локально — чтобы не дёргать сервер с
          // заведомо непролезающим файлом.
          if (!isExisting && size > remainingBytes) {
            quotaFull++;
            continue;
          }

          final fp = await _fileSha256(mndFile);
          final fileCheck = await check(
            questId: q.id,
            fingerprint: fp,
            size: size,
          );

          if (fileCheck.sameFingerprint) {
            // Сервер подтвердил эти байты — со следующего раза квест можно не
            // паковать вовсе.
            syncState.remember(
              q.id,
              signature: localSignature,
              fingerprint: fp,
            );
            skipped++;
            continue;
          }
          if (fileCheck.wouldExceedQuota) {
            quotaFull++;
            continue;
          }
          if (fileCheck.recommendation != 'upload') {
            failed.add('${q.title}: ${fileCheck.reason ?? 'нельзя загрузить'}');
            continue;
          }

          await uploadFromFile(
            questId: q.id,
            title: q.title,
            file: mndFile,
            fingerprint: fp,
          );
          syncState.remember(q.id, signature: localSignature, fingerprint: fp);
          uploaded++;
          if (!isExisting) {
            remainingUserSlots--;
          }
          remainingBytes -= size;
        } finally {
          try {
            await mndFile.delete();
          } catch (_) {}
        }
      } catch (e) {
        failed.add('${q.title}: ${friendlyError(e)}');
      }
    }

    // ===== Скачивание квестов, которых нет локально =====
    final missingLocally = remote.where((r) => !localIds.contains(r.questId));
    for (final r in missingLocally) {
      done++;
      onProgress(
        CloudSyncProgress(
          message: trf('Скачивание: {p0}', {'p0': r.title}),
          progress: progressFor(done),
        ),
      );
      try {
        final file = await downloadToTempFile(r.questId);
        await AsyncImportService.importFromFile(file.path);
        try {
          await file.delete();
        } catch (_) {}
        downloaded++;
      } catch (e) {
        failed.add('${r.title}: ${friendlyError(e)}');
      }
    }

    syncState.prune(localIds);
    await syncState.save();

    onProgress(CloudSyncProgress(message: tr('Готово'), progress: 1.0));

    return CloudSyncSummary(
      uploaded: uploaded,
      refLinked: refLinked,
      downloaded: downloaded,
      skipped: skipped,
      quotaFull: quotaFull,
      failed: failed,
    );
  }

  // ---------------------------------------------------------------------------
  //  Утилиты
  // ---------------------------------------------------------------------------

  /// Кодирует значение HTTP-заголовка так, чтобы оно содержало только ASCII.
  ///
  /// HTTP-заголовки должны быть в пределах ASCII/latin-1, поэтому кириллица
  /// (и любые другие не-ASCII символы) в названии квеста приводят к
  /// `FormatException: Invalid HTTP header field value` на стороне Dart-клиента
  /// ещё до отправки запроса. Мы percent-кодируем строку (UTF-8 → %XX), что
  /// даёт безопасный ASCII-заголовок. Дополнительно отправляем флаг
  /// `x-title-encoding: percent`, чтобы сервер мог декодировать значение.
  static String _safeHeader(String s) {
    // Обрезаем по символам до серверного лимита (200), чтобы percent-encoding
    // не раздул значение и не привёл к слишком длинному заголовку.
    final clean = s.replaceAll(RegExp(r'[\r\n]'), ' ');
    final trimmed = clean.length > 180 ? clean.substring(0, 180) : clean;
    return Uri.encodeComponent(trimmed);
  }
}
