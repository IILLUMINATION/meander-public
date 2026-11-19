import 'dart:io';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:share_plus/share_plus.dart';

/// Чем закончилась быстрая отправка `.mnd`.
enum QuestMndShareResult {
  /// Системная шторка «Поделиться» отработала.
  shared,

  /// Платформа не умеет файлы в share_plus — файл сохранён диалогом.
  saved,

  /// Автор закрыл шторку или диалог.
  cancelled,
}

/// «Отправить .mnd»: собрать архив и сразу открыть системную шторку.
///
/// Отличается от [ExportService.exportQuestAsMnd] только последним шагом:
/// на Android/iOS/macOS файл уходит в мессенджеры и почту, а не в диалог
/// «Сохранить как». На Linux/Windows share_plus файлы не поддерживает,
/// поэтому там остаётся обычный диалог сохранения.
class QuestMndShare {
  const QuestMndShare._();

  /// Умеет ли платформа отдавать файл в системную шторку. На десктопе
  /// (Linux/Windows) `share_plus` файлы не поддерживает — там будет диалог
  /// сохранения, и UI честно пишет об этом в подзаголовке.
  static bool get canShareFiles =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  static Future<QuestMndShareResult> shareQuest(
    String questId,
    String questTitle, {
    bool includeSaves = false,
    bool isProtected = false,
  }) async {
    final tempFile = await ExportService.createMndTempFile(
      questId,
      includeSaves: includeSaves,
      isProtected: isProtected,
    );
    try {
      return await shareTempFile(
        tempFile,
        questTitle,
        canShareFiles: canShareFiles,
      );
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
    }
  }

  /// Отдать уже собранный `.mnd` системе. Вынесено из [shareQuest], чтобы
  /// можно было проверить параметры шторки без настоящего квеста и движка.
  static Future<QuestMndShareResult> shareTempFile(
    File tempFile,
    String questTitle, {
    required bool canShareFiles,
  }) async {
    if (!canShareFiles) {
      final saved = await ExportService.saveMndFileFromTemp(
        tempFile,
        questTitle,
      );
      return saved ? QuestMndShareResult.saved : QuestMndShareResult.cancelled;
    }

    final safeTitle = questTitle.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_');
    final fileName = '$safeTitle.mnd';
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            tempFile.path,
            mimeType: 'application/octet-stream',
            name: fileName,
          ),
        ],
        fileNameOverrides: [fileName],
        subject: questTitle,
        text: tr(
          'Квест «{questTitle}» в Meander',
        ).replaceAll('{questTitle}', questTitle),
      ),
    );
    if (result.status == ShareResultStatus.dismissed) {
      return QuestMndShareResult.cancelled;
    }
    if (result.status == ShareResultStatus.unavailable) {
      // Платформа объявила себя «умеющей», но шторки нет — не теряем
      // готовый файл и отдаём его обычному сохранению.
      final saved = await ExportService.saveMndFileFromTemp(
        tempFile,
        questTitle,
      );
      return saved ? QuestMndShareResult.saved : QuestMndShareResult.cancelled;
    }
    return QuestMndShareResult.shared;
  }
}
