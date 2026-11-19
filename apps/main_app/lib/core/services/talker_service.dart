import 'package:flutter/foundation.dart'; // Нужно для kDebugMode
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/diagnostics_export.dart';

/// Глобальный инстанс Talker
final talker = TalkerFlutter.init(
  settings: TalkerSettings(
    // --- ИСПРАВЛЕНИЕ ---
    // Talker будет включен ТОЛЬКО если это НЕ дебаг режим.
    // В Debug режиме он отключится, и логи будут нормально видны в консоли VS Code
    // благодаря parent.print в main.dart.
    enabled: !kDebugMode,

    maxHistoryItems: 1000,

    // Оставляем false, так как в main.dart есть свой перехватчик print,
    // и мы не хотим дублирования в релизе.
    useConsoleLogs: false,
  ),
);

final talkerProvider = Provider((ref) => talker);

class TalkerExportService {
  static Future<void> exportAndShareLogs(BuildContext context) async {
    try {
      final history = talker.history;
      final StringBuffer buffer = StringBuffer();

      buffer.writeln('=== MEANDER APP LOGS ===');
      buffer.writeln('Generated: ${DateTime.now()}');
      buffer.writeln('Total logs: ${history.length}');
      buffer.writeln('========================\n');

      for (final log in history) {
        buffer.writeln(log.generateTextMessage());
        buffer.writeln('-' * 20);
      }

      final fileName =
          'meander_logs_${DateTime.now().millisecondsSinceEpoch}.txt';
      // Единый путь с записью сессии: на мобильных — «поделиться», на
      // десктопе — файловый диалог (share_plus файлы там не отдаёт).
      final saved = await DiagnosticsExport.saveOrShareText(
        fileName: fileName,
        content: buffer.toString(),
        shareSubject: tr('Логи приложения Meander'),
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved == null
                  ? tr('Сохранение отменено')
                  : trf('Логи сохранены: {saved}', {'saved': saved}),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e, st) {
      // Используем handle, он безопасен
      talker.handle(e, st, 'Ошибка экспорта логов');
    }
  }
}
