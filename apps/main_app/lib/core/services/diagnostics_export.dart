import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

/// Отдать текстовый файл наружу: на мобильных — системный «поделиться»,
/// на десктопе — «сохранить как».
///
/// Общий путь для логов и записи сессии тестировщика. `share_plus` на
/// десктопе файлы не отдаёт (Linux кидает `UnimplementedError`), поэтому там
/// используется файловый диалог — тот же, что у экспорта `.mnd`.
///
/// Возвращает путь сохранённого файла или `null`, если пользователь отменил
/// диалог. Мобильная ветка возвращает пустую строку: файл ушёл в шеринг,
/// пути у нас нет.
class DiagnosticsExport {
  DiagnosticsExport._();

  static Future<String?> saveOrShareText({
    required String fileName,
    required String content,
    required String shareSubject,
  }) async {
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (desktop) {
      final uri = await FilePicker.saveFile(
        dialogTitle: shareSubject,
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(content)),
        type: FileType.custom,
        allowedExtensions: [fileName.split('.').last],
      );
      return uri?.toFilePath() ?? uri?.toString();
    }

    final xFile = await _writeTemp(fileName, content);
    await Share.shareXFiles([xFile], text: shareSubject);
    return '';
  }

  static Future<XFile> _writeTemp(String fileName, String content) async {
    final dir = Directory.systemTemp.createTempSync('mnd_export_');
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(content, flush: true);
    return XFile(file.path);
  }
}
