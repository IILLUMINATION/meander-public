import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:canvas_app/core/services/template_bundler.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/template_model.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:path/path.dart' as p;

/// Путь ассета в манифесте шаблона — недоверенный: шаблоны ездят по сети.
/// `../<чужой квест>/config.json` в `applyAssetsToQuest` записывал файл в
/// чужую папку квеста, минуя проверку коллизий.
void main() {
  late Directory appDir;

  setUp(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_template_');
    FileStorage.overrideAppDirectory(appDir);
    final other = Directory(p.join(appDir.path, 'quests', 'q2'));
    await other.create(recursive: true);
    await File(p.join(other.path, 'config.json')).writeAsString('{"title":"q2"}');
  });

  tearDown(() async {
    FileStorage.overrideAppDirectory(null);
    if (await appDir.exists()) await appDir.delete(recursive: true);
  });

  test('ассет с путём наружу не пишется', () async {
    final payload = Uint8List.fromList(utf8.encode('{"evil":true}'));
    final sha = sha256.convert(payload).toString();
    final asset = TemplateAsset(
      relativePath: '../q2/config.json',
      sha256: sha,
      size: payload.length,
      storageFileName: '$sha.json',
    );

    final report = await TemplateBundler.applyAssetsToQuest(
      questId: 'q1',
      assets: [asset],
      bytesBySha: {sha: payload},
    );

    expect(report.copied, 0);
    expect(report.failed, ['../q2/config.json']);
    expect(
      File(p.join(appDir.path, 'quests', 'q2', 'config.json')).readAsStringSync(),
      '{"title":"q2"}',
    );
  });

  test('обычный ассет копируется в папку квеста', () async {
    final payload = Uint8List.fromList(utf8.encode('png'));
    final sha = sha256.convert(payload).toString();
    final asset = TemplateAsset(
      relativePath: 'res/images/bg.png',
      sha256: sha,
      size: payload.length,
      storageFileName: '$sha.png',
    );

    final report = await TemplateBundler.applyAssetsToQuest(
      questId: 'q1',
      assets: [asset],
      bytesBySha: {sha: payload},
    );

    expect(report.copied, 1);
    expect(report.failed, isEmpty);
    expect(
      File(p.join(appDir.path, 'quests', 'q1', 'res', 'images', 'bg.png'))
          .existsSync(),
      isTrue,
    );
  });
}