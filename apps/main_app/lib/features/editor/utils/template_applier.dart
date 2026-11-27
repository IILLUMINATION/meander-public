import 'dart:convert';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:mnd_core/models/inline_image.dart';
import 'package:mnd_core/models/saved_node.dart';
import 'package:mnd_player/services/font_service.dart';
import 'package:uuid/uuid.dart';

/// Результат применения шаблона главы.
class ChapterApplyResult {
  final String newChapterId;
  final String? chapterName;
  final List<SavedNode> nodes;
  final List<ChapterConnection> connections;
  final String? entryNodeId;

  ChapterApplyResult({
    required this.newChapterId,
    required this.nodes,
    required this.connections,
    this.chapterName,
    this.entryNodeId,
  });
}

class ChapterConnection {
  final String id;
  final String fromId;
  final String toId;
  ChapterConnection({
    required this.id,
    required this.fromId,
    required this.toId,
  });

  Map<String, dynamic> toJson() => {'id': id, 'fromId': fromId, 'toId': toId};
}

/// Утилита, превращающая [TemplateItem] в готовый объект для вставки
/// в текущий квест/контейнер.
///
/// Все идентификаторы (ноды, контент-айтемы, модальные кнопки) рекурсивно
/// перегенерируются, чтобы не было коллизий с уже существующими объектами.
class TemplateApplier {
  static const _uuid = Uuid();

  // ============================================================
  // CONTENT-ITEM templates (content / row / column / modal)
  // ============================================================

  /// Преобразует payload шаблона в [ContentItem] с новыми id.
  /// Возвращает null, если payload не похож на ContentItem-payload.
  static ContentItem? buildContentItem(TemplateItem template) {
    switch (template.kind) {
      case TemplateKind.content:
      case TemplateKind.row:
      case TemplateKind.column:
      case TemplateKind.modal:
        break;
      case TemplateKind.node:
      case TemplateKind.chapter:
      case TemplateKind.multi:
        return null;
    }
    try {
      final raw = _deepClone(template.payload);
      final item = ContentItem.fromJson(raw);
      return _reIdContentItem(item);
    } catch (_) {
      return null;
    }
  }

  /// Глубоко копирует [ContentItem] и заменяет id во всех вложенных детях
  /// и кнопках модального окна.
  static ContentItem reIdContentItem(ContentItem item) =>
      _reIdContentItem(item);

  static ContentItem _reIdContentItem(ContentItem item) {
    final List<ContentItem>? newChildren = item.children
        ?.map(_reIdContentItem)
        .toList();
    final newModalButtons = item.modalButtons
        ?.map((b) => b.copyWith(id: _uuid.v4()))
        .toList();
    return item.copyWith(
      id: _uuid.v4(),
      children: newChildren,
      modalButtons: newModalButtons,
    );
  }

  // ============================================================
  // LINKED instances (Templates v2 — Always-latest)
  // ============================================================

  /// Создаёт «тощий» linked-инстанс ContentItem для шаблона.
  ///
  /// На диск/в дерево пишется только это: новый uuid, ссылка на мастера и
  /// версия. Реальный контент (children/modalButtons/настройки) будет
  /// разворачиваться `TemplateInstanceResolver`-ом на чтении.
  ///
  /// Поле [parent] из payload мастера используется только чтобы взять
  /// корректный `type` (button/row/column/modal/text/...): тип должен
  /// совпадать, чтобы дерево было валидно для редактора и сериализации.
  static ContentItem? buildLinkedContentItem(TemplateItem template) {
    switch (template.kind) {
      case TemplateKind.content:
      case TemplateKind.row:
      case TemplateKind.column:
      case TemplateKind.modal:
        break;
      case TemplateKind.node:
      case TemplateKind.chapter:
      case TemplateKind.multi:
        return null;
    }
    String type;
    try {
      type = (template.payload['type'] as String?) ?? 'text';
    } catch (_) {
      type = 'text';
    }
    return ContentItem(
      id: _uuid.v4(),
      type: type,
      templateRef: template.id,
      templateVersion: template.contentVersion,
    );
  }

  /// Создаёт linked-инстанс ноды.
  static SavedNode? buildLinkedNode(
    TemplateItem template, {
    required String chapterId,
    required double x,
    required double y,
  }) {
    if (template.kind != TemplateKind.node) return null;
    String title = tr('Нода');
    try {
      title = (template.payload['title'] as String?) ?? title;
    } catch (_) {}
    return SavedNode(
      id: _uuid.v4(),
      chapterId: chapterId,
      title: title,
      content: const <String, dynamic>{'items': []},
      x: x,
      y: y,
      templateRef: template.id,
      templateVersion: template.contentVersion,
    );
  }

  /// «Отвязать» ContentItem от шаблона: получить разрешённый snapshot и
  /// сохранить его уже без `templateRef` (re-id, чтобы id были «нормальные»
  /// uuid v4, а не tpl_*).
  ///
  /// [resolved] — результат `TemplateInstanceResolver.resolveContentItem`
  /// (или resolveTree) для отвязываемого инстанса. Возвращает snapshot
  /// со свежими id внутри.
  static ContentItem detachContentItem(ContentItem resolved) {
    final cleared = resolved.copyWith(clearTemplateLink: true);
    return _reIdContentItem(cleared);
  }

  /// «Отвязать» ноду от шаблона: вернуть SavedNode со свежими id содержимого
  /// и без `templateRef`.
  static SavedNode detachNode(SavedNode resolved) {
    final fixedContent = _reIdContentMap(resolved.content);
    return resolved.copyWith(content: fixedContent, clearTemplateLink: true);
  }

  // ============================================================
  // NODE templates
  // ============================================================

  /// Превращает payload шаблона ноды в [SavedNode] с новыми id у самой ноды
  /// и у всех вложенных контент-айтемов.
  ///
  /// [chapterId] — глава, в которую вставляем (обязательно).
  /// [position] — где разместить ноду (мировая координата).
  /// [titleSuffix] — необязательная приписка к названию (напр. ' (шаблон)').
  static SavedNode? buildNode(
    TemplateItem template, {
    required String chapterId,
    required double x,
    required double y,
    String? titleSuffix,
  }) {
    if (template.kind != TemplateKind.node) return null;
    try {
      final raw = _deepClone(template.payload);
      final original = SavedNode.fromJson(raw);

      // Рекурсивно перегенерируем id внутри content.items
      final fixedContent = _reIdContentMap(original.content);

      final newTitle = titleSuffix == null
          ? original.title
          : '${original.title}$titleSuffix';

      // Копируем поверх исходной ноды, а не собираем поле за полем:
      // перечисление молча теряло каждое новое поле модели — в шаблон
      // не попадали видео-фон, размытие, отступы, переход, ограничения
      // ноды. Сбрасываем только то, что в копии невалидно.
      return original.copyWith(
        id: _uuid.v4(),
        chapterId: chapterId,
        title: newTitle,
        content: fixedContent,
        x: x,
        y: y,
        // namespace-only ссылка на другую ноду в template невалидна;
        // безопаснее обнулить, чтобы не было битой ссылки.
        clearDefaultActionNodeId: true,
        // Копия — обычная нода: связь с мастер-шаблоном мастера не переезжает.
        clearTemplateLink: true,
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _reIdContentMap(Map<String, dynamic> content) {
    final items = content['items'];
    if (items is! List) return content;
    final fixedItems = <Map<String, dynamic>>[];
    for (final raw in items) {
      if (raw is Map) {
        try {
          final ci = ContentItem.fromJson(Map<String, dynamic>.from(raw));
          fixedItems.add(_reIdContentItem(ci).toJson());
        } catch (_) {
          // на крайний случай — копируем как есть с заменой id
          final m = Map<String, dynamic>.from(raw);
          m['id'] = _uuid.v4();
          fixedItems.add(m);
        }
      }
    }
    return {...content, 'items': fixedItems};
  }

  // ============================================================
  // Создание шаблона ИЗ существующих объектов
  // ============================================================

  /// Создать шаблон из существующего [ContentItem].
  /// Тип определяется автоматически (row/column/modal/content).
  static TemplateItem makeFromContentItem({
    required String name,
    required ContentItem item,
    String? description,
    String? category,
  }) {
    final TemplateKind kind;
    switch (item.type) {
      case 'row':
        kind = TemplateKind.row;
        break;
      case 'column':
        kind = TemplateKind.column;
        break;
      case 'modal':
        kind = TemplateKind.modal;
        break;
      default:
        kind = TemplateKind.content;
    }
    return TemplateItem(
      id: _uuid.v4(),
      name: name,
      kind: kind,
      payload: _deepClone(item.toJson()),
      description: description,
      category: category,
    );
  }

  /// Создать шаблон из существующего [SavedNode].
  static TemplateItem makeFromNode({
    required String name,
    required SavedNode node,
    String? description,
    String? category,
  }) {
    return TemplateItem(
      id: _uuid.v4(),
      name: name,
      kind: TemplateKind.node,
      payload: _deepClone(node.toJson()),
      description: description,
      category: category,
    );
  }

  // ============================================================
  // CHAPTER templates
  // ============================================================

  /// Создать шаблон из главы.
  ///
  /// [chapterName] — название главы (для UI).
  /// [nodes] — все ноды этой главы (`SavedNode`).
  /// [connections] — связи в формате `{id, fromId, toId}` из `config.json`.
  /// [entryNodeId] — id ноды-входа в главу (опц.).
  static TemplateItem makeFromChapter({
    required String name,
    required List<SavedNode> nodes,
    required List<Map<String, dynamic>> connections,
    String? chapterName,
    String? entryNodeId,
    String? description,
    String? category,
  }) {
    // Берём только связи, обе ноды которых входят в [nodes].
    final ids = nodes.map((n) => n.id).toSet();
    final internalConns = connections
        .where(
          (c) =>
              ids.contains(c['fromId']?.toString()) &&
              ids.contains(c['toId']?.toString()),
        )
        .map(
          (c) => {
            'id': c['id']?.toString() ?? _uuid.v4(),
            'fromId': c['fromId'].toString(),
            'toId': c['toId'].toString(),
          },
        )
        .toList();

    final payload = {
      if (chapterName != null) 'chapterName': chapterName,
      'nodes': nodes.map((n) => n.toJson()).toList(),
      'connections': internalConns,
      if (entryNodeId != null && ids.contains(entryNodeId))
        'entryNodeId': entryNodeId,
    };

    return TemplateItem(
      id: _uuid.v4(),
      name: name,
      kind: TemplateKind.chapter,
      payload: payload,
      description: description,
      category: category,
    );
  }

  /// Применить шаблон главы: перегенерировать все id, обновить ссылки.
  ///
  /// [targetChapterId] — новый id главы (генерится снаружи).
  /// [offsetX]/[offsetY] — сдвиг координат, если нужно.
  static ChapterApplyResult? buildChapter(
    TemplateItem template, {
    required String targetChapterId,
    double offsetX = 0,
    double offsetY = 0,
  }) {
    if (template.kind != TemplateKind.chapter) return null;
    try {
      final raw = _deepClone(template.payload);
      final nodesRaw = raw['nodes'];
      if (nodesRaw is! List) return null;

      // 1. Считываем все ноды и создаём mapping old → new.
      final original = <SavedNode>[];
      for (final n in nodesRaw) {
        if (n is Map) {
          try {
            original.add(SavedNode.fromJson(Map<String, dynamic>.from(n)));
          } catch (_) {}
        }
      }
      if (original.isEmpty) return null;

      final idMap = <String, String>{};
      for (final node in original) {
        idMap[node.id] = _uuid.v4();
      }

      // 2. Пересобираем ноды с новыми id и chapterId.
      final newNodes = <SavedNode>[];
      for (final node in original) {
        final newId = idMap[node.id]!;
        final fixedContent = _reIdContentMapWithLinkRemap(node.content, idMap);
        final remappedDefault = node.defaultActionNodeId == null
            ? null
            : idMap[node.defaultActionNodeId];
        // Пересборка поверх исходной ноды: поля, которые здесь не
        // перечислить, копируются сами (видео-фон, размытие, отступы,
        // переход, ограничения). Ссылка на ноду вне копии главы
        // нерезолвится — её снимаем.
        newNodes.add(
          node.copyWith(
            id: newId,
            chapterId: targetChapterId,
            content: fixedContent,
            x: node.x + offsetX,
            y: node.y + offsetY,
            defaultActionNodeId: remappedDefault,
            clearDefaultActionNodeId:
                node.defaultActionNodeId != null && remappedDefault == null,
            clearTemplateLink: true,
          ),
        );
      }

      // 3. Пересобираем связи (только внутренние).
      final connsRaw = raw['connections'];
      final newConns = <ChapterConnection>[];
      if (connsRaw is List) {
        for (final c in connsRaw) {
          if (c is Map) {
            final from = idMap[c['fromId']?.toString()];
            final to = idMap[c['toId']?.toString()];
            if (from != null && to != null) {
              newConns.add(
                ChapterConnection(id: _uuid.v4(), fromId: from, toId: to),
              );
            }
          }
        }
      }

      return ChapterApplyResult(
        newChapterId: targetChapterId,
        chapterName: raw['chapterName'] as String?,
        nodes: newNodes,
        connections: newConns,
        entryNodeId: idMap[raw['entryNodeId']?.toString()],
      );
    } catch (_) {
      return null;
    }
  }

  /// Та же логика, что и `_reIdContentMap`, но дополнительно ремапит
  /// `targetNodeId` у кнопок (с помощью [nodeIdMap]).
  static Map<String, dynamic> _reIdContentMapWithLinkRemap(
    Map<String, dynamic> content,
    Map<String, String> nodeIdMap,
  ) {
    final items = content['items'];
    if (items is! List) return content;
    final fixedItems = <Map<String, dynamic>>[];
    for (final raw in items) {
      if (raw is Map) {
        try {
          final ci = ContentItem.fromJson(Map<String, dynamic>.from(raw));
          final fixed = _reIdAndRemapLinks(ci, nodeIdMap);
          fixedItems.add(fixed.toJson());
        } catch (_) {
          final m = Map<String, dynamic>.from(raw);
          m['id'] = _uuid.v4();
          fixedItems.add(m);
        }
      }
    }
    return {...content, 'items': fixedItems};
  }

  static ContentItem _reIdAndRemapLinks(
    ContentItem item,
    Map<String, String> nodeIdMap,
  ) {
    final List<ContentItem>? newChildren = item.children
        ?.map((c) => _reIdAndRemapLinks(c, nodeIdMap))
        .toList();
    final newModalButtons = item.modalButtons?.map((b) {
      final remapped = nodeIdMap[b.targetNodeId];
      return b.copyWith(
        id: _uuid.v4(),
        targetNodeId: remapped ?? b.targetNodeId,
      );
    }).toList();
    final newTarget = nodeIdMap[item.targetNodeId] ?? item.targetNodeId;
    return item.copyWith(
      id: _uuid.v4(),
      children: newChildren,
      modalButtons: newModalButtons,
      targetNodeId: newTarget,
    );
  }

  // ============================================================
  // Сбор путей к ресурсам, на которые ссылается шаблон
  // ============================================================

  /// Возвращает все относительные пути ресурсов в payload (для упаковки в
  /// архив). Поддерживает любые `kind`.
  ///
  /// Пути собираются из:
  /// * `resourcePath` (`image`, `audio`, `script`)
  /// * `backgroundAssetId` / `backgroundAudioId` / `scriptAssetId`
  ///   (для нод и глав)
  /// * `buttonStyle.cornerAsset/hAsset/vAsset/centerAsset`
  /// * `fontFamily` у айтемов и у `buttonStyle` — шрифт живёт в `res/fonts/`
  ///   отдельным файлом, без него в другом квесте текст рисуется дефолтным
  /// * инлайн-теги `[font=res/fonts/x.ttf]…[/font]` в любом тексте
  /// * `scriptTriggers.*` (значения — пути к скриптам)
  static Set<String> collectResourcePaths(TemplateItem template) {
    final result = <String>{};

    void addCandidate(dynamic value) {
      if (value is! String) return;
      var raw = value.trim();
      if (raw.isEmpty) return;
      // Игнорируем формульные привязки (начинаются с '=').
      if (raw.startsWith('=')) return;
      // Нормализуем — убираем ведущий / и quests/<id>/
      raw = raw.replaceFirst(RegExp(r'^/+'), '');
      // Не относительный путь? скорее всего просто id ресурса (имя файла).
      // Превращаем в res/images/<name>, если не содержит '/'.
      if (!raw.contains('/')) {
        final lower = raw.toLowerCase();
        if (lower.endsWith('.png') ||
            lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.webp') ||
            lower.endsWith('.gif')) {
          raw = 'res/images/$raw';
        } else if (lower.endsWith('.mp3') ||
            lower.endsWith('.wav') ||
            lower.endsWith('.ogg') ||
            lower.endsWith('.m4a')) {
          raw = 'res/audio/$raw';
        } else if (lower.endsWith('.ttf') || lower.endsWith('.otf')) {
          raw = 'res/fonts/$raw';
        } else if (lower.endsWith('.json')) {
          // Скрипт — пусть остаётся в scripts/, если относительный путь
          // не указан.
          raw = 'scripts/$raw';
        } else {
          // не знаем тип — пропускаем
          return;
        }
      }
      result.add(raw);
    }

    void addInlineFonts(String text) {
      if (!text.contains('[font=')) return;
      for (final path in FontService.extractInlineFontPaths(text)) {
        addCandidate(path);
      }
    }

    void addInlineImages(String text) {
      for (final path in extractInlineImagePaths(text)) {
        addCandidate(path.contains('/') ? path : 'res/images/$path');
      }
    }

    void walk(dynamic node) {
      if (node is Map) {
        node.forEach((key, value) {
          final k = key.toString();
          if (k == 'resourcePath' ||
              k == 'backgroundAssetId' ||
              k == 'backgroundAudioId' ||
              k == 'scriptAssetId' ||
              k == 'cornerAsset' ||
              k == 'hAsset' ||
              k == 'vAsset' ||
              k == 'centerAsset' ||
              k == 'avatarPath' ||
              k == 'fontFamily') {
            addCandidate(value);
          } else if (k == 'scriptTriggers' && value is Map) {
            for (final v in value.values) {
              addCandidate(v);
            }
          } else {
            walk(value);
          }
        });
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      } else if (node is String) {
        // Шрифт слоя мог быть задан не свойством, а инлайн-тегом в тексте.
        addInlineFonts(node);
        addInlineImages(node);
      }
    }

    walk(template.payload);
    return result;
  }

  // ============================================================
  // Анализ: какие плагины использует шаблон?
  // ============================================================

  /// Рекурсивно собирает все pluginId, на которые ссылается payload шаблона.
  static Set<String> collectPluginIds(TemplateItem template) {
    final result = <String>{};
    void walk(dynamic raw) {
      if (raw is Map) {
        if (raw['type']?.toString() == 'plugin') {
          final pid = raw['pluginId']?.toString();
          if (pid != null && pid.isNotEmpty) {
            result.add(pid);
          }
        }
        for (final v in raw.values) {
          walk(v);
        }
      } else if (raw is List) {
        for (final v in raw) {
          walk(v);
        }
      }
    }

    walk(template.payload);
    return result;
  }

  static Map<String, dynamic> _deepClone(Map<String, dynamic> source) {
    final encoded = jsonEncode(source);
    final decoded = jsonDecode(encoded);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return <String, dynamic>{};
  }
}
