import 'dart:async';

import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/services/quest_search_service.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/variable_selection_screen.dart';
import 'package:canvas_app/features/resources/screens/resources_screen.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Поиск по всему квесту: ноды, скрипты, таблицы, переменные, ресурсы.
///
/// Открывается как отдельный экран поверх редактора и закрывается перед
/// переходом к результату: документ получает вкладку воркспейса, а не
/// прячется под поиском.
class QuestSearchScreen extends StatefulWidget {
  const QuestSearchScreen({super.key, required this.questId, this.service});

  final String questId;

  /// Подмена поиска в тестах: по умолчанию читается диск квеста.
  final QuestSearchService? service;

  @override
  State<QuestSearchScreen> createState() => _QuestSearchScreenState();
}

class _QuestSearchScreenState extends State<QuestSearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final QuestSearchService _service =
      widget.service ?? QuestSearchService(questId: widget.questId);

  Timer? _debounce;
  bool _isSearching = false;
  String _query = '';
  List<QuestSearchHit> _hits = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _hits = const [];
        _isSearching = false;
      });
      return;
    }
    setState(() => _isSearching = true);
    // Файлы читаются с диска: на каждый символ это лишний проход, поэтому
    // ждём паузу в наборе.
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      final hits = await _service.search(query);
      if (!mounted || _controller.text.trim() != query) return;
      setState(() {
        _query = query;
        _hits = hits;
        _isSearching = false;
      });
    });
  }

  /// Открыть результат и закрыть поиск.
  ///
  /// Порядок важен: сначала документ (в воркспейсе он занимает вкладку под
  /// поиском), и только потом поиск уходит со стека — иначе переход шёл бы
  /// из контекста уже удалённого экрана.
  Future<void> _openHit(QuestSearchHit hit) async {
    final navigator = Navigator.of(context);
    final descriptor = _descriptorFor(hit);
    final screen = _screenFor(hit);

    if (descriptor != null &&
        EditorWorkspaceScope.maybeOf(context) != null) {
      await EditorDocumentLauncher.open(context, descriptor);
      if (mounted) navigator.pop();
      return;
    }

    navigator.pop();
    if (descriptor != null) {
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              EditorDocumentLauncher.buildDocument(descriptor, routeOnly: true),
        ),
      );
      return;
    }
    if (screen != null) {
      await navigator.push(MaterialPageRoute<void>(builder: screen));
    }
  }

  EditorDocumentDescriptor? _descriptorFor(QuestSearchHit hit) {
    switch (hit.kind) {
      case QuestSearchKind.node:
        return EditorDocumentDescriptor.node(
          widget.questId,
          hit.id,
          title: hit.title,
        );
      case QuestSearchKind.script:
        return EditorDocumentDescriptor.visualScript(
          widget.questId,
          hit.id.replaceFirst(RegExp(r'\.json$'), ''),
          title: hit.title,
        );
      case QuestSearchKind.lua:
        return EditorDocumentDescriptor.lua(
          widget.questId,
          hit.id,
          title: hit.title,
          fileName: hit.id,
        );
      case QuestSearchKind.table:
      case QuestSearchKind.variable:
      case QuestSearchKind.resource:
        return null;
    }
  }

  WidgetBuilder? _screenFor(QuestSearchHit hit) {
    switch (hit.kind) {
      case QuestSearchKind.table:
        return (_) => VariableSelectionScreen(
          questId: widget.questId,
          initialTabIndex: 1,
          initialSearch: hit.id,
        );
      case QuestSearchKind.variable:
        return (_) => VariableSelectionScreen(
          questId: widget.questId,
          initialSearch: hit.id,
        );
      case QuestSearchKind.resource:
        return (_) => ResourcesScreen(
          questId: widget.questId,
          initialSearch: hit.title,
        );
      case QuestSearchKind.node:
      case QuestSearchKind.script:
      case QuestSearchKind.lua:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          style: TextStyle(color: scheme.onSurface),
          decoration: InputDecoration(
            hintText: tr('Найти в квесте: нода, скрипт, таблица, переменная'),
            hintStyle: TextStyle(color: scheme.onSurfaceVariant),
            border: InputBorder.none,
          ),
          onChanged: _onQueryChanged,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: tr('Очистить'),
              icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
              onPressed: () {
                _controller.clear();
                _onQueryChanged('');
              },
            ),
        ],
      ),
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_isSearching) {
      return Center(child: CircularProgressIndicator(color: scheme.primary));
    }
    if (_query.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr(
              'Ищу по названиям и содержимому: ноды, визуальные скрипты, Lua, таблицы, переменные, ресурсы.',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text(
          tr('Ничего не нашлось'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }

    final grouped = <QuestSearchKind, List<QuestSearchHit>>{};
    for (final hit in _hits) {
      grouped.putIfAbsent(hit.kind, () => []).add(hit);
    }

    return AdaptiveContent(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final kind in QuestSearchKind.values)
            if (grouped[kind] != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  _kindTitle(kind),
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              for (final hit in grouped[kind]!)
                ListTile(
                  leading: Icon(_kindIcon(kind), color: scheme.primary),
                  title: Text(
                    hit.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: hit.snippet.isEmpty
                      ? (hit.context.isEmpty ? null : Text(hit.context))
                      : Text(
                          hit.snippet,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: hit.snippet.isEmpty
                      ? null
                      : Text(
                          hit.context,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                  onTap: () => _openHit(hit),
                ),
            ],
        ],
      ),
    );
  }

  static String _kindTitle(QuestSearchKind kind) => switch (kind) {
    QuestSearchKind.node => tr('Ноды'),
    QuestSearchKind.script => tr('Визуальные скрипты'),
    QuestSearchKind.lua => tr('Lua-скрипты'),
    QuestSearchKind.table => tr('Таблицы'),
    QuestSearchKind.variable => tr('Переменные'),
    QuestSearchKind.resource => tr('Ресурсы'),
  };

  static IconData _kindIcon(QuestSearchKind kind) => switch (kind) {
    QuestSearchKind.node => Icons.article_rounded,
    QuestSearchKind.script => Icons.account_tree_outlined,
    QuestSearchKind.lua => Icons.data_object_rounded,
    QuestSearchKind.table => Icons.table_chart_rounded,
    QuestSearchKind.variable => Icons.data_array_rounded,
    QuestSearchKind.resource => Icons.folder_special_rounded,
  };
}