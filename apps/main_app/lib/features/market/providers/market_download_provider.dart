import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/async_import_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/quests/providers/cloud_sync_provider.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:mnd_player/utils/key_derivation_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mnd_core/utils/quest_paths.dart';

/// Состояние одной загрузки квеста
class QuestDownloadState {
  final double progress;
  final String status;
  final String? error;
  final bool isCompleted;

  const QuestDownloadState({
    this.progress = 0.0,
    this.status = '',
    this.error,
    this.isCompleted = false,
  });

  bool get isRunning => !isCompleted && error == null;
  bool get hasFailed => error != null;

  QuestDownloadState copyWith({
    double? progress,
    String? status,
    String? error,
    bool? isCompleted,
  }) {
    return QuestDownloadState(
      progress: progress ?? this.progress,
      status: status ?? this.status,
      error: error ?? this.error,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }
}

/// Нотифаер, управляющий фоновыми загрузками квестов с маркета.
/// Живёт на уровне приложения — загрузки продолжаются после ухода с экрана.
class MarketDownloadNotifier
    extends StateNotifier<Map<String, QuestDownloadState>> {
  final Ref _ref;

  MarketDownloadNotifier(this._ref) : super({});

  /// Возвращает true, если для данного quest.id уже идёт загрузка.
  bool isDownloading(String questId) => state[questId]?.isRunning ?? false;

  /// Запускает загрузку квеста в фоне. Метод сразу возвращается.
  /// Прогресс обновляется через state, виджет может его слушать.
  Future<void> startDownload({
    required MarketQuest quest,
    required String token,
  }) async {
    if (isDownloading(quest.id)) return;

    _updateState(quest.id, const QuestDownloadState(progress: 0.0, status: ''));

    // Сама загрузка запускается «fire and forget»
    unawaited(_runDownload(quest: quest, token: token));
  }

  Future<void> _runDownload({
    required MarketQuest quest,
    required String token,
  }) async {
    try {
      _updateState(
        quest.id,
        QuestDownloadState(
          progress: 0.0,
          status: tr('Регистрация загрузки...'),
        ),
      );

      // Регистрируем загрузку на сервере
      try {
        await _ref.read(apiServiceProvider).post('quests/${quest.id}/download');
      } catch (e) {
        print("Download tracking warning: $e");
      }

      _updateState(
        quest.id,
        QuestDownloadState(progress: 0.0, status: tr('Загрузка файла...')),
      );

      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/${quest.id}.mnd');

      final httpClient = http.Client();
      Uint8List? uint8Bytes;
      Object? lastDownloadError;

      bool isAuthError(Object error) {
        final message = error.toString();
        return message.contains('HTTP 401') || message.contains('HTTP 403');
      }

      Future<Uint8List> downloadFromUri(
        Uri uri, {
        required bool includeAuth,
      }) async {
        final request = http.Request('GET', uri);
        request.headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';
        if (includeAuth && token.trim().isNotEmpty) {
          request.headers['Authorization'] = 'Bearer $token';
        }

        final streamedResponse = await httpClient
            .send(request)
            .timeout(
              const Duration(minutes: 5),
              onTimeout: () {
                throw TimeoutException(tr('Загрузка превысила время ожидания'));
              },
            );

        final contentLength = streamedResponse.contentLength;

        if (streamedResponse.statusCode != 200) {
          throw HttpException(
            'HTTP ${streamedResponse.statusCode}: ${streamedResponse.reasonPhrase}',
          );
        }

        final bytes = <int>[];
        int downloadedBytes = 0;
        const int updateInterval = 1024 * 100;

        await for (final chunk in streamedResponse.stream) {
          bytes.addAll(chunk);
          downloadedBytes += chunk.length;

          if (contentLength != null &&
              downloadedBytes % updateInterval < chunk.length) {
            _updateState(
              quest.id,
              QuestDownloadState(
                progress: downloadedBytes / contentLength,
                status: tr('Загрузка файла...'),
              ),
            );
          }
        }

        if (contentLength != null) {
          _updateState(
            quest.id,
            QuestDownloadState(progress: 1.0, status: tr('Загрузка файла...')),
          );
        }

        return Uint8List.fromList(bytes);
      }

      final candidateUris = <Uri>[];
      try {
        candidateUris.add(Uri.parse(quest.downloadUrl));
      } catch (_) {}
      final fallbackUrl =
          '${AppConfig.apiUrl}/static/downloads/${quest.id}.mnd';
      if (candidateUris.isEmpty ||
          candidateUris.first.toString() != fallbackUrl) {
        candidateUris.add(Uri.parse(fallbackUrl));
      }

      try {
        for (final uri in candidateUris) {
          _updateState(
            quest.id,
            QuestDownloadState(progress: 0.0, status: tr('Загрузка файла...')),
          );
          try {
            uint8Bytes = await downloadFromUri(uri, includeAuth: true);
            break;
          } catch (e) {
            lastDownloadError = e;
            if (isAuthError(e)) {
              try {
                uint8Bytes = await downloadFromUri(uri, includeAuth: false);
                break;
              } catch (e2) {
                lastDownloadError = e2;
              }
            }
          }
        }
      } finally {
        httpClient.close();
      }

      if (uint8Bytes == null || uint8Bytes.isEmpty) {
        throw lastDownloadError ?? Exception(tr('Не удалось скачать файл'));
      }

      await tempFile.writeAsBytes(uint8Bytes, flush: true);

      if (!await tempFile.exists()) {
        throw Exception(tr('Файл не был создан'));
      }

      _updateState(
        quest.id,
        QuestDownloadState(progress: 1.0, status: tr('Установка...')),
      );

      final importedQuestId = await AsyncImportService.importFromFile(
        tempFile.path,
      );

      if (importedQuestId == null) throw Exception('Import failed');

      // Определяем права доступа
      final isAdmin = await _isCurrentUserAdmin();

      try {
        final configPath = QuestPaths.config(importedQuestId);
        if (await FileStorage.exists(configPath)) {
          final config = await FileStorage.readJsonFile(configPath);
          final bool questAllowsOpen =
              config['allowOpenContent'] as bool? ?? false;
          final bool makeReadOnly = !isAdmin && !questAllowsOpen;
          config['isReadOnly'] = makeReadOnly;
          if (makeReadOnly) {
            config['signature'] = KeyDerivationService.generateConfigSignature(
              importedQuestId,
              true,
            );
          }
          config['isMarketDownloaded'] = true;
          config['marketQuestId'] = quest.id;
          config['author'] = quest.authorName ?? config['author'];
          if (quest.authorId != null && quest.authorId!.isNotEmpty) {
            config['authorId'] = quest.authorId;
          }
          config['authorIsVerified'] = quest.authorIsVerified;
          config['marketUpdatedAt'] = quest.updatedAt.toUtc().toIso8601String();
          config['marketVersion'] = quest.version;
          config['lastOpened'] = DateTime.now().toIso8601String();
          await FileStorage.writeJsonFile(configPath, config);
        }
      } catch (e) {
        print('Ошибка обновления флагов маркет-квеста: $e');
      }

      // Обновляем список квестов
      _ref.invalidate(questsProvider);

      // Квест из маркета попадает в облако сразу, без кнопки: ref не тратит
      // байты квоты, а «Мои квесты» на другом устройстве должны догонять
      // библиотеку сами. Ошибки (гость, нет доступа к облаку, нет сети) тут
      // штатные — наружу не показываем.
      unawaited(
        _ref
            .read(cloudSyncServiceProvider)
            .publishMarketRefQuietly(
              questId: importedQuestId,
              title: quest.title,
              marketQuestId: quest.id,
              marketVersion: quest.version,
            ),
      );

      // Помечаем загрузку завершённой
      _updateState(
        quest.id,
        QuestDownloadState(
          progress: 1.0,
          status: tr('Готово'),
          isCompleted: true,
        ),
      );
    } catch (e) {
      print('MarketDownload Error [${quest.id}]: $e');
      _updateState(
        quest.id,
        QuestDownloadState(
          progress: 0.0,
          status: '',
          // Это печатается в снэкбаре как «Ошибка: …» — только фраза.
          error: questDownloadErrorText(e),
        ),
      );
    }
  }

  /// Очищает состояние загрузки (вызывается виджетом после показа результата)
  void clearDownload(String questId) {
    if (!state.containsKey(questId)) return;
    final newState = Map<String, QuestDownloadState>.from(state);
    newState.remove(questId);
    state = newState;
  }

  // ---------------------------------------------------------------------------

  void _updateState(String questId, QuestDownloadState downloadState) {
    state = {...state, questId: downloadState};
  }

  Future<bool> _isCurrentUserAdmin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null || userId.isEmpty) return false;
      final profile = await _ref.read(userProfileProvider(userId).future);
      return profile.role == 'admin';
    } catch (_) {
      return false;
    }
  }
}

/// Причина неудачной загрузки — фразой, а не трейсом.
///
/// Экран печатает `state.error` в снэкбаре как «Ошибка: …», поэтому сюда
/// попадает то, что видит человек: `HttpException` — «HttpException: HTTP 404:
/// Not Found», `SocketException` — многострочный дамп с errno, таймаут —
/// «TimeoutException after 0:00:300.000000». Новичок без сети читает это как
/// сломанное приложение, хотя дело только в соединении.
String questDownloadErrorText(Object error) {
  if (isConnectionFailure(error)) return tr('Нет соединения с сервером');
  final code = RegExp(r'HTTP (\d{3})').firstMatch('$error')?.group(1);
  if (code != null) {
    return switch (code) {
      '404' => tr('Квеста больше нет на сервере'),
      '403' || '401' => tr('Сервер не отдаёт этот квест'),
      _ => trf('Сервер не отдал квест (код {code})', {'code': code}),
    };
  }
  return friendlyError(error);
}

final marketDownloadProvider =
    StateNotifierProvider<
      MarketDownloadNotifier,
      Map<String, QuestDownloadState>
    >((ref) => MarketDownloadNotifier(ref));
