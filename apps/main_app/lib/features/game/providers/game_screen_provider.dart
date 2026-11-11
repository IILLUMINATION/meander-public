// Хуки для единого `gameScreenProvider` из mnd_player: пробрасывают
// main_app-специфичные сервисы (crash-логи, watchdog, live-reload, safety,
// playtime). Вся core-логика (engine, audio, reveal, timers) живёт в
// mnd_player. bootstrap.dart переопределяет `gameScreenHooksProvider` этим
// провайдером — тогда виджеты (HUD, контент, таймер) обращаются к тому же
// нотификатору, что и экран.

import 'package:canvas_app/core/services/crash_log_service.dart';
import 'package:canvas_app/core/services/hang_watchdog.dart';
import 'package:canvas_app/core/services/playtime_service.dart';
import 'package:canvas_app/core/services/quest_shot_export.dart';
import 'package:canvas_app/core/services/quest_shot_service.dart';
import 'package:canvas_app/core/services/quest_content_change_bus.dart';
import 'package:canvas_app/core/services/quest_safety_service.dart';
import 'package:canvas_app/features/plugins/providers/plugin_content_types_provider.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/features/plugins/providers/plugin_registry_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';

// Реэкспорт для обратной совместимости.
export 'package:mnd_player/providers/game_screen_provider.dart'
    show GameScreenNotifier, GameScreenState, GameScreenHooks;
export 'package:mnd_player/providers/game_screen_provider.dart'
    show GameSessionKey, gameScreenProvider, gameScreenHooksProvider;

/// main_app-версия хуков: watchdog, crash-логи, live-reload, safety,
/// playtime-трекинг. Переопределяется в корневом ProviderScope.
final appGameScreenHooksProvider = Provider<GameScreenHooks>((ref) {
  return GameScreenHooks(
    onStep: (step) => HangWatchdog.mark(step),
    onError: (e, s, ctx) => CrashLogService.handle(e, s, ctx),
    listenContentChanges: (questId, cb) =>
        QuestContentChangeBus.instance.listen(questId, cb),
    unlistenContentChanges: (questId, cb) =>
        QuestContentChangeBus.instance.unlisten(questId, cb),
    isUrlSafe: (url) => QuestNetworkSafety.checkUrl(url).allowed,
    onGameSessionStarted: (questId) =>
        ref.read(playtimeServiceProvider).setActiveQuest(questId),
    onGameSessionEnded: (questId) =>
        ref.read(playtimeServiceProvider).setActiveQuest(null),
    // Снимок уже собран плеером (карточка с подписью) — остаётся положить
    // файл в квест и дописать config.
    onScreenshot: (questId, png) async {
      await saveQuestShot(questId, png);
    },
    // Экспорт наружу: системный диалог/шторка, файл квеста не трогаем.
    onExportScreenshot: (questId, png) async {
      final quest = await ref.read(questProvider(questId).future);
      return exportQuestShot(png, questTitle: quest?.title);
    },
    // Rust-хост понимает только новый формат пакета: `plugin.json` + Lua.
    // Старые установки с `plugin.yaml` сюда не доходят — плагин просто
    // не ставится, а квест играется без него.
    listPluginPackages: () async {
      final registry = await ref.read(pluginRegistryProvider.future);
      return enabledPluginPackageDirs(registry);
    },
  );
});
