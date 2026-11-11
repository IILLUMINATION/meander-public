import 'dart:io';
import 'dart:typed_data';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

// ============================================================================
//  Экспорт снимка квеста наружу
//
//  «Экспортировать» в превью снимка: на десктопе — системный «сохранить как»,
//  на телефоне — системная шторка поделиться. share_plus на Linux/Windows/
//  macOS файлы не отдаёт (UnimplementedError), поэтому там только диалог —
//  как у экспорта логов и `.mnd`.
// ============================================================================

/// Отдать PNG наружу. `false` — автор отменил сохранение.
Future<bool> exportQuestShot(Uint8List png, {String? questTitle}) async {
  final fileName =
      'meander_shot_${DateTime.now().millisecondsSinceEpoch}.png';
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Экспорт скриншота',
      fileName: fileName,
      bytes: png,
      type: FileType.image,
      allowedExtensions: const ['png'],
    );
    return saved != null;
  }
  final file = XFile.fromData(
    png,
    mimeType: 'image/png',
    name: fileName,
  );
  await SharePlus.instance.share(
    ShareParams(
      files: [file],
      fileNameOverrides: [fileName],
      text: questTitle == null || questTitle.isEmpty
          ? tr('Скриншот квеста в Meander')
          : tr('Квест «{questTitle}» в Meander')
              .replaceAll('{questTitle}', questTitle),
    ),
  );
  return true;
}
