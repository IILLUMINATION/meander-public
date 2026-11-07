// Детализация канваса: что рисовать на node при текущем зуме и цене кадра.
//
// Раньше при `scale < 0.35` ноды рисовались целиком без текста («миникарта»),
// и на большом отдалении граф превращался в набор одинаковых плашек —
// ориентироваться по нему было нельзя. Теперь подпись остаётся всегда, а
// экономия идёт по измеренной цене кадра: подписи уступают место бюджетом
// только когда сборка списка отрисовки и правда не успевает в кадр.

class CanvasLod {
  CanvasLod._();

  /// Порог, ниже которого описание ноды, пилюли-индикаторы и якоря связей не
  /// рисуются: они в этом масштабе всё равно неразборчивы, но и недёшевы.
  static const double detailsMinScale = 0.35;

  /// Сколько нод должно быть видно одновременно, чтобы упрощение вообще
  /// включалось. На маленьком графе (как на экране с десятком нод) кадр и так
  /// укладывается в бюджет, а снятые подписи и детали только портят вид.
  static const int lodMinNodes = 40;

  /// Сколько миллисекунд UI-потока на сборку списка отрисовки канваса мы
  /// считаем нормой. Кадр 60 fps — 16.6 мс, половину оставляем остальному UI.
  static const double frameBudgetMs = 8.0;

  /// Ниже этого числа подписей не опускаемся никогда: без единой подписи
  /// канвас снова становится «миникартой», а это ровно то, на что жалуются.
  static const int minTitleBudget = 8;

  /// Детали (описание, индикаторы, якоря) рисовать при текущем зуме?
  ///
  /// Упрощение включается только на большом графе: при [visibleNodes] не выше
  /// [lodMinNodes] детали остаются, даже если ноды уменьшены.
  static bool showDetails(double scale, {int visibleNodes = 0}) =>
      visibleNodes <= lodMinNodes || scale >= detailsMinScale;
}

/// Скользящая цена кадра канваса и вытекающий бюджет подписей.
///
/// Живёт в `State` экрана, а не в `CanvasState`: последний immutable и
/// копируется на каждый жест, а здесь наоборот — mutating счётчик.
class CanvasFrameCost {
  double _emaMs = 0;

  /// `null` = бюджета ещё нет, подписей рисуется столько, сколько влезло.
  int? _budget;

  double get measuredMs => _emaMs;

  /// Сколько подписей разрешить в этом кадре при [visibleNodes] видимых нодах.
  int budgetFor(int visibleNodes) {
    if (visibleNodes <= CanvasLod.lodMinNodes) return visibleNodes;
    final budget = _budget;
    return budget == null ? visibleNodes : budget.clamp(0, visibleNodes);
  }

  /// [paintMs] — время сборки списка отрисовки (UI-поток), не растеризация.
  /// Именно здесь дорог `TextPainter.layout` на каждую подпись.
  void record(double paintMs, {required int visibleNodes}) {
    _emaMs = _emaMs <= 0 ? paintMs : _emaMs * 0.6 + paintMs * 0.4;
    if (visibleNodes <= CanvasLod.lodMinNodes) {
      // Мало нод: подписи не могут быть причиной тяжёлого кадра — не режем.
      _budget = null;
      return;
    }
    final current = _budget ?? visibleNodes;
    if (_emaMs > CanvasLod.frameBudgetMs) {
      // Кадр не влезает: режем подписи, но оставляем запас для восстановления.
      final shrunk = (current * 0.6).floor();
      _budget = shrunk < CanvasLod.minTitleBudget
          ? CanvasLod.minTitleBudget
          : shrunk;
    } else if (_emaMs < CanvasLod.frameBudgetMs * 0.6) {
      // Явный запас по времени — отыгрываем обратно, но не рывком, чтобы
      // бюджет не гулял вверх-вниз на каждом кадре.
      final grown = (current * 1.5).ceil();
      _budget = grown >= visibleNodes ? null : grown;
    }
  }

  void reset() {
    _emaMs = 0;
    _budget = null;
  }
}
