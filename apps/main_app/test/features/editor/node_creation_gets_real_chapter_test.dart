// Нода, созданная из пикера, обязана родиться в существующей главе.
//
// `NodeSelectionScreen._createAndSelectNewNode` брал главу из текущей ноды,
// иначе — из списка глав. В свежем квесте глав нет (`config.json` создаётся с
// `'tags': []`), и старый код подставлял в `chapterId` случайный Uuid.
// Канвас фильтрует ноды по главе, поэтому такая нода не появлялась ни в одной
// главе: новичок жал «Создать ноду», видел «Создана нода: …» — и тут же терял
// её: ни на графе, ни в списке. Экран к тому же закрывался «успехом», когда
// `saveNodes` возвращал false.
//
// Здесь работает настоящий диск во временной папке, поэтому проверка читает
// nodes.json и config.json, а не переопределённые провайдеры.
//
// В ФАЙЛЕ ОДИН ТЕСТ — это не случайность. Цепочка провайдера, начатая во
// втором `testWidgets` того же файла, не возобновляется после первого `await`:
// `allQuestNodesProvider` доходит до `await _qs()` и замирает, хотя тот же
// `QuestStore.synchronized` и те же файловые вызовы в том же окне `runAsync`
// отрабатывают. Проверено: первый тест в файле проходит, второй висит на
// загрузке списка. Поэтому сюжеты (пустой квест, живая глава, сломанный диск)
// идут актами одного теста — как и сессия новичка.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ (проверено тремя мутациями, каждая роняет свой акт):
//  • `chapterId = const Uuid().v4()` вместо `createTag` — падает акт 1: главы
//    так и нет, нода сирота;
//  • `createTag` всегда, без чтения живых глав — падает акт 2: ноды разъезжаются
//    по разным главам, хотя вторая главе неоткуда взяться;
//  • `await saveNodes(...)` без проверки результата — падает акт 3: пикер
//    закрывается «успехом», хотя нода не записана.

import 'dart:io';

import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

late String _questId;
late Directory _appDir;

/// Id, которыми пикер закрывался: пустой хвост означает, что выбор ещё не
/// завершился (или завершился ошибкой и экран остался открыт).
final List<String?> _pops = [];

/// Реальный диск из fake-зоны виджет-теста не обслуживается: `File.exists()`
/// или `rename()`, запущенные из тела теста, зависают навсегда. Файловые
/// операции — и тапы, которые их запускают — гоняем через `runAsync`, как в
/// `quest_create_offline_test.dart`.
/// Реальный event loop для операции с результатом.
Future<T> _io<T>(WidgetTester tester, Future<T> Function() action) async {
  final result = await tester.runAsync<T>(action);
  if (result == null) throw TestFailure('runAsync не отдал результат');
  return result;
}

/// То же для операций без результата: `void` из `runAsync` приходит как null,
/// и `!` на нём падает. Тап тоже запускает файловые операции, поэтому он
/// вместе с ними живёт в `runAsync`.
Future<void> _run(WidgetTester tester, Future<void> Function() action) async {
  await tester.runAsync<void>(action);
}

Future<Map<String, dynamic>> _readConfig(WidgetTester tester) =>
    _io(tester, () => FileStorage.readJsonFile(QuestPaths.config(_questId)));

Future<List<Map<String, dynamic>>> _nodesOnDisk(WidgetTester tester) async =>
    ((await _io(
              tester,
              () => FileStorage.readJsonFile(QuestPaths.nodesLegacy(_questId)),
            ))['nodes']
            as List)
        .cast<Map<String, dynamic>>();

Future<List<Map<String, dynamic>>> _chaptersOnDisk(WidgetTester tester) async =>
    ((await _readConfig(tester))['tags'] as List).cast<Map<String, dynamic>>();

/// Кадры и настоящий event loop по очереди: одна часть цепочки провайдера
/// живёт на фейковом времени, другая — на реальных таймерах.
Future<void> _pumpReal(WidgetTester tester) async {
  await _run(
    tester,
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// Снимок всего текста на экране: иначе таймаут прогона неотличим от «пикер
/// показал ошибку вместо списка».
String _visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
    .where((value) => value.isNotEmpty)
    .join(' | ');

/// Гоним кадры, пока не наступит [done] (или пока не кончится запас шагов).
/// Фиксированный прогон здесь ненадёжен: диск в `runAsync` идёт в реальном
/// времени, и после инвалидации провайдеров пикер успевает показать спиннер.
Future<void> _driveUntil(
  WidgetTester tester,
  bool Function() done, {
  int steps = 120,
}) async {
  for (var step = 0; step < steps; step++) {
    if (done()) return;
    await _pumpReal(tester);
  }
  throw TestFailure(
    'условие не наступило за $steps шагов; текст на экране: '
    '${_visibleText(tester)}',
  );
}

/// Создание ноды доступно висячей кнопкой и при пустом списке, и при непустом,
/// поэтому все акты жмут именно её.
Finder _createFab() =>
    find.widgetWithText(FloatingActionButton, 'Создать новую');

/// Пикер готов к новому созданию: список прочитан и висячая кнопка реально
/// принимает тап — её не перекрывает ни плашка, ни ещё не доигранный переход
/// маршрута (`ModalRoute` игнорирует указатели, пока анимация не завершена).
/// `hitTestable()` проверяет оба случая сразу; без него тап молча уходил мимо,
/// и тест выглядел зависшим.
bool _pickerLoaded(WidgetTester tester) =>
    _createFab().evaluate().length == 1 &&
    _createFab().hitTestable().evaluate().length == 1 &&
    find.byType(CircularProgressIndicator).evaluate().isEmpty;

/// Открывает пикер с хостового экрана и жмёт создание ноды.
///
/// Ждём развязки, а не кадра: хостовый экран остаётся в дереве виджетов под
/// пикером, поэтому «вернулись домой» по finder'у не проверить — оно совпадает
/// сразу. [failureMessage] — текст, которым заканчивается создание при сбое;
/// без него ждём успешного закрытия пикера.
Future<void> _createNode(WidgetTester tester, {Finder? failureMessage}) async {
  final before = _pops.length;

  await _run(tester, () => tester.tap(find.text('открыть пикер')));
  await _driveUntil(tester, () => _pickerLoaded(tester));

  await _run(tester, () => tester.tap(_createFab()));
  await _driveUntil(
    tester,
    () =>
        // Пикер закрылся и его маршрут доиграл: иначе висячая кнопка старого
        // маршрута ещё в дереве, и следующий тап ищет две кнопки.
        (_pops.length > before &&
            find.text('открыть пикер').hitTestable().evaluate().isNotEmpty) ||
        (failureMessage?.evaluate().isNotEmpty ?? false),
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _appDir = await Directory.systemTemp.createTemp('mnd_node_chapter_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return _appDir.path;
          }
          return null;
        });
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _pops.clear();
    // Корень документов приходит через платформенный канал: греем его заранее,
    // пока не началась fake-зона виджет-теста.
    await FileStorage.getAppDirectory();
    _questId = const Uuid().v4();
    // Квест новичка: ни глав, ни нод.
    await FileStorage.writeJsonFile(QuestPaths.config(_questId), {
      'id': _questId,
      'title': 'Первый квест',
      'startNodeId': '',
      'tags': [],
      'connections': [],
    });
    await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
      'nodes': [],
    });
  });

  tearDown(() async {
    // Каталог квеста удаляется мимо FileStorage — его кэш JSON по этим путям
    // больше не действителен.
    FileStorage.invalidateJsonCache([
      QuestPaths.config(_questId),
      QuestPaths.nodesLegacy(_questId),
    ]);
    final dir = Directory('${_appDir.path}/quests');
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  tearDownAll(() async {
    if (_appDir.existsSync()) await _appDir.delete(recursive: true);
  });

  testWidgets('новичок создаёт ноды: глава, повтор и сбой записи', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    _pops.add(
                      await Navigator.of(context).push<String>(
                        MaterialPageRoute(
                          builder: (_) => NodeSelectionScreen(
                            questId: _questId,
                            allowCreate: true,
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('открыть пикер'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Акт 1: пустой квест. Новая нода обязана получить существующую главу,
    // иначе канвас её не покажет.
    await _createNode(tester);
    expect(_pops, hasLength(1));

    final chapters = await _chaptersOnDisk(tester);
    expect(chapters, hasLength(1));
    expect(chapters.first['name'], 'Глава 1');

    var nodes = await _nodesOnDisk(tester);
    expect(nodes, hasLength(1));
    expect(nodes.single['chapterId'], chapters.first['id']);
    expect(_pops.single, nodes.single['id']);

    // Акт 2: глава уже есть — вторая не нужна, нода становится в ту же.
    await _createNode(tester);
    expect(_pops, hasLength(2));

    nodes = await _nodesOnDisk(tester);
    expect(nodes, hasLength(2));
    expect(
      nodes.map((node) => node['chapterId']),
      everyElement(chapters.first['id']),
      reason: 'обе ноды в одной главе',
    );
    expect(
      await _chaptersOnDisk(tester),
      hasLength(1),
      reason: 'не множить главы',
    );

    // Акт 3: nodes.json подменяем каталогом — запись в него всегда падает.
    // Файл удаляем мимо FileStorage, чтобы кэш JSON остался: тогда список нод
    // прочитается, пикер откроется, и споткнётся именно запись.
    await _run(tester, () async {
      final path = await FileStorage.getFilePath(
        QuestPaths.nodesLegacy(_questId),
      );
      await File(path).delete();
      await Directory(path).create();
    });

    await _createNode(
      tester,
      failureMessage: find.text('Не удалось сохранить ноду'),
    );

    expect(_pops, hasLength(2), reason: 'выбор не должен завершиться id ноды');
    // Пикер остался открыт: новичок видит, что не вышло, а не пустой граф.
    expect(find.byType(NodeSelectionScreen), findsOneWidget);
    expect(find.text('Не удалось сохранить ноду'), findsOneWidget);
  });
}
