import 'dart:io';

import 'package:canvas_app/core/services/quest_content_change_bus.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';

/// Подменяет каталог целиком, не оставляя окна, в котором его нет.
///
/// Так ставятся на место восстановленный квест, импортированный `.mnd` и
/// распакованный бэкап. Наивный порядок «удалить старую папку → записать
/// новую» теряет данные, если процесс упадёт между шагами: старой копии уже
/// нет, новой ещё нет.
///
/// Старая папка сначала переименовывается рядом (в пределах одной ФС
/// переименование атомарно), и только после успешной подмены удаляется. Если
/// подмена сорвалась — старое имя возвращается, исключение уходит наружу.
Future<void> replaceDirectoryAtomically({
  required Directory staging,
  required Directory target,
}) async {
  Directory? aside;
  if (await target.exists()) {
    aside = Directory(
      '${target.path}.replaced_${DateTime.now().microsecondsSinceEpoch}',
    );
    await target.rename(aside.path);
  }
  try {
    await staging.rename(target.path);
  } catch (_) {
    if (aside != null && !await target.exists()) {
      try {
        await aside.rename(target.path);
      } catch (_) {
        // Вернуть старое имя не удалось — исходная ошибка важнее.
      }
    }
    rethrow;
  }
  if (aside != null) {
    try {
      await aside.delete(recursive: true);
    } catch (_) {
      // Мусорная папка рядом не должна валить успешную установку.
    }
  }
}

/// Подмена квеста под тем же локом, что и редакторские сохранения.
Future<void> replaceQuestDirectoryAtomically({
  required String questId,
  required Directory staging,
  required Directory target,
  Future<void> Function()? afterReplace,
}) {
  return QuestStore.synchronized(
    'nodes_$questId',
    () => QuestStore.synchronized('config_$questId', () async {
      await replaceDirectoryAtomically(staging: staging, target: target);
      FileStorage.invalidateJsonCache([QuestPaths.questRoot(questId)]);
      try {
        await afterReplace?.call();
      } finally {
        QuestContentChangeBus.instance.markReplaced(questId);
      }
    }),
  );
}
