// «Назад» из скрипта возвращает в ту папку библиотеки, из которой его открыли.
//
// Регрессия: при выключенном авто-открытии вкладок воркспейс заменяет вкладку
// библиотеки документом скрипта. Возврат переоткрывает `ResourcesScreen`,
// и папка жила только в его State — автор попадал в корень. Теперь папка
// хранится в провайдере квеста и переживает пересоздание экрана.

import 'package:canvas_app/features/resources/screens/resources_screen.dart';
import 'package:canvas_app/features/resources/services/quest_storage.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStorageAdapter implements StorageAdapter {
  final Map<String, dynamic> jsonFiles = {};
  final Map<String, String> textFiles = {};

  @override
  Future<Map<String, dynamic>> readJsonFile(String relativePath) async {
    final data = jsonFiles[relativePath];
    if (data == null) throw Exception('Файл $relativePath не существует');
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Future<void> writeJsonFile(
    String relativePath,
    Map<String, dynamic> data,
  ) async {
    jsonFiles[relativePath] = Map<String, dynamic>.from(data);
  }

  @override
  Future<List<String>> listFiles(
    String relativePath, {
    String? extension,
  }) async {
    final prefix = relativePath.endsWith('/') ? relativePath : '$relativePath/';
    final result = <String>[];
    for (final path in [...jsonFiles.keys, ...textFiles.keys]) {
      if (!path.startsWith(prefix)) continue;
      final name = path.substring(prefix.length);
      if (name.contains('/')) continue;
      if (extension != null && !name.endsWith(extension)) continue;
      result.add(name);
    }
    return result;
  }

  @override
  Future<List<String>> listFolders(String relativePath) async => [];

  @override
  Future<bool> exists(String relativePath) async =>
      jsonFiles.containsKey(relativePath) ||
      textFiles.containsKey(relativePath);

  @override
  Future<void> delete(String relativePath) async {
    jsonFiles.remove(relativePath);
    textFiles.remove(relativePath);
  }

  @override
  Future<String> getFilePath(String relativePath) async =>
      '/in-memory/$relativePath';

  @override
  Future<String> readText(String relativePath) async =>
      textFiles[relativePath] ?? '';

  @override
  Future<void> writeText(String relativePath, String content) async {
    textFiles[relativePath] = content;
  }
}

const String _questId = 'quest-folders';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('папка библиотеки переживает пересоздание экрана', (
    tester,
  ) async {
    final adapter = _MemoryStorageAdapter();
    adapter.jsonFiles[QuestPaths.metadata(_questId)] = {
      QuestStorage.foldersKey: ['/Скрипты'],
    };
    final container = ProviderContainer(
      overrides: [
        questStorageProvider(
          _questId,
        ).overrideWithValue(QuestStorage(questId: _questId, adapter: adapter)),
      ],
    );
    addTearDown(container.dispose);

    Widget screen() => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ResourcesScreen(questId: _questId)),
    );

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    // Корень библиотеки.
    expect(find.text('/Скрипты'), findsNothing);

    // Последнее «Скрипты» — карточка папки, а не фильтр типов.
    await tester.tap(find.text('Скрипты').last);
    await tester.pumpAndSettle();

    expect(
      find.text('/Скрипты'),
      findsOneWidget,
      reason: 'после входа в папку экран показывает её путь',
    );

    // Воркспейс пересоздаёт вкладку библиотеки при возврате из скрипта.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    expect(
      find.text('/Скрипты'),
      findsOneWidget,
      reason: 'пересозданный экран обязан открыться в той же папке',
    );
  });
}
