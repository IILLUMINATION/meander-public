import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/background_blur.dart';

void main() {
  group('resolveBackgroundBlur', () {
    // НЕГАТИВНЫЙ КОНТРОЛЬ: этот кейс падал до фикса — там было
    // `nodeBlur ?? stateBlur`, и блок `set_blur` не мог перебить поле ноды.
    test('скрипт перекрывает поле ноды', () {
      expect(
        resolveBackgroundBlur(scriptBlur: 3, nodeBlur: 18),
        3,
        reason: 'set_blur должен иметь слово',
      );
    });

    test('без скрипта решает поле ноды', () {
      expect(resolveBackgroundBlur(scriptBlur: null, nodeBlur: 0), 0);
      expect(resolveBackgroundBlur(scriptBlur: null, nodeBlur: 22), 22);
    });

    test('ни скрипт, ни нода — исторический дефолт 10', () {
      expect(resolveBackgroundBlur(), defaultBackgroundBlur);
      expect(defaultBackgroundBlur, 10.0);
    });

    test('ноль из скрипта — это «без размытия», а не «нет значения»', () {
      expect(resolveBackgroundBlur(scriptBlur: 0, nodeBlur: 18), 0);
    });
  });

  group('parseBackgroundBlur', () {
    test('число и целое из JSON приводятся к double', () {
      expect(parseBackgroundBlur(12.0), 12.0);
      expect(parseBackgroundBlur(12), 12.0);
    });

    test('строка из assign_variable не роняет экран', () {
      // `(raw as num?)` на строке бросает TypeError — этим и лечим.
      expect(parseBackgroundBlur('7.5'), 7.5);
      expect(parseBackgroundBlur('слабое'), isNull);
    });

    test('отсутствие значения — это null, а не ноль', () {
      expect(parseBackgroundBlur(null), isNull);
    });
  });

  group('shouldApplyBackgroundBlur', () {
    test('малые сигмы не тянут слой', () {
      expect(shouldApplyBackgroundBlur(0), isFalse);
      expect(shouldApplyBackgroundBlur(0.4), isFalse);
    });

    test('рабочие сигмы применяются', () {
      expect(shouldApplyBackgroundBlur(0.6), isTrue);
      expect(shouldApplyBackgroundBlur(10), isTrue);
    });
  });

  group('gateBackgroundBlur', () {
    // НЕГАТИВНЫЙ КОНТРОЛЬ (#206): раньше видео-ветка резалась тяжёлым
    // рубильником `shouldDisableBlur`, который на Linux всегда `true`. Со
    // вторым аргументом `disabled: true` (то есть «тяжёлые эффекты выключены»)
    // эта же сигма давала 0.0 — фон оставался резким. Картинка же проходила по
    // мягкому порогу и размывалась, поэтому расхождение и выглядело как
    // «размытие на видео не работает».
    test('выключенный резалкой фон не размывается вовсе', () {
      expect(gateBackgroundBlur(18, disabled: true), 0.0);
      expect(gateBackgroundBlur(defaultBackgroundBlur, disabled: true), 0.0);
    });

    test('разрешённый фон отдаёт сигму автора как есть', () {
      expect(gateBackgroundBlur(18, disabled: false), 18.0);
      expect(gateBackgroundBlur(defaultBackgroundBlur, disabled: false), 10.0);
      expect(gateBackgroundBlur(0, disabled: false), 0.0);
    });

    test('допороговые значения не превращаются в слой', () {
      expect(gateBackgroundBlur(0.4, disabled: false), 0.0);
      expect(gateBackgroundBlur(0.6, disabled: false), 0.6);
    });

    test('ноль на выходе порога — виджет не ставит ImageFiltered', () {
      // `_BackgroundVideo` и картинка спрашивают `shouldApplyBackgroundBlur`
      // уже у gates-значения, поэтому связка «выключено → нет слоя» держится
      // только на том, что гейт возвращает ровно 0.0.
      expect(
        shouldApplyBackgroundBlur(gateBackgroundBlur(18, disabled: true)),
        isFalse,
      );
      expect(
        shouldApplyBackgroundBlur(gateBackgroundBlur(18, disabled: false)),
        isTrue,
      );
    });
  });

  group('backgroundVideoBlurFilter', () {
    // НЕГАТИВНЫЙ КОНТРОЛЬ (#206, вторая половина): до фикса фон-видео
    // обвешивался `ImageFiltered`, который поверх внешней GL-текстуры
    // (`Texture` из media_kit) не применяется вовсе — сигма приходила,
    // размытия не было. Здесь проверяется фильтр mpv, который кадр реально
    // видит: пустой ответ на «не размывать» и растущий радиус на рабочие сигмы.
    test('порог и ноль — фильтра нет вовсе', () {
      expect(backgroundVideoBlurFilter(0), isNull);
      expect(backgroundVideoBlurFilter(0.4), isNull);
    });

    test('сигма уходит в gblur один-в-один, как у картинки', () {
      expect(backgroundVideoBlurFilter(10), 'gblur=sigma=10');
      expect(backgroundVideoBlurFilter(2.4), 'gblur=sigma=2');
    });

    test('сигма растёт монотонно', () {
      final sigma = RegExp(r'sigma=(\d+)');
      int of(double v) => int.parse(sigma.firstMatch(backgroundVideoBlurFilter(v)!)!.group(1)!);
      expect(of(2) < of(6), isTrue);
      expect(of(6) < of(10), isTrue);
      expect(of(10) < of(20), isTrue);
    });

    test('сигма ограничена сверху: gblur линейен по ней, а фон крутится всегда',
        () {
      expect(backgroundVideoBlurFilter(1000), 'gblur=sigma=25');
    });
  });

  group('mpvBlurFilterSupported', () {
    // НЕГАТИВНЫЙ КОНТРОЛЬ (#216): до этой проверки мобильный фон-видео
    // обвешивался `gblur`, которого в мобильных сборках libmpv нет (в
    // libmpv-darwin-build и libmpv-android-video-build белый список фильтров —
    // `overlay` и `equalizer`). mpv на неизвестный фильтр печатает FATAL, кадр
    // остаётся резким. Если убрать 'ios' из условия — провалится кейс pro ios.
    test('desktop несёт ffmpeg-фильтры', () {
      expect(mpvBlurFilterSupported('linux'), isTrue);
      expect(mpvBlurFilterSupported('macos'), isTrue);
      expect(mpvBlurFilterSupported('windows'), isTrue);
    });

    test('мобильные сборки — нет', () {
      expect(mpvBlurFilterSupported('ios'), isFalse);
      expect(mpvBlurFilterSupported('android'), isFalse);
    });
  });

  group('backgroundVideoBlurRoute', () {
    // НЕГАТИВНЫЙ КОНТРОЛЬ (#223): мобильная ветка раньше выдавала
    // `format=w=iw/4:h=ih/4`. Этот mpv-овский фильтр размеры только согласует,
    // скале не делает (кадр байт в байт как без него), а `iw/4` ещё и не
    // разбирается — то есть на телефоне фон-видео не размывался ничем. Маршрут
    // обязан быть «слой поверх кадра», а не фильтр в mpv.
    test('десктоп размывает mpv', () {
      expect(backgroundVideoBlurRoute('linux', 10), VideoBlurRoute.mpvFilter);
      expect(backgroundVideoBlurRoute('windows', 10), VideoBlurRoute.mpvFilter);
    });

    test('телефон размывает слой над кадром', () {
      expect(backgroundVideoBlurRoute('android', 10), VideoBlurRoute.backdrop);
      expect(backgroundVideoBlurRoute('ios', 10), VideoBlurRoute.backdrop);
    });

    test('без сигмы маршрута нет — ни слоя, ни фильтра', () {
      expect(backgroundVideoBlurRoute('android', 0), VideoBlurRoute.none);
      expect(backgroundVideoBlurRoute('linux', 0.4), VideoBlurRoute.none);
    });
  });

  group('mpvBackgroundBlurFilter', () {
    // Инвариант: платформа решает, уходит ли фильтр в `vf`.
    test('desktop — gblur по сигме', () {
      expect(mpvBackgroundBlurFilter('linux', 10), 'gblur=sigma=10');
    });

    test('мобильным сборкам в mpv фильтра не отправляется никогда', () {
      expect(mpvBackgroundBlurFilter('ios', 10), isNull);
      expect(mpvBackgroundBlurFilter('android', 100), isNull);
      expect(mpvBackgroundBlurFilter('ios', 100), isNot(contains('gblur')));
    });

    test('сигма ниже порога — пусто на любой платформе (фильтр снимается)', () {
      expect(mpvBackgroundBlurFilter('linux', 0), isNull);
    });
  });

  group('mobileBackdropBlurSigma', () {
    test('потолок: гаусс по всему экрану на каждый кадр дороже большой сигмы', () {
      expect(mobileBackdropBlurSigma(4), 4);
      expect(mobileBackdropBlurSigma(12), 12);
      expect(mobileBackdropBlurSigma(25), mobileBackdropBlurMaxSigma);
      expect(mobileBackdropBlurSigma(1000), mobileBackdropBlurMaxSigma);
    });
  });
}
