import 'dart:convert';
import 'dart:io';

import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:path/path.dart' as p;

const String _rowLabel = 'Ряд';
const String _columnLabel = 'Колонка';
const String _incomingLabel = 'входящее';
const String _outgoingLabel = 'исходящее';
const String _buttonWord = 'кнопка';
const String _elementWord = 'элемент';
const String _yes = 'да';
const String _no = 'нет';

/// Что попадает в `.txt`-экспорт квеста.
///
/// По умолчанию файл рассчитан на ИИ: есть краткое описание Meander и
/// человекочитаемая структура, без JSON-обвеса. Технический дамп остаётся
/// доступен одним переключателем.
class TxtExportOptions {
  /// Короткая справка о движке и правилах чтения файла.
  final bool aiGuide;

  /// `true` — текстовая структура; `false` — прежний сырой JSON-дамп.
  final bool readable;

  /// UUID превращать в `ID_1`, `ID_2`, …
  final bool shortenIds;

  final bool includeConfig;
  final bool includeNodes;
  final bool includeScripts;
  final bool includeConnections;
  final bool includeGroups;
  final bool includeComments;

  /// Координаты нод на канвасе — для ИИ обычно шум.
  final bool includeCoordinates;

  /// `_internal_scripts` — служебные скрипты движка.
  final bool includeSystemScripts;

  const TxtExportOptions({
    this.aiGuide = true,
    this.readable = true,
    this.shortenIds = true,
    this.includeConfig = true,
    this.includeNodes = true,
    this.includeScripts = true,
    this.includeConnections = true,
    this.includeGroups = true,
    this.includeComments = false,
    this.includeCoordinates = false,
    this.includeSystemScripts = false,
  });

  TxtExportOptions copyWith({
    bool? aiGuide,
    bool? readable,
    bool? shortenIds,
    bool? includeConfig,
    bool? includeNodes,
    bool? includeScripts,
    bool? includeConnections,
    bool? includeGroups,
    bool? includeComments,
    bool? includeCoordinates,
    bool? includeSystemScripts,
  }) => TxtExportOptions(
    aiGuide: aiGuide ?? this.aiGuide,
    readable: readable ?? this.readable,
    shortenIds: shortenIds ?? this.shortenIds,
    includeConfig: includeConfig ?? this.includeConfig,
    includeNodes: includeNodes ?? this.includeNodes,
    includeScripts: includeScripts ?? this.includeScripts,
    includeConnections: includeConnections ?? this.includeConnections,
    includeGroups: includeGroups ?? this.includeGroups,
    includeComments: includeComments ?? this.includeComments,
    includeCoordinates: includeCoordinates ?? this.includeCoordinates,
    includeSystemScripts: includeSystemScripts ?? this.includeSystemScripts,
  );
}

/// Собирает читаемый `.txt` квеста для передачи ИИ.
class TxtQuestExporter {
  TxtQuestExporter._(this.options);

  final TxtExportOptions options;
  final Map<String, String> _shortIds = {};
  final Map<String, String> _nodeTitles = {};
  int _nextId = 0;

  static Future<String> build(
    String questId,
    String questTitle,
    TxtExportOptions options,
  ) async {
    final exporter = TxtQuestExporter._(options);
    return exporter._build(questId, questTitle);
  }

  Future<String> _build(String questId, String questTitle) async {
    final buffer = StringBuffer();
    final root = QuestPaths.questRoot(questId);

    buffer.writeln('MEANDER — ЭКСПОРТ КВЕСТА');
    buffer.writeln('═' * 72);
    buffer.writeln('Квест: $questTitle');
    buffer.writeln('Дата: ${DateTime.now().toIso8601String()}');
    buffer.writeln();

    final config = await _readConfig(root);
    final nodesData = await QuestNodesStore.read(questId);
    final nodes = _asMapList(nodesData['nodes']);
    for (final node in nodes) {
      final id = node['id']?.toString();
      final title = node['title']?.toString();
      if (id != null && id.isNotEmpty) _nodeTitles[id] = title ?? id;
    }

    if (options.aiGuide) _writeGuide(buffer);
    if (options.includeConfig && config != null) {
      _writeConfig(buffer, config, nodes);
    }
    if (options.includeNodes) _writeNodes(buffer, nodes);
    if (options.includeConnections) _writeConnections(buffer, nodes);
    if (options.includeGroups || options.includeComments) {
      _writeGroupsAndComments(buffer, nodesData);
    }
    if (options.includeScripts) await _writeScripts(buffer, root);

    buffer.writeln();
    buffer.writeln('КОНЕЦ ЭКСПОРТА');
    return buffer.toString();
  }

  Future<Map<String, dynamic>?> _readConfig(String root) async {
    final path = p.join(root, 'config.json');
    if (!await FileStorage.exists(path)) return null;
    try {
      return await FileStorage.readJsonFile(path);
    } catch (_) {
      return null;
    }
  }

  void _writeGuide(StringBuffer buffer) {
    buffer.writeln('## КАК ЧИТАТЬ ЭТОТ ФАЙЛ');
    buffer.writeln(
      'Meander — движок интерактивных квестов и визуальных новелл. Квест — это граф нод: игрок читает ноду и переходит по кнопкам, таймеру или скрипту.',
    );
    buffer.writeln(
      'В ноде есть контент (текст, картинки, видео, кнопки, ряды, стеки, модальные окна, чат, поля ввода) и необязательные скрипты.',
    );
    buffer.writeln(
      'Переменные пишутся в тексте в фигурных скобках: {золото}. Формулы и условия используют те же имена. Таблицы адресуются как таблица["колонка"][1] (нумерация строк с 1).',
    );
    buffer.writeln(
      'События скриптов: onQuestStart, onNodeEnter, onPress, onDataChange, функции. В скриптах могут быть условия, циклы, переменные, переходы и команды движка.',
    );
    buffer.writeln(
      'Ресурсы — пути от корня квеста: res/images/..., res/audio/..., res/videos/..., scripts/....',
    );
    buffer.writeln(
      'Правила для ИИ: не выдумывай новые ID без необходимости; сохраняй имена переменных, таблиц и путей; ссылки на ноды даны как «Название» (ID); тексты можно переписывать, структуру — только осознанно.',
    );
    buffer.writeln();
  }

  void _writeConfig(
    StringBuffer buffer,
    Map<String, dynamic> config,
    List<Map<String, dynamic>> nodes,
  ) {
    buffer.writeln('## КОНФИГУРАЦИЯ');
    buffer.writeln('Название: ${config['title'] ?? ''}');
    final author = config['author']?.toString();
    if (author != null && author.isNotEmpty) buffer.writeln('Автор: $author');
    final description = config['description']?.toString();
    if (description != null && description.isNotEmpty) {
      buffer.writeln('Описание: $description');
    }
    final start = config['startNodeId']?.toString();
    if (start != null && start.isNotEmpty) {
      buffer.writeln('Стартовая нода: ${_nodeRef(start)}');
    }

    const labeled = {
      'version': 'Версия',
      'scriptEngineMode': 'Режим скриптов',
      'dimBackground': 'Затемнять фон',
      'hideNodeTitles': 'Скрывать заголовки нод',
      'nodeTransitionMode': 'Переход между нодами',
    };
    for (final entry in labeled.entries) {
      final value = config[entry.key];
      if (value == null || '$value'.isEmpty) continue;
      buffer.writeln('${entry.value}: ${_plain(value)}');
    }

    final variables = _asMapList(config['variables']);
    if (variables.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Переменные');
      for (final variable in variables) {
        final name = variable['name']?.toString();
        if (name == null || name.isEmpty) continue;
        buffer.writeln(
          '- $name = ${_plain(variable['defaultValue'] ?? variable['value'])}',
        );
      }
    }

    final tables = _asMapList(config['tables']);
    for (final table in tables) {
      final name = table['name']?.toString();
      if (name == null || name.isEmpty) continue;
      buffer.writeln();
      buffer.writeln('### Таблица «$name»');
      final columns = (table['columns'] as List?)?.map((e) => '$e').toList();
      if (columns != null && columns.isNotEmpty) {
        buffer.writeln('Колонки: ${columns.join(' | ')}');
      }
      final rows = _asMapList(table['rows']);
      if (rows.isNotEmpty) {
        for (final row in rows) {
          final values = (columns ?? row.keys.toList())
              .map((column) => _plain(row[column]))
              .join(' | ');
          buffer.writeln('- $values');
        }
      }
    }
    buffer.writeln();
  }

  void _writeNodes(StringBuffer buffer, List<Map<String, dynamic>> nodes) {
    buffer.writeln('## НОДЫ');
    if (nodes.isEmpty) {
      buffer.writeln('(нод нет)');
      buffer.writeln();
      return;
    }
    for (final node in nodes) {
      final id = node['id']?.toString() ?? '';
      buffer.writeln();
      buffer.writeln('### ${_nodeRef(id)}');
      buffer.writeln('- ID: ${_id(id)}');
      final chapter = node['chapterId']?.toString();
      if (chapter != null && chapter.isNotEmpty) {
        buffer.writeln('- Глава: ${_id(chapter)}');
      }
      if (options.includeCoordinates) {
        buffer.writeln(
          '- Координаты: ${_plain(node['x'])}, ${_plain(node['y'])}',
        );
      }
      _writeNodeDetails(buffer, node);
      final content = _asMap(node['content']);
      final items = _asMapList(content?['items']);
      if (items.isEmpty) {
        buffer.writeln('- Содержимое: пусто');
      } else {
        buffer.writeln('- Содержимое:');
        _writeItems(buffer, items, 1);
      }
    }
    buffer.writeln();
  }

  void _writeNodeDetails(StringBuffer buffer, Map<String, dynamic> node) {
    final script = node['scriptAssetId']?.toString();
    if (script != null && script.isNotEmpty) {
      buffer.writeln('- Скрипт ноды: $script');
    }
    final timer = node['timerDuration'];
    if (timer != null) {
      buffer.writeln('- Таймер: ${_plain(timer)} с');
    }
    final defaultAction = node['defaultActionNodeId']?.toString();
    if (defaultAction != null && defaultAction.isNotEmpty) {
      buffer.writeln('- Действие по умолчанию: ${_nodeRef(defaultAction)}');
    }
    final background = node['backgroundAssetId']?.toString();
    if (background != null && background.isNotEmpty) {
      buffer.writeln('- Фон: $background');
    }
    final video = node['backgroundVideoAssetId']?.toString();
    if (video != null && video.isNotEmpty) {
      buffer.writeln('- Фоновое видео: $video');
    }
    final audio = node['backgroundAudioId']?.toString();
    if (audio != null && audio.isNotEmpty) {
      buffer.writeln('- Фоновая музыка: $audio');
    }
    if (node['allowSave'] == false) buffer.writeln('- Сохранение запрещено');
    if (node['allowInventoryAccess'] == false) {
      buffer.writeln('- Инвентарь запрещён');
    }
  }

  void _writeItems(
    StringBuffer buffer,
    List<Map<String, dynamic>> items,
    int depth,
  ) {
    final pad = '  ' * depth;
    for (final item in items) {
      final type = item['type']?.toString() ?? 'unknown';
      final flags = <String>[
        if (item['isHidden'] == true) 'скрыт',
        if (item['locked'] == true) 'заблокирован',
      ];
      final suffix = flags.isEmpty ? '' : ' [${flags.join(', ')}]';

      switch (type) {
        case 'text':
          _writeText(buffer, pad, item, suffix);
        case 'button':
        case 'button_jump':
          _writeButton(buffer, pad, item, suffix);
        case 'row':
        case 'column':
          _writeContainer(buffer, pad, type, item, depth, suffix);
        case 'stack':
          _writeStack(buffer, pad, item, depth, suffix);
        case 'modal':
          _writeModal(buffer, pad, item, suffix);
        case 'chat':
          _writeChat(buffer, pad, item, suffix);
        case 'input':
          _writeInput(buffer, pad, item, suffix);
        case 'wait_input':
          buffer.writeln('$pad- Ожидание: ${_quote(item['text'])}$suffix');
        case 'image':
          buffer.writeln(
            '$pad- Картинка: ${item['resourcePath'] ?? item['resourceExpr'] ?? '—'}$suffix',
          );
        case 'audio':
          buffer.writeln('$pad- Аудио: ${item['resourcePath'] ?? '—'}$suffix');
        case 'video':
          buffer.writeln('$pad- Видео: ${_videoSource(item)}$suffix');
        case 'spacer':
          buffer.writeln('$pad- Отступ: ${_plain(item['padding'])} px$suffix');
        case 'delay':
        case 'timer':
          buffer.writeln(
            '$pad- Пауза: ${_plain(item['text'] ?? item['duration'])} с$suffix',
          );
        case 'script':
          buffer.writeln(
            '$pad- Скрипт: ${item['resourcePath'] ?? item['scriptAssetId'] ?? '—'}$suffix',
          );
        case 'plugin':
          buffer.writeln(
            '$pad- Плагин: ${item['pluginTypeId'] ?? item['pluginId'] ?? '—'}$suffix',
          );
          _writePluginData(buffer, pad, item);
        case 'chat_message':
          _writeChat(buffer, pad, item, suffix);
        default:
          buffer.writeln('$pad- Элемент «$type»$suffix');
          final text = item['text']?.toString();
          if (text != null && text.isNotEmpty) {
            buffer.writeln('$pad  ${_quote(text)}');
          }
      }
    }
  }

  void _writeText(
    StringBuffer buffer,
    String pad,
    Map<String, dynamic> item,
    String suffix,
  ) {
    final text = item['text']?.toString() ?? '';
    final style = <String>[
      if (item['textReveal'] != null && item['textReveal'] != 'none')
        'появление: ${item['textReveal']}',
      if (item['textSize'] != null) 'размер: ${item['textSize']}',
    ];
    buffer.writeln(
      '$pad- Текст${style.isEmpty ? '' : ' (${style.join(', ')})'}$suffix:',
    );
    for (final line in text.split('\n')) {
      buffer.writeln('$pad  $line');
    }
  }

  void _writeButton(
    StringBuffer buffer,
    String pad,
    Map<String, dynamic> item,
    String suffix,
  ) {
    final target = item['targetNodeId']?.toString();
    final parts = <String>['$pad- Кнопка ${_quote(item['text'])}'];
    if (target != null && target.isNotEmpty) {
      parts.add('→ ${_nodeRef(target)}');
    }
    final triggers = _asMap(item['scriptTriggers']);
    if (triggers != null && triggers.isNotEmpty) {
      final readable = triggers.entries
          .where((entry) => entry.value != null)
          .map((entry) => '${entry.key}: ${entry.value}')
          .join(', ');
      if (readable.isNotEmpty) parts.add('скрипты: $readable');
    }
    final behaviours = _asMapList(item['behaviours']);
    if (behaviours.isNotEmpty) {
      parts.add('поведения: ${behaviours.map((e) => _plain(e)).join('; ')}');
    }
    buffer.writeln('${parts.join(' ')} $suffix'.trimRight());
  }

  void _writeContainer(
    StringBuffer buffer,
    String pad,
    String type,
    Map<String, dynamic> item,
    int depth,
    String suffix,
  ) {
    final name = type == 'row' ? _rowLabel : _columnLabel;
    final gap = item['itemSpacing'];
    buffer.writeln(
      '$pad- $name${gap == null ? '' : ' (зазор: ${_plain(gap)})'}$suffix:',
    );
    final children = _asMapList(item['children']);
    if (children.isEmpty) {
      buffer.writeln('$pad  (пусто)');
    } else {
      _writeItems(buffer, children, depth + 1);
    }
  }

  void _writeStack(
    StringBuffer buffer,
    String pad,
    Map<String, dynamic> item,
    int depth,
    String suffix,
  ) {
    final pin = item['stackPin']?.toString();
    final size = <String>[
      if (item['stackWidth'] != null) 'ширина ${item['stackWidth']}',
      if (item['stackHeight'] != null) 'высота ${item['stackHeight']}',
      if (pin != null && pin.isNotEmpty) 'закрепление: $pin',
    ];
    buffer.writeln(
      '$pad- Стек${size.isEmpty ? '' : ' (${size.join(', ')})'}$suffix:',
    );
    final children = _asMapList(item['children']);
    if (children.isEmpty) {
      buffer.writeln('$pad  (пусто)');
    } else {
      _writeItems(buffer, children, depth + 1);
    }
  }

  void _writeModal(
    StringBuffer buffer,
    String pad,
    Map<String, dynamic> item,
    String suffix,
  ) {
    final title = item['buttonText'] ?? item['text'];
    final target = item['targetNodeId']?.toString();
    final details = <String>[
      if (title != null && '$title'.isNotEmpty) 'заголовок: ${_quote(title)}',
      if (target != null && target.isNotEmpty) 'переход: ${_nodeRef(target)}',
    ];
    buffer.writeln(
      '$pad- Модальное окно${details.isEmpty ? '' : ' (${details.join(', ')})'}$suffix:',
    );
    final content = item['contentMarkdown']?.toString();
    if (content != null && content.isNotEmpty) {
      for (final line in content.split('\n')) {
        buffer.writeln('$pad  $line');
      }
    }
    final buttons = _asMapList(item['modalButtons']);
    if (buttons.isNotEmpty) {
      for (final button in buttons) {
        buffer.writeln(
          '$pad  - Кнопка ${_quote(button['text'])}'
          '${button['isPrimary'] == true ? ' (основная)' : ''}',
        );
      }
    }
  }

  void _writeChat(
    StringBuffer buffer,
    String pad,
    Map<String, dynamic> item,
    String suffix,
  ) {
    final incoming = item['isIncoming'] == true;
    final sender = item['senderName']?.toString();
    final kind = incoming ? _incomingLabel : _outgoingLabel;
    final who = sender == null || sender.isEmpty ? kind : '$sender ($kind)';
    buffer.writeln('$pad- Чат, $who: ${_quote(item['text'])}$suffix');
  }

  void _writeInput(
    StringBuffer buffer,
    String pad,
    Map<String, dynamic> item,
    String suffix,
  ) {
    final parts = <String>[
      if (item['text'] != null) 'подсказка: ${_quote(item['text'])}',
      if (item['variableName'] != null) 'переменная: ${item['variableName']}',
      if (item['targetNodeId'] != null)
        'переход: ${_nodeRef(item['targetNodeId'].toString())}',
    ];
    buffer.writeln(
      '$pad- Поле ввода${parts.isEmpty ? '' : ' (${parts.join(', ')})'}$suffix',
    );
  }

  void _writePluginData(
    StringBuffer buffer,
    String pad,
    Map<String, dynamic> item,
  ) {
    final data = _asMap(item['pluginData']);
    if (data == null) return;
    for (final entry in data.entries) {
      buffer.writeln('$pad  ${entry.key}: ${_plain(entry.value)}');
    }
  }

  String _videoSource(Map<String, dynamic> item) {
    final url = item['videoUrl']?.toString();
    if (url != null && url.isNotEmpty) return url;
    final path = item['resourcePath']?.toString();
    return path == null || path.isEmpty ? '—' : path;
  }

  void _writeConnections(
    StringBuffer buffer,
    List<Map<String, dynamic>> nodes,
  ) {
    final links = <String>[];
    final seen = <String>{};
    for (final node in nodes) {
      final fromId = node['id']?.toString() ?? '';
      final from = _nodeRef(fromId);
      final content = _asMap(node['content']);
      for (final item in _asMapList(content?['items'])) {
        _collectLinks(item, from, links, seen);
      }
      final timer = node['defaultActionNodeId']?.toString();
      if (timer != null && timer.isNotEmpty) {
        _addLink(links, seen, from, _nodeRef(timer), 'таймер');
      }
    }
    buffer.writeln('## СВЯЗИ');
    if (links.isEmpty) {
      buffer.writeln('(переходов нет)');
    } else {
      for (final link in links) {
        buffer.writeln('- $link');
      }
    }
    buffer.writeln();
  }

  void _collectLinks(
    Map<String, dynamic> item,
    String from,
    List<String> links,
    Set<String> seen,
  ) {
    final type = item['type']?.toString();
    final target = item['targetNodeId']?.toString();
    if (target != null && target.isNotEmpty) {
      final label = type == 'button' || type == 'button_jump'
          ? '$_buttonWord ${_quote(item['text'])}'
          : type ?? _elementWord;
      _addLink(links, seen, from, _nodeRef(target), label);
    }
    for (final child in _asMapList(item['children'])) {
      _collectLinks(child, from, links, seen);
    }
  }

  void _addLink(
    List<String> links,
    Set<String> seen,
    String from,
    String to,
    String label,
  ) {
    final line = '$from → $to ($label)';
    if (seen.add(line)) links.add(line);
  }

  void _writeGroupsAndComments(
    StringBuffer buffer,
    Map<String, dynamic> nodesData,
  ) {
    if (options.includeGroups) {
      final groups = _asMapList(nodesData['groups']);
      if (groups.isNotEmpty) {
        buffer.writeln('## ГРУППЫ');
        for (final group in groups) {
          buffer.writeln(
            '- ${_quote(group['title'] ?? group['name'])}: '
            '${_asMapList(group['nodes']).map((n) => _nodeRef(n['id']?.toString() ?? '')).join(', ')}',
          );
        }
        buffer.writeln();
      }
    }
    if (options.includeComments) {
      final comments = _asMapList(nodesData['comments']);
      if (comments.isNotEmpty) {
        buffer.writeln('## КОММЕНТАРИИ');
        for (final comment in comments) {
          buffer.writeln('- ${_quote(comment['text'] ?? comment['title'])}');
        }
        buffer.writeln();
      }
    }
  }

  Future<void> _writeScripts(StringBuffer buffer, String root) async {
    final files = <File>[];
    for (final folder in ['scripts', '_internal_scripts']) {
      if (folder == '_internal_scripts' && !options.includeSystemScripts) {
        continue;
      }
      final dirPath = await FileStorage.getFilePath(p.join(root, folder));
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.json')) {
          files.add(entity);
        }
      }
    }
    buffer.writeln('## СКРИПТЫ');
    if (files.isEmpty) {
      buffer.writeln('(скриптов нет)');
      buffer.writeln();
      return;
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final absoluteRoot = Directory(
      await FileStorage.getFilePath(root),
    ).absolute.path;
    for (final file in files) {
      final relative = p
          .relative(file.path, from: absoluteRoot)
          .replaceAll('\\', '/');
      buffer.writeln();
      buffer.writeln('### $relative');
      final text = await file.readAsString();
      if (file.path.endsWith('.lua.json')) {
        _writeLua(buffer, text);
        continue;
      }
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          final blocks = decoded['blocks'];
          if (blocks is List) {
            _writeBlocks(buffer, blocks, 0);
          } else {
            _writeMapAsLines(buffer, decoded, 0);
          }
        } else if (decoded is String) {
          _writeCode(buffer, decoded, 'lua');
        } else {
          buffer.writeln(_plain(decoded));
        }
      } catch (_) {
        _writeCode(buffer, text, 'lua');
      }
    }
    buffer.writeln();
  }

  void _writeLua(StringBuffer buffer, String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    _writeCode(buffer, decoded is String ? decoded : text, 'lua');
  }

  void _writeCode(StringBuffer buffer, String code, String language) {
    buffer.writeln('```$language');
    buffer.writeln(code.trimRight());
    buffer.writeln('```');
  }

  void _writeBlocks(StringBuffer buffer, List<dynamic> blocks, int depth) {
    final pad = '  ' * depth;
    for (final raw in blocks) {
      if (raw is! Map) continue;
      final block = Map<String, dynamic>.from(raw);
      final type = block['type']?.toString() ?? 'unknown';
      switch (type) {
        case 'event':
          final event = block['eventType']?.toString() ?? 'event';
          final watch = block['watchPaths'];
          buffer.writeln(
            '$pad- Событие $event'
            '${watch is List && watch.isNotEmpty ? ' (следит: ${watch.join(', ')})' : ''}',
          );
          _writeBlocks(
            buffer,
            (block['children'] as List?) ?? const [],
            depth + 1,
          );
        case 'condition':
          buffer.writeln('$pad- Если ${block['expression'] ?? '—'}:');
          _writeBlocks(
            buffer,
            (block['then_blocks'] as List?) ?? const [],
            depth + 1,
          );
          final elseBlocks = block['else_blocks'] as List?;
          if (elseBlocks != null && elseBlocks.isNotEmpty) {
            buffer.writeln('$pad- Иначе:');
            _writeBlocks(buffer, elseBlocks, depth + 1);
          }
        case 'assign_variable':
          final op = block['операция'] ?? block['operation'];
          buffer.writeln(
            '$pad- Присвоить «${block['variable'] ?? '?'}» = '
            '${block['value'] ?? '?'}${op == null ? '' : ' ($op)'}',
          );
        case 'go_to_node':
          buffer.writeln(
            '$pad- Перейти к ноде ${_nodeRef(block['targetNodeId']?.toString() ?? '')}',
          );
        case 'call_script':
          buffer.writeln(
            '$pad- Вызвать скрипт ${block['scriptPath'] ?? block['script'] ?? '—'}',
          );
        case 'call_function':
          buffer.writeln(
            '$pad- Вызвать функцию ${block['functionName'] ?? block['name'] ?? '—'}',
          );
        case 'for_each':
          buffer.writeln(
            '$pad- Для каждой строки таблицы «${block['table'] ?? '?'}»:',
          );
          _writeBlocks(
            buffer,
            (block['children'] as List?) ?? const [],
            depth + 1,
          );
        case 'while':
          buffer.writeln('$pad- Пока ${block['condition'] ?? '?'}:');
          _writeBlocks(
            buffer,
            (block['children'] as List?) ?? const [],
            depth + 1,
          );
        case 'crossfade':
          buffer.writeln('$pad- Кроссфейд:');
          _writeBlocks(
            buffer,
            (block['children'] as List?) ?? const [],
            depth + 1,
          );
        case 'comment':
          buffer.writeln('$pad- # ${block['text'] ?? ''}');
        default:
          buffer.writeln('$pad- $type: ${_blockFields(block)}');
      }
    }
  }

  String _blockFields(Map<String, dynamic> block) {
    final keys = block.keys.where(
      (key) =>
          key != 'type' &&
          key != 'id' &&
          key != 'collapsed' &&
          key != 'children' &&
          key != 'then_blocks' &&
          key != 'else_blocks',
    );
    return keys.map((key) => '$key=${_plain(block[key])}').join('; ');
  }

  void _writeMapAsLines(
    StringBuffer buffer,
    Map<String, dynamic> map,
    int depth,
  ) {
    final pad = '  ' * depth;
    for (final entry in map.entries) {
      if (entry.key == 'id' || entry.key == 'blocks') continue;
      final value = entry.value;
      if (value is Map) {
        buffer.writeln('$pad- ${entry.key}:');
        _writeMapAsLines(buffer, Map<String, dynamic>.from(value), depth + 1);
      } else if (value is List) {
        buffer.writeln('$pad- ${entry.key}: ${_plain(value)}');
      } else {
        buffer.writeln('$pad- ${entry.key}: ${_plain(value)}');
      }
    }
  }

  String _nodeRef(String? id) {
    if (id == null || id.isEmpty) return '—';
    final title = _nodeTitles[id];
    final short = _id(id);
    return title == null ? short : '«$title» ($short)';
  }

  String _id(String raw) {
    if (!options.shortenIds) return raw;
    if (!_looksLikeUuid(raw)) return raw;
    return _shortIds.putIfAbsent(raw, () => 'ID_${++_nextId}');
  }

  bool _looksLikeUuid(String value) =>
      value.length >= 20 && RegExp(r'^[0-9a-fA-F-]+$').hasMatch(value);

  String _quote(Object? value) {
    final text = value?.toString() ?? '';
    return text.isEmpty ? '«—»' : '«$text»';
  }

  String _plain(Object? value) {
    if (value == null) return '—';
    if (value is bool) return value ? _yes : _no;
    if (value is String) return value.isEmpty ? '—' : value;
    if (value is List) {
      return value.isEmpty ? '—' : value.map(_plain).join(', ');
    }
    if (value is Map) {
      if (value.isEmpty) return '—';
      return value.entries
          .map((entry) => '${entry.key}=${_plain(entry.value)}')
          .join('; ');
    }
    return value.toString();
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  List<Map<String, dynamic>> _asMapList(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }
}
