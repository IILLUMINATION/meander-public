import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnd_web_player/quest_bundle.dart';
import 'package:mnd_web_player/quest_source.dart';

/// Архив той же раскладки, что отдаёт сервер (`MND_ZIP_` + zip).
Uint8List mndBytes(Map<String, String> files, {String magic = ''}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final zip = ZipEncoder().encode(archive);
  return Uint8List.fromList([...utf8.encode(magic), ...zip]);
}

/// Текстовая часть квеста — то, что бэкенд кладёт в `boot.mnd`.
final Map<String, String> _bootFiles = {
  'config.json': jsonEncode({
    'id': 'quest-1',
    'title': 'Проба',
    'startNodeId': 'n1',
  }),
  'nodes.json': jsonEncode({
    'nodes': [
      {'id': 'n1', 'content': []},
    ],
  }),
  'res/templates.json': jsonEncode([
    {'id': 't1'},
  ]),
  'res/metadata.json': jsonEncode({
    '__folders': ['images'],
    '7b0f.png': {'name': 'закат', 'resourceId': 'res-9'},
  }),
  'res/fonts/Fira.ttf': 'ttf bytes',
  'scripts/uuid-1.json': '{"blocks":[]}',
};

/// Медиа: в boot не попадает, забирается по требованию.
final Map<String, String> _media = {
  'res/images/7b0f.png': '\x89PNG bytes',
  'res/images/мой фон.png': 'SPACE PNG',
};

const String _questUrl = 'https://meander.illuminat.dev/quest-src/quest-1.mnd';

String _manifest({int version = 1}) => jsonEncode({
  'version': version,
  'questId': 'quest-1',
  'contentHash': 'abc',
  'format': 'legacy',
  'boot': 'boot.mnd',
  'entries': [
    for (final path in [..._bootFiles.keys, ..._media.keys])
      {'path': path, 'kind': 'image', 'size': 1, 'sha256': 'x', 'boot': _bootFiles.containsKey(path)},
  ],
});

/// Заглушка бэкенда потоковой выдачи: манифест, boot, ленивые записи и полный
/// архив по тому же хосту.
class _Server {
  _Server({this.manifestStatus = 200, this.version = 1});

  final int manifestStatus;
  final int version;

  int manifestCalls = 0;
  int bootCalls = 0;
  final List<Uri> entryRequests = [];

  http.Client client() => MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/manifest')) {
      manifestCalls++;
      if (manifestStatus != 200) return http.Response('nope', manifestStatus);
      return http.Response.bytes(
        utf8.encode(_manifest(version: version)),
        200,
      );
    }
    if (path.endsWith('/boot')) {
      bootCalls++;
      return http.Response.bytes(mndBytes(_bootFiles, magic: 'MND_ZIP_'), 200);
    }
    if (path.contains('/entry/')) {
      entryRequests.add(request.url);
      final rel = Uri.decodeComponent(path.split('/entry/').last);
      final data = _media[rel];
      if (data == null) return http.Response('nope', 404);
      return http.Response.bytes(utf8.encode(data), 200);
    }
    if (path.endsWith('.mnd') || path.endsWith('.zip')) {
      return http.Response.bytes(
        mndBytes({..._bootFiles, ..._media}, magic: 'MND_ZIP_'),
        200,
      );
    }
    return http.Response('nope', 404);
  });
}

void main() {
  group('openQuestAssets — потоковая выдача', () {
    test('boot даёт JSON сразу, медиа приезжает по требованию', () async {
      final server = _Server();
      final assets = await openQuestAssets(_questUrl, client: server.client());

      expect(assets.questId, 'quest-1');
      expect(assets.config['title'], 'Проба');
      expect(assets.nodesJson['nodes'], hasLength(1));
      expect(assets.templates, hasLength(1));
      expect(assets.embeddedScripts.keys, ['scripts/uuid-1.json']);
      expect(assets.fontPaths, ['res/fonts/Fira.ttf']);
      expect(server.bootCalls, 1);
      // Медиа в boot нет: до запроса его не просили и в памяти нет.
      expect(server.entryRequests, isEmpty);
      expect(assets.assetBytes('res/images/7b0f.png'), isNull);

      var notifications = 0;
      assets.addListener(() => notifications++);
      await assets.prefetch(['res/images/7b0f.png']);

      expect(notifications, greaterThan(0));
      expect(
        assets.assetBytes('res/images/7b0f.png'),
        utf8.encode('\x89PNG bytes'),
      );
      expect(assets.assets.containsKey('res/images/7b0f.png'), isTrue);
      // Лениво: запрошена ровно одна запись, вторая картинка не тронута.
      expect(server.entryRequests, hasLength(1));
    });

    test('имя из библиотеки резолвится в запись архива', () async {
      final server = _Server();
      final assets = await openQuestAssets(_questUrl, client: server.client());

      await assets.prefetch(['закат']);

      expect(server.entryRequests.single.path, endsWith('/entry/res/images/7b0f.png'));
      expect(assets.assetBytes('закат'), utf8.encode('\x89PNG bytes'));
    });

    test('пробелы и не-ASCII в пути уезжают закодированными', () async {
      final server = _Server();
      final assets = await openQuestAssets(_questUrl, client: server.client());

      await assets.prefetch(['res/images/мой фон.png']);

      final request = server.entryRequests.single;
      expect(request.path, contains('/entry/res/images/'));
      expect(request.path, isNot(contains('мой фон')));
      expect(assets.assetBytes('res/images/мой фон.png'), utf8.encode('SPACE PNG'));
    });

    test('база выводится из URL квеста и переопределяется', () async {
      final server = _Server();
      await openQuestAssets(
        'https://meander.illuminat.dev/quests/quest-1/file',
        client: server.client(),
      );
      expect(server.manifestCalls, 1);

      final explicit = _Server();
      await openQuestAssets(
        _questUrl,
        base: 'https://meander.illuminat.dev/quest-src/quest-1/',
        client: explicit.client(),
      );
      expect(explicit.manifestCalls, 1);
    });
  });

  group('openQuestAssets — откат на полный архив', () {
    test('нет манифеста — качаем `.mnd` целиком', () async {
      final server = _Server(manifestStatus: 404);
      final assets = await openQuestAssets(_questUrl, client: server.client());

      expect(assets, isA<QuestBundle>());
      expect(server.entryRequests, isEmpty);
      // Всё уже в памяти: догружать нечего.
      expect(assets.assetBytes('res/images/7b0f.png'), utf8.encode('\x89PNG bytes'));
      expect(assets.assetBytes('res/images/мой фон.png'), utf8.encode('SPACE PNG'));
    });

    test('чужая версия манифеста — тоже полный архив', () async {
      final server = _Server(version: 2);
      final assets = await openQuestAssets(_questUrl, client: server.client());

      expect(assets, isA<QuestBundle>());
      expect(assets.assetBytes('res/images/7b0f.png'), isNotNull);
    });

    test('URL не похож на квест — манифест не спрашиваем', () async {
      final server = _Server();
      final assets = await openQuestAssets(
        'https://meander.illuminat.dev/assets/quest.zip',
        client: server.client(),
      );

      expect(server.manifestCalls, 0);
      expect(assets, isA<QuestBundle>());
    });
  });
}
