// Как выглядит обводка текста — здесь и только здесь.
//
// Обводку рисуют четыре разные поверхности: плеер (слоем штриха под заливкой),
// редактор стека, превью markdown-редактора и экспорт в HTML (там доступен
// только `text-shadow`), плюс web-плеер. Раньше каждая считала толщину и
// геометрию сама, и контур в превью не совпадал ни с игрой, ни со страницей.
// Теперь толщина, кисть и кольцо смещений для теневых рендереров считаются
// ядром, а клиент только рисует ими.
//
// Толщина трактуется как полная ширина контура: [textOutlineShadowOffsets]
// сдвигает копии на полтолщины, а штрих [textOutlineStroke] идёт по центру
// глифа, поэтому наружу торчит ровно полтолщины — и оба способа дают один
// визуальный размер.

import 'dart:ui'
    show Color, Offset, Paint, PaintingStyle, Shadow, StrokeCap, StrokeJoin;

/// Толщина контура обводки по умолчанию: автор её задаёт ползунком, а квесту,
/// написанному руками с одним цветом, хватает и этого.
const double kTextOutlineWidthDefault = 2.0;
const double kTextOutlineWidthMin = 0.5;
const double kTextOutlineWidthMax = 12.0;

/// Толщина из json — в допустимых пределах. Значения вне диапазона приходят
/// из ручных правок файла: 50 px контур в браузере съел бы текст целиком.
double normalizeTextOutlineWidth(double? width) =>
    (width ?? kTextOutlineWidthDefault).clamp(
      kTextOutlineWidthMin,
      kTextOutlineWidthMax,
    );

/// Кисть контура: штрих по глифам, который кладётся ПОД слой заливки.
///
/// `strokeJoin`/`strokeCap` — round, а не дефолтные miter/butt: на острых
/// стыках глифа miter вытягивает шип длиной в толщину, и толстая обводка
/// обрастает иглами. Скруглённые стыки дают ровное кольцо на любой толщине.
Paint textOutlineStroke(Color color, {double? width}) => Paint()
  ..style = PaintingStyle.stroke
  ..isAntiAlias = true
  ..strokeJoin = StrokeJoin.round
  ..strokeCap = StrokeCap.round
  ..color = color
  ..strokeWidth = normalizeTextOutlineWidth(width);

/// Прозрачный штрих: текст без собственной обводки в слое контура. Нужен,
/// когда контур есть только у фрагментов `[outline=…]` — остальное не видно.
final Paint transparentTextOutlineStroke = Paint()
  ..style = PaintingStyle.stroke
  ..color = const Color(0x00000000);

/// Кольцо смещений для рендереров, где есть только копии глифа со сдвигом
/// (CSS `text-shadow`, `TextStyle.shadows`): восемь направлений на
/// полтолщины, без центральной копии — она съела бы само начертание.
List<Offset> textOutlineShadowOffsets({double? width}) {
  final half = normalizeTextOutlineWidth(width) / 2.0;
  return [
    for (final dx in [-half, 0.0, half])
      for (final dy in [-half, 0.0, half])
        if (dx != 0.0 || dy != 0.0) Offset(dx, dy),
  ];
}

/// То же кольцо, но готовыми тенями для Flutter.
List<Shadow> textOutlineShadows(Color color, {double? width}) => [
  for (final offset in textOutlineShadowOffsets(width: width))
    Shadow(color: color, offset: offset, blurRadius: 0),
];

/// Инлайн-тег фрагментной обводки `[outline=#RRGGBB[:толщина]]…[/outline]`.
///
/// Шаблон живёт в ядре, потому что его читают все парсеры разметки — игровой,
/// редакторский и веб-плеера. Разные шаблоны значили бы разный набор
/// распознаваемых тегов на разных поверхностях.
final RegExp inlineOutlineTag = RegExp(
  r'\[outline=(#[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{8})(?::([0-9]+(?:\.[0-9]+)?))?\]([\s\S]*?)\[\/outline\]',
);

/// Есть ли в тексте фрагментная обводка.
bool hasInlineOutline(String text) => inlineOutlineTag.hasMatch(text);
