import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';

/// Служебная метка «документ изменён»: её пишет контроллер в `subtitle` и по
/// ней же `isDirty` понимает, что надо сохранить. Хранится непереведённой —
/// на витрину она уходит через `displaySubtitle`.
const String kDirtyDocumentMarker = 'Изменено';

/// Persistent documents which can live in the quest editor workspace.
enum EditorDocumentKind {
  chapters,
  canvas,
  node,
  visualScript,
  lua,
  resources,
  templates,
  questSettings,
  game,
  gameLoad,
  guide,
  questHistory,
}

extension EditorDocumentKindX on EditorDocumentKind {
  String get wireName => switch (this) {
    EditorDocumentKind.chapters => 'chapters',
    EditorDocumentKind.canvas => 'canvas',
    EditorDocumentKind.node => 'node',
    EditorDocumentKind.visualScript => 'visual_script',
    EditorDocumentKind.lua => 'lua',
    EditorDocumentKind.resources => 'resources',
    EditorDocumentKind.templates => 'templates',
    EditorDocumentKind.questSettings => 'quest_settings',
    EditorDocumentKind.game => 'game',
    EditorDocumentKind.gameLoad => 'game_load',
    EditorDocumentKind.guide => 'guide',
    EditorDocumentKind.questHistory => 'quest_history',
  };

  static EditorDocumentKind? fromWireName(String? value) {
    for (final kind in EditorDocumentKind.values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }

  IconData get icon => switch (this) {
    EditorDocumentKind.chapters => Icons.account_tree_rounded,
    EditorDocumentKind.canvas => Icons.schema_rounded,
    EditorDocumentKind.node => Icons.article_rounded,
    EditorDocumentKind.visualScript => Icons.account_tree_outlined,
    EditorDocumentKind.lua => Icons.data_object_rounded,
    EditorDocumentKind.resources => Icons.folder_special_rounded,
    EditorDocumentKind.templates => Icons.bookmark_rounded,
    EditorDocumentKind.questSettings => Icons.settings_rounded,
    EditorDocumentKind.game => Icons.play_arrow_rounded,
    EditorDocumentKind.gameLoad => Icons.restore_rounded,
    EditorDocumentKind.guide => Icons.menu_book_rounded,
    EditorDocumentKind.questHistory => Icons.history_rounded,
  };

  /// Короткая человекочитаемая метка типа документа (для обзора вкладок).
  String get label => switch (this) {
    EditorDocumentKind.chapters => tr('Главы'),
    EditorDocumentKind.canvas => 'Canvas',
    EditorDocumentKind.node => tr('Нода'),
    EditorDocumentKind.visualScript => tr('Скрипт'),
    EditorDocumentKind.lua => 'Lua',
    EditorDocumentKind.resources => tr('Ресурсы'),
    EditorDocumentKind.templates => tr('Шаблоны'),
    EditorDocumentKind.questSettings => tr('Настройки'),
    EditorDocumentKind.game => tr('Симуляция'),
    EditorDocumentKind.gameLoad => tr('Симуляция из сейва'),
    EditorDocumentKind.guide => tr('Гайды'),
    EditorDocumentKind.questHistory => tr('История версий'),
  };
}

/// Stable identity of a document, independent from Navigator and widget state.
@immutable
class EditorDocumentId {
  final String questId;
  final EditorDocumentKind kind;
  final String key;

  const EditorDocumentId({
    required this.questId,
    required this.kind,
    required this.key,
  });

  String get persistenceKey => '$questId|${kind.wireName}|$key';

  Map<String, dynamic> toJson() => {
    'questId': questId,
    'kind': kind.wireName,
    'key': key,
  };

  factory EditorDocumentId.fromJson(Map<String, dynamic> json) {
    final kind = EditorDocumentKindX.fromWireName(json['kind']?.toString());
    if (kind == null) {
      throw const FormatException('Unknown editor document kind');
    }
    return EditorDocumentId(
      questId: json['questId']?.toString() ?? '',
      kind: kind,
      key: json['key']?.toString() ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EditorDocumentId &&
      other.questId == questId &&
      other.kind == kind &&
      other.key == key;

  @override
  int get hashCode => Object.hash(questId, kind, key);

  @override
  String toString() => persistenceKey;
}

@immutable
class EditorDocumentDescriptor {
  final EditorDocumentId id;
  final String title;
  final String? subtitle;

  /// Runtime/file key used to build the screen; it is not document identity.
  final String? routeKey;

  const EditorDocumentDescriptor({
    required this.id,
    required this.title,
    this.subtitle,
    this.routeKey,
  });

  IconData get icon => id.kind.icon;

  /// Dirty state is represented in the persisted descriptor without adding a
  /// second mutable flag to the workspace model. `kDirtyDocumentMarker` —
  /// маркер грязного документа без подзаголовка (см. `_dirtySubtitle`).
  ///
  /// Сравнение идёт по константе, а не по переводу: подпись на витрине
  /// локализирована, и проверка вида `subtitle == tr('Изменено')` молча
  /// перестала бы находить грязные документы при другом языке UI — автосейв
  /// и предупреждение при закрытии теряли бы правки.
  bool get isDirty =>
      subtitle != null &&
      (subtitle!.endsWith(' •') || subtitle == kDirtyDocumentMarker);

  /// Подзаголовок для показа: служебная метка переводится, остальное как есть.
  String? get displaySubtitle =>
      subtitle == kDirtyDocumentMarker ? tr('Изменено') : subtitle;

  EditorDocumentDescriptor copyWith({
    String? title,
    String? subtitle,
    String? routeKey,
    bool clearSubtitle = false,
  }) => EditorDocumentDescriptor(
    id: id,
    title: title ?? this.title,
    subtitle: clearSubtitle ? null : (subtitle ?? this.subtitle),
    routeKey: routeKey ?? this.routeKey,
  );

  Map<String, dynamic> toJson() => {
    ...id.toJson(),
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (routeKey != null) 'routeKey': routeKey,
  };

  factory EditorDocumentDescriptor.fromJson(Map<String, dynamic> json) {
    return EditorDocumentDescriptor(
      id: EditorDocumentId.fromJson(json),
      title: json['title']?.toString() ?? tr('Документ'),
      subtitle: json['subtitle']?.toString(),
      routeKey: json['routeKey']?.toString(),
    );
  }

  static EditorDocumentDescriptor chapters(String questId) =>
      EditorDocumentDescriptor(
        id: EditorDocumentId(
          questId: questId,
          kind: EditorDocumentKind.chapters,
          key: 'root',
        ),
        title: tr('Главы'),
      );

  static EditorDocumentDescriptor canvas(
    String questId,
    String tagId, {
    String title = 'Canvas',
  }) => EditorDocumentDescriptor(
    id: EditorDocumentId(
      questId: questId,
      kind: EditorDocumentKind.canvas,
      key: tagId,
    ),
    title: title,
  );

  static EditorDocumentDescriptor node(
    String questId,
    String nodeId, {
    String? title,
  }) => EditorDocumentDescriptor(
    id: EditorDocumentId(
      questId: questId,
      kind: EditorDocumentKind.node,
      key: nodeId,
    ),
    // Не const-дефолт: подпись по умолчанию строится под текущий язык.
    title: title ?? tr('Нода'),
  );

  static EditorDocumentDescriptor visualScript(
    String questId,
    String scriptId, {
    String? title,
  }) => EditorDocumentDescriptor(
    id: EditorDocumentId(
      questId: questId,
      kind: EditorDocumentKind.visualScript,
      key: scriptId,
    ),
    title: title ?? tr('Скрипт'),
  );

  static EditorDocumentDescriptor lua(
    String questId,
    String resourceKey, {
    String title = 'Lua',
    String? fileName,
  }) => EditorDocumentDescriptor(
    id: EditorDocumentId(
      questId: questId,
      kind: EditorDocumentKind.lua,
      key: resourceKey,
    ),
    title: title,
    routeKey: fileName,
  );

  static EditorDocumentDescriptor resources(String questId) =>
      EditorDocumentDescriptor(
        id: EditorDocumentId(
          questId: questId,
          kind: EditorDocumentKind.resources,
          key: 'root',
        ),
        title: tr('Ресурсы'),
      );

  static EditorDocumentDescriptor templates(String questId) =>
      EditorDocumentDescriptor(
        id: EditorDocumentId(
          questId: questId,
          kind: EditorDocumentKind.templates,
          key: 'root',
        ),
        title: tr('Шаблоны'),
      );

  static EditorDocumentDescriptor questSettings(String questId) =>
      EditorDocumentDescriptor(
        id: EditorDocumentId(
          questId: questId,
          kind: EditorDocumentKind.questSettings,
          key: 'root',
        ),
        title: tr('Настройки'),
      );

  static EditorDocumentDescriptor gameSimulation(
    String questId, {
    String? title,
    String? startNodeId,
  }) => EditorDocumentDescriptor(
    id: EditorDocumentId(
      questId: questId,
      kind: EditorDocumentKind.game,
      // Идентичность симуляции включает точку старта, чтобы запуск из другой
      // ноды не переиспользовал чужую вкладку со старым startNodeId.
      key: 'simulation:${startNodeId ?? 'root'}',
    ),
    title: title ?? tr('Симуляция'),
    routeKey: startNodeId,
  );

  /// Вкладка «Симуляция из сейва». Пока слот не выбран — ключ `save:pick`
  /// (экран выбора сохранения); после выбора слота — `save:<slotId>`
  /// (игра, запущенная из этого слота).
  static EditorDocumentDescriptor gameFromSave(
    String questId, {
    String? title,
    String? slotId,
  }) => EditorDocumentDescriptor(
    id: EditorDocumentId(
      questId: questId,
      kind: EditorDocumentKind.gameLoad,
      key: slotId == null ? 'save:pick' : 'save:$slotId',
    ),
    title: title ?? tr('Симуляция из сейва'),
    routeKey: slotId,
  );

  /// Каталог гайдов как вкладка. Ключ `catalog` отличает его от вкладки
  /// конкретного гайда: у той ключ — id гайда.
  static EditorDocumentDescriptor guidesCatalog(String questId) =>
      EditorDocumentDescriptor(
        id: EditorDocumentId(
          questId: questId,
          kind: EditorDocumentKind.guide,
          key: 'catalog',
        ),
        title: tr('Гайды'),
      );

  static EditorDocumentDescriptor guide(
    String questId,
    String guideId, {
    String? title,
  }) => EditorDocumentDescriptor(
    id: EditorDocumentId(
      questId: questId,
      kind: EditorDocumentKind.guide,
      key: guideId,
    ),
    title: title ?? tr('Гайд'),
  );

  static EditorDocumentDescriptor questHistory(String questId) =>
      EditorDocumentDescriptor(
        id: EditorDocumentId(
          questId: questId,
          kind: EditorDocumentKind.questHistory,
          key: 'root',
        ),
        title: tr('История версий'),
      );
}

/// Узел дерева панелей (тайлинг): лист (документ) или сплит (две панели).
/// Каждый лист — будущее отдельное окно на ПК.
@immutable
sealed class EditorDockNode {
  const EditorDockNode();

  /// Все документы, видимые в этом поддереве.
  Iterable<EditorDocumentId> get documentIds => switch (this) {
    EditorDockLeaf(:final documentId) => [documentId],
    EditorDockSplit(:final first, :final second) => [
      ...first.documentIds,
      ...second.documentIds,
    ],
  };

  Map<String, dynamic> toJson() => switch (this) {
    EditorDockLeaf(:final documentId) => {
      'type': 'leaf',
      'doc': documentId.toJson(),
    },
    EditorDockSplit(
      :final horizontal,
      :final ratio,
      :final first,
      :final second,
    ) =>
      {
        'type': 'split',
        'axis': horizontal ? 'row' : 'col',
        'ratio': ratio,
        'first': first.toJson(),
        'second': second.toJson(),
      },
  };

  static EditorDockNode? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final map = Map<String, dynamic>.from(json);
    try {
      return switch (map['type']?.toString()) {
        'leaf' => EditorDockLeaf(
          EditorDocumentId.fromJson(
            Map<String, dynamic>.from(map['doc'] as Map),
          ),
        ),
        'split' => EditorDockSplit(
          horizontal: map['axis']?.toString() == 'row',
          ratio: ((map['ratio'] as num?)?.toDouble() ?? 0.5)
              .clamp(0.15, 0.85)
              .toDouble(),
          first: EditorDockNode.tryFromJson(map['first'])!,
          second: EditorDockNode.tryFromJson(map['second'])!,
        ),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
}

/// Панель с одним документом.
@immutable
class EditorDockLeaf extends EditorDockNode {
  final EditorDocumentId documentId;

  const EditorDockLeaf(this.documentId);

  @override
  bool operator ==(Object other) =>
      other is EditorDockLeaf && other.documentId == documentId;

  @override
  int get hashCode => Object.hash('leaf', documentId);
}

/// Сплит из двух панелей. [horizontal] — панели рядом (row); иначе — одна
/// над другой (col). [ratio] — доля первой панели (0..1).
@immutable
class EditorDockSplit extends EditorDockNode {
  final bool horizontal;
  final double ratio;
  final EditorDockNode first;
  final EditorDockNode second;

  const EditorDockSplit({
    required this.horizontal,
    required this.ratio,
    required this.first,
    required this.second,
  });

  @override
  bool operator ==(Object other) =>
      other is EditorDockSplit &&
      other.horizontal == horizontal &&
      other.ratio == ratio &&
      other.first == first &&
      other.second == second;

  @override
  int get hashCode => Object.hash('split', horizontal, ratio, first, second);
}

/// Docking-ready layout. null [paneTree] — одна панель на весь экран
/// (обычный режим вкладок); иначе — дерево тайлинга.
@immutable
class EditorDockLayout {
  final List<EditorDocumentId> rootTabs;
  final EditorDockNode? paneTree;

  const EditorDockLayout({this.rootTabs = const [], this.paneTree});

  EditorDockLayout copyWith({
    List<EditorDocumentId>? rootTabs,
    EditorDockNode? paneTree,
    bool clearPaneTree = false,
  }) => EditorDockLayout(
    rootTabs: List.unmodifiable(rootTabs ?? this.rootTabs),
    paneTree: clearPaneTree ? null : (paneTree ?? this.paneTree),
  );

  Map<String, dynamic> toJson() => {
    'type': 'stack',
    'tabs': rootTabs.map((id) => id.toJson()).toList(),
    if (paneTree != null) 'panes': paneTree!.toJson(),
  };

  factory EditorDockLayout.fromJson(Map<String, dynamic> json) {
    final rawTabs = json['tabs'];
    final tabs = rawTabs is List
        ? rawTabs
              .whereType<Map>()
              .map(
                (raw) =>
                    EditorDocumentId.fromJson(Map<String, dynamic>.from(raw)),
              )
              .toList()
        : const <EditorDocumentId>[];
    return EditorDockLayout(
      rootTabs: List.unmodifiable(tabs),
      paneTree: EditorDockNode.tryFromJson(json['panes']),
    );
  }
}

@immutable
class EditorWorkspaceState {
  final List<EditorDocumentDescriptor> documents;
  final EditorDocumentId? activeId;
  final EditorDockLayout layout;

  const EditorWorkspaceState({
    this.documents = const [],
    this.activeId,
    this.layout = const EditorDockLayout(),
  });

  /// Инвариант воркспейса: документы без повторов по id.
  ///
  /// Дубликат вкладки = дубликаты GlobalKey/ValueKey/Hero в дереве →
  /// каскад ассертов (duplicate keys, multiple heroes, layout crashes).
  /// Санитизация применяется на всех границах: [restore] (вход из сессии),
  /// сохранение сессии, построение таб-бара.
  EditorWorkspaceState sanitized() {
    // Последнее вхождение каждого id побеждает (свежие title/subtitle),
    // но ПОЗИЦИЯ сохраняется от первого — порядок вкладок не скачет.
    final lastById = <EditorDocumentId, EditorDocumentDescriptor>{};
    for (final d in documents) {
      lastById[d.id] = d;
    }
    final emittedIds = <EditorDocumentId>{};
    final deduped = [
      for (final d in documents)
        if (emittedIds.add(d.id)) lastById[d.id]!,
    ];

    var active = activeId;
    if (active != null && !lastById.containsKey(active)) {
      active = deduped.isEmpty ? null : deduped.first.id;
    }

    // rootTabs без повторов и только из живых документов.
    final validTabs = <EditorDocumentId>[];
    final tabSeen = <EditorDocumentId>{};
    for (final id in layout.rootTabs) {
      if (lastById.containsKey(id) && tabSeen.add(id)) validTabs.add(id);
    }
    for (final d in deduped) {
      if (tabSeen.add(d.id)) validTabs.add(d.id);
    }

    return copyWith(
      documents: deduped,
      activeId: active,
      clearActive: active == null,
      layout: layout.copyWith(rootTabs: validTabs),
    );
  }

  EditorWorkspaceState copyWith({
    List<EditorDocumentDescriptor>? documents,
    EditorDocumentId? activeId,
    bool clearActive = false,
    EditorDockLayout? layout,
  }) {
    return EditorWorkspaceState(
      documents: List.unmodifiable(documents ?? this.documents),
      activeId: clearActive ? null : (activeId ?? this.activeId),
      layout: layout ?? this.layout,
    );
  }
}
