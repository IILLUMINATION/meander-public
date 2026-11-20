import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Сколько человек смотрит на сплэш перед первым экраном.
///
/// Проверяем текст файла: `SplashScreen` тянет riverpod, рекламный SDK и
/// audio-сессию, полноценный виджет-тест на Linux всё равно не соберётся, а
/// инвариант ровно один — сетевой запрос и искусственная пауза не держат
/// первый экран.
///
/// НЕГАТИВНЫЙ КОНТРОЛЬ (#216): в HEAD `_startApp` ждал `stopwatch < 2000 мс`
/// и делал `await VersionCheckService.check()` (8 с таймаут) до перехода на
/// MenuScreen. Верните любой из двух кусков обратно — падает соответствующий
/// тест.
void main() {
  final file = File('lib/features/app/screens/splash_screen.dart');
  late String source;

  setUpAll(() {
    expect(file.existsSync(), isTrue, reason: 'запускать из apps/main_app');
    source = file.readAsStringSync();
  });

  group('старт приложения', () {
    test('искусственная пауза не держит экран дольше секунды', () {
      final floor = RegExp(
        r'static const int _minSplashMillis = (\d+);',
      ).firstMatch(source);
      expect(floor, isNotNull, reason: 'пауза сплэша не описана константой');
      final millis = int.parse(floor!.group(1)!);
      expect(millis, lessThanOrEqualTo(1000));
      expect(millis, greaterThan(0));
    });

    test('проверка версии не блокирует переход на первый экран', () {
      final startApp = source.substring(
        source.indexOf(RegExp(r'Future<void> _startApp\(')),
        source.indexOf('Future<void> _showUpdateIfAny('),
      );
      expect(
        startApp,
        isNot(contains('await VersionCheckService.check()')),
        reason: 'запрос с 8-секундным таймаутом вешает сплэш на слабой сети',
      );
      expect(
        startApp,
        contains('unawaited(_showUpdateIfAny('),
        reason: 'окно обновления должно прилетать поверх уже открытого экрана',
      );
    });

    test('в debug-сборке окно обновления не всплывает само', () {
      final flag = RegExp(
        r'static const bool _debugForceUpdatePrompt = (\w+);',
      ).firstMatch(source);
      expect(
        flag,
        isNotNull,
        reason: 'нет переключателя отладки экрана обновления',
      );
      expect(
        flag!.group(1),
        'false',
        reason:
            'dev-сборка на iPhone не должна каждый запуск показывать UpdateScreen',
      );
    });

    test('окно обновления идёт в корневой навигатор, а не в сплэш', () {
      // Сплэш-роут к моменту ответа сервера уже заменён — push из своего
      // context молча бы пропал.
      expect(source, contains('NavigatorState rootNavigator'));
      expect(source, contains('rootNavigator.mounted'));
      expect(source, contains('rootNavigator.push('));
    });
  });
}
