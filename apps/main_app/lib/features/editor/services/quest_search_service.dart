import 'package:mnd_core/engine/quest_search.dart' as core;
import 'package:mnd_player/utils/file_storage.dart';

export 'package:mnd_core/engine/quest_search.dart'
    show QuestSearchHit, QuestSearchKind, QuestSearchReport;

/// Поиск по всему квесту: ноды, скрипты (визуальные и Lua), таблицы,
/// переменные, ресурсы.
///
/// Обход файлов и сопоставление живут в Rust (`mnd_core::quest_search`):
/// раньше Dart-сервис читал тела нод по одной на каждый символ запроса.
/// Здесь остаётся только путь к хранилищу и вызов моста.
class QuestSearchService {
  QuestSearchService({required this.questId});

  final String questId;

  /// Сколько результатов показывать в каждой группе.
  static const int limitPerKind = 12;

  /// Полный отчёт: попадания, счётчики по видам и время поиска.
  Future<core.QuestSearchReport> search(String rawQuery) async {
    final appDir = await FileStorage.getAppDirectory();
    return core.searchQuest(
      questId: questId,
      questRoot: appDir.path,
      query: rawQuery.trim(),
      limitPerKind: limitPerKind,
    );
  }
}
