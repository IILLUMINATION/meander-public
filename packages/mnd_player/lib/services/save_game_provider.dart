import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

SaveStore _createFileStore() {
  return JsonFileSaveStore(
    (path) => FileStorage.readJsonFile(path),
    (path, data) => FileStorage.writeJsonFile(path, data),
    (path) => FileStorage.exists(path),
    (path, {extension}) => FileStorage.listFiles(path, extension: extension),
    (path) => FileStorage.delete(path),
  );
}

final saveGameServiceProvider = Provider<SaveGameService>((ref) {
  return SaveGameService(_createFileStore());
});

final saveSlotsProvider = FutureProvider.autoDispose
    .family<List<SaveSlot>, String>((ref, questId) {
      final service = ref.watch(saveGameServiceProvider);
      return service.getSaveSlots(questId);
    });

/// Команда сохранения из скрипта (`save_operation`). Движок не имеет доступа
/// к UI и ФС, поэтому выставляет событие, а экран игры открывает диалог/экран
/// и выполняет операцию через [SaveGameService].
final saveUiCommandProvider = StateProvider<Map<String, dynamic>?>(
  (ref) => null,
);
