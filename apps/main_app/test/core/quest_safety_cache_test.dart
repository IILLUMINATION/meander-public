// Тест: кэш отчёта QuestSafetyService — повторный inspect на тех же файлах
// берётся из кэша (тот же объект), правка скрипта инвалидирует кэш.
import 'dart:io';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/quest_safety_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/quest_descriptor.dart';
import 'package:mnd_player/utils/file_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('кэш отчёта: повторный inspect из кэша, правка инвалидирует',
      () async {
    final docs = await Directory.systemTemp.createTemp('safety_cache_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return docs.path;
          }
          return null;
        });

    const questId = 'bench-quest';
    final quest = Quest(id: questId, title: 'Bench');
    final api = _FakeApi();

    // config.json обязателен: без него fingerprint = null и кэш отключён.
    await FileStorage.writeTextFile(
      'quests/$questId/config.json',
      '{"id":"$questId","title":"Bench"}',
    );
    // Квест с одним сетевым блоком в скрипте.
    await FileStorage.writeTextFile(
      'quests/$questId/scripts/s1.json',
      '{"name":"s1","blocks":['
          '{"type":"open_link","url":"https://example.com"}]}',
    );

    final service = const QuestSafetyService();
    final r1 = await service.inspect(quest: quest, api: api);
    expect(r1.internetBlockCount, 1);

    // Повтор: из кэша, тот же объект.
    final r2 = await service.inspect(quest: quest, api: api);
    expect(r2.internetBlockCount, 1);
    expect(identical(r1, r2), isTrue, reason: 'второй вызов — из кэша');

    // Правка скрипта: mtime меняется — кэш инвалидируется.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await FileStorage.writeJsonFile(
      'quests/$questId/scripts/s1.json',
      {'name': 's1', 'blocks': <dynamic>[]},
    );
    final r3 = await service.inspect(quest: quest, api: api);
    expect(r3.internetBlockCount, 0, reason: 'после правки отчёт пересчитан');
    expect(identical(r2, r3), isFalse);
  });
}

/// Сетевые вызовы в тесте не нужны: квест без verified-онлайна. Реальный
///ApiService замещён фейкой с тем же интерфейсом.
class _FakeApi implements ApiService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
