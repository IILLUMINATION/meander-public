import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/features/quests/screens/my_quests_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          questsProvider.overrideWith(
            (ref) async => [Quest(id: 'q1', title: 'Первый квест')],
          ),
        ],
        child: MaterialApp(home: MyQuestsScreen(isRoot: true)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('карточка квеста открывает M3E-меню действий', (tester) async {
    await pumpLibrary(tester);

    final more = find.byIcon(Icons.more_vert_rounded);
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(find.text('Экспортировать (.mnd)'), findsOneWidget);
    expect(find.text('Удалить квест'), findsOneWidget);
    expect(find.text('Удалить квест'), findsOneWidget);
  });

  testWidgets('поиск открывает M3E-лист сортировки', (tester) async {
    await pumpLibrary(tester);

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Сортировка'), findsOneWidget);
    expect(find.text('По алфавиту А–Я'), findsOneWidget);
  });

  testWidgets('шапка открывает M3E-меню бэкапов', (tester) async {
    await pumpLibrary(tester);

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Бэкап всех квестов'), findsOneWidget);
    expect(find.text('Восстановить из бэкапа'), findsOneWidget);
  });
}
