import 'dart:convert';
import 'dart:io';

import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:path/path.dart' as p;

import 'quest_book_models.dart';
import 'quest_html_template.dart';
import '../utils/quest_script_events.dart';
import 'package:mnd_core/models/content_item.dart';
import 'package:mnd_core/utils/quest_paths.dart';

class _Resource {
  final String id;
  final String mime;
  final String base64;
  _Resource({required this.id, required this.mime, required this.base64});
}

/// Сборка единого самодостаточного HTML-файла «плеера» квеста.
/// Ноды рендерятся лениво в JS, бинарные ресурсы лежат отдельными
/// `<script type="text/plain">` блоками — JSON.parse не тормозит на мегабайтах.
class QuestHtmlBuilder {
  static Future<String> build(QuestBook book) async {
    final jsNodes = <String, Map<String, dynamic>>{};
    final imageResources = <String, _Resource>{};
    final audioResources = <String, _Resource>{};
    int resCounter = 0;
    String nextResId() => 'r${resCounter++}';

    final pathToResId = <String, String>{};

    Future<String?> registerResource(
      String relPath, {
      required bool isImage,
    }) async {
      if (relPath.isEmpty) return null;
      if (pathToResId.containsKey(relPath)) {
        return pathToResId[relPath];
      }
      try {
        // Резолвим тем же движком, что и плеер: автор мог написать имя из
        // библиотеки или uuid вместо точного пути. Без этого экспорт молча
        // отдавал страницу без картинки (`resId: null`), хотя в приложении она
        // была на месте.
        final relative =
            await QuestImageSource.resolveRelative(book.id, relPath) ?? relPath;
        final fullPath = await FileStorage.getFilePath(
          QuestPaths.questFile(book.id, relative),
        );
        final file = File(fullPath);
        if (!await file.exists()) return null;
        final bytes = await file.readAsBytes();
        final mime = isImage
            ? _guessImageMime(relative)
            : _guessAudioMime(relative);
        final resId = nextResId();
        final res = _Resource(
          id: resId,
          mime: mime,
          base64: base64Encode(bytes),
        );
        if (isImage) {
          imageResources[resId] = res;
        } else {
          audioResources[resId] = res;
        }
        pathToResId[relPath] = resId;
        return resId;
      } catch (_) {
        return null;
      }
    }

    // Регистрация фона главы/ноды.
    Future<String?> registerBackground(String? assetId) async {
      if (assetId == null || assetId.isEmpty) return null;
      // Префикс `res/images/` здесь не дописывается: резолвер сам подставит
      // каталог по расширению, а уже готовый путь от двойного префикса бы
      // перестал находиться.
      return registerResource(assetId, isImage: true);
    }

    Future<Map<String, dynamic>?> processItem(Map<String, dynamic> item) async {
      final type = item['type']?.toString() ?? '';
      // Экспортный JS-движок знает одну форму ссылок — legacy-карту
      // `scriptTriggers` (он читает только `.onPress`/`.onAppear`), поэтому
      // новый массив `behaviours` сворачивается в неё. Правило выбора совпадает
      // с плеером: непустые `behaviours` затеняют legacy целиком. Иначе
      // страница выполняла бы скрипт, который в приложении мёртв, — или, при
      // обратном порядке, молча игнорировала рабочий.
      final triggerMap = <String, String>{};
      final behaviours = item['behaviours'];
      if (behaviours is List && behaviours.isNotEmpty) {
        for (final beh in behaviours.whereType<Map>()) {
          final event = beh['event']?.toString() ?? '';
          final script = _normalizeScriptId(beh['script']?.toString() ?? '');
          if (event.isEmpty || script.isEmpty) continue;
          triggerMap.putIfAbsent(event, () => script);
        }
      } else {
        final triggers = (item['scriptTriggers'] as Map?)
            ?.cast<dynamic, dynamic>();
        if (triggers != null) {
          triggers.forEach((k, v) {
            final script = _normalizeScriptId(v?.toString() ?? '');
            if (script.isEmpty) return;
            triggerMap[k.toString()] = script;
          });
        }
      }

      switch (type) {
        case 'text':
          final textShadow = _textShadowCss(item);
          return {
            'id': item['id']?.toString() ?? '',
            'type': 'text',
            'text': item['text']?.toString() ?? '',
            if (textShadow != null) 'textShadow': textShadow,
            if (triggerMap.isNotEmpty) 'scriptTriggers': triggerMap,
          };
        case 'button':
          return {
            'id': item['id']?.toString() ?? '',
            'type': 'button',
            'text': item['text']?.toString() ?? '',
            'targetNodeId': item['targetNodeId']?.toString(),
            if (triggerMap.isNotEmpty) 'scriptTriggers': triggerMap,
          };
        case 'image':
          final path = item['resourcePath']?.toString() ?? '';
          final resId = await registerResource(path, isImage: true);
          return {
            'id': item['id']?.toString() ?? '',
            'type': 'image',
            'resId': resId,
            'path': path,
            if (triggerMap.isNotEmpty) 'scriptTriggers': triggerMap,
          };
        case 'audio':
          final path = item['resourcePath']?.toString() ?? '';
          final resId = await registerResource(path, isImage: false);
          return {
            'id': item['id']?.toString() ?? '',
            'type': 'audio',
            'resId': resId,
            'path': path,
            'volume': (item['volume'] as num?)?.toDouble() ?? 1.0,
            if (triggerMap.isNotEmpty) 'scriptTriggers': triggerMap,
          };
        case 'input':
          return {
            'id': item['id']?.toString() ?? '',
            'type': 'input',
            'text': item['text']?.toString() ?? '',
            'placeholderText': item['placeholderText']?.toString() ?? '',
            'buttonText': item['buttonText']?.toString() ?? 'Готово',
            'variableName': item['variableName']?.toString() ?? '',
            if (triggerMap.isNotEmpty) 'scriptTriggers': triggerMap,
          };
        case 'chat':
          final avatarPath = item['avatarPath']?.toString();
          String? avatarResId;
          if (avatarPath != null && avatarPath.isNotEmpty) {
            avatarResId = await registerResource(avatarPath, isImage: true);
          }
          return {
            'id': item['id']?.toString() ?? '',
            'type': 'chat',
            'text': item['text']?.toString() ?? '',
            'senderName': item['senderName']?.toString() ?? '',
            'isIncoming': item['isIncoming'] as bool? ?? true,
            'avatarColor': (item['avatarColor'] as num?)?.toInt(),
            'avatarResId': avatarResId,
            if (triggerMap.isNotEmpty) 'scriptTriggers': triggerMap,
          };
        case 'script':
          // Невидимая нода — скрипт выполняется в onAppear триггере.
          return {
            'id': item['id']?.toString() ?? '',
            'type': 'script',
            'path': _normalizeScriptId(item['resourcePath']?.toString() ?? ''),
            if (triggerMap.isNotEmpty) 'scriptTriggers': triggerMap,
          };
        case 'row':
        case 'column':
          final rawChildren = (item['children'] as List<dynamic>? ?? const [])
              .whereType<Map>()
              .map((c) => Map<String, dynamic>.from(c))
              .toList();
          final children = <Map<String, dynamic>>[];
          for (final c in rawChildren) {
            final processed = await processItem(c);
            if (processed != null) children.add(processed);
          }
          return {
            'id': item['id']?.toString() ?? '',
            'type': type,
            'children': children,
            if (triggerMap.isNotEmpty) 'scriptTriggers': triggerMap,
          };
        default:
          return null;
      }
    }

    // Собираем backgrounds для глав
    final chapterBackgrounds = <String, String?>{};
    // Из tagsList мы изначально не имеем подробной инфы; QuestBook хранит только
    // id/name/nodes. Поэтому фоны глав достанем из config.json повторно.
    Map<String, dynamic>? config;
    try {
      config = await FileStorage.readJsonFile(QuestPaths.config(book.id));
    } catch (_) {}

    if (config != null) {
      final tagsList = (config['tags'] as List<dynamic>? ?? const []);
      for (final tag in tagsList) {
        if (tag is Map) {
          final cid = tag['id']?.toString() ?? '';
          if (cid.isEmpty) continue;
          final bg = tag['backgroundAssetId']?.toString();
          if (bg != null && bg.isNotEmpty) {
            final resId = await registerBackground(bg);
            if (resId != null) chapterBackgrounds[cid] = resId;
          }
        }
      }
    }

    // Фон квеста
    String? questBackgroundResId;
    if (config != null) {
      final bg = config['backgroundAssetId']?.toString();
      if (bg != null && bg.isNotEmpty) {
        questBackgroundResId = await registerBackground(bg);
      }
    }

    // Таблицы квеста: без них HTML-плеер играл с пустым state.tables,
    // и любой квест с таблицами молча терял данные.
    final initialTables = <String, dynamic>{};
    if (config != null) {
      final tables = config['tables'] as List<dynamic>? ?? const [];
      for (final raw in tables) {
        if (raw is! Map) continue;
        final table = Map<String, dynamic>.from(raw);
        final name = table['name']?.toString() ?? '';
        if (name.isNotEmpty) initialTables[name] = table;
      }
    }

    // Переменные квеста (initial)
    final initialVariables = <String, dynamic>{};
    if (config != null) {
      final vars = config['variables'] as List<dynamic>? ?? const [];
      for (final v in vars) {
        if (v is Map) {
          final name = v['name']?.toString();
          if (name == null || name.isEmpty) continue;
          initialVariables[name] = v['defaultValue'];
        }
      }
    }

    for (final chapter in book.chapters) {
      for (final node in chapter.nodes) {
        final id = node['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final content = node['content'] as Map<String, dynamic>?;
        final rawItems = (content?['items'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        final items = <Map<String, dynamic>>[];
        for (final it in rawItems) {
          final processed = await processItem(it);
          if (processed != null) items.add(processed);
        }

        // Фон ноды (node-level)
        String? nodeBgResId;
        final nodeBg = node['backgroundAssetId']?.toString();
        if (nodeBg != null && nodeBg.isNotEmpty) {
          nodeBgResId = await registerBackground(nodeBg);
        }

        // scriptAssetId / timerDuration / defaultActionNodeId
        final scriptAssetId = _normalizeScriptId(
          node['scriptAssetId']?.toString() ?? '',
        );

        jsNodes[id] = {
          'title': node['title']?.toString() ?? '',
          'chapterId': node['chapterId']?.toString() ?? '',
          'items': items,
          if (nodeBgResId != null) 'backgroundResId': nodeBgResId,
          if (scriptAssetId.isNotEmpty) 'scriptAssetId': scriptAssetId,
          if (node['timerDuration'] is num)
            'timerDuration': (node['timerDuration'] as num).toDouble(),
          if (node['defaultActionNodeId'] != null)
            'defaultActionNodeId': node['defaultActionNodeId'].toString(),
          if (node['timerHidden'] == true) 'timerHidden': true,
        };
      }
    }

    // === Загрузка всех скриптов квеста ===
    // Включаем все .json из quests/<id>/scripts/ и quests/<id>/_internal_scripts/
    final scriptsMap = <String, dynamic>{};
    final bootScriptIds = <String>[];
    for (final folder in const ['scripts', '_internal_scripts']) {
      final dirPath = await FileStorage.getFilePath(
        QuestPaths.questFile(book.id, folder),
      );
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      try {
        await for (final entity in dir.list(recursive: false)) {
          if (entity is File && entity.path.endsWith('.json')) {
            final fileName = p.basename(entity.path);
            final scriptId = fileName.replaceAll('.json', '');
            try {
              final content = await entity.readAsString();
              final data = jsonDecode(content);
              if (data is Map) {
                scriptsMap[scriptId] = data;
                // Движок запускает на старте квеста только скрипты из
                // `scripts/`, объявившие событие «При запуске квеста».
                if (folder == 'scripts' &&
                    declaresQuestStartEvent(data['blocks'])) {
                  bootScriptIds.add(scriptId);
                }
              }
            } catch (e) {
              // ignore: avoid_print
              print('⚠️ [HTML] Не удалось прочитать скрипт $fileName: $e');
            }
          }
        }
      } catch (_) {}
    }

    // Preview как ресурс
    String? previewResId;
    if (book.previewBytes != null) {
      previewResId = nextResId();
      imageResources[previewResId] = _Resource(
        id: previewResId,
        mime: book.previewMime ?? 'image/png',
        base64: base64Encode(book.previewBytes!),
      );
    }

    // Кастомный шрифт
    String? fontBase64;
    String? fontFormat;
    if (book.customFontBytes != null && book.customFontFileName != null) {
      fontBase64 = base64Encode(book.customFontBytes!);
      final lower = book.customFontFileName!.toLowerCase();
      fontFormat = lower.endsWith('.otf') ? 'opentype' : 'truetype';
    }

    final chaptersForJs = book.chapters
        .map(
          (c) => {
            'id': c.id,
            'name': c.name,
            'nodeIds': c.nodes
                .map((n) => n['id']?.toString() ?? '')
                .where((s) => s.isNotEmpty)
                .toList(),
            if (chapterBackgrounds[c.id] != null)
              'backgroundResId': chapterBackgrounds[c.id],
          },
        )
        .toList();

    // Скрипты, которые надо выполнить до первой ноды. Реестра в конфиге больше
    // нет: список собран по объявленному событию. Lua в HTML-плеере выполнить
    // нечем, поэтому в него попадают только визуальные скрипты.
    bootScriptIds.sort();
    final startScriptIds = <String>[
      ...{
        for (final id in bootScriptIds)
          if (scriptsMap.containsKey(id)) id,
      },
    ];

    final questMeta = {
      'id': book.id,
      'title': book.title,
      'author': book.author,
      'description': book.description,
      'startNodeId': book.startNodeId,
      'previewResId': previewResId,
      if (questBackgroundResId != null) 'backgroundResId': questBackgroundResId,
      'chapters': chaptersForJs,
      'nodes': jsNodes,
      'variables': initialVariables,
      'tables': initialTables,
      'scripts': scriptsMap,
      if (startScriptIds.isNotEmpty) 'startScripts': startScriptIds,
    };

    final jsonStr = jsonEncode(questMeta);

    return _renderSkeleton(
      book: book,
      jsonStr: jsonStr,
      images: imageResources.values.toList(),
      audios: audioResources.values.toList(),
      fontBase64: fontBase64,
      fontFormat: fontFormat,
    );
  }

  /// Нормализует ID скрипта: убирает префикс "scripts/" / "_internal_scripts/"
  /// и расширение ".json".
  static String _normalizeScriptId(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return v;
    final slash = v.lastIndexOf('/');
    if (slash != -1) v = v.substring(slash + 1);
    if (v.endsWith('.json')) v = v.substring(0, v.length - 5);
    return v;
  }

  static String _renderSkeleton({
    required QuestBook book,
    required String jsonStr,
    required List<_Resource> images,
    required List<_Resource> audios,
    String? fontBase64,
    String? fontFormat,
  }) {
    final buf = StringBuffer();
    buf.writeln('<!DOCTYPE html>');
    buf.writeln('<html lang="ru">');
    buf.writeln('<head>');
    buf.writeln('<meta charset="UTF-8">');
    buf.writeln(
      '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">',
    );
    buf.writeln('<meta name="theme-color" content="#0B1118">');
    buf.writeln('<title>${_escapeHtml(book.title)}</title>');
    buf.writeln('<style>$questHtmlCss</style>');
    if (fontBase64 != null) {
      buf.writeln(
        '<style>@font-face{font-family:"QuestCustom";'
        'src:url(data:font/${fontFormat ?? 'truetype'};base64,$fontBase64) '
        'format("${fontFormat ?? 'truetype'}");font-display:swap;}'
        'body, .player-text, .player-btn{'
        'font-family:"QuestCustom", system-ui, sans-serif;}</style>',
      );
    }
    buf.writeln('</head>');
    buf.writeln('<body>');

    buf.writeln('''
<div id="bg-layer"></div>
<div id="app">
  <header id="header" class="card">
    <button id="menu-btn" class="hdr-btn" aria-label="Меню">☰</button>
    <div id="header-text">
      <div id="header-title">${_escapeHtml(book.title)}</div>
      <div id="header-sub">Meander HTML Player</div>
    </div>
    <button id="back-btn" class="hdr-btn" aria-label="Назад">←</button>
  </header>

  <div id="info-bar" class="card info">
    Для лучшего опыта играйте в Meander Player (Windows, macOS, Linux, iOS, Android):
    <a href="https://github.com/IILLUMINATION/meanderPUBLIC/releases" target="_blank" rel="noopener">releases</a>.
    Мобильная версия:
    <a href="https://play.google.com/store/apps/details?id=com.IILLUMINAT.meadner" target="_blank" rel="noopener">Google Play</a>.
  </div>

  <main id="stage">
    <div id="node-content"></div>
  </main>

  <footer id="footer" class="card brand">
    <div class="brand-text">Сделано с помощью программы Meander — текстовые квесты</div>
    <div class="brand-links">
      <a class="pill" href="https://t.me/meanderRU" target="_blank" rel="noopener">Telegram</a>
      <a class="pill" href="https://www.youtube.com/@meanderRU" target="_blank" rel="noopener">YouTube</a>
      <a class="pill" href="https://boosty.to/iilluminat/posts/8e4bc65c-f106-4560-b158-973d6e8a65f6" target="_blank" rel="noopener">Boosty</a>
      <a class="pill" href="https://play.google.com/store/apps/details?id=com.IILLUMINAT.meadner" target="_blank" rel="noopener">Google Play</a>
    </div>
  </footer>

  <aside id="drawer">
    <div class="drawer-head">
      <strong>Содержание</strong>
      <button id="drawer-close" aria-label="Закрыть">×</button>
    </div>
    <nav id="drawer-list"></nav>
  </aside>
  <div id="drawer-backdrop"></div>
</div>
''');

    buf.write('<script id="quest-data" type="application/json">');
    buf.write(_escapeForScriptTag(jsonStr));
    buf.writeln('</script>');

    for (final img in images) {
      buf.write(
        '<script id="${img.id}" type="text/plain" data-mime="${img.mime}">',
      );
      buf.write(img.base64);
      buf.writeln('</script>');
    }
    for (final audio in audios) {
      buf.write(
        '<script id="${audio.id}" type="text/plain" data-mime="${audio.mime}">',
      );
      buf.write(audio.base64);
      buf.writeln('</script>');
    }

    buf.writeln('<script>$questHtmlPlayerJs</script>');
    buf.writeln('</body>');
    buf.writeln('</html>');
    return buf.toString();
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  /// Обводка текста айтема в значение для CSS `text-shadow`, либо `null`, если
  /// обводки нет. В браузере нет слоя штриха, поэтому контур — восемь копий
  /// глифа без размытия. Кольцо смещений считает ядро
  /// (`textOutlineShadowOffsets`): ровно те же сдвиги, что у Flutter-рендереров,
  /// и та же нормировка толщины — иначе страница расходилась бы с игрой.
  static String? _textShadowCss(Map<String, dynamic> item) {
    final color = _cssColor(item['textOutlineColor']);
    if (color == null) return null;
    final width = (item['textOutlineWidth'] as num?)?.toDouble();
    final parts = <String>[
      for (final offset in textOutlineShadowOffsets(width: width))
        // Dart печатает double как «1.0»/«0.25» — валидное CSS-число, единицы
        // приписываем руками: без `px` ненулевой offset браузер не принимает.
        '${offset.dx}px ${offset.dy}px 0 $color',
    ];
    return parts.join(', ');
  }

  /// ARGB-целое из модели в CSS-краску. Альфаву сохраняем: обводка, сделанная
  /// полупрозрачной в редакторе, не должна становиться глухой в браузере.
  static String? _cssColor(Object? raw) {
    final argb = (raw is num) ? raw.toInt() : null;
    if (argb == null) return null;
    final a = (argb >> 24) & 0xFF;
    if (a == 0) return null;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    String hex(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    if (a == 0xFF) return '#${hex(r)}${hex(g)}${hex(b)}';
    return 'rgba($r, $g, $b, ${(a / 255).toStringAsFixed(3)})';
  }

  /// Безопасно встраиваем JSON внутрь `<script>...</script>`.
  /// Главное: не должно быть подстроки `</script` в любом регистре.
  static String _escapeForScriptTag(String s) {
    return s
        .replaceAll('</', '<\\/')
        .replaceAll('\u2028', '\\u2028')
        .replaceAll('\u2029', '\\u2029');
  }

  static String _guessImageMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    return 'image/png';
  }

  static String _guessAudioMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.m4a') || lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.opus')) return 'audio/opus';
    return 'audio/mpeg';
  }
}
