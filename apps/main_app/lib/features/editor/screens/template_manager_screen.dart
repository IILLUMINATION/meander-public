import 'package:canvas_app/features/editor/providers/template_provider.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

/// Экран управления шаблонами: список «глобальные / этого квеста»,
/// поиск, переименование, удаление, экспорт `.mndtpl`, импорт `.mndtpl`,
/// перенос между scope.
class TemplateManagerScreen extends ConsumerStatefulWidget {
  final String? questId;

  /// Если null — управление только глобальными.
  const TemplateManagerScreen({super.key, this.questId});

  @override
  ConsumerState<TemplateManagerScreen> createState() =>
      _TemplateManagerScreenState();
}

class _TemplateManagerScreenState extends ConsumerState<TemplateManagerScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _searchCtrl = TextEditingController();
  String _search = '';

  bool get _hasQuest => widget.questId != null;

  Future<void> _closeDocument() async {
    if (!mounted) return;
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);
    if (document != null && workspace != null) {
      await workspace.closeDocument(document.id);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _hasQuest ? 2 : 1,
      vsync: this,
      initialIndex: _hasQuest ? 0 : 0,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        leading: IconButton(
          tooltip: tr('Закрыть вкладку'),
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _closeDocument,
        ),
        title: Text(tr('Шаблоны')),
        backgroundColor: const Color(0xFF1E1E1E),
        bottom: _hasQuest
            ? TabBar(
                controller: _tabController,
                tabs: [
                  Tab(text: tr('Этого квеста')),
                  Tab(text: tr('Глобальные')),
                ],
                indicatorColor: Colors.cyanAccent,
              )
            : null,
        actions: [
          IconButton(
            tooltip: tr('Импорт'),
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _importFromFile,
          ),
        ],
      ),
      body: AdaptiveContent(
        maxWidth: 900,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: tr('Поиск...'),
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Colors.white54,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            Expanded(
              child: _hasQuest
                  ? TabBarView(
                      controller: _tabController,
                      children: [
                        _buildList(scope: TemplateScope.quest),
                        _buildList(scope: TemplateScope.global),
                      ],
                    )
                  : _buildList(scope: TemplateScope.global),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList({required TemplateScope scope}) {
    final AsyncValue<List<TemplateItem>> async;
    if (scope == TemplateScope.global) {
      async = ref.watch(globalTemplatesProvider);
    } else {
      async = ref.watch(questTemplatesProvider(widget.questId!));
    }
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text(
          trf('Не удалось загрузить: {p0}', {'p0': friendlyError(e)}),
          style: const TextStyle(color: Colors.redAccent),
        ),
      ),
      data: (items) {
        final q = _search.trim().toLowerCase();
        final filtered = q.isEmpty
            ? items
            : items.where((t) {
                final hay =
                    '${t.name} ${t.description ?? ''} ${t.category ?? ''}'
                        .toLowerCase();
                return hay.contains(q);
              }).toList();
        if (filtered.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bookmark_border_rounded,
                    size: 56,
                    color: Colors.white24,
                  ),
                  SizedBox(height: 10),
                  Text(tr('Здесь пусто'), style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          itemCount: filtered.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (_, i) => _TemplateManagerTile(
            template: filtered[i],
            scope: scope,
            onAction: (action) => _handleAction(action, filtered[i], scope),
          ),
        );
      },
    );
  }

  Future<void> _handleAction(
    _TileAction action,
    TemplateItem template,
    TemplateScope scope,
  ) async {
    final actions = ref.read(templateActionsProvider);
    switch (action) {
      case _TileAction.rename:
        final newName = await _askName(template.name);
        if (newName == null || newName.trim().isEmpty) return;
        await actions.rename(
          template,
          newName: newName.trim(),
          scope: scope,
          questId: widget.questId,
        );
        break;
      case _TileAction.delete:
        final confirmed = await _confirm(
          trf('Удалить «{p0}»?', {'p0': template.name}),
          tr('Это действие нельзя отменить.'),
        );
        if (confirmed != true) return;
        await actions.delete(template, scope: scope, questId: widget.questId);
        if (mounted) _showSnack(tr('Шаблон удалён'));
        break;
      case _TileAction.export:
        final path = await actions.exportToFile(template);
        if (path != null && mounted) {
          _showSnack(tr('Экспортировано'));
        }
        break;
      case _TileAction.moveToGlobal:
        await actions.move(
          template: template,
          from: scope,
          to: TemplateScope.global,
          questId: widget.questId,
        );
        if (mounted) _showSnack(tr('Перенесён в глобальные'));
        break;
      case _TileAction.moveToQuest:
        if (widget.questId == null) return;
        await actions.move(
          template: template,
          from: scope,
          to: TemplateScope.quest,
          questId: widget.questId,
        );
        if (mounted) _showSnack(tr('Перенесён в квест'));
        break;
    }
  }

  Future<void> _importFromFile() async {
    final actions = ref.read(templateActionsProvider);
    final imported = await actions.importFromFile();
    if (!mounted || imported == null) return;

    TemplateScope target;
    if (!_hasQuest) {
      target = TemplateScope.global;
    } else {
      final picked = await showAppDialog<TemplateScope>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text(
            tr('Куда добавить шаблон?'),
            style: TextStyle(color: Colors.white),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, TemplateScope.quest),
              child: Text(tr('В этот квест')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, TemplateScope.global),
              child: Text(tr('Глобально')),
            ),
          ],
        ),
      );
      if (picked == null) return;
      target = picked;
    }
    if (target == TemplateScope.global) {
      await actions.saveAsGlobal(
        imported.template,
        bytesBySha: imported.bytesBySha,
      );
    } else {
      await actions.saveToQuest(widget.questId!, imported.template);
    }
  }

  Future<String?> _askName(String initial) {
    final ctrl = TextEditingController(text: initial);
    return showAppDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          tr('Переименовать'),
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: tr('Название'),
            labelStyle: TextStyle(color: Colors.white60),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm(String title, String body) {
    return showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(body, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

enum _TileAction { rename, delete, export, moveToGlobal, moveToQuest }

class _TemplateManagerTile extends StatelessWidget {
  final TemplateItem template;
  final TemplateScope scope;
  final void Function(_TileAction action) onAction;

  const _TemplateManagerTile({
    required this.template,
    required this.scope,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1F1F1F),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              _kindIcon(template.kind),
              color: _kindColor(template.kind),
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    template.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${template.kind.displayName}'
                    '${template.category != null ? ' · ${template.category}' : ''}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            PopupMenuButton<_TileAction>(
              icon: const Icon(Icons.more_vert, color: Colors.white60),
              onSelected: onAction,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _TileAction.rename,
                  child: ListTile(
                    leading: Icon(Icons.edit_rounded),
                    title: Text(tr('Переименовать')),
                  ),
                ),
                PopupMenuItem(
                  value: _TileAction.export,
                  child: ListTile(
                    leading: Icon(Icons.file_upload_outlined),
                    title: Text(tr('Экспорт .mndtpl')),
                  ),
                ),
                if (scope == TemplateScope.quest)
                  PopupMenuItem(
                    value: _TileAction.moveToGlobal,
                    child: ListTile(
                      leading: Icon(Icons.public_rounded),
                      title: Text(tr('Сделать глобальным')),
                    ),
                  ),
                if (scope == TemplateScope.global)
                  PopupMenuItem(
                    value: _TileAction.moveToQuest,
                    child: ListTile(
                      leading: Icon(Icons.folder_rounded),
                      title: Text(tr('Перенести в квест')),
                    ),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: _TileAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_rounded, color: Colors.red),
                    title: Text(tr('Удалить'), style: TextStyle(color: Colors.red)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _kindIcon(TemplateKind kind) {
    switch (kind) {
      case TemplateKind.node:
        return Icons.account_tree_rounded;
      case TemplateKind.row:
        return Icons.table_rows_rounded;
      case TemplateKind.column:
        return Icons.view_column_rounded;
      case TemplateKind.modal:
        return Icons.web_asset_rounded;
      case TemplateKind.content:
        return Icons.widgets_rounded;
      case TemplateKind.chapter:
        return Icons.book_rounded;
      case TemplateKind.multi:
        return Icons.dynamic_feed_rounded;
    }
  }

  Color _kindColor(TemplateKind kind) {
    switch (kind) {
      case TemplateKind.node:
        return Colors.cyanAccent;
      case TemplateKind.row:
        return Colors.orangeAccent;
      case TemplateKind.column:
        return Colors.purpleAccent;
      case TemplateKind.modal:
        return Colors.tealAccent;
      case TemplateKind.content:
        return Colors.lightBlueAccent;
      case TemplateKind.chapter:
        return Colors.greenAccent;
      case TemplateKind.multi:
        return Colors.amberAccent;
    }
  }
}
