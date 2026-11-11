import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_web_player/quest_bundle.dart';

/// Архив той же раскладки, что у каталога квеста на диске.
Uint8List mndBytes(Map<String, String> files, {String magic = ''}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final zip = ZipEncoder().encode(archive);
  return Uint8List.fromList([...utf8.encode(magic), ...zip]);
}

final _questFiles = <String, String>{
  'config.json': jsonEncode({
    'id': 'quest-1',
    'title': 'Проба',
    'author': 'autor',
    'startNodeId': 'n1',
  }),
  'nodes.json': jsonEncode({
    'nodes': [
      {'id': 'n1', 'content': []},
    ],
    'groups': [],
  }),
  'res/templates.json': jsonEncode([
    {'id': 't1'},
  ]),
  'res/metadata.json': jsonEncode({
    '__folders': ['images'],
    '7b0f.png': {'name': 'закат', 'resourceId': 'res-9'},
  }),
  'res/images/7b0f.png': '\x89PNG bytes',
  'res/fonts/Fira.ttf': 'ttf bytes',
  'scripts/uuid-1.json': '{"blocks":[]}',
  'editor_session.json': '{"open":true}',
};

void main() {
  group('decodeMnd — форматы .mnd', () {
    test('открытый архив: магия MND_ZIP_ + zip', () {
      final bundle = decodeMnd(
        mndBytes(_questFiles, magic: 'MND_ZIP_'),
        'http://127.0.0.1/quests/proba.mnd',
      );
      expect(bundle.questId, 'quest-1');
      expect(bundle.title, 'Проба');
      expect(bundle.startNodeId, 'n1');
      expect(bundle.nodesJson['nodes'], hasLength(1));
      expect(bundle.templates, hasLength(1));
      expect(bundle.embeddedScripts.keys, ['scripts/uuid-1.json']);
      expect(bundle.assets.containsKey('editor_session.json'), isFalse);
    });

    test('голый zip без магии — так квесты лежат в каталоге маркета', () {
      final bundle = decodeMnd(
        mndBytes(_questFiles),
        'https://meander.illuminat.dev/quest-src/quest-1.mnd',
      );
      expect(bundle.title, 'Проба');
      expect(bundle.hasScripts, isTrue);
    });

    test('шаблоны: редактор пишет карту, а не голый массив', () {
      final files = Map<String, String>.of(_questFiles)
        ..['res/templates.json'] = jsonEncode({
          'schemaVersion': 1,
          'templates': [
            {'id': 't1', 'kind': 'row', 'payload': {'id': 'm1', 'type': 'row'}},
          ],
        });
      final bundle = decodeMnd(
        mndBytes(files),
        'https://meander.illuminat.dev/quest-src/quest-1.mnd',
      );
      expect(bundle.templates, hasLength(1));
      expect((bundle.templates.single as Map)['id'], 't1');
    });

    test('шифрованный архив — честная ошибка, а не битый квест', () {
      expect(
        () => decodeMnd(
          mndBytes(_questFiles, magic: 'MND_SEC_'),
          'http://h/x.mnd',
        ),
        throwsA(
          isA<QuestLoadException>().having(
            (e) => e.message,
            'message',
            contains('защищён паролем'),
          ),
        ),
      );
    });

    test('не-архив и архив без config — ошибка, а не пустой квест', () {
      expect(
        () => decodeMnd(
          mndBytes({'nodes.json': '{"nodes":[]}'}),
          'http://h/x.mnd',
        ),
        throwsA(
          isA<QuestLoadException>().having(
            (e) => e.message,
            'message',
            contains('config.json'),
          ),
        ),
      );
      expect(
        () => decodeMnd(
          Uint8List.fromList(utf8.encode('<!DOCTYPE html><html>')),
          'http://h/x.mnd',
        ),
        throwsA(isA<QuestLoadException>()),
      );
    });
  });

  group('QuestBundle.assetBytes — три формы источника', () {
    late QuestBundle bundle;
    setUp(() {
      bundle = decodeMnd(
        mndBytes(_questFiles, magic: 'MND_ZIP_'),
        'http://h/x.mnd',
      );
    });

    test('путь в каталоге', () {
      expect(bundle.assetBytes('res/images/7b0f.png'), isNotNull);
    });

    test('имя ресурса из библиотеки', () {
      expect(bundle.assetBytes('закат'), isNotNull);
    });

    test('uuid файла и resourceId', () {
      expect(bundle.assetBytes('7b0f.png'), isNotNull);
      expect(bundle.assetBytes('res-9'), isNotNull);
    });

    test('путь, которого нет, не подменяется другим файлом', () {
      expect(bundle.assetBytes('res/images/net.png'), isNull);
      expect(bundle.assetBytes(null), isNull);
    });

    test('шрифты квеста видны для FontLoader', () {
      expect(bundle.fontPaths, ['res/fonts/Fira.ttf']);
    });
  });
}
