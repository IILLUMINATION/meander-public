// Детализация канваса: что рисовать на ноде и связях.
//
// Раньше детали привязывались к зуму: при `scale < 0.35` ноды рисовались
// без тела, при `scale < 0.5` у связей пропадали кривые и стрелки. На
// отдалении граф превращался в набор одинаковых плашек без направлений —
// ориентироваться было нельзя. Теперь зум на детализацию не влияет: тело
// карточки прячется только при большом числе нод в кадре или когда кадр
// перестаёт влезать в бюджет по измеренному времени.

class CanvasLod {
  CanvasLod._();

  /// Сколько видимых нод ещё показывают тело карточки (реплики, ветки,
  /// счётчики). Выше порога тело прячется: сотни карточек в кадре — это уже
  /// не работа с графом, а обзор.
  static const int detailsMaxVisibleNodes = 250;

  /// Сколько миллисекунд UI-потока на сборку списка отрисовки канваса мы
  /// считаем нормой. Кадр 60 fps — 16.6 мс, половину оставляем остальному UI.
  static const double frameBudgetMs = 8.0;

  /// Порог по цене кадра для тела карточки: выше — прячем, ниже — возвращаем.
  /// Между порогами решение не меняется (гистерезис).
  static const double detailsDropAboveMs = 16.0;
  static const double detailsRestoreBelowMs = 9.0;

  /// Ниже этого числа подписей не опускаемся никогда: без единой подписи
  /// канвас снова становится «миникартой», а это ровно то, на что жалуются.
  static const int minTitleBudget = 8;

  /// Детали (описание, индикаторы, якоря) рисовать при таком числе нод?
  ///
  /// Цена кадра проверяется отдельно — [CanvasFrameCost.detailsAllowed].
  static bool showDetailsFor(int visibleNodes) =>
      visibleNodes <= detailsMaxVisibleNodes;
}

/// Скользящая цена кадра канваса и вытекающий бюджет подписей.
///
/// Живёт в `State` экрана, а не в `CanvasState`: последний immutable и
/// копируется на каждый жест, а здесь наоборот — mutating счётчик.
class CanvasFrameCost {
  double _emaMs = 0;

  /// `null` = бюджета ещё нет, подписей рисуется столько, сколько влезло.
  int? _budget;

  /// Тело карточки на медленном кадре прячется первым: оно дороже подписи.
  /// Гистерезис (порог отключения выше порога возврата) не даёт деталям
  /// мигать на каждом кадре.
  bool _details = true;

  double get measuredMs => _emaMs;

  /// Можно ли сейчас рисовать тело карточки.
  bool get detailsAllowed => _details;

  /// Сколько подписей разрешить в этом кадре при [visibleNodes] видимых нодах.
  int budgetFor(int visibleNodes) {
    final budget = _budget;
    return budget == null ? visibleNodes : budget.clamp(0, visibleNodes);
  }

  /// [paintMs] — время сборки списка отрисовки (UI-поток), не растеризация.
  /// Именно здесь дорог `TextPainter.layout` на каждую подпись.
  void record(double paintMs, {required int visibleNodes}) {
    _emaMs = _emaMs <= 0 ? paintMs : _emaMs * 0.6 + paintMs * 0.4;
    final current = _budget ?? visibleNodes;
    if (_emaMs > CanvasLod.detailsDropAboveMs) {
      _details = false;
    } else if (_emaMs < CanvasLod.detailsRestoreBelowMs) {
      _details = true;
    }
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
    _details = true;
  }
}
