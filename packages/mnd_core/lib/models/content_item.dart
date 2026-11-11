import 'dart:ui' show Color, Offset, Paint, Rect, Size;
import 'package:uuid/uuid.dart';

import 'text_outline.dart';

export 'text_outline.dart';

/// Дизайн-ширина стека: якорная модель детей (`anchor * W + offset`) считается
/// от неё и в редакторе, и в игре. `offset`-ы автор задаёт в пикселях этого
/// холста, поэтому рантайм обязан раскладывать детей при той же ширине и
/// масштабировать результат, а не раскладывать по фактической ширине ноды —
/// иначе на телефоне объект с `offsetLeft: 340` просто вылезает за край.
const double kStackDesignWidth = 720.0;

/// Дизайн-высота стека по умолчанию, когда автор её не задал. Одна на редактор
/// и плеер: раньше превью рисовало 220 px, а игра — 200.
const double kStackDesignHeight = 220.0;

/// Максимальная ширина колонки контента на широком окне. Одна на все
/// поверхности: иначе «прижать слева» в редакторе значило бы прижать к краю
/// окна, а в игре — к краю центрированной колонки.
const double kContentColumnMaxWidth = 720.0;

/// Поля холста стека в px дизайна. Пределы общие для редактора и плеера: если
/// у них разные, редактор тихо переписывает введённое значение обратно.
const double kStackCanvasWidthMin = 60;
const double kStackCanvasWidthMax = 4000;
const double kStackCanvasHeightMin = 60;
const double kStackCanvasHeightMax = 4000;

/// Где стек живёт на экране. `top`/`bottom` — фиксированные панели,
/// `left`/`right` — колонки у края (из них собирается ряд), `center` —
/// всплывающее окно, `fill` — всё доступное место (интерфейс поверх ноды).
/// `custom` — рамку задают якоря и отступы закрепления, а не ярлык.
/// Отсутствующее значение = в потоке.
const List<String> kStackPinValues = [
  'top',
  'bottom',
  'left',
  'right',
  'center',
  'fill',
  'custom',
];

/// Значение `stackPin` из JSON: только известный край, иначе null. Ядро
/// (`crates/mnd-core` · `parse_stack_pin`) чистит точно так же — обе стороны
/// должны одинаково реагировать на написанное руками «left».
String? normalizeStackPin(Object? raw) {
  final value = (raw as String?)?.trim().toLowerCase();
  return kStackPinValues.contains(value) ? value : null;
}

/// Затемнение ноды под модальным стеком, когда автор его не задал: ровно
/// настолько, чтобы отделить окно от сцены, но сцена оставалась читаемой.
const double kStackModalScrimDefault = 0.55;

/// Как картинка-фон ложится в холст стека: `cover` — заполнить холст, обрезав
/// лишнее, `contain` — вписать целиком, `fill` — растянуть по обеим осям,
/// `tile` — мозаика в нативных px картинки. Последний режим — про текстуры и
/// паттерны: их нельзя «вписать», их повторяют.
const List<String> kStackBackgroundFitValues = [
  'cover',
  'contain',
  'fill',
  'tile',
];
const String kStackBackgroundFitDefault = 'cover';

/// Значение `stackBackgroundFit` из JSON: известный режим, иначе дефолт — как
/// [normalizeStackPin], чтобы написанное руками «мозаика» не дало пустой фон.
String normalizeStackBackgroundFit(Object? raw) {
  final value = (raw as String?)?.trim().toLowerCase();
  return kStackBackgroundFitValues.contains(value)
      ? value!
      : kStackBackgroundFitDefault;
}

/// Режимы появления текста в плеере: `none` — как раньше, мгновенно;
/// `typewriter` — побуквенно; `fade` — блок проявляется плавно.
const List<String> kTextRevealValues = ['none', 'typewriter', 'fade'];
const String kTextRevealDefault = 'none';

/// Скорость проявления: видимых символов в секунду. Дефолт взят по
/// интонации визуальных новелл (~6 знаков/с читается спокойно, 40 — бодро);
/// плеер дополнительно множит на глобальную настройку игрока.
const double kRevealSpeedDefault = 40.0;
const double kRevealSpeedMin = 5.0;
const double kRevealSpeedMax = 200.0;

/// Значение `textReveal` из JSON: известный режим, иначе дефолт.
String normalizeTextReveal(Object? raw) {
  final value = (raw as String?)?.trim().toLowerCase();
  return kTextRevealValues.contains(value) ? value! : kTextRevealDefault;
}

/// Скорость проявления из JSON: в допустимом диапазоне, иначе дефолт —
/// ноль или отрицательное значение остановили бы анимацию навсегда.
double normalizeRevealSpeed(Object? raw) {
  final value = (raw as num?)?.toDouble();
  if (value == null) return kRevealSpeedDefault;
  return value.clamp(kRevealSpeedMin, kRevealSpeedMax);
}

/// Картинка-фон стека из JSON: пустая строка означает «фон не выбран», а не
/// «фон — пустой путь», иначе резолвер полез бы искать файл по пустому имени.
String? normalizeStackBackgroundPath(Object? raw) {
  final value = (raw as String?)?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

/// Ярлык [stackPin] → рамка закрепления (l, t, r, b в долях экрана). Легаси-
/// квесты хранят только строку: без этих значений плеер вернулся бы к
/// «по центру», и панель, прижатая к низу, уехала бы в центр экрана.
const Map<String, List<double>> kStackPinFallbackAnchors = {
  'top': [0.5, 0.0, 0.5, 0.0],
  'bottom': [0.5, 1.0, 0.5, 1.0],
  'left': [0.0, 0.5, 0.0, 0.5],
  'right': [1.0, 0.5, 1.0, 0.5],
  'center': [0.5, 0.5, 0.5, 0.5],
  'fill': [0.0, 0.0, 1.0, 1.0],
};

class ButtonStyleConfig {
  final String presetId;
  final String? presetName;
  final int horizontalModules;
  final int verticalModules;
  final int centerModules;
  final double moduleSize;
  final bool autoCenterByText;
  final int fillColorValue;
  final int borderColorValue;
  final int textColorValue;
  final String? cornerAsset;
  final String? hAsset;
  final String? vAsset;
  final String? centerAsset;

  // ── Текст (null = как сейчас: 16 px, обычный вес, без разрядки) ────────────
  final double? textSize;
  final int? textWeight; // 100..900 (FontWeight.w100..w900)
  final double? letterSpacing;
  final String? fontFamily; // переопределение шрифта кнопки

  // ── Форма плоской кнопки (null = авто из moduleSize, как раньше) ───────────
  final double? borderRadius;
  final double? borderWidth;
  final double? fillOpacity; // 0..1, по умолчанию 0.92
  final bool useGradient;
  final int? gradientStartColorValue;
  final int? gradientEndColorValue;
  final String? gradientDirection; // 'topBottom' (по умолчанию) | 'leftRight'

  // ── Тень (null = авто из borderColor, как раньше) ──────────────────────────
  final int? shadowColorValue;
  final double? shadowOpacity;
  final double? shadowBlur;
  final double? shadowOffsetX;
  final double? shadowOffsetY;

  // ── Паддинги (null = авто из модулей, как раньше) ──────────────────────────
  final double? paddingH;
  final double? paddingV;

  const ButtonStyleConfig({
    this.presetId = 'custom',
    this.presetName,
    this.horizontalModules = 6,
    this.verticalModules = 3,
    this.centerModules = 10,
    this.moduleSize = 12.0,
    this.autoCenterByText = true,
    this.fillColorValue = 0xFF1A2336,
    this.borderColorValue = 0xFF26C6DA,
    this.textColorValue = 0xFF26C6DA,
    this.cornerAsset,
    this.hAsset,
    this.vAsset,
    this.centerAsset,
    this.textSize,
    this.textWeight,
    this.letterSpacing,
    this.fontFamily,
    this.borderRadius,
    this.borderWidth,
    this.fillOpacity,
    this.useGradient = false,
    this.gradientStartColorValue,
    this.gradientEndColorValue,
    this.gradientDirection,
    this.shadowColorValue,
    this.shadowOpacity,
    this.shadowBlur,
    this.shadowOffsetX,
    this.shadowOffsetY,
    this.paddingH,
    this.paddingV,
  });

  Color get fillColor => Color(fillColorValue);
  Color get borderColor => Color(borderColorValue);
  Color get textColor => Color(textColorValue);
  Color get shadowColor => Color(shadowColorValue ?? borderColorValue);
  Color get gradientStartColor =>
      Color(gradientStartColorValue ?? fillColorValue);
  Color get gradientEndColor => Color(gradientEndColorValue ?? fillColorValue);
  double get effectiveFillOpacity => fillOpacity ?? 0.92;
  double get effectiveShadowOpacity => shadowOpacity ?? 0.2;
  double get effectiveShadowBlur => shadowBlur ?? 16.0;
  double get effectiveShadowOffsetX => shadowOffsetX ?? 0.0;
  double get effectiveShadowOffsetY => shadowOffsetY ?? 0.0;
  double get effectiveTextSize => textSize ?? 16.0;
  bool get gradientIsHorizontal => gradientDirection == 'leftRight';
  bool get hasModuleAssets =>
      (cornerAsset?.trim().isNotEmpty ?? false) &&
      (hAsset?.trim().isNotEmpty ?? false) &&
      (vAsset?.trim().isNotEmpty ?? false) &&
      (centerAsset?.trim().isNotEmpty ?? false);

  ButtonStyleConfig copyWith({
    String? presetId,
    String? presetName,
    int? horizontalModules,
    int? verticalModules,
    int? centerModules,
    double? moduleSize,
    bool? autoCenterByText,
    int? fillColorValue,
    int? borderColorValue,
    int? textColorValue,
    String? cornerAsset,
    String? hAsset,
    String? vAsset,
    String? centerAsset,
    bool clearModuleAssets = false,
    double? textSize,
    int? textWeight,
    double? letterSpacing,
    String? fontFamily,
    double? borderRadius,
    double? borderWidth,
    double? fillOpacity,
    bool? useGradient,
    int? gradientStartColorValue,
    int? gradientEndColorValue,
    String? gradientDirection,
    int? shadowColorValue,
    double? shadowOpacity,
    double? shadowBlur,
    double? shadowOffsetX,
    double? shadowOffsetY,
    double? paddingH,
    double? paddingV,
    bool clearTextOverrides = false,
    bool clearShapeOverrides = false,
    bool clearShadowOverrides = false,
    bool clearPaddingOverrides = false,
  }) {
    return ButtonStyleConfig(
      presetId: presetId ?? this.presetId,
      presetName: presetName ?? this.presetName,
      horizontalModules: horizontalModules ?? this.horizontalModules,
      verticalModules: verticalModules ?? this.verticalModules,
      centerModules: centerModules ?? this.centerModules,
      moduleSize: moduleSize ?? this.moduleSize,
      autoCenterByText: autoCenterByText ?? this.autoCenterByText,
      fillColorValue: fillColorValue ?? this.fillColorValue,
      borderColorValue: borderColorValue ?? this.borderColorValue,
      textColorValue: textColorValue ?? this.textColorValue,
      cornerAsset: clearModuleAssets ? null : (cornerAsset ?? this.cornerAsset),
      hAsset: clearModuleAssets ? null : (hAsset ?? this.hAsset),
      vAsset: clearModuleAssets ? null : (vAsset ?? this.vAsset),
      centerAsset: clearModuleAssets ? null : (centerAsset ?? this.centerAsset),
      textSize: clearTextOverrides ? null : (textSize ?? this.textSize),
      textWeight: clearTextOverrides ? null : (textWeight ?? this.textWeight),
      letterSpacing: clearTextOverrides
          ? null
          : (letterSpacing ?? this.letterSpacing),
      fontFamily: clearTextOverrides ? null : (fontFamily ?? this.fontFamily),
      borderRadius: clearShapeOverrides
          ? null
          : (borderRadius ?? this.borderRadius),
      borderWidth: clearShapeOverrides
          ? null
          : (borderWidth ?? this.borderWidth),
      fillOpacity: clearShapeOverrides
          ? null
          : (fillOpacity ?? this.fillOpacity),
      useGradient: useGradient ?? this.useGradient,
      gradientStartColorValue: clearShapeOverrides
          ? null
          : (gradientStartColorValue ?? this.gradientStartColorValue),
      gradientEndColorValue: clearShapeOverrides
          ? null
          : (gradientEndColorValue ?? this.gradientEndColorValue),
      gradientDirection: clearShapeOverrides
          ? null
          : (gradientDirection ?? this.gradientDirection),
      shadowColorValue: clearShadowOverrides
          ? null
          : (shadowColorValue ?? this.shadowColorValue),
      shadowOpacity: clearShadowOverrides
          ? null
          : (shadowOpacity ?? this.shadowOpacity),
      shadowBlur: clearShadowOverrides ? null : (shadowBlur ?? this.shadowBlur),
      shadowOffsetX: clearShadowOverrides
          ? null
          : (shadowOffsetX ?? this.shadowOffsetX),
      shadowOffsetY: clearShadowOverrides
          ? null
          : (shadowOffsetY ?? this.shadowOffsetY),
      paddingH: clearPaddingOverrides ? null : (paddingH ?? this.paddingH),
      paddingV: clearPaddingOverrides ? null : (paddingV ?? this.paddingV),
    );
  }

  Map<String, dynamic> toJson() => {
    'presetId': presetId,
    if (presetName != null) 'presetName': presetName,
    'horizontalModules': horizontalModules,
    'verticalModules': verticalModules,
    'centerModules': centerModules,
    'moduleSize': moduleSize,
    'autoCenterByText': autoCenterByText,
    'fillColor': fillColorValue,
    'borderColor': borderColorValue,
    'textColor': textColorValue,
    if (cornerAsset != null) 'cornerAsset': cornerAsset,
    if (hAsset != null) 'hAsset': hAsset,
    if (vAsset != null) 'vAsset': vAsset,
    if (centerAsset != null) 'centerAsset': centerAsset,
    if (textSize != null) 'textSize': textSize,
    if (textWeight != null) 'textWeight': textWeight,
    if (letterSpacing != null) 'letterSpacing': letterSpacing,
    if (fontFamily != null) 'fontFamily': fontFamily,
    if (borderRadius != null) 'borderRadius': borderRadius,
    if (borderWidth != null) 'borderWidth': borderWidth,
    if (fillOpacity != null) 'fillOpacity': fillOpacity,
    if (useGradient) 'useGradient': true,
    if (gradientStartColorValue != null)
      'gradientStartColor': gradientStartColorValue,
    if (gradientEndColorValue != null)
      'gradientEndColor': gradientEndColorValue,
    if (gradientDirection != null) 'gradientDirection': gradientDirection,
    if (shadowColorValue != null) 'shadowColor': shadowColorValue,
    if (shadowOpacity != null) 'shadowOpacity': shadowOpacity,
    if (shadowBlur != null) 'shadowBlur': shadowBlur,
    if (shadowOffsetX != null) 'shadowOffsetX': shadowOffsetX,
    if (shadowOffsetY != null) 'shadowOffsetY': shadowOffsetY,
    if (paddingH != null) 'paddingH': paddingH,
    if (paddingV != null) 'paddingV': paddingV,
  };

  factory ButtonStyleConfig.fromJson(Map<String, dynamic> json) {
    return ButtonStyleConfig(
      presetId: json['presetId'] as String? ?? 'custom',
      presetName: json['presetName'] as String?,
      horizontalModules: (json['horizontalModules'] as num?)?.toInt() ?? 6,
      verticalModules: (json['verticalModules'] as num?)?.toInt() ?? 3,
      centerModules: (json['centerModules'] as num?)?.toInt() ?? 10,
      moduleSize: (json['moduleSize'] as num?)?.toDouble() ?? 12.0,
      autoCenterByText: json['autoCenterByText'] as bool? ?? true,
      fillColorValue: (json['fillColor'] as num?)?.toInt() ?? 0xFF1A2336,
      borderColorValue: (json['borderColor'] as num?)?.toInt() ?? 0xFF26C6DA,
      textColorValue: (json['textColor'] as num?)?.toInt() ?? 0xFF26C6DA,
      cornerAsset: (json['cornerAsset'] ?? json['cornerAssetPath']) as String?,
      hAsset: (json['hAsset'] ?? json['horizontalAsset']) as String?,
      vAsset: (json['vAsset'] ?? json['verticalAsset']) as String?,
      centerAsset: (json['centerAsset'] ?? json['centerAssetPath']) as String?,
      textSize: (json['textSize'] as num?)?.toDouble(),
      textWeight: (json['textWeight'] as num?)?.toInt(),
      letterSpacing: (json['letterSpacing'] as num?)?.toDouble(),
      fontFamily: json['fontFamily'] as String?,
      borderRadius: (json['borderRadius'] as num?)?.toDouble(),
      borderWidth: (json['borderWidth'] as num?)?.toDouble(),
      fillOpacity: (json['fillOpacity'] as num?)?.toDouble(),
      useGradient: json['useGradient'] as bool? ?? false,
      gradientStartColorValue: (json['gradientStartColor'] as num?)?.toInt(),
      gradientEndColorValue: (json['gradientEndColor'] as num?)?.toInt(),
      gradientDirection: json['gradientDirection'] as String?,
      shadowColorValue: (json['shadowColor'] as num?)?.toInt(),
      shadowOpacity: (json['shadowOpacity'] as num?)?.toDouble(),
      shadowBlur: (json['shadowBlur'] as num?)?.toDouble(),
      shadowOffsetX: (json['shadowOffsetX'] as num?)?.toDouble(),
      shadowOffsetY: (json['shadowOffsetY'] as num?)?.toDouble(),
      paddingH: (json['paddingH'] as num?)?.toDouble(),
      paddingV: (json['paddingV'] as num?)?.toDouble(),
    );
  }

  static ButtonStyleConfig fantasy() {
    return const ButtonStyleConfig(
      presetId: 'fantasy',
      presetName: 'Фэнтези',
      horizontalModules: 7,
      verticalModules: 3,
      centerModules: 11,
      moduleSize: 12.0,
      autoCenterByText: true,
      fillColorValue: 0xFF1B2138,
      borderColorValue: 0xFF26C6DA,
      textColorValue: 0xFF4DD0E1,
    );
  }

  static ButtonStyleConfig classic() {
    return const ButtonStyleConfig(
      presetId: 'classic',
      presetName: 'Классика',
      horizontalModules: 6,
      verticalModules: 3,
      centerModules: 9,
      moduleSize: 11.0,
      autoCenterByText: true,
      fillColorValue: 0xFF2B2B2B,
      borderColorValue: 0xFF9E9E9E,
      textColorValue: 0xFFF5F5F5,
    );
  }
}

/// Модель кнопки для всплывающего окна
class ModalButtonConfig {
  final String id;
  final String text; // Текст кнопки (поддерживает формулы)
  final String? targetNodeId; // Целевая нода для перехода
  final String? scriptAssetId; // ID скрипта для выполнения
  final bool isPrimary; // Является ли кнопка основной (стиль)

  const ModalButtonConfig({
    required this.id,
    required this.text,
    this.targetNodeId,
    this.scriptAssetId,
    this.isPrimary = true,
  });

  ModalButtonConfig copyWith({
    String? id,
    String? text,
    String? targetNodeId,
    String? scriptAssetId,
    bool? isPrimary,
  }) {
    return ModalButtonConfig(
      id: id ?? this.id,
      text: text ?? this.text,
      targetNodeId: targetNodeId ?? this.targetNodeId,
      scriptAssetId: scriptAssetId ?? this.scriptAssetId,
      isPrimary: isPrimary ?? this.isPrimary,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    if (targetNodeId != null) 'targetNodeId': targetNodeId,
    if (scriptAssetId != null) 'scriptAssetId': scriptAssetId,
    'isPrimary': isPrimary,
  };

  factory ModalButtonConfig.fromJson(Map<String, dynamic> json) {
    return ModalButtonConfig(
      id: json['id'] as String? ?? const Uuid().v4(),
      text: json['text'] as String? ?? 'Кнопка',
      targetNodeId: json['targetNodeId'] as String?,
      scriptAssetId: json['scriptAssetId'] as String?,
      isPrimary: json['isPrimary'] as bool? ?? true,
    );
  }
}

/// Одно поведение (триггер) контент-айтема — замена старому
/// `scriptTriggers: { "onPress": "scripts/btn.json" }`.
class ContentTrigger {
  final String event;
  final String script;
  final String kind; // "action" | "visibility" | "reveal"

  const ContentTrigger({
    required this.event,
    required this.script,
    this.kind = 'action',
  });

  factory ContentTrigger.fromJson(Map<String, dynamic> json) {
    return ContentTrigger(
      event: json['event'] as String? ?? '',
      script: json['script'] as String? ?? '',
      kind: json['kind'] as String? ?? 'action',
    );
  }

  Map<String, dynamic> toJson() => {
    'event': event,
    'script': script,
    if (kind != 'action') 'kind': kind,
  };
}

class ContentItem {
  final String id;
  final String type;
  final String? text;
  final String? contentMarkdown; // Для всплывающих окон - содержимое в Markdown
  final String? targetNodeId;
  final String? resourcePath;

  /// Шаблон источника картинки (тип `image`) в том же синтаксисе, что и текст:
  /// `{pic}`, `res/{level}.png`, `{Тест["B"][1]}`. Значение подставляет движок;
  /// пустой результат или `null` — статический [resourcePath]. Смена кадра
  /// делается формулой или одним присваиванием в скрипте, а не двумя айтемами
  /// с взаимоисключающими условиями видимости.
  final String? resourceExpr;

  /// Формулы числовых полей айтема: имя поля (`padding`, `itemSpacing`,
  /// `textSize`, `borderRadius`, `duration`) → выражение, которое движок
  /// считает целиком: `hp / 2 + 16`, `min(40, hp)`. Скобки `{}` при вычислении
  /// съедаются, так что привычный текстовый вид `{hp}/2 + 16` считается так же.
  /// В редакторе поле показывает статическое число — оно остаётся дефолтом и
  /// превью. Пустые значения выкинуты при чтении, карта `null` — «формулы нет
  /// вовсе». У `duration` смысл другой: отсчёт считается один раз при
  /// появлении, пересчёт на середине перезапустил бы таймер.
  final Map<String, String>? numericExprs;
  final String? scriptAssetId; // ID скрипта для выполнения
  final String? pluginId;
  final String? pluginTypeId;
  final Map<String, dynamic>? pluginData;
  final List<ModalButtonConfig>?
  modalButtons; // Список кнопок для модального окна
  final Map<String, String>? scriptTriggers;

  /// Новый формат поведений (заменяет scriptTriggers).
  final List<ContentTrigger>? behaviours;
  final String? variableName;
  final String? placeholderText;
  final String? buttonText;
  final Color? backgroundColor;
  final double? padding;
  final double? borderRadius;

  /// Шрифт айтема: путь ресурса (`res/fonts/xx.ttf`). null — унаследовать
  /// от квеста / контейнера-родителя. Работает для текста, контейнеров
  /// (дети наследуют) и кнопок (фолбэк под buttonStyle.fontFamily).
  final String? fontFamily;

  final List<ContentItem>? children;
  final int flex;
  final String crossAxisAlignment;
  final String rowTextAlignment;
  final bool isHidden;

  /// Слой защищён от правки в редакторе канваса: не берётся тапом, рамкой и
  /// Ctrl+A. Для плеера смысла не имеет — как и [isHidden], поле редакторское.
  final bool locked;

  /// Показывать обратный отсчёт в модалке с автозакрытием. Раньше флаг прятался
  /// в `scriptTriggers` (`{'showTimer': 'true'}`), где валидация читала его как
  /// ссылку на скрипт и выдавала «скрипт удалён или переименован».
  final bool showTimer;
  final String textFit;

  /// Размер шрифта текста в px. `null` — движковый дефолт 16 (он был всегда,
  /// поэтому в json не пишется). У кнопок свой размер в `buttonStyle.textSize`.
  final double? textSize;

  /// Обводка текста: цвет контура вокруг глифов. `null` — обводки нет. Работает
  /// там, где и [textSize] (текст и заголовки markdown), и рисуется слоем ПОД
  /// заполнением, поэтому цвет из `[color=#…]` остаётся как был.
  final Color? textOutlineColor;

  /// Толщина контура в px. `null` → [kTextOutlineWidthDefault]. Без цвета поле
  /// ничего не значит — плеер его не применяет.
  final double? textOutlineWidth;

  /// Кисть обводки для рисующего: штрих в допустимых пределах или `null`, когда
  /// обводки нет. Одна на плеер и редактор — иначе превью и игра показывали бы
  /// разный контур, а автор выбирал бы толщину «на глаз» по чужому рендеру.
  Paint? get textOutlinePaint {
    final color = textOutlineColor;
    if (color == null) return null;
    return textOutlineStroke(color, width: textOutlineWidth);
  }

  /// Как текст появляется в плеере: `none` | `typewriter` | `fade`
  /// ([kTextRevealValues]). Дефолт [kTextRevealDefault] — в json не пишется,
  /// поэтому старые квесты и существующие тесты видят ровно то же, что видели.
  final String textReveal;

  /// Видимых символов в секунду для [textReveal]. Поле одно на оба режима:
  /// в `typewriter` это прям скорость печати, в `fade` — длительность
  /// проявления всего блока (длина текста / скорость), поэтому автору не нужно
  /// переводить секунды в голове.
  final double revealSpeed;

  /// Внутренний отступ между детьми контейнера (row/column).
  /// `null` — старое поведение (4px горизонталь у ряда, 8px низ у колонки).
  /// `0` — сетка без зазоров. Любое другое — используется как gap.
  final double? itemSpacing;

  /// Высота «стека» (type == 'stack') в пикселях дизайна. Ширина —
  /// [stackWidth]. `null` → [kStackDesignHeight].
  final double? stackHeight;

  /// Ширина холста «стека» в пикселях дизайна: дети заданы в них, а не в
  /// реальных px, поэтому весь холст уждается до доступной ширины целиком.
  /// `null` → [kStackDesignWidth].
  final double? stackWidth;

  /// Закрепление стека на экране: `top` | `bottom` | `center` | `fill`.
  /// `null` — стек идёт в потоке контента и скроллится вместе с ним;
  /// значение — стек поднимается в неизменный слой поверх прокрутки ноды.
  ///
  /// Само по себе значение — только ярлык: положение задают [pinAnchorLeft]
  /// … [pinOffsetBottom], а `stackPin` решает «не скроллится» и служит
  /// дефолтом рамки для квестов, написанных до неё.
  final String? stackPin;

  // ── Рамка закрепления: тот же язык, что у ребёнка стека ──────────────────
  // Только ребёнок считается от холста, а эта рамка — от экрана (SafeArea
  // ноды, в логических px):
  //   left   = pinAnchorLeft   * W + pinOffsetLeft
  //   right  = pinAnchorRight  * W + pinOffsetRight
  //   top    = pinAnchorTop    * H + pinOffsetTop
  //   bottom = pinAnchorBottom * H + pinOffsetBottom
  // `null` якорь → выводится из [stackPin] (легаси), `null` смещение → 0.
  // Схлопнутая по оси пара якорей (например 0.5/0.5) даёт размер из
  // [stackWidth]/[stackHeight]; растянутая (0/1) — бокс во весь экран по этой
  // оси. Отсюда «ряд из закреплённых стеков» = 0..0.5 и 0.5..1.
  final double? pinAnchorLeft;
  final double? pinAnchorTop;
  final double? pinAnchorRight;
  final double? pinAnchorBottom;
  final double? pinOffsetLeft;
  final double? pinOffsetTop;
  final double? pinOffsetRight;
  final double? pinOffsetBottom;

  /// Модальное окно: поверх затемнённой ноды, тапы под него не проходят, и
  /// тап мимо окна закрывает его ([stackDismissOnTapOutside]). Требует
  /// закрепления — незакреплённое окно уехало бы вместе со скроллом.
  final bool? stackModal;

  /// Плотность затемнения под модальным стекком, 0..1. `null` →
  /// [kStackModalScrimDefault]. 0 — окно без затемнения, но всё равно блокирует.
  final double? stackScrim;

  /// Закрывать ли модальное окно тапом вне его рамки. `null` → true.
  final bool? stackDismissOnTapOutside;

  /// Картинка-фон холста: путь в библиотеке, имя ресурса или его uuid — тем же
  /// языком, что `resourcePath` у слоя-картинки, и тем же резолвером. `null` —
  /// фон только цветом. Цвет лежит ПОД картинкой, а не рядом: у `contain` и
  /// `tile` остаются незакрытые места, и автору решать, чем они залиты.
  final String? stackBackgroundPath;

  /// Способ положить картинку-фон в холст — [kStackBackgroundFitValues].
  final String stackBackgroundFit;

  /// Есть ли у стека картинка-фон. Отдельный геттер потому, что пустое поле в
  /// документе возможно (руки, импорт, старый сейв), а «фон есть» от него
  /// отличаться должно.
  bool get hasStackBackgroundImage =>
      normalizeStackBackgroundPath(stackBackgroundPath) != null;

  // ── Позиционирование ребёнка внутри «стека» (Godot-модель) ───────────────
  // Четыре якоря в долях (0..1) от размера стека + четыре смещения в px:
  //   left   = anchorLeft   * W + offsetLeft
  //   right  = anchorRight  * W + offsetRight
  //   top    = anchorTop    * H + offsetTop
  //   bottom = anchorBottom * H + offsetBottom
  // Пресеты (центр, верх-лево, stretch и т.д.) — это готовые комбинации
  // якорей. Дефолт (все якоря 0.5, смещения 0) — ребёнок по центру.
  final double anchorLeft;
  final double anchorTop;
  final double anchorRight;
  final double anchorBottom;
  final double offsetLeft;
  final double offsetTop;
  final double offsetRight;
  final double offsetBottom;

  // ── Прозрачность и поворот ───────────────────────────────────────────────
  /// 0..1. Дефолт 1.0 — в json не пишется.
  final double opacity;

  /// Поворот вокруг центра бокса, в градусах. Дефолт 0 — не сериализуется.
  /// Это только отрисовка: rect ребёнка остаётся ось-выровненным, поэтому
  /// хит-тест, снаппинг и выравнивание про поворот не знают.
  final double rotation;

  /// Масштаб слоя вокруг центра бокса: 1.0 — как нарисован. Дефолт не
  /// сериализуется. Нужен потому, что рамку слоя двигает и тянет редактор, а
  /// кнопка и текст рисуются своим размером: без масштаба автор мог менять
  /// бокс, но сам объект оставался прежним.
  final double scale;

  /// Имя группы в редакторе канваса стека: дети с одинаковым именем двигаются,
  /// ресайзятся и выделяются как один объект. `null` — объект не в группе.
  /// Для плеера не значит ничего — как [locked].
  final String? groupName;

  /// Название слоя в редакторе канваса стека. В панели слоёв оно перекрывает
  /// подпись из текста/имени файла; `null` — подпись выводится как раньше.
  /// Для плеера не значит ничего — как [groupName].
  final String? layerName;

  /// Направляющие редактора канваса стека: вертикальные — расстояние от левого
  /// края холста, горизонтальные — от верхнего, в пикселях канваса. `null` —
  /// направляющих нет. Для плеера не значат ничего — как [layerName].
  final List<double>? guidesX;
  final List<double>? guidesY;

  /// Только для `row`: скруглять ли углы у детей-изображений.
  /// `null` — старое поведение (скругление 12). `false` — без скругления.
  final bool? childImageRoundedCorners;
  final bool wrapText;
  // null means use quest-level button wrap setting
  final bool? wrapTextOverride;
  final ButtonStyleConfig? buttonStyle;
  final double volume;
  // Chat fields
  final String? senderName;
  final bool isIncoming;
  final String? avatarPath;
  final int? avatarColor;
  final bool animateIn;

  // ── Видео (type == 'video') ───────────────────────────────────────────
  final String? videoUrl;
  final String? videoSourceType; // asset | url | youtube
  final String? videoPosterPath;
  final bool? videoAutoplay;
  final bool? videoLoop;
  final bool? videoMuted;
  final bool? videoShowControls;
  final bool? videoAllowFullscreen;
  final bool? videoAllowSeek;
  final String? videoFit; // contain | cover | fill
  final int? videoStartMs;
  final int? videoEndMs;
  final bool? videoBlockProgress;

  // ====== Linked template fields (Templates v2) ======
  /// Если задан — этот ContentItem связан с мастер-шаблоном `templateRef`.
  /// Различение двух режимов через [isTemplateMaster]:
  ///
  /// * `templateRef != null && !isTemplateMaster` → **linked-инстанс**:
  ///   read-only, реальное содержимое разворачивается из мастера через
  ///   `TemplateInstanceResolver`. На диске хранится только инстанс
  ///   (id + templateRef + локальные layout-поля).
  /// * `templateRef != null && isTemplateMaster` → **мастер-элемент**:
  ///   обычный full-edit ContentItem, но при сохранении его payload
  ///   автоматически пишется обратно в `TemplateRepository`, что
  ///   обновляет все linked-инстансы по всему квесту.
  /// * `templateRef == null` → обычный (snapshot) ContentItem.
  final String? templateRef;

  /// Последняя известная инстансу версия мастера. Информационное поле —
  /// при текущей политике always-latest используется только для UI
  /// (показать «обновлён» / «версия N»). При обнаружении расхождения
  /// будет переписано на актуальное при следующем сохранении.
  final int? templateVersion;

  /// true — этот объект сам является «мастером» шаблона `templateRef`.
  /// Изменения его содержимого синхронизируются с
  /// `TemplateRepository` при следующем сохранении ноды.
  /// Имеет смысл только если `templateRef != null`.
  final bool isTemplateMaster;

  ContentItem({
    required this.id,
    required this.type,
    this.text,
    this.contentMarkdown,
    this.targetNodeId,
    this.resourcePath,
    this.resourceExpr,
    this.numericExprs,
    this.scriptAssetId,
    this.pluginId,
    this.pluginTypeId,
    this.pluginData,
    this.modalButtons,
    this.scriptTriggers,
    this.behaviours,
    this.variableName,
    this.placeholderText,
    this.buttonText,
    this.backgroundColor,
    this.padding,
    this.borderRadius,
    this.fontFamily,
    this.children,
    this.flex = 1,
    this.crossAxisAlignment = 'center',
    this.rowTextAlignment = 'center',
    this.isHidden = false,
    this.locked = false,
    this.showTimer = false,
    this.textFit = 'auto',
    this.textSize,
    this.textOutlineColor,
    this.textOutlineWidth,
    this.textReveal = kTextRevealDefault,
    this.revealSpeed = kRevealSpeedDefault,
    this.itemSpacing,
    this.stackHeight,
    this.stackWidth,
    this.stackPin,
    this.pinAnchorLeft,
    this.pinAnchorTop,
    this.pinAnchorRight,
    this.pinAnchorBottom,
    this.pinOffsetLeft,
    this.pinOffsetTop,
    this.pinOffsetRight,
    this.pinOffsetBottom,
    this.stackModal,
    this.stackScrim,
    this.stackDismissOnTapOutside,
    this.stackBackgroundPath,
    this.stackBackgroundFit = kStackBackgroundFitDefault,
    this.anchorLeft = 0.5,
    this.anchorTop = 0.5,
    this.anchorRight = 0.5,
    this.anchorBottom = 0.5,
    this.offsetLeft = 0.0,
    this.offsetTop = 0.0,
    this.offsetRight = 0.0,
    this.offsetBottom = 0.0,
    this.opacity = 1.0,
    this.rotation = 0.0,
    this.scale = 1.0,
    this.groupName,
    this.layerName,
    this.guidesX,
    this.guidesY,
    this.childImageRoundedCorners,
    this.wrapText = true,
    this.wrapTextOverride,
    this.buttonStyle,
    this.volume = 1.0,
    this.senderName,
    this.isIncoming = true,
    this.avatarPath,
    this.avatarColor,
    this.animateIn = true,
    this.videoUrl,
    this.videoSourceType,
    this.videoPosterPath,
    this.videoAutoplay,
    this.videoLoop,
    this.videoMuted,
    this.videoShowControls,
    this.videoAllowFullscreen,
    this.videoAllowSeek,
    this.videoFit,
    this.videoStartMs,
    this.videoEndMs,
    this.videoBlockProgress,
    this.templateRef,
    this.templateVersion,
    this.isTemplateMaster = false,
  });

  /// Связан ли элемент с мастер-шаблоном (любой режим: linked или master).
  bool get hasTemplateLink => templateRef != null && templateRef!.isNotEmpty;

  /// Стек, закреплённый на экране: его рисует слой поверх прокрутки ноды,
  /// а не строка в списке контента. См. [stackPin].
  bool get isPinnedStack => type == 'stack' && stackPin != null;

  /// Модальное окно: затемнённая нода под стеклом, тапы до неё не доходят.
  /// Незакреплённое окно уехало бы вместе со скроллом, поэтому пин обязателен:
  /// редактор включает его сам, а json без пина остаётся обычным слоем.
  bool get isModalStack =>
      stackModal == true && type == 'stack' && stackPin != null;

  /// Насколько затемнить ноду под окном; 0 — окно без затемнения.
  double get stackScrimOpacity => isModalStack
      ? (stackScrim ?? kStackModalScrimDefault).clamp(0.0, 1.0)
      : 0.0;

  /// Закрывать ли окно тапом мимо рамки.
  bool get stackDismissesOnTapOutside =>
      isModalStack && stackDismissOnTapOutside != false;

  /// Якоря рамки закрепления (l, t, r, b в долях экрана): авторские либо
  /// выведенные из ярлыка [stackPin].
  List<double> get stackPinAnchors {
    final fallback =
        kStackPinFallbackAnchors[stackPin] ?? const [0.5, 0.5, 0.5, 0.5];
    return [
      (pinAnchorLeft ?? fallback[0]).clamp(0.0, 1.0),
      (pinAnchorTop ?? fallback[1]).clamp(0.0, 1.0),
      (pinAnchorRight ?? fallback[2]).clamp(0.0, 1.0),
      (pinAnchorBottom ?? fallback[3]).clamp(0.0, 1.0),
    ];
  }

  /// Рамка закрепления во вьюпорте [screen] — то же правило, что у ребёнка
  /// стека ([stackChildRect]), только вместо холста экран: якорь в долях плюс
  /// смещение в px. Схлопнутая по оси пара якорей оставляет авторский размер
  /// холста, но уже в px экрана: холст масштабируется по ширине
  /// (`px = дизайн-px * scale`), поэтому и высота берётся масштабированной —
  /// иначе рамка расходилась бы с тем, что реально рисует стек. Точка якоря
  /// делит бокс в той же доле, что и экран: `0` прижимает к левому/верхнему
  /// краю, `1` — к правому/нижнему, `0.5` центрирует. Поэтому легаси-панель
  /// `top` остаётся по центру по X и у верхнего края по Y.
  Rect stackPinRect(Size screen) {
    final a = stackPinAnchors;
    final sw = screen.width, sh = screen.height;
    var left = a[0] * sw + (pinOffsetLeft ?? 0);
    var top = a[1] * sh + (pinOffsetTop ?? 0);
    var right = a[2] * sw + (pinOffsetRight ?? 0);
    var bottom = a[3] * sh + (pinOffsetBottom ?? 0);
    if (right <= left) {
      final width = stackCanvasWidth < sw ? stackCanvasWidth : sw;
      left = left - width * a[0];
      right = left + width;
    }
    if (bottom <= top) {
      final scale = (right - left) / stackCanvasWidth;
      final height = stackCanvasHeight * scale;
      final capped = height < sh ? height : sh;
      top = top - capped * a[1];
      bottom = top + capped;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// Растянется ли бокс по ширине/высоте за рамки якорей (тогда холст
  /// заполняет рамку, а не сохраняется пропорция дизайн-px). У стека в потоке
  /// рамки нет, поэтому поля закрепления его не трогают.
  bool get stackPinStretchesWidth =>
      isPinnedStack && stackPinAnchors[2] - stackPinAnchors[0] > 1e-6;
  bool get stackPinStretchesHeight =>
      isPinnedStack && stackPinAnchors[3] - stackPinAnchors[1] > 1e-6;

  /// Копия, у которой рамка закрепления во вьюпорте [screen] становится
  /// [rect]: якоря не трогаются — ровно как у [stackChildWithRect]. Точное
  /// зеркало [stackPinRect]: редактор даёт автору X/Y/W/H позиции на экране,
  /// а в документ идут якоря + отступы.
  ///
  /// Схлопнутая по оси пара якорей не имеет своего размера — рамка там равна
  /// холсту, поэтому W/H такой оси пишется в [stackWidth]/[stackHeight], а из
  /// смещений остаётся только позиция. Иначе поле «высота» у панели
  /// `top`/`bottom` молча делало бы ничего.
  ContentItem stackPinWithRect(Rect rect, Size screen) {
    final a = stackPinAnchors;
    final sw = screen.width, sh = screen.height;
    final stretchesW = stackPinStretchesWidth;
    final stretchesH = stackPinStretchesHeight;
    final canvasWidth =
        (stretchesW ? (stackWidth ?? kStackDesignWidth) : rect.width).clamp(
          kStackCanvasWidthMin,
          kStackCanvasWidthMax,
        );
    // Масштаб, тем же правилом, что и рендер: холст ужимается/растётся по
    // ширине рамки, а высота следует за ним.
    final scale = rect.width / canvasWidth;
    final offLeft = stretchesW
        ? rect.left - a[0] * sw
        : rect.left + a[0] * (rect.width - sw);
    final offTop = stretchesH
        ? rect.top - a[1] * sh
        : rect.top + a[1] * (rect.height - sh);
    return copyWith(
      stackWidth: stretchesW ? null : canvasWidth,
      stackHeight: stretchesH
          ? null
          : (rect.height / scale).clamp(
              kStackCanvasHeightMin,
              kStackCanvasHeightMax,
            ),
      pinOffsetLeft: offLeft,
      pinOffsetRight: stretchesW ? rect.right - a[2] * sw : offLeft,
      pinOffsetTop: offTop,
      pinOffsetBottom: stretchesH ? rect.bottom - a[3] * sh : offTop,
    );
  }

  /// Копия с новыми якорями рамки [anchors] (l, t, r, b в долях экрана).
  /// Вёрстка детей не трогается: `stackWidth`/`stackHeight` остаются авторские
  /// (px дизайна), а рамка пересчитывается от них — схлопнутая ось даёт холст
  /// в px экрана, растянутая расстояние между якорями. Поэтому сетка позиции
  /// и переключатели «растянуть» переставляют панель, но не тяют её содержимое.
  ContentItem stackPinWithAnchors(List<double> anchors, Size screen) {
    final sw = screen.width, sh = screen.height;
    final l = anchors[0], t = anchors[1], r = anchors[2], b = anchors[3];
    final stretchedX = r - l > 1e-6;
    final stretchedY = b - t > 1e-6;
    final canvasW = stackCanvasWidth, canvasH = stackCanvasHeight;
    final widthScreen = stretchedX
        ? (r - l) * sw
        : (canvasW < sw ? canvasW : sw);
    final scale = widthScreen / canvasW;
    final height = canvasH * scale;
    final heightScreen = stretchedY
        ? (b - t) * sh
        : (height < sh ? height : sh);
    // Доля свободного места = позиция: 0 прижимает к краю, 0.5 центрирует.
    final left = stretchedX ? l * sw : (sw - widthScreen) * l;
    final top = stretchedY ? t * sh : (sh - heightScreen) * t;
    // Растянутая ось сохраняет свои отступы-поля: штора с зазором 8 не должна
    // их терять, когда автор меняет позицию по второй оси. Схлопнутая ось
    // задаёт только позицию.
    final offLeft = stretchedX
        ? (pinOffsetLeft ?? 0)
        : left + l * (widthScreen - sw);
    final offTop = stretchedY
        ? (pinOffsetTop ?? 0)
        : top + t * (heightScreen - sh);
    return copyWith(
      stackPin: 'custom',
      pinAnchorLeft: l,
      pinAnchorTop: t,
      pinAnchorRight: r,
      pinAnchorBottom: b,
      pinOffsetLeft: offLeft,
      pinOffsetRight: stretchedX ? (pinOffsetRight ?? 0) : offLeft,
      pinOffsetTop: offTop,
      pinOffsetBottom: stretchedY ? (pinOffsetBottom ?? 0) : offTop,
    );
  }

  /// Доля экрана, на которой стоит центр рамки по каждой оси — из неё
  /// считается схлопнутая пара якорей при отмене растяжения.
  List<double> stackPinCenterFractions(Size screen) {
    final rect = stackPinRect(screen);
    return [
      (rect.center.dx / screen.width).clamp(0.0, 1.0),
      (rect.center.dy / screen.height).clamp(0.0, 1.0),
    ];
  }

  /// Ширина холста стека в px дизайна: то, относительно чего ребёнок считает
  /// `anchor * W + offset`. Автор может задать свою — иначе 720.
  double get stackCanvasWidth => (stackWidth ?? kStackDesignWidth).clamp(
    kStackCanvasWidthMin,
    kStackCanvasWidthMax,
  );

  /// Высота холста стека в px дизайна. Зеркало [stackCanvasWidth]: те же
  /// пределы и тот же дефолт в редакторе и в игре.
  double get stackCanvasHeight => (stackHeight ?? kStackDesignHeight).clamp(
    kStackCanvasHeightMin,
    kStackCanvasHeightMax,
  );

  /// Rect ребёнка внутри «стека» размером [w]×[h] (Godot-модель):
  /// left = anchorLeft*w + offsetLeft и т.д. Используется и рендером
  /// (GameStackWidget), и превью редактора.
  Rect stackChildRect(double w, double h) => Rect.fromLTRB(
    anchorLeft * w + offsetLeft,
    anchorTop * h + offsetTop,
    anchorRight * w + offsetRight,
    anchorBottom * h + offsetBottom,
  );

  /// Возвращает копию ребёнка, у которой rect внутри стека [w]×[h]
  /// становится [rect]. Якоря не меняются — двигаются только offset'ы
  /// (Godot-поведение: перемещение/изменение размера не трогает якоря).
  /// Используется визуальным редактором стека (драг в превью).
  ContentItem stackChildWithRect(Rect rect, double w, double h) => copyWith(
    offsetLeft: rect.left - anchorLeft * w,
    offsetTop: rect.top - anchorTop * h,
    offsetRight: rect.right - anchorRight * w,
    offsetBottom: rect.bottom - anchorBottom * h,
  );

  /// Является ли элемент **linked-инстансом** шаблона (read-only от мастера).
  bool get isTemplateInstance => hasTemplateLink && !isTemplateMaster;

  /// Является ли элемент **мастером** шаблона (источник правды для linked).
  bool get isTemplateMasterItem => hasTemplateLink && isTemplateMaster;

  // ── Видео хелперы ─────────────────────────────────────────────────────
  bool get isVideoAsset =>
      type == 'video' &&
      (videoSourceType == null || videoSourceType == 'asset') &&
      (resourcePath != null && resourcePath!.isNotEmpty);

  bool get isVideoNetwork =>
      type == 'video' &&
      ((videoUrl != null && videoUrl!.isNotEmpty) ||
          (videoSourceType == 'url' || videoSourceType == 'youtube'));

  bool get isYoutubeVideo {
    if (videoUrl == null) return false;
    final u = videoUrl!.toLowerCase();
    return u.contains('youtube.com') ||
        u.contains('youtu.be') ||
        videoSourceType == 'youtube';
  }

  /// Эффективный источник видео: локальный путь или внешний URL.
  String? get effectiveVideoSource {
    if (videoUrl != null && videoUrl!.trim().isNotEmpty)
      return videoUrl!.trim();
    return resourcePath;
  }

  /// Есть ли у айтема формула-источник картинки.
  bool get hasResourceExpr =>
      resourceExpr != null && resourceExpr!.trim().isNotEmpty;

  /// Путь картинки, которую рисовать **сейчас**: [resourceExpr] уже подставлен
  /// движком в [evaluatedExpr], а если значения нет — статический
  /// [resourcePath].
  ///
  /// Пустой результат формулы не роняет картинку: автор мог её ещё не дописать,
  /// а показывать пустоту — значит сломать сцену. Подстановку делает
  /// вызывающий (только он знает, где взять движок и состояние), чтобы модель
  /// не тянула Riverpod.
  String? resolveResourcePath({String? evaluatedExpr}) {
    final value = evaluatedExpr?.trim();
    if (hasResourceExpr &&
        value != null &&
        value.isNotEmpty &&
        !_isUnset(value)) {
      return value;
    }
    return resourcePath;
  }

  /// Движок на неизвестную переменную отвечает её же именем: `{pic}` без
  /// значения превращается в `pic`. Для текста это терпимо, картинку `pic`
  /// искать бессмысленно — считаем источник не заполненным.
  bool _isUnset(String evaluated) {
    final single = RegExp(r'^\{([^{}]+)\}$').firstMatch(resourceExpr!.trim());
    return single?.group(1)?.trim() == evaluated;
  }

  /// Формула числового поля [field] (`padding`, `itemSpacing`, `textSize`,
  /// `borderRadius`, `duration`) или `null`, если её не задавали.
  String? numericExpr(String field) {
    final expr = numericExprs?[field]?.trim();
    return (expr == null || expr.isEmpty) ? null : expr;
  }

  /// Копия с формулой числового поля [field]. Пустая строка и `null` формулу
  /// снимают; если после этого карты не остаётся, поле становится `null` —
  /// пустой объект в JSON не плодим (паритет с Rust-моделью).
  ContentItem withNumericExpr(String field, String? expr) {
    final kept = <String, String>{
      for (final entry in (numericExprs ?? const <String, String>{}).entries)
        if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
    };
    final value = expr?.trim();
    if (value == null || value.isEmpty) {
      kept.remove(field);
    } else {
      kept[field] = value;
    }
    return copyWith(
      numericExprs: kept.isEmpty ? null : kept,
      forceNumericExprs: true,
    );
  }

  /// Число поля [field], которое использовать **сейчас**: [evaluatedValue] —
  /// формула уже вычислена движком. Без формулы, с невычисленным значением
  /// (движок не нашёл переменную, формула сломалась) и с не-числом берём
  /// статическое [staticValue] — тот же откат, что у картинки: автор мог
  /// формулу ещё не дописать, а ронять сцену из-за этого нельзя.
  ///
  /// Вычисление делает вызывающий: только он знает, где взять движок и
  /// состояние сессии, а модель не тянет Riverpod.
  double resolveNumeric(
    String field, {
    required double? evaluatedValue,
    required double staticValue,
  }) {
    if (numericExpr(field) == null) return staticValue;
    if (evaluatedValue == null || !evaluatedValue.isFinite) return staticValue;
    return evaluatedValue;
  }

  /// Все поведения айтема (новый формат или из старых scriptTriggers).
  List<ContentTrigger> get resolvedBehaviours {
    if (behaviours != null && behaviours!.isNotEmpty) {
      return behaviours!;
    }
    if (scriptTriggers != null) {
      return scriptTriggers!.entries
          .where((e) => e.value.isNotEmpty)
          .map(
            (e) =>
                ContentTrigger(event: e.key, script: e.value, kind: 'action'),
          )
          .toList();
    }
    return const [];
  }

  /// Скрипт, привязанный к событию (`onPress`, `onSubmit`, `onAppear`, …) в
  /// любом из двух форматов: новый `behaviours` или legacy `scriptTriggers`.
  /// Пустые ссылки не возвращаются — айтем с `onPress: ''` нажатием не считается.
  String? scriptForEvent(String event) {
    for (final b in resolvedBehaviours) {
      if (b.event == event && b.script.trim().isNotEmpty) return b.script;
    }
    return null;
  }

  /// Те же события, но картой `событие → скрипт`. Нужна редактору, который
  /// показывает занятость слотов: без неё он читал только legacy
  /// `scriptTriggers` и молчал на айтеме с `behaviours`, хотя плеер скрипт
  /// выполнял. Правило совпадает с [scriptForEvent]: при двух форматах
  /// побеждают `behaviours`, пустые ссылки выпадают, первое событие — первое.
  Map<String, String> get resolvedTriggers {
    final out = <String, String>{};
    for (final b in resolvedBehaviours) {
      if (b.script.trim().isNotEmpty) {
        out.putIfAbsent(b.event, () => b.script);
      }
    }
    return out;
  }

  /// Записать скрипт события в тот формат, который читает движок.
  ///
  /// `behaviours` перекрывает legacy: движок не смотрит в `scriptTriggers`,
  /// пока есть непустые `behaviours`. Поэтому запись в legacy при живых
  /// `behaviours` — мёртвый код: слот выглядит занятым, тап создаёт второй
  /// скрипт, который никогда не запускается.
  ///
  /// `kind` уже занятого события сохраняется: условие видимости
  /// (`visibility`) нельзя случайно превратить в действие сменой скрипта.
  ContentItem withTrigger(String event, String script) {
    if (behaviours != null && behaviours!.isNotEmpty) {
      return copyWith(
        behaviours: [
          for (final b in behaviours!)
            if (b.event != event) b,
          ContentTrigger(event: event, script: script, kind: _kindOf(event)),
        ],
      );
    }
    final legacy = Map<String, String>.from(scriptTriggers ?? const {});
    legacy[event] = script;
    return copyWith(scriptTriggers: legacy);
  }

  /// Убрать скрипт события из обоих форматов: осталась бы запись в том,
  /// который редактор больше не показывает, и значок занятого слота не
  /// гас бы после «удалить».
  ContentItem withoutTrigger(String event) {
    final legacy = Map<String, String>.from(scriptTriggers ?? const {})
      ..remove(event);
    final behs = behaviours ?? const <ContentTrigger>[];
    final kept = [
      for (final b in behs)
        if (b.event != event) b,
    ];
    return copyWith(
      behaviours: kept,
      forceClearBehaviours: kept.isEmpty,
      scriptTriggers: legacy,
      forceClearTriggers: legacy.isEmpty,
    );
  }

  String _kindOf(String event) {
    for (final b in behaviours ?? const <ContentTrigger>[]) {
      if (b.event == event) return b.kind;
    }
    return 'action';
  }

  ContentItem copyWith({
    String? id,
    String? type,
    String? text,
    String? contentMarkdown,
    String? targetNodeId,
    bool clearTargetNodeId = false,
    String? resourcePath,
    String? resourceExpr,
    bool clearResourceExpr = false,
    Map<String, String>? numericExprs,
    bool forceNumericExprs = false,
    String? scriptAssetId,
    String? pluginId,
    String? pluginTypeId,
    Map<String, dynamic>? pluginData,
    List<ModalButtonConfig>? modalButtons,
    Map<String, String>? scriptTriggers,
    bool forceClearTriggers = false,
    List<ContentTrigger>? behaviours,
    bool forceClearBehaviours = false,
    String? variableName,
    String? placeholderText,
    String? buttonText,
    Color? backgroundColor,
    bool clearBackgroundColor = false,
    double? padding,
    bool clearPadding = false,
    double? borderRadius,
    bool clearBorderRadius = false,
    String? fontFamily,
    bool clearFontFamily = false,
    List<ContentItem>? children,
    int? flex,
    String? crossAxisAlignment,
    String? rowTextAlignment,
    bool? isHidden,
    bool? locked,
    bool? showTimer,
    String? textFit,
    double? textSize,
    Color? textOutlineColor,
    double? textOutlineWidth,
    String? textReveal,
    double? revealSpeed,
    bool clearTextSize = false,
    bool clearTextOutline = false,
    double? itemSpacing,
    bool clearItemSpacing = false,
    double? stackHeight,
    bool clearStackHeight = false,
    double? stackWidth,
    bool clearStackWidth = false,
    String? stackPin,
    double? pinAnchorLeft,
    double? pinAnchorTop,
    double? pinAnchorRight,
    double? pinAnchorBottom,
    double? pinOffsetLeft,
    double? pinOffsetTop,
    double? pinOffsetRight,
    double? pinOffsetBottom,
    bool clearStackPinBox = false,
    bool? stackModal,
    double? stackScrim,
    bool? stackDismissOnTapOutside,
    String? stackBackgroundPath,
    String? stackBackgroundFit,
    bool clearStackBackground = false,
    bool clearStackModal = false,
    bool clearStackPin = false,
    double? anchorLeft,
    double? anchorTop,
    double? anchorRight,
    double? anchorBottom,
    double? offsetLeft,
    double? offsetTop,
    double? offsetRight,
    double? offsetBottom,
    double? opacity,
    double? rotation,
    double? scale,
    String? groupName,
    bool clearGroupName = false,
    String? layerName,
    bool clearLayerName = false,
    List<double>? guidesX,
    bool clearGuidesX = false,
    List<double>? guidesY,
    bool clearGuidesY = false,
    bool? childImageRoundedCorners,
    bool clearChildImageRoundedCorners = false,
    bool? wrapText,
    bool? wrapTextOverride,
    bool clearWrapTextOverride = false,
    ButtonStyleConfig? buttonStyle,
    bool clearButtonStyle = false,
    double? volume,
    String? senderName,
    bool? isIncoming,
    String? avatarPath,
    int? avatarColor,
    bool? animateIn,
    String? videoUrl,
    String? videoSourceType,
    String? videoPosterPath,
    bool? videoAutoplay,
    bool? videoLoop,
    bool? videoMuted,
    bool? videoShowControls,
    bool? videoAllowFullscreen,
    bool? videoAllowSeek,
    String? videoFit,
    int? videoStartMs,
    int? videoEndMs,
    bool? videoBlockProgress,
    String? templateRef,
    int? templateVersion,
    bool? isTemplateMaster,
    bool clearTemplateLink = false,
  }) {
    return ContentItem(
      id: id ?? this.id,
      type: type ?? this.type,
      text: text ?? this.text,
      contentMarkdown: contentMarkdown ?? this.contentMarkdown,
      targetNodeId: clearTargetNodeId
          ? null
          : (targetNodeId ?? this.targetNodeId),
      resourcePath: resourcePath ?? this.resourcePath,
      resourceExpr: clearResourceExpr
          ? null
          : (resourceExpr ?? this.resourceExpr),
      numericExprs: forceNumericExprs
          ? numericExprs
          : (numericExprs ?? this.numericExprs),
      scriptAssetId: scriptAssetId ?? this.scriptAssetId,
      pluginId: pluginId ?? this.pluginId,
      pluginTypeId: pluginTypeId ?? this.pluginTypeId,
      pluginData: pluginData ?? this.pluginData,
      modalButtons: modalButtons ?? this.modalButtons,
      scriptTriggers: forceClearTriggers
          ? null
          : (scriptTriggers ?? this.scriptTriggers),
      behaviours: forceClearBehaviours ? null : (behaviours ?? this.behaviours),
      variableName: variableName ?? this.variableName,
      placeholderText: placeholderText ?? this.placeholderText,
      buttonText: buttonText ?? this.buttonText,
      backgroundColor: clearBackgroundColor
          ? null
          : (backgroundColor ?? this.backgroundColor),
      padding: clearPadding ? null : (padding ?? this.padding),
      borderRadius: clearBorderRadius
          ? null
          : (borderRadius ?? this.borderRadius),
      fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
      children: children ?? this.children,
      flex: flex ?? this.flex,
      crossAxisAlignment: crossAxisAlignment ?? this.crossAxisAlignment,
      rowTextAlignment: rowTextAlignment ?? this.rowTextAlignment,
      isHidden: isHidden ?? this.isHidden,
      locked: locked ?? this.locked,
      showTimer: showTimer ?? this.showTimer,
      textFit: textFit ?? this.textFit,
      textSize: clearTextSize ? null : (textSize ?? this.textSize),
      textOutlineColor: clearTextOutline
          ? null
          : (textOutlineColor ?? this.textOutlineColor),
      textOutlineWidth: clearTextOutline
          ? null
          : (textOutlineWidth ?? this.textOutlineWidth),
      textReveal: textReveal ?? this.textReveal,
      revealSpeed: revealSpeed ?? this.revealSpeed,
      itemSpacing: clearItemSpacing ? null : (itemSpacing ?? this.itemSpacing),
      stackHeight: clearStackHeight ? null : (stackHeight ?? this.stackHeight),
      stackWidth: clearStackWidth ? null : (stackWidth ?? this.stackWidth),
      stackPin: clearStackPin ? null : (stackPin ?? this.stackPin),
      pinAnchorLeft: clearStackPinBox
          ? null
          : (pinAnchorLeft ?? this.pinAnchorLeft),
      pinAnchorTop: clearStackPinBox
          ? null
          : (pinAnchorTop ?? this.pinAnchorTop),
      pinAnchorRight: clearStackPinBox
          ? null
          : (pinAnchorRight ?? this.pinAnchorRight),
      pinAnchorBottom: clearStackPinBox
          ? null
          : (pinAnchorBottom ?? this.pinAnchorBottom),
      pinOffsetLeft: clearStackPinBox
          ? null
          : (pinOffsetLeft ?? this.pinOffsetLeft),
      pinOffsetTop: clearStackPinBox
          ? null
          : (pinOffsetTop ?? this.pinOffsetTop),
      pinOffsetRight: clearStackPinBox
          ? null
          : (pinOffsetRight ?? this.pinOffsetRight),
      pinOffsetBottom: clearStackPinBox
          ? null
          : (pinOffsetBottom ?? this.pinOffsetBottom),
      stackModal: clearStackModal ? null : (stackModal ?? this.stackModal),
      stackScrim: clearStackModal ? null : (stackScrim ?? this.stackScrim),
      stackBackgroundPath: clearStackBackground
          ? null
          : (stackBackgroundPath ?? this.stackBackgroundPath),
      // Режим без картинки не значит ничего, поэтому «убрать фон» обнуляет и
      // его: иначе следующий фон печатался бы в чужой мозаике.
      stackBackgroundFit: clearStackBackground
          ? kStackBackgroundFitDefault
          : (stackBackgroundFit ?? this.stackBackgroundFit),
      stackDismissOnTapOutside: clearStackModal
          ? null
          : (stackDismissOnTapOutside ?? this.stackDismissOnTapOutside),
      anchorLeft: anchorLeft ?? this.anchorLeft,
      anchorTop: anchorTop ?? this.anchorTop,
      anchorRight: anchorRight ?? this.anchorRight,
      anchorBottom: anchorBottom ?? this.anchorBottom,
      offsetLeft: offsetLeft ?? this.offsetLeft,
      offsetTop: offsetTop ?? this.offsetTop,
      offsetRight: offsetRight ?? this.offsetRight,
      offsetBottom: offsetBottom ?? this.offsetBottom,
      opacity: opacity ?? this.opacity,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      groupName: clearGroupName ? null : (groupName ?? this.groupName),
      layerName: clearLayerName ? null : (layerName ?? this.layerName),
      guidesX: clearGuidesX ? null : (guidesX ?? this.guidesX),
      guidesY: clearGuidesY ? null : (guidesY ?? this.guidesY),
      childImageRoundedCorners: clearChildImageRoundedCorners
          ? null
          : (childImageRoundedCorners ?? this.childImageRoundedCorners),
      wrapText: wrapText ?? this.wrapText,
      wrapTextOverride: clearWrapTextOverride
          ? null
          : (wrapTextOverride ?? this.wrapTextOverride),
      buttonStyle: clearButtonStyle ? null : (buttonStyle ?? this.buttonStyle),
      volume: volume ?? this.volume,
      senderName: senderName ?? this.senderName,
      isIncoming: isIncoming ?? this.isIncoming,
      avatarPath: avatarPath ?? this.avatarPath,
      avatarColor: avatarColor ?? this.avatarColor,
      animateIn: animateIn ?? this.animateIn,
      videoUrl: videoUrl ?? this.videoUrl,
      videoSourceType: videoSourceType ?? this.videoSourceType,
      videoPosterPath: videoPosterPath ?? this.videoPosterPath,
      videoAutoplay: videoAutoplay ?? this.videoAutoplay,
      videoLoop: videoLoop ?? this.videoLoop,
      videoMuted: videoMuted ?? this.videoMuted,
      videoShowControls: videoShowControls ?? this.videoShowControls,
      videoAllowFullscreen: videoAllowFullscreen ?? this.videoAllowFullscreen,
      videoAllowSeek: videoAllowSeek ?? this.videoAllowSeek,
      videoFit: videoFit ?? this.videoFit,
      videoStartMs: videoStartMs ?? this.videoStartMs,
      videoEndMs: videoEndMs ?? this.videoEndMs,
      videoBlockProgress: videoBlockProgress ?? this.videoBlockProgress,
      templateRef: clearTemplateLink ? null : (templateRef ?? this.templateRef),
      templateVersion: clearTemplateLink
          ? null
          : (templateVersion ?? this.templateVersion),
      isTemplateMaster: clearTemplateLink
          ? false
          : (isTemplateMaster ?? this.isTemplateMaster),
    );
  }

  static Color? _colorFromInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return Color(value);
    if (value is num) return Color(value.toInt());
    return null;
  }

  factory ContentItem.fromJson(Map<String, dynamic> json) {
    var childrenList = <ContentItem>[];
    if (json['children'] != null && json['children'] is List) {
      childrenList = (json['children'] as List)
          .map((i) => ContentItem.fromJson(i as Map<String, dynamic>))
          .toList();
    }

    // Парсим кнопки модалки если есть
    List<ModalButtonConfig>? modalButtons;
    if (json['modalButtons'] != null && json['modalButtons'] is List) {
      modalButtons = (json['modalButtons'] as List)
          .map((b) => ModalButtonConfig.fromJson(b as Map<String, dynamic>))
          .toList();
    }

    final legacyWrapText = json['wrapText'] as bool? ?? true;
    final type = json['type'] as String;

    // Флаг обратного отсчёта модалки исторически ехал в `scriptTriggers`
    // (`"showTimer": "true"`), хотя это не ссылка на скрипт. При чтении он
    // переезжает в своё поле и выпадает из карты: иначе плеер и редактор
    // видели бы занятый слот триггера «showTimer» вместо настройки модалки.
    // Так старые файлы квестов не теряют настройку.
    Map<String, String>? scriptTriggers;
    var showTimer = json['showTimer'] as bool? ?? false;
    final rawTriggers = json['scriptTriggers'] as Map?;
    if (rawTriggers != null) {
      final kept = <String, String>{};
      rawTriggers.forEach((key, value) {
        final event = key.toString();
        if (event == 'showTimer') {
          if (value.toString() == 'true') showTimer = true;
          return;
        }
        kept[event] = value?.toString() ?? '';
      });
      if (kept.isNotEmpty) scriptTriggers = kept;
    }

    // Формулы числовых полей: пробелы съедаем, пустые значения не держим —
    // иначе Rust-модель после round-trip вернёт карту без них, а сохранение
    // покажет фантомные изменения.
    Map<String, String>? numericExprs;
    final rawNumericExprs = json['numericExprs'] as Map?;
    if (rawNumericExprs != null) {
      final kept = <String, String>{};
      rawNumericExprs.forEach((key, value) {
        final expr = value?.toString().trim() ?? '';
        if (expr.isNotEmpty) kept[key.toString()] = expr;
      });
      if (kept.isNotEmpty) numericExprs = kept;
    }

    return ContentItem(
      id: json['id'] as String? ?? const Uuid().v4(),
      type: type,
      text: json['text'] as String?,
      contentMarkdown: json['contentMarkdown'] as String?,
      targetNodeId: json['targetNodeId'] as String?,
      resourcePath:
          json['resourcePath'] as String? ?? json['imagePath'] as String?,
      resourceExpr: json['resourceExpr'] as String?,
      numericExprs: numericExprs,
      scriptAssetId: json['scriptAssetId'] as String?,
      pluginId: json['pluginId'] as String?,
      pluginTypeId: json['pluginTypeId'] as String?,
      pluginData: json['pluginData'] is Map
          ? Map<String, dynamic>.from(json['pluginData'] as Map)
          : null,
      modalButtons: modalButtons,
      scriptTriggers: scriptTriggers,
      behaviours: (json['behaviours'] as List?)
          ?.map((b) => ContentTrigger.fromJson(b as Map<String, dynamic>))
          .toList(),
      variableName: json['variableName'] as String?,
      placeholderText: json['placeholderText'] as String?,
      buttonText: json['buttonText'] as String?,
      backgroundColor: _colorFromInt(json['backgroundColor']),
      padding: (json['padding'] as num?)?.toDouble(),
      borderRadius: (json['borderRadius'] as num?)?.toDouble(),
      fontFamily: json['fontFamily'] as String?,
      children: childrenList.isNotEmpty ? childrenList : null,
      flex: (json['flex'] as num?)?.toInt() ?? 1,
      crossAxisAlignment: json['crossAxisAlignment'] as String? ?? 'center',
      rowTextAlignment: json['rowTextAlignment'] as String? ?? 'center',
      isHidden: json['isHidden'] as bool? ?? false,
      locked: json['locked'] as bool? ?? false,
      showTimer: showTimer,
      textFit: json['textFit'] as String? ?? 'auto',
      textSize: (json['textSize'] as num?)?.toDouble(),
      textOutlineColor: _colorFromInt(json['textOutlineColor']),
      textOutlineWidth: (json['textOutlineWidth'] as num?)?.toDouble(),
      textReveal: normalizeTextReveal(json['textReveal']),
      revealSpeed: normalizeRevealSpeed(json['revealSpeed']),
      itemSpacing: (json['itemSpacing'] as num?)?.toDouble(),
      stackHeight: (json['stackHeight'] as num?)?.toDouble(),
      stackWidth: (json['stackWidth'] as num?)?.toDouble(),
      stackPin: normalizeStackPin(json['stackPin']),
      pinAnchorLeft: (json['pinAnchorLeft'] as num?)?.toDouble(),
      pinAnchorTop: (json['pinAnchorTop'] as num?)?.toDouble(),
      pinAnchorRight: (json['pinAnchorRight'] as num?)?.toDouble(),
      pinAnchorBottom: (json['pinAnchorBottom'] as num?)?.toDouble(),
      pinOffsetLeft: (json['pinOffsetLeft'] as num?)?.toDouble(),
      pinOffsetTop: (json['pinOffsetTop'] as num?)?.toDouble(),
      pinOffsetRight: (json['pinOffsetRight'] as num?)?.toDouble(),
      pinOffsetBottom: (json['pinOffsetBottom'] as num?)?.toDouble(),
      stackModal: json['stackModal'] as bool?,
      stackScrim: (json['stackScrim'] as num?)?.toDouble(),
      stackDismissOnTapOutside: json['stackDismissOnTapOutside'] as bool?,
      stackBackgroundPath: normalizeStackBackgroundPath(
        json['stackBackgroundPath'],
      ),
      stackBackgroundFit: normalizeStackBackgroundFit(
        json['stackBackgroundFit'],
      ),
      anchorLeft: (json['anchorLeft'] as num?)?.toDouble() ?? 0.5,
      anchorTop: (json['anchorTop'] as num?)?.toDouble() ?? 0.5,
      anchorRight: (json['anchorRight'] as num?)?.toDouble() ?? 0.5,
      anchorBottom: (json['anchorBottom'] as num?)?.toDouble() ?? 0.5,
      offsetLeft: (json['offsetLeft'] as num?)?.toDouble() ?? 0.0,
      offsetTop: (json['offsetTop'] as num?)?.toDouble() ?? 0.0,
      offsetRight: (json['offsetRight'] as num?)?.toDouble() ?? 0.0,
      offsetBottom: (json['offsetBottom'] as num?)?.toDouble() ?? 0.0,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
      groupName: json['groupName'] as String?,
      layerName: json['layerName'] as String?,
      guidesX: _guides(json['guidesX']),
      guidesY: _guides(json['guidesY']),
      childImageRoundedCorners: json['childImageRoundedCorners'] as bool?,
      wrapText: legacyWrapText,
      wrapTextOverride: json.containsKey('wrapTextOverride')
          ? json['wrapTextOverride'] as bool?
          : ((type == 'button' || type == 'input') && legacyWrapText == false
                ? false
                : null),
      buttonStyle: json['buttonStyle'] is Map<String, dynamic>
          ? ButtonStyleConfig.fromJson(
              json['buttonStyle'] as Map<String, dynamic>,
            )
          : (json['buttonStyle'] is Map
                ? ButtonStyleConfig.fromJson(
                    Map<String, dynamic>.from(json['buttonStyle'] as Map),
                  )
                : null),
      volume: (json['volume'] as num? ?? 1.0).toDouble(),
      senderName: json['senderName'] as String?,
      isIncoming: json['isIncoming'] as bool? ?? true,
      avatarPath: json['avatarPath'] as String?,
      avatarColor: (json['avatarColor'] as num?)?.toInt(),
      animateIn: json['animateIn'] as bool? ?? true,
      videoUrl: json['videoUrl'] as String?,
      videoSourceType: json['videoSourceType'] as String?,
      videoPosterPath: json['videoPosterPath'] as String?,
      videoAutoplay: json['videoAutoplay'] as bool?,
      videoLoop: json['videoLoop'] as bool?,
      videoMuted: json['videoMuted'] as bool?,
      videoShowControls: json['videoShowControls'] as bool?,
      videoAllowFullscreen: json['videoAllowFullscreen'] as bool?,
      videoAllowSeek: json['videoAllowSeek'] as bool?,
      videoFit: json['videoFit'] as String?,
      videoStartMs: (json['videoStartMs'] as num?)?.toInt(),
      videoEndMs: (json['videoEndMs'] as num?)?.toInt(),
      videoBlockProgress: json['videoBlockProgress'] as bool?,
      templateRef: json['templateRef'] as String?,
      templateVersion: (json['templateVersion'] as num?)?.toInt(),
      isTemplateMaster: json['isTemplateMaster'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    if (text != null) 'text': text,
    if (contentMarkdown != null) 'contentMarkdown': contentMarkdown,
    if (targetNodeId != null) 'targetNodeId': targetNodeId,
    if (resourcePath != null) 'resourcePath': resourcePath,
    if (resourceExpr != null) 'resourceExpr': resourceExpr,
    if (numericExprs != null && numericExprs!.isNotEmpty)
      'numericExprs': numericExprs,
    if (scriptAssetId != null) 'scriptAssetId': scriptAssetId,
    if (pluginId != null) 'pluginId': pluginId,
    if (pluginTypeId != null) 'pluginTypeId': pluginTypeId,
    if (pluginData != null) 'pluginData': pluginData,
    if (modalButtons != null)
      'modalButtons': modalButtons!.map((b) => b.toJson()).toList(),
    if (scriptTriggers != null) 'scriptTriggers': scriptTriggers,
    if (behaviours != null && behaviours!.isNotEmpty)
      'behaviours': behaviours!.map((b) => b.toJson()).toList(),
    if (variableName != null) 'variableName': variableName,
    if (placeholderText != null) 'placeholderText': placeholderText,
    if (buttonText != null) 'buttonText': buttonText,
    if (backgroundColor != null) 'backgroundColor': backgroundColor!.value,
    if (padding != null) 'padding': padding,
    if (borderRadius != null) 'borderRadius': borderRadius,
    if (fontFamily != null) 'fontFamily': fontFamily,
    if (children != null) 'children': children!.map((x) => x.toJson()).toList(),
    'flex': flex,
    'crossAxisAlignment': crossAxisAlignment,
    'rowTextAlignment': rowTextAlignment,
    'isHidden': isHidden,
    'locked': locked,
    // Пишем только включённый флаг: false = ключа нет.
    if (showTimer) 'showTimer': true,
    'textFit': textFit,
    if (textSize != null) 'textSize': textSize,
    // Цвет без толщины — обводки нет, поэтому пишем их только вместе.
    if (textOutlineColor != null) 'textOutlineColor': textOutlineColor!.value,
    if (textOutlineColor != null && textOutlineWidth != null)
      'textOutlineWidth': textOutlineWidth,
    if (textReveal != kTextRevealDefault) 'textReveal': textReveal,
    if (revealSpeed != kRevealSpeedDefault) 'revealSpeed': revealSpeed,
    if (itemSpacing != null) 'itemSpacing': itemSpacing,
    if (stackHeight != null) 'stackHeight': stackHeight,
    if (stackWidth != null) 'stackWidth': stackWidth,
    if (stackPin != null) 'stackPin': stackPin,
    if (pinAnchorLeft != null) 'pinAnchorLeft': pinAnchorLeft,
    if (pinAnchorTop != null) 'pinAnchorTop': pinAnchorTop,
    if (pinAnchorRight != null) 'pinAnchorRight': pinAnchorRight,
    if (pinAnchorBottom != null) 'pinAnchorBottom': pinAnchorBottom,
    if (pinOffsetLeft != null) 'pinOffsetLeft': pinOffsetLeft,
    if (pinOffsetTop != null) 'pinOffsetTop': pinOffsetTop,
    if (pinOffsetRight != null) 'pinOffsetRight': pinOffsetRight,
    if (pinOffsetBottom != null) 'pinOffsetBottom': pinOffsetBottom,
    if (stackModal != null) 'stackModal': stackModal,
    if (stackScrim != null) 'stackScrim': stackScrim,
    if (stackDismissOnTapOutside != null)
      'stackDismissOnTapOutside': stackDismissOnTapOutside,
    // Фон — это пара полей: путь и режим. Без пути режим не пишем, иначе стек
    // без фона таскал бы за собой бессмысленный ключ.
    if (hasStackBackgroundImage) ...{
      'stackBackgroundPath': stackBackgroundPath!.trim(),
      if (stackBackgroundFit != kStackBackgroundFitDefault)
        'stackBackgroundFit': stackBackgroundFit,
    },
    if (anchorLeft != 0.5) 'anchorLeft': anchorLeft,
    if (anchorTop != 0.5) 'anchorTop': anchorTop,
    if (anchorRight != 0.5) 'anchorRight': anchorRight,
    if (anchorBottom != 0.5) 'anchorBottom': anchorBottom,
    if (offsetLeft != 0.0) 'offsetLeft': offsetLeft,
    if (offsetTop != 0.0) 'offsetTop': offsetTop,
    if (offsetRight != 0.0) 'offsetRight': offsetRight,
    if (offsetBottom != 0.0) 'offsetBottom': offsetBottom,
    if (opacity != 1.0) 'opacity': opacity,
    if (rotation != 0.0) 'rotation': rotation,
    if (scale != 1.0) 'scale': scale,
    if (groupName != null) 'groupName': groupName,
    if (layerName != null) 'layerName': layerName,
    if (guidesX != null && guidesX!.isNotEmpty) 'guidesX': guidesX,
    if (guidesY != null && guidesY!.isNotEmpty) 'guidesY': guidesY,
    if (childImageRoundedCorners != null)
      'childImageRoundedCorners': childImageRoundedCorners,
    'wrapText': wrapText,
    if (wrapTextOverride != null) 'wrapTextOverride': wrapTextOverride,
    if (buttonStyle != null) 'buttonStyle': buttonStyle!.toJson(),
    'volume': volume,
    if (senderName != null) 'senderName': senderName,
    'isIncoming': isIncoming,
    if (avatarPath != null) 'avatarPath': avatarPath,
    if (avatarColor != null) 'avatarColor': avatarColor,
    'animateIn': animateIn,
    if (videoUrl != null) 'videoUrl': videoUrl,
    if (videoSourceType != null) 'videoSourceType': videoSourceType,
    if (videoPosterPath != null) 'videoPosterPath': videoPosterPath,
    if (videoAutoplay != null) 'videoAutoplay': videoAutoplay,
    if (videoLoop != null) 'videoLoop': videoLoop,
    if (videoMuted != null) 'videoMuted': videoMuted,
    if (videoShowControls != null) 'videoShowControls': videoShowControls,
    if (videoAllowFullscreen != null)
      'videoAllowFullscreen': videoAllowFullscreen,
    if (videoAllowSeek != null) 'videoAllowSeek': videoAllowSeek,
    if (videoFit != null) 'videoFit': videoFit,
    if (videoStartMs != null) 'videoStartMs': videoStartMs,
    if (videoEndMs != null) 'videoEndMs': videoEndMs,
    if (videoBlockProgress != null) 'videoBlockProgress': videoBlockProgress,
    if (templateRef != null) 'templateRef': templateRef,
    if (templateVersion != null) 'templateVersion': templateVersion,
    if (isTemplateMaster) 'isTemplateMaster': true,
  };
}

/// Направляющие из json: список чисел или ничего. Пустой список, не-список и
/// произвольные элементы внутри — это «направляющих нет»: редактирует человек,
/// а не протокол, и чинить здесь нечего.
List<double>? _guides(Object? raw) {
  if (raw is! List) return null;
  final values = [
    for (final v in raw)
      if (v is num) v.toDouble(),
  ];
  return values.isEmpty ? null : List<double>.unmodifiable(values);
}

/// Режим драга ребёнка в визуальном редакторе «стека».
enum StackChildDragMode {
  move,
  resizeTL,
  resizeTR,
  resizeBL,
  resizeBR,

  /// Середины сторон: тянут одну ось, вторая остаётся на месте.
  resizeLeft,
  resizeRight,
  resizeTop,
  resizeBottom;

  /// У угловой ручки есть смысл «сохранить пропорции» (Shift). У ручки
  /// середины стороны вторая ось не двигается, поэтому aspect-lock для неё
  /// ничего не значит.
  bool get isCorner =>
      this == resizeTL ||
      this == resizeTR ||
      this == resizeBL ||
      this == resizeBR;
}

/// Применяет сдвиг [delta] к rect [start] согласно режиму драга.
///
/// - [move] — весь бокс сдвигается;
/// - resize* — двигается один угол, противоположный остаётся на месте;
/// - [keepAspect] у resize* держит исходные пропорции (Shift в редакторе):
///   масштаб берётся по той оси, по которой указатель ушёл дальше относительно
///   своего размера, вторая подстраивается. Для середин сторон игнорируется.
Rect applyStackChildDrag(
  Rect start,
  StackChildDragMode mode,
  Offset delta, {
  bool keepAspect = false,
}) {
  // Вырожденный rect не имеет пропорций: деление на ноль дало бы NaN в
  // координатах, поэтому такой ресайз идёт обычным путём.
  if (keepAspect && mode.isCorner && start.width > 0 && start.height > 0) {
    return _resizeKeepingAspect(start, mode, delta);
  }
  switch (mode) {
    case StackChildDragMode.move:
      return start.shift(delta);
    case StackChildDragMode.resizeTL:
      return Rect.fromLTRB(
        start.left + delta.dx,
        start.top + delta.dy,
        start.right,
        start.bottom,
      );
    case StackChildDragMode.resizeTR:
      return Rect.fromLTRB(
        start.left,
        start.top + delta.dy,
        start.right + delta.dx,
        start.bottom,
      );
    case StackChildDragMode.resizeBL:
      return Rect.fromLTRB(
        start.left + delta.dx,
        start.top,
        start.right,
        start.bottom + delta.dy,
      );
    case StackChildDragMode.resizeBR:
      return Rect.fromLTRB(
        start.left,
        start.top,
        start.right + delta.dx,
        start.bottom + delta.dy,
      );
    case StackChildDragMode.resizeLeft:
      return Rect.fromLTRB(
        start.left + delta.dx,
        start.top,
        start.right,
        start.bottom,
      );
    case StackChildDragMode.resizeRight:
      return Rect.fromLTRB(
        start.left,
        start.top,
        start.right + delta.dx,
        start.bottom,
      );
    case StackChildDragMode.resizeTop:
      return Rect.fromLTRB(
        start.left,
        start.top + delta.dy,
        start.right,
        start.bottom,
      );
    case StackChildDragMode.resizeBottom:
      return Rect.fromLTRB(
        start.left,
        start.top,
        start.right,
        start.bottom + delta.dy,
      );
  }
}

/// Resize с фиксированным соотношением сторон. Противоположный тащимому угол
/// остаётся на месте, как в обычном ресайзе; знак ширины и высоты не
/// подбирается — разворот через ноль остаётся поведением вызывающего кода.
Rect _resizeKeepingAspect(Rect start, StackChildDragMode mode, Offset delta) {
  final widthDragged =
      mode == StackChildDragMode.resizeTL ||
      mode == StackChildDragMode.resizeBL;
  final heightDragged =
      mode == StackChildDragMode.resizeTL ||
      mode == StackChildDragMode.resizeTR;
  // Для TL движение влево ширину увеличивает, поэтому знак сдвига зависит от
  // того, с какой стороны бокса работает ручка.
  final wRaw = start.width + (widthDragged ? -delta.dx : delta.dx);
  final hRaw = start.height + (heightDragged ? -delta.dy : delta.dy);
  final ratio = start.height == 0 ? 1.0 : start.width / start.height;

  // Нормированное отклонение: 40 px у бокса в 400 px — мелочь, а у бокса
  // в 40 px — удвоение. Ведущей считается ось, где палец ушёл дальше.
  final wDev = start.width == 0 ? wRaw.abs() : (wRaw / start.width - 1).abs();
  final hDev = start.height == 0 ? hRaw.abs() : (hRaw / start.height - 1).abs();
  final useWidth = wDev >= hDev;
  final w = useWidth ? wRaw : hRaw * ratio;
  final h = useWidth ? wRaw / ratio : hRaw;

  final anchor = switch (mode) {
    StackChildDragMode.resizeTL => start.bottomRight,
    StackChildDragMode.resizeTR => start.bottomLeft,
    StackChildDragMode.resizeBL => start.topRight,
    _ => start.topLeft,
  };
  return Rect.fromLTWH(
    widthDragged ? anchor.dx - w : anchor.dx,
    heightDragged ? anchor.dy - h : anchor.dy,
    w,
    h,
  );
}
