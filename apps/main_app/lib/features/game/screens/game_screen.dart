import 'dart:async';

import 'package:canvas_app/core/services/hang_watchdog.dart';
import 'package:canvas_app/core/services/quest_safety_service.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/editor/screens/node_content_screen.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/game/providers/game_screen_provider.dart';
import 'package:canvas_app/features/game/widgets/quest_safety_warning_dialog.dart';
import 'package:canvas_app/features/plugins/providers/plugin_registry_provider.dart';
import 'package:canvas_app/features/plugins/screens/plugin_manager_screen.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/models/save_slot_model.dart';
import 'package:canvas_app/plugin_host/plugin_host_provider.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_player/screens/game_screen.dart' as player;
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

/// Игровой экран main_app — тонкая обёртка над единым [player.GameScreen].
///
/// Вся отрисовка и движковая логика живут в mnd_player; здесь подключаются
/// app-специфичные сервисы: ключ игровой сессии (вкладка workspace),
/// preflight (проверка плагинов + safety-аудит), выход из вкладки и
/// «Редактировать ноду».
class GameScreen extends ConsumerStatefulWidget {
  final String questId;
  final String? startNodeId;
  final bool isOnboarding;
  final SaveSlot? saveSlot;
  final bool isTesting;

  const GameScreen({
    super.key,
    required this.questId,
    this.startNodeId,
    this.isOnboarding = false,
    this.saveSlot,
    this.isTesting = false,
  });

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen> {
  static int _routeSessionCounter = 0;

  /// Ключ игровой сессии: документ вкладки в workspace, иначе route-only токен.
  late final GameSessionKey _sessionKey;

  @override
  void initState() {
    super.initState();
    final document = context
        .getInheritedWidgetOfExactType<EditorDocumentContext>();
    _sessionKey = (
      questId: widget.questId,
      docKey: document?.id.persistenceKey ?? 'route:${_routeSessionCounter++}',
    );
    if (const bool.fromEnvironment('dart.vm.product') == false) {
      final st = StackTrace.current.toString().split('\n').take(10).join(' | ');
      // ignore: avoid_print
      print(
        '🎮 [GameScreen][main_app] initState session=$_sessionKey docId=${document?.id.persistenceKey} routeCounter=$_routeSessionCounter hash=${hashCode} stack=$st',
      );
    }
  }

  @override
  void dispose() {
    if (const bool.fromEnvironment('dart.vm.product') == false) {
      final st = StackTrace.current.toString().split('\n').take(14).join('\n');
      // ignore: avoid_print
      print(
        '🎮 [GameScreen][main_app] dispose session=$_sessionKey hash=${hashCode}\nStack:\n$st',
      );
    }
    super.dispose();
  }

  Future<bool> _preflight() async {
    if (!mounted) return false;
    HangWatchdog.mark('game init: post-frame');

    // Предупреждение показываем только в настоящем игровом режиме. Тестовый
    // запуск из редактора и debug-сессии не должны блокироваться модалками.
    if (!widget.isTesting) {
      try {
        final quest = await ref.read(questProvider(widget.questId).future);
        if (!mounted) return false;
        HangWatchdog.mark('game init: quest loaded');
        if (quest != null) {
          final report = await const QuestSafetyService().inspect(
            quest: quest,
            api: ref.read(apiServiceProvider),
          );
          if (!mounted) return false;
          HangWatchdog.mark('game init: safety inspected');
          await showQuestSafetyWarning(context, quest: quest, report: report);
          if (!mounted) return false;
          HangWatchdog.mark('game init: safety dialog closed');
        }
      } catch (error, stack) {
        // Safety-аудит не должен блокировать запуск локального квеста:
        // реальные URL всё равно проверяются fail-closed в runtime.
        debugPrint('[QuestSafety] аудит пропущен: $error\n$stack');
      }
    }

    final canStart = await _ensureQuestPluginDependencies();
    if (!canStart || !mounted) return false;
    HangWatchdog.mark('game init: plugin deps ok');
    ref
        .read(pluginHostProvider)
        .onQuestStart(widget.questId, fromSave: widget.saveSlot != null);
    HangWatchdog.mark('game init: plugin started');
    return true;
  }

  Future<bool> _ensureQuestPluginDependencies() async {
    final deps = await _collectQuestPluginDependencies();
    if (deps.isEmpty) return true;

    final plugins = await ref.read(pluginRegistryProvider.future);
    final registry = {for (final entry in plugins) entry.id: entry};
    final missing = <String>[];
    final disabled = <String>[];

    for (final id in deps) {
      final entry = registry[id];
      if (entry == null) {
        missing.add(id);
      } else if (!entry.enabled) {
        disabled.add(id);
      }
    }

    if (missing.isEmpty && disabled.isEmpty) return true;

    if (!mounted) return false;
    final action = await showAppDialog<_PluginDependencyAction>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text(
            tr('Квест использует плагины'),
            style: TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (missing.isNotEmpty) ...[
                  Text(
                    tr('Не установлены:'),
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  ...missing.map(
                    (id) => Text(
                      '• $id',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (disabled.isNotEmpty) ...[
                  Text(
                    tr('Отключены:'),
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  ...disabled.map(
                    (id) => Text(
                      '• $id',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(
                ctx,
              ).pop(_PluginDependencyAction.continueWithout),
              child: Text(tr('Продолжить без')),
            ),
            if (disabled.isNotEmpty)
              ElevatedButton(
                onPressed: () =>
                    Navigator.of(ctx).pop(_PluginDependencyAction.enable),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00C853),
                  foregroundColor: Colors.black,
                ),
                child: Text(tr('Включить')),
              ),
            if (missing.isNotEmpty)
              ElevatedButton(
                onPressed: () =>
                    Navigator.of(ctx).pop(_PluginDependencyAction.manage),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2A2A2A),
                  foregroundColor: Colors.white,
                ),
                child: Text(tr('Импортировать')),
              ),
          ],
        );
      },
    );

    if (!mounted) return false;
    switch (action) {
      case _PluginDependencyAction.enable:
        final notifier = ref.read(pluginRegistryProvider.notifier);
        for (final id in disabled) {
          await notifier.togglePlugin(id, true);
        }
        return true;
      case _PluginDependencyAction.manage:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => PluginManagerScreen()));
        return true;
      case _PluginDependencyAction.continueWithout:
        return true;
      case _PluginDependencyAction.cancel:
      default:
        return false;
    }
  }

  Future<Set<String>> _collectQuestPluginDependencies() async {
    final configPath = QuestPaths.config(widget.questId);
    if (await FileStorage.exists(configPath)) {
      try {
        final config = await FileStorage.readJsonFile(configPath);
        final list = config['pluginDependencies'];
        if (list is List && list.isNotEmpty) {
          return list.map((e) => e.toString()).toSet();
        }
      } catch (_) {}
    }
    return _collectDependenciesFromNodes();
  }

  Future<Set<String>> _collectDependenciesFromNodes() async {
    try {
      final nodesData = await QuestNodesStore.read(widget.questId);
      final nodes = nodesData['nodes'] as List<dynamic>? ?? const [];
      final deps = <String>{};
      for (final raw in nodes) {
        if (raw is! Map) continue;
        final content = raw['content'];
        if (content is! Map) continue;
        final items = content['items'];
        if (items is! List) continue;
        for (final item in items) {
          _collectDepsFromItem(item, deps);
        }
      }
      return deps;
    } catch (_) {
      return {};
    }
  }

  void _collectDepsFromItem(dynamic raw, Set<String> deps) {
    if (raw is! Map) return;
    final type = raw['type']?.toString();
    if (type == 'plugin') {
      final pluginId = raw['pluginId']?.toString().trim();
      if (pluginId != null && pluginId.isNotEmpty) {
        deps.add(pluginId);
      }
    }
    final children = raw['children'];
    if (children is List) {
      for (final child in children) {
        _collectDepsFromItem(child, deps);
      }
    }
  }

  Future<void> _editCurrentNode() async {
    final screenState = ref.read(gameScreenProvider(_sessionKey));
    final currentNode = screenState.currentNode;
    if (currentNode == null) return;
    final currentNodeId = currentNode.id;

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => NodeContentScreen(
          questId: widget.questId,
          nodeId: currentNodeId,
          fromGameSession: true,
        ),
      ),
    );

    if (mounted) {
      if (result == false) return;
      // Если игровую вкладку закрыли, пока редактор был открыт, провайдер
      // сессии уже уничтожен — перезагрузка не нужна (и создание нового
      // экземпляра через read только завёл бы лишний движок).
      final container = ProviderScope.containerOf(context, listen: false);
      if (!container.exists(gameScreenProvider(_sessionKey))) return;
      await ref
          .read(gameScreenProvider(_sessionKey).notifier)
          .reloadNodeAfterEditor(currentNodeId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return player.GameScreen(
      questId: widget.questId,
      docKey: _sessionKey.docKey,
      startNodeId: widget.startNodeId,
      isOnboarding: widget.isOnboarding,
      saveSlot: widget.saveSlot,
      isTesting: widget.isTesting,
      preflight: _preflight,
      onEditNode: widget.isTesting ? _editCurrentNode : null,
      onExit: () async {
        // Автосейв делает базовый экран; здесь — закрытие вкладки workspace
        // либо pop в route-only режиме.
        if (!mounted) return;
        final document = EditorDocumentContext.maybeOf(context);
        final workspace = EditorWorkspaceScope.maybeOf(context);
        if (document != null && workspace != null) {
          await workspace.closeDocument(document.id);
        } else if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
    );
  }
}

enum _PluginDependencyAction { enable, manage, continueWithout, cancel }
