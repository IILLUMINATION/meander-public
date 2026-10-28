import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/hang_watchdog.dart';

import 'editor_back_handler.dart';
import 'editor_document.dart';
import 'editor_document_launcher.dart';
import 'editor_tabs_bar.dart';
import 'editor_tabs_overview.dart';
import 'editor_workspace_controller.dart';
import 'editor_workspace_scope.dart';
import 'editor_workspace_session.dart';

class QuestEditorShell extends ConsumerStatefulWidget {
  final String questId;
  final EditorDocumentDescriptor? initialDocument;

  /// Подмена сборки документа. Нужна тестам навигации шелла: настоящие
  /// экраны тянут Rust-ядро и файлы квеста, а проверить «Назад» надо и без
  /// них. В приложении не передаётся.
  @visibleForTesting
  final Widget Function(EditorDocumentDescriptor document)? documentBuilder;

  const QuestEditorShell({
    super.key,
    required this.questId,
    this.initialDocument,
    this.documentBuilder,
  });

  @override
  ConsumerState<QuestEditorShell> createState() => _QuestEditorShellState();
}

class _QuestEditorShellState extends ConsumerState<QuestEditorShell>
    with WidgetsBindingObserver {
  late final Map<ShortcutActivator, VoidCallback> _shortcuts;
  /// Реестр back-обработчиков документов. Живёт в State, чтобы пересборки
  /// шелла не теряли регистрации вкладок.
  late final EditorBackHandlers _backHandlers = EditorBackHandlers();
  bool _tabsEnabled = true;
  bool _autoOpenTab = false;
  final Set<EditorDocumentId> _pinnedIds = {};
  /// Маршрут редактора уже снимают — повторный pop закрыл бы и экран под
  /// ним (см. [_popEditorRoute]).
  bool _routeExitRequested = false;
  Timer? _persistDebounce;
  final GlobalKey<_EditorDocumentSurfaceState> _surfaceKey =
      GlobalKey<_EditorDocumentSurfaceState>();
  EditorWorkspaceController get controller =>
      ref.read(editorWorkspaceControllerProvider(widget.questId).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shortcuts = {
      // Ctrl+T — новая вкладка.
      const SingleActivator(LogicalKeyboardKey.keyT, control: true):
          _openNewTabMenu,
      // Ctrl+W — закрыть активную вкладку.
      const SingleActivator(LogicalKeyboardKey.keyW, control: true):
          _closeActiveTab,
      // Ctrl+Shift+T — вернуть последнюю закрытую вкладку.
      const SingleActivator(
        LogicalKeyboardKey.keyT,
        control: true,
        shift: true,
      ): _reopenLastClosed,
      // Ctrl+Tab / Ctrl+Shift+Tab — цикл по вкладкам.
      const SingleActivator(LogicalKeyboardKey.tab, control: true):
          _cycleTabsForward,
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
          _cycleTabsBackward,
      // Ctrl+1..9 — прыжок к вкладке по номеру.
      for (var index = 0; index < 9; index++)
        SingleActivator(
          LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + index),
          control: true,
        ): () =>
            _focusTabIndex(index),
    };
    _loadEditorSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_restoreSession());
    });
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(controller.flushDirtyDocuments());
    }
  }

  Future<void> _loadEditorSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _tabsEnabled = prefs.getBool('editor_tabs_enabled') ?? true;
        _autoOpenTab = prefs.getBool('editor_auto_open_tab') ?? false;
      });
    }
  }

  Future<void> _restoreSession() async {
    HangWatchdog.mark('restore session: load');
    final restored = await ref
        .read(editorWorkspaceSessionStoreProvider)
        .load(widget.questId);
    if (!mounted) return;
    HangWatchdog.mark('restore session: loaded');
    // Загружаем настройки синхронно до принятия решения — иначе гонка
    // с _loadEditorSettings() перетрёт настройку и плодит вкладки.
    try {
      final prefs = await SharedPreferences.getInstance();
      final tabsEnabled = prefs.getBool('editor_tabs_enabled') ?? true;
      final autoOpen = prefs.getBool('editor_auto_open_tab') ?? false;
      if (mounted) {
        setState(() {
          _tabsEnabled = tabsEnabled;
          _autoOpenTab = autoOpen;
        });
      } else {
        _tabsEnabled = tabsEnabled;
        _autoOpenTab = autoOpen;
      }
    } catch (_) {}
    final current = ref.read(editorWorkspaceControllerProvider(widget.questId));
    if (current.documents.isEmpty && restored != null) {
      controller.restore(restored);
    }
    HangWatchdog.mark('restore session: restored');
    final docs = ref
        .read(editorWorkspaceControllerProvider(widget.questId));
    if (docs.documents.isEmpty) {
      await _open(
        widget.initialDocument ??
            EditorDocumentDescriptor.chapters(widget.questId),
      );
    } else if (widget.initialDocument != null) {
      // Точка входа этой сессии становится единственной записью стека
      // «Назад». Уважаем _autoOpenTab и _tabsEnabled через _open(),
      // чтобы отключённое авто-открытие не плодило вкладки.
      await _open(widget.initialDocument!);
    }
    await _persistSession();
  }

  Future<void> _persistSession() =>
      ref.read(editorWorkspaceSessionStoreProvider).save(
        widget.questId,
        ref.read(editorWorkspaceControllerProvider(widget.questId)),
      );

  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(_persistSession());
    });
  }

  Future<void> _open(EditorDocumentDescriptor descriptor) async {
    // Уже открыта — просто фокус (не зависит от настроек, защита от дублей).
    if (controller.contains(descriptor.id)) {
      _focus(descriptor.id);
      return;
    }
    if (!_tabsEnabled) {
      // Tabs disabled: always replace current document (no tab bar to switch)
      // Закрепление при отключённых вкладках тоже учитываем — если текущая
      // закреплена, не заменяем а открываем новую (таб-бар появится).
      final currentId = controller.activeId;
      if (currentId != null) {
        if (_pinnedIds.contains(currentId)) {
          _captureLeaving(controller.activeId);
          controller.open(descriptor);
          _schedulePersist();
          return;
        }
        await controller.flushIfDirty(currentId);
        controller.replace(currentId, descriptor);
        _schedulePersist();
        return;
      }
    }
    if (!_autoOpenTab) {
      // Авто-открытие выключено — не плодим вкладки, заменяем текущую,
      // но закреплённая вкладка защищена от замены.
      final currentId = controller.activeId;
      if (currentId != null) {
        if (_pinnedIds.contains(currentId)) {
          _captureLeaving(controller.activeId);
          controller.open(descriptor);
          _schedulePersist();
          return;
        }
        await controller.flushIfDirty(currentId);
        controller.replace(currentId, descriptor);
        _schedulePersist();
        return;
      }
    }
    _captureLeaving(controller.activeId);
    controller.open(descriptor);
    _schedulePersist();
  }

  /// Принудительно открывает документ в новой вкладке, игнорируя
  /// _tabsEnabled/_autoOpenTab. Используется кнопкой "Открыть в новой вкладке".
  void _openForcedAsNewTab(EditorDocumentDescriptor descriptor) {
    if (controller.contains(descriptor.id)) {
      _focus(descriptor.id);
      return;
    }
    _captureLeaving(controller.activeId);
    controller.open(descriptor);
    _schedulePersist();
  }

  bool _isPinned(EditorDocumentId id) => _pinnedIds.contains(id);

  void _togglePin(EditorDocumentId id) {
    setState(() {
      if (_pinnedIds.contains(id)) {
        _pinnedIds.remove(id);
      } else {
        _pinnedIds.add(id);
      }
    });
  }

  void _focus(EditorDocumentId id) {
    // capturePreview убран с hot path — только для обзора вкладок.
    // Раньше каждый свитч делал boundary.toImage (GPU readback) и лагал.
    controller.focus(id);
    _schedulePersist();
  }

  /// Снимает превью уходящей вкладки, если она сейчас видима.
  /// Теперь no-op на hot path, превью снимается только в _openTabsOverview.
  void _captureLeaving(EditorDocumentId? leaving) {
    // intentionally no-op for perf; keep method for compatibility
  }

  /// Живые id документов — для чистки кэша превью после закрытий.
  Set<EditorDocumentId> _liveIds() => ref
      .read(editorWorkspaceControllerProvider(widget.questId))
      .documents
      .map((d) => d.id)
      .toSet();

  Future<void> _replace(
    EditorDocumentId oldId,
    EditorDocumentDescriptor descriptor,
  ) async {
    // Та же причина, что и в _open: замена убивает экран вместе с
    // несброшенным дебаунс-автосейвом.
    await controller.flushIfDirty(oldId);
    final wasPinned = _pinnedIds.remove(oldId);
    if (wasPinned) _pinnedIds.add(descriptor.id);
    controller.replace(oldId, descriptor);
    _surfaceKey.currentState?.prunePreviews(_liveIds());
    _schedulePersist();
  }

  Future<void> _closeOthers(EditorDocumentId keepId) async {
    _pinnedIds.removeWhere((id) => id != keepId);
    await controller.closeOthers(keepId);
    _surfaceKey.currentState?.prunePreviews(_liveIds());
    await _persistSession();
  }

  Future<void> _closeRight(EditorDocumentId anchorId) async {
    // Удаляем пины справа от якоря
    final docs = ref.read(editorWorkspaceControllerProvider(widget.questId)).documents;
    final idx = docs.indexWhere((d) => d.id == anchorId);
    if (idx >= 0) {
      final toRemove = docs.skip(idx + 1).map((d) => d.id).toSet();
      _pinnedIds.removeAll(toRemove);
    }
    await controller.closeRight(anchorId);
    _surfaceKey.currentState?.prunePreviews(_liveIds());
    await _persistSession();
  }

  Future<void> _closeAll() async {
    _pinnedIds.clear();
    await controller.closeAll();
    _surfaceKey.currentState?.prunePreviews(_liveIds());
    await _persistSession();
  }

  void _splitRight(EditorDocumentId id) {
    final ok = controller.split(id, horizontal: true);
    if (ok) {
      _schedulePersist();
    } else {
      _showSplitUnavailable();
    }
  }

  void _splitDown(EditorDocumentId id) {
    final ok = controller.split(id, horizontal: false);
    if (ok) {
      _schedulePersist();
    } else {
      _showSplitUnavailable();
    }
  }

  void _showSplitUnavailable() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr('Эта вкладка и так в активной панели — выберите другую вкладку'),
        ),
      ),
    );
  }

  void _collapsePanes() {
    controller.collapsePanes();
    _schedulePersist();
  }

  void _resizeSplit(List<bool> path, double ratio) {
    controller.setSplitRatio(path, ratio);
    _schedulePersist();
  }

  void _closePane(EditorDocumentId id) {
    controller.closePane(id);
    _schedulePersist();
  }

  void _closeActiveTab() {
    final activeId = controller.activeId;
    if (activeId != null) unawaited(_close(activeId));
  }

  void _reopenLastClosed() {
    controller.reopenLastClosed();
    _schedulePersist();
  }

  void _cycleTabsForward() => _cycleTabs(1);

  void _cycleTabsBackward() => _cycleTabs(-1);

  List<EditorDocumentDescriptor> get _documents =>
      ref.read(editorWorkspaceControllerProvider(widget.questId)).documents;

  void _cycleTabs(int delta) {
    final documents = _documents;
    if (documents.length < 2) return;
    final activeId = controller.activeId;
    final current = documents.indexWhere((d) => d.id == activeId);
    final next = (current < 0 ? 0 : current + delta) % documents.length;
    final target = documents[next < 0 ? documents.length - 1 : next];
    _focus(target.id);
  }

  void _focusTabIndex(int index) {
    final documents = _documents;
    if (index < 0 || index >= documents.length) return;
    _focus(documents[index].id);
  }

  /// Конвертирует EditorWorkspaceState → List<EditorTabData>.
  List<EditorTabData> _buildTabData(EditorWorkspaceState state) {
    final scheme = Theme.of(context).colorScheme;
    // Последний рубеж против duplicate keys: даже если дубликат где-то
    // просочился мимо инвариантов, в дерево виджетов он не попадёт.
    final seen = <String>{};
    final tabs = <EditorTabData>[];
    for (final doc in state.documents) {
      final key = doc.id.persistenceKey;
      if (!seen.add(key)) continue;
      tabs.add(
        EditorTabData(
          id: key,
          title: doc.title,
          subtitle: doc.displaySubtitle,
          icon: doc.icon,
          accentColor: _accentFor(doc.id.kind, scheme),
          isDirty: doc.isDirty,
          isPinned: _pinnedIds.contains(doc.id),
        ),
      );
    }
    return tabs;
  }

  /// Конвертирует persistenceKey обратно в EditorDocumentId.
  EditorDocumentId? _docIdFromKey(String key) {
    for (final doc in ref.read(editorWorkspaceControllerProvider(widget.questId)).documents) {
      if (doc.id.persistenceKey == key) return doc.id;
    }
    return null;
  }

  /// Цвет-акцент для типа документа.
  Color? _accentFor(EditorDocumentKind kind, ColorScheme scheme) {
    return switch (kind) {
      EditorDocumentKind.canvas => scheme.tertiary,
      EditorDocumentKind.visualScript => scheme.secondary,
      EditorDocumentKind.lua => scheme.secondary,
      EditorDocumentKind.resources => scheme.tertiary,
      _ => null,
    };
  }

  /// Гайды всегда под рукой: не нужно уходить в настройки и обратно.
  void _openGuides() {
    unawaited(_open(EditorDocumentDescriptor.guidesCatalog(widget.questId)));
  }

  void _openNewTabMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Дно шита — под зоной жеста iPhone: Material без `useSafeArea` нижний
      // отступ не добавляет (см. `_showBottomSheet` в adaptive_ui.dart).
      builder: (sheetContext) => SafeArea(
        top: false,
        child: _NewTabSheet(
          questId: widget.questId,
          onOpen: (descriptor) {
            Navigator.of(sheetContext).pop();
            // Явное действие пользователя «Новая вкладка» — всегда принудительно.
            _openForcedAsNewTab(descriptor);
          },
        ),
      ),
    );
  }

  /// Полноэкранный обзор открытых вкладок: поиск, переход, закрытие.
  void _openTabsOverview() async {
    // У активной вкладки превью может ещё не быть (с неё не уходили) —
    // снимаем кадр до открытия обзора.
    final activeId = controller.activeId;
    if (activeId != null) {
      await _surfaceKey.currentState?.capturePreview(activeId);
    }
    if (!mounted) return;
    final state = ref.read(editorWorkspaceControllerProvider(widget.questId));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditorTabsOverview(
          documents: state.documents,
          activeId: state.activeId,
          // Временное превью: кадр при уходе с вкладки; чего нет — иконка.
          previews: Map.of(_surfaceKey.currentState?.previews ?? const {}),
          onFocus: _focus,
          onClose: (id) => _close(id).then((_) {}),
          onCloseAll: () async {
            await _closeAll();
          },
        ),
      ),
    );
  }

  Future<bool> _close(EditorDocumentId id) async {
    _pinnedIds.remove(id);
    final result = await controller.close(id);
    _surfaceKey.currentState?.prunePreviews(_liveIds());
    if (result) {
      await _persistSession();
      await _exitWhenEmpty();
    }
    return result;
  }

  /// Если после закрытия вкладок не осталось — закрываем маршрут редактора,
  /// чтобы пользователь не увидел пустой экран шелла.
  Future<void> _exitWhenEmpty() async {
    if (!mounted) return;
    if (ref.read(editorWorkspaceControllerProvider(widget.questId))
        .documents
        .isNotEmpty) {
      return;
    }
    _popEditorRoute();
  }

  /// Выход из маршрута редактора — ровно один pop за нажатие «Назад».
  ///
  /// Без флага второй pop случался двумя способами: закрытие последней
  /// вкладки уже снимало маршрут, а «Назад» снимал и экран под ним
  /// («кидает на 2 экрана назад»), и быстрый двойной тап по системной
  /// кнопке делал то же самое.
  void _popEditorRoute() {
    if (_routeExitRequested || !mounted) return;
    final nav = Navigator.of(context);
    if (!nav.canPop()) return;
    _routeExitRequested = true;
    nav.pop();
  }

  Future<void> _exitToQuestMenu() async {
    // Автосохранение грязных документов, вкладки остаются — сессия
    // восстановится при следующем входе. Диалог не показываем.
    try {
      await controller.flushDirtyDocuments();
    } catch (_) {}
    await _persistSession();
    _popEditorRoute();
  }

  /// Единая точка «Назад» на маршруте редактора.
  ///
  /// 1. Пустой воркспейс → выход.
  /// 2. Браузерная история: возврат к предыдущей посещённой вкладке,
  ///    текущая остаётся открытой.
  /// 3. История исчерпана, вкладок несколько → закрываем активную (документ
  ///    сам решает, что сохранить, и может отказать) и остаёмся в
  ///    воркспейсе: «Назад» не должен выкидывать из рабочего поля, пока
  ///    там есть над чем работать.
  /// 4. История исчерпана и вкладка одна → сохраняем и выходим из
  ///    редактора, НЕ закрывая вкладку: сессия восстановит её при следующем
  ///    входе, а закрытие последней вкладки уже снимало бы маршрут и
  ///    «Назад» снял бы ещё и экран под ним.
  Future<void> _handleWorkspaceBack() async {
    final state = ref.read(editorWorkspaceControllerProvider(widget.questId));
    if (state.documents.isEmpty) {
      _popEditorRoute();
      return;
    }
    final backTarget = controller.popBackTarget();
    if (backTarget != null) {
      await _open(backTarget);
      return;
    }

    final activeId = state.activeId ?? state.documents.last.id;

    if (state.documents.length > 1) {
      final handler = _backHandlers.handlerFor(activeId);
      if (handler == null) {
        // Документ «Назад» не перехватывает (Ресурсы) — вкладку закрывает
        // шелл; runtime-вето в controller.close остаётся в силе.
        await _close(activeId);
        return;
      }
      await handler();
      if (!mounted) return;
      // Veto: документ не закрылся (остались в диалоге несохранённых
      // изменений) — ничего не делаем.
      final after = ref.read(editorWorkspaceControllerProvider(widget.questId));
      final closed = !after.documents.any((d) => d.id == activeId);
      if (closed) _schedulePersist();
      return;
    }

    final saved = await controller.flushDirtyDocuments();
    if (!mounted || !saved) return;
    _popEditorRoute();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(editorWorkspaceControllerProvider(widget.questId));
    final scope = EditorWorkspaceScope(
      openDocument: _open,
      openForcedAsNewTab: _openForcedAsNewTab,
      showNewTabSheet: _openNewTabMenu,
      togglePin: _togglePin,
      isPinned: _isPinned,
      focusDocument: _focus,
      closeDocument: _close,
      replaceDocument: _replace,
      registerRuntime: controller.registerRuntime,
      unregisterRuntime: controller.unregisterRuntime,
      markDirty: controller.markDirty,
      requestBack: _handleWorkspaceBack,
      child: PopScope(
        canPop: state.documents.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          unawaited(_handleWorkspaceBack());
        },
        child: EditorBackRegistry(
          holder: _backHandlers,
          child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: CallbackShortcuts(
          bindings: _shortcuts,
          child: Focus(
            autofocus: true,
            child: Column(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < constraints.maxHeight;
                    if (!_tabsEnabled) return const SizedBox.shrink();
                  return EditorTabsBar(
                      tabs: _buildTabData(state),
                      activeTabId: state.activeId?.persistenceKey,
                      onSelect: (id) {
                        final docId = _docIdFromKey(id);
                        if (docId != null) _focus(docId);
                      },
                      onClose: (id) async {
                        final docId = _docIdFromKey(id);
                        if (docId != null) await _close(docId);
                      },
                      onNewTab: _openNewTabMenu,
                      onGuides: _openGuides,
                      onExitToMenu: _exitToQuestMenu,
                      onShowOverview: _openTabsOverview,
                      onTogglePin: state.activeId == null ? null : () => _togglePin(state.activeId!),
                      isPinnedActive: state.activeId != null && _pinnedIds.contains(state.activeId),
                      onCollapsePanes: compact ? null : _collapsePanes,
                      onContextAction: (tabId, action) {
                        final docId = _docIdFromKey(tabId);
                        if (docId == null) return;
                        switch (action) {
                          case TabContextAction.close:
                            _close(docId);
                          case TabContextAction.closeOthers:
                            _closeOthers(docId);
                          case TabContextAction.closeToRight:
                            _closeRight(docId);
                          case TabContextAction.closeAll:
                            _closeAll();
                          case TabContextAction.splitRight:
                            if (!compact) _splitRight(docId);
                          case TabContextAction.splitDown:
                            if (!compact) _splitDown(docId);
                          case TabContextAction.pinAsNewTab:
                            _openNewTabMenu();
                          case TabContextAction.togglePin:
                            _togglePin(docId);
                          }
                      },
                    );
                  },
                ),
                Expanded(
                  child: _EditorDocumentSurface(
                    key: _surfaceKey,
                    workspace: state,
                    questId: widget.questId,
                    documentBuilder:
                        widget.documentBuilder ??
                        EditorDocumentLauncher.buildDocument,
                    onFocusDocument: _focus,
                    onClosePane: _closePane,
                    onResizeSplit: _resizeSplit,
                  ),
                ),
              ],
            ),
          ),
        ),
          ),
        ),
      ),
    );
    return scope;
  }
}

class _EditorDocumentSurface extends StatefulWidget {
  final EditorWorkspaceState workspace;
  final String questId;
  final Widget Function(EditorDocumentDescriptor document) documentBuilder;
  final ValueChanged<EditorDocumentId> onFocusDocument;
  final ValueChanged<EditorDocumentId> onClosePane;
  final void Function(List<bool> path, double ratio) onResizeSplit;

  const _EditorDocumentSurface({
    super.key,
    required this.workspace,
    required this.questId,
    required this.documentBuilder,
    required this.onFocusDocument,
    required this.onClosePane,
    required this.onResizeSplit,
  });

  @override
  State<_EditorDocumentSurface> createState() => _EditorDocumentSurfaceState();
}

class _EditorDocumentSurfaceState extends State<_EditorDocumentSurface> {
  static const int _kMaxKeptTabs = 5;
  final Map<EditorDocumentId, int> _lastUsed = {};
  int _tick = 0;

  /// Ключи границ документов для захвата превью + кэш самих превью.
  /// Живут здесь же, где строятся RepaintBoundary. Временное превью:
  /// ui.Image в памяти, удаляется через dispose() при закрытии вкладки.
  final Map<EditorDocumentId, GlobalKey> _boundaryKeys = {};
  final Map<EditorDocumentId, ui.Image> previews = {};

  @override
  void initState() {
    super.initState();
    // Сидим стартовые документы как недавно использованные
    for (final doc in widget.workspace.documents) {
      _lastUsed[doc.id] = ++_tick;
    }
    if (widget.workspace.activeId != null) {
      _lastUsed[widget.workspace.activeId!] = ++_tick;
    }
  }

  GlobalKey _keyFor(EditorDocumentId id) =>
      _boundaryKeys.putIfAbsent(id, () => GlobalKey());

  /// Снимает миниатюру документа. Для обзора достаточно 360px,
  /// полный 680px жрал GPU и лагал на каждом свитче.
  Future<void> capturePreview(EditorDocumentId id) async {
    final context = _boundaryKeys[id]?.currentContext;
    if (context == null) return;
    final boundary = boundaryFor(context);
    if (boundary == null) return;
    try {
      final width = boundary.size.width;
      final ratio = width <= 0 ? 1.0 : (360 / width).clamp(0.3, 1.0);
      final image = await boundary.toImage(pixelRatio: ratio);
      if (!mounted) {
        image.dispose();
        return;
      }
      previews[id]?.dispose();
      previews[id] = image;
    } catch (_) {
      // Пустой/чёрный кадр (видео, платформенные вью) — оставляем иконку.
    }
  }

  static RenderRepaintBoundary? boundaryFor(BuildContext context) =>
      context.findRenderObject() as RenderRepaintBoundary?;

  /// Чистит превью (с dispose нативной памяти) для закрытых вкладок.
  void prunePreviews(Set<EditorDocumentId> liveIds) {
    for (final id in previews.keys
        .where((id) => !liveIds.contains(id))
        .toList()) {
      previews.remove(id)?.dispose();
    }
    _boundaryKeys.removeWhere((id, _) => !liveIds.contains(id));
  }

  @override
  void dispose() {
    for (final image in previews.values) {
      image.dispose();
    }
    previews.clear();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _EditorDocumentSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ws = widget.workspace;
    final oldWs = oldWidget.workspace;
    if (ws.activeId != oldWs.activeId && ws.activeId != null) {
      _lastUsed[ws.activeId!] = ++_tick;
    }
    final visible = ws.layout.paneTree?.documentIds.toSet() ?? const <EditorDocumentId>{};
    final oldVisible = oldWs.layout.paneTree?.documentIds.toSet() ?? const <EditorDocumentId>{};
    if (visible.length != oldVisible.length || !visible.containsAll(oldVisible)) {
      for (final id in visible) {
        _lastUsed[id] = ++_tick;
      }
    }
    // Чистим протухшие записи, чтобы sorted не рос бесконечно.
    _lastUsed.removeWhere((id, _) => !ws.documents.any((d) => d.id == id));
    _boundaryKeys.removeWhere((id, _) => !ws.documents.any((d) => d.id == id));
    // превью чистим только по liveIds в prunePreviews, но и здесь подчищаем ключи
  }

  Set<EditorDocumentId> _keepSet(EditorWorkspaceState ws) {
    if (ws.documents.length <= _kMaxKeptTabs) {
      return ws.documents.map((d) => d.id).toSet();
    }
    final active = ws.activeId;
    final visible = ws.layout.paneTree?.documentIds.toSet() ?? const <EditorDocumentId>{};
    // Include active + visible first (без мутации _lastUsed — она в didUpdateWidget)
    final keep = <EditorDocumentId>{};
    if (active != null) keep.add(active);
    keep.addAll(visible);
    // Most recent by tick
    final sorted = _lastUsed.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      if (keep.length >= _kMaxKeptTabs) break;
      if (ws.documents.any((d) => d.id == e.key)) keep.add(e.key);
    }
    if (keep.length < _kMaxKeptTabs) {
      for (final d in ws.documents.reversed) {
        if (keep.length >= _kMaxKeptTabs) break;
        keep.add(d.id);
      }
    }
    keep.retainWhere((id) => ws.documents.any((d) => d.id == id));
    return keep;
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    if (workspace.documents.isEmpty) {
      // Пусто может быть легитимно, пока документ вынесен в подокно:
      // показываем заглушку вместо пустой («синей») поверхности.
      return const _EmptyWorkspacePlaceholder();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final surfaceRect = Offset.zero & size;
        final tree = workspace.layout.paneTree;
        final layout = tree == null
            ? _singlePaneLayout(workspace, surfaceRect)
            : _computePaneLayout(tree, surfaceRect);
        final paneWidgets = _buildPaneWidgets(workspace, layout, surfaceRect);

        return Stack(
          fit: StackFit.expand,
          children: paneWidgets,
        );
      },
    );
  }

  /// Обычный режим: одна панель на весь экран (активный документ).
  _PaneLayoutResult _singlePaneLayout(
    EditorWorkspaceState workspace,
    Rect surfaceRect,
  ) {
    final activeId = workspace.activeId ?? workspace.documents.first.id;
    return _PaneLayoutResult(
      rects: {activeId: surfaceRect},
      dividers: const [],
    );
  }

  List<Widget> _buildPaneWidgets(
    EditorWorkspaceState workspace,
    _PaneLayoutResult layout,
    Rect surfaceRect,
  ) {
    // Последний рубеж: дубликат id в документах = duplicate ValueKey в
    // дереве. Инварианты выше должны это исключать, здесь — страховка.
    final seenDocs = <EditorDocumentId>{};
    final documents = workspace.documents
        .where((d) => seenDocs.add(d.id))
        .toList();
    if (workspace.layout.paneTree == null) {
      // Держим только 5 последних вкладок смонтированными (LRU), вместо
      // IndexedStack со всеми N. Невидимые за пределами кэша размонтируются
      // и пересоздадутся при фокусе — экономит память/GPU-слои при 20+ вкладках.
      final keep = _keepSet(workspace);
      final keptDocs = documents.where((d) => keep.contains(d.id)).toList();
      final effectiveDocs = keptDocs.any((d) => d.id == workspace.activeId)
          ? keptDocs
          : (() {
              final withActive = [...keptDocs];
              final activeDoc = documents.firstWhere(
                (d) => d.id == workspace.activeId,
                orElse: () => keptDocs.first,
              );
              if (!withActive.any((d) => d.id == activeDoc.id)) {
                withActive[withActive.length - 1] = activeDoc;
              }
              return withActive;
            })();
      final children = [
        for (final document in effectiveDocs)
          TickerMode(
            enabled: document.id == workspace.activeId,
            child: EditorDocumentContext(
              id: document.id,
              isActive: document.id == workspace.activeId,
              child: KeyedSubtree(
                key: ValueKey(document.id),
                child: RepaintBoundary(
                  key: _keyFor(document.id),
                  child: widget.documentBuilder(document),
                ),
              ),
            ),
          ),
      ];
      // Защита от рассинхрона index/children: активный документ обязан
      // быть в списке, иначе IndexedStack падает по ассерту
      // (stack.dart _childAtIndex: index за пределами детей).
      final activeIndex = effectiveDocs.indexWhere(
        (document) => document.id == workspace.activeId,
      );
      return [
        Positioned.fromRect(
          rect: surfaceRect,
          child: IndexedStack(
            index: activeIndex < 0 ? 0 : activeIndex,
            children: children,
          ),
        ),
      ];
    }

    // Тайлинг: видимые панели + LRU-кэш фоновых (max 5), остальные
    // размонтируются. Раньше все оставались смонтированными.
    final keep = _keepSet(workspace);
    final visibleIds = layout.rects.keys.toSet();
    final docsToBuild = documents.where((d) => keep.contains(d.id) || visibleIds.contains(d.id)).toList();
    return [
      for (final document in docsToBuild)
        KeyedSubtree(
          key: ValueKey(document.id),
          child: Positioned.fromRect(
            rect: layout.rects[document.id] ?? surfaceRect,
            child: Visibility(
              visible: layout.rects.containsKey(document.id),
              maintainState: keep.contains(document.id),
              child: _wrapPaneDocument(
                document,
                visible: layout.rects.containsKey(document.id),
                active: document.id == workspace.activeId,
              ),
            ),
          ),
        ),
      for (final divider in layout.dividers)
        Positioned.fromRect(
          rect: divider.rect,
          child: _PaneDivider(
            vertical: divider.vertical,
            parentSize: divider.parentSize,
            currentRatio: divider.currentRatio,
            onResize: (ratio) => widget.onResizeSplit(divider.path, ratio),
          ),
        ),
    ];
  }

  /// Документ в режиме панелей: с шапкой (фокус/закрытие) или фоновый
  /// (шапка схлопывается, но документ остаётся в дереве — состояние живо).
  Widget _wrapPaneDocument(
    EditorDocumentDescriptor document, {
    required bool visible,
    required bool active,
  }) {
    final id = document.id;
    return TickerMode(
      enabled: visible,
      child: EditorDocumentContext(
        id: id,
        isActive: active,
        child: RepaintBoundary(
          key: _keyFor(id),
          child: _PaneFrame(
            document: document,
            visible: visible,
            active: active,
            onFocus: () => widget.onFocusDocument(id),
            onClosePane: () => widget.onClosePane(id),
            child: widget.documentBuilder(document),
          ),
        ),
      ),
    );
  }
}

/// Заглушка пустого рабочего поля. Возникает, когда все вкладки вынесены
/// в подокна либо воркспейс временно опустел.
class _EmptyWorkspacePlaceholder extends StatelessWidget {
  const _EmptyWorkspacePlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.web_asset_off_rounded,
              size: 42,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              tr('Открытых вкладок нет'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Каркас панели: шапка (иконка, заголовок, закрыть) + документ. Фоновая
/// вкладка рендерится тем же каркасом без шапки — документ не размонтируется
/// при переключении видимости.
class _PaneFrame extends StatelessWidget {
  final EditorDocumentDescriptor document;
  final bool visible;
  final bool active;
  final VoidCallback onFocus;
  final VoidCallback onClosePane;
  final Widget child;

  const _PaneFrame({
    required this.document,
    required this.visible,
    required this.active,
    required this.onFocus,
    required this.onClosePane,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) {
        if (focused) onFocus();
      },
      child: Column(
        children: [
          if (visible)
            _PaneHeader(
              document: document,
              active: active,
              onFocus: onFocus,
              onClosePane: onClosePane,
            )
          else
            const SizedBox.shrink(),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _PaneHeader extends StatelessWidget {
  final EditorDocumentDescriptor document;
  final bool active;
  final VoidCallback onFocus;
  final VoidCallback onClosePane;

  const _PaneHeader({
    required this.document,
    required this.active,
    required this.onFocus,
    required this.onClosePane,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onFocus,
      child: Container(
        height: 32,
        padding: const EdgeInsets.only(left: 10, right: 2),
        decoration: BoxDecoration(
          color: active
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerHigh.withValues(alpha: 0.6),
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              document.icon,
              size: 15,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                document.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: active ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
            Tooltip(
              message: tr('Закрыть панель (вкладка останется в таб-баре)'),
              child: IconButton(
                onPressed: onClosePane,
                icon: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Разделитель между панелями: drag изменяет долю сплита (ratio).
class _PaneDivider extends StatelessWidget {
  final bool vertical;
  final double parentSize;
  final double currentRatio;
  final ValueChanged<double> onResize;

  const _PaneDivider({
    required this.vertical,
    required this.parentSize,
    required this.currentRatio,
    required this.onResize,
  });

  void _apply(double delta) {
    if (parentSize <= 0) return;
    onResize((currentRatio + delta / parentSize).clamp(0.15, 0.85));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: vertical
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: vertical ? (d) => _apply(d.delta.dx) : null,
        onVerticalDragUpdate: vertical ? null : (d) => _apply(d.delta.dy),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}

/// Результат раскладки панелей: rect каждого видимого документа и спектры
/// разделителей (с путём от корня для обновления ratio).
class _PaneLayoutResult {
  final Map<EditorDocumentId, Rect> rects;
  final List<_PaneDividerSpec> dividers;

  const _PaneLayoutResult({required this.rects, required this.dividers});
}

class _PaneDividerSpec {
  final List<bool> path;
  final Rect rect;
  final bool vertical;
  final double parentSize;
  final double currentRatio;

  const _PaneDividerSpec({
    required this.path,
    required this.rect,
    required this.vertical,
    required this.parentSize,
    required this.currentRatio,
  });
}

const double _kPaneDividerThickness = 5;

_PaneLayoutResult _computePaneLayout(EditorDockNode node, Rect area) {
  final rects = <EditorDocumentId, Rect>{};
  final dividers = <_PaneDividerSpec>[];

  void walk(EditorDockNode n, Rect r, List<bool> path) {
    switch (n) {
      case EditorDockLeaf(:final documentId):
        rects[documentId] = r;
      case EditorDockSplit(
        :final horizontal,
        :final ratio,
        :final first,
        :final second,
      ):
        final total = horizontal ? r.width : r.height;
        if (total > _kPaneDividerThickness) {
          final firstSize =
              (total - _kPaneDividerThickness) * ratio.clamp(0.0, 1.0);
          final secondSize = total - _kPaneDividerThickness - firstSize;
          final Rect firstRect;
          final Rect secondRect;
          final Rect dividerRect;
          if (horizontal) {
            firstRect = Rect.fromLTWH(r.left, r.top, firstSize, r.height);
            dividerRect = Rect.fromLTWH(
              r.left + firstSize,
              r.top,
              _kPaneDividerThickness,
              r.height,
            );
            secondRect = Rect.fromLTWH(
              r.left + firstSize + _kPaneDividerThickness,
              r.top,
              secondSize,
              r.height,
            );
          } else {
            firstRect = Rect.fromLTWH(r.left, r.top, r.width, firstSize);
            dividerRect = Rect.fromLTWH(
              r.left,
              r.top + firstSize,
              r.width,
              _kPaneDividerThickness,
            );
            secondRect = Rect.fromLTWH(
              r.left,
              r.top + firstSize + _kPaneDividerThickness,
              r.width,
              secondSize,
            );
          }
          dividers.add(
            _PaneDividerSpec(
              path: path,
              rect: dividerRect,
              vertical: horizontal,
              parentSize: total,
              currentRatio: ratio,
            ),
          );
          walk(first, firstRect, [...path, false]);
          walk(second, secondRect, [...path, true]);
        } else {
          // Слишком мало места — показываем только первую панель.
          walk(first, r, [...path, false]);
        }
    }
  }

  walk(node, area, const []);
  return _PaneLayoutResult(rects: rects, dividers: dividers);
}

/// Меню «Новая вкладка»: все документы квеста без параметров, которые можно
/// открыть сразу. Canvas/ноды открываются контекстно из этих экранов.
class _NewTabSheet extends StatelessWidget {
  final String questId;
  final ValueChanged<EditorDocumentDescriptor> onOpen;

  const _NewTabSheet({required this.questId, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = <(IconData, String, String, EditorDocumentDescriptor)>[
      (
        EditorDocumentKind.chapters.icon,
        EditorDocumentKind.chapters.label,
        tr('Список глав и нод квеста'),
        EditorDocumentDescriptor.chapters(questId),
      ),
      (
        EditorDocumentKind.resources.icon,
        EditorDocumentKind.resources.label,
        tr('Картинки, аудио, Lua-скрипты'),
        EditorDocumentDescriptor.resources(questId),
      ),
      (
        EditorDocumentKind.templates.icon,
        EditorDocumentKind.templates.label,
        tr('Шаблоны контента'),
        EditorDocumentDescriptor.templates(questId),
      ),
      (
        EditorDocumentKind.questSettings.icon,
        EditorDocumentKind.questSettings.label,
        tr('Настройки квеста'),
        EditorDocumentDescriptor.questSettings(questId),
      ),
      (
        EditorDocumentKind.game.icon,
        EditorDocumentKind.game.label,
        tr('Тестовый запуск квеста'),
        EditorDocumentDescriptor.gameSimulation(questId),
      ),
      (
        EditorDocumentKind.gameLoad.icon,
        EditorDocumentKind.gameLoad.label,
        tr('Продолжить из сохранения'),
        EditorDocumentDescriptor.gameFromSave(questId),
      ),
      (
        EditorDocumentKind.guide.icon,
        EditorDocumentKind.guide.label,
        tr('Инструкции и подсказки'),
        EditorDocumentDescriptor.guidesCatalog(questId),
      ),
      (
        EditorDocumentKind.questHistory.icon,
        EditorDocumentKind.questHistory.label,
        tr('Точки восстановления'),
        EditorDocumentDescriptor.questHistory(questId),
      ),
    ];

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: ListView(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                tr('Новая вкладка'),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            for (final (icon, title, subtitle, descriptor) in entries)
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: scheme.onPrimaryContainer, size: 20),
                ),
                title: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(subtitle),
                onTap: () => onOpen(descriptor),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
