import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/workspace/script_document_store.dart';

/// Свободная расстановка блоков живёт в том же файле скрипта, что и дерево.
/// Тест держит оба контракта: канвас сохраняет `layout`, а сохранение без него
/// (классический редактор) не стирает уже записанное.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;
  const questId = 'layout-quest';
  const scriptId = 'intro';

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_script_layout');
    FileStorage.overrideAppDirectory(appDir);
  });

  tearDownAll(() async {
    FileStorage.overrideAppDirectory(null);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  setUp(() {
    FileStorage.invalidateJsonCache([QuestPaths.scriptFile(questId, '$scriptId.json')]);
  });

  File scriptFile() =>
      File('${appDir.path}/${QuestPaths.scriptFile(questId, '$scriptId.json')}');

  void writeScript(String body) {
    final file = scriptFile();
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
  }

  Map<String, dynamic> readScript() =>
      jsonDecode(scriptFile().readAsStringSync()) as Map<String, dynamic>;

  test('читает layout и сохраняет расстановку', () async {
    writeScript('''
{
  "id": "$scriptId",
  "name": "Вступление",
  "blocks": [
    {"type": "event", "id": "event-1", "eventType": "onNodeEnter", "children": []}
  ],
  "layout": {"event-1": {"x": 420, "y": 180}}
}
''');

    final store = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    final doc = await store.load();
    expect(doc.layout, {'event-1': const Offset(420, 180)});

    await store.save(
      name: doc.name,
      blocks: doc.blocks,
      layout: {'event-1': const Offset(-60, 32)},
    );

    final saved = readScript();
    expect(saved['layout'], {
      'event-1': {'x': -60.0, 'y': 32.0},
    });
    // Дерево блоков не пострадало.
    expect((saved['blocks'] as List).single['id'], 'event-1');
  });

  test('сохранение без layout не стирает прочитанную расстановку', () async {
    writeScript('''
{
  "id": "$scriptId",
  "name": "Вступление",
  "blocks": [
    {"type": "delay", "id": "delay-1"}
  ],
  "layout": {"delay-1": {"x": 10, "y": 20}}
}
''');

    final store = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    final doc = await store.load();
    FileStorage.invalidateJsonCache([QuestPaths.scriptFile(questId, '$scriptId.json')]);

    await store.save(name: doc.name, blocks: doc.blocks);

    expect(readScript()['layout'], {
      'delay-1': {'x': 10.0, 'y': 20.0},
    });
  });

  test('мусор в layout пропускается, пустая расстановка не пишется', () async {
    writeScript('''
{
  "id": "$scriptId",
  "name": "",
  "blocks": [],
  "layout": {"ok": {"x": 1, "y": 2}, "bad": "nope", "half": {"x": 3}}
}
''');

    final store = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    final doc = await store.load();
    expect(doc.layout, {'ok': const Offset(1, 2)});

    await store.save(
      name: doc.name,
      blocks: <VisualScriptBlock>[],
      layout: const {},
    );
    expect(readScript().containsKey('layout'), isFalse);
  });
}
