import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Куда новичка выбрасывает после чистой установки.
///
/// `MenuScreen` и `OnboardingScreen` не собираются в виджет-тесте на Linux
/// (ad-SDK, audio-сессия, riverpod-обвязка), поэтому проверяем текст файлов —
/// как в `splash_launch_test.dart`. Инвариант один: стартовый таб гостя
/// определяется его же ответом с онбординга, а не «Каталогом».
///
/// НЕГАТИВНЫЙ КОНТРОЛЬ (#247): в HEAD гость получал `_currentIndex = 1`, а под
/// единицей лежит `MarketScreen`. Верни эту строку — падает первый же тест.
void main() {
  final menu = File('lib/features/shell/screens/menu_screen.dart');
  final onboarding = File('lib/features/app/screens/onboarding_screen.dart');
  late String menuSource;
  late String onboardingSource;

  setUpAll(() {
    expect(menu.existsSync(), isTrue, reason: 'запускать из apps/main_app');
    expect(onboarding.existsSync(), isTrue);
    menuSource = menu.readAsStringSync();
    onboardingSource = onboarding.readAsStringSync();
  });

  String guestBranch() {
    final start = menuSource.indexOf('} else {\n      screens = [');
    expect(start, greaterThan(-1), reason: 'не найден гостевый список табов');
    return menuSource.substring(start, menuSource.indexOf('];', start));
  }

  /// Подписи гостевых табов — те, что новичок читает в нижней панели.
  String guestItemsSource() {
    final branch = menuSource.indexOf('} else {\n      screens = [');
    expect(branch, greaterThan(-1), reason: 'не найден гостевый список табов');
    final itemsList = menuSource.indexOf('items = [', branch);
    expect(itemsList, greaterThan(branch), reason: 'не найден items гостя');
    return menuSource.substring(itemsList, menuSource.indexOf('];', itemsList));
  }

  String checkSessionBody() {
    final start = menuSource.indexOf('Future<void> _checkSession()');
    final end = menuSource.indexOf('void _onTabTapped', start);
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    return menuSource.substring(start, end);
  }

  group('стартовый экран гостя', () {
    test('гость садится по ответу с онбординга, а не в «Каталог»', () {
      final body = checkSessionBody();
      expect(
        body,
        contains('OnboardingService.kIntentKey'),
        reason: 'выбор новичка должен определять стартовый таб',
      );
      expect(
        body,
        isNot(contains('_currentIndex = 1')),
        reason: 'единица в гостевом списке табов — это «Каталог»',
      );
    });

    test('номера табов соответствуют реальному порядку screens', () {
      final guest = guestBranch();
      final order = RegExp(
        r'screens = \[\s*'
        r'MyQuestsScreen\(isRoot: true\),\s*'
        r'MarketScreen\(isRoot: true\),\s*'
        r'AuthPlaceholderScreen\(',
      ).hasMatch(guest);
      expect(
        order,
        isTrue,
        reason: 'порядок гостевых экранов поменялся — индексы выше врут',
      );
      // «Мои» — 0, вход — 2; Каталог (1) новичку не стартовый.
      expect(menuSource, contains('static const int _guestLibraryTab = 0;'));
      expect(menuSource, contains('static const int _guestSignInTab = 2;'));
    });

    test('таб входа называется «Вход», а не «Профиль»', () {
      // Под этим табом у гостя форма входа. «Профиль» обещает анкету, которой
      // у новичка ещё нет, и он не понимает, куда его развилка привела.
      final items = guestItemsSource();
      // Метка живёт внутри tr(): на русском экране это тот же литерал.
      final labels = RegExp(r"label: (?:tr\()?'([^']+)'")
          .allMatches(items)
          .map((m) => m.group(1)!)
          .toList();
      expect(labels, ['Мои', 'Каталог', 'Вход', 'Настройки']);
    });

    test('экран входа даёт гостю выход, а не только wall', () {
      expect(
        menuSource,
        contains('onBrowseAsGuest: () => _onTabTapped(_guestLibraryTab)'),
        reason: 'новичок не должен упираться в тупик без аккаунта',
      );
    });

    test('после входа — каталог квестов', () {
      final body = checkSessionBody();
      final authed = body.substring(
        body.indexOf('if (token != null && userId != null) {'),
        body.indexOf('} else {'),
      );
      expect(
        authed,
        contains('_currentIndex = 0;'),
        reason: 'свежезалогиненный должен попасть на «Каталог»',
      );
    });
  });

  group('развилка в онбординге', () {
    test('отвечают ровно два пути — пройти и создать', () {
      expect(
        onboardingSource,
        contains('OnboardingService.intentPlay'),
      );
      expect(
        onboardingSource,
        contains('OnboardingService.intentCreate'),
      );
      expect(
        RegExp(r"_finish\(OnboardingService\.\w+\)")
            .allMatches(onboardingSource)
            .length,
        2,
      );
    });

    test('ответ пишется в тот же ключ, что читает оболочка', () {
      expect(
        onboardingSource,
        contains('prefs.setString(OnboardingService.kIntentKey, intent)'),
      );
      expect(
        onboardingSource,
        contains("prefs.setBool('has_completed_onboarding', true)"),
        reason: 'без этого флага онбординг показывался бы каждый запуск',
      );
    });

    test('развилка идёт после промо-страниц, а не вместо них', () {
      expect(
        onboardingSource,
        contains('if (_choosing) return _buildChoice(context);'),
      );
      expect(onboardingSource, contains('_pages.length'));
    });
  });
}
