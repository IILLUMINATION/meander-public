import 'dart:io';

import 'package:canvas_app/features/plugins/models/plugin_entry.dart';
import 'package:canvas_app/features/plugins/providers/plugin_registry_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

// ============================================================================
//  ПЛАГИНЫ — Material You / Material 3 редизайн
// ============================================================================

class PluginManagerScreen extends ConsumerWidget {
  const PluginManagerScreen({super.key});

  Future<void> _importPlugin(BuildContext context, WidgetRef ref) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip', 'plugin', 'json', 'yaml', 'yml'],
    );
    if (files.isEmpty) return;

    final path = files.single.path;
    if (path == null) {
      _showSnack(context, tr('Не удалось получить путь к файлу.'));
      return;
    }

    try {
      await ref
          .read(pluginRegistryProvider.notifier)
          .importPluginFile(File(path));
    } catch (e) {
      _showSnack(context, trf('Ошибка импорта: {e}', {'e': e}));
    }
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final pluginsAsync = ref.watch(pluginRegistryProvider);

    return Scaffold(
      body: AdaptiveContent(
        maxWidth: 900,
        child: SafeArea(
          bottom: false,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverAppBar.large(
                title: Text(tr('Плагины')),
                // Прозрачная подложка пропускала контент списка сквозь
                // крупный заголовок — строки рисовались поверх него.
                backgroundColor: scheme.surface,
                surfaceTintColor: Colors.transparent,
                scrolledUnderElevation: 0,
                actions: [
                  IconButton(
                    tooltip: tr('Импортировать плагин'),
                    icon: const Icon(Icons.file_upload_outlined),
                    onPressed: () => _importPlugin(context, ref),
                  ),
                  const SizedBox(width: 4),
                ],
              ),

              // Описание + кнопка импорта
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    tr('Управляйте установленными плагинами и включайте нужные.'),
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                sliver: SliverToBoxAdapter(
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: () => _importPlugin(context, ref),
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      label: Text(tr('Импортировать плагин')),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Список
              pluginsAsync.when(
                loading: () => const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => SliverFillRemaining(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        trf('Ошибка загрузки: {error}', {'error': error}),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ),
                ),
                data: (plugins) {
                  if (plugins.isEmpty) {
                    return SliverFillRemaining(
                      child: _EmptyBlock(
                        icon: Icons.extension_outlined,
                        text: tr('Плагины не установлены'),
                      ),
                    );
                  }
                  final enabledCount = plugins
                      .where((plugin) => plugin.enabled)
                      .length;
                  return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                    sliver: SliverList.separated(
                      itemCount: plugins.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return _StatBanner(
                            enabledCount: enabledCount,
                            total: plugins.length,
                          );
                        }
                        final plugin = plugins[index - 1];
                        return _PluginCard(
                          plugin: plugin,
                          onToggle: (v) => ref
                              .read(pluginRegistryProvider.notifier)
                              .togglePlugin(plugin.id, v),
                          onRemove: () => ref
                              .read(pluginRegistryProvider.notifier)
                              .removePlugin(plugin.id),
                        );
                      },
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  СТАТУСНЫЙ БАННЕР
// ============================================================================

class _StatBanner extends StatelessWidget {
  final int enabledCount;
  final int total;
  const _StatBanner({required this.enabledCount, required this.total});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.secondaryContainer],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.surface.withOpacity(0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.extension_rounded,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trf('Активные: {enabledCount} / {total}', {'enabledCount': enabledCount, 'total': total}),
                  style: textTheme.titleMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  tr('Плагин — это папка с plugin.json и Lua-скриптом. Включённые плагины исполняются в песочнице прямо на игровом экране.'),
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer.withOpacity(0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  КАРТОЧКА ПЛАГИНА
// ============================================================================

class _PluginCard extends StatelessWidget {
  final PluginEntry plugin;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;

  const _PluginCard({
    required this.plugin,
    required this.onToggle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final fileName = p.basename(plugin.localPath);

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: plugin.enabled
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.extension_rounded,
                color: plugin.enabled
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    plugin.name,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${plugin.id} · ${plugin.version}',
                    style: textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    fileName,
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withOpacity(0.8),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Switch(value: plugin.enabled, onChanged: onToggle),
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert_rounded,
                color: scheme.onSurfaceVariant,
              ),
              onSelected: (value) {
                if (value == 'remove') onRemove();
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'remove',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded, color: scheme.error),
                      const SizedBox(width: 8),
                      Text(tr('Удалить')),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  ПУСТОЙ СТЕЙТ
// ============================================================================

class _EmptyBlock extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyBlock({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 72,
              color: scheme.onSurfaceVariant.withOpacity(0.6),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
