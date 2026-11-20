import 'dart:async';

import 'package:canvas_app/app/startup_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _readyApp() =>
    const MaterialApp(home: Scaffold(body: Text('READY')));

void main() {
  testWidgets('показывает загрузку и затем приложение', (tester) async {
    final completer = Completer<Widget>();

    await tester.pumpWidget(StartupGate(boot: () => completer.future));
    expect(find.text('Запуск...'), findsOneWidget);

    completer.complete(_readyApp());
    await tester.pump();
    await tester.pump();

    expect(find.text('READY'), findsOneWidget);
    expect(find.text('Запуск...'), findsNothing);
  });

  testWidgets('показывает текст ошибки вместо пустого экрана', (tester) async {
    await tester.pumpWidget(
      StartupGate(boot: () async => throw StateError('rust core missing')),
    );
    await tester.pump();

    expect(find.text('Не удалось запустить Meander'), findsOneWidget);
    expect(find.textContaining('rust core missing'), findsOneWidget);
    expect(find.text('Скопировать ошибку'), findsOneWidget);
  });

  testWidgets('показывает экран таймаута, если boot завис', (tester) async {
    final never = Completer<Widget>();

    await tester.pumpWidget(
      StartupGate(
        boot: () => never.future,
        timeout: const Duration(milliseconds: 50),
      ),
    );
    expect(find.text('Запуск...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();

    expect(find.text('Запуск не завершился'), findsOneWidget);
    expect(find.text('Скопировать ошибку'), findsOneWidget);
  });
}