// Миниатюры карточек канваса: асинхронная загрузка, кэш и отсутствующие файлы.
//
// Художник рисует синхронно, поэтому картинка либо уже в кэше, либо карточка
// рисуется без подложки. Здесь проверяется именно это: загрузка по требованию,
// одно уведомление на картинку, пометка «нет файла» без повторных попыток и
// вытеснение из кэша.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:canvas_app/shared/widgets/canvas_thumbnail_cache.dart';

/// 1×1 PNG.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
  'IQAAAABJRU5ErkJggg==',
);

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('миниатюра не загрузилась за 5 секунд');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File imageFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('thumb_cache_test_');
    imageFile = File('${tempDir.path}/bg.png');
    await imageFile.writeAsBytes(tinyPng);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('картинка грузится по требованию и уведомляет художника', () async {
    var notifications = 0;
    final cache = CanvasThumbnailCache(
      resolver: (questId, source) async => source == 'bg.png'
          ? imageFile.path
          : '',
    )..addListener(() => notifications++);

    expect(cache.imageFor('bg.png'), isNull);

    cache.ensure('q1', 'bg.png');
    await waitFor(() => cache.imageFor('bg.png') != null);

    expect(cache.imageFor('bg.png'), isNotNull);
    expect(notifications, 1);
    cache.dispose();
  });

  test('пустой источник и отсутствующий файл не грузятся повторно', () async {
    var resolutions = 0;
    final cache = CanvasThumbnailCache(
      resolver: (questId, source) async {
        resolutions++;
        return '';
      },
    );

    cache.ensure('q1', 'missing.png');
    cache.ensure('q1', '');
    await waitFor(() => resolutions > 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cache.ensure('q1', 'missing.png');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(resolutions, 1);
    expect(cache.imageFor('missing.png'), isNull);
    cache.dispose();
  });

  test('кэш ограничен по размеру и вытесняет старые картинки', () async {
    final cache = CanvasThumbnailCache(
      maxEntries: 1,
      resolver: (questId, source) async => imageFile.path,
    );

    cache.ensure('q1', 'a.png');
    await waitFor(() => cache.imageFor('a.png') != null);
    cache.ensure('q1', 'b.png');
    await waitFor(() => cache.imageFor('b.png') != null);

    expect(cache.imageFor('a.png'), isNull);
    expect(cache.imageFor('b.png'), isNotNull);
    cache.dispose();
  });
}
