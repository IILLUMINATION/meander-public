import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/async_import_service.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:mnd_core/models/quest_descriptor.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class GitHubSyncSettings {
  final bool enabled;
  final String token;
  final String owner;
  final String repo;
  final String branch;
  final String rootPath;

  const GitHubSyncSettings({
    required this.enabled,
    required this.token,
    required this.owner,
    required this.repo,
    required this.branch,
    required this.rootPath,
  });

  static const empty = GitHubSyncSettings(
    enabled: false,
    token: '',
    owner: '',
    repo: '',
    branch: 'main',
    rootPath: 'meander-sync',
  );

  bool get isConfigured =>
      token.trim().isNotEmpty &&
      owner.trim().isNotEmpty &&
      repo.trim().isNotEmpty &&
      branch.trim().isNotEmpty;

  GitHubSyncSettings copyWith({
    bool? enabled,
    String? token,
    String? owner,
    String? repo,
    String? branch,
    String? rootPath,
  }) {
    return GitHubSyncSettings(
      enabled: enabled ?? this.enabled,
      token: token ?? this.token,
      owner: owner ?? this.owner,
      repo: repo ?? this.repo,
      branch: branch ?? this.branch,
      rootPath: rootPath ?? this.rootPath,
    );
  }
}

class GitHubSyncProgress {
  final String message;
  final double progress;

  const GitHubSyncProgress({required this.message, required this.progress});
}

class QuestFileSnapshot {
  final Map<String, String> hashes;
  final Map<String, int> sizes;

  const QuestFileSnapshot({required this.hashes, required this.sizes});
}

class GitHubSyncConflict {
  final String questId;
  final String title;
  final String path;

  const GitHubSyncConflict({
    required this.questId,
    required this.title,
    required this.path,
  });
}

class GitHubSyncConflictException implements Exception {
  final String path;
  GitHubSyncConflictException(this.path);

  @override
  String toString() => 'GitHubSyncConflictException: $path';
}

class _UploadResult {
  final String path;
  final String? sha;
  final bool conflict;

  const _UploadResult({
    required this.path,
    required this.sha,
    required this.conflict,
  });
}

class GitHubSyncResult {
  final int uploaded;
  final int downloaded;
  final bool noChanges;
  final int skipped;
  final int conflicts;
  final List<GitHubSyncConflict> conflictItems;

  const GitHubSyncResult({
    required this.uploaded,
    required this.downloaded,
    required this.noChanges,
    required this.skipped,
    required this.conflicts,
    required this.conflictItems,
  });
}

class GitHubSyncService {
  static const _settingsPath = 'app/sync/github_settings.json';
  static const _httpTimeout = Duration(seconds: 30);
  static const _maxRetries = 3;

  Future<GitHubSyncSettings> loadSettings() async {
    GitHubSyncSettings local;
    try {
      if (!await FileStorage.exists(_settingsPath)) {
        local = GitHubSyncSettings.empty;
      } else {
        final json = await FileStorage.readJsonFile(_settingsPath);
        local = GitHubSyncSettings(
          enabled: json['enabled'] == true,
          token: (json['token'] ?? '').toString(),
          owner: (json['owner'] ?? '').toString(),
          repo: (json['repo'] ?? '').toString(),
          branch: (json['branch'] ?? 'main').toString(),
          rootPath: (json['rootPath'] ?? 'meander-sync').toString(),
        );
      }
    } catch (_) {
      local = GitHubSyncSettings.empty;
    }

    try {
      final remote = await loadSettingsFromBackend();
      if (remote != null) {
        await FileStorage.writeJsonFile(_settingsPath, {
          'enabled': remote.enabled,
          'token': remote.token,
          'owner': remote.owner,
          'repo': remote.repo,
          'branch': remote.branch,
          'rootPath': remote.rootPath,
        });
        return remote;
      }
    } catch (_) {}

    return local;
  }

  Future<GitHubSyncSettings?> loadSettingsFromBackend() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');
    if (token == null || token.trim().isEmpty) return null;

    final uri = Uri.parse('${AppConfig.apiUrl}/profiles/sync-settings');
    final resp = await http.get(
      uri,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
    );

    if (resp.statusCode == 404 ||
        resp.statusCode == 401 ||
        resp.statusCode == 403) {
      return null;
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        'Load sync settings failed: ${resp.statusCode} ${resp.body}',
      );
    }

    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) return null;
    final github = decoded['github'];
    if (github is! Map) return null;
    final g = Map<String, dynamic>.from(github);
    return GitHubSyncSettings(
      enabled: g['enabled'] == true,
      token: (g['token'] ?? '').toString(),
      owner: (g['owner'] ?? '').toString(),
      repo: (g['repo'] ?? '').toString(),
      branch: (g['branch'] ?? 'main').toString(),
      rootPath: (g['rootPath'] ?? 'meander-sync').toString(),
    );
  }

  Future<void> saveSettingsToBackend(GitHubSyncSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');
    if (token == null || token.trim().isEmpty) return;

    final uri = Uri.parse('${AppConfig.apiUrl}/profiles/sync-settings');
    final resp = await http.post(
      uri,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
      body: jsonEncode({
        'github': {
          'enabled': settings.enabled,
          'token': settings.token,
          'owner': settings.owner,
          'repo': settings.repo,
          'branch': settings.branch,
          'rootPath': settings.rootPath,
        },
      }),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        'Save sync settings failed: ${resp.statusCode} ${resp.body}',
      );
    }
  }

  Future<void> saveSettings(GitHubSyncSettings settings) async {
    await FileStorage.writeJsonFile(_settingsPath, {
      'enabled': settings.enabled,
      'token': settings.token,
      'owner': settings.owner,
      'repo': settings.repo,
      'branch': settings.branch,
      'rootPath': settings.rootPath,
    });
    try {
      await saveSettingsToBackend(settings);
    } catch (_) {}
  }

  Future<void> clearSettings() async {
    if (await FileStorage.exists(_settingsPath)) {
      await FileStorage.delete(_settingsPath);
    }
  }

  Future<void> validateConnection(GitHubSyncSettings settings) async {
    if (!settings.isConfigured) {
      throw Exception(tr('Заполните токен, owner, repo и branch'));
    }

    final userUri = Uri.https('api.github.com', '/user');
    final userResp = await _requestWithRetry(
      () => http.get(userUri, headers: _headers(settings.token)),
      context: 'validate user',
    );
    if (userResp.statusCode != 200) {
      throw Exception(
        trf('GitHub token невалиден ({p0})', {'p0': userResp.statusCode}),
      );
    }

    final repoUri = Uri.https(
      'api.github.com',
      '/repos/${settings.owner.trim()}/${settings.repo.trim()}',
    );
    final repoResp = await _requestWithRetry(
      () => http.get(repoUri, headers: _headers(settings.token)),
      context: 'validate repo',
    );
    if (repoResp.statusCode != 200) {
      throw Exception(
        trf('Нет доступа к репозиторию {p0}/{p1} ({p2})', {
          'p0': settings.owner,
          'p1': settings.repo,
          'p2': repoResp.statusCode,
        }),
      );
    }
  }

  Future<GitHubSyncResult> syncQuests({
    required GitHubSyncSettings settings,
    required List<Quest> localQuests,
    required void Function(GitHubSyncProgress p) onProgress,
  }) async {
    if (!settings.enabled) {
      throw Exception(tr('Синхронизация выключена в настройках'));
    }
    await validateConnection(settings);

    final normalizedRoot = _normalizeRoot(settings.rootPath);
    final indexPath = normalizedRoot.isEmpty
        ? 'index.json'
        : '$normalizedRoot/index.json';
    final questsPrefix = normalizedRoot.isEmpty
        ? 'quests'
        : '$normalizedRoot/quests';

    onProgress(
      GitHubSyncProgress(message: tr('Чтение индекса...'), progress: 0.03),
    );
    final remoteIndexFile = await _getContentFile(
      settings: settings,
      filePath: indexPath,
    );

    final remoteIndex = remoteIndexFile == null
        ? <String, dynamic>{'quests': <String, dynamic>{}}
        : _decodeJsonContent(remoteIndexFile['content']?.toString() ?? '');

    final remoteQuestsRaw = remoteIndex['quests'];
    final remoteQuests = remoteQuestsRaw is Map
        ? Map<String, dynamic>.from(remoteQuestsRaw)
        : <String, dynamic>{};
    final format = (remoteIndex['format']?.toString() ?? '').trim();
    final useFileSync = format.isEmpty || format == 'files';
    if (useFileSync) {
      return _syncQuestsFiles(
        settings: settings,
        localQuests: localQuests,
        onProgress: onProgress,
        remoteIndexFile: remoteIndexFile,
        remoteIndex: remoteIndex,
        normalizedRoot: normalizedRoot,
        indexPath: indexPath,
        questsPrefix: questsPrefix,
      );
    }
    bool indexDirty = format.isEmpty;

    final discoveredRemote = await _discoverRemoteQuestFiles(
      settings: settings,
      questsPrefix: questsPrefix,
    );
    for (final entry in discoveredRemote.entries) {
      if (!remoteQuests.containsKey(entry.key)) {
        remoteQuests[entry.key] = entry.value;
        indexDirty = true;
      }
    }

    final syncableLocal = localQuests.where((q) => !q.isCorrupted).toList();
    final localIds = syncableLocal.map((q) => q.id).toSet();
    final remoteOnly = remoteQuests.entries
        .where((entry) => !localIds.contains(entry.key))
        .toList();

    int uploaded = 0;
    int downloaded = 0;
    int skipped = 0;
    int conflicts = 0;
    final conflictItems = <GitHubSyncConflict>[];
    final totalSteps = (syncableLocal.length * 2) + remoteOnly.length + 2;
    int doneSteps = 0;
    final localSyncState = await _loadLocalSyncState();
    final localFingerprintsRaw = localSyncState['fingerprints'];
    final localFingerprints = localFingerprintsRaw is Map
        ? Map<String, dynamic>.from(localFingerprintsRaw)
        : <String, dynamic>{};

    if (syncableLocal.isEmpty && remoteOnly.isNotEmpty) {
      onProgress(
        GitHubSyncProgress(
          message: tr(
            'Локальная библиотека пуста. Восстанавливаем квесты из GitHub...',
          ),
          progress: 0.02,
        ),
      );
    }

    for (final quest in syncableLocal) {
      onProgress(
        GitHubSyncProgress(
          message: trf('Проверка: {p0}', {'p0': quest.title}),
          progress: _stepProgress(doneSteps, totalSteps),
        ),
      );
      final fingerprint = await _computeQuestFingerprint(quest.id);
      doneSteps++;

      final hasRemote = remoteQuests.containsKey(quest.id);
      final previousFingerprint = localFingerprints[quest.id]?.toString();
      String? remoteFingerprint;
      final remoteEntry = remoteQuests[quest.id];
      if (remoteEntry is Map) {
        remoteFingerprint = remoteEntry['fingerprint']?.toString();
      }
      final hasConflict = _detectConflict(
        hasRemote: hasRemote,
        previousFingerprint: previousFingerprint,
        localFingerprint: fingerprint,
        remoteFingerprint: remoteFingerprint,
      );
      if (hasConflict) {
        conflicts++;
        final title =
            (remoteEntry is Map &&
                (remoteEntry['title']?.toString().isNotEmpty ?? false))
            ? remoteEntry['title'].toString()
            : quest.title;
        String path = '$questsPrefix/${quest.id}.mnd';
        if (remoteEntry is Map &&
            (remoteEntry['path']?.toString().trim().isNotEmpty ?? false)) {
          path = remoteEntry['path'].toString();
        }
        conflictItems.add(
          GitHubSyncConflict(questId: quest.id, title: title, path: path),
        );
        doneSteps++;
        continue;
      }

      final isUnchanged =
          hasRemote &&
          (previousFingerprint == fingerprint ||
              (remoteFingerprint != null && remoteFingerprint == fingerprint));
      if (isUnchanged) {
        skipped++;
        localFingerprints[quest.id] = fingerprint;
        final existing = remoteQuests[quest.id];
        if (existing is Map) {
          final current = existing['fingerprint']?.toString();
          if (current != fingerprint) {
            final updated = Map<String, dynamic>.from(existing);
            updated['fingerprint'] = fingerprint;
            remoteQuests[quest.id] = updated;
            indexDirty = true;
          }
        }
        doneSteps++;
        continue;
      }

      final remoteFilePath = '$questsPrefix/${quest.id}.mnd';
      final entry = remoteQuests[quest.id];
      String? previousSha;
      if (entry is Map) {
        previousSha = entry['sha']?.toString();
      }

      onProgress(
        GitHubSyncProgress(
          message: trf('Архивация: {p0}', {'p0': quest.title}),
          progress: _stepProgress(doneSteps, totalSteps),
        ),
      );
      final data = await ExportService.createMndFile(
        quest.id,
        // GitHub-синхронизация должна читаться старыми клиентами.
        nodesFormat: QuestArchiveNodesFormat.legacy,
      );

      onProgress(
        GitHubSyncProgress(
          message: trf('Загрузка в GitHub: {p0}', {'p0': quest.title}),
          progress: _stepProgress(doneSteps, totalSteps),
        ),
      );
      final uploadedMeta = await _putContentFile(
        settings: settings,
        filePath: remoteFilePath,
        bytes: data,
        message: 'sync quest ${quest.id}',
        previousSha: previousSha,
      );
      doneSteps++;
      uploaded++;
      localFingerprints[quest.id] = fingerprint;

      remoteQuests[quest.id] = {
        'id': quest.id,
        'title': quest.title,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'path': remoteFilePath,
        'sha': uploadedMeta['sha']?.toString(),
        'fingerprint': fingerprint,
      };
      indexDirty = true;
    }

    for (final entry in remoteOnly) {
      final item = entry.value;
      String path;
      if (item is Map &&
          (item['path']?.toString().trim().isNotEmpty ?? false)) {
        path = item['path'].toString();
      } else {
        path = '$questsPrefix/${entry.key}.mnd';
      }

      onProgress(
        GitHubSyncProgress(
          message: trf('Скачивание: {p0}', {'p0': entry.key}),
          progress: _stepProgress(doneSteps, totalSteps),
        ),
      );
      final bytes = await _downloadContentFileBytes(
        settings: settings,
        filePath: path,
      );
      final imported = await _importQuestFromBytes(bytes, entry.key);
      doneSteps++;
      if (imported != null) {
        final fp = await _computeQuestFingerprint(imported);
        localFingerprints[imported] = fp;
        downloaded++;
      }
    }

    if (indexDirty) {
      onProgress(
        GitHubSyncProgress(
          message: tr('Обновление индекса...'),
          progress: _stepProgress(doneSteps, totalSteps),
        ),
      );

      final updatedIndex = {'quests': _sortIndexQuests(remoteQuests)};
      await _putContentFile(
        settings: settings,
        filePath: indexPath,
        bytes: utf8.encode(jsonEncode(updatedIndex)),
        message: 'sync index',
        previousSha: remoteIndexFile?['sha']?.toString(),
      );
      doneSteps++;
    }

    await _saveLocalSyncState({'fingerprints': localFingerprints});

    onProgress(GitHubSyncProgress(message: tr('Готово'), progress: 1.0));
    final noChanges = uploaded == 0 && downloaded == 0;
    return GitHubSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      noChanges: noChanges,
      skipped: skipped,
      conflicts: conflicts,
      conflictItems: conflictItems,
    );
  }

  Future<GitHubSyncResult> _syncQuestsFiles({
    required GitHubSyncSettings settings,
    required List<Quest> localQuests,
    required void Function(GitHubSyncProgress p) onProgress,
    required Map<String, dynamic>? remoteIndexFile,
    required Map<String, dynamic> remoteIndex,
    required String normalizedRoot,
    required String indexPath,
    required String questsPrefix,
  }) async {
    final syncableLocal = localQuests.where((q) => !q.isCorrupted).toList();
    final localIds = syncableLocal.map((q) => q.id).toSet();

    onProgress(
      GitHubSyncProgress(
        message: tr('Чтение структуры репозитория...'),
        progress: 0.03,
      ),
    );
    final remoteQuestIds = await _listRemoteQuestFolders(
      settings: settings,
      questsPrefix: questsPrefix,
    );

    final remoteMnd = await _discoverRemoteQuestFiles(
      settings: settings,
      questsPrefix: questsPrefix,
    );

    final remoteOnly = <String>{}
      ..addAll(remoteQuestIds.where((id) => !localIds.contains(id)))
      ..addAll(
        remoteMnd.keys.where(
          (id) => !localIds.contains(id) && !remoteQuestIds.contains(id),
        ),
      );

    int uploaded = 0;
    int downloaded = 0;
    int skipped = 0;
    int conflicts = 0;
    final conflictItems = <GitHubSyncConflict>[];
    bool indexDirty = false;
    int doneSteps = 0;
    final totalSteps = (syncableLocal.length * 3) + remoteOnly.length + 2;

    final localSyncState = await _loadLocalSyncState();
    final fileHashesRaw = localSyncState['fileHashes'];
    final fileHashes = fileHashesRaw is Map
        ? Map<String, dynamic>.from(fileHashesRaw)
        : <String, dynamic>{};

    for (final quest in syncableLocal) {
      final questStopwatch = Stopwatch()..start();
      onProgress(
        GitHubSyncProgress(
          message: trf('Проверка: {p0}', {'p0': quest.title}),
          progress: _stepProgress(doneSteps, totalSteps),
        ),
      );
      var localSnapshot = await _collectLocalQuestFileSnapshot(quest.id);
      var localFiles = localSnapshot.hashes;
      print('🔍 [Sync] ${quest.id}: local files=${localFiles.length}');
      doneSteps++;

      final remoteManifest = await _getRemoteQuestManifest(
        settings: settings,
        questsPrefix: questsPrefix,
        questId: quest.id,
      );
      final manifestSha = remoteManifest?['_sha']?.toString();
      final remoteFilesRaw = remoteManifest?['files'];
      final remoteFiles = remoteFilesRaw is Map
          ? Map<String, dynamic>.from(remoteFilesRaw)
          : <String, dynamic>{};
      final remoteShasRaw = remoteManifest?['shas'];
      final remoteShas = remoteShasRaw is Map
          ? Map<String, dynamic>.from(remoteShasRaw)
          : <String, dynamic>{};
      final hasManifest = remoteManifest != null;
      Map<String, dynamic> remoteSizes = <String, dynamic>{};

      if (!hasManifest) {
        onProgress(
          GitHubSyncProgress(
            message: trf('Сканирование облака: {p0}', {'p0': quest.title}),
            progress: _stepProgress(doneSteps, totalSteps),
          ),
        );
        final listing = await _listRemoteQuestFilesRecursive(
          settings: settings,
          questsPrefix: questsPrefix,
          questId: quest.id,
        );
        for (final entry in listing.entries) {
          remoteShas.putIfAbsent(entry.key, () => entry.value['sha']);
          remoteSizes[entry.key] = entry.value['size'];
        }
      }
      print('🌐 [Sync] ${quest.id}: remote files=${remoteFiles.length}');

      final previousRaw = fileHashes[quest.id];
      final previousFiles = previousRaw is Map
          ? Map<String, dynamic>.from(previousRaw)
          : <String, dynamic>{};

      final hasConflict = _detectQuestFileConflict(
        localFiles: localFiles,
        remoteFiles: remoteFiles,
        previousFiles: previousFiles,
      );
      if (hasConflict) {
        conflicts++;
        conflictItems.add(
          GitHubSyncConflict(
            questId: quest.id,
            title: quest.title,
            path: '$questsPrefix/${quest.id}',
          ),
        );
        doneSteps += 2;
        continue;
      }

      int questUploads = 0;
      int questDownloads = 0;

      final updatedShas = Map<String, dynamic>.from(remoteShas);
      final uploadTasks = <Future<_UploadResult>>[];
      final filesToUpload = <String>{};

      for (final entry in localFiles.entries) {
        final remoteHash = remoteFiles[entry.key]?.toString();
        if (remoteHash == entry.value) continue;
        if (!hasManifest && remoteSizes.containsKey(entry.key)) {
          final remoteSize =
              int.tryParse(remoteSizes[entry.key].toString()) ?? -1;
          final localSize = localSnapshot.sizes[entry.key] ?? -2;
          if (remoteSize >= 0 && localSize == remoteSize) continue;
        }
        filesToUpload.add(entry.key);
      }

      for (final rel in filesToUpload) {
        String? knownSha = remoteShas[rel]?.toString();
        if ((knownSha == null || knownSha.isEmpty) &&
            (remoteFiles.containsKey(rel) || remoteShas.containsKey(rel))) {
          final existing = await _getContentFile(
            settings: settings,
            filePath: '$questsPrefix/${quest.id}/$rel',
          );
          knownSha = existing?['sha']?.toString();
          if (knownSha != null && knownSha.isNotEmpty) {
            updatedShas[rel] = knownSha;
          }
        }
        uploadTasks.add(
          _safeUploadQuestFile(
            settings: settings,
            questsPrefix: questsPrefix,
            questId: quest.id,
            relativePath: rel,
            previousSha: knownSha,
          ),
        );
      }

      var questHasConflict = false;
      for (final batch in _chunkFutures(uploadTasks, 4)) {
        // eagerError: false — собираем все результаты даже при частичном фейле
        final results = await Future.wait(batch, eagerError: false);
        for (final res in results) {
          if (res.conflict) {
            conflicts++;
            conflictItems.add(
              GitHubSyncConflict(
                questId: quest.id,
                title: quest.title,
                path: '$questsPrefix/${quest.id}/${res.path}',
              ),
            );
            questHasConflict = true;
            break;
          }
          if (res.sha != null && res.sha!.isNotEmpty) {
            updatedShas[res.path] = res.sha!;
          }
        }
        if (questHasConflict) break;
      }
      if (questHasConflict) {
        doneSteps++;
        questStopwatch.stop();
        continue;
      }
      questUploads += uploadTasks.length;

      for (final entry in remoteFiles.entries) {
        if (localFiles.containsKey(entry.key)) continue;
        await _downloadQuestFile(
          settings: settings,
          questsPrefix: questsPrefix,
          questId: quest.id,
          relativePath: entry.key,
        );
        questDownloads++;
      }
      if (questDownloads > 0) {
        localSnapshot = await _collectLocalQuestFileSnapshot(quest.id);
        localFiles = localSnapshot.hashes;
      }

      doneSteps++;
      uploaded += questUploads;
      downloaded += questDownloads;
      questStopwatch.stop();
      print(
        '✅ [Sync] ${quest.id}: uploaded=$questUploads downloaded=$questDownloads '
        'time=${questStopwatch.elapsedMilliseconds}ms',
      );

      if (questUploads == 0 && questDownloads == 0) {
        skipped++;
      }

      final manifestUnchanged =
          hasManifest && _mapsEqualString(localFiles, remoteFiles);
      if (!manifestUnchanged || questUploads > 0 || questDownloads > 0) {
        final manifest = _buildRemoteManifest(
          questId: quest.id,
          questTitle: quest.title,
          files: localFiles,
          shas: updatedShas,
        );
        await _putRemoteQuestManifest(
          settings: settings,
          questsPrefix: questsPrefix,
          questId: quest.id,
          manifest: manifest,
          previousSha: manifestSha,
        );
      }

      fileHashes[quest.id] = localFiles;
      doneSteps++;

      final existing = remoteIndex['quests'] is Map
          ? Map<String, dynamic>.from(remoteIndex['quests'] as Map)
          : <String, dynamic>{};
      final existingEntry = existing[quest.id];
      final desired = {
        'id': quest.id,
        'title': quest.title,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'path': '$questsPrefix/${quest.id}',
      };
      if (existingEntry is Map) {
        if (existingEntry['title']?.toString() != quest.title ||
            existingEntry['path']?.toString() != desired['path']) {
          existing[quest.id] = desired;
          indexDirty = true;
        }
      } else {
        existing[quest.id] = desired;
        indexDirty = true;
      }
      remoteIndex['quests'] = existing;
      remoteIndex['format'] = 'files';
    }

    for (final questId in remoteOnly) {
      final sw = Stopwatch()..start();
      onProgress(
        GitHubSyncProgress(
          message: trf('Скачивание: {questId}', {'questId': questId}),
          progress: _stepProgress(doneSteps, totalSteps),
        ),
      );

      if (remoteQuestIds.contains(questId)) {
        await _downloadRemoteQuestFolder(
          settings: settings,
          questsPrefix: questsPrefix,
          questId: questId,
        );
        final fp = await _collectLocalQuestFileSnapshot(questId);
        fileHashes[questId] = fp.hashes;
        downloaded++;
      } else if (remoteMnd.containsKey(questId)) {
        final path =
            remoteMnd[questId]?['path']?.toString() ??
            '$questsPrefix/$questId.mnd';
        final bytes = await _downloadContentFileBytes(
          settings: settings,
          filePath: path,
        );
        final imported = await _importQuestFromBytes(bytes, questId);
        if (imported != null) {
          final fp = await _collectLocalQuestFileSnapshot(imported);
          fileHashes[imported] = fp.hashes;
          downloaded++;
        }
      }
      doneSteps++;
      sw.stop();
      print('✅ [Sync] restore $questId time=${sw.elapsedMilliseconds}ms');
    }

    if (indexDirty) {
      final existing = (remoteIndex['quests'] is Map)
          ? Map<String, dynamic>.from(remoteIndex['quests'] as Map)
          : <String, dynamic>{};
      for (final questId in remoteQuestIds) {
        existing.putIfAbsent(questId, () {
          return {
            'id': questId,
            'title': questId,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'path': '$questsPrefix/$questId',
          };
        });
      }
      remoteIndex['quests'] = existing;
      remoteIndex['format'] = 'files';

      onProgress(
        GitHubSyncProgress(
          message: tr('Обновление индекса...'),
          progress: _stepProgress(doneSteps, totalSteps),
        ),
      );
      final updatedIndex = {
        'format': 'files',
        'quests': _sortIndexQuests(existing),
      };
      await _putContentFile(
        settings: settings,
        filePath: indexPath,
        bytes: utf8.encode(jsonEncode(updatedIndex)),
        message: 'sync index',
        previousSha: remoteIndexFile?['sha']?.toString(),
      );
      doneSteps++;
    }

    final fingerprintsRaw = localSyncState['fingerprints'];
    final fingerprints = fingerprintsRaw is Map
        ? Map<String, dynamic>.from(fingerprintsRaw)
        : <String, dynamic>{};
    await _saveLocalSyncState({
      'fingerprints': fingerprints,
      'fileHashes': fileHashes,
    });

    onProgress(GitHubSyncProgress(message: tr('Готово'), progress: 1.0));
    final noChanges = uploaded == 0 && downloaded == 0;
    return GitHubSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      noChanges: noChanges,
      skipped: skipped,
      conflicts: conflicts,
      conflictItems: conflictItems,
    );
  }

  Future<Map<String, dynamic>> _loadLocalSyncState() async {
    const statePath = 'app/sync/github_sync_state.json';
    if (!await FileStorage.exists(statePath)) return <String, dynamic>{};
    try {
      return await FileStorage.readJsonFile(statePath);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _saveLocalSyncState(Map<String, dynamic> json) async {
    const statePath = 'app/sync/github_sync_state.json';
    await FileStorage.writeJsonFile(statePath, json);
  }

  String _hashBytesHex(List<int> bytes) {
    var hash = 0x811C9DC5;
    for (final byte in bytes) {
      hash ^= (byte & 0xFF);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<String> _computeQuestFingerprint(String questId) async {
    final rootRelative = QuestPaths.questRoot(questId);
    final rootAbsolute = await FileStorage.getFilePath(rootRelative);
    final rootDir = Directory(rootAbsolute);
    if (!await rootDir.exists()) return '';

    final files = <File>[];
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final bytes = <int>[];
    for (final file in files) {
      final rel = p
          .relative(file.path, from: rootAbsolute)
          .replaceAll('\\', '/');
      if (_shouldIgnoreFingerprintPath(rel)) continue;
      bytes.addAll(utf8.encode(rel));
      bytes.add(0);
      bytes.addAll(await _readFileBytesForFingerprint(file, rel));
      bytes.add(255);
    }
    return _hashBytesHex(bytes);
  }

  Future<List<int>> _readFileBytesForFingerprint(File file, String rel) async {
    if (rel == 'config.json') {
      try {
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          map.remove('lastOpened');
          final normalized = jsonEncode(map);
          return utf8.encode(normalized);
        }
      } catch (_) {}
    }
    return file.readAsBytes();
  }

  Future<QuestFileSnapshot> _collectLocalQuestFileSnapshot(
    String questId,
  ) async {
    final rootRelative = QuestPaths.questRoot(questId);
    final rootAbsolute = await FileStorage.getFilePath(rootRelative);
    final rootDir = Directory(rootAbsolute);
    if (!await rootDir.exists()) {
      return const QuestFileSnapshot(hashes: {}, sizes: {});
    }

    final files = <File>[];
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final hashes = <String, String>{};
    final sizes = <String, int>{};
    for (final file in files) {
      final rel = p
          .relative(file.path, from: rootAbsolute)
          .replaceAll('\\', '/');
      if (_isIgnoredQuestFile(rel)) continue;
      final bytes = await file.readAsBytes();
      hashes[rel] = _hashBytesHex(bytes);
      sizes[rel] = bytes.length;
    }
    return QuestFileSnapshot(hashes: hashes, sizes: sizes);
  }

  bool _isIgnoredQuestFile(String rel) {
    if (rel == '.sync.json') return true;
    return _shouldIgnoreFingerprintPath(rel);
  }

  Future<Map<String, dynamic>?> _getRemoteQuestManifest({
    required GitHubSyncSettings settings,
    required String questsPrefix,
    required String questId,
  }) async {
    final path = '$questsPrefix/$questId/.sync.json';
    final content = await _getContentFile(settings: settings, filePath: path);
    if (content == null) return null;
    final decoded = _decodeJsonContent(content['content']?.toString() ?? '');
    decoded['_sha'] = content['sha']?.toString();
    return decoded;
  }

  Future<void> _putRemoteQuestManifest({
    required GitHubSyncSettings settings,
    required String questsPrefix,
    required String questId,
    required Map<String, dynamic> manifest,
    String? previousSha,
  }) async {
    final path = '$questsPrefix/$questId/.sync.json';
    await _putContentFile(
      settings: settings,
      filePath: path,
      bytes: utf8.encode(jsonEncode(manifest)),
      message: 'sync manifest $questId',
      previousSha: previousSha,
    );
  }

  Map<String, dynamic> _buildRemoteManifest({
    required String questId,
    required String questTitle,
    required Map<String, String> files,
    Map<String, dynamic>? shas,
  }) {
    return {
      'questId': questId,
      'title': questTitle,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'files': files,
      if (shas != null) 'shas': shas,
    };
  }

  bool _detectQuestFileConflict({
    required Map<String, String> localFiles,
    required Map<String, dynamic> remoteFiles,
    required Map<String, dynamic> previousFiles,
  }) {
    final allPaths = <String>{}
      ..addAll(localFiles.keys)
      ..addAll(remoteFiles.keys.cast<String>())
      ..addAll(previousFiles.keys.cast<String>());

    for (final path in allPaths) {
      final previous = previousFiles[path]?.toString();
      if (previous == null || previous.isEmpty) continue;
      final local = localFiles[path];
      final remote = remoteFiles[path]?.toString();
      if (local != null &&
          remote != null &&
          local != previous &&
          remote != previous &&
          local != remote) {
        return true;
      }
    }
    return false;
  }

  /// Загружает один файл квеста в GitHub с автоматическим получением актуального SHA при конфликте.
  Future<String?> _uploadQuestFile({
    required GitHubSyncSettings settings,
    required String questsPrefix,
    required String questId,
    required String relativePath,
    String? previousSha,
  }) async {
    final sw = Stopwatch()..start();
    final filePath = '$questsPrefix/$questId/$relativePath';
    final localPath = await FileStorage.getFilePath(
      QuestPaths.questFile(questId, relativePath),
    );
    final file = File(localPath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();

    var currentSha = previousSha;
    const maxAttempts = 3;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final resp = await _putContentFile(
          settings: settings,
          filePath: filePath,
          bytes: bytes,
          message: 'sync file $questId/$relativePath',
          previousSha: currentSha,
        );
        sw.stop();
        print(
          '⬆️ [Sync] $questId/$relativePath '
          'size=${bytes.length}B time=${sw.elapsedMilliseconds}ms '
          'attempts=${attempt + 1}',
        );
        return resp['sha']?.toString();
      } catch (e) {
        final msg = e.toString();
        final isShaConflict =
            msg.contains('409') ||
            msg.contains('422') ||
            msg.contains('is at') ||
            (msg.contains('sha') && msg.contains('but expected'));

        if (!isShaConflict || attempt >= maxAttempts - 1) {
          throw GitHubSyncConflictException(filePath);
        }

        // Получаем свежий SHA перед повтором
        try {
          final existing = await _getContentFile(
            settings: settings,
            filePath: filePath,
          );
          final freshSha = existing?['sha']?.toString();
          if (freshSha == null || freshSha.isEmpty) {
            throw GitHubSyncConflictException(filePath);
          }
          currentSha = freshSha;
        } catch (_) {
          throw GitHubSyncConflictException(filePath);
        }

        await Future.delayed(_backoffDelay(attempt));
      }
    }

    throw GitHubSyncConflictException(filePath);
  }

  Future<void> _downloadQuestFile({
    required GitHubSyncSettings settings,
    required String questsPrefix,
    required String questId,
    required String relativePath,
  }) async {
    final sw = Stopwatch()..start();
    final filePath = '$questsPrefix/$questId/$relativePath';
    final bytes = await _downloadContentFileBytes(
      settings: settings,
      filePath: filePath,
    );
    final localPath = await FileStorage.getFilePath(
      QuestPaths.questFile(questId, relativePath),
    );
    final file = File(localPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    sw.stop();
    print(
      '⬇️ [Sync] $questId/$relativePath '
      'size=${bytes.length}B time=${sw.elapsedMilliseconds}ms',
    );
  }

  Future<void> _downloadRemoteQuestFolder({
    required GitHubSyncSettings settings,
    required String questsPrefix,
    required String questId,
  }) async {
    final manifest = await _getRemoteQuestManifest(
      settings: settings,
      questsPrefix: questsPrefix,
      questId: questId,
    );
    final filesRaw = manifest?['files'];
    if (filesRaw is! Map) return;
    final files = Map<String, dynamic>.from(filesRaw);
    for (final entry in files.entries) {
      await _downloadQuestFile(
        settings: settings,
        questsPrefix: questsPrefix,
        questId: questId,
        relativePath: entry.key,
      );
    }
  }

  /// Безопасная обёртка над [_uploadQuestFile].
  /// Любые исключения (включая сетевые и auth) преобразуются в conflict: true,
  /// чтобы один сломанный файл не роняли весь sync.
  Future<_UploadResult> _safeUploadQuestFile({
    required GitHubSyncSettings settings,
    required String questsPrefix,
    required String questId,
    required String relativePath,
    required String? previousSha,
  }) async {
    try {
      final sha = await _uploadQuestFile(
        settings: settings,
        questsPrefix: questsPrefix,
        questId: questId,
        relativePath: relativePath,
        previousSha: previousSha,
      );
      return _UploadResult(path: relativePath, sha: sha, conflict: false);
    } on GitHubSyncConflictException {
      return _UploadResult(path: relativePath, sha: null, conflict: true);
    } catch (e) {
      // Сетевые ошибки, auth и прочее — не роняем весь sync
      print('❌ [Sync] upload error $questId/$relativePath: $e');
      return _UploadResult(path: relativePath, sha: null, conflict: true);
    }
  }

  List<List<T>> _chunkFutures<T>(List<T> items, int size) {
    if (items.isEmpty) return const [];
    final chunks = <List<T>>[];
    for (var i = 0; i < items.length; i += size) {
      final end = (i + size) > items.length ? items.length : (i + size);
      chunks.add(items.sublist(i, end));
    }
    return chunks;
  }

  Future<Map<String, Map<String, dynamic>>> _listRemoteQuestFilesRecursive({
    required GitHubSyncSettings settings,
    required String questsPrefix,
    required String questId,
  }) async {
    final output = <String, Map<String, dynamic>>{};

    Future<void> walk(String relPath) async {
      final path = relPath.isEmpty
          ? '$questsPrefix/$questId'
          : '$questsPrefix/$questId/$relPath';
      final uri = Uri.https(
        'api.github.com',
        '/repos/${settings.owner.trim()}/${settings.repo.trim()}/contents/$path',
        {'ref': settings.branch.trim()},
      );
      final resp = await _requestWithRetry(
        () => http.get(uri, headers: _headers(settings.token)),
        context: 'list $path',
      );
      if (resp.statusCode == 404) return;
      if (resp.statusCode != 200) {
        throw Exception(
          'GitHub list $path failed: ${resp.statusCode} ${resp.body}',
        );
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! List) return;
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final type = item['type']?.toString();
        final name = item['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        if (type == 'dir') {
          final next = relPath.isEmpty ? name : '$relPath/$name';
          await walk(next);
        } else if (type == 'file') {
          final rel = relPath.isEmpty ? name : '$relPath/$name';
          output[rel] = {'sha': item['sha']?.toString(), 'size': item['size']};
        }
      }
    }

    await walk('');
    return output;
  }

  Future<Set<String>> _listRemoteQuestFolders({
    required GitHubSyncSettings settings,
    required String questsPrefix,
  }) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/${settings.owner.trim()}/${settings.repo.trim()}/contents/$questsPrefix',
      {'ref': settings.branch.trim()},
    );
    final resp = await _requestWithRetry(
      () => http.get(uri, headers: _headers(settings.token)),
      context: 'list quest folders',
    );
    if (resp.statusCode == 404) return <String>{};
    if (resp.statusCode != 200) {
      throw Exception(
        'GitHub list $questsPrefix failed: ${resp.statusCode} ${resp.body}',
      );
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! List) return <String>{};
    final output = <String>{};
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      if (item['type']?.toString() != 'dir') continue;
      final name = item['name']?.toString() ?? '';
      if (name.isNotEmpty) output.add(name);
    }
    return output;
  }

  bool _shouldIgnoreFingerprintPath(String rel) {
    final lower = rel.toLowerCase();
    final base = p.basename(lower);
    if (lower.endsWith('.backup')) return true;
    if (lower.endsWith('.tmp')) return true;
    if (lower.contains('.tmp.')) return true;
    if (base == '.ds_store' || base == 'thumbs.db') return true;
    return false;
  }

  bool _detectConflict({
    required bool hasRemote,
    required String? previousFingerprint,
    required String localFingerprint,
    required String? remoteFingerprint,
  }) {
    if (!hasRemote) return false;
    if (remoteFingerprint == null || remoteFingerprint.isEmpty) return false;
    if (remoteFingerprint == localFingerprint) return false;
    if (previousFingerprint == null || previousFingerprint.isEmpty) return true;
    final localChanged = previousFingerprint != localFingerprint;
    final remoteChanged = previousFingerprint != remoteFingerprint;
    return localChanged && remoteChanged;
  }

  Map<String, dynamic> _sortIndexQuests(Map<String, dynamic> raw) {
    final keys = raw.keys.toList()..sort();
    final sorted = <String, dynamic>{};
    for (final key in keys) {
      sorted[key] = raw[key];
    }
    return sorted;
  }

  bool _mapsEqualString(Map<String, String> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final val = b[entry.key]?.toString();
      if (val != entry.value) return false;
    }
    return true;
  }

  Future<Map<String, Map<String, dynamic>>> _discoverRemoteQuestFiles({
    required GitHubSyncSettings settings,
    required String questsPrefix,
  }) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/${settings.owner.trim()}/${settings.repo.trim()}/contents/$questsPrefix',
      {'ref': settings.branch.trim()},
    );

    final resp = await _requestWithRetry(
      () => http.get(uri, headers: _headers(settings.token)),
      context: 'list quests',
    );
    if (resp.statusCode == 404) return <String, Map<String, dynamic>>{};
    if (resp.statusCode != 200) {
      throw Exception(
        'GitHub list $questsPrefix failed: ${resp.statusCode} ${resp.body}',
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! List) return <String, Map<String, dynamic>>{};

    final output = <String, Map<String, dynamic>>{};
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final type = item['type']?.toString();
      if (type != 'file') continue;
      final name = item['name']?.toString() ?? '';
      if (!name.toLowerCase().endsWith('.mnd')) continue;
      final questId = name.substring(0, name.length - 4).trim();
      if (questId.isEmpty) continue;
      output[questId] = {
        'id': questId,
        'title': questId,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'path': '$questsPrefix/$name',
        'sha': item['sha']?.toString(),
      };
    }
    return output;
  }

  Future<Map<String, dynamic>?> _getContentFile({
    required GitHubSyncSettings settings,
    required String filePath,
  }) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/${settings.owner.trim()}/${settings.repo.trim()}/contents/$filePath',
      {'ref': settings.branch.trim()},
    );
    final resp = await _requestWithRetry(
      () => http.get(uri, headers: _headers(settings.token)),
      context: 'get $filePath',
    );
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw Exception(
        'GitHub GET $filePath failed: ${resp.statusCode} ${resp.body}',
      );
    }
    final json = jsonDecode(resp.body);
    if (json is Map<String, dynamic>) return json;
    throw Exception('Unexpected GitHub response for $filePath');
  }

  Future<Map<String, dynamic>> _putContentFile({
    required GitHubSyncSettings settings,
    required String filePath,
    required List<int> bytes,
    required String message,
    String? previousSha,
  }) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/${settings.owner.trim()}/${settings.repo.trim()}/contents/$filePath',
    );
    final payload = <String, dynamic>{
      'message': message,
      'content': base64Encode(bytes),
      'branch': settings.branch.trim(),
    };
    if (previousSha != null && previousSha.trim().isNotEmpty) {
      payload['sha'] = previousSha.trim();
    }

    final resp = await _requestWithRetry(
      () => http.put(
        uri,
        headers: _headers(settings.token),
        body: jsonEncode(payload),
      ),
      context: 'put $filePath',
    );

    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw Exception(
        'GitHub PUT $filePath failed: ${resp.statusCode} ${resp.body}',
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is Map<String, dynamic> &&
        decoded['content'] is Map<String, dynamic>) {
      return Map<String, dynamic>.from(decoded['content'] as Map);
    }
    throw Exception('Unexpected GitHub PUT response for $filePath');
  }

  Future<List<int>> _downloadContentFileBytes({
    required GitHubSyncSettings settings,
    required String filePath,
  }) async {
    final content = await _getContentFile(
      settings: settings,
      filePath: filePath,
    );
    if (content == null) {
      throw Exception('Remote file not found: $filePath');
    }
    final encoded = (content['content'] ?? '').toString().replaceAll('\n', '');
    if (encoded.isEmpty) {
      throw Exception('Remote file is empty: $filePath');
    }
    return base64Decode(encoded);
  }

  Future<String?> _importQuestFromBytes(
    List<int> bytes,
    String questIdHint,
  ) async {
    final tempPath = await FileStorage.getFilePath(
      'temp/sync_import_${DateTime.now().millisecondsSinceEpoch}_$questIdHint.mnd',
    );
    final file = File(tempPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    try {
      return await AsyncImportService.importFromFile(tempPath);
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Map<String, dynamic> _decodeJsonContent(String encodedContent) {
    final cleaned = encodedContent.replaceAll('\n', '').trim();
    if (cleaned.isEmpty) return <String, dynamic>{};
    final bytes = base64Decode(cleaned);
    final raw = utf8.decode(bytes);
    final json = jsonDecode(raw);
    if (json is Map<String, dynamic>) return json;
    if (json is Map) return Map<String, dynamic>.from(json);
    return <String, dynamic>{};
  }

  double _stepProgress(int done, int total) {
    if (total <= 0) return 0;
    final raw = done / total;
    return raw.clamp(0.0, 0.98);
  }

  String _normalizeRoot(String raw) {
    final normalized = raw.trim().replaceAll('\\', '/');
    return normalized.replaceAll(RegExp(r'^/+|/+$'), '');
  }

  Map<String, String> _headers(String token) {
    return {
      HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
      HttpHeaders.acceptHeader: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'Meander-Sync-MVP',
      HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
    };
  }

  bool _isRetryableStatus(int code) {
    return code == 429 ||
        code == 500 ||
        code == 502 ||
        code == 503 ||
        code == 504;
  }

  Duration _backoffDelay(int attempt) {
    final ms = 400 * (1 << attempt);
    return Duration(milliseconds: ms.clamp(400, 4000));
  }

  Future<http.Response> _requestWithRetry(
    Future<http.Response> Function() request, {
    String? context,
  }) async {
    int attempt = 0;
    while (true) {
      final sw = Stopwatch()..start();
      try {
        final resp = await request().timeout(_httpTimeout);
        sw.stop();
        if (context != null) {
          print(
            '🌐 [HTTP] $context status=${resp.statusCode} '
            'time=${sw.elapsedMilliseconds}ms',
          );
        }
        if (resp.statusCode == 403 &&
            (resp.headers['x-ratelimit-remaining'] == '0')) {
          final reset = resp.headers['x-ratelimit-reset'];
          throw Exception(
            'GitHub rate limit. Retry after ${reset ?? 'a few minutes'}.',
          );
        }
        if (_isRetryableStatus(resp.statusCode) && attempt < _maxRetries - 1) {
          await Future.delayed(_backoffDelay(attempt));
          attempt++;
          continue;
        }
        return resp;
      } on TimeoutException catch (_) {
        if (attempt >= _maxRetries - 1) rethrow;
        await Future.delayed(_backoffDelay(attempt));
        attempt++;
      } on SocketException catch (_) {
        if (attempt >= _maxRetries - 1) rethrow;
        await Future.delayed(_backoffDelay(attempt));
        attempt++;
      }
    }
  }

  Future<void> forceUploadQuest({
    required GitHubSyncSettings settings,
    required String questId,
    required String questTitle,
    required void Function(GitHubSyncProgress p) onProgress,
  }) async {
    await validateConnection(settings);

    final normalizedRoot = _normalizeRoot(settings.rootPath);
    final indexPath = normalizedRoot.isEmpty
        ? 'index.json'
        : '$normalizedRoot/index.json';
    final questsPrefix = normalizedRoot.isEmpty
        ? 'quests'
        : '$normalizedRoot/quests';

    onProgress(
      GitHubSyncProgress(message: tr('Чтение индекса...'), progress: 0.1),
    );
    final remoteIndexFile = await _getContentFile(
      settings: settings,
      filePath: indexPath,
    );
    final remoteIndex = remoteIndexFile == null
        ? <String, dynamic>{'quests': <String, dynamic>{}}
        : _decodeJsonContent(remoteIndexFile['content']?.toString() ?? '');
    final format = (remoteIndex['format']?.toString() ?? '').trim();
    final useFileSync = format.isEmpty || format == 'files';
    final remoteQuestsRaw = remoteIndex['quests'];
    final remoteQuests = remoteQuestsRaw is Map
        ? Map<String, dynamic>.from(remoteQuestsRaw)
        : <String, dynamic>{};

    if (useFileSync) {
      onProgress(
        GitHubSyncProgress(message: tr('Подготовка файлов...'), progress: 0.2),
      );
      final localSnapshot = await _collectLocalQuestFileSnapshot(questId);
      final localFiles = localSnapshot.hashes;
      final remoteManifest = await _getRemoteQuestManifest(
        settings: settings,
        questsPrefix: questsPrefix,
        questId: questId,
      );
      final manifestSha = remoteManifest?['_sha']?.toString();
      final remoteFilesRaw = remoteManifest?['files'];
      final remoteFiles = remoteFilesRaw is Map
          ? Map<String, dynamic>.from(remoteFilesRaw)
          : <String, dynamic>{};

      final remoteShasRaw = remoteManifest?['shas'];
      final remoteShas = remoteShasRaw is Map
          ? Map<String, dynamic>.from(remoteShasRaw)
          : <String, dynamic>{};

      final updatedShas = Map<String, dynamic>.from(remoteShas);
      final tasks = <Future<MapEntry<String, String?>>>[];
      for (final entry in localFiles.entries) {
        final remoteHash = remoteFiles[entry.key]?.toString();
        if (remoteHash == entry.value) continue;
        final knownSha = remoteShas[entry.key]?.toString();
        tasks.add(
          _uploadQuestFile(
            settings: settings,
            questsPrefix: questsPrefix,
            questId: questId,
            relativePath: entry.key,
            previousSha: knownSha,
          ).then((sha) => MapEntry(entry.key, sha)),
        );
      }
      for (final batch in _chunkFutures(tasks, 4)) {
        final results = await Future.wait(batch, eagerError: false);
        for (final res in results) {
          if (res.value != null && res.value!.isNotEmpty) {
            updatedShas[res.key] = res.value!;
          }
        }
      }

      final manifest = _buildRemoteManifest(
        questId: questId,
        questTitle: questTitle,
        files: localFiles,
        shas: updatedShas,
      );
      await _putRemoteQuestManifest(
        settings: settings,
        questsPrefix: questsPrefix,
        questId: questId,
        manifest: manifest,
        previousSha: manifestSha,
      );

      remoteQuests[questId] = {
        'id': questId,
        'title': questTitle,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'path': '$questsPrefix/$questId',
      };
      remoteIndex['quests'] = remoteQuests;
      remoteIndex['format'] = 'files';

      onProgress(
        GitHubSyncProgress(
          message: tr('Обновление индекса...'),
          progress: 0.85,
        ),
      );
      final updatedIndex = {
        'format': 'files',
        'quests': _sortIndexQuests(remoteQuests),
      };
      await _putContentFile(
        settings: settings,
        filePath: indexPath,
        bytes: utf8.encode(jsonEncode(updatedIndex)),
        message: 'sync index',
        previousSha: remoteIndexFile?['sha']?.toString(),
      );

      final localSyncState = await _loadLocalSyncState();
      final fileHashesRaw = localSyncState['fileHashes'];
      final fileHashes = fileHashesRaw is Map
          ? Map<String, dynamic>.from(fileHashesRaw)
          : <String, dynamic>{};
      fileHashes[questId] = localFiles;
      await _saveLocalSyncState({
        'fingerprints': (localSyncState['fingerprints'] is Map)
            ? Map<String, dynamic>.from(localSyncState['fingerprints'] as Map)
            : <String, dynamic>{},
        'fileHashes': fileHashes,
      });

      onProgress(GitHubSyncProgress(message: tr('Готово'), progress: 1.0));
      return;
    }

    onProgress(
      GitHubSyncProgress(message: tr('Архивация квеста...'), progress: 0.3),
    );
    final fingerprint = await _computeQuestFingerprint(questId);
    final data = await ExportService.createMndFile(
      questId,
      nodesFormat: QuestArchiveNodesFormat.legacy,
    );

    final remoteFilePath = '$questsPrefix/$questId.mnd';
    String? previousSha;
    final entry = remoteQuests[questId];
    if (entry is Map) {
      previousSha = entry['sha']?.toString();
    }

    onProgress(
      GitHubSyncProgress(message: tr('Загрузка в GitHub...'), progress: 0.6),
    );
    final uploadedMeta = await _putContentFile(
      settings: settings,
      filePath: remoteFilePath,
      bytes: data,
      message: 'force sync quest $questId',
      previousSha: previousSha,
    );

    remoteQuests[questId] = {
      'id': questId,
      'title': questTitle,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'path': remoteFilePath,
      'sha': uploadedMeta['sha']?.toString(),
      'fingerprint': fingerprint,
    };

    onProgress(
      GitHubSyncProgress(message: tr('Обновление индекса...'), progress: 0.85),
    );
    final updatedIndex = {'quests': _sortIndexQuests(remoteQuests)};
    await _putContentFile(
      settings: settings,
      filePath: indexPath,
      bytes: utf8.encode(jsonEncode(updatedIndex)),
      message: 'sync index',
      previousSha: remoteIndexFile?['sha']?.toString(),
    );

    final localSyncState = await _loadLocalSyncState();
    final localFingerprintsRaw = localSyncState['fingerprints'];
    final localFingerprints = localFingerprintsRaw is Map
        ? Map<String, dynamic>.from(localFingerprintsRaw)
        : <String, dynamic>{};
    localFingerprints[questId] = fingerprint;
    await _saveLocalSyncState({'fingerprints': localFingerprints});

    onProgress(GitHubSyncProgress(message: tr('Готово'), progress: 1.0));
  }

  Future<void> forceDownloadQuest({
    required GitHubSyncSettings settings,
    required String questId,
    required void Function(GitHubSyncProgress p) onProgress,
  }) async {
    await validateConnection(settings);

    final normalizedRoot = _normalizeRoot(settings.rootPath);
    final indexPath = normalizedRoot.isEmpty
        ? 'index.json'
        : '$normalizedRoot/index.json';
    final questsPrefix = normalizedRoot.isEmpty
        ? 'quests'
        : '$normalizedRoot/quests';

    onProgress(
      GitHubSyncProgress(message: tr('Чтение индекса...'), progress: 0.1),
    );
    final remoteIndexFile = await _getContentFile(
      settings: settings,
      filePath: indexPath,
    );
    final remoteIndex = remoteIndexFile == null
        ? <String, dynamic>{'quests': <String, dynamic>{}}
        : _decodeJsonContent(remoteIndexFile['content']?.toString() ?? '');
    final format = (remoteIndex['format']?.toString() ?? '').trim();
    final useFileSync = format.isEmpty || format == 'files';

    if (useFileSync) {
      await _downloadRemoteQuestFolder(
        settings: settings,
        questsPrefix: questsPrefix,
        questId: questId,
      );
      final fp = await _collectLocalQuestFileSnapshot(questId);
      final localSyncState = await _loadLocalSyncState();
      final fileHashesRaw = localSyncState['fileHashes'];
      final fileHashes = fileHashesRaw is Map
          ? Map<String, dynamic>.from(fileHashesRaw)
          : <String, dynamic>{};
      fileHashes[questId] = fp.hashes;
      await _saveLocalSyncState({
        'fingerprints': (localSyncState['fingerprints'] is Map)
            ? Map<String, dynamic>.from(localSyncState['fingerprints'] as Map)
            : <String, dynamic>{},
        'fileHashes': fileHashes,
      });
      onProgress(GitHubSyncProgress(message: tr('Готово'), progress: 1.0));
      return;
    }

    final remoteQuestsRaw = remoteIndex['quests'];
    final remoteQuests = remoteQuestsRaw is Map
        ? Map<String, dynamic>.from(remoteQuestsRaw)
        : <String, dynamic>{};
    final entry = remoteQuests[questId];
    String path = '$questsPrefix/$questId.mnd';
    if (entry is Map &&
        (entry['path']?.toString().trim().isNotEmpty ?? false)) {
      path = entry['path'].toString();
    }

    onProgress(GitHubSyncProgress(message: tr('Скачивание...'), progress: 0.6));
    final bytes = await _downloadContentFileBytes(
      settings: settings,
      filePath: path,
    );
    final imported = await _importQuestFromBytes(bytes, questId);
    if (imported != null) {
      final fp = await _computeQuestFingerprint(imported);
      final localSyncState = await _loadLocalSyncState();
      final localFingerprintsRaw = localSyncState['fingerprints'];
      final localFingerprints = localFingerprintsRaw is Map
          ? Map<String, dynamic>.from(localFingerprintsRaw)
          : <String, dynamic>{};
      localFingerprints[imported] = fp;
      await _saveLocalSyncState({'fingerprints': localFingerprints});
    }

    onProgress(GitHubSyncProgress(message: tr('Готово'), progress: 1.0));
  }
}
