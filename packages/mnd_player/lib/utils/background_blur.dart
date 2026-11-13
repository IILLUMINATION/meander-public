/// Размытие, когда его не задал ни скрипт, ни нода.
const double defaultBackgroundBlur = 10.0;

/// Правило приоритета фонового размытия в плеере.
///
/// Значение приходит из трёх мест, и порядок именно такой:
/// 1. канал эффектов скрипта (`set_blur`) — свежая воля автора на рантайме;
/// 2. поле ноды `backgroundBlur` — то, что автор выставил в редакторе;
/// 3. [defaultBackgroundBlur] — исторический дефолт плеера.
///
/// Раньше было наоборот (`nodeBlur ?? stateBlur`), поэтому блок `set_blur` не
/// мог перебить ноду, а движок к тому же сеял 10.0 в канал эффектов при каждом
/// старте игры — то есть «скрипт» был активен всегда.
double resolveBackgroundBlur({
  double? scriptBlur,
  double? nodeBlur,
  double fallback = defaultBackgroundBlur,
}) {
  return scriptBlur ?? nodeBlur ?? fallback;
}

/// Значение канала эффектов `_internal_background_blur` из зеркала состояния.
///
/// Движок пишет туда число, но в переменную мог попасть и обычный
/// `assign_variable` — тогда приходит строка (или целое после JSON round-trip).
/// Приводим то, что приводится; остальное считаем «скрипт не задавал».
double? parseBackgroundBlur(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

/// Стоит ли вообще применять размытие к этому значению.
///
/// Порог 0.5, а не `> 0`: при малых сигмах `ImageFiltered` даёт почти резкую
/// картинку, но стоит отдельный offscreen-слой — на слабых устройствах такой
/// «почти ноль» выгоднее не рисовать вовсе.
bool shouldApplyBackgroundBlur(double sigma) => sigma > 0.5;

/// Сигма, которую отдаём фону — картинке или видео.
///
/// Единая точка для обеих веток, потому что видео раньше резалась другим
/// рубильником (`shouldDisableBlur`, т.е. тяжёлые эффекты): он на Linux всегда
/// `true`, и авторское размытие доходило до видео нулём — фон оставался резким,
/// хотя для картинки тот же `ImageFiltered` рисовался.
double gateBackgroundBlur(double sigma, {required bool disabled}) =>
    disabled || !shouldApplyBackgroundBlur(sigma) ? 0.0 : sigma;

/// Отдавать ли mpv фильтр `gblur` на этой платформе.
///
/// Мобильные libmpv media_kit берёт готовыми, и ffmpeg-фильтры в них не
/// компилируют: в `libmpv.so` из `media_kit_libs_android_video` строк
/// `gblur`/`boxblur`/`avgblur` нет вообще (проверено grep по arm64-артефакту
/// gradle-кэша), есть только собственные фильтры mpv — `format`, `scale`,
/// `crop`, `overlay`, `equalizer`. На `--vf=gblur` такой mpv пишет
/// `filter 'gblur' not found` уровнем FATAL, а кадр остаётся резким.
///
/// На десктопе фильтр проверен живым mpv 0.41 против его же системного
/// libmpv: `--hwdec=auto-safe --vf=gblur=sigma=10` и `--hwdec=no` проходят без
/// ошибок — mpv сам скачивает кадр в обычную память, поэтому `hwdec` трогать
/// не нужно. Мобильный mpv этого не делает, см. `_applyMpvBlur`.
///
/// [platform] — `defaultTargetPlatform.name` ('ios', 'android', 'linux', …).
bool mpvBlurFilterSupported(String platform) {
  return platform != 'android' && platform != 'ios';
}

/// Где размывать фоновое видео.
enum VideoBlurRoute {
  /// Десктоп: фильтр `gblur` внутри mpv — кадр размывается до того, как
  /// станет внешней текстурой.
  mpvFilter,

  /// Мобильная сборка: ffmpeg-фильтров в libmpv нет, поэтому размывает
  /// Flutter-слой `BackdropFilter` поверх уже нарисованного кадра.
  backdrop,

  /// Сигмы нет — ни слоя, ни фильтра.
  none,
}

/// Каким способом размывать фон-видео на этой платформе.
///
/// Проверено живым mpv 0.41 против его же системного libmpv:
/// `--vf=gblur=sigma=10` меняет кадр (PSNR к исходному 23.7 дБ), а
/// `--vf=format=w=320:h=180` — нет, байт в байт: у mpv-овского `format`
/// размеры только согласуют пиксельный формат, скале он не делает
/// (нативного `scale`-фильтра у mpv тоже нет). Поэтому «даунскейл как
/// замена гаусса» на мобильных сборках был бы пустой строкой в `vf`, а
/// `iw/4` этот mpv ещё и отвергает при разборе.
VideoBlurRoute backgroundVideoBlurRoute(String platform, double sigma) {
  if (!shouldApplyBackgroundBlur(sigma)) return VideoBlurRoute.none;
  return mpvBlurFilterSupported(platform)
      ? VideoBlurRoute.mpvFilter
      : VideoBlurRoute.backdrop;
}

/// Фильтр mpv для фоновому видео, либо null — если на этой платформе кадр
/// размывает Flutter ([backgroundVideoBlurRoute]), а не mpv.
String? mpvBackgroundBlurFilter(String platform, double sigma) =>
    mpvBlurFilterSupported(platform) ? backgroundVideoBlurFilter(sigma) : null;

/// Верхняя граница сигмы для мобильного слоя-размытия поверх видео.
///
/// `BackdropFilter` на телефоне — это гаусс по всему экрану на каждый кадр,
/// и в отличие от `gblur` внутри mpv (там кадр ещё маленький и один проход)
/// платит он именно частотой кадров. Дальше ~12 фон уже не различим как
/// картинка, а FPS продолжает падать — поэтому ползунок автора выше этого
/// значения просто упирается в потолок.
const double mobileBackdropBlurMaxSigma = 12.0;

double mobileBackdropBlurSigma(double sigma) =>
    sigma.clamp(0.0, mobileBackdropBlurMaxSigma);

/// Фильтр mpv для desktop-сборок: `gblur=sigma=N`.
///
/// `ImageFiltered` поверх видео бессилен: media_kit показывает кадр через
/// `Texture` — внешнюю GL-текстуру, и движок не гонит такие слои через
/// offscreen-пасс фильтра (flutter#144266, flutter#183842 — «working as
/// intended»). Поэтому размываем там, где кадр ещё наш: в цепочке фильтров
/// mpv, которую media_kit отдаёт наружу через `NativePlayer.setProperty`.
///
/// `gblur` берёт сигму напрямую, один-в-один как `ImageFilter.blur` у
/// картинки, — обе ветки фона выглядят одинаково при одном значении автора.
/// mpv регистрирует ffmpeg-фильтры по имени, поэтому достаточно `gblur=…`.
String? backgroundVideoBlurFilter(double sigma) {
  if (!shouldApplyBackgroundBlur(sigma)) return null;
  // Верхняя граница — за CPU: gblur линейен по сигме, а фон крутится 24/7.
  final clamped = sigma.clamp(0.5, 25.0);
  return 'gblur=sigma=${clamped.round()}';
}
