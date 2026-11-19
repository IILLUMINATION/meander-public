import 'dart:io';

import 'package:canvas_app/core/services/async_import_service.dart';
import 'package:flutter/services.dart';
import 'package:mnd_player/utils/file_storage.dart';

/// Большой интерактивный квест-тренажёр по таблицам. Лежит рядом
/// с приложением (`assets/examples/table_tutorial.mnd`), импорт идёт обычным
/// путём — тем же, что файл, выбранный в «Мои квесты → Импортировать».
///
/// Ассет, а не генерация на месте: тренажёр видно в редакторе и плеере ровно
/// таким, каким он собран и проверен тестом; расхождение с движком поймает
/// `table_examples_test.dart`, а не автор на живом квесте.
class TableExamples {
  TableExamples._();

  /// ID внутри `config.json`. Повторное добавление перезапишет тренажёр,
  /// а не наплодит копий.
  static const tutorialQuestId = '11111111-2222-4333-8444-555555555550';

  static const assets = <String>['assets/examples/table_tutorial.mnd'];

  /// Импортировать тренажёр. Возвращает ID добавленного квеста.
  ///
  /// [importFile] подменяется в тесте: проверяем, что в импорт уходят именно
  /// байты ассета, без поднятия Rust-моста.
  static Future<List<String>> importAll({
    Future<String?> Function(String path)? importFile,
    Future<ByteData> Function(String asset)? loadAsset,
  }) async {
    final doImport = importFile ?? AsyncImportService.importFromFile;
    final load = loadAsset ?? rootBundle.load;
    final imported = <String>[];
    final dir = Directory(await FileStorage.getFilePath('temp/table_examples'));
    await dir.create(recursive: true);
    try {
      for (final asset in assets) {
        final data = await load(asset);
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final file = File('${dir.path}/${asset.split('/').last}');
        await file.writeAsBytes(bytes, flush: true);
        final id = await doImport(file.path);
        if (id != null) imported.add(id);
      }
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    return imported;
  }
}
