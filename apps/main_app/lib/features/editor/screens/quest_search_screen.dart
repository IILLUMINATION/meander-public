import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
///
/// Экран показывает не только список: сколько всего совпало, сколько времени
/// занял поиск (считает Rust) и фильтр по видам — иначе в большом квесте
/// десяток нод и скриптов перемешивается и автор ищет глазами.
class QuestSearchScreen extends StatefulWidget {
  const QuestSearchScreen({super.key, required this.questId, this.service});

  final String questId;

  /// Подмена поиска в тестах: по умолчанию запрос уходит в Rust-ядро.
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
  QuestSearchReport? _report;
  int _elapsedMs = 0;

  /// `null` — показывать все виды.
  QuestSearchKind? _filter;

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
        _report = null;
        _isSearching = false;
        _filter = null;
      });
      return;
    }
    setState(() => _isSearching = true);
    // Поиск в Rust быстрый, но каждый символ — это чтение файлов квеста:
    // короткая пауза в наборе убирает лишние проходы, не мешая печатать.
    _debounce = Timer(const Duration(milliseconds: 160), () async {
      final report = await _search(query);
      if (!mounted || _controller.text.trim() != query) return;
      setState(() {
        _query = query;
        _report = report;
        _elapsedMs = report?.elapsedMs ?? 0;
        _isSearching = false;
        if (_filter != null && (report?.totals[_filter] ?? 0) == 0) {
          _filter = null;
        }
      });
    });
  }

  Future<QuestSearchReport?> _search(String query) async {
    try {
      return await _service.search(query);
    } catch (_) {
      return null;
    }
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

    if (descriptor != null && EditorWorkspaceScope.maybeOf(context) != null) {
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

  List<QuestSearchHit> get _visibleHits {
    final report = _report;
    if (report == null) return const [];
    final filter = _filter;
    if (filter == null) return report.hits;
    return report.hits.where((hit) => hit.kind == filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final report = _report;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            SingleActivator(LogicalKeyboardKey.enter): _OpenFirstIntent(),
          },
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  Navigator.of(context).maybePop();
                  return null;
                },
              ),
              _OpenFirstIntent: CallbackAction<_OpenFirstIntent>(
                onInvoke: (_) {
                  final visible = _visibleHits;
                  if (visible.isNotEmpty) _openHit(visible.first);
                  return null;
                },
              ),
            },
            child: Column(
              children: [
                _buildHeader(scheme),
                if (report != null)
                  _buildStatusBar(scheme, report)
                else
                  const SizedBox(height: 8),
                Expanded(child: _buildBody(scheme)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: tr('Назад'),
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      autofocus: true,
                      style: TextStyle(color: scheme.onSurface),
                      decoration: InputDecoration(
                        hintText: tr(
                          'Найти в квесте: нода, скрипт, таблица, переменная',
                        ),
                        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onChanged: _onQueryChanged,
                    ),
                  ),
                  if (_isSearching)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    )
                  else if (_controller.text.isNotEmpty)
                    IconButton(
                      tooltip: tr('Очистить'),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      onPressed: () {
                        _controller.clear();
                        _onQueryChanged('');
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Сводка и фильтры: «12 из 30 · 4 мс» и чипы видов с количеством.
  Widget _buildStatusBar(ColorScheme scheme, QuestSearchReport report) {
    final kinds = [
      for (final kind in QuestSearchKind.values)
        if ((report.totals[kind] ?? 0) > 0) kind,
    ];
    final shownText = report.matches > report.total
        ? trf('Показано {p0} из {p1}', {
            'p0': report.total,
            'p1': report.matches,
          })
        : trf('Найдено: {p0}', {'p0': report.matches});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
          child: Row(
            children: [
              Text(
                shownText,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              if (_elapsedMs > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '· ${trf('{p0} мс', {'p0': _elapsedMs})}',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              _FilterChip(
                label: tr('Все'),
                selected: _filter == null,
                onTap: () => setState(() => _filter = null),
              ),
              for (final kind in kinds)
                _FilterChip(
                  icon: _kindIcon(kind),
                  tooltip: _kindTitle(kind),
                  count: report.totals[kind] ?? 0,
                  selected: _filter == kind,
                  onTap: () => setState(
                    () => _filter = _filter == kind ? null : kind,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_query.isEmpty) {
      return _EmptyState(
        icon: Icons.manage_search_rounded,
        title: tr('Ищу по названиям и содержимому'),
        hint: tr(
          'Ноды, визуальные и Lua-скрипты, таблицы, переменные и ресурсы — всё сразу.',
        ),
      );
    }
    if (_isSearching && _report == null) {
      return Center(child: CircularProgressIndicator(color: scheme.primary));
    }
    final report = _report;
    if (report == null) {
      return _EmptyState(
        icon: Icons.wifi_off_rounded,
        title: tr('Поиск недоступен'),
        hint: tr('Обновите страницу и попробуйте ещё раз.'),
      );
    }
    final visible = _visibleHits;
    if (visible.isEmpty) {
      return _EmptyState(
        icon: Icons.search_off_rounded,
        title: tr('Ничего не нашлось'),
        hint: tr('Попробуйте другое слово — поиск идёт по всему квесту.'),
      );
    }

    final grouped = <QuestSearchKind, List<QuestSearchHit>>{};
    for (final hit in visible) {
      grouped.putIfAbsent(hit.kind, () => []).add(hit);
    }

    return AdaptiveContent(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          for (final kind in QuestSearchKind.values)
            if (grouped[kind] != null) ...[
              _SectionHeader(
                icon: _kindIcon(kind),
                title: _kindTitle(kind),
                count: grouped[kind]!.length,
              ),
              for (final hit in grouped[kind]!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _HitTile(
                    hit: hit,
                    query: _query,
                    onTap: () => _openHit(hit),
                  ),
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
    QuestSearchKind.script => Icons.account_tree_rounded,
    QuestSearchKind.lua => Icons.data_object_rounded,
    QuestSearchKind.table => Icons.table_chart_rounded,
    QuestSearchKind.variable => Icons.data_array_rounded,
    QuestSearchKind.resource => Icons.folder_special_rounded,
  };
}

/// Запрос без начального действия: Enter открывает первый результат.
class _OpenFirstIntent extends Intent {
  const _OpenFirstIntent();
}

class _FilterChip extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final String? tooltip;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    this.label,
    this.icon,
    this.tooltip,
    this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final chip = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: fg),
                  const SizedBox(width: 6),
                ],
                if (label != null)
                  Text(
                    label!,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '$count',
                    style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final int count;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _HitTile extends StatelessWidget {
  final QuestSearchHit hit;
  final String query;
  final VoidCallback onTap;

  const _HitTile({
    required this.hit,
    required this.query,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _QuestSearchScreenState._kindIcon(hit.kind),
                  size: 18,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      _highlighted(context, hit.title, query),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (hit.snippet.isNotEmpty || hit.context.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text.rich(
                        TextSpan(
                          children: [
                            if (hit.snippet.isNotEmpty)
                              TextSpan(text: hit.snippet)
                            else
                              TextSpan(text: hit.context),
                            if (hit.snippet.isNotEmpty && hit.context.isNotEmpty)
                              TextSpan(
                                text: '  ·  ${hit.context}',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: scheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Подсветить совпадение: автор сразу видит, где именно нашлось слово.
  static TextSpan _highlighted(
    BuildContext context,
    String text,
    String query,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    if (lowerQuery.isEmpty) return TextSpan(text: text);
    final index = lowerText.indexOf(lowerQuery);
    if (index < 0) return TextSpan(text: text);
    return TextSpan(
      children: [
        TextSpan(text: text.substring(0, index)),
        TextSpan(
          text: text.substring(index, index + query.length),
          style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
        TextSpan(text: text.substring(index + query.length)),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
