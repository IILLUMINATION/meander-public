// «О приложении» на языке интерфейса.
//
// Экран раньше читал единственный русский JSON-ассет, поэтому переводов у него
// не было в принципе. Теперь текст живёт в коде и идёт через tr(): проверяем,
// что на чужом языке до экрана доходят и заголовки, и сам текст «О проекте»,
// и заметки — то есть что перевод не остался только в словаре.
//
// Экран длинный, а список изменений ленивый: секции ниже по экрану просто не
// строятся в маленьком окне, поэтому кадру задаётся высокий вьюпорт.

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/build_info_service.dart';
import 'package:canvas_app/features/app/data/about_content.dart';
import 'package:canvas_app/features/app/screens/about_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _buildInfo = AppBuildInfo(branch: 'ui-update', commit: 'ab9b92c');

const _sourceProjectText =
    'Данный проект разрабатывается уже более года, за это время мы успели '
    'сделать многое и рады поделиться этим с вами.';

Future<void> _pumpAbout(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(home: AboutScreen(buildInfo: _buildInfo)),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => L10n.setCurrent(L10n.byCode('ru')));

  testWidgets('немецкий: заголовки и «О проекте» из словаря', (tester) async {
    L10n.setCurrent(L10n.byCode('de'));
    await _pumpAbout(tester);

    expect(find.text('Über das Projekt'), findsOneWidget);
    expect(find.text('Änderungsprotokoll'), findsOneWidget);
    expect(find.text('Hinweise'), findsOneWidget);
    expect(find.text('Spender'), findsOneWidget);
    // Текст на языке интерфейса, а русского источника на экране нет.
    expect(find.text(aboutProject()), findsOneWidget);
    expect(aboutProject(), isNot(_sourceProjectText));
    expect(find.text(_sourceProjectText), findsNothing);
  });

  testWidgets('русский: текст-источник на месте', (tester) async {
    await _pumpAbout(tester);

    expect(find.text('О проекте'), findsOneWidget);
    expect(find.text(_sourceProjectText), findsOneWidget);
  });

  testWidgets('японский: заголовки переведены, аватар тестеров рисуется', (
    tester,
  ) async {
    L10n.setCurrent(L10n.byCode('ja'));
    await _pumpAbout(tester);

    expect(find.text('プロジェクトについて'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
  });
}
