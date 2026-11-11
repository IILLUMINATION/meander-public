import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:flutter/material.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:path/path.dart' as p;

import 'local_history_service.dart';

/// Что стало с данными квеста после проверки.
enum QuestDataHealth {
  /// Все JSON-файлы читаются.
  healthy,

  /// Битые файлы были, но данные восстановлены из снимка.
  repaired,

  /// Битые файлы есть, а целых снимков нет — откатывать некуда.
  corrupt,
}

class QuestDataGuardResult {
  final String questId;
  final QuestDataHealth health;

  /// Относительные пути файлов, которые не разобрались как JSON.
  final List<String> brokenFiles;

  /// Снимок повреждённого состояния, снятый перед откатом.
  final String? brokenSnapshot;

  /// Снимок, из которого восстановили данные.
  final SnapshotInfo? restoredSnapshot;

  const QuestDataGuardResult({
    required this.questId,
    required this.health,
    this.brokenFiles = const [],
    this.brokenSnapshot,
    this.restoredSnapshot,
  });

  /// Данные на диске изменились — пользователю стоит об этом сказать.
  bool get changed => health == QuestDataHealth.repaired;
}

/// Страховка данных пользовательских квестов.
///
/// Пользователь открыл квест — а `config.json` или `nodes.json` не разбираются
/// (оборванная запись, поломанная миграция, кривой импорт). Читатели в таком
/// случае либо молча отдают пустой квест, либо показывают его повреждённым,
/// и правки продолжаются поверх мусора.
///
/// Порядок действий:
///  1. проверить все JSON квеста (включая тела нод, скрипты и метаданные
///     ресурсов — они читаются тем же загрузчиком);
///  2. если всё цело — сделать авто-снимок (`LocalHistoryService`;
///     не чаще раза в 10 минут, хранится 10 последних);
///  3. если файлы битые — сначала снять копию повреждённого состояния
///     (`broken_*`, чтобы ничего не потерять), затем найти самый свежий
///     снимок, который целиком разбирается, и восстановить его.
///
/// Решение принимается по содержимому, а не по mtime: у снимков с диска
/// время записи может быть любым.
class QuestDataGuard {
  QuestDataGuard._();

  /// Квесты, уже проверенные в этой сессии. Повторная проверка при каждом
  /// открытии документа (у квеста их десятки) — лишние чтение десятков
  /// файлов; порча внутри живой сессии и так видна редактору по месту.
  static final Set<String> _validated = {};

  /// Квесты, по которым пользователю уже показали сообщение об откате.
  static final Set<String> _notified = {};

  /// Проверки в полёте: редактор и игра могут открыть один квест
  /// одновременно (вкладка игры из редактора) — откат обязан быть один.
  static final Map<String, Future<QuestDataGuardResult>> _inFlight = {};

  @visibleForTesting
  static void resetSessionCache() {
    _validated.clear();
    _notified.clear();
    _inFlight.clear();
  }

  /// Проверяет квест перед открытием редактора или запуском игры.
  static Future<QuestDataGuardResult> protect(
    String questId, {
    bool allowRollback = true,
    bool snapshot = true,
  }) {
    final running = _inFlight[questId];
    if (running != null) return running;
    final future = _protect(
      questId,
      allowRollback: allowRollback,
      snapshot: snapshot,
    );
    _inFlight[questId] = future;
    return future.whenComplete(() => _inFlight.remove(questId));
  }

  static Future<QuestDataGuardResult> _protect(
    String questId, {
    required bool allowRollback,
    required bool snapshot,
  }) async {
    final result = _validated.contains(questId)
        ? QuestDataGuardResult(
            questId: questId,
            health: QuestDataHealth.healthy,
          )
        : await _inspectAndHeal(questId, allowRollback: allowRollback);

    // Снимок делается и после отката: восстановленное состояние — новая
    // исходная точка, а повреждённую копию будет с чего сравнить.
    if (snapshot) {
      // Снимок не должен ронять открытие квеста: нет прав на запись,
      // квест слишком большой, диск полон — это шум в логе, а не отказ.
      unawaited(
        LocalHistoryService.autoSnapshotOnOpen(questId).catchError((
          Object error,
          StackTrace stack,
        ) {
          debugPrint('[QuestGuard] авто-снимок $questId пропущен: $error');
          return null;
        }),
      );
    }
    return result;
  }

  static Future<QuestDataGuardResult> _inspectAndHeal(
    String questId, {
    required bool allowRollback,
  }) async {
    final root = Directory(
      await FileStorage.getFilePath(QuestPaths.questRoot(questId)),
    );
    if (!await root.exists()) {
      return QuestDataGuardResult(
        questId: questId,
        health: QuestDataHealth.healthy,
      );
    }

    final broken = await findBrokenJsonFiles(root);
    if (broken.isEmpty) {
      _validated.add(questId);
      return QuestDataGuardResult(
        questId: questId,
        health: QuestDataHealth.healthy,
      );
    }

    print('🛟 [QuestGuard] Повреждены файлы квеста $questId: $broken');
    if (!allowRollback) {
      return QuestDataGuardResult(
        questId: questId,
        health: QuestDataHealth.corrupt,
        brokenFiles: broken,
      );
    }

    final brokenSnapshot = await LocalHistoryService.snapshotBroken(questId);

    for (final snapshot in await LocalHistoryService.listSnapshots(questId)) {
      if (snapshot.fileName == brokenSnapshot) continue;
      if (!await _snapshotIsIntact(questId, snapshot.fileName)) continue;
      try {
        await LocalHistoryService.restoreSnapshot(questId, snapshot.fileName);
      } catch (error) {
        print(
          '⚠️ [QuestGuard] Откат на ${snapshot.fileName} не удался: $error',
        );
        continue;
      }
      final stillBroken = await findBrokenJsonFiles(root);
      if (stillBroken.isEmpty) {
        _validated.add(questId);
        print('✅ [QuestGuard] Квест $questId восстановлен: ${snapshot.fileName}');
        return QuestDataGuardResult(
          questId: questId,
          health: QuestDataHealth.repaired,
          brokenFiles: broken,
          brokenSnapshot: brokenSnapshot,
          restoredSnapshot: snapshot,
        );
      }
      print(
        '⚠️ [QuestGuard] Снимок ${snapshot.fileName} тоже битый: $stillBroken',
      );
    }

    return QuestDataGuardResult(
      questId: questId,
      health: QuestDataHealth.corrupt,
      brokenFiles: broken,
      brokenSnapshot: brokenSnapshot,
    );
  }

  /// Все JSON-файлы квеста, которые не разбираются.
  ///
  /// Каталог `_history` пропускается: снимки лежат в zip и проверяются
  /// отдельно. Пустой `config.json` — это тоже порча (без конфига квест
  /// не открывается), пустой файл нод — законное состояние нового квеста.
  static Future<List<String>> findBrokenJsonFiles(Directory root) async {
    if (!await root.exists()) return const [];
    final broken = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p
          .relative(entity.path, from: root.path)
          .replaceAll('\\', '/');
      if (relative.startsWith('${LocalHistoryService.historyFolder}/')) {
        continue;
      }
      if (!relative.toLowerCase().endsWith('.json')) continue;
      // `.backup` не заканчивается на `.json`, но легаси-копии конфига
      // (config.json.backup) не читаются загрузчиком — их не проверяем.
      if (!await _jsonIsReadable(entity, relative)) broken.add(relative);
    }
    broken.sort();
    return broken;
  }

  static Future<bool> _jsonIsReadable(File file, String relative) async {
    String text;
    try {
      text = await file.readAsString();
    } catch (_) {
      return false;
    }
    if (text.trim().isEmpty) {
      // config.json обязан быть объектом; пустой nodes.json — норма.
      return relative != 'config.json';
    }
    try {
      final decoded = jsonDecode(text);
      if (relative == 'config.json') return decoded is Map;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Снимок пригоден к откату, если внутри есть `config.json`-объект и
  /// каждый JSON-файл разбирается. Проверяется содержимое zip, файлы на
  /// диске не трогаются.
  /// true, если сообщение по квесту ещё не показывали.
  static bool markNotified(String questId) => _notified.add(questId);

  static Future<bool> _snapshotIsIntact(
    String questId,
    String fileName,
  ) async {
    try {
      final historyDir = await FileStorage.getFilePath(
        QuestPaths.questFile(questId, LocalHistoryService.historyFolder),
      );
      final file = File(p.join(historyDir, fileName));
      if (!await file.exists()) return false;

      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      var configOk = false;
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final name = entry.name;
        if (name.startsWith('${LocalHistoryService.historyFolder}/')) continue;
        if (!name.toLowerCase().endsWith('.json')) continue;
        final data = entry.content as List<int>;
        final text = utf8.decode(data, allowMalformed: true);
        if (text.trim().isEmpty) {
          if (name == 'config.json') return false;
          continue;
        }
        try {
          final decoded = jsonDecode(text);
          if (name == 'config.json') {
            if (decoded is! Map) return false;
            configOk = true;
          }
        } catch (_) {
          return false;
        }
      }
      return configOk;
    } catch (_) {
      return false;
    }
  }
}
/// Сообщает пользователю, что квест был повреждён и откатён. Молчит, если
/// данные целы.
Future<void> notifyQuestDataProtection(
  BuildContext context,
  QuestDataGuardResult result,
) async {
  if (!result.changed && result.health != QuestDataHealth.corrupt) return;
  // Один квест открывают несколько экранов (шелл, документ, игра) —
  // сообщение показываем один раз за сессию.
  if (!QuestDataGuard.markNotified(result.questId)) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final message = result.health == QuestDataHealth.repaired
      ? trf(
          'Квест был повреждён — восстановлена резервная копия от {p0}',
          {
            'p0': formatQuestGuardTime(result.restoredSnapshot!.timestamp),
          },
        )
      : trf(
          'Квест повреждён, а целых резервных копий нет. Битые файлы: {p0}',
          {'p0': result.brokenFiles.join(', ')},
        );
  messenger.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 8)),
  );
}

/// "12 мая 2025, 18:30" — время снимка в сообщении об откате.
String formatQuestGuardTime(DateTime time) {
  final local = time.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${formatDayMonthYear(local)}, $hh:$mm';
}
