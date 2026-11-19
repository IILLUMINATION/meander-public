import 'dart:async';

import 'package:flutter/material.dart';

import 'editor_document.dart';
import 'editor_workspace_scope.dart';

/// Обработчик запроса «Назад» для документа воркспейса.
///
/// Возвращает `true`, если запрос обработан полностью: вкладка закрыта,
/// шаг внутри документа сделан (например, выход из папки библиотеки) или
/// выход отменён (пользователь не сохранил изменения) — шелл после этого
/// никаких дополнительных действий не выполняет.
///
/// `false` — «не моё событие»: документ глубины не имеет, решает шелл
/// (история вкладок, закрытие, выход из редактора) или маршрут в режиме
/// отдельного экрана.
typedef EditorBackPressed = Future<bool> Function();

/// Запись реестра: обработчик и его место в очереди «Назад».
class EditorBackEntry {
  final EditorBackPressed handler;

  /// Документ живёт в собственной глубине (папки библиотеки ресурсов), и
  /// «Назад» внутри неё значит «на уровень выше», а не «предыдущая вкладка».
  /// Такой обработчик спрашивается раньше истории воркспейса.
  final bool beforeWorkspaceHistory;

  const EditorBackEntry(this.handler, {this.beforeWorkspaceHistory = false});
}

/// Реестр back-обработчиков документов редактора.
///
/// Проблема, которую решает: вкладки живут в IndexedStack внутри одного
/// маршрута шелла, но каждая вкладка со своим `PopScope(canPop: false)`
/// регистрировалась на маршруте шелла — одно нажатие «Назад» дёргало
/// onPopInvoked всех смонтированных вкладок сразу (закрывалось несколько
/// вкладок за раз, вплоть до пустого экрана).
///
/// Теперь маршрут шелла содержит ровно один PopScope; документы вместо него
/// оборачивают контент в [EditorBackHandler] и регистрируют сюда свой
/// обработчик. Шелл диспатчит запрос только активному документу.
class EditorBackHandlers {
  final Map<EditorDocumentId, EditorBackEntry> _handlers = {};

  /// Обработчик документа или null, если документ его не зарегистрировал.
  EditorBackPressed? handlerFor(EditorDocumentId id) => _handlers[id]?.handler;

  /// Берёт ли документ «Назад» раньше истории воркспейса.
  bool takesBackBeforeHistory(EditorDocumentId id) =>
      _handlers[id]?.beforeWorkspaceHistory ?? false;

  void _register(
    EditorDocumentId id,
    EditorBackPressed handler, {
    bool beforeWorkspaceHistory = false,
  }) => _handlers[id] = EditorBackEntry(
    handler,
    beforeWorkspaceHistory: beforeWorkspaceHistory,
  );

  /// Снимаем регистрацию только если это то же самое замыкание —
  /// защита от гонки при быстром dispose/пересоздании виджетов.
  void _unregister(EditorDocumentId id, EditorBackPressed handler) {
    if (identical(_handlers[id]?.handler, handler)) {
      _handlers.remove(id);
    }
  }
}

/// Inherited-обёртка над [EditorBackHandlers]. Экземпляр хранилища создаёт
/// шелл в своём State — пересборки не теряют регистрации вкладок.
class EditorBackRegistry extends InheritedWidget {
  final EditorBackHandlers holder;

  const EditorBackRegistry({
    super.key,
    required this.holder,
    required super.child,
  });

  /// Без dependOn: реестр читается императивно из pop-колбэков и
  /// регистрации, подписываться на него во время build не нужно.
  static EditorBackRegistry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EditorBackRegistry>();

  @override
  bool updateShouldNotify(EditorBackRegistry oldWidget) => false;
}

/// Регистрирует [onBackPressed] для текущего документа на время жизни
/// этого виджета. Документ должен находиться под [EditorDocumentContext]
/// (иначе регистрация не происходит — режим отдельного маршрута).
///
/// Использование:
/// ```dart
/// return EditorBackHandler(
///   onBackPressed: _handleExit,
///   child: scaffold,
/// );
/// ```
class EditorBackHandler extends StatefulWidget {
  final EditorBackPressed onBackPressed;

  /// Документ со своей глубиной: «Назад» спрашивается раньше истории вкладок.
  /// См. [EditorBackEntry.beforeWorkspaceHistory].
  final bool beforeWorkspaceHistory;

  final Widget child;

  const EditorBackHandler({
    super.key,
    required this.onBackPressed,
    this.beforeWorkspaceHistory = false,
    required this.child,
  });

  @override
  State<EditorBackHandler> createState() => _EditorBackHandlerState();
}

class _EditorBackHandlerState extends State<EditorBackHandler> {
  EditorDocumentId? _id;
  EditorBackPressed? _registered;
  EditorBackHandlers? _holder;

  void _sync() {
    final doc = EditorDocumentContext.maybeOf(context);
    final holder = EditorBackRegistry.maybeOf(context)?.holder;

    // Контекст сменился (id другой или вышли из воркспейса) — снимаем старую
    // регистрацию и ставим новую.
    if (_registered != null &&
        (_holder != holder || doc == null || doc.id != _id)) {
      _holder?._unregister(_id!, _registered!);
      _registered = null;
    }

    if (doc != null && holder != null) {
      _id = doc.id;
      _holder = holder;
      _registered = widget.onBackPressed;
      holder._register(
        doc.id,
        widget.onBackPressed,
        beforeWorkspaceHistory: widget.beforeWorkspaceHistory,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    // _sync вызовется в didChangeDependencies, где доступен InheritedWidget.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(EditorBackHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!identical(oldWidget.onBackPressed, widget.onBackPressed) ||
            oldWidget.beforeWorkspaceHistory !=
                widget.beforeWorkspaceHistory) &&
        _registered != null &&
        _holder != null &&
        _id != null) {
      _holder!._unregister(_id!, _registered!);
      _registered = widget.onBackPressed;
      _holder!._register(
        _id!,
        widget.onBackPressed,
        beforeWorkspaceHistory: widget.beforeWorkspaceHistory,
      );
    }
  }

  @override
  void dispose() {
    if (_registered != null && _holder != null && _id != null) {
      _holder!._unregister(_id!, _registered!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Область обработки «Назад» документа редактора.
///
/// Встроенный режим (документ как вкладка воркспейса, есть
/// [EditorDocumentContext]): обработчик уходит в [EditorBackRegistry],
/// диспатчится только когда документ активен. Сам PopScope на маршруте
/// один — в шелле.
///
/// Режим отдельного маршрута ([EditorOpenMode.routeOnly] и legacy-точки
/// входа): классический `PopScope(canPop: [standaloneCanPop])` вокруг
/// контента, поведение идентично прежнему коду документов.
class EditorDocumentBackScope extends StatefulWidget {
  final EditorBackPressed onBackPressed;

  /// Документ со своей глубиной: «Назад» спрашивается раньше истории вкладок.
  final bool beforeWorkspaceHistory;

  /// Может ли маршрут попнуть напрямую без обработчика (например,
  /// экран настроек без несохранённых изменений). Используется только
  /// в режиме отдельного маршрута.
  final bool standaloneCanPop;

  final Widget child;

  const EditorDocumentBackScope({
    super.key,
    required this.onBackPressed,
    this.beforeWorkspaceHistory = false,
    this.standaloneCanPop = false,
    required this.child,
  });

  @override
  State<EditorDocumentBackScope> createState() =>
      _EditorDocumentBackScopeState();
}

class _EditorDocumentBackScopeState extends State<EditorDocumentBackScope> {
  bool _embedded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _embedded = EditorDocumentContext.maybeOf(context) != null;
  }

  /// Отдельный маршрут: обработчик сделал шаг внутри документа — остаёмся;
  /// вернул `false` (шагов больше нет) — закрываем экран, как и «Назад»
  /// на обычном маршруте.
  Future<void> _runAndMaybePop(BuildContext context) async {
    final handled = await widget.onBackPressed();
    if (handled || !context.mounted) return;
    Navigator.maybeOf(context)?.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_embedded) {
      return EditorBackHandler(
        onBackPressed: widget.onBackPressed,
        beforeWorkspaceHistory: widget.beforeWorkspaceHistory,
        child: widget.child,
      );
    }
    return PopScope(
      canPop: widget.standaloneCanPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || widget.standaloneCanPop) return;
        unawaited(_runAndMaybePop(context));
      },
      child: widget.child,
    );
  }
}
