import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/workspace/script_document_store.dart';

/// Порядок чтения и записи одного файла скрипта.
///
/// Вкладку скрипта держат ДВА экземпляра редактора (вкладка воркспейса и
/// экран-маршрут из модалки/стека) и пересоздание вкладки вытеснением из
/// кэша поверхностей. Если чтение обгоняет запись предыдущего экземпляра,
/// новый показывает устаревшее содержимое, а его автосейв затирает свежую
/// правку — снаружи это «скрипт не сохраняется».
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;
  const questId = 'store-quest';
  const scriptId = 'logic';

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_script_store');
    FileStorage.overrideAppDirectory(appDir);
  });

  tearDownAll(() async {
    FileStorage.overrideAppDirectory(null);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  setUp(() {
    ScriptDocumentStore.resetQueuesForTest();
    final dir = Directory('${appDir.path}/quests/$questId');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    FileStorage.invalidateJsonCache(const []);
  });

  File scriptFile() => File(
    '${appDir.path}/${QuestPaths.scriptFile(questId, '$scriptId.json')}',
  );

  List<VisualScriptBlock> blocksWith(int count) => [
    for (var i = 0; i < count; i++)
      DelayBlock(id: 'delay-$i', expression: '${(i + 1) * 100}'),
  ];

  test('чтение ждёт незавершённую запись другого экземпляра', () async {
    final writer = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    final reader = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    // Файл уже есть: без сериализации читатель успевает прочитать «Старое».
    await writer.save(name: 'Старое', blocks: blocksWith(1));

    // Запись запускаем, но НЕ ждём: читатель стартует сразу же, как это
    // делает вкладка, смонтированная поверх уходящего экрана.
    final saving = writer.save(name: 'Логика', blocks: blocksWith(3));
    final loaded = await reader.load();
    await saving;

    expect(loaded.exists, isTrue);
    expect(loaded.name, 'Логика');
    expect(loaded.blocks, hasLength(3));
  });

  test('новый экземпляр после записи видит свежие данные', () async {
    final writer = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    await writer.save(name: 'Первый', blocks: blocksWith(1));

    final reader = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    final loaded = await reader.load();
    expect(loaded.name, 'Первый');
    expect(loaded.blocks, hasLength(1));
  });

  test('файл, которого нет в обоих каталогах, создаётся в scripts/', () async {
    final store = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    expect((await store.load()).exists, isFalse);

    await store.save(name: 'Новый', blocks: blocksWith(1));

    expect(scriptFile().existsSync(), isTrue);
    final internal = File(
      '${appDir.path}/${QuestPaths.internalScriptFile(questId, '$scriptId.json')}',
    );
    expect(
      internal.existsSync(),
      isFalse,
      reason: 'легаси-каталог не должен получать новые скрипты',
    );
  });

  test('имя сохраняется и в metadata.json', () async {
    final metaFile = File('${appDir.path}/${QuestPaths.metadata(questId)}');
    metaFile.parent.createSync(recursive: true);
    metaFile.writeAsStringSync(
      jsonEncode({
        '$scriptId.json': {'name': 'Старое', 'folder': '/логика'},
      }),
    );

    final store = ScriptDocumentStore(questId: questId, scriptId: scriptId);
    await store.save(name: 'Новое имя', blocks: blocksWith(1));

    final meta =
        jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
    final entry = meta['$scriptId.json'] as Map<String, dynamic>;
    expect(entry['name'], 'Новое имя');
    expect(entry['folder'], '/логика', reason: 'папка не должна сбрасываться');
  });
}
