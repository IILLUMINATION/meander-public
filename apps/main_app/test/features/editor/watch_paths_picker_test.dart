import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/watch_paths_picker_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory appDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('mnd_watch_paths_picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? appDir.path
              : null,
        );
    final dir = Directory('${appDir.path}/quests/q1');
    dir.createSync(recursive: true);
    File('${dir.path}/config.json').writeAsStringSync(
      jsonEncode({
        'variables': [
          {'name': 'Золото', 'defaultValue': 15},
          {'name': 'Здоровье', 'defaultValue': '100'},
          // Служебные переменные движок не отдаёт — подсказки не должно быть.
          {'name': '_служебная', 'defaultValue': 1},
        ],
        'tables': [
          {
            'name': 'лавка',
            'columns': ['цена'],
            'rows': [
              {'цена': '50'},
              {'цена': '120'},
            ],
            'data': {'цена': 50},
          },
        ],
      }),
    );
  });

  tearDownAll(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  /// Пикер читает конфиг квеста с диска. Настоящий IO — только в `runAsync`,
  /// иначе `await` dart:io внутри testWidgets не завершится в fake-async зоне.
  Future<void> settleWithIo(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<List<String>>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const WatchPathsPickerScreen(questId: 'q1'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settleWithIo(tester);
  }

  test('путь ячейки совпадает с токеном движка: ряды с 1', () {
    // Движок отдаёт изменение ячейки как `table.лавка.цена.1`
    // (crates/mnd-core: table_tokens_are_granular_and_cells_are_one_based).
    // Негативный контроль: при нумерации с нуля первая ячейка не совпала бы.
    expect(watchPathForCell('лавка', 'цена', 1), 'лавка.цена.1');
    expect(watchPathForCell('лавка', 'цена', 2), 'лавка.цена.2');
  });

  testWidgets('переменные отмечаются пачкой, ячейка таблицы — из сетки', (
    tester,
  ) async {
    // Высокое окно: список ленивый, и без этого таблица ниже вьюпорта не
    // построится вовсе — искать её бессмысленно.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    List<String>? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await Navigator.push<List<String>>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const WatchPathsPickerScreen(questId: 'q1'),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settleWithIo(tester);

    expect(find.text('Золото'), findsOneWidget);
    expect(find.text('Здоровье'), findsOneWidget);
    expect(find.text('_служебная'), findsNothing);

    await tester.ensureVisible(find.text('Здоровье'));
    await tester.tap(find.text('Здоровье'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('лавка'));
    await tester.tap(find.text('лавка'));
    await tester.pumpAndSettle();
    expect(find.text('лавка.*'), findsOneWidget);

    await tester.ensureVisible(find.text('цена'));
    await tester.tap(find.text('цена'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Строка 2'));
    await tester.tap(find.text('Строка 2'));
    await tester.pumpAndSettle();

    expect(find.text('Выбрано: 2'), findsOneWidget);
    await tester.tap(find.text('Выбрано: 2'));
    await tester.pumpAndSettle();

    expect(picked, ['Здоровье', 'лавка.цена.2']);
  });

  testWidgets('ручной ввод через запятую добавляет сразу несколько путей', (
    tester,
  ) async {
    // Кнопка «Добавить путь» замыкает ленивый список: в низком окне она
    // просто не построится.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openPicker(tester);

    await tester.tap(find.text('Добавить путь'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'лавка.цена.1, здоровье',
    );
    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();

    expect(find.text('Выбрано: 2'), findsOneWidget);
  });
}
