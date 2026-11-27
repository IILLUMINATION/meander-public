import 'dart:io';

import 'package:canvas_app/core/services/quest_cleaner_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

const _questId = '33333333-3333-4333-8333-333333333333';
const _chapterId = 'chapter-1';
const _nodeId = 'node-1';

const _used = [
  'direct.png',
  'bare.webp',
  'nested.gif',
  'template.avif',
  'script.png',
  'MiXeD.PNG',
];
const _unused = ['unsafe.png', 'remote.png', 'orphan.png', 'unsafe-script.png'];

Future<void> _writeImage(String name) async {
  final file = File(
    await FileStorage.getFilePath(QuestPaths.resImage(_questId, name)),
  );
  await file.parent.create(recursive: true);
  await file.writeAsBytes(List<int>.filled(32, 0));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory appDir;

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_cleaner_inline_images');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return appDir.path;
          }
          return null;
        });

    await FileStorage.writeJsonFile(QuestPaths.config(_questId), {
      'id': _questId,
      'title': 'Инлайн-картинки',
      'startNodeId': _nodeId,
      'tags': [
        {'id': _chapterId, 'name': 'Глава'},
      ],
    });
    await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
      'nodes': [
        {
          'id': _nodeId,
          'chapterId': _chapterId,
          'title': 'Нода',
          'content': {
            'items': [
              {
                'id': 'text-1',
                'type': 'text',
                'text':
                    '[img=res/images/direct.png] '
                    '[img=bare.webp] '
                    '[img=mixed.png] '
                    '[img=../unsafe.png] '
                    '[img=https://example.com/remote.png]',
              },
              {
                'id': 'stack-1',
                'type': 'stack',
                'children': [
                  {
                    'id': 'text-2',
                    'type': 'text',
                    'text': '[img=res/images/nested.gif]',
                  },
                ],
              },
            ],
          },
        },
      ],
    });
    await FileStorage.writeJsonFile(QuestPaths.templates(_questId), {
      'schemaVersion': 1,
      'templates': [
        {
          'id': 'tpl-1',
          'name': 'Плашка',
          'items': [
            {
              'id': 'master-1',
              'type': 'text',
              'text': '[img=res/images/template.avif]',
            },
          ],
        },
      ],
    });
    await FileStorage.writeJsonFile(QuestPaths.scriptFile(_questId, 'inline'), {
      'blocks': [
        {
          'type': 'set_variable',
          'name': 'label',
          'value': '[img=script.png] [img=../unsafe-script.png]',
        },
      ],
    });

    for (final name in [..._used, ..._unused]) {
      await _writeImage(name);
    }
  });

  tearDownAll(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test(
    'очистка сохраняет инлайн-картинки, но не защищает битые теги',
    () async {
      final report = await QuestCleanerService().scanQuest(_questId);
      final toDelete = report.issues
          .where((issue) => issue.type == 'delete_resource')
          .map((issue) => issue.payload['resourcePath'].toString())
          .toSet();

      for (final name in _used) {
        expect(
          toDelete,
          isNot(contains('res/images/$name')),
          reason: 'используемая картинка $name помечена к удалению: $toDelete',
        );
      }
      for (final name in _unused) {
        expect(
          toDelete,
          contains('res/images/$name'),
          reason: 'негативный контроль: $name не должен защищаться очисткой',
        );
      }
    },
  );
}
