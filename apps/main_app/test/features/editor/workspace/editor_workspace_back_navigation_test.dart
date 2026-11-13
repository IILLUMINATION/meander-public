import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/features/editor/workspace/editor_back_handler.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_controller.dart';
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
  testWidgets('одна вкладка: «Назад» снимает ровно один маршрут и щадит вкладку', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_single');

    await h.pressBack();

    // До фикса: закрытие последней вкладки уже сняло маршрут, а «Назад»
    // снял и экран под ним — пользователь выпадал из редактора на 2 экрана.
    expect(h.observer.pops, 1);
    // Вкладка живёт в сессии и вернётся при следующем входе.
    expect(h.activeKey, 'a');
  });

  testWidgets('вкладок несколько: «Назад» закрывает активную и оставляет в воркспейсе', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_multi');
    await h.openTab('b');
    expect(h.keys, ['a', 'b']);

    await h.pressBack(); // история: возврат к a
    expect(h.activeKey, 'a');
    await h.pressBack(); // история исчерпана: закрываем активную

    expect(
      h.observer.pops,
      0,
      reason: 'в воркспейсе ещё есть над чем работать — выход только по «Меню»',
    );
    expect(h.keys, ['b']);
    expect(find.text('DOC:b'), findsOneWidget);
  });

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

  testWidgets('многократная «Назад» не возвращает закрытые экраны', (tester) async {
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

  testWidgets('документ без своего обработчика «Назад» закрывает вкладку шелл', (
    tester,
  ) async {
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
  });

  testWidgets('история важнее закрытия: возврат к предыдущей посещённой вкладке', (
    tester,
  ) async {
    final h = await _Harness.mount(tester, questId: 'q_history');
    await h.openTab('b');

    await h.pressBack();

    expect(h.observer.pops, 0);
    expect(h.activeKey, 'a');
    expect(h.keys, ['a', 'b'], reason: 'вкладка b остаётся открытой');
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
        editorWorkspaceSessionStoreProvider
            .overrideWithValue(const _NoSessionStore()),
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
          documentBuilder: (document) => _FakeDocument(
            document: document,
            saveResult: document.id.key == 'a' ? saveResult : null,
            registersBackHandler:
                harness.backHandlers[document.id.key] ?? true,
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
          const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
          (_) {},
        );
    await settle();
  }

  /// Закрыть вкладку так, как это делает кнопка «Закрыть вкладку» на экране.
  Future<void> closeTab(String key) async {
    final scope = EditorWorkspaceScope.of(
      tester.element(find.text('DOC:$key')),
    );
    await scope.closeDocument(
      EditorDocumentDescriptor.node(questId, key).id,
    );
    await settle();
  }

  /// Открыть вкладку так, как это делает документ из воркспейса.
  Future<void> openTab(
    String key, {
    bool registersBackHandler = true,
  }) async {
    backHandlers[key] = registersBackHandler;
    EditorWorkspaceScope.of(
      tester.element(find.text('DOC:a')),
    ).openDocument(
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
  });

  final EditorDocumentDescriptor document;
  final bool registersBackHandler;
  final bool? saveResult;

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
    if (result != null) {
      _scope?.registerRuntime(
        widget.document.id,
        EditorDocumentRuntime(onSave: () async => result),
      );
    }
  }

  @override
  void dispose() {
    if (widget.saveResult != null) {
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
    return EditorDocumentBackScope(
      onBackPressed: _handleBack,
      child: content,
    );
  }
}
