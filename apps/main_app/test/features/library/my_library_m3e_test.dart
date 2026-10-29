import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/features/library/screens/my_library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('экран «Моя библиотека» рендерится на M3E', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final temp = Directory.systemTemp.createTempSync('mnd_library_test_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final library = Directory('${temp.path}/my_library')..createSync();
    File('${library.path}/index.json').writeAsStringSync(
      jsonEncode({
        'items': [
          {
            'id': 'bg-1',
            'kind': 'background',
            'title': 'Фон леса',
            'fileUrl': 'https://example.com/bg.png',
            'license': 'CC-BY',
            'addedAt': 1,
          },
        ],
      }),
    );
    File('${library.path}/music_index.json').writeAsStringSync(
      jsonEncode({
        'items': [
          {
            'id': 'track-1',
            'title': 'Тихая ночь',
            'performer': 'Meander',
            'fileUrl': 'https://example.com/track.mp3',
            'license': 'CC-BY',
            'addedAt': 1,
          },
        ],
      }),
    );

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => temp.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
            home: const MyLibraryScreen(pickerMode: true, questId: 'test'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(tester.takeException(), isNull);
    expect(find.text('Моя библиотека'), findsOneWidget);
    expect(find.text('Ресурсы'), findsOneWidget);
    expect(find.text('Музыка'), findsOneWidget);
    expect(find.text('Фон леса'), findsOneWidget);

    await tester.tap(find.text('Музыка'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('Тихая ночь'), findsOneWidget);
  });
}
