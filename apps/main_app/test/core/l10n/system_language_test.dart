// Язык по умолчанию — язык системы, а не русский источник.
//
// Правило: пока человек не выбрал язык руками, интерфейс идёт за системой, и
// решение принимается до `runApp` (`bootstrap`), поэтому сплэш и первый экран
// уже на его языке, а не перекрашиваются на ходу.
//
// Пол ожиданий: список `PlatformDispatcher.locales` упорядочен по предпочтению,
// поэтому второй язык системы обязан выигрывать у английского по умолчанию.

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/l10n/l10n_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => L10n.setCurrent(L10n.byCode('ru')));

  group('локаль системы -> язык реестра', () {
    test('язык без вариантов совпадает по коду', () {
      expect(L10n.forSystemLocale(const Locale('de'))?.code, 'de');
      expect(L10n.forSystemLocale(const Locale('ja'))?.code, 'ja');
      expect(L10n.forSystemLocale(const Locale('ru', 'RU'))?.code, 'ru');
    });

    test('португальский любой страны — бразильский: другого у нас нет', () {
      expect(L10n.forSystemLocale(const Locale('pt', 'BR'))?.code, 'pt-BR');
      expect(L10n.forSystemLocale(const Locale('pt', 'PT'))?.code, 'pt-BR');
    });

    test('упрощённый китайский наш, традиционный — чужой', () {
      expect(L10n.forSystemLocale(const Locale('zh', 'CN'))?.code, 'zh-CN');
      expect(
        L10n.forSystemLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        )?.code,
        'zh-CN',
      );
      // Традиционные иероглифы — другая письменность: подменять их
      // упрощёнными нельзя, пусть работает правило по умолчанию.
      expect(L10n.forSystemLocale(const Locale('zh', 'TW')), isNull);
      expect(L10n.forSystemLocale(const Locale('zh', 'HK')), isNull);
      expect(
        L10n.forSystemLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ),
        isNull,
      );
    });

    test('языка системы нет в реестре — null', () {
      expect(L10n.forSystemLocale(const Locale('pl')), isNull);
      expect(L10n.forSystemLocale(const Locale('uk')), isNull);
    });

    test('из списка предпочтений берётся первый поддерживаемый', () {
      expect(
        L10n.forSystemLocales(const [Locale('pl'), Locale('ko')])?.code,
        'ko',
      );
      expect(L10n.forSystemLocales(const [Locale('pl'), Locale('uk')]), isNull);
    });
  });

  group('старт приложения', () {
    testWidgets('без сохранённого выбора берётся язык системы', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.binding.platformDispatcher.localesTestValue = const [Locale('fr')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      await initAppLanguage();
      expect(L10n.code, 'fr');
    });

    testWidgets('системный язык не выдаёт себя за выбор пользователя', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.binding.platformDispatcher.localesTestValue = const [Locale('ja')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      await initAppLanguage();
      final prefs = await SharedPreferences.getInstance();
      // Иначе следующая смена языка в системе до приложения уже не дойдёт.
      expect(prefs.getString(AppLanguageNotifier.prefsKey), isNull);
    });

    testWidgets('выбор пользователя важнее системы', (tester) async {
      SharedPreferences.setMockInitialValues({
        AppLanguageNotifier.prefsKey: 'de',
      });
      tester.binding.platformDispatcher.localesTestValue = const [Locale('fr')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      await initAppLanguage();
      expect(L10n.code, 'de');
    });

    testWidgets('неподдерживаемый системный язык -> английский', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.binding.platformDispatcher.localesTestValue = const [Locale('pl')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      await initAppLanguage();
      expect(L10n.code, 'en');
    });
  });
}
