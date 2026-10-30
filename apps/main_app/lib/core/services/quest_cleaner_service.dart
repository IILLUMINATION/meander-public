import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/core/services/local_history_service.dart';
import 'package:mnd_player/services/font_service.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:mnd_player/utils/trigger_reference.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/quest_script_events.dart';

// План 020-C4.4: операции над квестом — через ядро (QuestStore).
Future<QuestStore> _qs() => QuestStore.defaultInstance();
Future<Map<String, dynamic>> _readMap(String rel) async =>
    await (await _qs()).readJson(rel) ?? <String, dynamic>{};
Future<T> _qsync<T>(String key, Future<T> Function() action) =>
    QuestStore.synchronized<T>(key, action);

class QuestCleanerIssue {
  final String id;
  final String category;
  final String title;
  final String description;
  final String type;
  final Map<String, dynamic> payload;

  const QuestCleanerIssue({
    required this.id,
    required this.category,
    required this.title,
    required this.description,
    required this.type,
    this.payload = const {},
  });
}

class QuestCleanerReport {
  final List<QuestCleanerIssue> issues;

  const QuestCleanerReport({required this.issues});

  Map<String, List<QuestCleanerIssue>> grouped() {
    final byCategory = <String, List<QuestCleanerIssue>>{};
    for (final issue in issues) {
      byCategory.putIfAbsent(issue.category, () => []).add(issue);
    }
    final sortedKeys = byCategory.keys.toList()..sort();
    final sorted = <String, List<QuestCleanerIssue>>{};
    for (final key in sortedKeys) {
      sorted[key] = byCategory[key]!;
    }
    return sorted;
  }
}

class QuestCleanerApplyResult {
  final int applied;
  final int failed;
  final List<String> errors;

  const QuestCleanerApplyResult({
    required this.applied,
    required this.failed,
    required this.errors,
  });
}

class QuestCleanerProgress {
  final double progress;
  final String stage;

  const QuestCleanerProgress({required this.progress, required this.stage});
}

class QuestCleanerService {
  Future<QuestCleanerReport> scanQuest(
    String questId, {
    void Function(QuestCleanerProgress progress)? onProgress,
  }) async {
    final issues = <QuestCleanerIssue>[];
    void emit(double value, String stage) {
      onProgress?.call(
        QuestCleanerProgress(progress: value.clamp(0.0, 1.0), stage: stage),
      );
    }

    emit(0.02, tr('Подготовка'));

    final configPath = QuestPaths.config(questId);
    if (!await (await _qs()).exists(configPath)) {
      return const QuestCleanerReport(issues: []);
    }

    final config = await _readMap(configPath);
    final metadata = await _readMetadataMap(questId);
    emit(0.08, tr('Чтение структуры квеста'));

    String resolveDisplayName(String pathOrId) {
      final normalized = _normalizeQuestRelativePath(pathOrId);
      final base = normalized.split('/').last;
      final candidates = <String>[normalized, base];
      for (final key in candidates) {
        final raw = metadata[key];
        if (raw is Map && raw['name'] != null) {
          final name = raw['name'].toString().trim();
          if (name.isNotEmpty) return name;
        }
        if (raw is String) {
          final name = raw.trim();
          if (name.isNotEmpty) return name;
        }
      }
      if (base.isNotEmpty) return base;
      return normalized.isNotEmpty ? normalized : pathOrId;
    }

    final tagsRaw = (config['tags'] as List<dynamic>? ?? []).toList();
    final tags = tagsRaw.whereType<Map>().map((e) {
      final map = <String, dynamic>{};
      e.forEach((k, v) => map[k.toString()] = v);
      return map;
    }).toList();
    final tagIds = tags
        .map((t) => t['id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();

    final nodesData = await _readNodesData(questId);
    final nodesRaw = (nodesData['nodes'] as List<dynamic>? ?? []).toList();
    final groupsRaw = (nodesData['groups'] as List<dynamic>? ?? []).toList();
    final commentsRaw = (nodesData['comments'] as List<dynamic>? ?? [])
        .toList();

    final nodes = nodesRaw.whereType<Map>().map((e) {
      final map = <String, dynamic>{};
      e.forEach((k, v) => map[k.toString()] = v);
      return map;
    }).toList();
    emit(0.18, tr('Анализ глав и нод'));

    final nodeIds = nodes
        .map((n) => n['id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    final nodeTitleById = <String, String>{
      for (final node in nodes)
        if ((node['id']?.toString().isNotEmpty ?? false))
          node['id'].toString():
              ((node['title']?.toString().trim().isNotEmpty ?? false)
              ? node['title'].toString().trim()
              : tr('Нода')),
    };

    final chapterNodeCount = <String, int>{};
    for (final node in nodes) {
      final chapterId = node['chapterId']?.toString() ?? '';
      if (chapterId.isNotEmpty) {
        chapterNodeCount.update(chapterId, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    for (final tag in tags) {
      final tagId = tag['id']?.toString() ?? '';
      if (tagId.isEmpty) continue;
      final hasNodes = (chapterNodeCount[tagId] ?? 0) > 0;
      final hasGroups = groupsRaw.any(
        (g) => (g as Map)['chapterId']?.toString() == tagId,
      );
      final hasComments = commentsRaw.any(
        (c) => (c as Map)['chapterId']?.toString() == tagId,
      );

      if (!hasNodes && !hasGroups && !hasComments) {
        issues.add(
          QuestCleanerIssue(
            id: 'chapter_empty_$tagId',
            category: tr('Главы'),
            title: trf('Пустая глава: {p0}', {'p0': tag['name'] ?? tagId}),
            description: tr('В главе нет нод, групп и комментариев.'),
            type: 'delete_chapter',
            payload: {'tagId': tagId},
          ),
        );
      }
    }

    final connections = (config['connections'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) {
          final map = <String, dynamic>{};
          e.forEach((k, v) => map[k.toString()] = v);
          return map;
        })
        .toList();

    final incoming = <String, int>{};
    final outgoing = <String, int>{};
    for (final conn in connections) {
      final fromId = conn['fromId']?.toString();
      final toId = conn['toId']?.toString();

      if (fromId != null && nodeIds.contains(fromId)) {
        outgoing.update(fromId, (v) => v + 1, ifAbsent: () => 1);
      }
      if (toId != null && nodeIds.contains(toId)) {
        incoming.update(toId, (v) => v + 1, ifAbsent: () => 1);
      }

      if (fromId == null || toId == null) {
        issues.add(
          QuestCleanerIssue(
            id: 'conn_bad_shape_${conn['id'] ?? '$fromId->$toId'}',
            category: tr('Связи'),
            title: tr('Некорректная связь'),
            description: tr('Связь без fromId/toId.'),
            type: 'remove_connection',
            payload: {'id': conn['id'], 'fromId': fromId, 'toId': toId},
          ),
        );
        continue;
      }

      if (!nodeIds.contains(fromId) || !nodeIds.contains(toId)) {
        final fromTitle = nodeTitleById[fromId] ?? tr('Удаленная нода');
        final toTitle = nodeTitleById[toId] ?? tr('Удаленная нода');
        issues.add(
          QuestCleanerIssue(
            id: 'conn_orphan_${conn['id'] ?? '$fromId->$toId'}',
            category: tr('Связи'),
            title: tr('Битая связь'),
            description: trf(
              '"{fromTitle}" -> "{toTitle}". Одна из нод удалена.',
              {'fromTitle': fromTitle, 'toTitle': toTitle},
            ),
            type: 'remove_connection',
            payload: {'id': conn['id'], 'fromId': fromId, 'toId': toId},
          ),
        );
      }
    }

    final manualNodeTargets = <String>{};
    final referencedScriptPaths = <String>{};
    final referencedResources = <String>{};

    // Реестра AutoLoad в config больше нет: движок сам находит в `scripts/`
    // скрипты, объявившие «При запуске квеста». Ниже, при разборе файлов,
    // они помечаются используемыми — иначе очистка удалила бы стартовый
    // скрипт, на который не ссылается ни одна нода.

    for (final tag in tags) {
      _collectResourceRef(
        tag['backgroundAudioId'],
        referencedResources,
        metadata,
      );
      _collectResourceRef(
        tag['backgroundAssetId'],
        referencedResources,
        metadata,
      );
    }
    _collectResourceRef(
      config['backgroundAudioId'],
      referencedResources,
      metadata,
    );
    _collectResourceRef(
      config['backgroundAssetId'],
      referencedResources,
      metadata,
    );
    _collectResourceRef(
      config['customFontFileName'],
      referencedResources,
      metadata,
    );

    for (final node in nodes) {
      final nodeId = node['id']?.toString() ?? '';
      final nodeTitle = nodeTitleById[nodeId] ?? tr('Нода');
      final chapterId = node['chapterId']?.toString() ?? '';

      if (chapterId.isEmpty) {
        issues.add(
          QuestCleanerIssue(
            id: 'node_without_chapter_$nodeId',
            category: tr('Ноды'),
            title: trf('Нода без главы: {nodeTitle}', {'nodeTitle': nodeTitle}),
            description: tr('Нода не привязана ни к одной главе.'),
            type: 'bind_node_to_first_chapter',
            payload: {'nodeId': nodeId},
          ),
        );
      } else if (!tagIds.contains(chapterId)) {
        issues.add(
          QuestCleanerIssue(
            id: 'node_with_missing_chapter_$nodeId',
            category: tr('Ноды'),
            title: trf('Нода в удаленной главе: {nodeTitle}', {
              'nodeTitle': nodeTitle,
            }),
            description: tr('У ноды отсутствует валидная глава.'),
            type: 'bind_node_to_first_chapter',
            payload: {'nodeId': nodeId},
          ),
        );
      }

      _collectResourceRef(
        node['backgroundAudioId'],
        referencedResources,
        metadata,
      );
      _collectResourceRef(
        node['backgroundAssetId'],
        referencedResources,
        metadata,
      );

      _collectScriptRef(node['scriptAssetId'], questId, referencedScriptPaths);

      final defaultActionNodeId = node['defaultActionNodeId']?.toString();
      if (defaultActionNodeId != null && defaultActionNodeId.isNotEmpty) {
        manualNodeTargets.add(defaultActionNodeId);
      }

      final content = node['content'];
      final items = content is Map
          ? (content['items'] as List<dynamic>? ?? const <dynamic>[])
          : const <dynamic>[];

      if (items.isEmpty) {
        issues.add(
          QuestCleanerIssue(
            id: 'node_empty_$nodeId',
            category: tr('Ноды'),
            title: trf('Пустая нода: {p0}', {'p0': node['title'] ?? nodeId}),
            description: tr('В ноде нет контента.'),
            type: 'delete_node',
            payload: {'nodeId': nodeId},
          ),
        );
      }

      for (final raw in items) {
        _walkContentItem(raw, (item) {
          final targetNodeId = item['targetNodeId']?.toString();
          // `_CLOSE_MODAL` — служебная цель авто-закрывающейся модалки, её
          // обрабатывает плеер; ноды с таким id в квесте и не должно быть.
          if (targetNodeId != null &&
              targetNodeId.isNotEmpty &&
              targetNodeId != '_CLOSE_MODAL' &&
              !targetNodeId.startsWith('=')) {
            manualNodeTargets.add(targetNodeId);
            if (!nodeIds.contains(targetNodeId)) {
              issues.add(
                QuestCleanerIssue(
                  id: 'target_missing_${nodeId}_${item['id'] ?? ''}',
                  category: tr('Ноды'),
                  title: tr('Ссылка на несуществующую ноду'),
                  description: trf(
                    'Нода "{nodeTitle}" содержит битую ссылку.',
                    {'nodeTitle': nodeTitle},
                  ),
                  type: 'noop',
                  payload: {},
                ),
              );
            }
          }

          _collectResourceRef(
            item['resourcePath'],
            referencedResources,
            metadata,
          );
          _collectScriptRef(
            item['scriptAssetId'],
            questId,
            referencedScriptPaths,
          );
          if (item['type']?.toString() == 'script') {
            // У script-айтема ссылка на скрипт лежит в resourcePath, а не в
            // scriptAssetId. Без этого сбора файл считается неиспользуемым,
            // и «Очистка квеста» удаляет скрипт, который нода запускает.
            _collectScriptRef(
              item['resourcePath'],
              questId,
              referencedScriptPaths,
            );
          }

          final modalButtons = item['modalButtons'];
          if (modalButtons is List) {
            for (final btn in modalButtons.whereType<Map>()) {
              _collectScriptRef(
                btn['scriptAssetId'],
                questId,
                referencedScriptPaths,
              );
              final modalTarget = btn['targetNodeId']?.toString();
              if (modalTarget != null && modalTarget.isNotEmpty) {
                manualNodeTargets.add(modalTarget);
              }
            }
          }

          final style = item['buttonStyle'];
          if (style is Map) {
            _collectResourceRef(
              style['cornerAsset'],
              referencedResources,
              metadata,
            );
            _collectResourceRef(style['hAsset'], referencedResources, metadata);
            _collectResourceRef(style['vAsset'], referencedResources, metadata);
            _collectResourceRef(
              style['centerAsset'],
              referencedResources,
              metadata,
            );
          }

          final triggers = item['scriptTriggers'];
          if (triggers is Map) {
            for (final triggerRaw in triggers.values) {
              if (triggerRaw == null) continue;
              final triggerText = triggerRaw.toString().trim();
              if (triggerText.isEmpty) continue;
              final parsed = TriggerReference.parse(triggerText);
              _collectScriptRef(
                parsed.scriptPath,
                questId,
                referencedScriptPaths,
              );
            }
          }

          // Новый формат — массив `behaviours`. Скрипт, на который ссылается
          // только он, тоже рабочий: без этого сбора «Очистка квеста»
          // удаляла файл, который нода выполняет.
          final behaviours = item['behaviours'];
          if (behaviours is List) {
            for (final beh in behaviours.whereType<Map>()) {
              final triggerRaw = beh['script'];
              if (triggerRaw == null) continue;
              final triggerText = triggerRaw.toString().trim();
              if (triggerText.isEmpty) continue;
              final parsed = TriggerReference.parse(triggerText);
              _collectScriptRef(
                parsed.scriptPath,
                questId,
                referencedScriptPaths,
              );
            }
          }
        });
      }
    }
    emit(0.42, tr('Проверка связности'));

    final scriptFiles = await _listScriptFiles(questId);
    final existingScriptSet = scriptFiles.toSet();
    emit(0.48, tr('Анализ скриптов'));

    for (int i = 0; i < scriptFiles.length; i++) {
      final scriptPath = scriptFiles[i];
      final fullPath = await FileStorage.getFilePath(
        QuestPaths.questFile(questId, scriptPath),
      );
      final scriptFile = File(fullPath);
      String content;
      try {
        content = await scriptFile.readAsString();
      } catch (e) {
        issues.add(
          QuestCleanerIssue(
            id: 'script_read_fail_${_safeId(scriptPath)}',
            category: tr('Скрипты'),
            title: trf('Скрипт не читается: {p0}', {
              'p0': resolveDisplayName(scriptPath),
            }),
            description: friendlyError(e),
            type: 'delete_script',
            payload: {'scriptPath': scriptPath},
          ),
        );
        continue;
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(content);
      } catch (e) {
        issues.add(
          QuestCleanerIssue(
            id: 'script_broken_json_${_safeId(scriptPath)}',
            category: tr('Скрипты'),
            title: trf('Битый JSON скрипта: {p0}', {
              'p0': resolveDisplayName(scriptPath),
            }),
            description: friendlyError(e),
            type: 'delete_script',
            payload: {'scriptPath': scriptPath},
          ),
        );
        continue;
      }

      if (decoded is! Map) {
        issues.add(
          QuestCleanerIssue(
            id: 'script_bad_shape_${_safeId(scriptPath)}',
            category: tr('Скрипты'),
            title: trf('Невалидная структура: {p0}', {
              'p0': resolveDisplayName(scriptPath),
            }),
            description: tr('Корневой JSON должен быть объектом.'),
            type: 'delete_script',
            payload: {'scriptPath': scriptPath},
          ),
        );
        continue;
      }

      final blocks = decoded['blocks'];
      // Движок ищет стартовые скрипты только в `scripts/` — скрипт с таким
      // же событием в `_internal_scripts/` на старте не выполнится.
      if (scriptPath.startsWith('scripts/') &&
          declaresQuestStartEvent(blocks)) {
        referencedScriptPaths.add(scriptPath);
      }
      if (blocks is! List || blocks.isEmpty) {
        issues.add(
          QuestCleanerIssue(
            id: 'script_empty_${_safeId(scriptPath)}',
            category: tr('Скрипты'),
            title: trf('Пустой скрипт: {p0}', {
              'p0': resolveDisplayName(scriptPath),
            }),
            description: tr('В скрипте нет блоков.'),
            type: 'delete_script',
            payload: {'scriptPath': scriptPath},
          ),
        );
      }

      _collectRefsFromScriptJson(
        decoded,
        manualNodeTargets: manualNodeTargets,
        referencedScriptPaths: referencedScriptPaths,
        referencedResources: referencedResources,
        questId: questId,
        metadata: metadata,
      );

      if (i % 5 == 0 || i == scriptFiles.length - 1) {
        emit(
          0.48 +
              (scriptFiles.isEmpty ? 0 : (i + 1) / scriptFiles.length) * 0.24,
          trf('Анализ скриптов ({p0}/{p1})', {
            'p0': i + 1,
            'p1': scriptFiles.length,
          }),
        );
      }
    }
    final startNodeId = config['startNodeId']?.toString();
    for (final node in nodes) {
      final nodeId = node['id']?.toString() ?? '';
      if (nodeId.isEmpty) continue;

      final hasGraphLinks =
          (incoming[nodeId] ?? 0) > 0 || (outgoing[nodeId] ?? 0) > 0;
      final hasManualLink = manualNodeTargets.contains(nodeId);
      final isStartNode = startNodeId != null && startNodeId == nodeId;

      if (!hasGraphLinks && !hasManualLink && !isStartNode) {
        final nodeTitle = nodeTitleById[nodeId] ?? tr('Нода');
        issues.add(
          QuestCleanerIssue(
            id: 'node_isolated_$nodeId',
            category: tr('Ноды'),
            title: trf('Изолированная нода: {nodeTitle}', {
              'nodeTitle': nodeTitle,
            }),
            description: tr(
              'Нода не связана переходами и не используется как целевая.',
            ),
            type: 'delete_node',
            payload: {'nodeId': nodeId},
          ),
        );
      }
    }

    for (final refScript in referencedScriptPaths) {
      if (!existingScriptSet.contains(refScript)) {
        issues.add(
          QuestCleanerIssue(
            id: 'script_missing_${_safeId(refScript)}',
            category: tr('Скрипты'),
            title: trf('Отсутствующий скрипт: {p0}', {
              'p0': resolveDisplayName(refScript),
            }),
            description: tr('На скрипт есть ссылка, но файл не найден.'),
            type: 'noop',
            payload: {},
          ),
        );
      }
    }

    for (final script in existingScriptSet) {
      if (!referencedScriptPaths.contains(script)) {
        issues.add(
          QuestCleanerIssue(
            id: 'script_unused_${_safeId(script)}',
            category: tr('Скрипты'),
            title: trf('Неиспользуемый скрипт: {p0}', {
              'p0': resolveDisplayName(script),
            }),
            description: tr('Скрипт не найден в ссылках нод/контента.'),
            type: 'delete_script',
            payload: {'scriptPath': script},
          ),
        );
      }
    }

    final resourceFiles = await _listResourceFiles(questId);
    final resourceSet = resourceFiles.toSet();

    // Собираем ссылки из всех данных квеста, а не из заготовленного списка
    // полей. Шрифт живёт в `buttonStyle.fontFamily`, в `item.fontFamily`, в
    // инлайн-теге `[font=…]` внутри текста и в пресетах конфига — ни одно из
    // этих полей очистка раньше не смотрела, файл объявлялся «неиспользуемым»
    // и удалялся с диска. Квест оставался с кнопками без шрифта.
    final fileByBase = <String, List<String>>{};
    for (final file in resourceFiles) {
      fileByBase.putIfAbsent(file.split('/').last, () => <String>[]).add(file);
    }
    for (final node in nodes) {
      _collectResourceRefsFromJson(
        node,
        referencedResources,
        metadata,
        fileByBase,
      );
    }
    _collectResourceRefsFromJson(
      config,
      referencedResources,
      metadata,
      fileByBase,
    );
    final templatesPath = QuestPaths.templates(questId);
    if (await (await _qs()).exists(templatesPath)) {
      _collectResourceRefsFromJson(
        await _readMap(templatesPath),
        referencedResources,
        metadata,
        fileByBase,
      );
    }

    emit(0.76, tr('Проверка ресурсов'));
    for (final file in resourceFiles) {
      if (!referencedResources.contains(file)) {
        issues.add(
          QuestCleanerIssue(
            id: 'resource_unused_${_safeId(file)}',
            category: tr('Ресурсы'),
            title: trf('Неиспользуемый ресурс: {p0}', {
              'p0': resolveDisplayName(file),
            }),
            description: tr('Файл не используется в главах/нодах/контенте.'),
            type: 'delete_resource',
            payload: {'resourcePath': file},
          ),
        );
      }
    }

    final metadataPath = QuestPaths.metadata(questId);
    if (await (await _qs()).exists(metadataPath)) {
      final metadata = await _readMap(metadataPath);
      final referencedForMetadata = <String>{
        ...referencedResources,
        ...referencedScriptPaths,
      };

      for (final rawKey in metadata.keys) {
        final key = _normalizeQuestRelativePath(rawKey);
        final exists =
            resourceSet.contains(key) || existingScriptSet.contains(key);

        if (!exists) {
          issues.add(
            QuestCleanerIssue(
              id: 'meta_orphan_${_safeId(key)}',
              category: 'Metadata',
              title: trf('Сиротская запись metadata: {p0}', {
                'p0': resolveDisplayName(rawKey),
              }),
              description: tr('Файл для записи metadata не найден.'),
              type: 'remove_metadata_entry',
              payload: {'metadataKey': rawKey},
            ),
          );
          continue;
        }

        if (!referencedForMetadata.contains(key)) {
          issues.add(
            QuestCleanerIssue(
              id: 'meta_unused_${_safeId(key)}',
              category: 'Metadata',
              title: trf('Неиспользуемая запись metadata: {p0}', {
                'p0': resolveDisplayName(rawKey),
              }),
              description: tr(
                'Файл существует, но не используется в текущей структуре квеста.',
              ),
              type: 'remove_metadata_entry',
              payload: {'metadataKey': rawKey},
            ),
          );
        }
      }
    }

    final dedup = <String, QuestCleanerIssue>{};
    for (final issue in issues) {
      dedup[issue.id] = issue;
    }

    final result = dedup.values.toList()
      ..sort((a, b) {
        final categoryCmp = a.category.compareTo(b.category);
        if (categoryCmp != 0) return categoryCmp;
        return a.title.compareTo(b.title);
      });
    emit(1.0, tr('Сканирование завершено'));

    return QuestCleanerReport(issues: result);
  }

  Future<QuestCleanerApplyResult> applyIssues(
    String questId,
    List<QuestCleanerIssue> selectedIssues, {
    bool createBackup = true,
    void Function(QuestCleanerProgress progress)? onProgress,
  }) async {
    int applied = 0;
    int failed = 0;
    final errors = <String>[];
    void emit(double value, String stage) {
      onProgress?.call(
        QuestCleanerProgress(progress: value.clamp(0.0, 1.0), stage: stage),
      );
    }

    emit(0.02, tr('Подготовка очистки'));

    if (createBackup) {
      try {
        emit(0.06, tr('Создание авто-бэкапа'));
        await LocalHistoryService.createSnapshot(questId);
      } catch (e) {
        errors.add('Не удалось создать авто-бэкап: ${friendlyError(e)}');
      }
    }

    for (int i = 0; i < selectedIssues.length; i++) {
      final issue = selectedIssues[i];
      if (issue.type == 'noop') continue;
      try {
        emit(
          0.1 + ((i + 1) / selectedIssues.length) * 0.85,
          trf('Применение: {p0}', {'p0': issue.title}),
        );
        switch (issue.type) {
          case 'delete_node':
            await _deleteNode(
              questId,
              issue.payload['nodeId']?.toString() ?? '',
            );
            applied++;
            break;
          case 'bind_node_to_first_chapter':
            await _bindNodeToFirstChapter(
              questId,
              issue.payload['nodeId']?.toString() ?? '',
            );
            applied++;
            break;
          case 'delete_chapter':
            await _deleteChapter(
              questId,
              issue.payload['tagId']?.toString() ?? '',
            );
            applied++;
            break;
          case 'remove_connection':
            await _removeConnection(questId, issue.payload);
            applied++;
            break;
          case 'delete_script':
            await _deleteScript(
              questId,
              issue.payload['scriptPath']?.toString() ?? '',
            );
            applied++;
            break;
          case 'delete_resource':
            await _deleteResource(
              questId,
              issue.payload['resourcePath']?.toString() ?? '',
            );
            applied++;
            break;
          case 'remove_metadata_entry':
            await _removeMetadataEntry(
              questId,
              issue.payload['metadataKey']?.toString() ?? '',
            );
            applied++;
            break;
          default:
            break;
        }
      } catch (e) {
        failed++;
        errors.add('${issue.title}: ${friendlyError(e)}');
      }
    }
    emit(1.0, tr('Очистка завершена'));

    return QuestCleanerApplyResult(
      applied: applied,
      failed: failed,
      errors: errors,
    );
  }

  Future<Map<String, dynamic>> _readMetadataMap(String questId) async {
    final metadataPath = QuestPaths.metadata(questId);
    if (!await (await _qs()).exists(metadataPath)) return <String, dynamic>{};
    return _readMap(metadataPath);
  }

  Future<Map<String, dynamic>> _readNodesData(String questId) async {
    final data = await QuestNodesStore.read(questId);
    return {
      'nodes': (data['nodes'] as List<dynamic>? ?? []).toList(),
      'groups': (data['groups'] as List<dynamic>? ?? []).toList(),
      'comments': (data['comments'] as List<dynamic>? ?? []).toList(),
    };
  }

  Future<void> _deleteNode(String questId, String nodeId) async {
    if (nodeId.isEmpty) return;

    await _qsync('nodes_$questId', () async {
      final data = await QuestNodesStore.read(questId);
      final nodes = (data['nodes'] as List<dynamic>? ?? []).toList();
      nodes.removeWhere((n) => (n as Map)['id']?.toString() == nodeId);
      await QuestNodesStore.write(questId, {...data, 'nodes': nodes});
    });

    await _qsync('config_$questId', () async {
      final configPath = QuestPaths.config(questId);
      if (!await (await _qs()).exists(configPath)) return;

      final config = await _readMap(configPath);
      final connections = (config['connections'] as List<dynamic>? ?? [])
          .toList();
      connections.removeWhere((c) {
        final conn = c as Map;
        return conn['fromId']?.toString() == nodeId ||
            conn['toId']?.toString() == nodeId;
      });

      final startNodeId = config['startNodeId']?.toString();
      final nextStart = startNodeId == nodeId ? '' : startNodeId;

      await (await _qs()).writeJson(configPath, {
        ...config,
        'connections': connections,
        if (nextStart != null) 'startNodeId': nextStart,
      });
    });
  }

  Future<void> _bindNodeToFirstChapter(String questId, String nodeId) async {
    if (nodeId.isEmpty) return;

    await _qsync('config_$questId', () async {
      await _qsync('nodes_$questId', () async {
        final configPath = QuestPaths.config(questId);
        if (!await (await _qs()).exists(configPath)) return;
        final config = await _readMap(configPath);
        final tags = (config['tags'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) {
              final map = <String, dynamic>{};
              e.forEach((k, v) => map[k.toString()] = v);
              return map;
            })
            .toList();
        if (tags.isEmpty) return;

        final firstTagId = tags.first['id']?.toString();
        if (firstTagId == null || firstTagId.isEmpty) return;

        final nodesData = await QuestNodesStore.read(questId);
        final nodes = (nodesData['nodes'] as List<dynamic>? ?? []).toList();

        final index = nodes.indexWhere(
          (n) => (n as Map)['id']?.toString() == nodeId,
        );
        if (index < 0) return;

        final node = Map<String, dynamic>.from(nodes[index] as Map);
        node['chapterId'] = firstTagId;
        nodes[index] = node;

        await QuestNodesStore.write(questId, {...nodesData, 'nodes': nodes});
      });
    });
  }

  Future<void> _deleteChapter(String questId, String tagId) async {
    if (tagId.isEmpty) return;

    await _qsync('nodes_$questId', () async {
      await _qsync('config_$questId', () async {
        final configPath = QuestPaths.config(questId);

        if (!await (await _qs()).exists(configPath)) return;

        final nodesData = await _readNodesData(questId);
        final nodes = (nodesData['nodes'] as List<dynamic>? ?? []).toList();

        final deletedNodeIds = nodes
            .where((n) => (n as Map)['chapterId']?.toString() == tagId)
            .map((n) => (n as Map)['id']?.toString())
            .whereType<String>()
            .toSet();

        nodes.removeWhere((n) => (n as Map)['chapterId']?.toString() == tagId);

        final groups = (nodesData['groups'] as List<dynamic>? ?? []).toList()
          ..removeWhere((g) => (g as Map)['chapterId']?.toString() == tagId);
        final comments =
            (nodesData['comments'] as List<dynamic>? ?? []).toList()
              ..removeWhere(
                (c) => (c as Map)['chapterId']?.toString() == tagId,
              );

        await QuestNodesStore.write(questId, {
          'nodes': nodes,
          'groups': groups,
          'comments': comments,
        });

        final config = await _readMap(configPath);
        final tags = (config['tags'] as List<dynamic>? ?? []).toList()
          ..removeWhere((t) => (t as Map)['id']?.toString() == tagId);

        final connections =
            (config['connections'] as List<dynamic>? ?? []).toList()
              ..removeWhere((c) {
                final conn = c as Map;
                return deletedNodeIds.contains(conn['fromId']?.toString()) ||
                    deletedNodeIds.contains(conn['toId']?.toString());
              });

        await (await _qs()).writeJson(configPath, {
          ...config,
          'tags': tags,
          'connections': connections,
        });
      });
    });
  }

  Future<void> _removeConnection(
    String questId,
    Map<String, dynamic> payload,
  ) async {
    await _qsync('config_$questId', () async {
      final configPath = QuestPaths.config(questId);
      if (!await (await _qs()).exists(configPath)) return;
      final config = await _readMap(configPath);
      final connections = (config['connections'] as List<dynamic>? ?? [])
          .toList();

      final id = payload['id']?.toString();
      final fromId = payload['fromId']?.toString();
      final toId = payload['toId']?.toString();

      connections.removeWhere((c) {
        final conn = c as Map;
        if (id != null && id.isNotEmpty) {
          return conn['id']?.toString() == id;
        }
        return conn['fromId']?.toString() == fromId &&
            conn['toId']?.toString() == toId;
      });

      await (await _qs()).writeJson(configPath, {
        ...config,
        'connections': connections,
      });
    });
  }

  Future<void> _deleteScript(String questId, String scriptPath) async {
    if (scriptPath.isEmpty) return;
    await (await _qs()).delete(QuestPaths.questFile(questId, scriptPath));

    await _updateMetadataSafe(questId, (metadata) {
      final base = scriptPath.split('/').last;
      metadata.remove(scriptPath);
      metadata.remove(base);
    });
  }

  Future<void> _deleteResource(String questId, String resourcePath) async {
    if (resourcePath.isEmpty) return;
    await (await _qs()).delete(QuestPaths.questFile(questId, resourcePath));

    await _updateMetadataSafe(questId, (metadata) {
      final base = resourcePath.split('/').last;
      metadata.remove(resourcePath);
      metadata.remove(base);
    });
  }

  Future<void> _removeMetadataEntry(String questId, String key) async {
    if (key.isEmpty) return;
    await _updateMetadataSafe(questId, (metadata) {
      metadata.remove(key);
    });
  }

  void _walkContentItem(
    dynamic raw,
    void Function(Map<String, dynamic>) onItem,
  ) {
    if (raw is! Map) return;
    final item = <String, dynamic>{};
    raw.forEach((k, v) => item[k.toString()] = v);
    onItem(item);

    final children = item['children'];
    if (children is List) {
      for (final child in children) {
        _walkContentItem(child, onItem);
      }
    }
  }

  Future<List<String>> _listScriptFiles(String questId) async {
    final roots = ['scripts', '_internal_scripts'];
    final files = <String>[];
    final questBasePath = (await FileStorage.getFilePath(
      QuestPaths.questRoot(questId),
    )).replaceAll('\\', '/');

    for (final root in roots) {
      final dirPath = await FileStorage.getFilePath(
        QuestPaths.questFile(questId, root),
      );
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.json')) continue;
        final relative = entity.path
            .replaceAll('\\', '/')
            .replaceFirst('$questBasePath/', '');
        files.add(relative);
      }
    }

    files.sort();
    return files;
  }

  Future<List<String>> _listResourceFiles(String questId) async {
    final baseQuestPath = await FileStorage.getFilePath(
      QuestPaths.questRoot(questId),
    );
    final roots = ['res/images', 'res/audio', 'res/fonts', 'res/screenshots'];
    final files = <String>[];

    for (final root in roots) {
      final rootPath = await FileStorage.getFilePath(
        QuestPaths.questFile(questId, root),
      );
      final dir = Directory(rootPath);
      if (!await dir.exists()) continue;

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final normalized = entity.path.replaceAll('\\', '/');
        final relative = normalized.replaceFirst(
          '${baseQuestPath.replaceAll('\\', '/')}/',
          '',
        );
        files.add(relative);
      }
    }

    files.sort();
    return files;
  }

  void _collectScriptRef(dynamic raw, String questId, Set<String> output) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return;

    final normalized = _normalizeQuestRelativePath(text);
    if (normalized.endsWith('.json') &&
        (normalized.startsWith('scripts/') ||
            normalized.startsWith('_internal_scripts/'))) {
      output.add(normalized);
      return;
    }

    if (normalized.endsWith('.json')) {
      output.add('scripts/$normalized');
      return;
    }

    if (!_looksLikeUuid(normalized)) {
      return;
    }

    output.add('scripts/$normalized.json');
    output.add('_internal_scripts/$normalized.json');
  }

  void _collectResourceRef(
    dynamic raw,
    Set<String> output,
    Map<String, dynamic> metadata,
  ) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return;

    final normalized = _normalizeQuestRelativePath(text);
    if (normalized.startsWith('res/')) {
      output.add(normalized);
      return;
    }

    if (normalized.contains('/')) {
      output.add('res/$normalized');
    }

    final token = normalized.split('/').last;
    final tokenNoExt = token.contains('.')
        ? token.substring(0, token.lastIndexOf('.'))
        : token;
    for (final key in metadata.keys) {
      final normalizedKey = _normalizeQuestRelativePath(key);
      final keyBase = normalizedKey.split('/').last;
      final keyNoExt = keyBase.contains('.')
          ? keyBase.substring(0, keyBase.lastIndexOf('.'))
          : keyBase;
      if (token == keyBase ||
          tokenNoExt == keyNoExt ||
          token == normalizedKey) {
        if (normalizedKey.startsWith('res/')) {
          output.add(normalizedKey);
        }
      }
    }
  }

  /// Любой строковый value данных квеста может оказаться ссылкой на файл.
  /// Проходит рекурсивно по всему JSON и отмечает использованным всё, что
  /// похоже на путь ресурса, на голое имя файла из `res/<каталог>/` и на шрифт
  /// в инлайн-теге `[font=…]`. Ошибиться в эту сторону безопасно: лишний
  /// «использованный» файл просто переживёт очистку, потерянная ссылка —
  /// удаляет работу автору.
  void _collectResourceRefsFromJson(
    dynamic value,
    Set<String> output,
    Map<String, dynamic> metadata,
    Map<String, List<String>> fileByBase,
  ) {
    if (value is Map) {
      for (final entry in value.entries) {
        _collectResourceRefsFromJson(entry.value, output, metadata, fileByBase);
      }
      return;
    }
    if (value is List) {
      for (final entry in value) {
        _collectResourceRefsFromJson(entry, output, metadata, fileByBase);
      }
      return;
    }
    if (value is! String) return;
    final text = value.trim();
    if (text.isEmpty) return;

    for (final tag in FontService.inlineFontTag.allMatches(text)) {
      _collectResourceRef(tag.group(1), output, metadata);
    }

    final normalized = _normalizeQuestRelativePath(text);
    if (normalized.startsWith('res/')) {
      _collectResourceRef(text, output, metadata);
      return;
    }
    if (normalized.contains('/')) return;
    // Голое имя (`99f7349c-….ttf` — так хранит `customFontFileName`):
    // метаданных может и не быть, зато файл лежит в квесте на виду.
    _collectResourceRef(text, output, metadata);
    output.addAll(fileByBase[normalized] ?? const <String>[]);
  }

  void _collectRefsFromScriptJson(
    Map<dynamic, dynamic> scriptData, {
    required Set<String> manualNodeTargets,
    required Set<String> referencedScriptPaths,
    required Set<String> referencedResources,
    required String questId,
    required Map<String, dynamic> metadata,
  }) {
    const nodeKeys = {
      'node_id',
      'nodeId',
      'targetNodeId',
      'toNodeId',
      'defaultActionNodeId',
      'target_node_id',
    };
    const scriptKeys = {'script_id', 'scriptId', 'scriptPath', 'script_path'};
    const resourceKeys = {
      'resourcePath',
      'resource_path',
      'assetId',
      'asset_id',
      'audio',
      'image',
      'font',
      'file',
      'backgroundAudioId',
      'backgroundAssetId',
    };

    void walk(dynamic value, {String? keyName}) {
      if (value is Map) {
        for (final entry in value.entries) {
          walk(entry.value, keyName: entry.key.toString());
        }
        return;
      }
      if (value is List) {
        for (final item in value) {
          walk(item, keyName: keyName);
        }
        return;
      }
      if (value is! String) return;
      final text = value.trim();
      if (text.isEmpty || text.startsWith('=')) return;

      if (keyName != null && nodeKeys.contains(keyName)) {
        manualNodeTargets.add(text);
      }
      if (keyName != null && scriptKeys.contains(keyName)) {
        _collectScriptRef(text, questId, referencedScriptPaths);
      }
      if (keyName != null && resourceKeys.contains(keyName)) {
        _collectResourceRef(text, referencedResources, metadata);
      }

      if (text.startsWith('res/') ||
          text.startsWith('images/') ||
          text.startsWith('audio/') ||
          text.startsWith('fonts/')) {
        _collectResourceRef(text, referencedResources, metadata);
      }
    }

    walk(scriptData);
  }

  Future<void> _updateMetadataSafe(
    String questId,
    void Function(Map<String, dynamic> metadata) mutate,
  ) async {
    await _qsync('metadata_$questId', () async {
      final metadataPath = QuestPaths.metadata(questId);
      if (!await (await _qs()).exists(metadataPath)) return;
      final metadata = await _readMap(metadataPath);
      mutate(metadata);
      await (await _qs()).writeJson(metadataPath, metadata);
    });
  }

  String _normalizeQuestRelativePath(String raw) {
    var value = raw.trim().replaceAll('\\', '/');
    if (value.isEmpty) return value;

    final questPrefix = RegExp(r'^quests/[^/]+/');
    value = value.replaceFirst(questPrefix, '');
    if (value.startsWith('/')) value = value.substring(1);
    return value;
  }

  bool _looksLikeUuid(String value) {
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return uuidPattern.hasMatch(value);
  }

  String _safeId(String value) {
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }
}
