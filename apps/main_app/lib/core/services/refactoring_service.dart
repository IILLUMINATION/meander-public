import 'dart:async';

import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:mnd_core/utils/quest_paths.dart';

class RefactorRenameEvent {
  final String questId;
  final String oldName;
  final String newName;

  const RefactorRenameEvent({
    required this.questId,
    required this.oldName,
    required this.newName,
  });
}

/// Переименовали ресурс (скрипт/картинку) в библиотеке. Открытый редактор
/// обязан подхватить новое имя: иначе его автосейв вернёт на диск старое
/// и правка из библиотеки пропадёт.
class ResourceRenameEvent {
  final String questId;

  /// Литеральное имя файла, например `a1b2.json`.
  final String fileName;
  final String newName;

  const ResourceRenameEvent({
    required this.questId,
    required this.fileName,
    required this.newName,
  });
}

class RefactoringService {
  static const Set<String> _neverReplaceStringKeys = {
    'id',
    'targetNodeId',
    'scriptAssetId',
    'resourcePath',
    'path',
    'fileName',
    'questId',
    'nodeId',
    'fromId',
    'toId',
    'chapterId',
  };

  static const Set<String> _exactRenameKeys = {
    'variableName',
    'variable',
    'переменная',
    'targetVariable',
  };

  static final _renameEvents =
      StreamController<RefactorRenameEvent>.broadcast();

  static Stream<RefactorRenameEvent> get renameEvents => _renameEvents.stream;

  static final _resourceRenames =
      StreamController<ResourceRenameEvent>.broadcast();

  static Stream<ResourceRenameEvent> get resourceRenameEvents =>
      _resourceRenames.stream;

  /// Сообщает открытым редакторам о новом отображаемом имени ресурса.
  static void emitResourceRename(ResourceRenameEvent event) {
    _resourceRenames.add(event);
  }

  /// Эмитит событие переименования (для тестов и внешних триггеров).
  static void emitRenameEvent(RefactorRenameEvent event) {
    _renameEvents.add(event);
  }

  /// Переименовывает переменную или таблицу во всем проекте.
  /// Возвращает количество измененных файлов.
  static Future<int> renameVariableOrTable({
    required String questId,
    required String oldName,
    required String newName,
  }) async {
    if (oldName == newName) return 0;
    int modifiedFiles = 0;
    final ops = <QuestOp>[];

    print(
      '[Refactor] Start rename in quest=$questId: "$oldName" -> "$newName"',
    );

    // 1. config.json (определения переменных/таблиц)
    final configPath = QuestPaths.config(questId);
    if (await FileStorage.exists(configPath)) {
      final config = await FileStorage.readJsonFile(configPath);
      bool changed = false;

      final variables = (config['variables'] as List<dynamic>? ?? []).toList();
      for (int i = 0; i < variables.length; i++) {
        final entry = variables[i];
        if (entry is Map && entry['name'] == oldName) {
          entry['name'] = newName;
          changed = true;
        }
      }
      config['variables'] = variables;

      final tables = (config['tables'] as List<dynamic>? ?? []).toList();
      for (int i = 0; i < tables.length; i++) {
        final entry = tables[i];
        if (entry is Map && entry['name'] == oldName) {
          entry['name'] = newName;
          changed = true;
        }
      }
      config['tables'] = tables;

      if (changed) {
        ops.add(QuestOp.writeJson(configPath, config));
        modifiedFiles++;
        print('[Refactor] Updated: $configPath');
      }
    }

    // 2. Скрипты
    const scriptFolders = ['scripts', '_internal_scripts'];
    for (final folderName in scriptFolders) {
      final folder = QuestPaths.questFile(questId, folderName);
      if (!await FileStorage.exists(folder)) continue;

      final files = await FileStorage.listFiles(folder, extension: '.json');
      for (final file in files) {
        final filePath = '$folder/$file';
        final content = await FileStorage.readJsonFile(filePath);
        final hasChanges = _processScriptData(content, oldName, newName);
        if (!hasChanges) continue;

        ops.add(QuestOp.writeJson(filePath, content));
        modifiedFiles++;
        print('[Refactor] Updated script: $filePath');
      }
    }

    // 2b. Lua-скрипты: там переменные — строковые аргументы
    // (`core.get_var("gold")`), JSON-обход их не видит.
    for (final folderName in scriptFolders) {
      final folder = QuestPaths.questFile(questId, folderName);
      if (!await FileStorage.exists(folder)) continue;

      final files = await FileStorage.listFiles(folder, extension: '.lua');
      for (final file in files) {
        final filePath = '$folder/$file';
        final source = await FileStorage.readTextFile(filePath);
        final renamed = replaceInLuaSource(source, oldName, newName);
        if (renamed == source) continue;

        ops.add(QuestOp.writeText(filePath, renamed));
        modifiedFiles++;
        print('[Refactor] Updated lua: $filePath');
      }
    }

    // 3. Ноды (включая вложенный контент)
    final nodesData = await QuestNodesStore.read(questId);
    bool nodesChanged = false;

    final nodes = nodesData['nodes'];
    if (nodes is List) {
      for (final node in nodes) {
        if (node is! Map<String, dynamic>) continue;
        if (_processNodeContent(node, oldName, newName)) {
          nodesChanged = true;
        }
      }
    }

    if (nodesChanged) {
      ops.add(QuestOp.writeJson(QuestPaths.nodesLegacy(questId), nodesData));
      ops.add(QuestOp.writeJson(QuestPaths.nodesCanonical(questId), nodesData));
      modifiedFiles++;
      print('[Refactor] Updated nodes');
    }

    // План 020-C4.4: все изменённые файлы коммитятся ОДНОЙ транзакцией
    // ядра — rename больше не может оставить квест наполовину
    // переименованным при сбое между записями.
    if (ops.isNotEmpty) {
      final store = await QuestStore.defaultInstance();
      await store.transact(ops);
    }

    if (modifiedFiles > 0) {
      _renameEvents.add(
        RefactorRenameEvent(
          questId: questId,
          oldName: oldName,
          newName: newName,
        ),
      );
    }

    print('[Refactor] Done rename. Modified files: $modifiedFiles');
    return modifiedFiles;
  }

  static bool _processScriptData(
    Map<String, dynamic> data,
    String oldName,
    String newName,
  ) {
    bool changed = false;
    final blocks = data['blocks'];
    if (blocks is! List) return false;

    for (final block in blocks) {
      if (block is Map<String, dynamic> &&
          _processBlock(block, oldName, newName)) {
        changed = true;
      }
    }
    return changed;
  }

  static bool _processBlock(
    Map<String, dynamic> block,
    String oldName,
    String newName,
  ) {
    bool changed = false;

    for (final key in _exactRenameKeys) {
      if (block[key] == oldName) {
        block[key] = newName;
        changed = true;
      }
    }

    const keysToCheck = [
      'expression',
      'value',
      'значение',
      'condition',
      'tableName',
      'path',
      'node_id',
      'text',
      'title',
      'hint',
      'subtitle',
      'defaultValue',
      'comparison',
      'сравнение',
      'functionName',
      'script_name',
      'node_name',
    ];

    for (final key in keysToCheck) {
      final raw = block[key];
      if (raw is! String) continue;
      final replaced = replaceInString(raw, oldName, newName);
      if (replaced == raw) continue;
      block[key] = replaced;
      changed = true;
    }

    const listKeys = [
      'then_blocks',
      'else_blocks',
      'если_да',
      'если_нет',
      'children',
    ];
    for (final key in listKeys) {
      final list = block[key];
      if (list is! List) continue;
      for (final child in list) {
        if (child is Map<String, dynamic> &&
            _processBlock(child, oldName, newName)) {
          changed = true;
        }
      }
    }

    return changed;
  }

  static bool _processNodeContent(
    Map<String, dynamic> node,
    String oldName,
    String newName,
  ) {
    bool changed = false;

    if (node['title'] is String) {
      final current = node['title'] as String;
      final replaced = replaceInString(current, oldName, newName);
      if (replaced != current) {
        node['title'] = replaced;
        changed = true;
      }
    }

    final content = node['content'];
    if (content is Map<String, dynamic> &&
        _walkDynamicAndReplace(content, oldName, newName)) {
      changed = true;
    }

    return changed;
  }

  static bool _walkDynamicAndReplace(
    dynamic target,
    String oldName,
    String newName, {
    String? currentKey,
  }) {
    bool changed = false;

    if (target is Map) {
      final keys = target.keys.toList();
      for (final key in keys) {
        final keyStr = key.toString();
        final value = target[key];

        if (_exactRenameKeys.contains(keyStr) && value == oldName) {
          target[key] = newName;
          changed = true;
          continue;
        }

        if (value is String) {
          if (_neverReplaceStringKeys.contains(keyStr)) continue;
          final replaced = replaceInString(value, oldName, newName);
          if (replaced != value) {
            target[key] = replaced;
            changed = true;
          }
          continue;
        }

        if (_walkDynamicAndReplace(
          value,
          oldName,
          newName,
          currentKey: keyStr,
        )) {
          changed = true;
        }
      }
      return changed;
    }

    if (target is List) {
      for (int i = 0; i < target.length; i++) {
        final value = target[i];
        if (value is String &&
            (currentKey == null ||
                !_neverReplaceStringKeys.contains(currentKey))) {
          final replaced = replaceInString(value, oldName, newName);
          if (replaced != value) {
            target[i] = replaced;
            changed = true;
          }
          continue;
        }

        if (_walkDynamicAndReplace(
          value,
          oldName,
          newName,
          currentKey: currentKey,
        )) {
          changed = true;
        }
      }
    }

    return changed;
  }

  /// Функции Lua-API, первым аргументом которых идёт имя переменной/таблицы.
  static const List<String> _luaNameFunctions = [
    'get_var',
    'set_var',
    'has_var',
    'get_table',
    'set_table',
  ];

  /// Менять имя только внутри строковых литералов вызовов API — остальной
  /// код Lua (локальные переменные, текст) к именам квеста не относится.
  static String replaceInLuaSource(
    String source,
    String oldName,
    String newName,
  ) {
    if (!source.contains(oldName)) return source;
    final call = '\\b(?:${_luaNameFunctions.join('|')})\\s*\\(\\s*';
    final escapedOld = RegExp.escape(oldName);
    String result = source;
    for (final quote in const ['"', "'"]) {
      final regExp = RegExp('($call)$quote$escapedOld$quote');
      result = result.replaceAllMapped(
        regExp,
        (m) => '${m.group(1)}$quote$newName$quote',
      );
    }
    return result;
  }

  /// Заменяет oldName на newName в строке, учитывая границы слов.
  static String replaceInString(String input, String oldName, String newName) {
    final placeholder =
        '__mnd_refactor_placeholder_${oldName.hashCode}_${newName.hashCode}__';
    String result = input.replaceAll('{$oldName}', '{$placeholder}');

    final escapedOld = RegExp.escape(oldName);
    final regExp = RegExp(
      r'(?<![\wа-яА-ЯёЁ])' + escapedOld + r'(?![\wа-яА-ЯёЁ])',
    );

    result = result.replaceAll(regExp, newName);
    result = result.replaceAll('{$placeholder}', '{$newName}');
    return result;
  }
}
