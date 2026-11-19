import 'dart:math' as math;

import 'package:canvas_app/features/editor/logic/item_editor_helper.dart';
import 'package:canvas_app/features/editor/logic/stack_canvas_ops.dart';
import 'package:canvas_app/features/editor/logic/stack_canvas_session.dart';
import 'package:canvas_app/features/editor/screens/node_content/content_editor_logic.dart';
import 'package:canvas_app/features/editor/screens/node_content/stack_canvas/stack_canvas_hotkeys.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/editor/widgets/content_add_menu.dart';
import 'package:canvas_app/features/editor/widgets/editor_ui.dart'
    show showEditorSheet;
import 'package:canvas_app/features/editor/widgets/plugin_content_form.dart';
import 'package:canvas_app/features/editor/widgets/stack_anchor_presets.dart';
import 'package:canvas_app/features/editor/widgets/stack_help_panel.dart';
import 'package:canvas_app/features/editor/widgets/stack_pin_box_editor.dart';
import 'package:canvas_app/features/editor/widgets/stack_pin_selector.dart';
import 'package:canvas_app/features/editor/widgets/trigger_slot_buttons.dart';
import 'package:canvas_app/features/plugins/providers/plugin_content_types_provider.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart'
    show ResourceSelectionScreen, SelectableResource;
import 'package:canvas_app/shared/canvas/camera_state.dart';
import 'package:canvas_app/shared/widgets/color_palette_picker.dart'
    show showColorPickerDialog;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mnd_core/models/content_item.dart'
    show
        ContentItem,
        StackChildDragMode,
        applyStackChildDrag,
        kStackBackgroundFitValues,
        kTextOutlineWidthDefault,
        kTextOutlineWidthMax;
import 'package:mnd_player/services/font_service.dart';
import 'package:mnd_player/widgets/content_display_factory.dart'
    show ImageItemWidget;
import 'package:mnd_player/widgets/items/game_stack_widget.dart'
    show paintStackChildBox, StackBackgroundFile;
import 'package:uuid/uuid.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/node_content/stack_canvas/stack_rect_fields.dart';

// ================================================================
// Бесконечный канвас-редактор стека.
//
// Подход: FittedBox + SizedBox(stackCanvasWidth×stackHeight) — ровно та же
// модель, что в плеере. Дети рендерятся реальными
// Flutter-виджетами в фиксированном layout, а FittedBox +
// Transform обеспечивают pan/zoom.
//
// Документ и выделение — в StackCanvasSession (undo/redo, групповые
// правки), экрану остаются камера, жесты и отрисовка.
// ================================================================

/// Живые значения шита свойств. Ползунок, числовое поле и слушатель потери
/// фокуса пишут в один экземпляр: любое из них обязано показать то, что уже
/// попало в документ, а не снимок слоя на момент открытия шита.
class _SheetValues {
  _SheetValues({
    required this.opacity,
    required this.rotation,
    required this.scale,
    required this.textSize,
  });

  double opacity;
  double rotation;
  double scale;
  double textSize;

  double get(String field) => switch (field) {
    'opacity' => opacity,
    'rotation' => rotation,
    'scale' => scale,
    _ => textSize,
  };

  void set(String field, double value) {
    switch (field) {
      case 'opacity':
        opacity = value;
      case 'rotation':
        rotation = value;
      case 'scale':
        scale = value;
      default:
        textSize = value;
    }
  }
}

/// Хит-область служебных ручек и длина «ножки» ручки поворота — в координатах
/// вьюпорта, поэтому не зависят от зума.
const double kStackHandleHit = 28.0;
const double kStackRotateStem = 26.0;

/// Поля масштаба слоя: проценты, целые шаги, как у прозрачности.
const int kStackScaleMinPercent = 10;
const int kStackScaleMaxPercent = 400;

/// На сколько уезжает вниз-вправо каждая следующая вставка одного и того же.
const double kStackPasteStep = 16.0;

/// Человеческие имена режимов картинки-фона: `tile` автору ничего не скажет, а
/// «Мозаика» — ровно то, зачем берут текстуру или паттерн.
///
/// Геттер, а не const-таблица: подписи строятся под текущий язык.
Map<String, String> get stackBackgroundFitLabels => {
  'cover': tr('Заполнить'),
  'contain': tr('Вписать'),
  'fill': tr('Растянуть'),
  'tile': tr('Мозаика'),
};

/// Имена трёх судеб содержимого при новом размере холста. «Только рамка» —
/// прежнее поведение, поэтому оно и названо первым: правка обводки не должна
/// сама по себе двигать вёрстку.
// Геттер, а не final-таблица: подписи строятся под текущий язык.
Map<StackContentScale, String> get kStackContentScaleLabels => {
  StackContentScale.keep: tr('Только рамка'),
  StackContentScale.uniform: tr('Пропорционально'),
  StackContentScale.stretch: tr('По осям'),
};

/// Пояснение выбранного режима: множители не очевидны по названию, а цена
/// ошибки — переделанная вёрстка.
Map<StackContentScale, String> get kStackContentScaleHints => {
  StackContentScale.keep:
      tr('Слои остаются в старых пикселях: холст можно подогнать под вёрстку, не трогая её.'),
  StackContentScale.uniform:
      tr('Один множитель на обе оси: макет уменьшаете или увеличиваете целиком, пропорции объектов сохраняются.'),
  StackContentScale.stretch:
      tr('Каждая ось своим множителем: вёрстка заполняет новый холст, но объект сплющится вместе с ним.'),
};

/// Новый слой создаётся боксом 160×44: такой объект видно сразу, и он не
/// выпирает за холст минимальной высоты.
const double kStackNewChildHalfWidth = 80;
const double kStackNewChildHalfHeight = 22;

/// Шаги сетки канваса: 10 — плотная разметка, 40 — «на глаз» крупные блоки.
const List<double> kStackGridSteps = [10, 20, 40];
const double kStackGridStepDefault = 20;

/// Толщина линейки в экранных px: полоса, из которой вытаскивают направляющую
/// и в которую её возвращают, чтобы удалить. Нужна и State'у, и состоянию
/// жеста — поэтому на уровне файла.
const double kStackRulerThickness = 18;

/// Ширина ленты действий AppBar: восемь кнопок по 48 px. Больше неё лента не
/// растягивается, меньше — прокручивается.
const double kStackAppBarActionsWidth = 8 * 48.0;

/// Цвет пользовательской направляющей: красный занят линией прилипания,
/// голубой — рамкой выделения.
const Color kStackGuideColor = Color(0xFFD500F9);

/// край холста и всё, что за него не попадёт в игру: плеер режет стек по
/// границе холста, и без отметки «сюда не доедешь» вёрстка уезжала за край.
/// Янтарь занят не был — ни одна другая служебная разметка его не использует.
const Color kStackCutColor = Color(0xFFFFB300);

/// Курсор ручки ресайза — по направлению, в котором она тянет: ещё до жеста
/// видно, за что цепляешься.
extension StackChildDragModeCursor on StackChildDragMode {
  MouseCursor get resizeCursor => switch (this) {
    StackChildDragMode.resizeLeft ||
    StackChildDragMode.resizeRight => SystemMouseCursors.resizeLeftRight,
    StackChildDragMode.resizeTop ||
    StackChildDragMode.resizeBottom => SystemMouseCursors.resizeUpDown,
    StackChildDragMode.resizeTL ||
    StackChildDragMode.resizeBR => SystemMouseCursors.resizeUpLeftDownRight,
    StackChildDragMode.resizeTR ||
    StackChildDragMode.resizeBL => SystemMouseCursors.resizeUpRightDownLeft,
    StackChildDragMode.move => SystemMouseCursors.move,
  };
}

class StackCanvasScreen extends ConsumerStatefulWidget {
  final ContentItem stackItem;
  final String questId;
  final String nodeId;
  final Future<void> Function(Map<String, dynamic>)? onAutoSave;

  /// Наследие списка-прослойки, который этот экран заменил: переход по
  /// targetNodeId из триггера и флаг «редактируем поверх живой игры».
  final void Function(String targetNodeId)? onJumpToNode;
  final bool fromGameSession;

  /// Часы для склейки шагов истории. В прода — `DateTime.now`, тесты ставят
  /// фиктивное время: иначе серия из двух нажатий стрелки распадается на два
  /// шага undo просто потому, что машине не хватило 700 мс на кадр.
  final DateTime Function()? sessionClock;

  const StackCanvasScreen({
    super.key,
    required this.stackItem,
    required this.questId,
    required this.nodeId,
    this.onAutoSave,
    this.onJumpToNode,
    this.fromGameSession = false,
    this.sessionClock,
  });

  @override
  ConsumerState<StackCanvasScreen> createState() => _StackCanvasScreenState();
}

class _StackCanvasScreenState extends ConsumerState<StackCanvasScreen> {
  // ── Камера ───────────────────────────────────────────────────────
  CameraState _camera = const CameraState();

  // ── Документ: дети, высота, фон, выделение, undo/redo ────────────
  late final StackCanvasSession _session;

  /// Документ последней отправки в автосейв. Сравнение по `identical`:
  /// правки выделения тоже notify'ят сессию, но документ при них тот же.
  ContentItem? _savedStack;

  final Uuid _uuid = const Uuid();
  final FocusNode _focusNode = FocusNode(debugLabel: 'stack_canvas');

  /// Имена ресурсов квеста (`имя файла → имя из metadata`). Подписывают слои
  /// и картинки; пока metadata не прочитана, остаётся имя файла.
  ///
  /// Поле, а не `ref.watch` на месте: шит свойств и панель слоёв строятся
  /// вне build этого экрана, а `watch` там запрещён. Значение обновляется в
  /// [build], поэтому следующая пересборка приносит и имена.
  Map<String, String> _resourceNames = const {};

  ContentItem get _stackItem => _session.stack;
  List<ContentItem> get _children => _session.children;

  /// Высота холста. Во время драга нижнего края она берётся из предпросмотра:
  /// якоря детей пересчитываются сами, и объект, прижатый к низу, остаётся
  /// прижатым — как слой с привязкой в Figma.
  double get _stackHeight => _canvasPreviewHeight ?? _session.stackHeight;

  /// Ширина холста — авторская [`ContentItem.stackWidth`] или дизайн-ширина
  /// по умолчанию. От неё считаются все координаты канваса, снап и
  /// направляющие: ровно так же плеер кладёт детей, а потом ужимает весь
  /// холст до доступной ширины. Во время тяги правого края — из предпросмотра.
  double get _canvasWidth => _canvasPreviewWidth ?? _session.stackWidth;

  /// Скругление картинок стека — та же формула, что в GameStackWidget. Нодной
  /// оверрайд канвасу неизвестен, поэтому дефолт один: скруглять.
  bool? get _roundImages => _stackItem.childImageRoundedCorners;

  /// Дети, доступные канвасу: скрытые слои видны призраками, но не кликаются
  /// и рамкой не ловятся — их адрес — панель слоёв.
  List<ContentItem> get _visibleChildren => [
    for (final c in _children)
      if (!c.isHidden) c,
  ];

  /// Тот же помощник, что у карточки элемента в ноде: открывает полноценный
  /// редактор по типу и вешает триггеры на объект внутри стека.
  late final ContentEditorLogic _logic;

  ItemEditorHelper get _itemHelper => ItemEditorHelper(
    context: context,
    questId: widget.questId,
    nodeId: widget.nodeId,
    logic: _logic,
    getItem: (i) => _children[i],
    updateItem: (i, child) => _replaceChild(i, child),
    onJumpToNode: widget.onJumpToNode,
    fromGameSession: widget.fromGameSession,
    // У айтема плагина нет своего редактора: его поля описаны в манифесте.
    onCustomEditItem: (index, item) async {
      if (item.type != 'plugin') return false;
      final type = findPluginContentType(ref, item.pluginTypeId);
      if (type == null) return true;
      final data = await showPluginContentForm(
        context,
        type: type,
        questId: widget.questId,
        initial: item.pluginData,
      );
      if (data != null) {
        _replaceChild(
          index,
          item.copyWith(
            pluginId: type.pluginId,
            pluginTypeId: type.id,
            pluginData: data,
          ),
        );
      }
      return true;
    },
  );

  void _openChildEditor(int index) {
    if (index < 0 || index >= _children.length) return;
    _itemHelper.editItem(index);
  }

  void _openChildTriggers(int index) {
    if (index < 0 || index >= _children.length) return;
    final child = _children[index];
    _itemHelper.showTriggerOptions(
      index,
      includeTargetNodeId: child.type != 'row' && child.type != 'column',
    );
  }

  /// Пикер картинки из библиотеки квеста. Путь или null, если пользователь
  /// вышел ничего не выбрав — отмена не должна стоить шага истории.
  Future<String?> _pickImageResource() async {
    final res = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    return res?.path;
  }

  void _commitChildImage(String id, String path) {
    _session.commitChild(
      id,
      // Выбор файла руками снимает привязку к формуле: иначе
      // `resolveResourcePath` и дальше отдавал бы значение переменной,
      // и картинка бы не менялась.
      (c) => c.copyWith(resourcePath: path, clearResourceExpr: true),
      kind: StackEditKind.style,
      label: tr('изображение слоя'),
    );
  }

  /// Пикер формулы-источника: `{pic}`, `res/{level}.png`, ячейка таблицы.
  /// Тот же редактор формул, что у блоков скрипта.
  Future<String?> _editResourceExpr({required String current}) async {
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ExpressionEditorScreen(
          initialValue: current,
          questId: widget.questId,
          title: tr('Формула источника'),
          isTemplate: true,
        ),
      ),
    );
  }

  void _commitChildResourceExpr(String id, String? expr) {
    _session.commitChild(
      id,
      (c) => c.copyWith(resourceExpr: expr, clearResourceExpr: expr == null),
      kind: StackEditKind.style,
      label: tr('формула источника слоя'),
    );
  }

  /// Пикер формулы числа (скругление): в отличие от источника картинки это
  /// арифметическое выражение, а не шаблон строк — пикер открывается в
  /// обычном режиме (`isTemplate` по умолчанию false).
  Future<String?> _editNumericExpr({
    required String current,
    required String title,
  }) {
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ExpressionEditorScreen(
          initialValue: current,
          questId: widget.questId,
          title: title,
        ),
      ),
    );
  }

  /// Формула скругления стека (`numericExprs['borderRadius']`) — её читает
  /// `GameStackWidget`, статическое поле `borderRadius` остаётся фоллбэком.
  String get _stackRadiusExpr =>
      _session.stack.numericExpr('borderRadius') ?? '';

  void _commitStackRadiusExpr(String? expr) {
    _session.commit(
      _session.stack.withNumericExpr('borderRadius', expr),
      kind: StackEditKind.style,
      label: tr('формула скругления стека'),
    );
  }

  /// «Сменить изображение» слоя: только ресурс, геометрия и поведение те же.
  Future<void> _replaceLayerImage(String id) async {
    final path = await _pickImageResource();
    if (path == null || !mounted) return;
    _commitChildImage(id, path);
  }

  /// Файл для подписей: «res/images/cat.png» → «cat.png».
  static String? _fileName(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? trimmed : trimmed.substring(slash + 1);
  }

  /// Подпись ресурса для автора: имя из библиотеки квеста, а не имя файла —
  /// загруженные картинки называются `1790024448511_<uuid>.png`, и два
  /// соседних кадра по такому хвосту не отличить.
  String? _resourceLabel(String? path) {
    final file = _fileName(path);
    if (file == null) return null;
    final named = _resourceNames[file]?.trim();
    return (named == null || named.isEmpty) ? file : named;
  }

  // ── Drag child(ren) ──────────────────────────────────────────────
  /// id участников драга: перетаскивание группы тащит всё выделение.
  Set<String> _dragIds = <String>{};
  StackChildDragMode? _dragMode;
  Offset? _dragStartPos;
  Offset? _dragCurrentPos;
  Map<String, Rect> _dragStartRects = const {};

  /// Сдвиг жеста уже с прилипанием — его видит [_displayRect] и его же
  /// получает коммит, чтобы картинка и модель не расходились.
  Offset _dragDelta = Offset.zero;

  /// Жест брошен по Escape. Распознаватель этого не знает и шлёт кадры
  /// дальше: без флага остаток тяги ушёл бы в панораму холста.
  bool _gestureDropped = false;

  /// Держат ли Shift именно в этом жесте: решение принимается на каждом кадре
  /// драга и переиспользуется в коммите, иначе превью и модель разойдутся.
  bool _dragKeepAspect = false;

  /// Тащимые объекты — копии из Alt-драга: тогда итог пишется одним шагом
  /// истории «дубликат», а не двумя («дубликат» + «перемещение»).
  bool _dragIsDuplicate = false;

  /// Сетка канваса: шаг и показ — настройка вида, документ от неё не меняется
  /// и в историю не попадает. Шаг остаётся выбранным, даже когда сетку
  /// выключили: включить её обратно должно быть в один тап.
  bool _gridVisible = false;
  double _gridStep = kStackGridStepDefault;

  /// 0 — прилипания к сетке нет: так сценарии без сетки работают как работали.
  double get _gridSnapStep => _gridVisible ? _gridStep : 0;

  /// Направляющие и линейки: показ — настройка вида, линии живут в документе.
  /// Скрытые, они и прилипать не мешают: полоса линейки иначе легла бы на
  /// объекты у края холста.
  bool _guidesVisible = true;

  /// Показ слоёв за краем холста. Игрок получает ровно то, что попало в
  /// рамку, поэтому по умолчанию редактор режет так же, а вылезший слой
  /// подсказывает пунктиром. Пунктир не заменяет картинку: слой, уехавший за
  /// край целиком, нельзя ни поправить глазом, ни вытащить обратно на ощупь.
  bool _showOutsideCanvas = false;

  /// Что сделать со слоями, когда автор задаёт новый размер холста. По
  /// умолчанию правится только рамка — прежнее поведение: сменить высоту подложки
  /// не значит переделать вёрстку. Масштаб содержимого включается явно, чипами в
  /// шите, и живёт в сессии экрана, а не в документе.
  StackContentScale _contentScaleOnResize = StackContentScale.keep;

  /// Драг направляющей (создание из линейки, перестановка, возврат в линейку).
  _GuideDrag? _guideDrag;

  /// Точка, где палец коснулся канваса. Направляющую выбирают по ней, а не по
  /// [ScaleStartDetails.localFocalPoint]: жест распознаётся спустя сорок
  /// пикселей пути, и к этому моменту focal point уже уехал за линейку.
  Offset? _pointerDownPos;

  /// Старый ограничивающий rect при ресайзе группы: дети масштабируются
  /// аффинно относительно него, а не каждый за свою ручку.
  Rect? _groupStartUnion;
  List<double> _guideX = const [];
  List<double> _guideY = const [];

  /// Зазоры вокруг тащимого объекта — рисуются только на ходу драга.
  List<StackMeasure> _measures = const [];

  // ── Поворот за ручку ─────────────────────────────────────────────
  /// Центр и палец берём в координатах самой ручки: угол не зависит от зума,
  /// а две разные системы координат (окно и Stack) не смешиваются.
  String? _rotateId;
  Offset? _rotateCenter;
  double _rotateStartAngle = 0;
  double _rotateStartValue = 0;
  double? _rotateShownDegrees;

  /// Позиция пальца на down: pan-жест начинается только после слопа, и угол
  /// от стартовой точки жеста дал бы скачок поворота на те самые 18 px.
  Offset? _rotateDownPos;

  // ── Рамка выделения ──────────────────────────────────────────────
  /// По умолчанию фон отдаётся панораме: на телефоне рамка съела бы привычный
  /// жест. Кнопка в AppBar (и Shift/Alt+драг) включают рамку.
  bool _marqueeMode = false;
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;

  /// Держали Alt в момент, когда рамка началась: только для предпросмотра —
  /// итог решается по клавише при отпускании (её могли нажать позже).
  bool _marqueeSubtractive = false;

  // ── Растягивание холста за край ──────────────────────────────────
  /// Высота/ширина жеста: живой предпросмотр, в документ она попадёт одним
  /// коммитом по отпусканию — иначе каждый кадр тяги стоил бы шага истории.
  double? _canvasPreviewHeight;
  double? _canvasDragStartHeight;
  double? _canvasPreviewWidth;
  double? _canvasDragStartWidth;

  /// Накопленный сдвиг пальца и масштаб на старте: жест считает приращение,
  /// а не абсолютную позицию, и не зависит от того, где ухватили край.
  double? _canvasDragDy;
  double? _canvasDragDx;

  /// Экран→мир на старте тяги: в отрисовке холста множителем стоит
  /// `_fittedScale * _camera.scale`, поэтому без зума камеры жест при 50%
  /// ползёт вдвое быстрее пальца.
  double _canvasDragStartScale = 1;

  /// Тот же принцип для коэффициента «вдвое»: пересчёт на каждом кадре
  /// переворачивал его на середине жеста, и накопленная дельта вдруг то
  /// удваивалась, то сбрасывалась — холст прыгал на сотни px.
  bool _canvasDragStartDoubled = false;

  /// Объект под курсором мыши: обводка на канвасе и курсор «перемещение».
  /// Пальцем hover не генерируется, поэтому состояние чисто мышиное. Храним
  /// id, а не rect: после стрелок и undo рамка обязана сесть на актуальное
  /// место, а нового hover-события для этого нет.
  String? _hoverId;

  /// Панель слоёв — правая колонка, отъедающая место у канваса (не оверлей:
  /// иначе она легла бы поверх объектов, которые как раз и хочешь двигать).
  bool _layersOpen = false;

  /// Буфер канваса: копия живёт в экране, а не в сессии — undo/redo не должен
  /// терять то, что пользователь скопировал, и «копировать» не правит документ.
  List<ContentItem> _clipboard = const [];
  int _pasteStagger = 0;

  /// Скопированное оформление: сам слой-источник, из которого берут только
  /// поля вида. Как и [_clipboard], в сессии не живёт — undo не должен терять
  /// буфер.
  ContentItem? _styleSource;

  // ── FittedBox scale/origin (пересчитываются при layout) ──────────
  double _fittedScale = 1.0;
  Offset _fittedOrigin = Offset.zero;

  /// Размер области канваса: пишется из build'а вместе с [_fittedScale] и
  /// нужен клавиатурному зуму — у клавиатуры нет курсора, и центрировать
  /// приходится на вьюпорт.
  Size? _viewportSize;

  @override
  void initState() {
    super.initState();
    _session = StackCanvasSession(
      stack: widget.stackItem,
      clock: widget.sessionClock,
    );
    _session.addListener(_onSessionChanged);
    _savedStack = widget.stackItem;
    _logic = ContentEditorLogic(
      context: context,
      questId: widget.questId,
      currentNodeId: widget.nodeId,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fitStackInView();
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
    final stack = _session.stack;
    if (identical(stack, _savedStack)) return;
    _savedStack = stack;
    widget.onAutoSave?.call({'item': stack});
  }

  /// Слой по id в текущем документе. Нужен шитам свойств: они держат снимок
  /// слоя на момент открытия, а правки (якоря, замки) живут в сессии.
  ContentItem? _childById(String id) {
    for (final c in _children) {
      if (c.id == id) return c;
    }
    return null;
  }

  void _replaceChild(int index, ContentItem child) {
    if (index < 0 || index >= _children.length) return;
    final next = List<ContentItem>.from(_children);
    next[index] = child;
    _commitChildren(next, kind: StackEditKind.style);
  }

  void _commitChildren(
    List<ContentItem> next, {
    required StackEditKind kind,
    String? label,
    bool coalesce = false,
  }) {
    if (_sameChildren(_children, next)) return;
    _session.commit(
      _stackItem.copyWith(children: next),
      kind: kind,
      label: label,
      coalesce: coalesce,
    );
  }

  /// Список тот же по составу и экземплярам → правка ничего не меняла,
  /// в историю такую записывать не за чем.
  bool _sameChildren(List<ContentItem> a, List<ContentItem> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  // ── Конвертация координат ────────────────────────────────────────
  // Экранная точка → позиция внутри стека (0,0 = top-left стека).
  // Учитывает camera (pan/zoom) + FittedBox (scale/origin).
  Offset _screenToStack(Offset screenPos) {
    // 1. Убираем pan/zoom камеры
    final fitted = (screenPos - _camera.offset) / _camera.scale;
    // 2. Убираем FittedBox offset и scale
    return Offset(
      (fitted.dx - _fittedOrigin.dx) / _fittedScale,
      (fitted.dy - _fittedOrigin.dy) / _fittedScale,
    );
  }

  /// Stack-позиция → координаты вьюпорта (без камеры) — тот мир, в котором
  /// живёт [CameraState].
  Offset _stackToWorld(Offset stackPos) => Offset(
    stackPos.dx * _fittedScale + _fittedOrigin.dx,
    stackPos.dy * _fittedScale + _fittedOrigin.dy,
  );

  /// Stack-позиция → координаты вьюпорта (те же, в каком лежат оверлейные
  /// ручки и инфо-бар).
  Offset _stackToScreen(Offset stackPos) =>
      _stackToWorld(stackPos) * _camera.scale + _camera.offset;

  /// Углы бокса ребёнка в координатах оверлея: после масштаба и поворота,
  /// то есть там, где картинка на канвасе, а не там, её модельный rect.
  _BoxAnchors _anchorsOf(ContentItem child) {
    final corners = stackChildVisualCorners(
      _displayRect(child),
      rotation: child.rotation,
      scale: child.scale,
    );
    return _BoxAnchors(
      _stackToScreen(corners[0]),
      _stackToScreen(corners[1]),
      _stackToScreen(corners[2]),
      _stackToScreen(corners[3]),
    );
  }

  /// Точка ручки поворота и центр, вокруг который она крутится. Ручка сидит
  /// над серединой верхнего края картинки и уходит вместе с поворотом: угол
  /// считается от захваченного центра, так что «ручка под пальцем» — это
  /// следствия жеста, а не его вход.
  ({Offset anchor, Offset center}) _rotateAnchorOf(ContentItem child) {
    final anchors = _anchorsOf(child);
    return (
      anchor: anchors.topMid + anchors.up * kStackRotateStem,
      center: anchors.center,
    );
  }

  /// Хит-область ручки поворота: она лежит в том же Stack, что и канвас, и
  /// оба детектора попадают в одну арену. Без явного правила канвас начал бы
  /// перемещение одновременно с поворотом.
  Rect? get _rotateHandleHit {
    if (_session.selection.length != 1) return null;
    final primary = _session.primaryChild;
    if (primary == null) return null;
    return Rect.fromCenter(
      center: _rotateAnchorOf(primary).anchor,
      width: kStackHandleHit,
      height: kStackHandleHit,
    );
  }

  bool _ownsRotateGesture(Offset viewportPos) {
    final hit = _rotateHandleHit;
    return hit != null && hit.contains(viewportPos);
  }

  /// Rect для отображения: во время драга — пересчитанный из жеста
  /// (с прилипанием), иначе — из модели.
  Rect _displayRect(ContentItem child) {
    final start = _dragStartRects[child.id];
    if (start == null || _dragMode == null) {
      return child.stackChildRect(_canvasWidth, _stackHeight);
    }
    final groupStart = _groupStartUnion;
    final group = _groupRect;
    if (groupStart != null && group != null) {
      return scaleRectIntoGroup(start, groupStart, group);
    }
    return resizeStackChildRect(
      start: start,
      mode: _dragMode!,
      delta: _dragDelta,
      rotation: child.rotation,
      scale: child.scale,
      keepAspect: _dragKeepAspect,
    );
  }

  ContentItem? _hitTestChild(Offset screenPos) {
    final stackPos = _screenToStack(screenPos);
    for (int i = _children.length - 1; i >= 0; i--) {
      final child = _children[i];
      // Скрытый и заблокированный слои тапом не берутся: под заблокированным
      // объектом можно выделить тот, что ниже.
      if (child.isHidden || child.locked) continue;
      final rect = child.stackChildRect(_canvasWidth, _stackHeight);
      // Проверка в собственных осях бокса: под поворотом тап попадает по
      // картинке, а не по описанному вокруг неё rect'у с пустыми углами.
      if (stackChildContains(
        stackPos,
        rect,
        rotation: child.rotation,
        scale: child.scale,
      )) {
        return child;
      }
    }
    return null;
  }

  // ── Гесты ────────────────────────────────────────────────────────
  Offset? _lastFocalPoint;
  double _baseScale = 1.0;

  /// Драг (панорама, move, resize, рамка) уже распорядился выделением:
  /// подоспевший тап не должен его перетирать.
  bool _gestureHandledTap = false;

  /// Клик по объекту: Shift — диапазон по z-порядку, Ctrl/Cmd — добавить или
  /// убрать из выделения, иначе — одиночное выделение.
  void _applyClickSelection(ContentItem child) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) {
      _session.selectRange(child.id);
      return;
    }
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      _session.select(child.id, additive: true);
      return;
    }
    if (!_session.isSelected(child.id)) _session.select(child.id);
  }

  /// Прямоугольник рамки в координатах стека, пока жест не закончен.
  Rect? get _marqueeRect {
    final start = _marqueeStart;
    final current = _marqueeCurrent;
    if (start == null || current == null) return null;
    return Rect.fromPoints(start, current);
  }

  /// Бокс объекта под курсором: rect в координатах стека плюс та же пара
  /// трансформаций, что кладёт картинку `paintStackChildBox`. Обводка обязана
  /// облегать нарисованный объект, а не его неповёрнутую модель.
  ({double rotation, double scale, Rect rect})? get _hoverBox {
    final index = _hoverId == null ? null : _session.indexOf(_hoverId!);
    if (index == null) return null;
    final child = _children[index];
    return (
      rect: child.stackChildRect(_canvasWidth, _stackHeight),
      rotation: child.rotation,
      scale: child.scale,
    );
  }

  /// Курсор канваса: тащимый объект и объект под курсором показывают
  /// «перемещение», режим рамки — прицел.
  MouseCursor get _canvasCursor {
    if (_dragIds.isNotEmpty || _hoverBox != null) {
      return SystemMouseCursors.move;
    }
    if (_wantsMarquee) return SystemMouseCursors.precise;
    return SystemMouseCursors.basic;
  }

  void _onCanvasHover(PointerHoverEvent event) {
    // Во время жеста обводка только мешает: пользователь и так видит, что
    // он тащит.
    if (_dragIds.isNotEmpty || _marqueeStart != null || _rotateId != null) {
      _setHover(null);
      return;
    }
    _setHover(_hitTestChild(event.localPosition)?.id);
  }

  void _setHover(String? id) {
    if (id == _hoverId) return;
    setState(() => _hoverId = id);
  }

  // ── Выравнивание и распределение ─────────────────────────────────

  void _align(StackAlign align) {
    final ids = _session.selection;
    if (ids.isEmpty) return;
    _commitChildren(
      alignChildren(
        children: _children,
        ids: ids,
        align: align,
        width: _canvasWidth,
        height: _stackHeight,
      ),
      kind: StackEditKind.align,
      label: tr('выравнивание'),
    );
  }

  void _distribute(bool horizontal) {
    final ids = _session.selection;
    if (ids.length < 3) return;
    _commitChildren(
      distributeChildren(
        children: _children,
        ids: ids,
        horizontal: horizontal,
        width: _canvasWidth,
        height: _stackHeight,
      ),
      kind: StackEditKind.align,
      label: tr('равные промежутки'),
    );
  }

  // ── Свойства объекта ─────────────────────────────────────────────

  /// Инспектор одного объекта: точная геометрия + прозрачность и поворот.
  ///
  /// У каждого ползунка есть поле с тем же числом: поймать пальцем 37 % на
  /// линейке невозможно, а нажать «3» и «7» — можно.
  ///
  /// Поля коммитятся на Enter/потерю фокуса, а не по каждому нажатию цифры:
  /// иначе набор «1», «12», «120» дал бы три записи истории и три автосейва.
  /// Слайдеры, наоборот, пишутся на каждое движение, но с coalesce — серия
  /// остаётся одним шагом undo.
  void _openChildPropsSheet(ContentItem child) {
    final id = child.id;
    final initial = child.stackChildRect(_canvasWidth, _stackHeight);
    final controllers = <StackRectPart, TextEditingController>{
      StackRectPart.x: TextEditingController(text: _num(initial.left)),
      StackRectPart.y: TextEditingController(text: _num(initial.top)),
      StackRectPart.w: TextEditingController(text: _num(initial.width)),
      StackRectPart.h: TextEditingController(text: _num(initial.height)),
    };
    // Потеря фокуса — тоже ввод: пользователь мог уйти в соседнее поле без
    // Enter.
    final focusNodes = <StackRectPart, FocusNode>{};
    for (final part in StackRectPart.values) {
      final controller = controllers[part]!;
      final node = FocusNode(debugLabel: 'stack_rect_${part.name}');
      node.addListener(() {
        if (!node.hasFocus) _commitRectField(id, part, controller);
      });
      focusNodes[part] = node;
    }

    // Живые значения шита: у ползунка, поля и слушателя фокуса должен быть
    // один источник, иначе набранное в поле исчезнет при первом же движении
    // слайдера. Единицы — как в документе; в поля выводим целые проценты и
    // градусы, поэтому стартовое значение округляем тем же правилом: иначе
    // первый уход из нетронутого поля писал бы шаг «0.3333 → 0.33».
    final values = _SheetValues(
      opacity: _pct(child.opacity) / 100.0,
      rotation: child.rotation.round().toDouble(),
      scale: _scalePct(child.scale) / 100.0,
      textSize: (child.textSize ?? 16.0).round().toDouble(),
    );
    // Назначается в билдере: до первой сборки перерисовывать нечего.
    StateSetter? syncSheet;

    // Числовое поле рядом с каждым ползунком: попасть слайдером в 37 % так же
    // трудно, как мышью в 37 % на линейке. Единицы — те же, что в подписи
    // (проценты, градусы, пиксели), в документе прозрачность хранится долей.
    final valueControllers = <String, TextEditingController>{
      'opacity': TextEditingController(text: _num(_pct(child.opacity))),
      'rotation': TextEditingController(text: _num(child.rotation)),
      'scale': TextEditingController(text: _num(_scalePct(child.scale))),
      if (child.type == 'text')
        'textSize': TextEditingController(text: _num(child.textSize ?? 16.0)),
    };
    final valueNodes = <String, FocusNode>{
      for (final field in valueControllers.keys)
        field: FocusNode(debugLabel: 'stack_value_$field'),
    };

    // Толщина обводки — отдельная пара контроллер+фокус: она вне общего
    // числового механизма полей, потому что показывается только при выбранном
    // цвете и пишется не одним числом, а парой с цветом.
    final outlineWidthController = TextEditingController(
      text: _num(child.textOutlineWidth ?? kTextOutlineWidthDefault),
    );
    final outlineWidthNode = FocusNode(
      debugLabel: 'stack_text_outline_width',
    );

    double displayOf(String field, double model) =>
        (field == 'opacity' || field == 'scale') ? model * 100 : model;

    /// Число из поля → значение документа. Целые и те же единицы, что шагает
    /// ползунок: «120» в поле прозрачности должно стать 100 %, а не невидимым
    /// слоем, и в поле после ввода обязано остаться то же, что попало в файл.
    double modelOf(String field, double raw) => switch (field) {
      'opacity' => raw.round().clamp(0, 100) / 100.0,
      'rotation' => raw.round().clamp(-180, 180).toDouble(),
      'scale' =>
        raw.round().clamp(kStackScaleMinPercent, kStackScaleMaxPercent) / 100.0,
      _ => raw.round().clamp(8, 64).toDouble(),
    };

    void writeStyle(String field, double v, {bool coalesce = false}) {
      _session.commitChild(
        id,
        (c) => switch (field) {
          'opacity' => c.copyWith(opacity: v),
          'rotation' => c.copyWith(rotation: v),
          'scale' => c.copyWith(scale: v),
          _ => c.copyWith(textSize: v),
        },
        kind: StackEditKind.style,
        label: switch (field) {
          'opacity' => tr('прозрачность'),
          'rotation' => tr('поворот'),
          'scale' => tr('масштаб'),
          _ => tr('размер шрифта'),
        },
        coalesce: coalesce,
      );
    }

    /// Живой слой: `child` — снимок на момент открытия шита, а обводку правят
    /// из него же, поэтому читать надо документ, не снимок.
    ContentItem liveChild() {
      for (final c in _children) {
        if (c.id == id) return c;
      }
      return child;
    }

    /// Обводка текста. Цвет и толщина — одна пара: без цвета контур не рисуется,
    /// поэтому «убрать» снимает оба поля, а поле толщины показывается только
    /// когда цвет выбран.
    void commitOutline({
      Color? color,
      double? width,
      bool clear = false,
      bool coalesce = false,
    }) {
      final label = clear
          ? tr('обводка убрана')
          : width == null
          ? tr('цвет обводки')
          : tr('толщина обводки');
      // Белый, если цвета ещё не было: ползунок толщины без контура не имеет
      // смысла, а автор, который его двинул, именно контур и хочет получить.
      final nextColor =
          color ??
          liveChild().textOutlineColor ??
          const Color(0xFFFFFFFF);
      _session.commitChild(
        id,
        (c) => clear
            ? c.copyWith(clearTextOutline: true)
            : c.copyWith(
                textOutlineColor: nextColor,
                textOutlineWidth: width,
              ),
        kind: StackEditKind.style,
        label: label,
        coalesce: coalesce,
      );
      syncSheet?.call(() {});
    }

    void applyOutlineWidth(double v) {
      commitOutline(width: v, coalesce: true);
      if (!outlineWidthNode.hasFocus) {
        outlineWidthController.text = _num(v);
      }
    }

    void commitOutlineWidthField() {
      // Закрытие шита снимает фокус — не писать в сессию, уже снятую с экрана.
      if (!mounted) return;
      final current =
          liveChild().textOutlineWidth ?? kTextOutlineWidthDefault;
      final raw = double.tryParse(
        outlineWidthController.text.replaceAll(',', '.'),
      );
      if (raw == null) {
        outlineWidthController.text = _num(current);
        return;
      }
      final v = raw.round().clamp(1, kTextOutlineWidthMax.round()).toDouble();
      outlineWidthController.text = _num(v);
      // То же число, что уже стоит в документе, — не правка: иначе уход из
      // поля после Enter писал в историю второй, пустой на вид шаг.
      if (v == current) return;
      commitOutline(width: v);
    }

    outlineWidthNode.addListener(() {
      if (!outlineWidthNode.hasFocus) commitOutlineWidthField();
    });

    /// Движение ползунка: в документ и в поле. Поле, в котором сейчас печатают,
    /// не перетираем — иначе набор «1», «12» теряет уже набранное.
    void applySlider(String field, double v) {
      values.set(field, v);
      writeStyle(field, v, coalesce: true);
      if (!valueNodes[field]!.hasFocus) {
        valueControllers[field]!.text = _num(displayOf(field, v));
      }
    }

    /// Ввод числа тапом по нему: распарсить, записать в документ, оставить в
    /// поле фактическое значение — округление и clamp без молчаливого отката.
    void applyField(String field) {
      // Закрытие шита снимает фокус — не писать в сессию, уже снятую с экрана.
      if (!mounted) return;
      final controller = valueControllers[field]!;
      final raw = double.tryParse(controller.text.replaceAll(',', '.'));
      if (raw == null) {
        controller.text = _num(displayOf(field, values.get(field)));
        return;
      }
      final v = modelOf(field, raw);
      controller.text = _num(displayOf(field, v));
      // То же число, что уже стоит в документе, — не правка: иначе уход из
      // поля после Enter писал в историю второй, пустой на вид шаг.
      if (v == values.get(field)) return;
      values.set(field, v);
      writeStyle(field, v);
      syncSheet?.call(() {});
    }

    for (final field in valueControllers.keys) {
      final node = valueNodes[field]!;
      node.addListener(() {
        if (!node.hasFocus) applyField(field);
      });
    }

    showEditorSheet<void>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        // Картинка слоя: подпись обновляем на месте, иначе после «сменить»
        // шит показывал бы старый файл (child — снимок на момент открытия).
        String? image = child.resourcePath;
        String expr = child.resourceExpr ?? '';
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            syncSheet = setSheetState;
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trf('{p0} · свойства', {'p0': _typeLabel(child.type)}),
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      trf('Геометрия в пикселях канваса ({p0} × {p1}) от левого верхнего угла стека.', {'p0': _canvasWidth.round(), 'p1': _stackHeight.round()}),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _numField(
                            scheme,
                            label: 'X',
                            part: StackRectPart.x,
                            id: id,
                            controller: controllers[StackRectPart.x]!,
                            focusNode: focusNodes[StackRectPart.x]!,
                            sync: setSheetState,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _numField(
                            scheme,
                            label: 'Y',
                            part: StackRectPart.y,
                            id: id,
                            controller: controllers[StackRectPart.y]!,
                            focusNode: focusNodes[StackRectPart.y]!,
                            sync: setSheetState,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: _numField(
                            scheme,
                            label: tr('Ширина'),
                            part: StackRectPart.w,
                            id: id,
                            controller: controllers[StackRectPart.w]!,
                            focusNode: focusNodes[StackRectPart.w]!,
                            sync: setSheetState,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _numField(
                            scheme,
                            label: tr('Высота'),
                            part: StackRectPart.h,
                            id: id,
                            controller: controllers[StackRectPart.h]!,
                            focusNode: focusNodes[StackRectPart.h]!,
                            sync: setSheetState,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Якоря решают, что слой делает при изменении холста. На
                    // канвасе их раньше не было вовсе: «прижать к нижнему
                    // краю» приходилось угадывать перетаскиванием.
                    Text(
                      tr('Поведение при ресайзе холста'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    StackAnchorPresetGrid(
                      selected: stackAnchorPresetOf(_childById(id) ?? child),
                      onSelected: (anchors) {
                        _session.commitChild(
                          id,
                          (c) => applyStackAnchorPreset(
                            c,
                            anchors: anchors,
                            width: _canvasWidth,
                            height: _stackHeight,
                          ),
                          kind: StackEditKind.resize,
                          label: tr('якоря слоя'),
                        );
                        setSheetState(() {});
                      },
                    ),
                    const SizedBox(height: 12),
                    if (child.type == 'image') ...[
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tr('Изображение'),
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  // Без ellipsis: пока у файла нет имени из
                                  // библиотеки, остаётся uuid-хвост, и с
                                  // обрезанным хвостом кадр не отличить от
                                  // соседнего.
                                  _resourceLabel(image) ?? tr('не выбрано'),
                                  style: TextStyle(color: scheme.onSurface),
                                ),
                              ],
                            ),
                          ),
                          TextButton.icon(
                            icon: const Icon(
                              Icons.swap_horiz_rounded,
                              size: 18,
                            ),
                            label: Text(tr('Сменить')),
                            onPressed: () async {
                              final path = await _pickImageResource();
                              if (path == null) return;
                              _commitChildImage(id, path);
                              if (ctx.mounted) {
                                setSheetState(() => image = path);
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Источник слоя может считать формула: скрипт меняет
                      // картинку одним присваиванием, без второго слоя.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tr('Формула источника'),
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  expr.isEmpty
                                      ? tr('не задана — показываем файл выше')
                                      : expr,
                                  style: TextStyle(color: scheme.onSurface),
                                ),
                              ],
                            ),
                          ),
                          if (expr.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.link_off, size: 18),
                              tooltip: tr('Снять'),
                              onPressed: () {
                                _commitChildResourceExpr(id, null);
                                if (ctx.mounted) setSheetState(() => expr = '');
                              },
                            ),
                          TextButton.icon(
                            icon: const Icon(Icons.functions, size: 18),
                            label: Text(tr('Формула')),
                            onPressed: () async {
                              final edited = await _editResourceExpr(
                                current: expr,
                              );
                              // null — отмена, пустая строка — формула снята.
                              if (edited == null) return;
                              _commitChildResourceExpr(
                                id,
                                edited.isEmpty ? null : edited,
                              );
                              if (ctx.mounted) {
                                setSheetState(() => expr = edited);
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: values.opacity.clamp(0.0, 1.0),
                            min: 0,
                            max: 1,
                            divisions: 100,
                            onChanged: (v) =>
                                setSheetState(() => applySlider('opacity', v)),
                          ),
                        ),
                        SizedBox(
                          width: 116,
                          child: _labeledNumField(
                            scheme,
                            label: tr('Прозрачность, %'),
                            controller: valueControllers['opacity']!,
                            focusNode: valueNodes['opacity']!,
                            onCommit: () => applyField('opacity'),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: values.rotation.clamp(-180.0, 180.0),
                            min: -180,
                            max: 180,
                            divisions: 360,
                            onChanged: (v) =>
                                setSheetState(() => applySlider('rotation', v)),
                          ),
                        ),
                        SizedBox(
                          width: 116,
                          child: _labeledNumField(
                            scheme,
                            label: tr('Поворот, °'),
                            controller: valueControllers['rotation']!,
                            focusNode: valueNodes['rotation']!,
                            onCommit: () => applyField('rotation'),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      tr('Поворот вокруг центра бокса и только на отрисовку: рамка, хит-тест и выравнивание считают объект ось-выровненным.'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: values.scale.clamp(
                              kStackScaleMinPercent / 100.0,
                              kStackScaleMaxPercent / 100.0,
                            ),
                            min: kStackScaleMinPercent / 100.0,
                            max: kStackScaleMaxPercent / 100.0,
                            divisions:
                                kStackScaleMaxPercent - kStackScaleMinPercent,
                            onChanged: (v) =>
                                setSheetState(() => applySlider('scale', v)),
                          ),
                        ),
                        SizedBox(
                          width: 116,
                          child: _labeledNumField(
                            scheme,
                            label: tr('Масштаб, %'),
                            controller: valueControllers['scale']!,
                            focusNode: valueNodes['scale']!,
                            onCommit: () => applyField('scale'),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      tr('Масштаб вокруг центра бокса. Нужен кнопке и тексту: они рисуются своим размером, и рамка их не растягивает. Картинка растянется рамкой, а масштаб добавит сверху.'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    // Только у текста: движок рисует остальное не шрифтом.
                    if (child.type == 'text') ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: values.textSize.clamp(8.0, 64.0),
                              min: 8,
                              max: 64,
                              divisions: 56,
                              onChanged: (v) => setSheetState(
                                () => applySlider('textSize', v),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 116,
                            child: _labeledNumField(
                              scheme,
                              label: tr('Размер, px'),
                              controller: valueControllers['textSize']!,
                              focusNode: valueNodes['textSize']!,
                              onCommit: () => applyField('textSize'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              tr('Обводка'),
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (liveChild().textOutlineColor != null)
                            TextButton(
                              key: const ValueKey('stack_outline_clear'),
                              onPressed: () => commitOutline(clear: true),
                              child: Text(tr('убрать')),
                            ),
                          InkWell(
                            key: const ValueKey('stack_outline_swatch'),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () async {
                              final picked = await showColorPickerDialog(
                                context: ctx,
                                initialColor: liveChild().textOutlineColor,
                              );
                              if (picked == null || !mounted) return;
                              commitOutline(color: picked);
                            },
                            child: Container(
                              width: 44,
                              height: 32,
                              decoration: BoxDecoration(
                                color:
                                    liveChild().textOutlineColor ??
                                    Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: scheme.outline),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (liveChild().textOutlineColor != null)
                        Row(
                          children: [
                            Expanded(
                              child: Slider(
                                value:
                                    (liveChild().textOutlineWidth ??
                                            kTextOutlineWidthDefault)
                                        .clamp(1.0, kTextOutlineWidthMax),
                                min: 1,
                                max: kTextOutlineWidthMax,
                                divisions: kTextOutlineWidthMax.round() - 1,
                                onChanged: (v) =>
                                    setSheetState(() => applyOutlineWidth(v)),
                              ),
                            ),
                            SizedBox(
                              width: 116,
                              child: _labeledNumField(
                                scheme,
                                label: tr('Толщина, px'),
                                controller: outlineWidthController,
                                focusNode: outlineWidthNode,
                                onCommit: commitOutlineWidthField,
                              ),
                            ),
                          ],
                        ),
                      Text(
                        tr('Контур рисуется под буквами: цвет текста и теги [color=#…] остаются как были, обводка видна только по краям глифов.'),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      for (final c in controllers.values) {
        c.dispose();
      }
      for (final n in focusNodes.values) {
        n.dispose();
      }
      for (final c in valueControllers.values) {
        c.dispose();
      }
      for (final n in valueNodes.values) {
        n.dispose();
      }
      outlineWidthController.dispose();
      outlineWidthNode.dispose();
    });
  }

  static String _num(double v) => v.round().toString();

  /// Прозрачность в документе — доля, а показываются и вводятся целые
  /// проценты: шаг квантования один для поля, ползунка и значения в файле.
  static double _pct(double v) =>
      (v * 100).round().toDouble().clamp(0.0, 100.0);

  /// Масштаб в тех же целых процентах, что и поле: `_pct` для него не годится,
  /// потому что жмёт верх до 100 %, а слой увеличивают и до 400 %.
  static double _scalePct(double v) => (v * 100).round().toDouble().clamp(
    kStackScaleMinPercent.toDouble(),
    kStackScaleMaxPercent.toDouble(),
  );

  /// Ввод одного поля инспектора: распарсить, записать в документ, вернуть в
  /// поле фактическое значение (округление и clamp без молчаливого отката).
  void _commitRectField(
    String id,
    StackRectPart part,
    TextEditingController controller,
  ) {
    // Закрытие шита снимает фокус — не писать в сессию, уже снятую с экрана.
    if (!mounted) return;
    final value = double.tryParse(controller.text.replaceAll(',', '.'));
    if (value != null) _commitRectPart(id, part, value);
    _syncRectField(id, part, controller);
  }

  Widget _numField(
    ColorScheme scheme, {
    required String label,
    required StackRectPart part,
    required String id,
    required TextEditingController controller,
    required FocusNode focusNode,
    required StateSetter sync,
  }) {
    return _labeledNumField(
      scheme,
      label: label,
      controller: controller,
      focusNode: focusNode,
      onCommit: () {
        _commitRectField(id, part, controller);
        sync(() {});
      },
    );
  }

  /// Числовое поле с подписью: коммит по Enter и по потере фокуса. Значение
  /// всегда перечитывается из контроллера — источник правды один, и после
  /// clamp в поле оказывается то, что реально попало в документ.
  Widget _labeledNumField(
    ColorScheme scheme, {
    required String label,
    required TextEditingController controller,
    required FocusNode focusNode,
    required VoidCallback onCommit,
  }) {
    return SizedBox(
      height: 56,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        textAlign: TextAlign.end,
        keyboardType: const TextInputType.numberWithOptions(
          signed: true,
          decimal: true,
        ),
        textInputAction: TextInputAction.done,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]')),
        ],
        style: TextStyle(color: scheme.onSurface, fontSize: 14),
        onSubmitted: (_) => onCommit(),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: scheme.primary),
          ),
        ),
      ),
    );
  }

  /// Одно поле правит соответствующую сторону rect'а; якоря не трогаем —
  /// stackChildWithRect сам пересчитает offset'ы.
  void _commitRectPart(String id, StackRectPart part, double value) {
    final index = _session.indexOf(id);
    if (index == null) return;
    final child = _session.children[index];
    final rect = child.stackChildRect(_canvasWidth, _stackHeight);
    final v = part == StackRectPart.w || part == StackRectPart.h
        ? value.clamp(8.0, 8000.0)
        : value.clamp(-8000.0, 8000.0);
    final next = switch (part) {
      StackRectPart.x => Rect.fromLTWH(v, rect.top, rect.width, rect.height),
      StackRectPart.y => Rect.fromLTWH(rect.left, v, rect.width, rect.height),
      StackRectPart.w => Rect.fromLTWH(rect.left, rect.top, v, rect.height),
      StackRectPart.h => Rect.fromLTWH(rect.left, rect.top, rect.width, v),
    };
    final moved = part == StackRectPart.x || part == StackRectPart.y;
    // Тот же rect — не правка: без проверки уход из поля после Enter писал в
    // историю второй, пустой на вид шаг.
    if (next == rect) return;
    _session.commitChild(
      id,
      (c) => c.stackChildWithRect(next, _canvasWidth, _stackHeight),
      kind: moved ? StackEditKind.move : StackEditKind.resize,
      label: moved ? tr('координаты') : tr('размер'),
    );
  }

  /// Показать после коммита настоящее значение: поле «120.4» округлится до
  /// 120, а залезший за clamp размер — до фактического.
  void _syncRectField(
    String id,
    StackRectPart part,
    TextEditingController controller,
  ) {
    final index = _session.indexOf(id);
    if (index == null) return;
    final rect = _session.children[index].stackChildRect(
      _canvasWidth,
      _stackHeight,
    );
    controller.text = _num(switch (part) {
      StackRectPart.x => rect.left,
      StackRectPart.y => rect.top,
      StackRectPart.w => rect.width,
      StackRectPart.h => rect.height,
    });
  }

  // ── Свойства стека ───────────────────────────────────────────────

  /// Документные свойства: ширина и высота холста, скругление и фон.
  /// Правятся прямо на канвасе, чтобы не уходить из визуальной вёрстки.
  void _openStackPropsSheet() {
    final widthCtl = TextEditingController(text: _num(_canvasWidth));
    final heightCtl = TextEditingController(text: _num(_stackHeight));
    final radiusCtl = TextEditingController(
      text: _stackItem.borderRadius == null
          ? ''
          : _num(_stackItem.borderRadius!),
    );
    final widthFocus = FocusNode(debugLabel: 'stack_width');
    final heightFocus = FocusNode(debugLabel: 'stack_height');
    final radiusFocus = FocusNode(debugLabel: 'stack_radius');

    void commitWidth() {
      // Потеря фокуса при закрытии шита тоже приходит сюда — после unmount
      // писать в сессию уже нельзя.
      if (!mounted) return;
      final v = double.tryParse(widthCtl.text.replaceAll(',', '.'));
      if (v != null) {
        _session.setStackWidth(v, scaleContent: _contentScaleOnResize);
      }
      widthCtl.text = _num(_session.stackWidth);
    }

    void commitHeight() {
      // Потеря фокуса при закрытии шита тоже приходит сюда — после unmount
      // писать в сессию уже нельзя.
      if (!mounted) return;
      final v = double.tryParse(heightCtl.text.replaceAll(',', '.'));
      if (v != null) {
        _session.setStackHeight(v, scaleContent: _contentScaleOnResize);
      }
      heightCtl.text = _num(_session.stackHeight);
    }

    void commitRadius() {
      if (!mounted) return;
      final raw = double.tryParse(radiusCtl.text.replaceAll(',', '.'));
      final current = _session.stack.borderRadius;
      final stack = _session.stack;
      if (raw == null) {
        if (current != null) {
          _session.commit(
            stack.copyWith(clearBorderRadius: true),
            kind: StackEditKind.style,
            label: tr('скругление стека'),
          );
        }
      } else if (raw.round() != (current ?? 0).round()) {
        _session.commit(
          stack.copyWith(borderRadius: raw.clamp(0.0, 200.0)),
          kind: StackEditKind.style,
          label: tr('скругление стека'),
        );
      }
      radiusCtl.text = _session.stack.borderRadius == null
          ? ''
          : _num(_session.stack.borderRadius!);
    }

    // Слушатели заводятся один раз на открытие шита: внутри builder они бы
    // копировались на каждую перерисовку и коммитили по нескольку раз.
    widthFocus.addListener(() {
      if (!widthFocus.hasFocus) commitWidth();
    });
    heightFocus.addListener(() {
      if (!heightFocus.hasFocus) commitHeight();
    });
    radiusFocus.addListener(() {
      if (!radiusFocus.hasFocus) commitRadius();
    });

    showEditorSheet<void>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return StatefulBuilder(
          builder: (ctx, setSheetState) => SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Стек · холст и фон'),
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    tr('Размеры — в пикселях холста, а не экрана: на узком телефоне стек ужимается целиком, пропорции сохраняются. Слои при новом размере можно пересчитать или оставить как лежали — выбор ниже.'),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Справка и примеры рамок: без неё половина параметров
                  // читается как набор цифр, а «Ш/В» в 761 пугает больше, чем
                  // объясняет.
                  StackHelpPanel(
                    stack: _session.stack,
                    viewport: StackPinBoxEditor.viewportOf(ctx),
                    onApply: (next) {
                      _session.commit(
                        next,
                        kind: StackEditKind.style,
                        label: tr('пример рамки'),
                      );
                      setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: _labeledNumField(
                          scheme,
                          label: tr('Ширина холста'),
                          controller: widthCtl,
                          focusNode: widthFocus,
                          onCommit: commitWidth,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _labeledNumField(
                          scheme,
                          label: tr('Высота холста'),
                          controller: heightCtl,
                          focusNode: heightFocus,
                          onCommit: commitHeight,
                        ),
                      ),
                    ],
                  ),
                  // Один и тот же запрос «сделай 400» значит либо «подогнать
                  // рамку», либо «уменьшить макет». Угадывать нечем — выбирает
                  // автор, выбор живёт в этой сессии редактора.
                  Text(
                    tr('Слои при новом размере'),
                    style: TextStyle(color: scheme.onSurface, fontSize: 14),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final mode in StackContentScale.values)
                        ChoiceChip(
                          key: ValueKey('sheet_content_scale_${mode.name}'),
                          label: Text(kStackContentScaleLabels[mode]!),
                          selected: _contentScaleOnResize == mode,
                          onSelected: (_) {
                            setState(() => _contentScaleOnResize = mode);
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                  Text(
                    kStackContentScaleHints[_contentScaleOnResize]!,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: _labeledNumField(
                          scheme,
                          label: tr('Скругление'),
                          controller: radiusCtl,
                          focusNode: radiusFocus,
                          onCommit: commitRadius,
                        ),
                      ),
                    ],
                  ),
                  // Число выше остаётся запасным значением и превью: в игре
                  // скругление может считать движок.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _stackRadiusExpr.isEmpty
                              ? tr('Формула скругления: не задана — используем число выше')
                              : trf('Формула скругления: {_stackRadiusExpr}', {'_stackRadiusExpr': _stackRadiusExpr}),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      if (_stackRadiusExpr.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: tr('Снять формулу'),
                          onPressed: () {
                            _commitStackRadiusExpr(null);
                            setSheetState(() {});
                          },
                        ),
                      TextButton.icon(
                        icon: const Icon(Icons.functions, size: 18),
                        label: Text(tr('Формула')),
                        onPressed: () async {
                          final edited = await _editNumericExpr(
                            current: _stackRadiusExpr,
                            title: tr('Формула скругления'),
                          );
                          // null — отмена, пустая строка — формула снята.
                          if (edited == null || !mounted) return;
                          _commitStackRadiusExpr(
                            edited.isEmpty ? null : edited,
                          );
                          setSheetState(() {});
                        },
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('Фон стека'),
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (_session.stack.backgroundColor != null)
                        TextButton(
                          onPressed: () {
                            _session.commit(
                              _session.stack.copyWith(
                                clearBackgroundColor: true,
                              ),
                              kind: StackEditKind.style,
                              label: tr('фон стека'),
                            );
                            setSheetState(() {});
                          },
                          child: Text(tr('убрать')),
                        ),
                      InkWell(
                        onTap: () async {
                          final picked = await showColorPickerDialog(
                            context: ctx,
                            initialColor: _session.stack.backgroundColor,
                          );
                          if (picked == null || !mounted) return;
                          _session.commit(
                            _session.stack.copyWith(backgroundColor: picked),
                            kind: StackEditKind.style,
                            label: tr('фон стека'),
                          );
                          setSheetState(() {});
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 44,
                          height: 32,
                          decoration: BoxDecoration(
                            color:
                                _session.stack.backgroundColor ??
                                Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: scheme.outline),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Картинка-фон: фото за слоями или текстура-мозаика. Цвет
                  // выше остаётся подложкой — у «вписать» и «мозаика» всегда
                  // есть незакрытые места.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('Фон картинкой'),
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (_session.stack.hasStackBackgroundImage)
                        TextButton(
                          onPressed: () {
                            _session.commit(
                              _session.stack.copyWith(
                                clearStackBackground: true,
                              ),
                              kind: StackEditKind.style,
                              label: tr('фон стека'),
                            );
                            setSheetState(() {});
                          },
                          child: Text(tr('убрать')),
                        ),
                      TextButton.icon(
                        key: const ValueKey('stack_background_pick'),
                        onPressed: () async {
                          final path = await _pickImageResource();
                          if (path == null || !mounted) return;
                          _session.commit(
                            _session.stack.copyWith(stackBackgroundPath: path),
                            kind: StackEditKind.style,
                            label: tr('фон стека'),
                          );
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.image_rounded, size: 18),
                        label: Text(
                          _session.stack.hasStackBackgroundImage
                              ? tr('сменить')
                              : tr('выбрать'),
                        ),
                      ),
                    ],
                  ),
                  if (_session.stack.hasStackBackgroundImage) ...[
                    Text(
                      _resourceLabel(_session.stack.stackBackgroundPath) ??
                          _session.stack.stackBackgroundPath!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final fit in kStackBackgroundFitValues)
                          ChoiceChip(
                            key: ValueKey('stack_background_fit_$fit'),
                            label: Text(stackBackgroundFitLabels[fit] ?? fit),
                            selected: _session.stack.stackBackgroundFit == fit,
                            onSelected: (_) {
                              _session.commit(
                                _session.stack.copyWith(
                                  stackBackgroundFit: fit,
                                ),
                                kind: StackEditKind.style,
                                label: tr('фон стека'),
                              );
                              setSheetState(() {});
                            },
                          ),
                      ],
                    ),
                    Text(
                      tr('«Мозаика» повторяет картинку в её пикселях — режим для текстур и паттернов.'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // Закрепление: стек уходит из потока контента в слой над
                  // прокруткой ноды — фиксированная панель или окно.
                  Text(
                    tr('Позиция на экране'),
                    style: TextStyle(color: scheme.onSurface, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  StackPinSelector(
                    value: _session.stack.stackPin,
                    onChanged: (pin) {
                      final current = _session.stack.stackPin;
                      if (pin == current) return;
                      // Пресет — это про якоря ярлыка, поэтому авторскую рамку
                      // при смене края надо снести: иначе панель осталась бы
                      // там, где её поставил редактор рамки, а не у края.
                      // Снятие пина рамку трогать не должно: случайное «в
                      // поток» не стоит как потеря раскладки окна.
                      final next = pin == null
                          ? _session.stack.copyWith(clearStackPin: true)
                          : _session.stack.copyWith(
                              stackPin: pin,
                              clearStackPinBox: pin != 'custom',
                            );
                      _session.commit(
                        next,
                        kind: StackEditKind.style,
                        label: tr('закрепление стека'),
                      );
                      setSheetState(() {});
                    },
                  ),
                  Text(
                    _session.stack.stackPin == null
                        ? tr('Скроллится вместе с контентом ноды.')
                        : trf('Закреплён поверх прокрутки: {p0}.', {'p0': StackPinSelector.label(_session.stack.stackPin)}),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  if (_session.stack.stackPin != null) ...[
                    const SizedBox(height: 8),
                    StackPinBoxEditor(
                      stack: _session.stack,
                      viewport: StackPinBoxEditor.viewportOf(ctx),
                      onChanged: (next) {
                        _session.commit(
                          next,
                          kind: StackEditKind.style,
                          label: tr('рамка закрепления'),
                        );
                        setSheetState(() {});
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const ValueKey('sheet_round_images_switch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _session.stack.childImageRoundedCorners ?? true,
                    onChanged: (v) {
                      _session.commit(
                        _session.stack.copyWith(childImageRoundedCorners: v),
                        kind: StackEditKind.style,
                        label: tr('скругление картинок'),
                      );
                      setSheetState(() {});
                    },
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tr('Скруглять картинки'),
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (_session.stack.childImageRoundedCorners != null)
                          TextButton(
                            onPressed: () {
                              _session.commit(
                                _session.stack.copyWith(
                                  clearChildImageRoundedCorners: true,
                                ),
                                kind: StackEditKind.style,
                                label: tr('скругление картинок'),
                              );
                              setSheetState(() {});
                            },
                            child: Text(tr('как у ноды')),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      tr('Отдельно про картинки внутри стека; ряды и колонки настраиваются так же'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    key: const ValueKey('sheet_grid_switch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _gridVisible,
                    onChanged: (v) {
                      setState(() => _gridVisible = v);
                      setSheetState(() {});
                    },
                    title: Text(
                      tr('Сетка'),
                      style: TextStyle(color: scheme.onSurface, fontSize: 14),
                    ),
                    subtitle: Text(
                      tr('Объекты прилипают к линиям сетки'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (_gridVisible)
                    Row(
                      children: [
                        for (final step in kStackGridSteps)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text('${step.round()} px'),
                              selected: _gridStep == step,
                              onSelected: (_) {
                                setState(() => _gridStep = step);
                                setSheetState(() {});
                              },
                            ),
                          ),
                      ],
                    ),
                  SwitchListTile(
                    key: const ValueKey('sheet_guides_switch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _guidesVisible,
                    onChanged: (v) {
                      setState(() => _guidesVisible = v);
                      setSheetState(() {});
                    },
                    title: Text(
                      tr('Направляющие'),
                      style: TextStyle(color: scheme.onSurface, fontSize: 14),
                    ),
                    subtitle: Text(
                      tr('Линейки по краям холста; линию тянуть из линейки, обратно в неё — удалить'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    key: const ValueKey('sheet_outside_switch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _showOutsideCanvas,
                    onChanged: (v) {
                      setState(() => _showOutsideCanvas = v);
                      setSheetState(() {});
                    },
                    title: Text(
                      tr('Слои за краем холста'),
                      style: TextStyle(color: scheme.onSurface, fontSize: 14),
                    ),
                    subtitle: Text(
                      tr('Игроку видно только то, что внутри рамки. С выключенным показом вылезший слой — пунктир, с включённым — та же картинка снаружи холста'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ).whenComplete(() {
      widthCtl.dispose();
      heightCtl.dispose();
      radiusCtl.dispose();
      widthFocus.dispose();
      heightFocus.dispose();
      radiusFocus.dispose();
    });
  }

  void _startDrag(
    ContentItem child,
    Offset startStackPos,
    StackChildDragMode mode, {
    bool duplicate = false,
  }) {
    if (mode == StackChildDragMode.move) {
      _applyClickSelection(child);
    } else {
      _session.select(child.id);
    }
    // Alt+драг: копии создаются до жеста и забирают выделение — жест ведёт
    // копии, оригиналы стоят на месте.
    final copies = duplicate && mode == StackChildDragMode.move
        ? _session.beginDuplicateDrag(idFactory: _newChildId)
        : const <String>[];
    // Тащим всё выделение целиком — иначе группа разъезжается.
    final ids = copies.isNotEmpty
        ? copies.toSet()
        : _session.isSelected(child.id)
        ? _session.selection
        : <String>{child.id};
    setState(() {
      _dragIds = ids;
      _dragMode = mode;
      _dragIsDuplicate = copies.isNotEmpty;
      _dragStartRects = {
        for (final c in _children)
          if (ids.contains(c.id))
            c.id: c.stackChildRect(_canvasWidth, _stackHeight),
      };
      _dragStartPos = startStackPos;
      _dragCurrentPos = startStackPos;
      _dragDelta = Offset.zero;
      _dragKeepAspect = false;
      _groupStartUnion = null;
      _guideX = const [];
      _guideY = const [];
      _measures = const [];
    });
  }

  /// Ресайз группы за ручку ограничивающего rect'а: выделение не меняется
  /// (в отличие от одиночного ребёнка), а дети масштабируются все сразу.
  void _startGroupResize(Offset startStackPos, StackChildDragMode mode) {
    final ids = _session.selection;
    if (ids.isEmpty) return;
    final union = unionOfChildren(
      children: [
        for (final c in _children)
          if (ids.contains(c.id)) c,
      ],
      width: _canvasWidth,
      height: _stackHeight,
    );
    if (union == null) return;
    setState(() {
      _dragIds = Set.of(ids);
      _dragMode = mode;
      _dragIsDuplicate = false;
      _groupStartUnion = union;
      _dragStartRects = {
        for (final c in _children)
          if (ids.contains(c.id))
            c.id: c.stackChildRect(_canvasWidth, _stackHeight),
      };
      _dragStartPos = startStackPos;
      _dragCurrentPos = startStackPos;
      _dragDelta = Offset.zero;
      _dragKeepAspect = false;
      _guideX = const [];
      _guideY = const [];
      _measures = const [];
    });
  }

  /// Ограничивающий rect группы в этом кадре драга: он же идёт в коммит,
  /// поэтому превью и модель не расходятся.
  Rect? get _groupRect =>
      _groupStartUnion == null ? null : _previewRect(_dragDelta);

  /// Rect тащимого объекта (или группы) при дельте [delta]. Одна функция на
  /// отрисовку, прилипание и коммит — иначе картинка и документ расходятся.
  Rect? _previewRect(Offset delta) {
    final mode = _dragMode;
    if (mode == null || _dragIds.isEmpty) return null;
    final groupStart = _groupStartUnion;
    final start =
        groupStart ??
        (mode == StackChildDragMode.move
            ? null
            : _dragStartRects[_dragIds.first]);
    if (start == null) return null;
    if (groupStart == null) {
      // Одиночный объект: тот же путь, что и у коммита, чтобы картинка и
      // документ не разошлись на повороте.
      final child = _childById(_dragIds.first);
      return resizeStackChildRect(
        start: start,
        mode: mode,
        delta: delta,
        rotation: child?.rotation ?? 0,
        scale: child?.scale ?? 1,
        keepAspect: _dragKeepAspect,
      );
    }
    final rect = applyStackChildDrag(
      start,
      mode,
      delta,
      keepAspect: _dragKeepAspect,
    );
    // Только пол по размеру — как у одиночного объекта: группа не должна
    // схлопнуться в линию. Верхней планки нет: холст это окно, а не стена,
    // и авторский фон из больших спрайтов заведомо шире 720 px.
    return Rect.fromLTWH(
      rect.left,
      rect.top,
      rect.width.clamp(kStackChildMinWidth, double.infinity),
      rect.height.clamp(kStackChildMinHeight, double.infinity),
    );
  }

  /// Порог прилипания в пикселях стека: на экране он должен выглядеть
  /// одинаково и при 25%, и при 400% зума.
  double get _snapThreshold {
    final zoom = _fittedScale * _camera.scale;
    if (zoom <= 0 || !zoom.isFinite) return kStackSnapThreshold;
    return kStackSnapThreshold / zoom;
  }

  /// Пересчитать сдвиг жеста: для move и ресайза — с прилипанием к соседям,
  /// при Shift-ресайзе прилипания нет (правка сломала бы честные пропорции).
  void _updateDragDelta() {
    final start = _dragStartPos;
    final current = _dragCurrentPos;
    if (start == null || current == null) return;
    final raw = current - start;
    _dragKeepAspect =
        _dragMode?.isCorner == true && HardwareKeyboard.instance.isShiftPressed;
    if (_dragMode == StackChildDragMode.move) {
      final union = unionOfChildren(
        children: [
          for (final c in _children)
            if (_dragIds.contains(c.id)) c,
        ],
        width: _canvasWidth,
        height: _stackHeight,
      );
      if (union == null) {
        _dragDelta = raw;
        return;
      }
      final others = otherRects(
        children: _children,
        excludeIds: _dragIds,
        width: _canvasWidth,
        height: _stackHeight,
      );
      // Ctrl на ходу: объект идёт строго под палец — ни соседей, ни сетки,
      // ни направляющих, ни рамки холста.
      final snap = HardwareKeyboard.instance.isControlPressed
          ? StackSnap(delta: raw)
          : snapDrag(
              moving: union,
              desired: raw,
              others: others,
              canvasWidth: _canvasWidth,
              canvasHeight: _stackHeight,
              threshold: _snapThreshold,
              gridStep: _gridSnapStep,
              guidesX: _snapGuidesX,
              guidesY: _snapGuidesY,
            );
      final lockAxis = HardwareKeyboard.instance.isShiftPressed;
      final delta = constrainToAxis(snap.delta, locked: lockAxis);
      // Поперёк оси блокировки подсказок не показываем: рисовать прилипание,
      // которое только что вырезали, — значит врать про итог жеста.
      final alongX = !lockAxis ? null : delta.dx.abs() >= delta.dy.abs();
      _dragDelta = delta;
      _guideX = alongX == false ? const [] : snap.verticalGuides;
      _guideY = alongX == true ? const [] : snap.horizontalGuides;
      // Зазоры — уже после прилипания: иначе подпись обещает один pixel, а
      // объект встаёт в другой.
      _measures = [
        for (final m in measureDrag(
          moving: union.shift(delta),
          others: others,
          canvasWidth: _canvasWidth,
          canvasHeight: _stackHeight,
        ))
          if (alongX == null || m.horizontal == alongX) m,
      ];
      return;
    }
    // Ресайз: к соседям липнут свободные края. При Shift пропорции честные,
    // а поправка их бы сломала, поэтому прилипания там нет.
    final preview = _previewRect(raw);
    final mode = _dragMode;
    if (preview == null || mode == null) {
      _dragDelta = raw;
      _guideX = const [];
      _guideY = const [];
      _measures = const [];
      return;
    }
    final others = otherRects(
      children: _children,
      excludeIds: _dragIds,
      width: _canvasWidth,
      height: _stackHeight,
    );
    final snap = _dragKeepAspect
        ? const StackSnap(delta: Offset.zero)
        : snapResize(
            rect: preview,
            mode: mode,
            others: others,
            canvasWidth: _canvasWidth,
            canvasHeight: _stackHeight,
            threshold: _snapThreshold,
            gridStep: _gridSnapStep,
            guidesX: _snapGuidesX,
            guidesY: _snapGuidesY,
          );
    final delta = raw + snap.delta;
    _dragDelta = delta;
    _guideX = snap.verticalGuides;
    _guideY = snap.horizontalGuides;
    // Зазоры считаются с той же стороны, что и при перемещении: rect тянется,
    // но соседи у него те же самые.
    final rect = _previewRect(delta);
    _measures = rect == null
        ? const []
        : measureDrag(
            moving: rect,
            others: others,
            canvasWidth: _canvasWidth,
            canvasHeight: _stackHeight,
          );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureHandledTap = false;
    _gestureDropped = false;
    if (details.pointerCount == 1) {
      // Палец на ручке поворота — жест принадлежит кнопке: иначе арена
      // начала бы перемещение или рамку выделения вместе с поворотом.
      if (_ownsRotateGesture(details.localFocalPoint)) return;
      final hit = _hitTestChild(details.localFocalPoint);
      if (hit != null) {
        _startDrag(
          hit,
          _screenToStack(details.localFocalPoint),
          StackChildDragMode.move,
          duplicate: HardwareKeyboard.instance.isAltPressed,
        );
        return;
      }
      if (_wantsMarquee) {
        final origin = _screenToStack(details.localFocalPoint);
        setState(() {
          _marqueeStart = origin;
          _marqueeCurrent = origin;
          _marqueeSubtractive = HardwareKeyboard.instance.isAltPressed;
        });
        return;
      }
      // Объект и рамка важнее: направляющая перехватывает только свободный
      // фон, где иначе началась бы панорама.
      final down = _pointerDownPos ?? details.localFocalPoint;
      final target = _guideTargetAt(down);
      if (target != null) {
        _beginGuideDrag(vertical: target.$1, from: target.$2, pointer: down);
        return;
      }
    }
    _baseScale = _camera.scale;
    _lastFocalPoint = details.focalPoint;
  }

  /// Рамка выделения включена кнопкой или держат Shift (добавить) / Alt
  /// (вычесть) — на фоне, где иначе была бы панорама.
  bool get _wantsMarquee =>
      _marqueeMode ||
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isAltPressed;

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_gestureDropped) return;
    // Палец на ручке поворота: канвас не панорамируем и детей не тащим.
    if (_rotateId != null || _rotateDownPos != null) return;
    final guide = _guideDrag;
    if (guide != null) {
      _updateGuideDrag(guide, details.focalPointDelta);
      return;
    }
    if (_marqueeStart != null) {
      setState(() => _marqueeCurrent = _screenToStack(details.localFocalPoint));
      return;
    }
    if (_dragIds.isNotEmpty && _dragStartPos != null) {
      setState(() {
        _dragCurrentPos = _screenToStack(details.localFocalPoint);
        _updateDragDelta();
      });
      return;
    }

    if (details.pointerCount > 1) {
      final newScale = _baseScale * details.scale;
      _camera = _camera.zoomAt(newScale, details.focalPoint);
    } else if (_lastFocalPoint != null) {
      final delta = details.focalPoint - _lastFocalPoint!;
      _camera = _camera.panBy(delta);
    }
    _lastFocalPoint = details.focalPoint;
    setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _gestureHandledTap = true;
    _rotateDownPos = null;
    _pointerDownPos = null;
    if (_gestureDropped) {
      // Esc уже всё отменил: отпускание пальца не должно ни коммитить, ни
      // снимать выделение — жалкий хвост жеста просто игнорируем.
      _gestureDropped = false;
      return;
    }
    if (_guideDrag != null) {
      _endGuideDrag();
      return;
    }
    if (_marqueeStart != null) {
      _endMarquee();
      return;
    }
    _endDrag();
  }

  void _endMarquee() {
    final rect = _marqueeRect;
    final subtract = _marqueeSubtractive;
    setState(() {
      _marqueeStart = null;
      _marqueeCurrent = null;
      _marqueeSubtractive = false;
    });
    if (rect == null) return;
    if (rect.width < 2 && rect.height < 2) return;
    _session.selectMany(
      idsInRect(
        // Скрытые слои рамкой не ловятся — их выбирают из панели слоёв.
        children: _visibleChildren,
        rect: rect,
        width: _canvasWidth,
        height: _stackHeight,
      ),
      additive: HardwareKeyboard.instance.isShiftPressed,
      subtractive: subtract,
    );
  }

  /// Esc посреди рамки: она просто исчезает. Выделение меняется только в
  /// [_endMarquee], поэтому брошенная рамка его не трогает.
  void _cancelMarquee() {
    _gestureDropped = true;
    setState(() {
      _marqueeStart = null;
      _marqueeCurrent = null;
      _marqueeSubtractive = false;
    });
    _lastFocalPoint = null;
  }

  // ── Размер холста за край ────────────────────────────────────────

  /// Пока холст вписан по ширине, FittedBox размазывает добавленные пиксели
  /// высоты между двумя краями — нижний уходит вдвое медленнее пальца.
  /// Двойной коэффициент возвращает жесту точное совпадение с курсором.
  bool get _canvasWidthBound {
    final viewport = _viewportSize;
    if (viewport == null) return false;
    return viewport.width / _canvasWidth < viewport.height / _stackHeight;
  }

  /// Зеркало предыдущего для тяги за правый край.
  bool get _canvasHeightBound {
    final viewport = _viewportSize;
    if (viewport == null) return false;
    return viewport.height / _stackHeight < viewport.width / _canvasWidth;
  }

  void _startCanvasResize({required bool widthAxis}) {
    // Оба множителя снимаются ДО предпросмотра: на старте они ещё равны
    // документным размерам, и жест весь идёт по правилу, которое было в момент
    // захвата края.
    final startScale = _fittedScale * _camera.scale;
    final startDoubled = widthAxis ? _canvasHeightBound : _canvasWidthBound;
    setState(() {
      _canvasDragStartHeight = _stackHeight;
      _canvasDragStartWidth = _canvasWidth;
      _canvasDragDy = 0;
      _canvasDragDx = 0;
      _canvasDragStartScale = startScale;
      _canvasDragStartDoubled = startDoubled;
      // Живой предпросмотр живёт только по тянутой оси: вторая остаётся
      // документной, иначе холст поползёт и туда, где его не держали.
      _canvasPreviewHeight = widthAxis ? null : _stackHeight;
      _canvasPreviewWidth = widthAxis ? _canvasWidth : null;
    });
  }

  void _updateCanvasResize({required bool widthAxis, required double delta}) {
    final from = widthAxis ? _canvasDragStartWidth : _canvasDragStartHeight;
    if (from == null) return;
    final total = ((widthAxis ? _canvasDragDx : _canvasDragDy) ?? 0) + delta;
    var next =
        from +
        total * (_canvasDragStartDoubled ? 2 : 1) / _canvasDragStartScale;
    final step = _gridSnapStep;
    if (step > 0) next = (next / step).roundToDouble() * step;
    setState(() {
      if (widthAxis) {
        _canvasDragDx = total;
        _canvasPreviewWidth = next.clamp(kStackWidthMin, kStackWidthMax);
      } else {
        _canvasDragDy = total;
        _canvasPreviewHeight = next.clamp(kStackHeightMin, kStackHeightMax);
      }
    });
  }

  void _endCanvasResize({required bool widthAxis}) {
    final preview = widthAxis ? _canvasPreviewWidth : _canvasPreviewHeight;
    _resetCanvasResize();
    if (preview == null) return;
    if (widthAxis) {
      _session.setStackWidth(preview);
    } else {
      _session.setStackHeight(preview);
    }
  }

  /// Escape обрывает тягу без правки: то, что тащилось «в никуда», не должно
  /// оставаться в истории.
  void _cancelCanvasResize() {
    if (_canvasPreviewHeight == null && _canvasPreviewWidth == null) return;
    _resetCanvasResize();
  }

  void _resetCanvasResize() {
    setState(() {
      _canvasDragStartHeight = null;
      _canvasDragStartWidth = null;
      _canvasDragDy = null;
      _canvasDragDx = null;
      _canvasPreviewHeight = null;
      _canvasPreviewWidth = null;
    });
  }

  /// Ручки холста — полосы по нижней и правой кромке: тот же жест, что ресайз
  /// фрейма в Figma. Левый и верхний не тянут: от них холст растёт, как и в
  /// плеере, поэтому свободных сторон у него ровно две.
  List<Widget> _buildCanvasEdgeHandle(ColorScheme scheme) {
    final screen = _canvasScreenRect;
    const hit = kStackHandleHit;
    // Хит-зона лежит на кромке пополам. Когда холст вписан в окно, его край
    // совпадает с краем экрана и половина полосы уходит за него — ручку нельзя
    // схватить. Потому и ручки, и плашка прижимаются внутрь вьюпорта.
    final viewport = _viewportSize ?? Size(screen.right, screen.bottom);
    double fit(double value, double max) => math.max(0.0, math.min(value, max));

    Widget edge({
      required String key,
      required Rect band,
      required MouseCursor cursor,
      required bool active,
      required bool widthAxis,
    }) {
      return Positioned(
        key: ValueKey(key),
        left: band.left,
        top: band.top,
        width: band.width,
        height: band.height,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _startCanvasResize(widthAxis: widthAxis),
            onPanUpdate: (d) => _updateCanvasResize(
              widthAxis: widthAxis,
              delta: widthAxis ? d.delta.dx : d.delta.dy,
            ),
            onPanEnd: (_) => _endCanvasResize(widthAxis: widthAxis),
            onPanCancel: _cancelCanvasResize,
            child: Center(
              child: Container(
                width: widthAxis ? 5 : 96,
                height: widthAxis ? 96 : 5,
                decoration: BoxDecoration(
                  color: (active ? scheme.primary : kStackCutColor).withValues(
                    alpha: active ? 0.95 : 0.55,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final handles = [
      edge(
        key: 'canvas_edge_handle',
        band: Rect.fromLTWH(
          screen.left,
          fit(screen.bottom - hit / 2, viewport.height - hit),
          screen.width,
          hit,
        ),
        cursor: SystemMouseCursors.resizeUpDown,
        active: _canvasDragStartHeight != null,
        widthAxis: false,
      ),
      edge(
        key: 'canvas_right_handle',
        band: Rect.fromLTWH(
          fit(screen.right - hit / 2, viewport.width - hit),
          screen.top,
          hit,
          screen.height,
        ),
        cursor: SystemMouseCursors.resizeLeftRight,
        active: _canvasDragStartWidth != null,
        widthAxis: true,
      ),
    ];

    // Пока холст вписан по ширине, его правый край прижат к краю вьюпорта и
    // сдвинуться на экране некуда: жест меняет только масштаб содержимого.
    // Плашка с размерами — честный ответ на «тяну, а ничего не двигается».
    final byWidth = _canvasPreviewWidth != null;
    final dragging = byWidth || _canvasPreviewHeight != null;
    if (!dragging) return handles;

    final badgeLeft = byWidth
        ? fit(screen.right + 8, viewport.width - 130)
        : screen.center.dx - 52;
    final badgeTop = byWidth
        ? screen.center.dy - 12
        : fit(screen.bottom + 10, viewport.height - 28);

    return [
      ...handles,
      Positioned(
        key: const ValueKey('canvas_size_badge'),
        left: badgeLeft,
        top: badgeTop,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: kStackCutColor,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${_canvasWidth.round()} × ${_stackHeight.round()} px',
            style: const TextStyle(
              color: Colors.black,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ];
  }

  /// Rect'ы слоёв, которые вылезли за холст, в экранных координатах. Их
  /// вырезает `Clip.hardEdge` (как в плеере), и без подсказки слой просто
  /// исчезал — «пропал объект» вместо «обрезан край».
  List<Rect> _overhangingScreenRects() {
    final out = <Rect>[];
    for (final child in _children) {
      if (child.isHidden) continue;
      final r = child.stackChildRect(_canvasWidth, _stackHeight);
      if (r.left >= -0.5 &&
          r.top >= -0.5 &&
          r.right <= _canvasWidth + 0.5 &&
          r.bottom <= _stackHeight + 0.5) {
        continue;
      }
      out.add(
        Rect.fromPoints(
          _stackToScreen(r.topLeft),
          _stackToScreen(r.bottomRight),
        ),
      );
    }
    return out;
  }

  /// Габариты слоёв на экране — с поворотом и масштабом: линейка убирает
  /// подложку там, где реально лежит картинка, а не там, где её модельный rect.
  /// [_displayRect] во время тяги даёт живое положение, поэтому дымка идёт за
  /// слоем, а не стоит на месте из модели.
  List<Rect> _childScreenRects() {
    final out = <Rect>[];
    for (final child in _children) {
      if (child.isHidden) continue;
      final corners = stackChildVisualCorners(
        _displayRect(child),
        rotation: child.rotation,
        scale: child.scale,
      );
      var rect = Rect.fromLTWH(0, 0, 0, 0);
      var first = true;
      for (final corner in corners) {
        final at = _stackToScreen(corner);
        final point = Rect.fromLTWH(at.dx, at.dy, 0, 0);
        rect = first ? point : rect.expandToInclude(point);
        first = false;
      }
      out.add(rect);
    }
    return out;
  }

  /// Разметка края холста. Слои ниже объектных ручек и линеек: они важнее
  /// служебной графики, а сам холст под оверлеем не клипается — оверлей
  /// рисуется в координатах экрана.
  Widget _buildCanvasFrame() {
    return Positioned.fill(
      key: const ValueKey('canvas_cut_overlay'),
      child: IgnorePointer(
        child: CustomPaint(
          painter: _StackCutPainter(
            canvasRect: _canvasScreenRect,
            // Пунктир-призрак — замена невидимому слою. Когда слой видно
            // настоящим, подсказка рисовала бы второй контур поверх него.
            overhang: _showOutsideCanvas ? const [] : _overhangingScreenRects(),
            edge: kStackCutColor,
          ),
        ),
      ),
    );
  }

  // ── Направляющие: линейки, вытягивание, перестановка, удаление ────

  /// Невидимая полоса вокруг самой линии: в 1 px с телефона не попасть.
  static const double _guideHit = 9;

  /// Rect холста на экране — в нём же живут ручки объектов и оверлеи.
  Rect get _canvasScreenRect => Rect.fromPoints(
    _stackToScreen(Offset.zero),
    _stackToScreen(Offset(_canvasWidth, _stackHeight)),
  );

  /// Направляющие как цели прилипания: скрытые — не мешают.
  List<double> get _snapGuidesX => _guidesVisible ? _session.guidesX : const [];
  List<double> get _snapGuidesY => _guidesVisible ? _session.guidesY : const [];

  /// Начать драг направляющей. [pointer] — точка в координатах вьюпорта,
  /// [from] — позиция линии, если её тащат (null — линию вытягивают из
  /// линейки, в документе её ещё нет).
  void _beginGuideDrag({
    required bool vertical,
    required Offset pointer,
    double? from,
  }) {
    final stack = _screenToStack(pointer);
    final zoom = _fittedScale * _camera.scale;
    setState(() {
      _guideDrag = _GuideDrag(
        vertical: vertical,
        from: from,
        // При перестановке стартуем от самой линии: иначе она дёргается на
        // величину промаха пальца в момент захвата.
        startStack: from ?? (vertical ? stack.dx : stack.dy),
        zoom: zoom,
      );
    });
  }

  void _updateGuideDrag(_GuideDrag drag, Offset deltaScreen) {
    final zoom = _fittedScale * _camera.scale;
    if (zoom <= 0 || !zoom.isFinite) return;
    setState(() {
      drag.accum += (drag.vertical ? deltaScreen.dx : deltaScreen.dy) / zoom;
    });
  }

  void _endGuideDrag() {
    final drag = _guideDrag;
    setState(() => _guideDrag = null);
    if (drag == null) return;
    if (drag.overRuler) {
      // Вернули в линейку — это удаление; ещё не созданная линия просто
      // исчезает, не оставляя шага истории.
      final from = drag.from;
      if (from != null) {
        _session.removeGuide(vertical: drag.vertical, position: from);
      }
      return;
    }
    final from = drag.from;
    if (from == null) {
      _session.addGuide(vertical: drag.vertical, position: drag.position);
    } else {
      _session.moveGuide(
        vertical: drag.vertical,
        from: from,
        to: drag.position,
      );
    }
  }

  void _cancelGuideDrag() {
    if (_guideDrag == null) return;
    setState(() => _guideDrag = null);
  }

  /// Линии для отрисовки: документ без той, что тащат, плюс она сама сверху.
  List<(bool vertical, double position, bool dragging)> get _guideLines {
    final drag = _guideDrag;
    if (drag == null) {
      return [
        for (final g in _session.guidesX) (true, g, false),
        for (final g in _session.guidesY) (false, g, false),
      ];
    }
    // Переставляемая линия рисуется только в позиции под курсором: две её
    // копии («старая» и «новая») выглядели бы как две разные направляющие.
    final from = drag.from;
    bool dragged(bool vertical, double g) =>
        vertical == drag.vertical && g == from;
    return [
      for (final g in _session.guidesX)
        if (!dragged(true, g)) (true, g, false),
      for (final g in _session.guidesY)
        if (!dragged(false, g)) (false, g, false),
      (drag.vertical, drag.position, true),
    ];
  }

  /// Что хочет начать жест на пустом месте канваса: перестановку направляющей
  /// (её [position]) или новую линию из полосы линейки ([position] == null).
  ///
  /// Диспетч тут, а не отдельными виджетами-детекторами поверх холста:
  /// нативный жест линейки в арене переиграл бы scale-жест канваса, и под
  /// полосой линейки объекты стало бы невозможно ни тащить, ни выделять.
  (bool vertical, double? position)? _guideTargetAt(Offset screenPos) {
    if (!_guidesVisible) return null;
    final zoom = _fittedScale * _camera.scale;
    if (zoom <= 0 || !zoom.isFinite) return null;
    final screen = _canvasScreenRect;
    if (!screen.contains(screenPos)) return null;
    final stack = _screenToStack(screenPos);
    // Порог в экранных px: на 25% зума в 4 px стека не попасть.
    final tolerance = _guideHit / zoom;
    for (final g in _session.guidesX) {
      if ((stack.dx - g).abs() <= tolerance) return (true, g);
    }
    for (final g in _session.guidesY) {
      if ((stack.dy - g).abs() <= tolerance) return (false, g);
    }
    // Свободный край холста — полоса линейки: отсчитываем от её края, чтобы
    // зум не менял толщину зоны захвата.
    if (stack.dx * zoom <= kStackRulerThickness) return (true, null);
    if (stack.dy * zoom <= kStackRulerThickness) return (false, null);
    return null;
  }

  List<Widget> _buildRulersAndGuides(ColorScheme scheme) {
    if (!_guidesVisible) return const [];
    final screen = _canvasScreenRect;
    final zoom = _fittedScale * _camera.scale;
    if (zoom <= 0 || !zoom.isFinite) return const [];
    final content = _childScreenRects();

    Widget ruler({required bool vertical}) {
      final band = vertical
          ? Rect.fromLTWH(
              screen.left,
              screen.top + kStackRulerThickness,
              kStackRulerThickness,
              math.max(0, screen.height - kStackRulerThickness),
            )
          : Rect.fromLTWH(
              screen.left,
              screen.top,
              screen.width,
              kStackRulerThickness,
            );
      return Positioned(
        key: ValueKey(vertical ? 'ruler_vertical' : 'ruler_horizontal'),
        left: band.left,
        top: band.top,
        width: band.width,
        height: band.height,
        child: IgnorePointer(
          child: CustomPaint(
            painter: _StackRulerPainter(
              vertical: vertical,
              canvasSize: vertical ? _canvasWidth : _stackHeight,
              zoom: zoom,
              tick: scheme.onSurface.withOpacity(0.45),
              label: scheme.onSurfaceVariant,
              background: scheme.surface.withOpacity(0.82),
              border: scheme.outlineVariant.withOpacity(0.5),
              contentGaps: rulerContentGaps(band: band, content: content),
            ),
          ),
        ),
      );
    }

    return [
      // Направляющие — под линейками: линию, притянутую к краю, удаляют
      // возвратом в линейку, и она не должна её перекрывать.
      for (final (vertical, position, dragging) in _guideLines)
        _buildGuideLine(
          vertical: vertical,
          position: position,
          dragging: dragging,
          screen: screen,
          zoom: zoom,
          color: kStackGuideColor,
        ),
      ruler(vertical: false),
      ruler(vertical: true),
    ];
  }

  Widget _buildGuideLine({
    required bool vertical,
    required double position,
    required bool dragging,
    required Rect screen,
    required double zoom,
    required Color color,
  }) {
    final axis = position * zoom;
    final band = vertical
        ? Rect.fromLTWH(
            screen.left + axis - _guideHit / 2,
            screen.top,
            _guideHit,
            screen.height,
          )
        : Rect.fromLTWH(
            screen.left,
            screen.top + axis - _guideHit / 2,
            screen.width,
            _guideHit,
          );
    return Positioned(
      key: ValueKey('guide_${vertical ? 'x' : 'y'}_${position.round()}'),
      left: band.left,
      top: band.top,
      width: band.width,
      height: band.height,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _StackGuidePainter(
            vertical: vertical,
            thickness: dragging ? 1.6 : 1.0,
            color: color,
            label: dragging ? position.round().toString() : null,
            labelColor: color,
          ),
        ),
      ),
    );
  }

  /// Итог драга — одна запись истории (move или resize), а не на каждый
  /// кадр жеста: во время жеста rect живёт только в [_displayRect].
  void _endDrag() {
    final ids = _dragIds;
    final mode = _dragMode;
    final start = _dragStartPos;
    final current = _dragCurrentPos;
    final delta = _dragDelta;
    final startRects = _dragStartRects;
    final duplicate = _dragIsDuplicate;
    // Rect'ы группы читаем до сброса: превью и коммит должны сойтись на одном.
    final groupStart = _groupStartUnion;
    final group = _groupRect;
    setState(() {
      _dragIds = <String>{};
      _dragMode = null;
      _dragStartRects = const {};
      _dragStartPos = null;
      _dragCurrentPos = null;
      _dragDelta = Offset.zero;
      _dragIsDuplicate = false;
      _groupStartUnion = null;
      _guideX = const [];
      _guideY = const [];
      _measures = const [];
    });
    _lastFocalPoint = null;

    if (ids.isEmpty || mode == null || start == null || current == null) {
      return;
    }
    if (mode == StackChildDragMode.move) {
      if (duplicate) {
        // Копии уже в документе; остаётся сдвинуть их и закрыть одним
        // шагом истории — даже при нулевом смещении (Alt+клик без драга).
        _session.finishDuplicateDrag(delta);
        return;
      }
      _commitChildren(
        translateChildren(
          children: _children,
          ids: ids,
          delta: delta,
          width: _canvasWidth,
          height: _stackHeight,
        ),
        kind: StackEditKind.move,
        label: ids.length > 1
            ? trf('перемещение {n} объектов', {'n': ids.length})
            : null,
      );
      return;
    }
    if (groupStart != null && group != null) {
      _commitChildren(
        [
          for (final c in _children)
            if (startRects.containsKey(c.id))
              c.stackChildWithRect(
                scaleRectIntoGroup(startRects[c.id]!, groupStart, group),
                _canvasWidth,
                _stackHeight,
              )
            else
              c,
        ],
        kind: StackEditKind.resize,
        label: ids.length > 1
            ? trf('ресайз {n} объектов', {'n': ids.length})
            : null,
      );
      return;
    }
    final id = ids.first;
    final startRect = startRects[id];
    if (startRect == null) return;
    _session.commitChild(
      id,
      (child) => _applyDragRect(child, startRect, mode, delta),
      kind: StackEditKind.resize,
    );
  }

  /// Escape посреди драга или ресайза: превью живёт в состоянии, поэтому
  /// отмена — это только его сброс. Кроме Alt-жеста: его копии появились в
  /// документе на старте, и убирает их сессия.
  void _cancelDrag() {
    _gestureDropped = true;
    if (_dragIsDuplicate) _session.abortDuplicateDrag();
    setState(() {
      _dragIds = <String>{};
      _dragMode = null;
      _dragStartRects = const {};
      _dragStartPos = null;
      _dragCurrentPos = null;
      _dragDelta = Offset.zero;
      _dragIsDuplicate = false;
      _groupStartUnion = null;
      _guideX = const [];
      _guideY = const [];
      _measures = const [];
    });
    _lastFocalPoint = null;
  }

  /// Геометрия после resize: только нижний пол бокса, как в игроцком layout,
  /// чтобы объект не схлопнулся в ноль. Верхней планки нет: холст — окно, а не
  /// стена, и спрайт-фон заведомо больше 720 px. Без этого коммит возвращал
  /// объект назад к краю холста сразу после того, как ручка утащила его дальше.
  ///
  /// [resizeStackChildRect] — тот же вызов, что и в [_previewRect]: у повёрнутого
  /// объекта ручка тянет по его собственным осям и закрепленный угол стоит на
  /// месте, иначе центр уезжал бы при каждом кадре жеста.
  ContentItem _applyDragRect(
    ContentItem child,
    Rect startRect,
    StackChildDragMode mode,
    Offset delta,
  ) {
    final rect = resizeStackChildRect(
      start: startRect,
      mode: mode,
      delta: delta,
      rotation: child.rotation,
      scale: child.scale,
      keepAspect: _dragKeepAspect,
    );
    return child.stackChildWithRect(
      Rect.fromLTWH(
        rect.left,
        rect.top,
        rect.width.clamp(kStackChildMinWidth, double.infinity),
        rect.height.clamp(kStackChildMinHeight, double.infinity),
      ),
      _canvasWidth,
      _stackHeight,
    );
  }

  // ── Поворот ручкой на канвасе ────────────────────────────────────

  /// Угол считаем от фактического направления на палец, а не от «0»: тап по
  /// ручке сверху не должен мгновенно поворачивать объект на 90°.
  void _startRotate(ContentItem child, Offset center, Offset pointer) {
    setState(() {
      _rotateId = child.id;
      _rotateCenter = center;
      _rotateStartValue = child.rotation;
      _rotateStartAngle = math.atan2(
        pointer.dy - center.dy,
        pointer.dx - center.dx,
      );
      _rotateShownDegrees = child.rotation;
    });
  }

  /// [snapShift] — Shift: шаг 15°, как в Figma. Coalesce-правка, поэтому вся
  /// дуга остаётся одним шагом undo.
  void _updateRotate(Offset pointer, {required bool snapShift}) {
    final id = _rotateId;
    final center = _rotateCenter;
    if (id == null || center == null || _session.indexOf(id) == null) return;
    final angle = math.atan2(pointer.dy - center.dy, pointer.dx - center.dx);
    var deg = _rotateStartValue + (angle - _rotateStartAngle) * 180 / math.pi;
    if (snapShift) deg = (deg / 15).roundToDouble() * 15;
    // Модель живёт в ±180: 270° = -90°, иначе слайдер свойств уедет за край.
    deg = ((deg + 180) % 360 + 360) % 360 - 180;
    setState(() => _rotateShownDegrees = deg);
    _session.commitChild(
      id,
      (c) => c.copyWith(rotation: deg),
      kind: StackEditKind.style,
      label: tr('поворот'),
      coalesce: true,
    );
  }

  void _endRotate() {
    _rotateDownPos = null;
    if (_rotateId == null) return;
    setState(() {
      _rotateId = null;
      _rotateCenter = null;
      _rotateShownDegrees = null;
    });
  }

  void _onTapUp(TapUpDetails details) {
    if (_gestureHandledTap) {
      _gestureHandledTap = false;
      return;
    }
    // Тап по ручке поворота — не «мимо объекта»: выделение должно сохраниться.
    if (_ownsRotateGesture(details.localPosition)) return;
    final hit = _hitTestChild(details.localPosition);
    if (hit == null) {
      _session.clearSelection();
      return;
    }
    _applyClickSelection(hit);
    // Alt+тап — дубликат на месте: жест без движения до _startDrag не доходит,
    // а дублировать этим жестом пользователь как раз собирался.
    if (HardwareKeyboard.instance.isAltPressed) {
      _session.duplicateSelected(idFactory: _newChildId, offset: Offset.zero);
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    final hit = _hitTestChild(details.localPosition);
    if (hit == null) {
      // Двойной тап по пустому месту — «добавь слой сюда». Точка уходит в
      // меню и новый объект встаёт ровно под курсором, а не по центру
      // видимой области: раньше за каждое «вот сюда» слой нужно было двигать.
      final at = _screenToStack(details.localPosition);
      final canvas = Rect.fromLTWH(0, 0, _canvasWidth, _stackHeight);
      if (!canvas.contains(at)) return;
      _addNewItem(at: at);
      return;
    }
    final index = _session.indexOf(hit.id);
    if (index != null) _openChildEditor(index);
  }

  // ── Клавиатура ───────────────────────────────────────────────────

  static Offset? _nudgeDelta(LogicalKeyboardKey key, bool shift) {
    final step = shift ? 10.0 : 1.0;
    if (key == LogicalKeyboardKey.arrowLeft) return Offset(-step, 0);
    if (key == LogicalKeyboardKey.arrowRight) return Offset(step, 0);
    if (key == LogicalKeyboardKey.arrowUp) return Offset(0, -step);
    if (key == LogicalKeyboardKey.arrowDown) return Offset(0, step);
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Региональный вариант (fr, dvorak и т.п.) кладёт буквы на другие
    // physical-коды, поэтому сравниваем именно logical.
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final isModifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    final shift = keyboard.isShiftPressed;

    if (key == LogicalKeyboardKey.keyM && !isModifier) {
      setState(() => _marqueeMode = !_marqueeMode);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      // Драг объекта и рамка выделения живут только в превью, поэтому их
      // можно бросить без следа. Ресайз — тот же драг: он тоже превью до
      // отпускания. Поворот не откатываем: он пишется в историю на ходу.
      if (_dragIds.isNotEmpty) {
        _cancelDrag();
        return KeyEventResult.handled;
      }
      if (_marqueeStart != null) {
        _cancelMarquee();
        return KeyEventResult.handled;
      }
      // Драг направляющей и тяга холста — тоже жесты с превью.
      if (_guideDrag != null) {
        _cancelGuideDrag();
        return KeyEventResult.handled;
      }
      if (_canvasPreviewHeight != null) {
        _cancelCanvasResize();
        return KeyEventResult.handled;
      }
      if (_session.selection.isEmpty) return KeyEventResult.ignored;
      _session.clearSelection();
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.semicolon) {
      setState(() => _guidesVisible = !_guidesVisible);
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.keyA) {
      if (_children.isEmpty) return KeyEventResult.ignored;
      _session.selectAll();
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.keyZ) {
      return shift ? _redo() : _undo();
    }
    if (isModifier && key == LogicalKeyboardKey.keyY) return _redo();
    if (isModifier && key == LogicalKeyboardKey.keyD) {
      if (_session.selection.isEmpty) return KeyEventResult.ignored;
      _session.duplicateSelected(idFactory: _newChildId);
      return KeyEventResult.handled;
    }
    // Стиль, а не объект: Alt здесь отличает «оформление перенести» от
    // «скопировать слой». Проверять надо до обычного Ctrl+C/V.
    if (isModifier && keyboard.isAltPressed && key == LogicalKeyboardKey.keyC) {
      _copyStyleFromSelection();
      return KeyEventResult.handled;
    }
    if (isModifier && keyboard.isAltPressed && key == LogicalKeyboardKey.keyV) {
      _pasteStyleTo(_session.selection);
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.keyC) {
      if (_session.selection.isEmpty) return KeyEventResult.ignored;
      _copySelected();
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.keyX) {
      if (_session.selection.isEmpty) return KeyEventResult.ignored;
      _cutSelected();
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.keyV) {
      if (_clipboard.isEmpty) return KeyEventResult.ignored;
      _paste();
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.keyG) {
      final changed = shift
          ? _session.ungroupSelected()
          : _session.groupSelected() != null;
      return changed ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (isModifier && key == LogicalKeyboardKey.bracketRight) {
      _session.zOrder(toFront: true);
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.bracketLeft) {
      _session.zOrder(toFront: false);
      return KeyEventResult.handled;
    }
    final zoomFactor = _zoomFactor(key);
    if (isModifier && zoomFactor != null) {
      _zoomBy(zoomFactor);
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.digit0) {
      _fitStackInView();
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.digit1) {
      _zoomToActualSize();
      return KeyEventResult.handled;
    }
    if (isModifier && key == LogicalKeyboardKey.digit2) {
      _zoomToSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (_session.selection.isEmpty) return KeyEventResult.ignored;
      _session.removeSelected();
      return KeyEventResult.handled;
    }
    final nudge = _nudgeDelta(key, shift);
    if (nudge != null) {
      final ids = _session.selection;
      if (ids.isEmpty) return KeyEventResult.ignored;
      // Alt+стрелка — ресайз вместо перемещения: якорь стоит, растут правый
      // и нижний край.
      if (keyboard.isAltPressed) {
        _commitChildren(
          nudgeResize(
            children: _children,
            ids: ids,
            delta: nudge,
            width: _canvasWidth,
            height: _stackHeight,
          ),
          kind: StackEditKind.resize,
          coalesce: true,
        );
        return KeyEventResult.handled;
      }
      _commitChildren(
        translateChildren(
          children: _children,
          ids: ids,
          delta: nudge,
          width: _canvasWidth,
          height: _stackHeight,
        ),
        kind: StackEditKind.nudge,
        coalesce: true,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _undo() =>
      _session.undo() ? KeyEventResult.handled : KeyEventResult.ignored;

  KeyEventResult _redo() =>
      _session.redo() ? KeyEventResult.handled : KeyEventResult.ignored;

  String _newChildId() => 'item_${_uuid.v4()}';

  // ── Буфер канваса ────────────────────────────────────────────────

  /// Копируем по z-порядку: вставка обязана сохранять взаимный порядок слоёв,
  /// а Set выделения идёт в порядке нажатий.
  void _copySelected() {
    final ids = _session.selectedIdsInZOrder;
    if (ids.isEmpty) return;
    final byId = {for (final c in _children) c.id: c};
    _clipboard = [for (final id in ids) byId[id]].nonNulls.toList();
    _pasteStagger = 0;
  }

  void _cutSelected() {
    _copySelected();
    if (_clipboard.isNotEmpty) _session.removeSelected();
  }

  /// Повторная вставка одного и того же уходит веером: Ctrl+V трижды кладёт
  /// три копии лесенкой, а не одну ровно под другой.
  void _paste() {
    if (_clipboard.isEmpty) return;
    _pasteStagger++;
    _session.insertCopies(
      _clipboard,
      idFactory: _newChildId,
      offset:
          const Offset(kStackPasteStep, kStackPasteStep) *
          _pasteStagger.toDouble(),
    );
  }

  // ── Стиль ────────────────────────────────────────────────────────

  /// Копируем вид слоя, а не слой: у цели остаются своя геометрия, текст и
  /// поведения. Источник — основной выделенный (тот же, что у подписи группы).
  void _copyStyleFromSelection() {
    final source = _session.primaryChild;
    if (source == null) return;
    setState(() => _styleSource = source);
  }

  void _pasteStyleTo(Set<String> ids) {
    final source = _styleSource;
    if (source == null || ids.isEmpty) return;
    _commitChildren(
      pasteStyle(children: _children, ids: ids, source: source),
      kind: StackEditKind.style,
      label: tr('перенос стиля'),
    );
  }

  void _showItemContextMenu(ContentItem child) {
    final index = _session.indexOf(child.id);
    if (index == null) return;
    final scheme = Theme.of(context).colorScheme;
    showAdaptiveSheet(
      context: context,
      backgroundColor: scheme.surfaceContainerHigh,
      // Пунктов больше половины экрана: без скролла нижние уезжали за его
      // границы и на них было невозможно попасть.
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: SingleChildScrollView(
            child: Wrap(
              children: [
                ListTile(
                  leading: Icon(Icons.edit_rounded, color: scheme.onSurface),
                  title: Text(tr('Редактировать')),
                  subtitle: Text(tr('Редактор по типу объекта')),
                  onTap: () {
                    Navigator.pop(context);
                    _openChildEditor(index);
                  },
                ),
                if (child.type == 'image')
                  ListTile(
                    leading: Icon(
                      Icons.swap_horiz_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    title: Text(tr('Сменить изображение')),
                    subtitle: Text(
                      trf('Сейчас: {p0}', {'p0': _resourceLabel(child.resourcePath) ?? tr('не выбрано')}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _replaceLayerImage(child.id);
                    },
                  ),
                ListTile(
                  leading: Icon(
                    Icons.bolt,
                    color: TriggerSlotButtons.hasAny(child)
                        ? Colors.amber
                        : scheme.onSurfaceVariant,
                  ),
                  title: Text(tr('Триггеры')),
                  subtitle: Text(tr('onAppear / onPress этого объекта')),
                  onTap: () {
                    Navigator.pop(context);
                    _openChildTriggers(index);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.copy_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: Text(tr('Дублировать')),
                  subtitle: Text(tr('или Alt+драг / Ctrl+D')),
                  onTap: () {
                    Navigator.pop(context);
                    _session.select(child.id);
                    _session.duplicateSelected(idFactory: _newChildId);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.format_paint_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: Text(tr('Скопировать стиль')),
                  subtitle: Text(
                    tr('Только вид: цвет, шрифт, отступ, радиус'),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _session.select(child.id);
                    _copyStyleFromSelection();
                  },
                ),
                if (_styleSource != null && child.id != _styleSource!.id)
                  ListTile(
                    leading: const Icon(
                      Icons.format_color_fill_rounded,
                      color: Colors.amber,
                    ),
                    title: Text(tr('Вставить стиль в этот слой')),
                    subtitle: Text(tr('или Ctrl+Alt+V — в выделенное')),
                    onTap: () {
                      Navigator.pop(context);
                      _pasteStyleTo({child.id});
                    },
                  ),
                ListTile(
                  leading: Icon(
                    Icons.label_outline_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: Text(tr('Переименовать слой')),
                  subtitle: Text(tr('Подпись только в панели слоёв')),
                  onTap: () {
                    Navigator.pop(context);
                    _openRenameLayerSheet(child);
                  },
                ),
                ListTile(
                  leading: Icon(
                    child.isHidden
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: Text(child.isHidden ? tr('Показать слой') : tr('Скрыть слой')),
                  onTap: () {
                    Navigator.pop(context);
                    _toggleChildHidden(child);
                  },
                ),
                ListTile(
                  leading: Icon(
                    child.locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: Text(
                    child.locked ? tr('Разблокировать') : tr('Заблокировать'),
                  ),
                  subtitle: child.locked
                      ? Text(tr('Слой снова выделяется тапом и рамкой'))
                      : Text(tr('Не выделяется и не сдвигается случайно')),
                  onTap: () {
                    Navigator.pop(context);
                    _toggleChildLocked(child);
                  },
                ),
                if (child.groupName != null)
                  ListTile(
                    leading: Icon(
                      Icons.group_off_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    title: Text(tr('Разгруппировать')),
                    subtitle: Text(
                      trf('Слои группы «{p0}» перестанут выделяться вместе', {'p0': child.groupName}),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      // Без возни с выделением: по имени снимается вся группа,
                      // а слой в этом меню может быть и невыделенным.
                      _session.ungroupLayer(child.id);
                    },
                  ),
                ListTile(
                  leading: Icon(
                    Icons.vertical_align_top,
                    color: scheme.primary,
                  ),
                  title: Text(tr('На передний план')),
                  onTap: () {
                    Navigator.pop(context);
                    _session.select(child.id);
                    _session.zOrder(toFront: true);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.vertical_align_bottom,
                    color: scheme.primary,
                  ),
                  title: Text(tr('На задний план')),
                  onTap: () {
                    Navigator.pop(context);
                    _session.select(child.id);
                    _session.zOrder(toFront: false);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.zoom_in_map_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: Text(tr('Приблизить к объекту')),
                  subtitle: Text(tr('или Ctrl+2 по выделению')),
                  onTap: () {
                    Navigator.pop(context);
                    _session.select(child.id);
                    _zoomToSelection();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline, color: scheme.error),
                  title: Text(tr('Удалить'), style: TextStyle(color: scheme.error)),
                  onTap: () {
                    Navigator.pop(context);
                    _session.select(child.id);
                    _session.removeSelected();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Точка появления нового слоя: центр видимой области, а не центр холста.
  /// Иначе, приблизившись к правому нижнему углу, объект создался бы там, где
  /// его не видно, — «кнопка не работает» из-за прокрутки.
  Offset _spawnPoint() {
    final viewport = _viewportSize;
    if (viewport == null) {
      return Offset(_canvasWidth / 2, _stackHeight / 2);
    }
    final center = _screenToStack(
      Offset(viewport.width / 2, viewport.height / 2),
    );
    return Offset(
      center.dx.clamp(0.0, _canvasWidth),
      center.dy.clamp(0.0, _stackHeight),
    );
  }

  /// Кладёт слой центром в [at] (или в [_spawnPoint]) и выделяет его. Якоря —
  /// нулевые, от верхнего левого угла: тогда «X 12» в инспекторе означает 12 px
  /// от края холста, а не 12 px от центра, и ресайз холста не утаскивает слой
  /// за собой.
  void _placeNewChild(ContentItem item, {Offset? at}) {
    final point = at ?? _spawnPoint();
    // Центр не выпускаем за холст: на низком стеке бокс выше холста, и слой
    // встал бы так, что его не видно и не схватить.
    final halfW = math.min(kStackNewChildHalfWidth, _canvasWidth / 2);
    final halfH = math.min(kStackNewChildHalfHeight, _stackHeight / 2);
    double keep(double v, double half, double extent) =>
        math.min(math.max(v, half), extent - half);
    final dx = keep(point.dx, halfW, _canvasWidth);
    final dy = keep(point.dy, halfH, _stackHeight);
    final child = item.copyWith(
      anchorLeft: 0,
      anchorTop: 0,
      anchorRight: 0,
      anchorBottom: 0,
      offsetLeft: dx - kStackNewChildHalfWidth,
      offsetTop: dy - kStackNewChildHalfHeight,
      offsetRight: dx + kStackNewChildHalfWidth,
      offsetBottom: dy + kStackNewChildHalfHeight,
    );
    final children = List<ContentItem>.from(_children)..add(child);
    _session.select(child.id);
    _commitChildren(children, kind: StackEditKind.add);
  }

  /// Черновик/финал из вложенного редактора: заменяем слой по id или
  /// добавляем новый на месте вызова; закрывать вкладку ради сохранения
  /// не нужно.
  void _upsertLayer(ContentItem item, {Offset? at}) {
    if (!mounted) return;
    final index = _children.indexWhere((existing) => existing.id == item.id);
    if (index >= 0) {
      final children = List<ContentItem>.from(_children);
      final previous = children[index];
      children[index] = item.copyWith(
        anchorLeft: previous.anchorLeft,
        anchorTop: previous.anchorTop,
        anchorRight: previous.anchorRight,
        anchorBottom: previous.anchorBottom,
        offsetLeft: previous.offsetLeft,
        offsetTop: previous.offsetTop,
        offsetRight: previous.offsetRight,
        offsetBottom: previous.offsetBottom,
      );
      _commitChildren(
        children,
        kind: item.type == 'text' ? StackEditKind.text : StackEditKind.style,
        label: tr('Автосохранение'),
        coalesce: true,
      );
    } else {
      _placeNewChild(item, at: at);
    }
  }

  /// Добавить слой: тот же выбор типа, что у элемента ноды. Раньше «+» на
  /// канвасе создавала только текст, и за картинку или кнопку приходилось
  /// уходить в список детей. [at] — точка двойного тапа: слой появляется там,
  /// где его вызвали.
  Future<void> _addNewItem({Offset? at}) async {
    await ContentAddMenuSheet.show(
      context,
      excludeTypes: const ['stack'],
      onItemSelected: (type, {pluginTypeId}) async {
        final ContentItem? created;
        if (type == 'plugin') {
          // Плагин добавляется только через форму: пустой айтем в плеере
          // выглядит как «плагин ничего не вывел».
          final pluginType = findPluginContentType(ref, pluginTypeId);
          created = pluginType == null
              ? null
              : await createPluginContentItem(
                  context,
                  type: pluginType,
                  questId: widget.questId,
                );
        } else {
          created = await _logic.createItemByType(
            type,
            onDraft: (item) => _upsertLayer(item, at: at),
          );
        }
        if (created == null || !mounted) return;
        _upsertLayer(created, at: at);
      },
      // Буфер у канваса свой (Ctrl+C/V по слоям) — «вставить» ведёт туда же.
      onPaste: _paste,
      // Шаблоны в стек ещё не применяются — строку «Из шаблона» в меню
      // не показываем вместо обещания «позже».
    );
  }

  void _fitStackInView() {
    if (!mounted) return;
    // Сбрасываем камеру — FittedBox сам вписывает стек в viewport.
    setState(() => _camera = _camera.reset());
  }

  /// Шаг клавиатурного зума: 25% за нажатие — между «ничего не изменилось» и
  /// «пришлось жать десять раз».
  static const double _zoomStep = 1.25;

  /// «+» на разных раскладках приходит то как equal, то как add (Shift+=),
  /// поэтому принимаем оба варианта и цифровой блок.
  static double? _zoomFactor(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      return _zoomStep;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.underscore ||
        key == LogicalKeyboardKey.numpadSubtract) {
      return 1 / _zoomStep;
    }
    return null;
  }

  /// Зум вокруг центра вьюпорта: у клавиатуры нет курсора, в который можно
  /// было бы «приземлить» масштаб.
  void _zoomBy(double factor) {
    final viewport = _viewportSize;
    if (viewport == null) return;
    setState(
      () => _camera = _camera.zoomAtCenter(_camera.scale * factor, viewport),
    );
  }

  /// «100 %» — тот же масштаб, о котором говорит индикатор в статус-баре:
  /// он показывает камеру, а не итоговый зум вместе с вписыванием.
  void _zoomToActualSize() {
    final viewport = _viewportSize;
    if (viewport == null) return;
    setState(() => _camera = _camera.zoomAtCenter(1.0, viewport));
  }

  /// Приблизить вид до выделения (Ctrl+2): рамка объекта или группы
  /// вписывается в вьюпорт. На пустом выделении ничего не делает — зум
  /// «ко всему» уже есть на Ctrl+0.
  void _zoomToSelection() {
    final viewport = _viewportSize;
    if (viewport == null) return;
    final ids = _session.selection;
    if (ids.isEmpty) return;
    final union = unionOfChildren(
      children: [
        for (final c in _children)
          if (ids.contains(c.id)) c,
      ],
      width: _canvasWidth,
      height: _stackHeight,
    );
    if (union == null) return;
    final world = Rect.fromPoints(
      _stackToWorld(union.topLeft),
      _stackToWorld(union.bottomRight),
    );
    setState(() => _camera = _camera.fitToRect(world, viewport));
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Имена ресурсов — как и [_fittedScale], пишем из build: читают и модалки,
    // открываемые вне build, где watch запрещён.
    _resourceNames =
        ref.watch(questResourceNamesProvider(widget.questId)).valueOrNull ??
        const {};
    // Имена плагин-типов приходят из Rust-хоста асинхронно: без подписки
    // панель слоёв показывала бы «Плагин» до первой посторонней пересборки.
    ref.watch(pluginContentTypesProvider);

    return Scaffold(
      backgroundColor: scheme.surfaceDim,
      appBar: AppBar(
        title: Text(
          tr('Редактор стека (канвас)'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // На телефоне восемь кнопок в строку не влезают, и AppBar переполняется
        // ещё до панели слоёв. Лента действий прокручивается, заголовку
        // остаётся треть ширины; на десктопе лента шире самих кнопок не стала.
        actions: [
          SizedBox(
            width: math.min(
              kStackAppBarActionsWidth,
              MediaQuery.sizeOf(context).width * 0.62,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: tr('Холст и фон стека'),
                    icon: const Icon(Icons.aspect_ratio_rounded),
                    onPressed: _openStackPropsSheet,
                  ),
                  IconButton(
                    tooltip: _layersOpen
                        ? tr('Скрыть панель слоёв')
                        : tr('Панель слоёв: z-порядок (долгое нажатие на строку), видимость, замок, выбор'),
                    icon: Icon(
                      Icons.layers_rounded,
                      color: _layersOpen ? scheme.primary : null,
                    ),
                    onPressed: () => setState(() => _layersOpen = !_layersOpen),
                  ),
                  IconButton(
                    tooltip: _marqueeMode
                        ? tr('Рамка выделения включена: тащите по фону (M — выкл)')
                        : tr('Рамка выделения выключена: фон панорамирует (M или Shift+драг — рамка)'),
                    icon: Icon(
                      Icons.crop_free,
                      color: _marqueeMode ? scheme.primary : null,
                    ),
                    onPressed: () =>
                        setState(() => _marqueeMode = !_marqueeMode),
                  ),
                  IconButton(
                    tooltip: _session.undoLabel == null
                        ? tr('Отменить')
                        : trf('Отменить: {action}', {
                            'action': _session.undoLabel,
                          }),
                    icon: const Icon(Icons.undo_rounded),
                    onPressed: _session.canUndo ? () => _session.undo() : null,
                  ),
                  IconButton(
                    tooltip: _session.redoLabel == null
                        ? tr('Вернуть')
                        : trf('Вернуть: {action}', {
                            'action': _session.redoLabel,
                          }),
                    icon: const Icon(Icons.redo_rounded),
                    onPressed: _session.canRedo ? () => _session.redo() : null,
                  ),
                  IconButton(
                    tooltip:
                        tr('Вписать стек в экран (Ctrl+0), к выделению — Ctrl+2'),
                    icon: const Icon(Icons.fit_screen_rounded),
                    onPressed: _fitStackInView,
                  ),
                  IconButton(
                    tooltip: tr('Масштаб 100 % (Ctrl+1)'),
                    icon: const Icon(Icons.center_focus_strong_rounded),
                    onPressed: _zoomToActualSize,
                  ),
                  IconButton(
                    tooltip: tr('Горячие клавиши'),
                    icon: const Icon(Icons.keyboard_alt_outlined),
                    onPressed: () => showStackCanvasHotkeys(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Панель слоёв — оверлей справа, но канвас под неё сжимается:
          // иначе панель легла бы ровно на те объекты, которые двигают.
          final panelW = _layersOpen
              ? _layersPanelWidth(constraints.maxWidth)
              : 0.0;
          final cw = constraints.maxWidth - panelW;
          final ch = constraints.maxHeight;
          _viewportSize = Size(cw, ch);

          // FittedBox scale — масштаб, при котором 720×stackHeight
          // вписывается в viewport.
          final s = math.min(cw / _canvasWidth, ch / _stackHeight);
          final ox = (cw - _canvasWidth * s) / 2;
          final oy = (ch - _stackHeight * s) / 2;
          _fittedScale = s;
          _fittedOrigin = Offset(ox, oy);

          final selection = _session.selection;
          final primary = _session.primaryChild;

          return Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _onKey,
            child: Stack(
              children: [
                // Фон: тёмный + сетка
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GridPainter(
                      camera: _camera,
                      gridColor:
                          Color.lerp(scheme.surface, scheme.onSurface, 0.12) ??
                          scheme.onSurface,
                      backgroundColor: scheme.surfaceDim,
                    ),
                  ),
                ),

                // Дети стека: FittedBox + Transform (pan/zoom)
                Positioned.fill(
                  child: MouseRegion(
                    key: const ValueKey('stack_canvas_input'),
                    cursor: _canvasCursor,
                    onHover: _onCanvasHover,
                    onExit: (_) => _setHover(null),
                    child: Listener(
                      // Поведение обязано быть translucent: детектор ниже по
                      // дереву тоже translucent и родителю возвращает false,
                      // поэтому без явного поведения слушатель просто не попал
                      // бы в путь hit-теста на свободном фоне — и точка
                      // касания осталась бы неизвестной.
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (event) {
                        _pointerDownPos = event.localPosition;
                      },
                      onPointerSignal: (event) {
                        if (event is PointerScrollEvent) {
                          final speed = 0.05;
                          final newScale = event.scrollDelta.dy < 0
                              ? _camera.scale * (1 + speed)
                              : _camera.scale / (1 + speed);
                          setState(() {
                            _camera = _camera.zoomAt(
                              newScale,
                              event.localPosition,
                            );
                          });
                        }
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        onScaleEnd: _onScaleEnd,
                        onTapUp: _onTapUp,
                        onDoubleTapDown: _onDoubleTapDown,
                        onLongPressStart: (details) {
                          final hit = _hitTestChild(details.localPosition);
                          if (hit != null) _showItemContextMenu(hit);
                        },
                        child: Transform(
                          transform: Matrix4.identity()
                            ..translate(_camera.offset.dx, _camera.offset.dy)
                            ..scale(_camera.scale),
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: SizedBox(
                              width: _canvasWidth,
                              height: _stackHeight,
                              child: Stack(
                                key: const ValueKey('stack_children_layer'),
                                // Выкл. режим = честная копия плеера: за
                                // рамкой ничего не остаётся. Вкл. = слой
                                // дорисовывается снаружи, под затемнённой
                                // зоной отсечки.
                                clipBehavior: _showOutsideCanvas
                                    ? Clip.none
                                    : Clip.hardEdge,
                                children: [
                                  // Фон стека — при наличии цвета или
                                  // картинки-фона (как в GameStackWidget).
                                  if (_stackItem.backgroundColor != null)
                                    Positioned.fill(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: _stackItem.backgroundColor,
                                          borderRadius:
                                              _stackItem.borderRadius != null
                                              ? BorderRadius.circular(
                                                  _stackItem.borderRadius!,
                                                )
                                              : null,
                                        ),
                                      ),
                                    ),
                                  // Картинка-фон тем же виджетом, что рисует
                                  // игра: автор обязан видеть то, что получит
                                  // игрок, — включая режим «мозаика».
                                  if (_stackItem.hasStackBackgroundImage)
                                    Positioned.fill(
                                      child: StackBackgroundFile(
                                        questId: widget.questId,
                                        source: _stackItem.stackBackgroundPath!,
                                        fit: _stackItem.stackBackgroundFit,
                                      ),
                                    ),
                                  // Сетка — под объектами и под осевыми
                                  // пунктирами: она ориентир, а не участник.
                                  if (_gridVisible)
                                    Positioned.fill(
                                      key: const ValueKey('stack_grid'),
                                      child: CustomPaint(
                                        painter: _StackGridPainter(
                                          step: _gridStep,
                                          color: scheme.onSurface.withOpacity(
                                            0.10,
                                          ),
                                          zoom: _fittedScale * _camera.scale,
                                        ),
                                      ),
                                    ),
                                  // Пунктир по центру
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    top: _stackHeight / 2 - 0.5,
                                    height: 1,
                                    child: CustomPaint(
                                      painter: _DashedLinePainter(
                                        color: Colors.white.withOpacity(0.12),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: _canvasWidth / 2 - 0.5,
                                    top: 0,
                                    width: 1,
                                    bottom: 0,
                                    child: CustomPaint(
                                      painter: _DashedLinePainter(
                                        color: Colors.white.withOpacity(0.12),
                                        vertical: true,
                                      ),
                                    ),
                                  ),
                                  // Дети стека — реальные виджеты
                                  ..._children.map((child) {
                                    final rect = _displayRect(child);
                                    if (rect.width <= 0 || rect.height <= 0) {
                                      return const SizedBox.shrink();
                                    }
                                    Widget box = paintStackChildBox(
                                      child,
                                      _buildChildWidget(
                                        child,
                                        _session.isSelected(child.id),
                                      ),
                                    );
                                    if (child.isHidden) {
                                      // Призрак: видно, где объект лежит, но
                                      // канвас его не трогает — скрытым правят
                                      // из панели слоёв.
                                      box = Opacity(
                                        opacity: 0.25,
                                        child: IgnorePointer(child: box),
                                      );
                                    }
                                    return Positioned(
                                      left: rect.left,
                                      top: rect.top,
                                      width: rect.width,
                                      height: rect.height,
                                      child: box,
                                    );
                                  }),
                                  // Служебный слой: линии прилипания, рамка
                                  // выделения и обводка объекта под курсором.
                                  // IgnorePointer — чтобы слой не съел жест драга.
                                  if (_guideX.isNotEmpty ||
                                      _guideY.isNotEmpty ||
                                      _measures.isNotEmpty ||
                                      _marqueeStart != null ||
                                      _hoverBox != null)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: CustomPaint(
                                          key: const ValueKey('stack_overlay'),
                                          painter: _OverlayPainter(
                                            guideX: _guideX,
                                            guideY: _guideY,
                                            measures: _measures,
                                            marquee: _marqueeRect,
                                            marqueeSubtract:
                                                _marqueeSubtractive,
                                            hover: _hoverBox?.rect,
                                            hoverRotation:
                                                _hoverBox?.rotation ?? 0,
                                            hoverScale: _hoverBox?.scale ?? 1,
                                            accent: const Color(0xFF26C6DA),
                                            zoom: _fittedScale * _camera.scale,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Край холста и зона отсечки — под линейками и ручками:
                // служебная разметка, которая ничего не перехватывает.
                _buildCanvasFrame(),

                // Ручка высоты холста. До ручек объектов: объект, лежащий на
                // кромке, всё равно должен хвататься за свои углы.
                ..._buildCanvasEdgeHandle(scheme),

                // Линейки и направляющие — поверх холста, но под ручками
                // объектов: схватить угол всегда важнее, чем подвинуть линию.
                ..._buildRulersAndGuides(scheme),

                // Ручки resize: для одного объекта — вокруг него, для группы
                // — вокруг ограничивающего rect'а, и тянут они всех детей.
                if (primary != null && selection.length == 1)
                  ..._buildHandles(primary, scheme)
                else if (selection.length > 1)
                  ..._buildGroupHandles(scheme),

                // Инфо-бар
                Positioned(
                  top: 0,
                  left: 0,
                  right: panelW,
                  child: SafeArea(
                    bottom: false,
                    child: Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh.withOpacity(0.92),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: scheme.outlineVariant.withOpacity(0.4),
                        ),
                      ),
                      child: LayoutBuilder(
                        builder: (context, box) {
                          // Цифры выделения: полями, если слой один и полоса
                          // довольно широкая, — иначе подписью.
                          final inlineRect = _inlineRect(
                            context,
                            primary,
                            selection.length,
                            box.maxWidth,
                          );
                          final actions = Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Быстрые триггеры выбранного объекта — те же
                              // иконки, что в списке детей и в карточке
                              // элемента ноды.
                              if (primary != null && selection.length == 1) ...[
                                TriggerSlotButtons(
                                  item: primary,
                                  compact: true,
                                  warningTooltip: stackChildPressWarning(
                                    stack: _stackItem,
                                    child: primary,
                                  ),
                                  onSlotTap: (slot) =>
                                      _itemHelper.onTriggerSlotTap(
                                        _session.indexOf(primary.id) ?? -1,
                                        slot,
                                      ),
                                  onSettings: () {
                                    final index = _session.indexOf(primary.id);
                                    if (index != null) {
                                      _openChildTriggers(index);
                                    }
                                  },
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip: tr('Свойства объекта'),
                                  iconSize: 20,
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.tune_rounded,
                                    color: scheme.primary,
                                  ),
                                  onPressed: () =>
                                      _openChildPropsSheet(primary),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip: tr('Переименовать слой'),
                                  iconSize: 20,
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.label_outline_rounded,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  onPressed: () =>
                                      _openRenameLayerSheet(primary),
                                ),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                '${(_camera.scale * 100).round()}%',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          );
                          return Row(
                            children: [
                              Icon(
                                primary != null
                                    ? Icons.ads_click_rounded
                                    : Icons.layers_rounded,
                                color: scheme.primary,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: inlineRect
                                    ? StackRectFields(
                                        key: ValueKey(
                                          'rect_fields_${primary!.id}',
                                        ),
                                        childId: primary.id,
                                        rect: _displayRect(primary),
                                        scheme: scheme,
                                        onChanged: (part, value) =>
                                            _commitRectPart(
                                              primary.id,
                                              part,
                                              value,
                                            ),
                                      )
                                    : Text(
                                        _statusLabel(primary, selection.length),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: scheme.onSurface,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                              ),
                              // Кнопки не должны выпихивать строку за край:
                              // с открытой панелью слоёв на телефоне им
                              // остаётся треть полосы, поэтому они едут по
                              // своей горизонтальной ленте.
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: box.maxWidth * 0.45,
                                ),
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: actions,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),

                // Панель выравнивания — пока есть что выравнивать. Поднята
                // над FAB: на узком телефоне они иначе перекрывались бы.
                // Правый край — за панелью слоёв, и вся лента скроллится:
                // кнопок больше, чем ширины экрана телефона.
                if (selection.isNotEmpty)
                  Positioned(
                    left: 16,
                    right: 16 + panelW,
                    bottom: 92,
                    child: _buildAlignBar(scheme, selection.length),
                  ),

                // FAB
                Positioned(
                  bottom: 24,
                  right: 16 + panelW,
                  child: Tooltip(
                    message: tr('Добавить слой: текст, картинка, кнопка…'),
                    child: FloatingActionButton(
                      heroTag: 'stack_canvas_add',
                      onPressed: _addNewItem,
                      backgroundColor: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                      child: const Icon(Icons.add_rounded),
                    ),
                  ),
                ),

                // Панель слоёв — поверх всего своего столбца.
                if (_layersOpen)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: panelW,
                    child: _buildLayersPanel(scheme),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Поля геометрии в строке статуса — вместо подписи с цифрами. На широкой
  /// полосе они влезают вместе с кнопками; на телефоне вытеснили бы их, и там
  /// точные значения правятся в шите свойств. Группу полями не правят: у неё
  /// общий ограничивающий rect, и куда ляжет ввод — непонятно.
  bool _inlineRect(
    BuildContext barContext,
    ContentItem? primary,
    int selectionCount,
    double barWidth,
  ) =>
      primary != null &&
      selectionCount == 1 &&
      barWidth >= 640 &&
      // Пока поверх канваса модальный шит, поля не нужны: в шите тот же ввод,
      // и два одинаковых поля X на экране путаются (и в тестах тоже).
      (ModalRoute.of(barContext)?.isCurrent ?? true);

  /// Строка статуса: выделение (с типом и геометрией) или сводка по стеку.
  String _statusLabel(ContentItem? primary, int selectionCount) {
    if (primary == null) {
      return trf('{p0} элементов · {p1}×{p2}', {'p0': _children.length, 'p1': _canvasWidth.round(), 'p2': _stackHeight.round()});
    }
    // Пока жест идёт, показываем живой rect, а не из модели: координаты
    // должны меняться под пальцем, иначе сверстать «на 8 px левее» по глазам
    // нельзя и приходится тягать ручку, глядя в панель свойств.
    final rect = _displayRect(primary);
    final type = _typeLabel(primary.type);
    final group = primary.groupName;
    final geometry =
        '$type · ${rect.left.round()}, ${rect.top.round()} · '
        '${rect.width.round()}×${rect.height.round()}';
    final tail = selectionCount > 1 ? trf(' · ещё {p0}', {'p0': selectionCount - 1}) : '';
    return group == null ? '$geometry$tail' : '$group · $geometry$tail';
  }

  /// Лента кнопок. Скроллится по горизонтали, как нижняя панель основного
  /// канваса: на телефоне одиннадцать кнопок не влезают и в половину ширины.
  Widget _buildAlignBar(ColorScheme scheme, int selectionCount) {
    final canDistribute = selectionCount >= 3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withOpacity(0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.4)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _alignButton(
              Icons.align_horizontal_left,
              tr('По левому краю'),
              () => _align(StackAlign.left),
            ),
            _alignButton(
              Icons.align_horizontal_center,
              tr('По центру по горизонтали'),
              () => _align(StackAlign.centerX),
            ),
            _alignButton(
              Icons.align_horizontal_right,
              tr('По правому краю'),
              () => _align(StackAlign.right),
            ),
            _alignButton(
              Icons.vertical_align_top,
              tr('По верхнему краю'),
              () => _align(StackAlign.top),
            ),
            _alignButton(
              Icons.align_vertical_center,
              tr('По центру по вертикали'),
              () => _align(StackAlign.centerY),
            ),
            _alignButton(
              Icons.vertical_align_bottom,
              tr('По нижнему краю'),
              () => _align(StackAlign.bottom),
            ),
            _alignButton(
              Icons.horizontal_distribute,
              canDistribute
                  ? tr('Равные промежутки по горизонтали')
                  : tr('Нужно минимум 3 объекта'),
              canDistribute ? () => _distribute(true) : null,
            ),
            _alignButton(
              Icons.vertical_distribute,
              canDistribute
                  ? tr('Равные промежутки по вертикали')
                  : tr('Нужно минимум 3 объекта'),
              canDistribute ? () => _distribute(false) : null,
            ),
            const SizedBox(width: 4),
            Container(width: 1, height: 22, color: scheme.outlineVariant),
            const SizedBox(width: 4),
            // Группы: слои с одним именем выделяются и двигаются как один.
            _alignButton(
              Icons.group_rounded,
              _session.canGroup
                  ? tr('Сгруппировать выделенные слои (Ctrl+G)')
                  : tr('Нужно минимум 2 объекта'),
              _session.canGroup ? () => _session.groupSelected() : null,
            ),
            _alignButton(
              Icons.group_off_rounded,
              _session.canUngroup
                  ? tr('Разгруппировать (Ctrl+Shift+G)')
                  : tr('В выделении нет групп'),
              _session.canUngroup ? _session.ungroupSelected : null,
            ),
            _alignButton(
              Icons.drive_file_rename_outline_rounded,
              _session.selectedGroupName == null
                  ? tr('Выделите слой из группы')
                  : tr('Переименовать группу'),
              _session.selectedGroupName == null
                  ? null
                  : () => _openRenameGroupSheet(_session.selectedGroupName!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _alignButton(IconData icon, String tooltip, VoidCallback? onPressed) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }

  // ── Панель слоёв ─────────────────────────────────────────────────

  /// Имя группы. «Группа 1» из Ctrl+G — заготовка: пока группу не назвал,
  /// она остаётся просто рамкой вокруг нескольких слоёв.
  void _openRenameGroupSheet(String current) {
    showEditorSheet<void>(
      context: context,
      builder: (ctx) => _NameSheet(
        current: current,
        title: tr('Имя группы'),
        caption:
            tr('Слои с одним именем выделяются и двигаются как один. Новое имя, совпавшее с другой группой, сливает их.'),
        hint: tr('Например: Шапка'),
        onSubmit: (name) {
          _session.renameGroup(current, name);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  /// Имя слоя — кнопкой в строке состояния, когда выделен один объект. Нужно
  /// панели слоёв: без имени десять строк подписаны «Картинка».
  void _openRenameLayerSheet(ContentItem child) {
    showEditorSheet<void>(
      context: context,
      builder: (ctx) => _NameSheet(
        current: child.layerName ?? '',
        title: tr('Имя слоя'),
        caption:
            tr('Видно только в редакторе: без имени панель подписывает слой по тексту или имени файла. Пустое имя снимает подпись — плеер имя не показывает вообще.'),
        hint: tr('Например: Кнопка «Далее»'),
        onSubmit: (name) {
          _session.renameLayer(child.id, name);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  /// Треть ширины, но не уже списка и не шире 300 px: на телефоне панель не
  /// должна съедать канвас, а на десктопе — превращаться в простыню.
  /// Ширина панели слоёв. Треть экрана — это 130 px на телефоне: четыре
  /// кнопки слоя плюс иконка типа оставляют подписи один знак, поэтому минимум
  /// 200 px. Больше 70 % ширина не берёт никогда — под панелью должен остаться
  /// холст, который двигают.
  static double _layersPanelWidth(double available) {
    final wanted = math.min(300.0, math.max(200.0, available * 0.35));
    return math.min(wanted, available * 0.7);
  }

  void _toggleChildHidden(ContentItem child) {
    _session.commitChild(
      child.id,
      (c) => c.copyWith(isHidden: !c.isHidden),
      kind: StackEditKind.style,
      label: tr('видимость'),
    );
  }

  /// Замок — только про выделение: блок не прячет слой и не влияет на плеер.
  /// Выделенный объект из выделения выпадает сам (см. _pruneSelection).
  void _toggleChildLocked(ContentItem child) {
    _session.commitChild(
      child.id,
      (c) => c.copyWith(locked: !c.locked),
      kind: StackEditKind.style,
      label: child.locked ? tr('замок снят') : tr('блокировка'),
    );
  }

  /// Подпись слоя: имя, заданное в редакторе, — иначе текст, имя картинки
  /// из библиотеки или тип объекта.
  String _layerLabel(ContentItem child) {
    final named = child.layerName?.trim();
    if (named != null && named.isNotEmpty) return named;
    final text = child.text?.trim();
    if (text != null && text.isNotEmpty) return text.split('\n').first;
    final label = _resourceLabel(child.resourcePath);
    if (label != null) return label;
    if (child.type == 'plugin') {
      // Имя типа живёт в манифесте плагина: «plugin» автору ничего не скажет.
      return findPluginContentType(ref, child.pluginTypeId)?.name ?? tr('Плагин');
    }
    return _typeLabel(child.type);
  }

  static IconData _layerIcon(String type) {
    switch (type) {
      case 'text':
        return Icons.text_fields_rounded;
      case 'image':
        return Icons.image_rounded;
      case 'button':
      case 'button_jump':
        return Icons.smart_button_rounded;
      case 'audio':
        return Icons.audiotrack_rounded;
      case 'row':
        return Icons.table_rows_rounded;
      case 'column':
        return Icons.view_column_rounded;
      case 'modal':
        return Icons.crop_square_rounded;
      case 'timer':
      case 'delay':
        return Icons.timer_rounded;
      case 'input':
        return Icons.edit_rounded;
      case 'script':
        return Icons.code_rounded;
      case 'plugin':
        return Icons.extension_rounded;
      default:
        return Icons.category_rounded;
    }
  }

  Widget _buildLayersPanel(ColorScheme scheme) {
    // Передний план — сверху списка, как в Figma: z-порядок в обратную сторону.
    final layers = _children.reversed.toList();
    // Потерянные слои считаем один раз на сборку панели: строка-подсказка
    // важнее, чем четыре значка, разбросанных по списку.
    final lostCount = layers
        .where((child) => _layerLostReason(child) != null)
        .length;
    // Material, а не Container с фоном: ListTile рисует выделение и чернила
    // на ближайшем Material, и декорированный фон съел бы их.
    return Material(
      color: scheme.surface.withOpacity(0.97),
      type: MaterialType.card,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant.withOpacity(0.5)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
              child: Row(
                children: [
                  Icon(Icons.layers_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trf('Слои · {p0}', {'p0': layers.length}),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Закрыть панель слоёв'),
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.close_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    onPressed: () => setState(() => _layersOpen = false),
                  ),
                ],
              ),
            ),
            if (lostCount > 0)
              Padding(
                key: const ValueKey('layers_lost_hint'),
                padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
                child: Text(
                  trf('{lostCount} {p0} не видно на холсте — тап по красному значку в строке вернёт слой в центр', {'lostCount': lostCount, 'p0': _layerWord(lostCount)}),
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFFE53935),
                  ),
                ),
              ),
            if (layers.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr('В стеке пока нет объектов.'),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            else
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: layers.length,
                  // Дефолтный грип ReorderableListView лёг бы перед иконкой
                  // типа и съел бы ширину подписи: в панели 180 px и так
                  // четыре кнопки. Порядок меняют долгим нажатием на строку.
                  buildDefaultDragHandles: false,
                  onReorderItem: _onLayerReorder,
                  itemBuilder: (context, i) =>
                      _buildLayerRow(scheme, layers[i], i, layers.length),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Перестановка слоя долгим нажатием. Индексы экранные (верхний слой
  /// первый), а z-порядок в модели растёт снизу вверх — список переворачиваем
  /// в обе стороны.
  void _onLayerReorder(int from, int to) {
    final order = _children.reversed.toList();
    // ReorderableListView отдаёт `to` уже для списка без перетаскиваемого
    // элемента, поэтому смещать ничего не нужно.
    final item = order.removeAt(from);
    order.insert(to, item);
    _session.commit(
      _stackItem.copyWith(children: order.reversed.toList()),
      kind: StackEditKind.reorder,
      label: tr('порядок слоёв'),
    );
  }

  /// Значок типа слоя; поверх — молния, если на слое висит скрипт или переход,
  /// и красный треугольник, если слой уехал в никуда.
  /// В строке и так четыре кнопки, поэтому не новая колонка, а наложение.
  Widget _layerLeading(
    ContentItem child, {
    required ColorScheme scheme,
    required bool selected,
    required Color muted,
  }) {
    final icon = Icon(
      _layerIcon(child.type),
      size: 18,
      color: selected ? scheme.primary : muted,
    );
    final wiring = _wiringOf(child);
    final lost = _layerLostReason(child);
    if (wiring.isEmpty && lost == null) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        if (wiring.isNotEmpty)
          Positioned(
            right: -3,
            bottom: -3,
            child: Tooltip(
              key: ValueKey('layer_wiring_${child.id}'),
              message: trf('На слое действие: {p0}', {'p0': wiring.join(' · ')}),
              child: _wiringBadge(child, size: 11),
            ),
          ),
        if (lost != null)
          Positioned(
            left: -3,
            top: -3,
            child: _lostLayerBadge(child, reason: lost),
          ),
      ],
    );
  }

  /// Почему слоя нет на холсте: схлопнутая рамка либо слой целиком за его
  /// краем. Нулевой размер — это и есть «добавил кнопку, сменил пресет, и она
  /// исчезла»: документ целый, а рисовать нечего.
  ///
  /// Правку в файл молча не пишем: находка должна быть видна автору, а
  /// лечение — его решением.
  ///
  /// Размер считаем из якорей с offset'ами, а не через `stackChildRect`:
  /// перевёрнутая рамка (right < left) в Rect.fromLTRB упёрлась бы в assert
  /// раньше, чем мы успели её показать.
  String? _layerLostReason(ContentItem child) {
    final width =
        (child.anchorRight - child.anchorLeft) * _canvasWidth +
        (child.offsetRight - child.offsetLeft);
    final height =
        (child.anchorBottom - child.anchorTop) * _stackHeight +
        (child.offsetBottom - child.offsetTop);
    if (width < 1 || height < 1) return tr('нулевой размер');
    final rect = child.stackChildRect(_canvasWidth, _stackHeight);
    if (!rect.overlaps(Rect.fromLTRB(0, 0, _canvasWidth, _stackHeight))) {
      return tr('за краем холста');
    }
    return null;
  }

  /// «1 слой не видно», «2 слоя», «5 слоёв».
  static String _layerWord(int n) => trp(['слой', 'слоя', 'слоёв'], n);

  /// Значок «слоя нет в кадре»: тап — вернуть размер и посадить в центр.
  Widget _lostLayerBadge(ContentItem child, {required String reason}) {
    return Tooltip(
      key: ValueKey('layer_lost_${child.id}'),
      waitDuration: const Duration(milliseconds: 300),
      message:
          trf('Слоя не видно на холсте: {reason}. Тап по значку — разместить по центру холста.', {'reason': reason}),
      child: InkWell(
        key: ValueKey('layer_lost_tap_${child.id}'),
        onTap: () => _restoreLayerGeometry(child.id),
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: 18,
          child: Center(
            child: Icon(
              Icons.error_rounded,
              size: 14,
              color: const Color(0xFFE53935),
            ),
          ),
        ),
      ),
    );
  }

  /// Лечение потерянного слоя: те же габариты, что у только что созданного, и
  /// центр холста. Якоря не трогаем — `stackChildWithRect` пересчитывает
  /// только offset'ы, поэтому слой с `anchor=1` останется прижат к правому
  /// краю, когда холст растянут.
  void _restoreLayerGeometry(String id) {
    final halfW = math.min(kStackNewChildHalfWidth, _canvasWidth / 2);
    final halfH = math.min(kStackNewChildHalfHeight, _stackHeight / 2);
    _session.commitChild(
      id,
      (child) => child.stackChildWithRect(
        Rect.fromCenter(
          center: Offset(_canvasWidth / 2, _stackHeight / 2),
          width: halfW * 2,
          height: halfH * 2,
        ),
        _canvasWidth,
        _stackHeight,
      ),
      kind: StackEditKind.resize,
      label: tr('разместить слой'),
    );
    _session.select(id);
  }

  Widget _buildLayerRow(
    ColorScheme scheme,
    ContentItem child,
    int index,
    int count,
  ) {
    final selected = _session.isSelected(child.id);
    final muted = child.isHidden ? scheme.outline : scheme.onSurfaceVariant;
    return ReorderableDelayedDragStartListener(
      key: ValueKey(child.id),
      index: index,
      child: ListTile(
        dense: true,
        minLeadingWidth: 20,
        // Поле подписи и так между иконкой типа и четырьмя кнопками;
        // дефолтные 16 px по краям съедали бы её на телефоне.
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        selected: selected,
        selectedTileColor: scheme.primaryContainer.withOpacity(0.24),
        onTap: () => _session.select(child.id),
        leading: _layerLeading(
          child,
          scheme: scheme,
          selected: selected,
          muted: muted,
        ),
        title: Text(
          _layerLabel(child),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: muted),
        ),
        // Имя группы — чтобы было видно, какие слои по клику сойдутся вместе.
        subtitle: child.groupName == null
            ? null
            : Text(
                child.groupName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: selected ? scheme.primary : scheme.outline,
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _layerAction(
              tooltip: child.locked
                  ? tr('Разблокировать слой: его снова можно выделить')
                  : tr('Заблокировать слой: не выделяется тапом, рамкой и Ctrl+A'),
              icon: child.locked ? Icons.lock_rounded : Icons.lock_open_rounded,
              color: child.locked ? scheme.primary : muted,
              onPressed: () => _toggleChildLocked(child),
            ),
            _layerAction(
              tooltip: child.isHidden ? tr('Показать слой') : tr('Скрыть слой'),
              icon: child.isHidden
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              color: muted,
              onPressed: () => _toggleChildHidden(child),
            ),
            _layerAction(
              tooltip: tr('На слой выше'),
              icon: Icons.arrow_upward_rounded,
              color: muted,
              onPressed: index > 0
                  ? () => _session.moveChild(child.id, forward: true)
                  : null,
            ),
            _layerAction(
              tooltip: tr('На слой ниже'),
              icon: Icons.arrow_downward_rounded,
              color: muted,
              onPressed: index < count - 1
                  ? () => _session.moveChild(child.id, forward: false)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// Кнопка слоя в панели. `IconButton` для этого не годится: у него
  /// минимальная площадка 48 px, и четыре такие кнопки в панели на 200 px не
  /// влезают — ListTile тогда ругается, что «хвост» съел всю ширину строки.
  /// Здесь ровно 24 px на кнопку, а подпись слоя важнее чернил под пальцем.
  Widget _layerAction({
    required String tooltip,
    required IconData icon,
    required Color color,
    VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: 24,
          child: Center(child: Icon(icon, size: 17, color: color)),
        ),
      ),
    );
  }

  // ── Действие слоя ────────────────────────────────────────────────

  /// Чем занят слой в рантайме: слоты скриптов и переход по тапу. Пусто —
  /// объект статичный, и значок на него вешать не за чем.
  ///
  /// `button_jump` не считаем: он переход по своей природе, иначе молния
  /// была бы на каждой такой кнопке.
  static List<String> _wiringOf(ContentItem child) => [
    for (final b in child.resolvedBehaviours)
      if (b.script.trim().isNotEmpty) b.event,
    if ((child.targetNodeId ?? '').trim().isNotEmpty &&
        child.type != 'button_jump')
      'переход',
  ];

  /// Молния у слоя: на канвасе объект со скриптом выглядит в точности как
  /// глухая надпись, а узнать правду раньше можно было только в списковом
  /// редакторе стека.
  Widget _wiringBadge(ContentItem child, {required double size}) {
    if (_wiringOf(child).isEmpty) return const SizedBox.shrink();
    return Icon(Icons.bolt_rounded, size: size, color: const Color(0xFFFFC400));
  }

  /// Значок на холсте — только рисунок: молния лежит в углу объекта, и
  /// перекрывать ей жест выделения нельзя, поэтому подсказки тут нет.
  Widget _wiringCanvasBadge(ContentItem child) {
    if (_wiringOf(child).isEmpty) return const SizedBox.shrink();
    return Positioned(
      right: -5,
      bottom: -5,
      child: IgnorePointer(
        child: DecoratedBox(
          key: ValueKey('wiring_${child.id}'),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.66),
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(2.5),
            child: _wiringBadge(child, size: 11),
          ),
        ),
      ),
    );
  }

  // ── Рендер детей стека — реальные Flutter-виджеты ────────────────

  /// Ребёнок стека — точно как в GameStackWidget._buildChild:
  /// Align(center) + DefaultTextStyle.merge(textAlign, fontFamily).
  /// NOT Positioned.fill — родитель уже задаёт размер через
  /// Positioned(left, top, width, height).
  Widget _buildChildWidget(ContentItem child, bool isSelected) {
    final String? inheritedFont = FontService.resolveFamily(
      widget.questId,
      child.fontFamily,
    );

    Widget content;
    if (child.type == 'image') {
      content = ImageItemWidget(
        item: child,
        questId: widget.questId,
        onInteract: (_) {},
        suppressInteractions: true,
        // То же решение, что в GameStackWidget: стек сам решает, скруглять
        // свои картинки. Раньше здесь жёстко стоял false, и в игре углы
        // скруглялись, а на канвасе — нет.
        roundedCornersOverride: _roundImages,
        boxFit: BoxFit.contain,
      );
    } else {
      content = _buildSimpleContent(child);
    }

    return Align(
      alignment: Alignment.center,
      child: DefaultTextStyle.merge(
        textAlign: TextAlign.center,
        style: TextStyle(fontFamily: inheritedFont),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            content,
            _wiringCanvasBadge(child),
            if (isSelected)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFF26C6DA),
                      width: 2.0,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Упрощённый рендер контента (без game-session колбэков).
  Widget _buildSimpleContent(ContentItem child) {
    switch (child.type) {
      case 'text':
        return _buildTextWidget(child);
      case 'button':
      case 'button_jump':
        return _buildButtonWidget(child);
      case 'audio':
        return _buildAudioWidget(child);
      case 'input':
        return _buildInputWidget(child);
      case 'modal':
        return _buildModalWidget(child);
      case 'timer':
      case 'delay':
        return _buildTimerWidget(child);
      case 'spacer':
        return _buildSpacerWidget(child);
      case 'row':
      case 'column':
        return _buildContainerWidget(child);
      default:
        return _buildGenericWidget(child);
    }
  }

  // ── Ручки resize (4 угла) ───────────────────────────────────────

  /// Квадратик ручки ресайза. Одиночный объект и группа пользуются одной
  /// ручкой — различаются только тем, что отдаёт координату старта:
  /// [_startDrag] или [_startGroupResize].
  Widget _resizeHandle({
    required String key,
    required Offset center,
    required ColorScheme scheme,
    required MouseCursor cursor,
    required void Function(Offset stackPos) onStart,
  }) {
    const hit = kStackHandleHit;
    return Positioned(
      left: center.dx - hit / 2,
      top: center.dy - hit / 2,
      width: hit,
      height: hit,
      child: MouseRegion(
        key: ValueKey('cursor_$key'),
        cursor: cursor,
        child: GestureDetector(
          key: ValueKey(key),
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => onStart(_screenToStack(d.globalPosition)),
          onPanUpdate: (d) {
            setState(() {
              _dragCurrentPos = _screenToStack(d.globalPosition);
              _updateDragDelta();
            });
          },
          onPanEnd: (_) => _endDrag(),
          onPanCancel: _endDrag,
          child: Center(
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: Colors.white, width: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Восемь ручек ресайза вокруг бокса: середины сторон идут первыми, углы —
  /// последними, чтобы на маленьком объекте (хит-зоны ручек там пересекаются)
  /// угол не отдавал жест стороне.
  ///
  /// Точки берёт [anchors], а не rect: у повёрнутого или масштабированного
  /// объекта ручка должна лежать на углу картинки, иначе она висит над
  /// пустотой, а жест тянет не то, что видно.
  List<Widget> _resizeHandles({
    required _BoxAnchors anchors,
    required ColorScheme scheme,
    required String prefix,
    required void Function(Offset stackPos, StackChildDragMode mode) onStart,
  }) {
    Widget handle(Offset center, StackChildDragMode mode) => _resizeHandle(
      key: '$prefix${mode.name}',
      center: center,
      scheme: scheme,
      cursor: mode.resizeCursor,
      onStart: (pos) => onStart(pos, mode),
    );
    return [
      handle(anchors.leftMid, StackChildDragMode.resizeLeft),
      handle(anchors.rightMid, StackChildDragMode.resizeRight),
      handle(anchors.topMid, StackChildDragMode.resizeTop),
      handle(anchors.bottomMid, StackChildDragMode.resizeBottom),
      handle(anchors.tl, StackChildDragMode.resizeTL),
      handle(anchors.tr, StackChildDragMode.resizeTR),
      handle(anchors.bl, StackChildDragMode.resizeBL),
      handle(anchors.br, StackChildDragMode.resizeBR),
    ];
  }

  /// Ручки ресайза группы — углы и середины сторон ограничивающего rect'а.
  /// Поворота тут нет: непонятно, вокруг чего вращать группу, а вот размер
  /// у общего bounding box смысл имеет.
  List<Widget> _buildGroupHandles(ColorScheme scheme) {
    final ids = _session.selection;
    final union = unionOfChildren(
      children: [
        for (final c in _children)
          if (ids.contains(c.id)) c,
      ],
      width: _canvasWidth,
      height: _stackHeight,
    );
    if (union == null) return const [];
    final screen = Rect.fromPoints(
      _stackToScreen(union.topLeft),
      _stackToScreen(union.bottomRight),
    );
    return [
      Positioned(
        left: screen.left,
        top: screen.top,
        width: screen.width,
        height: screen.height,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.primary.withOpacity(0.6)),
            ),
          ),
        ),
      ),
      ..._resizeHandles(
        anchors: _BoxAnchors.ofRect(screen),
        scheme: scheme,
        prefix: 'group_handle_',
        onStart: (pos, mode) => _startGroupResize(pos, mode),
      ),
    ];
  }

  List<Widget> _buildHandles(ContentItem child, ColorScheme scheme) {
    final id = child.id;
    final anchors = _anchorsOf(child);
    final rotate = _rotateAnchorOf(child);
    const hit = kStackHandleHit;
    const hs = 12.0;

    Widget rotateHandle() {
      // Угол считаем в координатах самой ручки: globalPosition пальца живёт
      // в окнах координатах (ниже на высоту AppBar), чем координаты Stack'а,
      // и смешение двух систем дало бы поворот «на глазок». Внутри ручки
      // обе точки в одной системе, а масштаб угла не меняет.
      final centerLocal =
          const Offset(hit / 2, hit / 2) + (rotate.center - rotate.anchor);
      return Positioned(
        key: ValueKey('rotate_handle_$id'),
        left: rotate.anchor.dx - hit / 2,
        top: rotate.anchor.dy - hit / 2,
        width: hit,
        height: hit,
        child: MouseRegion(
          key: ValueKey('cursor_rotate_handle_$id'),
          cursor: SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (d) => _rotateDownPos = d.localPosition,
            onPanStart: (d) => _startRotate(
              child,
              centerLocal,
              _rotateDownPos ?? d.localPosition,
            ),
            onPanUpdate: (d) => _updateRotate(
              d.localPosition,
              snapShift: HardwareKeyboard.instance.isShiftPressed,
            ),
            onPanEnd: (_) => _endRotate(),
            onPanCancel: _endRotate,
            child: Center(
              child: Container(
                width: hs,
                height: hs,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary,
                  border: Border.all(color: Colors.white, width: 1),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return [
      ..._resizeHandles(
        anchors: anchors,
        scheme: scheme,
        prefix: 'handle_$id-',
        onStart: (pos, mode) => _startDrag(child, pos, mode),
      ),
      // Ножка ручки поворота — чтобы было видно, вокруг чего вращение.
      _rotateStem(anchors.topMid, rotate.anchor, scheme),
      rotateHandle(),
      if (_rotateId == id && _rotateShownDegrees != null)
        Positioned(
          left: rotate.anchor.dx + hit / 2 + 4,
          top: rotate.anchor.dy - 10,
          child: Text(
            '${_rotateShownDegrees!.round()}°',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
    ];
  }

  /// Ножка от середины верхнего края до ручки поворота. Под поворотом она уже
  /// не вертикальна, поэтому это отрезок, а не box фиксированной высоты.
  Widget _rotateStem(Offset from, Offset to, ColorScheme scheme) {
    final bounds = Rect.fromPoints(from, to).inflate(1);
    return Positioned(
      left: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _StemPainter(
            from: from - bounds.topLeft,
            to: to - bounds.topLeft,
            color: scheme.primary.withOpacity(0.7),
          ),
        ),
      ),
    );
  }

  Widget _buildTextWidget(ContentItem child) {
    final text = child.text ?? '';
    if (text.isEmpty) {
      return Center(
        child: Text(
          tr('(пусто)'),
          style: TextStyle(color: Colors.white30, fontSize: 11),
        ),
      );
    }
    // Как в TextItemWidget: высота строки 1.35, размер берём из слоя. Обводка
    // тем же приёмом — штриховой слой под заливкой, поэтому превью и игра
    // показывают один и тот же контур.
    final base = TextStyle(
      color: Colors.white,
      fontSize: (child.textSize ?? 16.0).clamp(6.0, 200.0),
      height: 1.35,
    );
    final stroke = child.textOutlinePaint;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(child.padding ?? 0),
        child: stroke == null
            ? Text(
                text,
                textAlign: TextAlign.center,
                style: base,
                maxLines: null,
              )
            : Stack(
                // Clip.none: контур торчит за метрики глифов на полтолщины.
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.center,
                      child: Text(
                        text,
                        textAlign: TextAlign.center,
                        style: base.copyWith(foreground: stroke),
                        maxLines: null,
                      ),
                    ),
                  ),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: base,
                    maxLines: null,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildButtonWidget(ContentItem child) {
    final style = child.buttonStyle;
    final fillColor = style?.fillColor ?? const Color(0xFF1A2336);
    final borderColor = style?.borderColor ?? const Color(0xFF26C6DA);
    final textColor = style?.textColor ?? const Color(0xFF26C6DA);
    final borderRadius = style?.borderRadius ?? 8.0;

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(color: borderColor, width: 1.5),
        ),
        child: Text(
          child.buttonText ?? child.text ?? tr('Кнопка'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: textColor,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildAudioWidget(ContentItem child) {
    return Container(
      color: const Color(0xFF1E1E2E),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 8),
          Icon(Icons.audiotrack_rounded, color: Colors.white54, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              child.resourcePath ?? child.text ?? tr('Аудио'),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildInputWidget(ContentItem child) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit, color: Colors.white38, size: 14),
            const SizedBox(width: 6),
            Text(
              child.placeholderText ?? tr('Введите текст...'),
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModalWidget(ContentItem child) {
    final buttons = child.modalButtons;
    return Center(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.15), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              child.text ?? tr('Модальное окно'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (buttons != null && buttons.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                alignment: WrapAlignment.center,
                children: buttons
                    .map(
                      (b) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          b.text,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTimerWidget(ContentItem child) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, color: Colors.white54, size: 16),
            const SizedBox(width: 6),
            Text(
              trf('{p0}с', {'p0': child.text ?? '0'}),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpacerWidget(ContentItem child) {
    final size = (child.padding ?? 16.0).clamp(0.0, 999.0);
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          border: Border.all(
            color: Colors.white.withOpacity(0.15),
            width: 1,
            style: BorderStyle.solid,
          ),
        ),
        child: Center(
          child: Text(
            '${size.round()}px',
            style: const TextStyle(color: Colors.white30, fontSize: 9),
          ),
        ),
      ),
    );
  }

  Widget _buildContainerWidget(ContentItem child) {
    final label = child.type == 'row' ? tr('Ряд') : tr('Колонка');
    return Center(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ),
    );
  }

  Widget _buildGenericWidget(ContentItem child) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(8),
        color: const Color(0xFF1E1E1E),
        child: Text(
          child.type,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white30, fontSize: 11),
        ),
      ),
    );
  }

  static String _typeLabel(String type) {
    switch (type) {
      case 'text':
        return tr('Текст');
      case 'image':
        return tr('Изображение');
      case 'button':
      case 'button_jump':
        return tr('Кнопка');
      case 'audio':
        return tr('Аудио');
      case 'row':
        return tr('Ряд');
      case 'column':
        return tr('Колонка');
      case 'modal':
        return tr('Окно');
      case 'plugin':
        return tr('Плагин');
      default:
        return type;
    }
  }
}

// ================================================================
// Шит одного имени — группы или слоя. Контроллер живёт в State, а не в
// вызывающей функции: future от showEditorSheet стреляет в момент pop, и
// внешний контроллер disposal'ился бы на середине анимации закрытия — TextField
// перерисовался бы с уже мёртвым контроллером.
// ================================================================

class _NameSheet extends StatefulWidget {
  const _NameSheet({
    required this.current,
    required this.title,
    required this.caption,
    required this.hint,
    required this.onSubmit,
  });

  final String current;
  final String title;
  final String caption;
  final String hint;
  final ValueChanged<String> onSubmit;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            widget.caption,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: widget.onSubmit,
          ),
          Align(
            child: TextButton(
              onPressed: () => widget.onSubmit(_controller.text),
              child: Text(tr('Переименовать')),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// Служебный слой канваса: линии прилипания и рамка выделения.
// Рисуется внутри SizedBox(720×stackHeight), то есть в координатах
// стека — масштаб и pan до него доносит родительский Transform.
// ================================================================

/// Углы бокса в координатах оверлея — те, что остались после масштаба и
/// поворота, то есть там, где картинка на канвасе. Из них считают ручки,
/// ножку поворота и её хит-область.
class _BoxAnchors {
  const _BoxAnchors(this.tl, this.tr, this.br, this.bl);

  factory _BoxAnchors.ofRect(Rect r) =>
      _BoxAnchors(r.topLeft, r.topRight, r.bottomRight, r.bottomLeft);

  final Offset tl;
  final Offset tr;
  final Offset br;
  final Offset bl;

  Offset get leftMid => Offset.lerp(tl, bl, 0.5)!;
  Offset get rightMid => Offset.lerp(tr, br, 0.5)!;
  Offset get topMid => Offset.lerp(tl, tr, 0.5)!;
  Offset get bottomMid => Offset.lerp(bl, br, 0.5)!;
  Offset get center => (tl + tr + br + bl) / 4;

  /// «Наружу» от верхнего края — по этому вектору растёт ножка ручки поворота.
  /// У бокса нулевой высоты направления нет, берём вертикаль.
  Offset get up {
    final d = topMid - center;
    return d.distance > 1e-6 ? d / d.distance : const Offset(0, -1);
  }
}

/// Отрезок-ножка под ручкой поворота.
class _StemPainter extends CustomPainter {
  const _StemPainter({
    required this.from,
    required this.to,
    required this.color,
  });

  final Offset from;
  final Offset to;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      from,
      to,
      Paint()
        ..color = color
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_StemPainter old) =>
      old.from != from || old.to != to || old.color != color;
}

class _OverlayPainter extends CustomPainter {
  final List<double> guideX;
  final List<double> guideY;

  /// Зазоры вокруг тащимого объекта: подписанные отрезки от края до края, как
  /// в Figma. Без них «попасть в 16 px между двумя плашками» — работа вслепую.
  final List<StackMeasure> measures;
  final Rect? marquee;

  /// Объект под курсором: тонкая обводка, чтобы было видно, что возьмётся по
  /// клику, пока не кликнули. Обводится тот же бокс, что рисует
  /// `paintStackChildBox`, — с масштабом и поворотом.
  final Rect? hover;
  final double hoverRotation;
  final double hoverScale;
  final Color accent;

  /// Зум, с которым этот слой реально попадает на экран: линии рисуются не
  /// экраном, а масштабированным Transform, поэтому их толщину делим на зум —
  /// иначе при 25% guide превращается в полпикселя и исчезает.
  final double zoom;

  /// Alt+рамка вычитает из выделения: предпросмотр затемняет попавшие под
  /// рамку объекты белым, чтобы режим читался до отпускания пальца.
  final bool marqueeSubtract;

  _OverlayPainter({
    required this.guideX,
    required this.guideY,
    this.measures = const [],
    required this.marquee,
    this.hover,
    this.hoverRotation = 0,
    this.hoverScale = 1,
    this.marqueeSubtract = false,
    required this.accent,
    required this.zoom,
  });

  double get _hairline => zoom > 0 && zoom.isFinite ? 1 / zoom : 1;

  /// Толщина и кегль служебной графики: задаём в экранных px, потому что этот
  /// слой попадает на экран через Transform — иначе при 25% зума подпись
  /// превратилась бы в кашу, а при 400% — в гигантскую плашку.
  double _px(double screenPx) => screenPx * _hairline;

  @override
  void paint(Canvas canvas, Size size) {
    final hovered = hover;
    if (hovered != null) {
      final paint = Paint()
        ..color = accent.withOpacity(0.55)
        ..strokeWidth = _hairline
        ..style = PaintingStyle.stroke;
      if (hoverRotation == 0 && hoverScale == 1) {
        canvas.drawRect(hovered, paint);
      } else {
        // Те же два трансформация вокруг центра, что и у картинки: обводка
        // обязана облегать нарисованный объект, а не его модельный бокс.
        final s = hoverScale > 0 && hoverScale.isFinite ? hoverScale : 1.0;
        paint.strokeWidth = _hairline / s;
        canvas.save();
        canvas.translate(hovered.center.dx, hovered.center.dy);
        canvas.rotate(hoverRotation * math.pi / 180);
        canvas.scale(s);
        canvas.drawRect(
          Rect.fromLTWH(
            -hovered.width / 2,
            -hovered.height / 2,
            hovered.width,
            hovered.height,
          ),
          paint,
        );
        canvas.restore();
      }
    }
    if (marquee != null) {
      final subtract = marqueeSubtract;
      canvas.drawRect(
        marquee!,
        Paint()
          ..color = Color.alphaBlend(
            const Color(0xFFFFFFFF).withOpacity(subtract ? 0.35 : 0.0),
            accent.withOpacity(0.12),
          )
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        marquee!,
        Paint()
          ..color = subtract ? const Color(0xFFBDBDBD) : accent
          ..strokeWidth = _hairline
          ..style = PaintingStyle.stroke,
      );
    }
    final guidePaint = Paint()
      ..color = const Color(0xFFFF5252)
      ..strokeWidth = _hairline;
    for (final x in guideX) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), guidePaint);
    }
    for (final y in guideY) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guidePaint);
    }
    for (final m in measures) {
      _paintMeasure(canvas, m);
    }
  }

  /// Отрезок зазора с засечками на концах и подписью по середине.
  void _paintMeasure(Canvas canvas, StackMeasure m) {
    const color = Color(0xFFFFAB40);
    final paint = Paint()
      ..color = color
      ..strokeWidth = _px(1);
    final cap = _px(4);
    if (m.horizontal) {
      canvas.drawLine(Offset(m.from, m.line), Offset(m.to, m.line), paint);
      for (final x in [m.from, m.to]) {
        canvas.drawLine(
          Offset(x, m.line - cap),
          Offset(x, m.line + cap),
          paint,
        );
      }
    } else {
      canvas.drawLine(Offset(m.line, m.from), Offset(m.line, m.to), paint);
      for (final y in [m.from, m.to]) {
        canvas.drawLine(
          Offset(m.line - cap, y),
          Offset(m.line + cap, y),
          paint,
        );
      }
    }
    final label = TextPainter(
      text: TextSpan(
        text: m.gap.round().toString(),
        style: TextStyle(
          color: const Color(0xFF1C1B1F),
          fontSize: _px(11),
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = _px(2.5);
    final center = m.horizontal
        ? Offset((m.from + m.to) / 2, m.line)
        : Offset(m.line, (m.from + m.to) / 2);
    final background = Rect.fromCenter(
      center: center,
      width: label.width + pad * 2,
      height: label.height + pad * 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(background, Radius.circular(_px(3))),
      Paint()..color = color,
    );
    label.paint(canvas, background.topLeft + Offset(pad, pad));
  }

  @override
  bool shouldRepaint(_OverlayPainter oldDelegate) =>
      oldDelegate.guideX != guideX ||
      oldDelegate.guideY != guideY ||
      // Список пересобирается каждый кадр драга, так что сравнение по ссылке
      // здесь и нужно: совпавший список = ничего не изменилось.
      oldDelegate.measures != measures ||
      oldDelegate.marquee != marquee ||
      oldDelegate.hover != hover ||
      oldDelegate.zoom != zoom;
}

// ================================================================
// Сетка фона — рисует адаптивную сетку с учётом камеры.
// ================================================================

class _GridPainter extends CustomPainter {
  final CameraState camera;
  final Color gridColor;
  final Color backgroundColor;

  _GridPainter({
    required this.camera,
    required this.gridColor,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    const baseGridSize = 50.0;
    int lodLevel = 1;
    double currentGridSize = baseGridSize * camera.scale;
    while (currentGridSize < 20 && lodLevel < 100) {
      lodLevel *= 5;
      currentGridSize = baseGridSize * lodLevel * camera.scale;
    }
    if (currentGridSize < 5) return;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    final offsetX = camera.offset.dx % currentGridSize;
    final offsetY = camera.offset.dy % currentGridSize;

    for (double x = offsetX; x < size.width; x += currentGridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = offsetY; y < size.height; y += currentGridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => oldDelegate.camera != camera;
}

/// Сетка канваса: линии с шагом [step] в пикселях стека. Толщина — 1 экран-
/// пиксель, иначе на 500 % холст превратился бы в решето.
class _StackGridPainter extends CustomPainter {
  final double step;
  final Color color;
  final double zoom;

  _StackGridPainter({
    required this.step,
    required this.color,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (step <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = zoom > 0 && zoom.isFinite ? 1 / zoom : 1;
    for (double x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_StackGridPainter oldDelegate) =>
      oldDelegate.step != step ||
      oldDelegate.color != color ||
      oldDelegate.zoom != zoom;
}

// ================================================================
// Пунктирная линия.
// ================================================================

/// Разметка границы холста: всё, что лежит вне него, игра не покажет.
///
/// Полосы за краем закрашиваются редкой штриховкой, сам край — сплошная
/// линия, а слои, вылезшие за холст, — пунктиром в зоне отсечки: без этого
/// их вырезает `Clip.hardEdge`, и объект на канвасе просто исчезает.
class _StackCutPainter extends CustomPainter {
  _StackCutPainter({
    required this.canvasRect,
    required this.overhang,
    required this.edge,
  });

  final Rect canvasRect;
  final List<Rect> overhang;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(canvasRect);
    if (canvasRect.isEmpty) return;

    canvas.save();
    canvas.clipPath(outside);
    canvas.drawRect(Offset.zero & size, Paint()..color = edge.withOpacity(.07));
    final hatch = Paint()
      ..color = edge.withOpacity(.22)
      ..strokeWidth = 1;
    const step = 14.0;
    for (var x = -size.height; x < size.width; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        hatch,
      );
    }
    final ghost = Paint()
      ..color = edge.withOpacity(.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (final rect in overhang) {
      _paintDashedRect(canvas, rect, ghost);
    }
    canvas.restore();

    // Линию края рисуем поверх штриховки и чуть снаружи: ровно по границе её
    // съела бы полоса линейки, лежащая внутри холста.
    canvas.drawRect(
      canvasRect.inflate(1.5),
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _paintDashedRect(Canvas canvas, Rect rect, Paint paint) {
    const dash = 6.0;
    const gap = 4.0;
    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];
    for (var i = 0; i < 4; i++) {
      final start = corners[i];
      final end = corners[(i + 1) % 4];
      final vector = end - start;
      final length = vector.distance;
      if (length == 0) continue;
      final unit = vector / length;
      for (var d = 0.0; d < length; d += dash + gap) {
        canvas.drawLine(
          start + unit * d,
          start + unit * math.min(d + dash, length),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_StackCutPainter oldDelegate) =>
      oldDelegate.canvasRect != canvasRect ||
      oldDelegate.overhang != overhang ||
      oldDelegate.edge != edge;
}

class _DashedLinePainter extends CustomPainter {
  final Color color;
  final bool vertical;

  _DashedLinePainter({required this.color, this.vertical = false});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    if (vertical) {
      const dashH = 6.0;
      const gapH = 4.0;
      double y = 0;
      while (y < size.height) {
        final end = math.min(y + dashH, size.height);
        canvas.drawLine(Offset(0, y), Offset(0, end), paint);
        y += dashH + gapH;
      }
    } else {
      const dashW = 6.0;
      const gapW = 4.0;
      double x = 0;
      while (x < size.width) {
        final end = math.min(x + dashW, size.width);
        canvas.drawLine(Offset(x, 0), Offset(end, 0), paint);
        x += dashW + gapW;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.vertical != vertical;
}

// ================================================================
// Направляющие: состояние драга, линейки, сама линия.
// ================================================================

/// Один незавершённый жест с направляющей.
///
/// Позиция считается от точки захвата накопленным сдвигом, а не берётся из
/// курсора напрямую: pan-жест начинается после слопа в ~18 px, и «линия под
/// пальцем» на первом кадре прыгнула бы на половину порога.
class _GuideDrag {
  final bool vertical;

  /// Позиция линии, которую переставляют; null — линию вытягивают из линейки,
  /// в документе её ещё нет.
  final double? from;

  /// Ось точки захвата в стековых px и зум на момент старта: за время одного
  /// пальца камера не двигается, а без зума не перевести экранный сдвиг в
  /// стековые пиксели.
  final double startStack;
  final double zoom;

  double accum = 0;

  _GuideDrag({
    required this.vertical,
    required this.startStack,
    required this.zoom,
    this.from,
  });

  double get position => startStack + accum;

  /// Курсор вернулся в полосу линейки: для новой линии это отмена жеста, для
  /// существующей — удаление.
  bool get overRuler => position * zoom <= kStackRulerThickness;
}

class _StackRulerPainter extends CustomPainter {
  /// true — вертикальная линейка у левого края (отсчитывает x).
  final bool vertical;

  /// Длина холста по этой оси, в стековых px.
  final double canvasSize;
  final double zoom;
  final Color tick;
  final Color label;
  final Color background;
  final Color border;

  /// Участки полосы, под которыми лежит слой (локальные координаты полосы).
  /// Над ними подложка уводится в дымку, чтобы линейка не прятала картинку.
  final List<Rect> contentGaps;

  _StackRulerPainter({
    required this.vertical,
    required this.canvasSize,
    required this.zoom,
    required this.tick,
    required this.label,
    required this.background,
    required this.border,
    required this.contentGaps,
  });

  /// Шаг деления: подписи не должны сливаться в кашу при 25% зума.
  static const List<double> _steps = [10, 20, 50, 100, 200, 400];

  double get _unit {
    for (final step in _steps) {
      if (step * zoom >= 26) return step;
    }
    return _steps.last;
  }

  /// Деления растут от края, обращённого в холст: ноль линейки сидит на нуле
  /// координат, и штрих у того же края читается как продолжение оси.
  static const double _minorTick = 4;
  static const double _majorTick = 8;

  @override
  void paint(Canvas canvas, Size size) {
    _paintScrim(canvas, size);

    final tickPaint = Paint()
      ..color = tick
      ..strokeWidth = 1;
    final axis = vertical ? size.height : size.width;
    final unit = _unit;
    for (var v = 0.0; v <= canvasSize; v += unit) {
      final at = v * zoom;
      if (at > axis) break;
      final signed = (v / unit).round() % 5 == 0;
      _drawTick(canvas, size, at, signed ? _majorTick : _minorTick, tickPaint);
      if (signed) _drawLabel(canvas, size, v, at);
    }

    canvas.drawLine(
      vertical ? Offset(size.width, 0) : Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()
        ..color = border
        ..strokeWidth = 1,
    );
  }

  /// Подложка полосы. Над пустым холстом она плотная — иначе деления и числа
  /// не читаются. Там, где под линейкой лежит слой, плотность падает втрое:
  /// автор придвинул картинку к краю и должен видеть её, а не серую полосу.
  void _paintScrim(Canvas canvas, Size size) {
    final band = Offset.zero & size;
    if (contentGaps.isEmpty) {
      canvas.drawRect(band, Paint()..color = background);
      return;
    }
    var solid = Path()..addRect(band);
    final holes = Path();
    for (final gap in contentGaps) {
      holes.addRect(gap);
    }
    solid = Path.combine(PathOperation.difference, solid, holes);
    canvas.save();
    canvas.clipPath(solid);
    canvas.drawRect(band, Paint()..color = background);
    canvas.restore();
    final haze = Paint()
      ..color = background.withOpacity(background.opacity / 3);
    for (final gap in contentGaps) {
      canvas.drawRect(gap, haze);
    }
  }

  void _drawTick(
    Canvas canvas,
    Size size,
    double at,
    double length,
    Paint paint,
  ) {
    if (vertical) {
      canvas.drawLine(
        Offset(size.width - length, at),
        Offset(size.width, at),
        paint,
      );
    } else {
      canvas.drawLine(
        Offset(at, size.height - length),
        Offset(at, size.height),
        paint,
      );
    }
  }

  void _drawLabel(Canvas canvas, Size size, double value, double at) {
    final text = TextPainter(
      text: TextSpan(
        text: value.round().toString(),
        style: TextStyle(color: label, fontSize: 9, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (vertical) {
      // Числа на узкой полосе влезают только повёрнутыми.
      canvas.save();
      canvas.translate(size.width - _majorTick - 1, at + 2);
      canvas.rotate(math.pi / 2);
      text.paint(canvas, Offset.zero);
      canvas.restore();
    } else {
      text.paint(canvas, Offset(at + 2, 1));
    }
    text.dispose();
  }

  @override
  bool shouldRepaint(_StackRulerPainter oldDelegate) =>
      oldDelegate.vertical != vertical ||
      oldDelegate.canvasSize != canvasSize ||
      oldDelegate.zoom != zoom ||
      oldDelegate.tick != tick ||
      oldDelegate.label != label ||
      !_sameGaps(oldDelegate.contentGaps);

  /// Список новых rect'ов на каждый кадр — лишнее; сравниваем содержимое.
  bool _sameGaps(List<Rect> other) {
    if (other.length != contentGaps.length) return false;
    for (var i = 0; i < contentGaps.length; i++) {
      if (other[i] != contentGaps[i]) return false;
    }
    return true;
  }
}

class _StackGuidePainter extends CustomPainter {
  final bool vertical;
  final double thickness;
  final Color color;

  /// Позиция в px — только пока линию тащат, чтобы не шуметь на канвасе.
  final String? label;
  final Color labelColor;

  _StackGuidePainter({
    required this.vertical,
    required this.thickness,
    required this.color,
    this.label,
    this.labelColor = const Color(0xFFFFFFFF),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness;
    final at = vertical ? size.width / 2 : size.height / 2;
    canvas.drawLine(
      vertical ? Offset(at, 0) : Offset(0, at),
      vertical ? Offset(at, size.height) : Offset(size.width, at),
      paint,
    );

    final text = label;
    if (text == null) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: labelColor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1,
          background: Paint()..color = color.withOpacity(0.15),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      vertical
          ? Offset(at + 2, math.min(2, size.height - tp.height))
          : Offset(math.min(at + 4, size.width - tp.width), at - tp.height - 1),
    );
    tp.dispose();
  }

  @override
  bool shouldRepaint(_StackGuidePainter oldDelegate) =>
      oldDelegate.vertical != vertical ||
      oldDelegate.thickness != thickness ||
      oldDelegate.color != color ||
      oldDelegate.label != label;
}
