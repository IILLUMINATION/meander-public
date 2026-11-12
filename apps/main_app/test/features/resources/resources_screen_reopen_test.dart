// Библиотека при повторном открытии не должна начинать с нуля: возврат из
// скрипта пересоздаёт экран (воркспейс заменяет вкладку), поэтому снимок
// ресурсов и позиция прокрутки живут вне его State.

import 'package:canvas_app/features/resources/models/resource_file.dart';
import 'package:canvas_app/features/resources/screens/resources_screen.dart';
import 'package:canvas_app/features/resources/services/quest_storage.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStorageAdapter implements StorageAdapter {
  final Map<String, dynamic> jsonFiles = {};
  final Map<String, String> textFiles = {};

  @override
  Future<Map<String, dynamic>> readJsonFile(String relativePath) async =>
      Map<String, dynamic>.from(jsonFiles[relativePath] as Map);

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
  }) async => const [];

  @override
  Future<List<String>> listFolders(String relativePath) async => const [];

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

  // Тест-адаптер без массового снимка: сервис идёт пофайловым путём.
  @override
  Future<List<ResourceFileFacts>?> scanFiles(
    String relativePath, {
    String? extension,
    bool parseJson = false,
  }) async => null;
}

/// Сервис без файлового ввода-вывода: виджет-тест проверяет поведение экрана,
/// а не диск. Кэш последнего снимка ведёт себя как настоящий.
class _FakeResourceService extends ResourceService {
  _FakeResourceService({required this.data})
    : super(
        storage: QuestStorage(
          questId: _questId,
          adapter: _MemoryStorageAdapter(),
        ),
      );

  final ResourcesData data;
  ResourcesData? _cached;

  @override
  ResourcesData? get lastLoaded => _cached;

  @override
  Future<ResourcesData> loadResources() async {
    _cached = data;
    return data;
  }
}

const String _questId = 'quest-reopen';

ResourcesData _dataWith(int scripts) => ResourcesData(
  resources: [
    for (var i = 0; i < scripts; i++)
      ResourceFile(
        id: '$i.json',
        stableId: '$i.json',
        name: '$i.json',
        path: 'scripts/$i.json',
        type: 'script',
        friendlyName: 'Скрипт $i',
        blockCount: i,
      ),
  ],
  explicitFolders: const [],
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  (ProviderContainer, Widget Function()) harness({int scripts = 30}) {
    final service = _FakeResourceService(data: _dataWith(scripts));
    final container = ProviderContainer(
      overrides: [resourceServiceProvider(_questId).overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    Widget screen() => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ResourcesScreen(questId: _questId)),
    );
    return (container, screen);
  }

  testWidgets('пересозданный экран показывает список сразу, без спиннера', (
    tester,
  ) async {
    final (_, screen) = harness();

    await tester.pumpWidget(screen());
    await tester.pump();
    expect(find.text('Скрипт 1'), findsOneWidget);

    // Воркспейс пересоздаёт вкладку при возврате из скрипта.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(screen());

    // Один кадр, без ожидания загрузки: снимок уже в памяти.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Скрипт 1'), findsOneWidget);
  });

  testWidgets('позиция прокрутки переживает пересоздание экрана', (
    tester,
  ) async {
    final (container, screen) = harness(scripts: 80);

    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.pump();

    await tester.drag(find.byType(GridView), const Offset(0, -500));
    await tester.pumpAndSettle();

    final saved = container.read(resourcesScrollOffsetProvider(_questId));
    expect(saved, greaterThan(0), reason: 'прокрутка должна запоминаться');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(screen());
    await tester.pump();

    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(GridView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(position.pixels, closeTo(saved, 1.0));
  });

  test(
    'сервис отдаёт последний снимок для мгновенного повторного показа',
    () async {
      final adapter = _MemoryStorageAdapter();
      adapter.jsonFiles[QuestPaths.metadata(_questId)] = <String, dynamic>{
        QuestStorage.foldersKey: <String>[],
      };
      final service = ResourceService(
        storage: QuestStorage(questId: _questId, adapter: adapter),
      );

      expect(service.lastLoaded, isNull);
      final first = await service.loadResources();
      expect(service.lastLoaded, same(first));
    },
  );
}
