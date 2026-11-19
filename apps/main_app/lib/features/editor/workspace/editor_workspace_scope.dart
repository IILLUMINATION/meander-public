import 'package:flutter/material.dart';

import 'editor_document.dart';
import 'editor_workspace_controller.dart';

class EditorDocumentContext extends InheritedWidget {
  final EditorDocumentId id;

  /// Видима ли вкладка документа в текущий момент. Используется для ленивого
  /// старта тяжёлых документов (например, игровой симуляции): фоновая вкладка
  /// не должна запускать движок, пока пользователь не переключится на неё.
  final bool isActive;

  const EditorDocumentContext({
    super.key,
    required this.id,
    this.isActive = true,
    required super.child,
  });

  static EditorDocumentContext? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EditorDocumentContext>();

  @override
  bool updateShouldNotify(EditorDocumentContext oldWidget) =>
      id != oldWidget.id || isActive != oldWidget.isActive;
}

class EditorWorkspaceScope extends InheritedWidget {
  /// Квест, в рабочей области которого открыт этот scope. Нужен экранам,
  /// которые умеют становиться вкладками, но не знают id квеста (профиль,
  /// каталог, настройки).
  final String questId;

  final void Function(EditorDocumentDescriptor descriptor) openDocument;
  final void Function(EditorDocumentDescriptor descriptor) openForcedAsNewTab;
  final VoidCallback showNewTabSheet;
  final void Function(EditorDocumentId id) togglePin;
  final bool Function(EditorDocumentId id) isPinned;
  final Future<bool> Function(EditorDocumentId id) closeDocument;
  final void Function(EditorDocumentId id) focusDocument;
  final void Function(EditorDocumentId id, EditorDocumentDescriptor descriptor)
  replaceDocument;
  final void Function(EditorDocumentId id, EditorDocumentRuntime runtime)
  registerRuntime;
  final void Function(EditorDocumentId id) unregisterRuntime;
  final void Function(EditorDocumentId id, bool dirty) markDirty;

  /// Единая точка «Назад» воркспейса: браузерная история, а при её
  /// исчерпании — закрытие активной вкладки. Кнопки-стрелки внутри
  /// документов обязаны вызывать его вместо самостоятельного
  /// closeDocument, иначе стек посещений не учитывается.
  final Future<void> Function() requestBack;

  const EditorWorkspaceScope({
    super.key,
    required this.questId,
    required this.openDocument,
    required this.openForcedAsNewTab,
    required this.showNewTabSheet,
    required this.togglePin,
    required this.isPinned,
    required this.closeDocument,
    required this.focusDocument,
    required this.replaceDocument,
    required this.registerRuntime,
    required this.unregisterRuntime,
    required this.markDirty,
    required this.requestBack,
    required super.child,
  });

  static EditorWorkspaceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EditorWorkspaceScope>();

  static EditorWorkspaceScope of(BuildContext context) =>
      maybeOf(context) ??
      (throw FlutterError(
        'EditorWorkspaceScope is missing above this context',
      ));

  @override
  bool updateShouldNotify(EditorWorkspaceScope oldWidget) =>
      questId != oldWidget.questId ||
      openDocument != oldWidget.openDocument ||
      openForcedAsNewTab != oldWidget.openForcedAsNewTab ||
      showNewTabSheet != oldWidget.showNewTabSheet ||
      togglePin != oldWidget.togglePin ||
      isPinned != oldWidget.isPinned ||
      closeDocument != oldWidget.closeDocument ||
      focusDocument != oldWidget.focusDocument ||
      replaceDocument != oldWidget.replaceDocument ||
      registerRuntime != oldWidget.registerRuntime ||
      unregisterRuntime != oldWidget.unregisterRuntime ||
      markDirty != oldWidget.markDirty ||
      requestBack != oldWidget.requestBack;
}
