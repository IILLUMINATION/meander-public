import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:canvas_app/core/services/offline_web_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('web_export_test_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<Directory> shell({String baseHref = '/'}) async {
    final dir = await Directory(p.join(temp.path, 'site')).create();
    await File(p.join(dir.path, 'index.html')).writeAsString(
      '<html><head><base href="$baseHref"></head><body></body></html>',
    );
    await Directory(p.join(dir.path, 'canvaskit')).create();
    await File(p.join(dir.path, 'canvaskit', 'canvaskit.wasm'))
        .writeAsBytes([0, 97, 115, 109]);
    return dir;
  }

  test('оболочке чинится абсолютный base href — сайт живёт в подпапке',
      () async {
    final dir = await shell();

    await OfflineWebBuilder.composeSite(
      shellDir: dir,
      questMnd: await File(p.join(temp.path, 'quest.mnd'))
          .writeAsBytes([1, 2, 3]),
    );

    final html = await File(p.join(dir.path, 'index.html')).readAsString();
    expect(html, contains('<base href="./"'));
  });

  test('относительный base href не трогаем', () async {
    final dir = await shell(baseHref: './');

    await OfflineWebBuilder.composeSite(
      shellDir: dir,
      questMnd: await File(p.join(temp.path, 'quest.mnd'))
          .writeAsBytes([1, 2, 3]),
    );

    expect(await File(p.join(dir.path, 'index.html')).readAsString(),
        contains('<base href="./"'));
  });

  test('в сайт кладутся квест байт-в-байт и памятка про COOP/COEP', () async {
    final dir = await shell();
    final mnd = File(p.join(temp.path, 'quest.mnd'));
    final payload = List<int>.generate(4096, (i) => i % 251);
    await mnd.writeAsBytes(payload);

    await OfflineWebBuilder.composeSite(shellDir: dir, questMnd: mnd);

    expect(await File(p.join(dir.path, 'quest.mnd')).readAsBytes(), payload);
    final readme = await File(p.join(dir.path, 'README.txt')).readAsString();
    expect(readme, contains('Cross-Origin-Opener-Policy'));
    expect(readme, contains('Cross-Origin-Embedder-Policy'));
  });

  test('zip содержит index.html и quest.mnd в корне, а не в подпапке',
      () async {
    final dir = await shell();
    await OfflineWebBuilder.composeSite(
      shellDir: dir,
      questMnd: await File(p.join(temp.path, 'quest.mnd'))
          .writeAsBytes([1, 2, 3]),
    );
    final zipFile = File(p.join(temp.path, 'quest-web.zip'));

    await OfflineWebBuilder.zipSite(dir, zipFile);

    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final names = archive.files.where((f) => f.isFile).map((f) => f.name);
    expect(names, containsAll(['index.html', 'quest.mnd', 'README.txt']));
    expect(names.any((n) => n.startsWith('site/')), isFalse);
  });
}