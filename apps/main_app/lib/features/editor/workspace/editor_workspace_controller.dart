import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'editor_document.dart';

/// Lifecycle callbacks are runtime-only and deliberately not serialized.
typedef EditorSaveCallback = Future<bool> Function();
typedef EditorCloseCallback = Future<bool> Function();

class EditorDocumentRuntime {
  final EditorSaveCallback? onSave;
  final EditorCloseCallback? onBeforeClose;
  final bool keepAlive;

  const EditorDocumentRuntime({
    this.onSave,
    this.onBeforeClose,
    this.keepAlive = true,
  });
}

final editorWorkspaceControllerProvider = StateNotifierProvider.autoDispose
    .family<EditorWorkspaceController, EditorWorkspaceState, String>(
      (ref, questId) {
        ref.keepAlive();
        return EditorWorkspaceController(questId);
      },
    );

class EditorWorkspaceController extends StateNotifier<EditorWorkspaceState> {
  /// Сколько последних закрытых вкладок помнить для Ctrl+Shift+T.
  static const int recentlyClosedLimit = 15;

  /// Лимит стека посещений вкладок (браузерный «Назад»).
  static const int _navStackLimit = 100;

  final String questId;
  final Map<EditorDocumentId, EditorDocumentRuntime> _runtimes = {};
  final List<EditorDocumentDescriptor> _recentlyClosed = [];

  /// Стек посещений вкладок в порядке переходов. Хранит дескрипторы,
  /// а не только id: документ, вытесненный заменой вкладки (режим без
  /// табов) или закрытый крестиком, «Назад» переоткрывает. Runtime-only:
  /// не сериализуется и пересобирается в [restore].
  final List<EditorDocumentDescriptor> _navStack = [];

  EditorWorkspaceController(this.questId) : super(const EditorWorkspaceState());

  /// Последние закрытые вкладки (runtime-only, не сериализуются).
  List<EditorDocumentDescriptor> get recentlyClosed =>
      List.unmodifiable(_recentlyClosed);

  bool contains(EditorDocumentId id) =>
      state.documents.any((document) => document.id == id);

  EditorDocumentId? get activeId => state.activeId;

  void _pushNav(EditorDocumentDescriptor descriptor) {
    _navStack.removeWhere((entry) => entry.id == descriptor.id);
    _navStack.add(descriptor);
    if (_navStack.length > _navStackLimit) {
      _navStack.removeRange(0, _navStack.length - _navStackLimit);
    }
  }

  void _pushNavById(EditorDocumentId id) {
    final index = state.documents.indexWhere((document) => document.id == id);
    if (index >= 0) _pushNav(state.documents[index]);
  }

  /// Браузерный «Назад»: возвращается к предыдущей посещённой вкладке,
  /// не закрывая текущую. Документ-цель при необходимости переоткрывается
  /// (замена вкладки в режиме без табов, закрытие крестиком).
  /// Возвращает false, если стек исчерпан — вызывающий может закрыть
  /// активную вкладку.
  bool goBack() {
    final target = popBackTarget();
    if (target == null) return false;
    open(target); // существует → фокус, нет → переоткрытие
    return true;
  }

  /// Архитектурно чистый вариант: возвращает дескриптор для навигации
  /// без открытия. Shell решает как открывать (через _open с учётом
  /// _autoOpenTab/_tabsEnabled). Удаляет текущую запись и возвращает
  /// предыдущую валидную, либо null если стек исчерпан.
  EditorDocumentDescriptor? popBackTarget() {
    while (_navStack.length >= 2) {
      _navStack.removeLast(); // уходим с текущей
      final target = _navStack.last;
      if (target.id.questId != questId) {
        _navStack.removeLast(); // чужая/протухшая запись
        continue;
      }
      return target;
    }
    return null;
  }

  void restore(EditorWorkspaceState restored) {
    // Инвариант на входе: дубликаты вкладок из сохранённой сессии
    // схлопываем до того, как они попадут в дерево (иначе — duplicate
    // keys / multiple heroes / каскад ассертов).
    final safe = restored.sanitized();
    final documents = safe.documents
        .where((document) => document.id.questId == questId)
        .toList();
    if (documents.isEmpty) return;
    assert(() {
      final removedIn = restored.documents.length;
      final removedOut = documents.length;
      if (removedIn != removedOut) {
        // ignore: avoid_print
        print(
          '⚠️ [Workspace] restore: удалено дублей/чужих документов: '
          '${removedIn - removedOut}',
        );
      }
      return true;
    }());
    var active =
        safe.activeId != null &&
            documents.any((document) => document.id == safe.activeId)
        ? safe.activeId
        : documents.first.id;
    // Валидируем дерево панелей: листья без документа отбрасываем, сплиты
    // схлопываем; активный документ обязан быть виден в панели.
    var tree = restored.layout.paneTree;
    if (tree != null) {
      final valid = documents.map((document) => document.id).toSet();
      tree = _pruneTreeTo(tree, valid);
      if (tree is EditorDockLeaf) tree = null;
      if (tree != null && !tree.documentIds.contains(active)) {
        active = tree.documentIds.first;
      }
    }
    state = EditorWorkspaceState(
      documents: List.unmodifiable(documents),
      activeId: active,
      layout: EditorDockLayout(
        rootTabs: safe.layout.rootTabs,
        paneTree: tree,
      ),
    );
    // Стек посещений не восстанавливаем: вкладки из сессии — фон,
    // а не «визиты» этой сессии. Точку входа в историю записывает шелл
    // (initialDocument / первое открытие), иначе «Назад» уводит на
    // протухшие вкладки прошлой сессии вместо выхода из редактора.
    _navStack.clear();
  }

  EditorDocumentId open(EditorDocumentDescriptor descriptor) {
    if (descriptor.id.questId != questId) {
      throw ArgumentError('Document belongs to another quest');
    }

    final existingIndex = state.documents.indexWhere(
      (document) => document.id == descriptor.id,
    );
    if (existingIndex >= 0) {
      focus(descriptor.id);
      return descriptor.id;
    }

    final previousActive = state.activeId;
    final documents = [...state.documents, descriptor];
    state = state.copyWith(
      documents: documents,
      activeId: descriptor.id,
      layout: state.layout.copyWith(
        rootTabs: documents.map((document) => document.id).toList(),
      ),
    );
    _pushNav(descriptor);
    // В режиме панелей новый документ тайлится в новую панель рядом с
    // активной (ориентация чередуется с родителем активного листа), чтобы
    // количество панелей могло расти вместе с открытыми вкладками.
    final tree = state.layout.paneTree;
    if (tree != null && previousActive != null) {
      final split = _splitLeaf(
        tree,
        previousActive,
        descriptor.id,
        horizontal: _autoSplitOrientation(tree, previousActive),
      );
      // Если якорь оказался не листом (рассинхрон стейта), сплит молча
      // вернул дерево без нового документа — активная вкладка осталась бы
      // невидимой («пустой экран»). Схлопываем панели в обычный режим.
      final safeTree = split.documentIds.contains(descriptor.id)
          ? split
          : null;
      state = state.copyWith(
        layout: state.layout.copyWith(
          paneTree: safeTree,
          clearPaneTree: safeTree == null,
        ),
      );
    }
    return descriptor.id;
  }

  void focus(EditorDocumentId id, {bool record = true}) {
    if (!contains(id)) return;
    final changed = state.activeId != id;
    final tree = state.layout.paneTree;
    if (tree == null) {
      if (changed) {
        state = state.copyWith(activeId: id);
        if (record) _pushNavById(id);
      }
      return;
    }
    if (tree.documentIds.contains(id)) {
      if (changed) {
        state = state.copyWith(activeId: id);
        if (record) _pushNavById(id);
      }
      return;
    }
    // Фоновая вкладка: показываем её в активной панели (свап документа).
    final active = state.activeId;
    if (active == null) return;
    state = state.copyWith(
      activeId: id,
      layout: state.layout.copyWith(paneTree: _swapLeaf(tree, active, id)),
    );
    if (record) _pushNavById(id);
  }

  void rename(EditorDocumentId id, String title, {String? subtitle}) {
    final documents = state.documents
        .map(
          (document) => document.id == id
              ? document.copyWith(title: title, subtitle: subtitle)
              : document,
        )
        .toList();
    state = state.copyWith(documents: documents);
  }

  void markDirty(EditorDocumentId id, bool dirty) {
    final documents = state.documents.map((document) {
      if (document.id != id) return document;
      final subtitle = dirty
          ? _dirtySubtitle(document.subtitle)
          : _cleanSubtitle(document.subtitle);
      return document.copyWith(
        subtitle: subtitle,
        clearSubtitle: !dirty && subtitle == null,
      );
    }).toList();
    state = state.copyWith(documents: documents);
  }

  void registerRuntime(EditorDocumentId id, EditorDocumentRuntime runtime) {
    _runtimes[id] = runtime;
  }

  void unregisterRuntime(EditorDocumentId id) {
    _runtimes.remove(id);
  }

  Future<bool> save(EditorDocumentId id) async {
    final callback = _runtimes[id]?.onSave;
    if (callback == null) return true;
    return callback();
  }

  /// Заменяет документ на той же позиции вкладки (например, экран выбора
  /// сохранения → запущенная игра из слота). Возвращает id нового документа.
  EditorDocumentId replace(
    EditorDocumentId oldId,
    EditorDocumentDescriptor newDescriptor,
  ) {
    if (newDescriptor.id.questId != questId) {
      throw ArgumentError('Document belongs to another quest');
    }
    final index = state.documents.indexWhere(
      (document) => document.id == oldId,
    );
    if (index < 0) return open(newDescriptor);

    final documents = [...state.documents];
    documents[index] = newDescriptor;
    _runtimes.remove(oldId);
    // Стек: замена вкладки — это НОВЫЙ визит. Прежние записи не трогаем:
    // вытесненный документ остаётся в стеке дескриптором, и «Назад»
    // сможет переоткрыть его (критично для режима без табов, где вся
    // навигация глав→канвас→нода живёт на одной заменяемой вкладке).
    state = state.copyWith(
      documents: documents,
      activeId: newDescriptor.id,
      layout: state.layout.copyWith(
        rootTabs: documents.map((document) => document.id).toList(),
      ),
    );
    _pushNav(newDescriptor);
    final tree = state.layout.paneTree;
    if (tree != null && tree.documentIds.contains(oldId)) {
      state = state.copyWith(
        layout: state.layout.copyWith(
          paneTree: _swapLeaf(tree, oldId, newDescriptor.id),
        ),
      );
    }
    return newDescriptor.id;
  }

  Future<bool> close(EditorDocumentId id) async {
    final runtime = _runtimes[id];
    if (runtime?.onBeforeClose != null) {
      final allowed = await runtime!.onBeforeClose!();
      if (!allowed) return false;
    }

    final index = state.documents.indexWhere((document) => document.id == id);
    if (index < 0) return true;

    final document = state.documents[index];
    _rememberClosed(document);
    // Явное закрытие убирает вкладку из стека посещений. Раньше запись
    // оставалась («Назад» умеет переоткрывать закрытые вкладки), и после
    // закрытия экрана ближайший «Назад» возвращал его обратно: пользователь
    // попадал в цикл «Назад → закрытая вкладка → Назад → та же вкладка».
    // Вернуть закрытую вкладку можно осознанно — Ctrl+Shift+T
    // ([reopenLastClosed]), а не кнопкой «Назад».
    _navStack.removeWhere((entry) => entry.id == id);
    final remaining = [...state.documents]..removeAt(index);
    final nextActive = remaining.isEmpty
        ? null
        : (state.activeId == id
              ? remaining[(index - 1).clamp(0, remaining.length - 1)].id
              : state.activeId);
    _runtimes.remove(id);
    state = _withPrunedPaneTree(remaining, nextActive);
    return true;
  }

  /// Synchronous close for tests and clean descriptors. UI should prefer [close].
  void closeImmediately(EditorDocumentId id) {
    final index = state.documents.indexWhere((document) => document.id == id);
    if (index < 0) return;
    _rememberClosed(state.documents[index]);
    _navStack.removeWhere((entry) => entry.id == id);
    final remaining = state.documents
        .where((document) => document.id != id)
        .toList();
    final nextActive = remaining.isEmpty
        ? null
        : (state.activeId == id ? remaining.last.id : state.activeId);
    _runtimes.remove(id);
    state = _withPrunedPaneTree(remaining, nextActive);
  }

  /// Закрывает все вкладки, кроме [keepId] (с учётом runtime-вето).
  Future<void> closeOthers(EditorDocumentId keepId) async {
    for (final document in [...state.documents]) {
      if (document.id == keepId) continue;
      await close(document.id);
    }
  }

  /// Закрывает все вкладки правее [anchorId] (с учётом runtime-вето).
  Future<void> closeRight(EditorDocumentId anchorId) async {
    final index = state.documents.indexWhere(
      (document) => document.id == anchorId,
    );
    if (index < 0) return;
    for (final document in state.documents.skip(index + 1).toList()) {
      await close(document.id);
    }
  }

  /// Закрывает все вкладки (с учётом runtime-вето).
  Future<void> closeAll() async {
    for (final document in [...state.documents]) {
      await close(document.id);
    }
  }

  /// Ctrl+Shift+T: возвращает последнюю закрытую вкладку.
  void reopenLastClosed() {
    if (_recentlyClosed.isEmpty) return;
    final descriptor = _recentlyClosed.removeAt(0);
    open(descriptor);
  }

  /// Документы, видимые в панелях (листья дерева тайлинга).
  Set<EditorDocumentId> get visiblePaneIds =>
      state.layout.paneTree?.documentIds.toSet() ?? const {};

  /// Документы вне панелей — только в таб-баре (живы, но не на экране).
  List<EditorDocumentDescriptor> get backgroundDocuments {
    final visible = visiblePaneIds;
    return state.documents
        .where((document) => !visible.contains(document.id))
        .toList();
  }

  /// Разделить активную панель документом [targetId]: рядом ([horizontal])
  /// или снизу. Возвращает false, если сплит невозможен (нет активной
  /// панели, тот же документ или документ уже виден в другой панели).
  bool split(EditorDocumentId targetId, {bool horizontal = true}) {
    final active = state.activeId;
    if (active == null || targetId == active) return false;
    if (!contains(targetId)) return false;

    var tree = state.layout.paneTree;
    // Цель уже видна в другой панели — забираем её оттуда (старая панель
    // схлопывается) и ставим на новую позицию, чтобы не было дубликатов.
    if (tree != null && tree.documentIds.contains(targetId)) {
      final withoutTarget = _removeLeaf(tree, targetId);
      if (withoutTarget != null) tree = withoutTarget;
    }

    final EditorDockNode newTree;
    if (tree == null) {
      newTree = EditorDockSplit(
        horizontal: horizontal,
        ratio: 0.5,
        first: EditorDockLeaf(active),
        second: EditorDockLeaf(targetId),
      );
    } else {
      newTree = _splitLeaf(tree, active, targetId, horizontal: horizontal);
    }
    state = state.copyWith(
      activeId: targetId,
      layout: state.layout.copyWith(paneTree: newTree),
    );
    return true;
  }

  /// Закрыть панель с документом: документ остаётся открытым в таб-баре.
  void closePane(EditorDocumentId id) {
    final tree = state.layout.paneTree;
    if (tree == null) return;
    final updated = _removeLeaf(tree, id);
    if (updated == null || identical(updated, tree)) return;

    EditorDockNode? newTree = updated;
    if (newTree is EditorDockLeaf) {
      newTree = null; // одна панель → обычный режим
    }
    final visibleIds = newTree == null
        ? const <EditorDocumentId>[]
        : newTree.documentIds.toList();
    EditorDocumentId? nextActive = state.activeId;
    if (nextActive == id ||
        (newTree != null && !visibleIds.contains(nextActive))) {
      nextActive = visibleIds.isEmpty
          ? (state.documents.isEmpty ? null : state.documents.first.id)
          : visibleIds.first;
    }
    state = state.copyWith(
      activeId: nextActive,
      clearActive: nextActive == null,
      layout: state.layout.copyWith(
        paneTree: newTree,
        clearPaneTree: newTree == null,
      ),
    );
  }

  /// Перетаскивание вкладки на рабочее поле (Windows/GNOME-стайл): разметить
  /// [draggedId] рядом с панелью [paneId] — слева/сверху ([first]) или
  /// справа/снизу. Если вкладка уже видна в другой панели — забираем её
  /// оттуда (старая панель схлопывается), дубликатов не появляется.
  bool tileInto(
    EditorDocumentId draggedId,
    EditorDocumentId paneId, {
    required bool horizontal,
    required bool first,
  }) {
    if (draggedId == paneId) {
      focus(draggedId);
      return true;
    }
    if (!contains(draggedId) || !contains(paneId)) return false;

    var tree = state.layout.paneTree;
    if (tree != null && tree.documentIds.contains(draggedId)) {
      final without = _removeLeaf(tree, draggedId);
      if (without != null) tree = without;
    }
    final EditorDockNode newTree;
    if (tree == null) {
      newTree = EditorDockSplit(
        horizontal: horizontal,
        ratio: 0.5,
        first: EditorDockLeaf(first ? draggedId : paneId),
        second: EditorDockLeaf(first ? paneId : draggedId),
      );
    } else {
      newTree = _splitLeafAt(
        tree,
        paneId,
        draggedId,
        horizontal: horizontal,
        targetFirst: first,
      );
    }
    state = state.copyWith(
      activeId: draggedId,
      layout: state.layout.copyWith(paneTree: newTree),
    );
    return true;
  }

  /// Перетаскивание вкладки: переместить [draggedId] в панель [paneId]
  /// (замена содержимого панели; старый документ остаётся в таб-баре).
  bool moveToPane(EditorDocumentId draggedId, EditorDocumentId paneId) {
    if (draggedId == paneId) {
      focus(draggedId);
      return true;
    }
    if (!contains(draggedId) || !contains(paneId)) return false;

    var tree = state.layout.paneTree;
    if (tree != null && tree.documentIds.contains(draggedId)) {
      final without = _removeLeaf(tree, draggedId);
      if (without != null) tree = without;
    }
    final newTree = _swapLeaf(
      tree ?? EditorDockLeaf(paneId),
      paneId,
      draggedId,
    );
    state = state.copyWith(
      activeId: draggedId,
      layout: state.layout.copyWith(paneTree: newTree),
    );
    return true;
  }

  /// Схлопнуть все панели — одна панель на весь экран (обычные вкладки).
  void collapsePanes() {
    if (state.layout.paneTree == null) return;
    state = state.copyWith(
      layout: state.layout.copyWith(paneTree: null, clearPaneTree: true),
    );
  }

  /// Изменить долю первой панели сплита по пути от корня (список выборов
  /// first/second). [ratio] — 0..1.
  void setSplitRatio(List<bool> path, double ratio) {
    final tree = state.layout.paneTree;
    if (tree == null) return;
    state = state.copyWith(
      layout: state.layout.copyWith(
        paneTree: _updateSplitRatio(tree, path, ratio),
      ),
    );
  }

  /// Убрать лист закрытого документа из дерева панелей и схлопнуть сплиты.
  EditorWorkspaceState _withPrunedPaneTree(
    List<EditorDocumentDescriptor> remaining,
    EditorDocumentId? nextActive,
  ) {
    var tree = state.layout.paneTree;
    if (tree != null) {
      final valid = remaining.map((document) => document.id).toSet();
      tree = _pruneTreeTo(tree, valid);
      if (tree is EditorDockLeaf) tree = null;
      if (tree != null &&
          nextActive != null &&
          !tree.documentIds.contains(nextActive)) {
        nextActive = tree.documentIds.first;
      }
    }
    return state.copyWith(
      documents: List.unmodifiable(remaining),
      activeId: nextActive,
      clearActive: nextActive == null,
      layout: state.layout.copyWith(
        rootTabs: remaining.map((document) => document.id).toList(),
        paneTree: tree,
        clearPaneTree: tree == null,
      ),
    );
  }

  void _rememberClosed(EditorDocumentDescriptor document) {
    _recentlyClosed.removeWhere((d) => d.id == document.id);
    _recentlyClosed.insert(0, document);
    if (_recentlyClosed.length > recentlyClosedLimit) {
      _recentlyClosed.removeRange(recentlyClosedLimit, _recentlyClosed.length);
    }
  }

  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= state.documents.length) return;
    if (newIndex < 0 || newIndex > state.documents.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final documents = [...state.documents];
    final moved = documents.removeAt(oldIndex);
    documents.insert(newIndex, moved);
    state = state.copyWith(
      documents: documents,
      layout: state.layout.copyWith(
        rootTabs: documents.map((document) => document.id).toList(),
      ),
    );
  }

  /// Runtime hook for a future memory policy. MVP keeps every document alive.
  bool canEvict(EditorDocumentId id) => _runtimes[id]?.keepAlive != true;

  /// Сохраняет все документы. false — хотя бы одна запись не удалась:
  /// «Назад» в этом случае остаётся в воркспейсе, а не уводит из него.
  Future<bool> flushDirtyDocuments() async {
    var allSaved = true;
    for (final document in state.documents) {
      if (!await save(document.id)) allSaved = false;
    }
    return allSaved;
  }

  /// Сохраняет [id], только если документ помечен грязным. Нужен перед
  /// ЗАМЕНОЙ вкладки: в режиме без табов замена уничтожает экран вместе с
  /// отложенным автосейвом (дебаунс-таймер гаснет в dispose), и правки
  /// теряются — например, добавленный в ноду скрипт исчезает навсегда.
  Future<void> flushIfDirty(EditorDocumentId? id) async {
    if (id == null) return;
    for (final document in state.documents) {
      if (document.id != id) continue;
      if (document.isDirty) await save(id);
      return;
    }
  }

  String? _dirtySubtitle(String? subtitle) {
    if (subtitle == null || subtitle.isEmpty) return kDirtyDocumentMarker;
    return subtitle.endsWith(' •') ? subtitle : '$subtitle •';
  }

  String? _cleanSubtitle(String? subtitle) {
    if (subtitle == null || subtitle == kDirtyDocumentMarker) return null;
    final clean = subtitle.endsWith(' •')
        ? subtitle.substring(0, subtitle.length - 2)
        : subtitle;
    return clean.isEmpty ? null : clean;
  }
}

// ---------------------------------------------------------------------------
// Вспомогательные операции над деревом панелей (immutable-замены).
// ---------------------------------------------------------------------------

/// Ориентация для авто-тайлинга: чередуется с ориентацией родителя активного
/// листа (рядом → вниз и наоборот), чтобы панели складывались в сетку.
bool _autoSplitOrientation(EditorDockNode node, EditorDocumentId leafId) {
  return switch (node) {
    EditorDockLeaf() => true,
    EditorDockSplit(:final horizontal, :final first, :final second) => () {
      if (first.documentIds.contains(leafId)) {
        return !horizontal;
      }
      if (second.documentIds.contains(leafId)) {
        return !horizontal;
      }
      return true;
    }(),
  };
}

/// Заменить лист [from] на лист [to] (свап документа в панель).
EditorDockNode _swapLeaf(
  EditorDockNode node,
  EditorDocumentId from,
  EditorDocumentId to,
) {
  return switch (node) {
    EditorDockLeaf(:final documentId) =>
      documentId == from ? EditorDockLeaf(to) : node,
    EditorDockSplit(
      :final horizontal,
      :final ratio,
      :final first,
      :final second,
    ) =>
      EditorDockSplit(
        horizontal: horizontal,
        ratio: ratio,
        first: _swapLeaf(first, from, to),
        second: _swapLeaf(second, from, to),
      ),
  };
}

/// Разделить лист [anchor]: сплит [anchor | target].
EditorDockNode _splitLeaf(
  EditorDockNode node,
  EditorDocumentId anchor,
  EditorDocumentId target, {
  required bool horizontal,
}) => _splitLeafAt(
  node,
  anchor,
  target,
  horizontal: horizontal,
  targetFirst: false,
);

/// Разделить лист [anchor]: сплит [target | anchor] ([targetFirst]) или
/// [anchor | target]. Используется при перетаскивании вкладки на край панели.
EditorDockNode _splitLeafAt(
  EditorDockNode node,
  EditorDocumentId anchor,
  EditorDocumentId target, {
  required bool horizontal,
  required bool targetFirst,
}) {
  return switch (node) {
    EditorDockLeaf(:final documentId) =>
      documentId == anchor
          ? EditorDockSplit(
              horizontal: horizontal,
              ratio: 0.5,
              first: EditorDockLeaf(targetFirst ? target : anchor),
              second: EditorDockLeaf(targetFirst ? anchor : target),
            )
          : node,
    EditorDockSplit(
      :final horizontal,
      :final ratio,
      :final first,
      :final second,
    ) =>
      EditorDockSplit(
        horizontal: horizontal,
        ratio: ratio,
        first: _splitLeafAt(
          first,
          anchor,
          target,
          horizontal: horizontal,
          targetFirst: targetFirst,
        ),
        second: _splitLeafAt(
          second,
          anchor,
          target,
          horizontal: horizontal,
          targetFirst: targetFirst,
        ),
      ),
  };
}

/// Удалить лист [id]; сплит с одним выжившим ребёнком схлопывается.
EditorDockNode? _removeLeaf(EditorDockNode node, EditorDocumentId id) {
  return switch (node) {
    EditorDockLeaf(:final documentId) => documentId == id ? null : node,
    EditorDockSplit(
      :final horizontal,
      :final ratio,
      :final first,
      :final second,
    ) =>
      () {
        final f = _removeLeaf(first, id);
        final s = _removeLeaf(second, id);
        if (f == null) return s;
        if (s == null) return f;
        if (identical(f, first) && identical(s, second)) return node;
        return EditorDockSplit(
          horizontal: horizontal,
          ratio: ratio,
          first: f,
          second: s,
        );
      }(),
  };
}

/// Оставить только листья с документами из [valid]; сплиты схлопываются.
EditorDockNode? _pruneTreeTo(EditorDockNode node, Set<EditorDocumentId> valid) {
  return switch (node) {
    EditorDockLeaf(:final documentId) =>
      valid.contains(documentId) ? node : null,
    EditorDockSplit(
      :final horizontal,
      :final ratio,
      :final first,
      :final second,
    ) =>
      () {
        final f = _pruneTreeTo(first, valid);
        final s = _pruneTreeTo(second, valid);
        if (f == null) return s;
        if (s == null) return f;
        if (identical(f, first) && identical(s, second)) return node;
        return EditorDockSplit(
          horizontal: horizontal,
          ratio: ratio,
          first: f,
          second: s,
        );
      }(),
  };
}

/// Обновить ratio сплита по пути выбора детей (first/second) от корня.
/// Пустой путь — корневой сплит; каждый следующий элемент пути спускается
/// к первому (false) или второму (true) ребёнку.
EditorDockNode _updateSplitRatio(
  EditorDockNode node,
  List<bool> path,
  double ratio,
) {
  if (node is! EditorDockSplit) return node;
  if (path.isEmpty) {
    return EditorDockSplit(
      horizontal: node.horizontal,
      ratio: ratio.clamp(0.15, 0.85),
      first: node.first,
      second: node.second,
    );
  }
  final goFirst = path.first;
  final updated = _updateSplitRatio(
    goFirst ? node.first : node.second,
    path.sublist(1),
    ratio,
  );
  return EditorDockSplit(
    horizontal: node.horizontal,
    ratio: node.ratio,
    first: goFirst ? updated : node.first,
    second: goFirst ? node.second : updated,
  );
}
