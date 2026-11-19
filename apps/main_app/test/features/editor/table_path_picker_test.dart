// Пикер пути блока «Данные»: путь — это ключ хранилища скриптов или адрес
// ячейки сетки. Раньше сетка не была путём, и автор, глядя на пустой список,
// писал в поле имя колонки. Теперь чипы сетки подставляют адрес
// ["колонка"][1] / ["колонка"]["имя"], который понимают «Записать» и
// «Получить».

import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/table_path_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('путь собирается из ключей, индексов и кавычек', () {
    expect(tablePathOf(['gold']), 'gold');
    expect(
      tablePathOf(['персонаж', 'инвентарь', 0]),
      'персонаж["инвентарь"][0]',
    );
    expect(tablePathOf(['a"b']), '["a\\"b"]');
    expect(tablePathOf([0]), '[0]');
  });

  test('ссылка для текста оборачивает путь и имя таблицы', () {
    expect(tableTextReference('лавка', 'gold'), '{лавка["gold"]}');
    expect(
      tableTextReference('лавка', 'персонаж["инвентарь"][0]'),
      '{лавка["персонаж"]["инвентарь"][0]}',
    );
    expect(
      tableTextReference('лавка', '["название"][1]'),
      '{лавка["название"][1]}',
    );
    expect(tableTextReference('лавка', ''), '{лавка}');
  });

  late Directory appDir;
  String? chosen;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('mnd_path_picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? appDir.path
              : null,
        );
  });

  tearDownAll(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  /// Конфиг пишем до тела теста: `await` dart:io внутри testWidgets попадает
  /// в fake-async зону и не завершается.
  Future<void> writeConfig(String questId, Map<String, dynamic> table) async {
    final dir = Directory('${appDir.path}/quests/$questId');
    await dir.create(recursive: true);
    await File('${dir.path}/config.json').writeAsString(
      jsonEncode({
        'variables': ['золото'],
        'tables': [table],
      }),
    );
  }

  setUp(() async {
    chosen = null;
    await writeConfig('q_grid', {
      'name': 'фрукты',
      'columns': ['название', 'цвет'],
      'rows': [
        {'название': 'тыква', 'цвет': 'жёлтый'},
        {'название': 'киви', 'цвет': 'зелёный'},
      ],
      'data': {},
      'folderPath': '/',
    });
    await writeConfig('q_nested', {
      'name': 'фрукты',
      'columns': ['название'],
      'rows': [
        {'название': 'тыква'},
      ],
      'data': {
        'корзина': {
          'инвентарь': ['меч'],
          'открыто': true,
        },
      },
      'folderPath': '/',
    });
    await writeConfig('q_keys', {
      'name': 'фрукты',
      'columns': ['название'],
      'rows': [
        {'название': 'тыква'},
      ],
      'data': {
        'корзина': ['тыква', 'киви'],
        'открыто': true,
      },
      'folderPath': '/',
    });
  });

  Future<void> openPicker(
    WidgetTester tester,
    String questId,
    String table,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  chosen = await pickTablePath(
                    context,
                    questId: questId,
                    tableName: table,
                    operation: TableOperation.set,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // Реальный IO доходит только внутри runAsync.
    await tester.runAsync(() async {
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('пустое хранилище: ячейка сетки подставляется как путь', (
    tester,
  ) async {
    await openPicker(tester, 'q_grid', 'фрукты');

    expect(find.textContaining('адрес ячейки сетки'), findsOneWidget);
    expect(find.textContaining('рядов сетки'), findsOneWidget);
    // Вторую колонку проверяет только текст: горизонтальный список на 360 px
    // её не вмещает, она за прокруткой.
    expect(find.text('["название"][1]'), findsOneWidget);

    await tester.tap(find.text('["название"][1]'));
    await tester.pumpAndSettle();
    // Тап по чипу возвращает путь и закрывает пикер.
    expect(chosen, '["название"][1]');
    expect(find.text('Путь в «фрукты»'), findsNothing);
  });

  testWidgets('ключи хранилища — это и есть пути, тап возвращает ключ', (
    tester,
  ) async {
    await openPicker(tester, 'q_keys', 'фрукты');

    expect(find.text('корзина'), findsOneWidget);
    expect(find.text('открыто'), findsOneWidget);

    await tester.tap(find.text('корзина'));
    await tester.pumpAndSettle();
    expect(chosen, 'корзина');
  });

  testWidgets('вложенный ключ раскрывается и выбирается полным путём', (
    tester,
  ) async {
    await openPicker(tester, 'q_nested', 'фрукты');

    // На корневом уровне контейнер один: у него есть кнопка раскрытия.
    expect(find.byTooltip('Открыть вложенные'), findsOneWidget);
    await tester.tap(find.byTooltip('Открыть вложенные'));
    await tester.pumpAndSettle();

    expect(find.text('инвентарь'), findsOneWidget);
    expect(find.text('открыто'), findsOneWidget);
    // Вложенный путь виден в подписи, а не только после выбора.
    expect(find.textContaining('корзина["инвентарь"]'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('инвентарь'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Открыть вложенные'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('[0]'), findsOneWidget);
    expect(find.textContaining('корзина["инвентарь"][0]'), findsOneWidget);

    await tester.tap(find.text('[0]'));
    await tester.pumpAndSettle();
    expect(chosen, 'корзина["инвентарь"][0]');
  });

  testWidgets('на вложенном уровне можно выбрать сам контейнер', (
    tester,
  ) async {
    await openPicker(tester, 'q_nested', 'фрукты');
    await tester.tap(find.byTooltip('Открыть вложенные'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Выбрать путь'));
    await tester.pumpAndSettle();
    expect(chosen, 'корзина');
  });
}
