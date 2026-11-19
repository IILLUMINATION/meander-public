// «С какой папки открывать библиотеку ресурсов» — настройка устройства.
//
// Умолчание прежнее: библиотека открывается в последней папке. Кому это
// неудобно, включает «с корня» — тогда каждый вход начинается с корня, где
// видны все папки квеста.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ: уберите чтение `resources_open_at_root` из
// `ResourcesPrefs.ensureLoaded` — «читает сохранённый выбор» падает.

import 'package:canvas_app/features/resources/services/resource_prefs.dart';
import 'package:canvas_app/features/settings/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpSettings(
  WidgetTester tester,
  Map<String, Object> prefs,
) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(prefs);
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: SettingsScreen())),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => ResourcesPrefs.instance.resetForTests());

  testWidgets('переключатель попадает в настройки и в память экрана', (
    tester,
  ) async {
    await _pumpSettings(tester, const {});

    final tile = find.text('Библиотека ресурсов с корня');
    expect(tile, findsOneWidget);
    expect(ResourcesPrefs.instance.openAtRoot, isFalse, reason: 'умолчание');

    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(ResourcesPrefs.instance.openAtRoot, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(ResourcesPrefs.openAtRootKey), isTrue);
  });

  testWidgets('читает сохранённый выбор', (tester) async {
    await _pumpSettings(tester, const {ResourcesPrefs.openAtRootKey: true});

    expect(ResourcesPrefs.instance.openAtRoot, isTrue);
    final switchTile = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Библиотека ресурсов с корня'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(switchTile.value, isTrue);
  });
}
