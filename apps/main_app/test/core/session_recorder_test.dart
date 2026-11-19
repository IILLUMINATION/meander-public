import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/core/services/session_recorder.dart';

/// Запись сессии тестировщика: журнал событий пишется в файл построчно
/// (JSONL), сводка собирается из тех же событий.
///
/// Контракты, которые ломать нельзя: файл появляется сразу, каждая строка —
/// валидный JSON, `session.start`/`session.stop` обрамляют журнал, а сводка
/// содержит то, что нужно для отчёта (экраны, редактор, скрипты, ошибки,
/// нажатия).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  final recorder = SessionRecorder.instance;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('mnd_session');
    SessionRecorder.directoryOverride = tmpDir;
    SessionRecorder.maxRetainedEvents = 5000;
    recorder.resetForTest();
  });

  tearDown(() async {
    await recorder.stop();
    recorder.resetForTest();
    SessionRecorder.directoryOverride = null;
    if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
  });

  List<Map<String, dynamic>> readEvents(File file) => file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();

  test('журнал пишет события в файл строками JSON', () async {
    await recorder.start(questId: 'quest-1', note: 'ручной прогон');
    expect(recorder.isRecording, isTrue);
    final path = recorder.currentFilePath;
    expect(path, isNotNull);
    final file = File(path!);
    expect(file.existsSync(), isTrue);

    recorder.record('editor', {'action': 'open', 'doc': 'node:1'});
    recorder.recordError('boom', StackTrace.current, context: 'test');
    await recorder.stop('manual');

    final events = readEvents(file);
    expect(events.first['type'], 'session.start');
    expect(events.first['questId'], 'quest-1');
    expect(events.first['note'], 'ручной прогон');
    expect(events.last['type'], 'session.stop');
    expect(events.last['reason'], 'manual');
    expect(
      events.any((e) => e['type'] == 'editor' && e['doc'] == 'node:1'),
      isTrue,
    );
    expect(events.any((e) => e['type'] == 'error'), isTrue);

    // Время монотонно: `t` — миллисекунды от старта сессии.
    final stamps = [for (final e in events) e['t'] as int];
    expect(stamps, orderedEquals([...stamps]..sort()));
  });

  test('после остановки события не пишутся ни в память, ни в файл', () async {
    await recorder.start();
    final file = File(recorder.currentFilePath!);
    await recorder.stop('manual');
    final before = file.lengthSync();
    final count = recorder.eventCount;

    recorder.record('editor', {'action': 'после стопа'});
    await recorder.stop('повторный стоп');

    expect(recorder.eventCount, count);
    expect(recorder.isActive, isFalse);
    expect(file.lengthSync(), before);
    expect(
      readEvents(file).where((e) => e['action'] == 'после стопа'),
      isEmpty,
    );
  });

  test('сводка перечисляет экраны, скрипты, ошибки и нажатия', () async {
    await recorder.start(questId: 'quest-2');
    recorder.noteRoute('NodeContentScreen');
    recorder.record('route', {'action': 'push', 'route': 'NodeContentScreen'});
    recorder.record('script', {
      'action': 'save',
      'scriptId': 'sc-1',
      'blocks': 4,
      'ok': false,
      'error': 'нет доступа',
    });
    recorder.record('tap', {
      'x': 10,
      'y': 20,
      'labels': ['Сохранить'],
    });
    recorder.recordError('boom', null);

    final digest = recorder.buildDigest();
    expect(digest, contains('Запись сессии тестировщика'));
    expect(digest, contains('## Экраны (1)'));
    expect(digest, contains('NodeContentScreen'));
    expect(digest, contains('## Скрипты (1)'));
    expect(digest, contains('sc-1'));
    expect(digest, contains('## Ошибки (1)'));
    expect(digest, contains('boom'));
    expect(digest, contains('## Нажатия (1)'));
    expect(digest, contains('Сохранить'));
  });

  test('в памяти хранится не больше maxRetainedEvents событий', () async {
    SessionRecorder.maxRetainedEvents = 10;
    await recorder.start();
    for (var i = 0; i < 40; i++) {
      recorder.record('tap', {'x': i});
    }
    // session.start + 40 нажатий, в памяти — последние 10.
    expect(recorder.eventCount, 10);
    expect(recorder.events.last['x'], 39);
    final path = recorder.currentFilePath!;
    await recorder.stop();
    // В файл при этом попали все события.
    expect(readEvents(File(path)).length, greaterThan(40));
  });

  test('без записи record() ничего не делает', () {
    recorder.record('tap', {'x': 1});
    expect(recorder.eventCount, 0);
    expect(recorder.isRecording, isFalse);
  });

  testWidgets('переходы между экранами попадают в журнал', (tester) async {
    recorder.seedForTest();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [SessionRecorderNavigatorObserver()],
        home: const Scaffold(body: Text('HOME')),
      ),
    );

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'EditorRoute'),
        builder: (_) => const Scaffold(body: Text('EDITOR')),
      ),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    final routes = [
      for (final event in recorder.events)
        if (event['type'] == 'route') '${event['action']}:${event['route']}',
    ];
    expect(routes, contains('push:EditorRoute'));
    expect(routes, contains('pop:EditorRoute'));
  });

  testWidgets('тап записывается с подписями элементов под пальцем', (
    tester,
  ) async {
    // Без файла: настоящий I/O в fake-async `testWidgets` не выполняется.
    recorder.seedForTest();
    await tester.pumpWidget(
      MaterialApp(
        home: SessionTapRecorder(
          child: Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {},
                child: const Text('Сохранить'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Сохранить'));
    await tester.pump();

    final taps = recorder.events.where((e) => e['type'] == 'tap').toList();
    expect(taps, hasLength(1));
    final labels = (taps.single['labels'] as List).cast<String>();
    expect(labels, contains('Сохранить'));
  });
}
