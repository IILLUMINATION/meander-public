import 'package:canvas_app/features/app/screens/policy_screen.dart';
import 'package:canvas_app/features/settings/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Тема, плагины и поведение редактора — свойства устройства, а не аккаунта.
// Раньше эти секции сидели внутри `if (isLoggedIn)`, и новичок, который ещё
// не вошёл, видел в «Настройках» только «Помощь» и «Информацию»: включить
// тёмную тему было негде, а экран выглядел сломанным.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ: верни секции «Внешний вид» и «Редактор» внутрь
// `if (isLoggedIn) ...[]` — падает «гостю доступны настройки устройства».
Future<void> _pumpSettings(
  WidgetTester tester,
  Map<String, Object> prefs,
) async {
  // Экран — CustomScrollView, и ниже вьюпорта сливеры не строятся: ищем не
  // «что вообще есть в дереве», а «что видит человек», поэтому задаём высокий
  // холст и находим секции целиком.
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
  testWidgets('гостю доступны настройки устройства', (tester) async {
    await _pumpSettings(tester, const {});

    expect(tester.takeException(), isNull);
    expect(find.text('Тема оформления'), findsOneWidget);
    expect(find.text('Вкладки'), findsOneWidget);
    expect(find.text('Академия'), findsOneWidget);
    // А то, что действительно требует аккаунта, гостю не показываем.
    expect(find.text('Редактировать имя'), findsNothing);
    expect(find.text('Push-уведомления'), findsNothing);
  });

  testWidgets('debug: кнопка первого запуска открывает стартовый экран', (
    tester,
  ) async {
    await _pumpSettings(tester, const {});

    final tile = find.text('Первый запуск');
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.byType(PolicyScreen), findsOneWidget);
    expect(find.text('Условиями использования (EULA)'), findsOneWidget);
  });

  testWidgets('аккаунту по-прежнему видно профиль', (tester) async {
    await _pumpSettings(tester, const {'user_id': 'u-1'});

    expect(find.text('Редактировать имя'), findsOneWidget);
    expect(find.text('Тема оформления'), findsOneWidget);
  });
}
