import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/shell/widgets/animated_nav_bar.dart';

/// Разложение вкладок для узкой панели (#150): сколько оставляем в ряду и что
/// уезжает под «Ещё».
void main() {
  const sections = [
    NavBarItem(icon: Icons.explore_outlined, label: 'Каталог'),
    NavBarItem(icon: Icons.public_outlined, label: 'Сообщество'),
    NavBarItem(icon: Icons.forum_outlined, label: 'Чаты'),
    NavBarItem(icon: Icons.auto_stories_outlined, label: 'Мои'),
    NavBarItem(icon: Icons.person_outline_rounded, label: 'Профиль'),
    NavBarItem(icon: Icons.settings_outlined, label: 'Настройки'),
  ];

  test('шесть разделов сворачиваются в четыре + «Ещё»', () {
    final fold = foldNavBarTiles(sections);
    expect(fold.visible.map((i) => i.label), [
      'Каталог',
      'Сообщество',
      'Чаты',
      'Мои',
    ]);
    expect(fold.hidden.map((i) => i.label), ['Профиль', 'Настройки']);
  });

  test('короткий список не сворачиваем', () {
    final fold = foldNavBarTiles(sections.take(4).toList());
    expect(fold.visible, hasLength(4));
    expect(fold.hidden, isEmpty);
  });

  testWidgets('в панели нет скрытых вкладок, «Ещё» — пятая плитка', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fold = foldNavBarTiles(sections);
    final tapped = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox(),
          bottomNavigationBar: AnimatedNavBar(
            items: [
              ...fold.visible,
              const NavBarItem(icon: Icons.more_horiz_rounded, label: 'Ещё'),
            ],
            currentIndex: fold.visible.length,
            onTap: tapped.add,
          ),
        ),
      ),
    );

    expect(find.byTooltip('Каталог'), findsOneWidget);
    expect(find.byTooltip('Профиль'), findsNothing);
    expect(find.byTooltip('Настройки'), findsNothing);

    // Индекс плитки, а не экрана: настоящий таб по нему выбирает вызывающий
    // код — на узком экране это список «Ещё».
    await tester.tap(find.byTooltip('Ещё'));
    await tester.pumpAndSettle();
    expect(tapped, [fold.visible.length]);
  });
}
