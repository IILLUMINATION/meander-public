// ============================================================================
//  Единый реестр путей каталога квеста (план 020-C6).
//
//  Регрессия-мотивация: ~284 строковых литерала 'quests/...' в 83 файлах,
//  включая рассинхрон ('nodes.json' vs 'nodes/nodes.json'). Любое изменение
//  схемы каталогов = ручной аудит. Все пути квеста — ТОЛЬКО отсюда.
//
//  Все пути — относительно корня документов приложения (каталог, который
//  возвращает FileStorage.getAppDirectory()). Пути не содержат ведущего '/'.
// ============================================================================

/// Единый реестр относительных путей каталога квеста.
///
/// Пути не зависят от платформы (чистые строковые функции), поэтому живут
/// в ядре и доступны всем пакетам: mnd_core, mnd_player и canvas_app.
class QuestPaths {
  QuestPaths._();

  /// Корневой каталог всех квестов.
  static const String questsDir = 'quests';

  /// Корень каталога квеста: `quests/<questId>`.
  static String questRoot(String questId) => 'quests/$questId';

  /// Основной конфиг квеста.
  static String config(String questId) => 'quests/$questId/config.json';

  /// Резервная копия конфига (пишется рядом при восстановлении).
  static String configBackup(String questId) =>
      'quests/$questId/config.json.backup';

  /// Каталог нод.
  static String nodesDir(String questId) => 'quests/$questId/nodes';

  /// Канонический файл нод — `nodes/nodes.json` (так пишет импорт).
  static String nodesCanonical(String questId) =>
      'quests/$questId/nodes/nodes.json';

  /// Легаси-файл нод — `nodes.json` (фактически использует редактор).
  static String nodesLegacy(String questId) => 'quests/$questId/nodes.json';

  /// Индекс per-node формата: лёгкие метаданные для канваса, группы,
  /// комментарии и рёбра. Тела нод лежат рядом, в [nodeBody].
  static String nodesIndex(String questId) =>
      'quests/$questId/nodes/index.json';

  /// Тело одной ноды per-node формата.
  static String nodeBody(String questId, String nodeId) =>
      'quests/$questId/nodes/$nodeId.json';

  /// Бэкап монолита перед миграцией на per-node формат.
  static String nodesMigrationBackup(String questId) =>
      'quests/$questId/nodes.json.v1_backup';

  /// Оба возможных расположения файла нод — порядок совпадает с приоритетом
  /// загрузчика в ядре (канонический → легаси).
  static List<String> nodesCandidates(String questId) => [
        nodesCanonical(questId),
        nodesLegacy(questId),
      ];

  /// Каталог визуальных скриптов (канонический).
  static String scriptsDir(String questId) => 'quests/$questId/scripts';

  /// Каталог внутренних скриптов (легаси, читаем, новые не создаём).
  static String internalScriptsDir(String questId) =>
      'quests/$questId/_internal_scripts';

  /// Путь скрипта в каталоге scripts (добавляет `.json` при необходимости).
  static String scriptFile(String questId, String fileName) =>
      '${scriptsDir(questId)}/${_withJson(fileName)}';

  /// Путь скрипта во внутреннем каталоге (добавляет `.json` при необходимости).
  static String internalScriptFile(String questId, String fileName) =>
      '${internalScriptsDir(questId)}/${_withJson(fileName)}';

  /// Путь файла в каталоге scripts без нормализации расширения
  /// (для `.lua` и других не-JSON ресурсов).
  static String scriptPath(String questId, String fileName) =>
      '${scriptsDir(questId)}/$fileName';

  /// Оба возможных расположения скрипта по имени файла/id — порядок
  /// совпадает с приоритетом загрузчика в ядре (scripts → internal).
  static List<String> scriptCandidates(String questId, String name) => [
        scriptFile(questId, name),
        internalScriptFile(questId, name),
      ];

  /// Ресурсный каталог.
  static String resDir(String questId) => 'quests/$questId/res';

  static String resImagesDir(String questId) => 'quests/$questId/res/images';
  static String resAudioDir(String questId) => 'quests/$questId/res/audio';
  static String resVideosDir(String questId) => 'quests/$questId/res/videos';
  static String resFontsDir(String questId) => 'quests/$questId/res/fonts';
  static String resScreenshotsDir(String questId) =>
      'quests/$questId/res/screenshots';

  static String resImage(String questId, String fileName) =>
      '${resImagesDir(questId)}/$fileName';
  static String resAudio(String questId, String fileName) =>
      '${resAudioDir(questId)}/$fileName';
  static String resVideo(String questId, String fileName) =>
      '${resVideosDir(questId)}/$fileName';
  static String resFont(String questId, String fileName) =>
      '${resFontsDir(questId)}/$fileName';
  static String resScreenshot(String questId, String fileName) =>
      '${resScreenshotsDir(questId)}/$fileName';

  /// Метаданные ресурсов.
  static String metadata(String questId) => 'quests/$questId/res/metadata.json';

  /// Пресеты кнопок (ресурс квеста).
  static String buttonPresets(String questId) =>
      'quests/$questId/res/button_presets.json';

  /// Каталог шаблонов.
  static String templates(String questId) =>
      'quests/$questId/res/templates.json';

  /// Папка сохранений.
  static String savesDir(String questId) => 'quests/$questId/saves';

  /// Файл слота сохранения.
  static String saveSlot(String questId, String slotId) =>
      'quests/$questId/saves/$slotId.json';

  /// Превью квеста (фолбэк, когда previewFileName не задан).
  static String preview(String questId) => 'quests/$questId/preview.png';

  /// Сессия воркспейса редактора (живёт внутри квеста, в .mnd не попадает).
  static String editorSession(String questId) =>
      'quests/$questId/editor_session.json';

  /// Произвольный файл внутри каталога квеста.
  static String questFile(String questId, String relative) =>
      'quests/$questId/$relative';

  /// true, если путь уже относительный к корню документов (`quests/...`).
  static bool isQuestPath(String path) => path.startsWith('quests/');

  static String _withJson(String name) =>
      name.endsWith('.json') ? name : '$name.json';
}
