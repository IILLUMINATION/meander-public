// «Отправить .mnd» — это не экспорт в проводник: на телефоне файл должен
// уйти в системную шторку. Проверяем, что в ShareParams попадает именно
// собранный `.mnd` с человеческим именем и заголовком квеста.

import 'dart:io';

import 'package:canvas_app/core/services/quest_mnd_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

class _FakeSharePlatform extends SharePlatform {
  ShareResult result = const ShareResult('ok', ShareResultStatus.success);
  ShareParams? lastParams;

  @override
  Future<ShareResult> share(ShareParams params) async {
    lastParams = params;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _FakeSharePlatform fake;

  setUpAll(() {
    // `SharePlus.instance` запоминает платформу при первом обращении;
    // подменяем её один раз до всех тестов и меняем только результат.
    fake = _FakeSharePlatform();
    SharePlatform.instance = fake;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mnd_share_test');
    fake.result = const ShareResult('ok', ShareResultStatus.success);
    fake.lastParams = null;
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('shareTempFile отдаёт шторке файл .mnd с именем квеста', () async {
    final file = File('${dir.path}/export_quest_123.mnd')
      ..writeAsBytesSync([1, 2, 3]);

    final result = await QuestMndShare.shareTempFile(
      file,
      'Мой: квест?',
      canShareFiles: true,
    );

    expect(result, QuestMndShareResult.shared);
    expect(fake.lastParams!.files!.single.path, file.path);
    expect(fake.lastParams!.fileNameOverrides, ['Мой_ квест_.mnd']);
    expect(fake.lastParams!.subject, 'Мой: квест?');
    expect(fake.lastParams!.text, contains('Мой: квест?'));
  });

  test('закрытая шторка — это отмена, а не отправка', () async {
    final file = File('${dir.path}/export_quest_123.mnd')
      ..writeAsBytesSync([1, 2, 3]);
    fake.result = const ShareResult('', ShareResultStatus.dismissed);

    final result = await QuestMndShare.shareTempFile(
      file,
      'Квест',
      canShareFiles: true,
    );

    expect(result, QuestMndShareResult.cancelled);
  });
}
