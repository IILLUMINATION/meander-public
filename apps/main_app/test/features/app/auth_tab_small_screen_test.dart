import 'package:canvas_app/features/shell/screens/menu_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Развилка онбординга (#247) сажает новичка-читателя именно на этот таб, а он
// состоял из центрированного Column без прокрутки: на маленьком телефоне с
// крупным системным шрифтом третья кнопка и выход «Продолжить без аккаунта»
// уезжали за нижний край, и экран превращался в тупик.
//
// Тест настоящий: AuthPlaceholderScreen собирается в изоляции — сервисы
// (Google/Yandex, сокет) трогаются только по нажатию кнопки.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ: верни `Center` вместо `LayoutBuilder +
// SingleChildScrollView + ConstrainedBox(minHeight)` в build — падает
// «кнопки входа влезают…», tester.takeException() отдаёт RenderFlex overflowed.
void main() {
  Future<void> pumpSmallPhone(WidgetTester tester, {double scale = 2.0}) async {
    tester.view.physicalSize = const Size(480, 800); // 320x533 логических px
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: AuthPlaceholderScreen(
            onLoginSuccess: () {},
            onBrowseAsGuest: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'кнопки входа влезают: экран прокручивается, а не переполняется',
    (WidgetTester tester) async {
      await pumpSmallPhone(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    },
  );

  testWidgets('выход для гостя достижим даже при трёх кнопках входа', (
    WidgetTester tester,
  ) async {
    await pumpSmallPhone(tester);

    final exit = find.text('Продолжить без аккаунта');
    expect(exit, findsOneWidget);

    // Кнопка обязана быть не просто в дереве, а дотягиваемой: до фикса она
    // лежала за нижним краем прокручиваемой области, которой не было.
    await tester.ensureVisible(exit);
    await tester.tap(exit);
    expect(tester.takeException(), isNull);
  });

  testWidgets('на экране входа есть согласие с EULA и его текст', (
    WidgetTester tester,
  ) async {
    await pumpSmallPhone(tester);

    expect(
      find.textContaining('Регистрируясь или входя, вы принимаете'),
      findsOneWidget,
    );
    final eulaLink = find.text('Условия использования (EULA)');
    expect(eulaLink, findsOneWidget);
    await tester.ensureVisible(eulaLink);
    await tester.tap(eulaLink);
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'There is no tolerance for objectionable content or abusive users.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('при обычном тексте контент остаётся по центру', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400); // 360x800 логических px
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPlaceholderScreen(
          onLoginSuccess: () {},
          onBrowseAsGuest: () {},
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final title = tester.getTopLeft(find.text('Войдите в аккаунт'));
    final bounds = tester.getRect(find.byType(Scaffold));
    // Контент вписан — значит вертикальное центрирование сохранено: заголовок
    // не прижат к верхнему краю.
    expect(title.dy, greaterThan(bounds.top + 80));
    expect(title.dy, lessThan(bounds.height / 2));
  });
}
