import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mnd_core/models/quest_descriptor.dart';
import 'package:mnd_core/models/saved_node.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:path_provider/path_provider.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/providers/tag_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:mnd_player/utils/key_derivation_service.dart';
import 'package:mnd_core/utils/quest_paths.dart';

export 'package:mnd_core/models/quest_descriptor.dart';

// План 020-C4.3: чтение/запись квеста — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};

String? _extractTitleFromRawConfig(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      final title = decoded['title']?.toString().trim();
      if (title != null && title.isNotEmpty) return title;
    } else if (decoded is Map) {
      final title = decoded['title']?.toString().trim();
      if (title != null && title.isNotEmpty) return title;
    }
  } catch (_) {
    // Ignored: this helper is best-effort only.
  }
  return null;
}

Future<void> _migrateLastEditedAt(
  String questId,
  Map<String, dynamic> config,
) async {
  // Защищённые квесты нельзя переписывать: это нарушит их подпись.
  if (config['isReadOnly'] == true || config['lastEditedAt'] != null) return;

  final fallback =
      config['updated'] ??
      config['updatedAt'] ??
      config['updated_at'] ??
      config['created'];
  if (fallback == null) return;

  config['lastEditedAt'] = fallback;
  try {
    await (await _qs()).writeJson(QuestPaths.config(questId), config);
  } catch (e) {
    print('⚠️ [Quest] Не удалось мигрировать lastEditedAt для $questId: $e');
  }
}

Quest _buildCorruptedQuest({
  required String questId,
  String? rawConfig,
  Object? error,
}) {
  final recoveredTitle = rawConfig == null
      ? null
      : _extractTitleFromRawConfig(rawConfig);
  return Quest(
    id: questId,
    title: recoveredTitle ?? questId,
    description: tr(
      'Конфигурация квеста повреждена. Доступен экспорт для ручного восстановления.',
    ),
    isCorrupted: true,
    loadError: error?.toString(),
  );
}

final questsProvider = FutureProvider<List<Quest>>((ref) async {
  final questsDir = Directory(
    await FileStorage.getFilePath(QuestPaths.questsDir),
  );
  if (!await questsDir.exists()) {
    await questsDir.create(recursive: true);
    return [];
  }

  final questFolders = await FileStorage.listFolders(QuestPaths.questsDir);
  if (questFolders.isEmpty) return [];

  final appDir = await getApplicationDocumentsDirectory();
  final quests = <Quest>[];

  for (final questId in questFolders) {
    try {
      final configPath = '${appDir.path}/${QuestPaths.config(questId)}';
      final configFile = File(configPath);
      if (!await configFile.exists()) {
        quests.add(
          _buildCorruptedQuest(
            questId: questId,
            error: tr('config.json не найден'),
          ),
        );
        continue;
      }

      final content = await configFile.readAsString();

      // Проверяем валидность JSON перед парсингом
      Map<String, dynamic> config;
      try {
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          config = decoded;
        } else if (decoded is Map) {
          config = Map<String, dynamic>.from(decoded);
        } else {
          throw FormatException(tr('config.json не является JSON-объектом'));
        }
      } catch (parseError) {
        print(
          '❌ [Quests] Повреждён config.json для квеста $questId: $parseError',
        );

        // Пробуем восстановить из бэкапа
        final backupPath = '$configPath.backup';
        final backupFile = File(backupPath);
        if (await backupFile.exists()) {
          try {
            final backupContent = await backupFile.readAsString();
            final backupDecoded = jsonDecode(backupContent);
            if (backupDecoded is Map<String, dynamic>) {
              config = backupDecoded;
            } else if (backupDecoded is Map) {
              config = Map<String, dynamic>.from(backupDecoded);
            } else {
              throw FormatException(
                tr('backup config.json не является JSON-объектом'),
              );
            }
            print(
              '🔄 [Quests] Восстановление config.json из бэкапа для $questId',
            );
            // Восстанавливаем основной файл
            await configFile.writeAsString(backupContent);
          } catch (backupError) {
            print('❌ [Quests] Не удалось восстановить из бэкапа: $backupError');
            quests.add(
              _buildCorruptedQuest(
                questId: questId,
                rawConfig: content,
                error: backupError,
              ),
            );
            continue;
          }
        } else {
          print('⚠️ [Quests] Бэкап не найден, пропускаем квест $questId');
          quests.add(
            _buildCorruptedQuest(
              questId: questId,
              rawConfig: content,
              error: parseError,
            ),
          );
          continue;
        }
      }

      String? localPreviewPath;
      final previewFileName = config['previewFileName']?.toString();

      if (previewFileName != null && previewFileName.isNotEmpty) {
        final fullPath =
            '${appDir.path}/${QuestPaths.questFile(questId, previewFileName)}';
        if (await File(fullPath).exists()) {
          localPreviewPath = fullPath;
        }
      } else {
        final fallbackPath = '${appDir.path}/${QuestPaths.preview(questId)}';
        if (await File(fallbackPath).exists()) {
          localPreviewPath = fallbackPath;
        }
      }

      // Проверяем HMAC-подпись, если квест защищён от чтения
      final isReadOnly = config['isReadOnly'] as bool? ?? false;
      if (isReadOnly) {
        final signature = config['signature']?.toString();
        if (signature == null || signature.isEmpty) {
          print(
            '[SIGNATURE] Quest $questId: signature MISSING, isReadOnly=true',
          );
          throw Exception(
            tr(
              'Квест поврежден или модифицирован сторонним лицом (HMAC Error: нет подписи)',
            ),
          );
        }
        if (!KeyDerivationService.verifyConfigSignature(
          questId,
          true,
          signature,
        )) {
          print('[SIGNATURE] Quest $questId: MISMATCH');
          print(
            '  expected=${KeyDerivationService.generateConfigSignature(questId, true)}',
          );
          print('  actual=$signature');
          print('  folder questId=$questId, config id=${config['id']}');
          print('  isReadOnly=${config['isReadOnly']}');
          throw Exception(
            tr(
              'Квест поврежден или модифицирован сторонним лицом (HMAC Error)',
            ),
          );
        }
      }

      await _migrateLastEditedAt(questId, config);
      quests.add(
        Quest.fromJson(
          config,
        ).copyWith(id: questId, localPreviewPath: localPreviewPath),
      );
    } catch (e) {
      print('❌ Ошибка загрузки квеста $questId: $e');
      quests.add(_buildCorruptedQuest(questId: questId, error: e));
    }
  }

  quests.sort((a, b) {
    final dateA = a.lastOpened ?? a.created ?? DateTime(1970);
    final dateB = b.lastOpened ?? b.created ?? DateTime(1970);
    return dateB.compareTo(dateA);
  });

  return quests;
});

final questProvider = FutureProvider.family<Quest?, String>((
  ref,
  questId,
) async {
  try {
    final configPath = QuestPaths.config(questId);
    if (!await (await _qs()).exists(configPath)) {
      return null;
    }

    Map<String, dynamic> config;
    try {
      config = await _readMap(configPath);
    } catch (readError) {
      print('❌ [Quest] Ошибка чтения config.json для $questId: $readError');

      // Пробуем восстановить из бэкапа
      final backupPath = QuestPaths.configBackup(questId);
      if (await (await _qs()).exists(backupPath)) {
        try {
          print('🔄 [Quest] Попытка восстановления из бэкапа...');
          final backupFile = File(await FileStorage.getFilePath(backupPath));
          final backupContent = await backupFile.readAsString();
          final backupDecoded = jsonDecode(backupContent);
          if (backupDecoded is Map<String, dynamic>) {
            config = backupDecoded;
          } else if (backupDecoded is Map) {
            config = Map<String, dynamic>.from(backupDecoded);
          } else {
            throw FormatException(
              tr('backup config.json не является JSON-объектом'),
            );
          }

          // Восстанавливаем основной файл
          await (await _qs()).writeJson(configPath, config);
          print('✅ [Quest] Успешное восстановление из бэкапа');
        } catch (backupError) {
          print('❌ [Quest] Не удалось восстановить из бэкапа: $backupError');
          return null;
        }
      } else {
        return null;
      }
    }

    final now = DateTime.now();

    String? localPreviewPath;
    final previewFileName = config['previewFileName']?.toString();

    if (previewFileName != null && previewFileName.isNotEmpty) {
      final fullPath = await FileStorage.getFilePath(
        QuestPaths.questFile(questId, previewFileName),
      );
      if (await File(fullPath).exists()) {
        localPreviewPath = fullPath;
      }
    } else {
      final fallbackPath = await FileStorage.getFilePath(
        QuestPaths.preview(questId),
      );
      if (await File(fallbackPath).exists()) {
        localPreviewPath = fallbackPath;
      }
    }

    // Проверяем подпись
    final isReadOnly = config['isReadOnly'] as bool? ?? false;
    if (isReadOnly) {
      final signature = config['signature']?.toString();
      if (signature == null || signature.isEmpty) {
        print(
          '[SIGNATURE] Quest $questId (single): signature MISSING, isReadOnly=true',
        );
        throw Exception(
          tr(
            'Квест поврежден или модифицирован сторонним лицом (HMAC Error: нет подписи)',
          ),
        );
      }
      if (!KeyDerivationService.verifyConfigSignature(
        questId,
        true,
        signature,
      )) {
        print('[SIGNATURE] Quest $questId (single): MISMATCH');
        print(
          '  expected=${KeyDerivationService.generateConfigSignature(questId, true)}',
        );
        print('  actual=$signature');
        print('  folder questId=$questId, config id=${config['id']}');
        print('  isReadOnly=${config['isReadOnly']}');
        throw Exception(
          tr('Квест поврежден или модифицирован сторонним лицом (HMAC Error)'),
        );
      }
    }

    await _migrateLastEditedAt(questId, config);

    // Первое открытие старого квеста: переводим ноды на v2 с бэкапом.
    // Ошибка миграции не должна блокировать открытие — остаёмся на legacy.
    try {
      await QuestNodesStore.ensurePerNode(questId);
    } catch (e) {
      print('⚠️ [Quest] per-node migration failed: $e');
    }

    final updatedQuest = Quest.fromJson(config).copyWith(
      id: questId,
      lastOpened: now,
      localPreviewPath: localPreviewPath,
    );

    unawaited(
      FileStorage.writeJsonFile(configPath, {
        ...config,
        'lastOpened': now.toIso8601String(),
      }),
    );

    // Автоматическая очистка нод без chapterId (исправление бага после копирования главы)
    unawaited(
      cleanupNodesWithoutChapter(questId).then((count) {
        if (count > 0) {
          print('🧹 [Quest] Автоматически удалено $count нод без chapterId');
        }
      }),
    );

    return updatedQuest;
  } catch (e) {
    print('❌ [Quest] Критическая ошибка загрузки квеста $questId: $e');
    return null;
  }
});

/// Сохранить импортированный квест (из URQ или другого формата)
Future<void> saveImportedQuest({
  required Quest quest,
  required List<SavedNode> nodes,
  Map<String, dynamic> scripts = const {},
}) async {
  final questId = quest.id;
  final uuid = const Uuid();

  try {
    // Создаём директорию квеста
    final questDir = Directory(
      await FileStorage.getFilePath(QuestPaths.questRoot(questId)),
    );
    if (!await questDir.exists()) {
      await questDir.create(recursive: true);
    }

    // Создаём дефолтный тег для импортированного квеста
    // Этот же ID будет использоваться как chapterId для всех нод
    final defaultChapterId = uuid.v4();
    final defaultTag = {
      'id': defaultChapterId,
      'name': tr('Основной'),
      'questId': questId,
    };

    // Сохраняем config.json
    final configData = quest.toJson();
    final nowIso = DateTime.now().toIso8601String();
    configData['created'] = nowIso;
    configData['lastEditedAt'] = nowIso;
    // Импортированный квест помечаем как только что открытый — чтобы
    // он оказался в самом верху библиотеки (сортировка по openedDate).
    configData['lastOpened'] = nowIso;
    configData['tags'] = [defaultTag];
    await (await _qs()).writeJson(QuestPaths.config(questId), configData);

    print('📝 [Import] Quest config:');
    print('   ID: ${quest.id}');
    print('   startNodeId: ${quest.startNodeId}');
    print('   configData[startNodeId]: ${configData['startNodeId']}');
    print('   Nodes count: ${nodes.length}');
    print('   First node ID: ${nodes.first.id}');

    // Создаём директорию нод
    final nodesDir = Directory(
      await FileStorage.getFilePath(QuestPaths.nodesDir(questId)),
    );
    if (!await nodesDir.exists()) {
      await nodesDir.create(recursive: true);
    }

    // Сохраняем ноды с chapterId = defaultChapterId (ID тега)
    final nodesData = <Map<String, dynamic>>[];
    for (final node in nodes) {
      // Обновляем chapterId - используем Map напрямую вместо copyWith
      final nodeJson = node.toJson();
      nodeJson['chapterId'] = defaultChapterId;
      nodesData.add(nodeJson);
    }

    await QuestNodesStore.write(questId, {
      'nodes': nodesData,
      'groups': [],
      'comments': [],
    });

    // Скрипты URQ-конвертера (assign/condition/goto в event-обёртке).
    for (final entry in scripts.entries) {
      await (await _qs()).writeJson(
        QuestPaths.questFile(questId, entry.key),
        entry.value,
      );
    }

    print('✅ [Import] Квест "${quest.title}" успешно импортирован');
  } catch (e) {
    print('❌ [Import] Ошибка сохранения импортированного квеста: $e');
    rethrow;
  }
}
