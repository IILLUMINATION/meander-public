import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/features/editor/workspace/editor_back_handler.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_nested_documents.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
import 'package:canvas_app/features/editor/workspace/editor_screen_tabs.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_session.dart';
import 'package:canvas_app/features/editor/workspace/quest_editor_shell.dart';

/// Навигация «Назад» на маршруте редактора.
///
/// Жалоба: «просто кидает на 2 экрана назад … выкидывает считай из рабочего
/// поля». Тесты монтируют настоящий шелл обычным маршрутом поверх экрана
/// «DETAILS» и жмут системную «Назад» — то же самое сообщение («popRoute»),
/// которое шлёт операционка по аппаратной кнопке.
///
/// Экраны документов подменены фейковыми: настоящие тянут Rust-ядро и файлы
/// квеста, а проверять здесь нужно именно поведение шелла.
void main() {
  tearDown(EditorNestedDocuments.resetForTest);

  testWidgets('вложенный редактор открывается вкладкой, не пряча таб-бар', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_tool');
    final context = tester.element(find.text('DOC:a'));
    final id = EditorDocumentId(
      questId: 'q_tool',
      kind: EditorDocumentKind.tool,
      key: 'stack:a:item1',
    );

    final future = EditorNestedDocuments.open<void>(
      context,
      questId: 'q_tool',
      identity: 'stack:a:item1',
      title: 'Стек',
      builder: (_) => const Scaffold(body: Center(child: Text('TOOL'))),
    );
    await h.settle();

    expect(h.keys, ['a', 'stack:a:item1']);
    expect(h.activeKind, EditorDocumentKind.tool);
    expect(find.text('TOOL'), findsOneWidget);
    expect(find.text('Стек'), findsOneWidget, reason: 'вкладка подписана');

    await EditorWorkspaceScope.of(
      tester.element(find.text('TOOL')),
    ).closeDocument(id);
    await h.settle();
    await future;

    expect(h.keys, ['a']);
    expect(h.activeKey, 'a');
  });

  testWidgets('домик открывает меню квеста вкладкой, а не закрывает редактор', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_menu');

    await tester.tap(find.byTooltip('В меню квеста'));
    await h.settle();

    expect(h.keys, ['a', 'quest-menu']);
    expect(h.activeKey, 'quest-menu');
    expect(h.activeKind, EditorDocumentKind.questMenu);
    expect(find.text('Меню квеста'), findsWidgets, reason: 'вкладка подписана');

    // Повторный домик фокусирует существующую вкладку, а не плодит копии.
    await tester.tap(find.byTooltip('В меню квеста'));
    await h.settle();
    expect(h.keys.where((key) => key == 'quest-menu').length, 1);
  });

  testWidgets('произвольный экран приложения открывается вкладкой', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_screen');

    final future = EditorScreenTabs.open<void>(
      tester.element(find.text('DOC:a')),
      identity: 'market',
      title: 'Каталог',
      builder: (_) => const Scaffold(body: Center(child: Text('MARKET'))),
    );
    await h.settle();

    expect(h.keys, ['a', 'market']);
    expect(h.activeKind, EditorDocumentKind.screen);
    expect(find.text('MARKET'), findsOneWidget);

    await EditorWorkspaceScope.of(
      tester.element(find.text('MARKET')),
    ).closeDocument(
      EditorDocumentId(
        questId: 'q_screen',
        kind: EditorDocumentKind.screen,
        key: 'market',
      ),
    );
    await h.settle();
    await future;
    expect(h.keys, ['a']);
  });

  testWidgets('«Назад» внутри вкладки снимает её маршрут, а не вкладку', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_tool_back');
    final id = EditorDocumentId(
      questId: 'q_tool_back',
      kind: EditorDocumentKind.tool,
      key: 'stack:a:item2',
    );

    final future = EditorNestedDocuments.open<void>(
      tester.element(find.text('DOC:a')),
      questId: 'q_tool_back',
      identity: 'stack:a:item2',
      title: 'Стек',
      builder: (_) => Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const Scaffold(body: Center(child: Text('PICKER'))),
                ),
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    );
    await h.settle();
    await tester.tap(find.text('OPEN'));
    await h.settle();
    expect(find.text('PICKER'), findsOneWidget);

    await h.pressBack();

    expect(find.text('PICKER'), findsNothing, reason: 'маршрут пикера снят');
    expect(find.text('OPEN'), findsOneWidget, reason: 'вкладка осталась');
    expect(h.keys, ['a', 'stack:a:item2']);
    expect(h.activeKey, 'stack:a:item2');

    await EditorWorkspaceScope.of(
      tester.element(find.text('OPEN')),
    ).closeDocument(id);
    await h.settle();
    await future;
  });

  testWidgets(
    'одна вкладка: «Назад» снимает ровно один маршрут и щадит вкладку',
    (tester) async {
      final h = await _Harness.mount(tester, questId: 'q_single');

      await h.pressBack();

      // До фикса: закрытие последней вкладки уже сняло маршрут, а «Назад»
      // снял и экран под ним — пользователь выпадал из редактора на 2 экрана.
      expect(h.observer.pops, 1);
      // Вкладка живёт в сессии и вернётся при следующем входе.
      expect(h.activeKey, 'a');
    },
  );

  testWidgets(
    'вкладок несколько: «Назад» закрывает активную и оставляет в воркспейсе',
    (tester) async {
      final h = await _Harness.mount(tester, questId: 'q_multi');
      await h.openTab('b');
      expect(h.keys, ['a', 'b']);

      await h.pressBack(); // история: возврат к a
      expect(h.activeKey, 'a');
      await h.pressBack(); // история исчерпана: закрываем активную

      expect(
        h.observer.pops,
        0,
        reason:
            'в воркспейсе ещё есть над чем работать — выход только по «Меню»',
      );
      expect(h.keys, ['b']);
      expect(find.text('DOC:b'), findsOneWidget);
    },
  );

  testWidgets('закрытая вкладка не всплывает по «Назад» (не циклим)', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_closed');

    // Пользователь открыл второй экран и закрыл первый — так «Назад»
    // возвращал его на закрытый экран, и кнопка цик лила между двумя окнами.
    await h.openTab('b');
    await h.closeTab('b');
    expect(h.keys, ['a']);

    await h.pressBack();

    expect(h.keys, ['a'], reason: 'закрытая вкладка остаётся закрытой');
    expect(find.text('DOC:b'), findsNothing);
    expect(h.observer.pops, 1);
  });

  testWidgets('многократная «Назад» не возвращает закрытые экраны', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_no_loop');
    await h.openTab('b');
    await h.closeTab('b');

    final seen = <String>{};
    for (var i = 0; i < 3; i++) {
      await h.pressBack();
      if (find.text('DOC:b').evaluate().isNotEmpty) seen.add('b');
    }

    expect(seen, isEmpty);
  });

  testWidgets(
    'документ без своего обработчика «Назад» закрывает вкладку шелл',
    (tester) async {
      final h = await _Harness.mount(
        tester,
        questId: 'q_no_handler',
        registersBackHandler: false,
      );
      await h.openTab('b', registersBackHandler: false);

      await h.pressBack(); // история: возврат к a
      await h.pressBack(); // история исчерпана

      expect(h.observer.pops, 0);
      expect(h.keys, ['b']);
    },
  );

  testWidgets(
    'история важнее закрытия: возврат к предыдущей посещённой вкладке',
    (tester) async {
      final h = await _Harness.mount(tester, questId: 'q_history');
      await h.openTab('b');

      await h.pressBack();

      expect(h.observer.pops, 0);
      expect(h.activeKey, 'a');
      expect(h.keys, ['a', 'b'], reason: 'вкладка b остаётся открытой');
    },
  );

  testWidgets('нода без истории: «Назад» возвращает на канвас, а не выходит', (
    tester,
  ) async {
    // Восстановленная сессия: стек посещений живёт в памяти, поэтому после
    // входа в квест «Назад» с ноды видел пустую историю и выкидывал автора
    // в список квестов вместо полотна главы.
    final h = await _Harness.mount(
      tester,
      questId: 'q_from_node',
      parent: EditorDocumentDescriptor.canvas('q_from_node', 'ch1'),
    );

    await h.pressBack();

    expect(h.observer.pops, 0, reason: 'из квеста не выходим');
    expect(h.activeKind, EditorDocumentKind.canvas);
    expect(h.keys, [
      'ch1',
    ], reason: 'вкладка ноды стала полотном, не размножилась');

    // Второй «Назад» уже на полотне: выход из редактора, а не возврат в ноду.
    await h.pressBack();

    expect(h.observer.pops, 1);
    expect(h.activeKind, EditorDocumentKind.canvas);
    expect(h.keys, ['ch1'], reason: 'нода не всплывает повторно');
  });

  testWidgets('сохранение не удалось: «Назад» не выбрасывает из редактора', (
    tester,
  ) async {
    final h = await _Harness.mount(
      tester,
      questId: 'q_veto',
      saveResult: false,
    );

    await h.pressBack();

    expect(h.observer.pops, 0);
    expect(find.text('DOC:a'), findsOneWidget);
  });
}

/// Считает pop'ы маршрутов: «Назад» обязан снять не больше одного.
class _NavObserver extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previous) => pops++;
}

/// Воркспейс без сохранённой сессии — как на устройстве при первом входе.
class _NoSessionStore extends EditorWorkspaceSessionStore {
  const _NoSessionStore();

  @override
  Future<EditorWorkspaceState?> load(String questId) async => null;

  @override
  Future<void> save(String questId, EditorWorkspaceState state) async {}
}

class _Harness {
  _Harness._(this.tester, this.container, this.observer, this.questId);

  final WidgetTester tester;
  final ProviderContainer container;
  final _NavObserver observer;
  final String questId;

  /// Какие ключи открывать БЕЗ собственного обработчика «Назад»
  /// (как экран «Ресурсы»: шелл сам закрывает такую вкладку).
  final Map<String, bool> backHandlers = {};

  static Future<_Harness> mount(
    WidgetTester tester, {
    required String questId,
    bool? saveResult,
    bool registersBackHandler = true,
    EditorDocumentDescriptor? parent,
  }) async {
    SharedPreferences.setMockInitialValues({
      'editor_tabs_enabled': true,
      // Авто-открытие включено: переход открывает вкладку, а не заменяет её,
      // — именно так пользователь и получает несколько вкладок.
      'editor_auto_open_tab': true,
    });

    final observer = _NavObserver();
    final container = ProviderContainer(
      // Настоящее хранилище сессии тянет путь приложения из path_provider,
      // а его Future под fake-async переживает лишь первый тест: во втором
      // await вешается и шелл никогда не открывает стартовую вкладку.
      overrides: [
        editorWorkspaceSessionStoreProvider.overrideWithValue(
          const _NoSessionStore(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    final harness = _Harness._(tester, container, observer, questId);
    harness.backHandlers['a'] = registersBackHandler;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [observer],
          home: const Scaffold(body: Center(child: Text('DETAILS'))),
        ),
      ),
    );

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => QuestEditorShell(
          questId: questId,
          initialDocument: EditorDocumentDescriptor.node(
            questId,
            'a',
            title: 'A',
          ),
          questMenuBuilder: (_) =>
              const Scaffold(body: Center(child: Text('QUEST MENU'))),
          documentBuilder: (document) => document.id.kind.isNested
              ? EditorNestedDocuments.build(document.id)
              : _FakeDocument(
                  document: document,
                  saveResult: document.id.key == 'a' ? saveResult : null,
                  registersBackHandler:
                      harness.backHandlers[document.id.key] ?? true,
                  parent: document.id.key == 'a' ? parent : null,
                ),
        ),
      ),
    );
    await harness.settle();
    return harness;
  }

  EditorWorkspaceState get _workspace =>
      container.read(editorWorkspaceControllerProvider(questId));

  List<String> get keys => _workspace.documents.map((d) => d.id.key).toList();

  String? get activeKey => _workspace.activeId?.key;

  EditorDocumentKind? get activeKind {
    final id = _workspace.activeId;
    if (id == null) return null;
    return _workspace.documents
        .firstWhere((document) => document.id == id)
        .id
        .kind;
  }

  /// Кадр + прогон таймеров деперсиста, чтобы в конце теста не осталось
  /// висеть таймеру.
  Future<void> settle() async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  /// Аппаратная «Назад»: WidgetsApp → Navigator.maybePop.
  Future<void> pressBack() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SystemChannels.navigation.name,
          const JSONMethodCodec().encodeMethodCall(
            const MethodCall('popRoute'),
          ),
          (_) {},
        );
    await settle();
  }

  /// Закрыть вкладку так, как это делает кнопка «Закрыть вкладку» на экране.
  Future<void> closeTab(String key) async {
    final scope = EditorWorkspaceScope.of(
      tester.element(find.text('DOC:$key')),
    );
    await scope.closeDocument(EditorDocumentDescriptor.node(questId, key).id);
    await settle();
  }

  /// Открыть вкладку так, как это делает документ из воркспейса.
  Future<void> openTab(String key, {bool registersBackHandler = true}) async {
    backHandlers[key] = registersBackHandler;
    EditorWorkspaceScope.of(tester.element(find.text('DOC:a'))).openDocument(
      EditorDocumentDescriptor.node(questId, key, title: key.toUpperCase()),
    );
    await settle();
  }
}

/// Фейковый документ — ведёт себя как экран ноды: по «Назад» закрывает свою
/// вкладку через [EditorWorkspaceScope.closeDocument].
class _FakeDocument extends StatefulWidget {
  const _FakeDocument({
    required this.document,
    required this.registersBackHandler,
    this.saveResult,
    this.parent,
  });

  final EditorDocumentDescriptor document;
  final bool registersBackHandler;
  final bool? saveResult;

  /// Родительский экран вкладки — как канвас у ноды. null — документ
  /// корневой (история исчерпана → выход из редактора).
  final EditorDocumentDescriptor? parent;

  @override
  State<_FakeDocument> createState() => _FakeDocumentState();
}

class _FakeDocumentState extends State<_FakeDocument> {
  EditorWorkspaceScope? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = EditorWorkspaceScope.maybeOf(context);
    final result = widget.saveResult;
    final parent = widget.parent;
    if (result != null || parent != null) {
      _scope?.registerRuntime(
        widget.document.id,
        EditorDocumentRuntime(
          onSave: result == null ? null : () async => result,
          onBackToParent: parent == null ? null : () => parent,
        ),
      );
    }
  }

  @override
  void dispose() {
    if (widget.saveResult != null || widget.parent != null) {
      _scope?.unregisterRuntime(widget.document.id);
    }
    super.dispose();
  }

  Future<bool> _handleBack() async {
    await _scope?.closeDocument(widget.document.id);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final content = Scaffold(
      body: Center(child: Text('DOC:${widget.document.id.key}')),
    );
    if (!widget.registersBackHandler) return content;
    return EditorDocumentBackScope(onBackPressed: _handleBack, child: content);
  }
}
