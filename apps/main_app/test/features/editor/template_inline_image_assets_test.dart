import 'dart:io';
import 'dart:typed_data';

import 'package:canvas_app/core/services/template_bundler.dart';
import 'package:canvas_app/features/editor/utils/template_applier.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';

const _questId = '44444444-4444-4444-8444-444444444444';
const _directPath = 'res/images/attack.png';
const _barePath = 'res/images/bare.webp';

TemplateItem _template() => TemplateItem(
  id: 'tpl-inline-images',
  name: 'Значки',
  kind: TemplateKind.content,
  payload: {
    'id': 'text-1',
    'type': 'text',
    'text':
        '[img=$_directPath] [img=bare.webp] '
        '[img=../secret.png] [img=res/fonts/not-an-image.ttf]',
  },
);

Future<void> _writeResource(String path, List<int> bytes) async {
  final file = File(
    await FileStorage.getFilePath(QuestPaths.questFile(_questId, path)),
  );
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory appDir;
  final directBytes = Uint8List.fromList(List<int>.filled(64, 1));
  final bareBytes = Uint8List.fromList(List<int>.filled(64, 2));

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp(
      'mnd_template_inline_images',
    );
    FileStorage.overrideAppDirectory(appDir);
    await _writeResource(_directPath, directBytes);
    await _writeResource(_barePath, bareBytes);
    await _writeResource('res/images/secret.png', List<int>.filled(64, 3));
  });

  tearDownAll(() async {
    FileStorage.overrideAppDirectory(null);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('шаблон собирает только валидные инлайн-картинки', () {
    final paths = TemplateApplier.collectResourcePaths(_template());

    expect(paths, containsAll([_directPath, _barePath]));
    expect(paths, isNot(contains('res/images/secret.png')));
    expect(paths, isNot(contains('res/fonts/not-an-image.ttf')));
  });

  test('бандел шаблона переносит байты инлайн-картинок', () async {
    final bytes = await TemplateBundler.buildBundle(
      template: _template(),
      questId: _questId,
    );
    final collection = await TemplateBundler.readBundle(
      Uint8List.fromList(bytes),
    );

    expect(collection, isNotNull);
    final paths = collection!.template.assets
        .map((asset) => asset.relativePath)
        .toSet();
    expect(paths, containsAll([_directPath, _barePath]));
    expect(paths, isNot(contains('res/images/secret.png')));
    expect(collection.bytesBySha.values, contains(orderedEquals(directBytes)));
    expect(collection.bytesBySha.values, contains(orderedEquals(bareBytes)));
  });

  test('полный путь не переписывается по совпадению базового имени', () {
    const original = 'res/images/nested/foo.png';
    const renamed = 'res/images/nested/foo__12345678.png';
    final remapped = TemplateBundler.remapPayloadPaths(
      {'text': '[img=res/images/other/foo.png] [img=foo.png]'},
      {original: renamed},
    );

    expect(
      remapped['text'],
      '[img=res/images/other/foo.png] [img=foo__12345678.png]',
    );
  });

  test('коллизия переименовывает ресурс внутри инлайн-тега', () async {
    const path = 'res/images/collision.png';
    await _writeResource(path, List<int>.filled(64, 8));
    final incoming = Uint8List.fromList(List<int>.filled(64, 9));
    final hash = sha256.convert(incoming).toString();
    final report = await TemplateBundler.applyAssetsToQuest(
      questId: _questId,
      assets: [
        TemplateAsset(relativePath: path, sha256: hash, size: incoming.length),
      ],
      bytesBySha: {hash: incoming},
    );
    final renamed = report.remappedPaths[path]!;
    final renamedBase = renamed.split('/').last;
    final payload = {
      'text': '[img=collision.png] [img=$path] [img=../secret.png]',
      'backgroundAssetId': 'collision.png',
      'nested': [
        {'text': 'Значок [img=collision.png]'},
      ],
    };

    final remapped = TemplateBundler.remapPayloadPaths(
      payload,
      report.remappedPaths,
    );

    expect(report.failed, isEmpty);
    expect(
      remapped['text'],
      '[img=$renamedBase] [img=$renamed] [img=../secret.png]',
    );
    expect(remapped['backgroundAssetId'], renamedBase);
    expect(
      (remapped['nested'] as List).single['text'],
      'Значок [img=$renamedBase]',
    );
    final copied = File(
      await FileStorage.getFilePath(QuestPaths.questFile(_questId, renamed)),
    );
    expect(await copied.readAsBytes(), orderedEquals(incoming));
  });
}
