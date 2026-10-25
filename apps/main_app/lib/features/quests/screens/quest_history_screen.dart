import 'dart:async';

import 'package:canvas_app/core/services/local_history_service.dart';
import 'package:canvas_app/core/services/save_game_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/providers/tag_provider.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

// ============================================================================
//  ИСТОРИЯ ВЕРСИЙ — Material 3 редизайн
// ============================================================================

/// Дата старой точки — без локали intl: таблицы локалей не инициализируются
/// на всех путях запуска, и `DateFormat(..., 'ru')` роняет всю карточку
/// (в release это серая плашка RenderErrorBox вместо версии).
String snapshotTimestampLabel(DateTime dt) =>
    DateFormat('dd.MM.yyyy').format(dt);

class QuestHistoryScreen extends ConsumerStatefulWidget {
  final String questId;
  const QuestHistoryScreen({super.key, required this.questId});

  @override
  ConsumerState<QuestHistoryScreen> createState() => _QuestHistoryScreenState();
}

class _QuestHistoryScreenState extends ConsumerState<QuestHistoryScreen> {
  List<SnapshotInfo> _snapshots = [];
  bool _isLoading = true;
  bool _isOperationInProgress = false;

  @override
  void initState() {
    super.initState();
    _loadSnapshots();
  }

  Future<void> _loadSnapshots() async {
    setState(() => _isLoading = true);
    try {
      final list = await LocalHistoryService.listSnapshots(widget.questId);
      if (mounted) {
        setState(() {
          _snapshots = list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _createBackup() async {
    if (_isOperationInProgress) return;
    setState(() => _isOperationInProgress = true);

    try {
      await LocalHistoryService.createSnapshot(widget.questId);
      if (mounted) _showSnack(tr('Точка восстановления создана'), success: true);
      await _loadSnapshots();
    } catch (e) {
      if (mounted) _showSnack(trf('Ошибка: {p0}', {'p0': friendlyError(e)}), error: true);
    } finally {
      if (mounted) setState(() => _isOperationInProgress = false);
    }
  }

  Future<void> _restoreBackup(SnapshotInfo snapshot) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(tr('Восстановить версию?')),
          content: Text(
            trf('Текущее состояние будет заменено версией от {p0}. Это действие необратимо.', {'p0': _formatDate(snapshot.timestamp)}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.tertiaryContainer,
                foregroundColor: scheme.onTertiaryContainer,
              ),
              child: Text(tr('Восстановить')),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;
    if (_isOperationInProgress) return;
    setState(() => _isOperationInProgress = true);

    try {
      // 1. Создаём страховочный бэкап.
      await LocalHistoryService.createSnapshot(widget.questId);

      // 2. Восстанавливаем.
      await LocalHistoryService.restoreSnapshot(
        widget.questId,
        snapshot.fileName,
      );

      // 3. Сброс кэша провайдеров — чтобы UI увидел новые файлы.
      debugPrint('♻️ [UI] Сброс кэша провайдеров...');
      ref.invalidate(allQuestNodesProvider(widget.questId));
      ref.invalidate(questTagsProvider(widget.questId));
      ref.invalidate(questProvider(widget.questId));
      ref.invalidate(saveSlotsProvider(widget.questId));

      // Даём время Riverpod «осознать» сброс и ФС обновиться.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      if (mounted) {
        _showSnack(tr('Версия успешно восстановлена'), success: true);
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('Restore UI Error: $e');
      if (mounted) {
        _showSnack(trf('Сбой восстановления: {p0}', {'p0': friendlyError(e)}), error: true);
      }
    } finally {
      if (mounted) setState(() => _isOperationInProgress = false);
    }
  }

  Future<void> _deleteBackup(SnapshotInfo snapshot) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(tr('Удалить точку восстановления?')),
          content: Text(
            trf('Версия от {p0} будет удалена безвозвратно.', {'p0': _formatDate(snapshot.timestamp)}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              child: Text(tr('Удалить')),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      await LocalHistoryService.deleteSnapshot(
        widget.questId,
        snapshot.fileName,
      );
      await _loadSnapshots();
      if (mounted) _showSnack(tr('Точка удалена'), success: true);
    }
  }

  // ---------------------------------------------------------------------------
  //  Утилиты
  // ---------------------------------------------------------------------------

  String _formatDate(DateTime dt) => DateFormat('dd.MM.yyyy HH:mm').format(dt);

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return tr('только что');
    if (diff.inMinutes < 60) return trf('{p0} мин назад', {'p0': diff.inMinutes});
    if (diff.inHours < 24) return trf('{p0} ч назад', {'p0': diff.inHours});
    if (diff.inDays < 7) return trf('{p0} д назад', {'p0': diff.inDays});
    return snapshotTimestampLabel(dt);
  }

  void _showSnack(String text, {bool success = false, bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    Color? bg;
    Color? fg;
    if (success) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
    } else if (error) {
      bg = scheme.error;
      fg = scheme.onError;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        closeIconColor: fg,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          tr('История версий'),
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isOperationInProgress ? null : _createBackup,
        heroTag: 'create_snapshot_fab',
        icon: _isOperationInProgress
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onPrimary,
                ),
              )
            : const Icon(Icons.add_rounded),
        label: Text(
          tr('Создать точку'),
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: scheme.primary))
          : _snapshots.isEmpty
          ? const _EmptyState()
          : _buildList(),
    );
  }

  Widget _buildList() {
    final totalBytes = _snapshots.fold<int>(0, (sum, s) => sum + s.sizeBytes);

    return AdaptiveContent(
      maxWidth: 900,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _StatsCard(
                count: _snapshots.length,
                totalSize: _formatSize(totalBytes),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
            sliver: SliverList.separated(
              itemCount: _snapshots.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _SnapshotCard(
                snapshot: _snapshots[i],
                isLatest: i == 0,
                dateLabel: _formatDate(_snapshots[i].timestamp),
                relativeLabel: _relativeTime(_snapshots[i].timestamp),
                sizeLabel: _formatSize(_snapshots[i].sizeBytes),
                onRestore: _isOperationInProgress
                    ? null
                    : () => _restoreBackup(_snapshots[i]),
                onDelete: _isOperationInProgress
                    ? null
                    : () => _deleteBackup(_snapshots[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  STATS CARD
// ============================================================================

class _StatsCard extends StatelessWidget {
  final int count;
  final String totalSize;

  const _StatsCard({required this.count, required this.totalSize});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.history_rounded,
              color: scheme.onPrimary,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count ${_plural(count)}',
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  trf('Занимает {totalSize}', {'totalSize': totalSize}),
                  style: TextStyle(
                    color: scheme.onPrimaryContainer.withOpacity(0.8),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _plural(int n) => trp(['точка', 'точки', 'точек'], n);
}

// ============================================================================
//  SNAPSHOT CARD
// ============================================================================

class _SnapshotCard extends StatelessWidget {
  final SnapshotInfo snapshot;
  final bool isLatest;
  final String dateLabel;
  final String relativeLabel;
  final String sizeLabel;
  final VoidCallback? onRestore;
  final VoidCallback? onDelete;

  const _SnapshotCard({
    required this.snapshot,
    required this.isLatest,
    required this.dateLabel,
    required this.relativeLabel,
    required this.sizeLabel,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onRestore,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.bookmark_rounded,
                  color: scheme.onSecondaryContainer,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          dateLabel,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (isLatest) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              tr('Новейшая'),
                              style: TextStyle(
                                color: scheme.onPrimary,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$relativeLabel • $sizeLabel',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_SnapshotAction>(
                tooltip: tr('Действия'),
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: scheme.onSurfaceVariant,
                ),
                onSelected: (action) {
                  switch (action) {
                    case _SnapshotAction.restore:
                      onRestore?.call();
                      break;
                    case _SnapshotAction.delete:
                      onDelete?.call();
                      break;
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _SnapshotAction.restore,
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text(tr('Восстановить')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: _SnapshotAction.delete,
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded, color: scheme.error),
                        const SizedBox(width: 12),
                        Text(tr('Удалить'), style: TextStyle(color: scheme.error)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _SnapshotAction { restore, delete }

// ============================================================================
//  EMPTY STATE
// ============================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.history_toggle_off_rounded,
                size: 36,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr('Нет сохранённых точек'),
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tr('Создавайте точки восстановления перед\nкрупными изменениями квеста'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
