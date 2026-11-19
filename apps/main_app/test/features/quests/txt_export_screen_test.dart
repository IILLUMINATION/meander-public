import 'package:canvas_app/core/services/txt_quest_exporter.dart';
import 'package:canvas_app/features/quests/screens/txt_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('экран отдаёт настройки по умолчанию', (tester) async {
    TxtExportOptions? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<TxtExportOptions>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const TxtExportScreen(questTitle: 'Квест'),
                    ),
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
    await tester.pumpAndSettle();
    expect(find.text('Настройки экспорта в .txt'), findsOneWidget);
    expect(find.text('Квест'), findsOneWidget);

    await tester.tap(find.text('Экспортировать'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.aiGuide, isTrue);
    expect(result!.readable, isTrue);
    expect(result!.shortenIds, isTrue);
    expect(result!.includeConfig, isTrue);
    expect(result!.includeNodes, isTrue);
    expect(result!.includeScripts, isTrue);
    expect(result!.includeCoordinates, isFalse);
  });

  testWidgets('переключатели меняют итоговые настройки', (tester) async {
    TxtExportOptions? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<TxtExportOptions>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const TxtExportScreen(questTitle: 'Квест'),
                    ),
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
    await tester.pumpAndSettle();

    await tester.tap(find.text('Понятный текст вместо JSON'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final coordinatesTile = find.ancestor(
      of: find.text('Координаты нод'),
      matching: find.byType(SwitchListTile),
    );
    await tester.tap(
      find.descendant(of: coordinatesTile, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Экспортировать'));
    await tester.pumpAndSettle();

    expect(result!.readable, isFalse);
    expect(result!.includeCoordinates, isTrue);
  });
}
