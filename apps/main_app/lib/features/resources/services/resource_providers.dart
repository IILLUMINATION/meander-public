import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:canvas_app/features/resources/services/quest_storage.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';

/// Конвенции путей и metadata.json конкретного квеста.
final questStorageProvider = Provider.family<QuestStorage, String>(
  (ref, questId) => QuestStorage(questId: questId),
);

/// Единая точка работы с ресурсами квеста (файлы, metadata.json, скрипты,
/// имена, папки). Экраны читают/пишут ресурсы только через этот сервис.
final resourceServiceProvider = Provider.family<ResourceService, String>(
  (ref, questId) =>
      ResourceService(storage: ref.watch(questStorageProvider(questId))),
);

/// Имена ресурсов квеста: `имя файла → имя из metadata.json`. Экранам нужен
/// человек, а не `1790024448511_<uuid>.png`: по такому хвосту два соседних
/// кадра не отличить.
///
/// Потребители берут `.valueOrNull ?? const {}` — подпись не стоит сцены на
/// spinner: пока metadata не прочитана, показываем имя файла.
final questResourceNamesProvider =
    FutureProvider.family<Map<String, String>, String>((ref, questId) async {
      final svc = ref.watch(resourceServiceProvider(questId));
      try {
        await svc.loadNameCache();
      } catch (_) {
        // Хранилище недоступно (пустой квест, тест без моста) — не ошибка
        // экрана: подписываем именами файлов.
        return const {};
      }
      return Map.unmodifiable(svc.nameCache);
    });

/// Текущая папка библиотеки ресурсов квеста.
///
/// Живёт вне `ResourcesScreen`: при выключенном «открывать в новой вкладке»
/// воркспейс заменяет вкладку библиотеки документом, и при возврате из
/// скрипта экран пересоздаётся с чистым состоянием. Без этого «Назад»
/// выбрасывал автора в корень библиотеки вместо папки со скриптом.
final resourcesFolderProvider = StateProvider.family<String, String>(
  (ref, questId) => '/',
);

/// Позиция прокрутки списка ресурсов квеста.
///
/// Тот же сценарий, что и у папки: экран пересоздаётся при возврате из
/// скрипта, и без сохранённой позиции автор, долиставший до конца библиотеки,
/// оказывался в её начале.
final resourcesScrollOffsetProvider = StateProvider.family<double, String>(
  (ref, questId) => 0,
);
