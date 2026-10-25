// Событие «При изменении данных»: подписки должны доживать до файла квеста.
//
// Движок читает пути из ключа `watchPaths` и сам находит такие блоки, поэтому
// всё, что теряет редактор, — это молчащий скрипт: подписки либо доехали до
// JSON, либо игрок никогда не увидит, что диспетчер вообще был.

import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/parser.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/widgets/event_block_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpEvent(
  WidgetTester tester,
  EventBlock block, {
  double width = 900,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: EventBlockWidget(
                block: block,
                questId: 'q1',
                onBlockDrop: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory appDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('mnd_data_watch_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return appDir.path;
      }
      return null;
    });
  });

  tearDownAll(() async {
    if (appDir.existsSync()) {
      await appDir.delete(recursive: true);
    }
  });

  /// Шит читает конфиг квеста с диска. Настоящий IO — только в `runAsync`, а
  /// `await` dart:io внутри testWidgets повесил бы тест на fake-async.
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

  group('сериализация подписок', () {
    test('пустой список не попадает в файл квеста', () {
      final json = EventBlock(eventType: EventType.onDataChange).toJson();

      expect(json.containsKey('watchPaths'), isFalse);
      expect(json['eventType'], 'onDataChange');
    });

    test('несколько путей пишутся массивом и переживают round-trip', () {
      final block = EventBlock(
        eventType: EventType.onDataChange,
        watchPaths: ['Золото', 'лавка.цена', 'лавка.цена.3', '*'],
      );

      final restored = EventBlock.fromJson(block.toJson());

      expect(restored.eventType, EventType.onDataChange);
      expect(restored.watchPaths, ['Золото', 'лавка.цена', 'лавка.цена.3', '*']);
    });

    test('строка через запятую и старый watchVariables читаются', () {
      final fromString = EventBlock.fromJson({
        'type': 'event',
        'eventType': 'onDataChange',
        'watchPaths': 'Золото, лавка.цена,, Золото',
      });
      final fromLegacy = EventBlock.fromJson({
        'type': 'event',
        'eventType': 'onDataChange',
        'watchVariables': ['health'],
      });

      // Дубли и пустые куски вычищаются: движок по ним строит формы подписки.
      expect(fromString.watchPaths, ['Золото', 'лавка.цена']);
      expect(fromLegacy.watchPaths, ['health']);
    });
  });

  group('парсер против Rust-карты заголовков', () {
    test('заголовок «При изменении данных» становится onDataChange', () {
      // Ядро (script_format.rs) по этому же заголовку кладет eventType;
      // без строки в Dart-парсере блок уехал бы в onContentAppear и
      // сработал при показе контента.
      final normalized = ScriptParser.normalizeBlockJson({
        'type': 'event',
        'title': 'При изменении данных',
        'watchPaths': ['Золото'],
      });

      expect(normalized['eventType'], EventType.onDataChange.name);
    });

    test('обычные заголовки не меняются', () {
      expect(
        ScriptParser.normalizeBlockJson({
          'title': 'При запуске квеста',
        })['eventType'],
        EventType.onQuestStart.name,
      );
      expect(
        ScriptParser.normalizeBlockJson({'title': 'Мой скрипт'})['eventType'],
        EventType.onContentAppear.name,
      );
    });
  });

  group('блок в редакторе', () {
    testWidgets('событие показывает поле подписок и чип в шапке', (
      tester,
    ) async {
      await pumpEvent(tester, EventBlock(eventType: EventType.onDataChange));

      // Заголовок в шапке + то же значение в поле «Тип».
      expect(find.text('При изменении данных'), findsNWidgets(2));
      expect(find.text('Следить'), findsOneWidget);
      // Пустые подписки = «любое изменение», и это видно без шита.
      expect(find.text('любое изменение'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('обычное событие поля «Следить» не получает', (tester) async {
      await pumpEvent(tester, EventBlock(eventType: EventType.onNodeEnter));

      expect(find.text('Следить'), findsNothing);
      expect(find.byIcon(Icons.change_circle_rounded), findsNothing);
    });

    testWidgets('в свёрнутом блоке список подписок остаётся видимым', (
      tester,
    ) async {
      await pumpEvent(
        tester,
        EventBlock(
          eventType: EventType.onDataChange,
          watchPaths: ['Золото', 'лавка.цена', 'health'],
        ),
      );

      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await tester.pumpAndSettle();

      // Тело (поле «Следить») скрыто — остаётся чип «первый +N».
      expect(find.text('Следить'), findsNothing);
      expect(find.text('Золото +2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('экран показывает подсказки из конфига и собирает список', (
      tester,
    ) async {
      // Высокое окно: полный экран пикера — ленивый список, в дефолтных
      // 800×600 таблица ниже вьюпорта не построится вовсе.
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Синхронный IO: `await` dart:io внутри testWidgets попадает в
      // fake-async зону и вешает тест.
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

      final block = EventBlock(
        eventType: EventType.onDataChange,
        watchPaths: ['Золото'],
      );
      await pumpEvent(tester, block);

      await tester.tap(find.text('Следить'));
      await settleWithIo(tester);

      expect(find.text('Следить за изменениями'), findsOneWidget);
      // Свёрнутая таблица показывает свой путь до раскрытия.
      expect(find.text('лавка.*'), findsOneWidget);

      // Столбцы лежат внутри таблицы: раскрываем её, и путь столбца виден.
      await tester.ensureVisible(find.text('лавка'));
      await tester.tap(find.text('лавка'));
      await tester.pumpAndSettle();
      // У таблицы ключ данных и столбец сетки называются одинаково: путь
      // должен быть в списке один раз.
      expect(find.text('лавка.цена'), findsOneWidget);
      expect(find.text('_служебная'), findsNothing);

      // Массовый выбор переменной — чекбоксом, а не отдельным тапом-чипом.
      await tester.ensureVisible(find.text('Здоровье'));
      await tester.tap(find.text('Здоровье'));
      await tester.pumpAndSettle();

      // Конкретная ячейка: таблица → столбец → ряд (номера с 1).
      await tester.ensureVisible(find.text('цена'));
      await tester.tap(find.text('цена'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Строка 2'));
      await tester.tap(find.text('Строка 2'));
      await tester.pumpAndSettle();

      // «Золото» уже был выбран изначально — вместе с «Здоровье» и ячейкой
      // получается три пути.
      await tester.tap(find.text('Выбрано: 3'));
      await tester.pumpAndSettle();

      expect(block.watchPaths, ['Золото', 'Здоровье', 'лавка.цена.2']);
      expect(tester.takeException(), isNull);

      dir.deleteSync(recursive: true);
    });

    testWidgets('на узком экране чип подписки не устраивает переполнение', (
      tester,
    ) async {
      await pumpEvent(
        tester,
        width: 320,
        EventBlock(
          eventType: EventType.onDataChange,
          watchPaths: ['veryLongVariableNameThatWillNotFit', 'лавка.цена.3'],
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.change_circle_rounded), findsWidgets);
    });
  });
}
