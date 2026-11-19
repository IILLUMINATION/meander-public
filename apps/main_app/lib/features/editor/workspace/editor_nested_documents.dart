import 'dart:async';

import 'package:flutter/material.dart';

import 'editor_document.dart';
import 'editor_workspace_controller.dart';
import 'editor_workspace_scope.dart';

/// Вкладки для вложенных редакторов: стек, контейнер, текст, кнопка и т. п.
///
/// Такой экран раньше открывался маршрутом поверх воркспейса и прятал
/// таб-бар. Здесь он становится обычной вкладкой, а его `Navigator.pop`
/// замыкается на вкладку: результат возвращается вызывающему коду, вкладка
/// закрывается. Builder живёт только в памяти — после перезапуска такие
/// вкладки не восстанавливаются (см. [EditorWorkspaceController.restore]).
class EditorNestedDocuments {
  EditorNestedDocuments._();

  static final Map<EditorDocumentId, _Entry> _entries = {};

  /// Открыть вложенный редактор вкладкой и дождаться его результата.
  ///
  /// Вне воркспейса (отдельный маршрут ноды) поведение прежнее — обычный
  /// `Navigator.push`, чтобы экран не остался без таб-бара.
  static Future<T?> open<T>(
    BuildContext context, {
    required String questId,
    required String identity,
    required String title,
    required WidgetBuilder builder,
    EditorDocumentKind kind = EditorDocumentKind.tool,
    IconData? icon,
  }) {
    final scope = EditorWorkspaceScope.maybeOf(context);
    if (scope == null) {
      return Navigator.push<T>(context, MaterialPageRoute(builder: builder));
    }

    final id = EditorDocumentId(questId: questId, kind: kind, key: identity);
    final existing = _entries[id];
    if (existing != null && !existing.completer.isCompleted) {
      scope.focusDocument(id);
      return existing.completer.future.then((value) => value as T?);
    }

    final entry = _Entry(
      builder: builder,
      parentId: EditorDocumentContext.maybeOf(context)?.id,
      close: scope.closeDocument,
    );
    _entries[id] = entry;
    scope.registerRuntime(
      id,
      EditorDocumentRuntime(
        keepAlive: true,
        onBeforeClose: () async {
          // Закрытие крестиком/«Назад» — это отмена вложенного редактора.
          complete(id, null);
          return true;
        },
      ),
    );
    scope.openForcedAsNewTab(
      EditorDocumentDescriptor(
        id: id,
        title: title,
        parentId: entry.parentId,
        customIcon: icon,
      ),
    );
    return entry.completer.future.then((value) => value as T?);
  }

  static EditorDocumentId? parentOf(EditorDocumentId id) =>
      _entries[id]?.parentId;

  static bool hasBuilder(EditorDocumentId id) =>
      _entries.containsKey(id) && !_entries[id]!.completer.isCompleted;

  /// Снять верхний маршрут внутри вкладки (пикер, вложенный диалог).
  ///
  /// Системная «Назад» приходит корневому навигатору и не видит вложенный:
  /// без этого вызова она закрывала бы всю вкладку вместе с несохранённым
  /// черновиком.
  static Future<bool> maybePop(EditorDocumentId id) async {
    final navigator = _entries[id]?.navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return false;
    await navigator.maybePop();
    return true;
  }

  /// Содержимое вкладки. Отсутствующий builder — сессия была восстановлена
  /// в другом процессе; контроллер такие документы и так отбрасывает.
  static Widget build(EditorDocumentId id) {
    final entry = _entries[id];
    if (entry == null) return const SizedBox.shrink();
    return _EditorNestedTabHost(
      key: ValueKey(id.persistenceKey),
      navigatorKey: entry.navigatorKey,
      builder: entry.builder,
      onResult: (result) => _finishAndClose(id, result),
    );
  }

  /// Завершить ожидание, не закрывая вкладку (закрытие уже идёт извне).
  static void complete(EditorDocumentId id, Object? result) {
    final entry = _entries.remove(id);
    if (entry == null || entry.completer.isCompleted) return;
    entry.completer.complete(result);
  }

  static void _finishAndClose(EditorDocumentId id, Object? result) {
    final entry = _entries.remove(id);
    if (entry != null && !entry.completer.isCompleted) {
      entry.completer.complete(result);
    }
    if (entry != null) unawaited(entry.close(id));
  }

  @visibleForTesting
  static void resetForTest() => _entries.clear();
}

class _Entry {
  _Entry({required this.builder, required this.parentId, required this.close});

  final WidgetBuilder builder;
  final EditorDocumentId? parentId;
  final Future<bool> Function(EditorDocumentId) close;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  final Completer<Object?> completer = Completer<Object?>();
}

/// Вкладка-хост: даёт экрану собственный `Navigator`, поэтому его
/// `Navigator.pop(result)` не закрывает весь редактор, а только эту вкладку.
class _EditorNestedTabHost extends StatefulWidget {
  const _EditorNestedTabHost({
    super.key,
    required this.navigatorKey,
    required this.builder,
    required this.onResult,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final WidgetBuilder builder;
  final ValueChanged<Object?> onResult;

  @override
  State<_EditorNestedTabHost> createState() => _EditorNestedTabHostState();
}

class _EditorNestedTabHostState extends State<_EditorNestedTabHost> {
  bool _pushed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pushed) return;
      _pushed = true;
      final navigator = widget.navigatorKey.currentState;
      if (navigator == null) return;
      unawaited(_pushEditor(navigator));
    });
  }

  Future<void> _pushEditor(NavigatorState navigator) async {
    final result = await navigator.push<Object?>(
      PageRouteBuilder<Object?>(
        pageBuilder: (context, _, _) => widget.builder(context),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    if (!mounted) return;
    widget.onResult(result);
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Navigator(
      key: widget.navigatorKey,
      onGenerateRoute: (_) => PageRouteBuilder<void>(
        pageBuilder: (context, _, _) => ColoredBox(color: surface),
        transitionDuration: Duration.zero,
      ),
    );
  }
}
