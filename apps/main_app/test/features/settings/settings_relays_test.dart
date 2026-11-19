import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/services/relay_registry.dart';
import 'package:canvas_app/core/services/server_registry.dart';
import 'package:canvas_app/features/settings/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Пользователь управляет ретрансляторами сам: список, переключатель,
// добавление, удаление. Раньше здесь был список зеркал-прокси, который
// расшифровывал трафик, — таких адресов в интерфейсе быть не должно.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ: верни в секцию строку retiredProxyUrls — падает
// «прокси-зеркал в настройках нет».
Future<void> _pumpSettings(
  WidgetTester tester,
  Map<String, Object> prefs,
) async {
  tester.view.physicalSize = const Size(900, 4000);
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
  setUp(() {
    ServerRegistry.instance.resetForTests();
    RelayRegistry.instance.resetForTests();
    RelayRegistry.probeHook = (endpoint) async => true;
  });

  tearDown(() {
    ServerRegistry.instance.resetForTests();
    RelayRegistry.instance.resetForTests();
  });

  testWidgets('секция показывает ретрансляторы, а не прокси-зеркала', (
    tester,
  ) async {
    await _pumpSettings(tester, const {});
    final title = find.text('Ретрансляторы');
    await tester.ensureVisible(title);
    await tester.pump();

    expect(find.text(AppConfig.relayUrls.first), findsOneWidget);
    for (final retired in AppConfig.retiredProxyUrls) {
      expect(
        find.text(retired),
        findsNothing,
        reason: 'прокси-зеркал в настройках нет',
      );
    }
  });

  testWidgets('переключатель выключает встроенный ретранслятор', (
    tester,
  ) async {
    await _pumpSettings(tester, const {});
    final title = find.text('Ретрансляторы');
    await tester.ensureVisible(title);
    await tester.pump();

    final endpoint = AppConfig.relayUrls.first;
    final tile = find.ancestor(
      of: find.text(endpoint),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(RelayRegistry.instance.isEnabled(endpoint), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('relay_disabled_endpoints'), contains(endpoint));
  });

  testWidgets('свой ретранслятор добавляется из поля host:port', (
    tester,
  ) async {
    await _pumpSettings(tester, const {});
    // Поле ретранслятора — последнее на экране (выше поле сервера).
    final relayField = find.byType(TextField).last;
    await tester.ensureVisible(relayField);
    await tester.enterText(relayField, 'mine.example:9443');
    await tester.tap(find.text('Добавить ретранслятор'));
    await tester.pumpAndSettle();

    expect(RelayRegistry.instance.custom, contains('mine.example:9443'));
    expect(find.text('mine.example:9443'), findsOneWidget);
    expect(find.text('Свой'), findsWidgets);
  });
}