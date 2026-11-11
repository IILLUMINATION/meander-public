
import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';

// ================================================================
// === СЕМАНТИЧЕСКИЕ РОЛИ ЦВЕТА НОДЫ (Material 3) ===
// Нода больше не хранит «сырой» ARGB. Вместо этого она ссылается на
// роль из ColorScheme. Реальный цвет вычисляется из текущей темы в
// момент отрисовки — это гарантирует, что нода всегда в гамме темы
// и перекрашивается при смене темы.
// ================================================================
enum NodeColorRole {
  surface, // нейтральная (по умолчанию)
  primary,
  secondary,
  tertiary,
  error,
}

// ================================================================
// === ТЕМА ХОЛСТА (токены цветов для CustomPainter) ===
// CustomPainter не имеет доступа к BuildContext, поэтому экран
// обновляет эти значения из ColorScheme в каждом build().
// ================================================================
class CanvasTheme {
  // --- Контейнеры ролей нод (filled-card M3) ---
  static Color roleSurfaceContainer = const Color(0xFF242424);
  static Color roleSurfaceOn = Colors.white;
  static Color rolePrimaryContainer = const Color(0xFF004A77);
  static Color rolePrimaryOn = Colors.white;
  static Color roleSecondaryContainer = const Color(0xFF3F4759);
  static Color roleSecondaryOn = Colors.white;
  static Color roleTertiaryContainer = const Color(0xFF5C3F5C);
  static Color roleTertiaryOn = Colors.white;
  static Color roleErrorContainer = const Color(0xFF8C1D18);
  static Color roleErrorOn = Colors.white;

  /// Возвращает цвет-контейнер шапки для роли.
  static Color containerForRole(NodeColorRole role) {
    switch (role) {
      case NodeColorRole.surface:
        return roleSurfaceContainer;
      case NodeColorRole.primary:
        return rolePrimaryContainer;
      case NodeColorRole.secondary:
        return roleSecondaryContainer;
      case NodeColorRole.tertiary:
        return roleTertiaryContainer;
      case NodeColorRole.error:
        return roleErrorContainer;
    }
  }

  /// Возвращает контрастный «on»-цвет для роли (текст на шапке).
  static Color onContainerForRole(NodeColorRole role) {
    switch (role) {
      case NodeColorRole.surface:
        return roleSurfaceOn;
      case NodeColorRole.primary:
        return rolePrimaryOn;
      case NodeColorRole.secondary:
        return roleSecondaryOn;
      case NodeColorRole.tertiary:
        return roleTertiaryOn;
      case NodeColorRole.error:
        return roleErrorOn;
    }
  }

  /// Текущая яркость активной темы (для генерации тональных контейнеров).
  static Brightness brightness = Brightness.dark;

  /// Кэш сгенерированных тональных схем по seed-цвету, чтобы не пересчитывать
  /// палитру на каждый кадр отрисовки.
  static final Map<int, ColorScheme> _tonalCache = {};

  static ColorScheme _tonalSchemeFor(Color seed) {
    final key = (seed.value * 31) ^ brightness.index;
    return _tonalCache.putIfAbsent(
      key,
      () => ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
    );
  }

  /// Гармоничный M3-контейнер для произвольного seed-цвета. В отличие от
  /// 5 фиксированных ролей (производных от одного seed темы) это даёт
  /// РАЗНООБРАЗНЫЕ, но всё ещё тональные (не кислотные) цвета, адаптивные
  /// к light/dark.
  static Color tonalContainerFor(Color seed) =>
      _tonalSchemeFor(seed).primaryContainer;

  /// Контрастный «on»-цвет для [tonalContainerFor].
  static Color onTonalContainerFor(Color seed) =>
      _tonalSchemeFor(seed).onPrimaryContainer;

  static Color background = const Color(0xFF1A1A1A);
  static Color grid = const Color(0xFF2F2F2F);
  static Color nodeBody = const Color(0xFF1E1E1E);
  static Color nodeHeader = const Color(0xFF242424);
  static Color nodeBorder = const Color(0xFF343434);
  static Color nodeBorderHovered = const Color(0xFF8A8A8A);
  static Color nodeTitle = Colors.white;
  static Color nodePreview = const Color(0xB3FFFFFF);
  static Color anchorBorder = Colors.white;
  static Color accent = Colors.orange;
  static Color accentTarget = Colors.greenAccent;
  static Color shadow = const Color(0x33000000);
  static Color surface = const Color(0xFF1A1A1A);
  static Color commentBody = const Color(0xFF2A2A1E);
  static Color commentText = Colors.white;

  /// Семейство шрифта подписей на холсте. `null` — системное по умолчанию.
  /// Тесты подставляют загруженный шрифт: иначе Flutter рисует заглушки Ahem,
  /// и снимок карточки не показывает, влезает ли текст.
  static String? cardFontFamily;
  static Color selection = Colors.blue;
  static bool isDark = true;

  // --- Цвета связей (берутся из темы) ---
  static Color connectionContent = const Color(0xFF8FB6E0);
  static Color connectionTimer = const Color(0xFFE0C46C);
  static Color connectionScript = const Color(0xFFB39DDB);

  static void update(ColorScheme scheme) {
    isDark = scheme.brightness == Brightness.dark;
    brightness = scheme.brightness;
    background = scheme.surface;
    surface = scheme.surface;
    grid = Color.lerp(scheme.surface, scheme.onSurface, 0.12) ?? scheme.onSurface;
    nodeBody = scheme.surfaceContainerHigh;
    nodeHeader = scheme.surfaceContainerHighest;
    nodeBorder = scheme.outlineVariant;
    nodeBorderHovered = scheme.primary;
    nodeTitle = scheme.onSurface;
    nodePreview = scheme.onSurfaceVariant;
    anchorBorder = scheme.surface;
    accent = scheme.primary;
    accentTarget = scheme.tertiary;
    // Тени в «трушном» M3 на холсте не используем — глубину даёт тон
    // поверхности (surfaceContainer-уровни), а не drop shadow.
    shadow = const Color(0x00000000);
    // Заметка — нейтральная «бумага» (surfaceContainerHigh), а не
    // цветной secondaryContainer (который на тёплых темах болотится).
    commentBody = scheme.surfaceContainerHigh;
    commentText = scheme.onSurface;
    selection = scheme.primary;

    // --- Роли цвета нод: семантические M3-контейнеры ---
    roleSurfaceContainer = scheme.surfaceContainerHighest;
    roleSurfaceOn = scheme.onSurface;
    rolePrimaryContainer = scheme.primaryContainer;
    rolePrimaryOn = scheme.onPrimaryContainer;
    roleSecondaryContainer = scheme.secondaryContainer;
    roleSecondaryOn = scheme.onSecondaryContainer;
    roleTertiaryContainer = scheme.tertiaryContainer;
    roleTertiaryOn = scheme.onTertiaryContainer;
    roleErrorContainer = scheme.errorContainer;
    roleErrorOn = scheme.onErrorContainer;

    // --- Связи: приглушённо, в гамме темы ---
    connectionContent = scheme.outline;
    connectionTimer = scheme.tertiary;
    connectionScript = scheme.secondary;
  }
}

// ================================================================
// === ОБРАТНАЯ СОВМЕСТИМОСТЬ: маппинг старых ARGB-цветов нод на роли ===
// Старые квесты хранят node.color как «сырой» ARGB (из прежней
// палитры NodeColors). Чтобы они не выглядели кислотно, переводим
// сохранённый цвет в ближайшую семантическую роль по оттенку (hue).
// ================================================================
NodeColorRole nodeColorRoleFromLegacyColor(Color color) {
  final hsl = HSLColor.fromColor(color);
  // Очень тёмные/серые цвета (старый «dark») → нейтральная роль.
  if (hsl.saturation < 0.15 || hsl.lightness < 0.18) {
    return NodeColorRole.surface;
  }
  final hue = hsl.hue;
  // Красные/розовые → error.
  if (hue < 20 || hue >= 330) return NodeColorRole.error;
  // Оранжевые/жёлтые/янтарные → tertiary.
  if (hue < 70) return NodeColorRole.tertiary;
  // Зелёные/бирюзовые → secondary.
  if (hue < 200) return NodeColorRole.secondary;
  // Синие/голубые/фиолетовые → primary.
  return NodeColorRole.primary;
}

// ================================================================
// === МОДЕЛЬ НОДЫ (для UI) ===
// ================================================================
/// Компактное содержимое ноды из индекса канваса.
///
/// Канвас не читает тела нод: `quests/<id>/nodes/index.json` несёт готовые
/// строки реплик и подписи кнопок. Здесь они приводятся к виду, который
/// нужен карточке, — без повторного обхода `content.items`.
class NodeCardPreview {
  const NodeCardPreview({
    this.lines = const [],
    this.branches = const [],
    this.branchTotal = 0,
    this.replies = 0,
    this.scripts = 0,
    this.hasImage = false,
    this.hasAudio = false,
  });

  /// Реплики (уже обрезанные по длине строки).
  final List<String> lines;

  /// Подписи первых кнопок; полное число — [branchTotal].
  final List<String> branches;
  final int branchTotal;
  final int replies;
  final int scripts;
  final bool hasImage;
  final bool hasAudio;

  static NodeCardPreview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final branches = (raw['branches'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList();
    return NodeCardPreview(
      lines: (raw['lines'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      branches: List<String>.unmodifiable(branches),
      branchTotal: ((raw['branchesTotal'] as num?)?.toInt() ?? branches.length),
      replies: (raw['replies'] as num?)?.toInt() ?? 0,
      scripts: (raw['scripts'] as num?)?.toInt() ?? 0,
      hasImage: ((raw['images'] as num?)?.toInt() ?? 0) > 0,
      hasAudio: ((raw['audio'] as num?)?.toInt() ?? 0) > 0,
    );
  }
}

class Node {
  String id;
  String? chapterId;
  Offset position;
  Size size;
  Color color;
  String label;
  String description;
  Map<String, dynamic>? content;

  /// Готовое превью из индекса. Если задано, обход [content] не нужен.
  NodeCardPreview? preview;
  String? backgroundAssetId;
  String? backgroundAudioId;
  double? backgroundAudioVolume;
  String? scriptAssetId;
  double? timerDuration;
  String? defaultActionNodeId;
  bool? timerHidden;
  bool isStartNode;

  // --- Кеш подписей карточки ---
  //
  // Тело карточки рисуется каждый кадр, поэтому всё, что дороже `paint`,
  // кешируется на ноде: строки реплик, подписи веток и разложенные
  // `TextPainter`. Ключ кеша строк — ширина, цвет и их число: ширина ноды
  // постоянна, а число строк художник выбирает под высоту карточки и бюджет
  // кадра.
  TextPainter? _titlePainter;
  double _titleWidth = -1;
  int _titleColor = 0;
  List<TextPainter> _bodyPainters = const [];
  double _bodyWidth = -1;
  int _bodyPaintersCount = -1;
  int _bodyPaintersColor = 0;
  List<TextPainter> _chipPainters = const [];
  double _chipsWidth = -1;
  int _chipsCount = -1;
  int _chipsColor = 0;
  TextPainter? _countersPainter;
  double _countersWidth = -1;
  int _countersColor = 0;
  bool _titleDirty = true;
  bool _bodyDirty = true;

  List<String>? _textLines;
  List<String>? _branchLabels;
  int _branchTotal = 0;
  String? _countersLabel;
  int _replyCount = 0;
  int _scriptCount = 0;
  bool _hasImageItem = false;
  bool _hasAudioItem = false;

  /// Отступ справа в шапке под иконки-индикаторы. Ставит художник: подпись
  /// рисуется отдельным проходом (после тела), и ей нужно знать, сколько места
  /// заняли иконки.
  double headerRightInset = 0;

  Node({
    required this.id,
    this.chapterId,
    required this.position,
    this.size = const Size(150, 150),
    required this.color,
    required this.label,
    required this.description,
    this.content,
    this.preview,
    this.backgroundAssetId,
    this.backgroundAudioId,
    this.backgroundAudioVolume,
    this.scriptAssetId,
    this.timerDuration,
    this.defaultActionNodeId,
    this.timerHidden,
    this.isStartNode = false,
  });

  Rect get rect =>
      Rect.fromCenter(center: position, width: size.width, height: size.height);
  Offset get topAnchor => Offset(position.dx, position.dy - size.height / 2);
  Offset get bottomAnchor => Offset(position.dx, position.dy + size.height / 2);
  Offset get leftAnchor => Offset(position.dx - size.width / 2, position.dy);
  Offset get rightAnchor => Offset(position.dx + size.width / 2, position.dy);

  Offset getClosestAnchor(Offset point) {
    final anchors = [topAnchor, bottomAnchor, leftAnchor, rightAnchor];
    double minDist = double.infinity;
    Offset closest = position;
    for (final anchor in anchors) {
      final dist = (anchor - point).distance;
      if (dist < minDist) {
        minDist = dist;
        closest = anchor;
      }
    }
    return closest;
  }

  Node copyWith({
    String? id,
    String? chapterId,
    Offset? position,
    Size? size,
    Color? color,
    String? label,
    String? description,
    Map<String, dynamic>? content,
    NodeCardPreview? preview,
    String? backgroundAssetId,
    String? backgroundAudioId,
    double? backgroundAudioVolume,
    String? scriptAssetId,
    double? timerDuration,
    String? defaultActionNodeId,
    bool? timerHidden,
    bool? isStartNode,
  }) {
    return Node(
      id: id ?? this.id,
      chapterId: chapterId ?? this.chapterId,
      position: position ?? this.position,
      size: size ?? this.size,
      color: color ?? this.color,
      label: label ?? this.label,
      description: description ?? this.description,
      content: content ?? this.content,
      preview: preview ?? this.preview,
      backgroundAssetId: backgroundAssetId ?? this.backgroundAssetId,
      backgroundAudioId: backgroundAudioId ?? this.backgroundAudioId,
      backgroundAudioVolume:
          backgroundAudioVolume ?? this.backgroundAudioVolume,
      scriptAssetId: scriptAssetId ?? this.scriptAssetId,
      timerDuration: timerDuration ?? this.timerDuration,
      defaultActionNodeId: defaultActionNodeId ?? this.defaultActionNodeId,
      timerHidden: timerHidden ?? this.timerHidden,
      isStartNode: isStartNode ?? this.isStartNode,
    );
  }

  /// Реплики ноды в порядке показа — включая вложенные в row/column.
  List<String> get textLines {
    _ensureSummary();
    return _textLines!;
  }

  /// Подписи кнопок-веток: «→ Во двор».
  List<String> get branchLabels {
    _ensureSummary();
    return _branchLabels!;
  }

  int get replyCount {
    _ensureSummary();
    return _replyCount;
  }

  /// Полное число кнопок-веток: рисуем не все, но счётчик должен быть честным.
  int get branchTotal {
    _ensureSummary();
    return _branchTotal;
  }

  int get scriptCount {
    _ensureSummary();
    return _scriptCount;
  }

  bool get hasImageItem {
    _ensureSummary();
    return _hasImageItem;
  }

  bool get hasAudioItem {
    _ensureSummary();
    return _hasAudioItem;
  }

  /// Сводка состава для нижней строки карточки.
  String get countersLabel {
    if (_countersLabel != null) return _countersLabel!;
    final parts = <String>[];
    if (replyCount > 0) {
      parts.add('$replyCount ${trp(['реплика', 'реплики', 'реплик'], replyCount)}');
    }
    final branches = _branchTotal;
    if (branches > 0) {
      parts.add('$branches ${trp(['ветка', 'ветки', 'веток'], branches)}');
    }
    _countersLabel = parts.join(' · ');
    return _countersLabel!;
  }

  /// Собирает текст, ветки и счётчики одним обходом контента.
  ///
  /// Идём по `row`/`column` рекурсивно: текст у авторов живёт во вложенных
  /// контейнерах, и плоский обход верхнего уровня показывал пустую карточку
  /// при полной сцене.
  void _ensureSummary() {
    if (_textLines != null) return;

    // Превью из индекса уже содержит строки и счётчики: канвас не читает
    // тела нод, поэтому обход `content` здесь — только для старых данных.
    final preview = this.preview;
    if (preview != null) {
      final lines = List<String>.of(preview.lines);
      if (lines.isEmpty) _appendLines(lines, description);
      var scripts = preview.scripts;
      if ((scriptAssetId ?? '').trim().isNotEmpty) scripts++;
      _textLines = lines;
      _branchLabels = preview.branches;
      _branchTotal = preview.branchTotal > 0
          ? preview.branchTotal
          : preview.branches.length;
      _replyCount = preview.replies;
      _scriptCount = scripts;
      _hasImageItem = preview.hasImage;
      _hasAudioItem = preview.hasAudio;
      return;
    }

    final lines = <String>[];
    final branches = <String>[];
    var replies = 0;
    var scripts = 0;
    var hasImage = false;
    var hasAudio = false;

    void walk(List<dynamic> items) {
      for (final raw in items) {
        if (raw is! Map) continue;
        final type = raw['type'];
        final text = (raw['text'] as String? ?? '').trim();
        switch (type) {
          case 'text':
            replies++;
            _appendLines(lines, text);
          case 'chat':
            replies++;
            final sender = (raw['senderName'] as String? ?? '').trim();
            _appendLines(lines, sender.isEmpty ? text : '$sender: $text');
          case 'input':
            replies++;
            _appendLines(lines, text);
          case 'button':
            if (text.isNotEmpty) branches.add(text);
          case 'script':
            scripts++;
          case 'image':
            hasImage = true;
          case 'audio':
            hasAudio = true;
        }
        final children = raw['children'];
        if (children is List) walk(children);
      }
    }

    final items = content?['items'];
    if (items is List) walk(items);
    if (lines.isEmpty) _appendLines(lines, description);
    if ((scriptAssetId ?? '').trim().isNotEmpty) scripts++;

    _textLines = lines;
    _branchLabels = branches;
    _branchTotal = branches.length;
    _replyCount = replies;
    _scriptCount = scripts;
    _hasImageItem = hasImage;
    _hasAudioItem = hasAudio;
  }

  static void _appendLines(List<String> target, String text) {
    if (text.isEmpty) return;
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) target.add(trimmed);
    }
  }

  /// Заголовок в шапке. Кешируется вместе с цветом: цвет меняется при смене
  /// темы и затемнении поиском, и тогда текст надо переложить один раз.
  TextPainter titlePainterFor(double maxWidth, {required Color color}) {
    if (!_titleDirty &&
        _titlePainter != null &&
        _titleWidth == maxWidth &&
        _titleColor == color.value) {
      return _titlePainter!;
    }
    _titlePainter?.dispose();
    _titlePainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 14,
          height: 1.15,
          fontWeight: FontWeight.w700,
          fontFamily: CanvasTheme.cardFontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    _titleWidth = maxWidth;
    _titleColor = color.value;
    _titleDirty = false;
    return _titlePainter!;
  }

  /// Подписи веток: «→ текст кнопки», по одной на чип.
  List<TextPainter> chipPainters(
    double maxWidth,
    int count, {
    required Color color,
  }) {
    final shown = count < branchLabels.length ? count : branchLabels.length;
    if (_chipsWidth == maxWidth &&
        _chipsCount == shown &&
        _chipsColor == color.value) {
      return _chipPainters;
    }
    for (final painter in _chipPainters) {
      painter.dispose();
    }
    _chipPainters = [
      for (final label in branchLabels.take(shown))
        TextPainter(
          text: TextSpan(
            text: '→ $label',
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontFamily: CanvasTheme.cardFontFamily,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: maxWidth - 16),
    ];
    _chipsWidth = maxWidth;
    _chipsCount = shown;
    _chipsColor = color.value;
    return _chipPainters;
  }

  /// Сводка состава ноды: «5 реплик · 2 ветки».
  TextPainter countersPainter(
    double maxWidth, {
    required Color color,
  }) {
    final cached = _countersPainter;
    if (cached != null &&
        _countersWidth == maxWidth &&
        _countersColor == color.value) {
      return cached;
    }
    cached?.dispose();
    _countersPainter = TextPainter(
      text: TextSpan(
        text: countersLabel,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontFamily: CanvasTheme.cardFontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    _countersWidth = maxWidth;
    _countersColor = color.value;
    return _countersPainter!;
  }

  /// Разложенные строки тела — не больше [maxLines], с кешем по ширине/цвету.
  List<TextPainter> bodyPainters(
    double maxWidth,
    int maxLines, {
    required Color color,
  }) {
    final count = maxLines < textLines.length ? maxLines : textLines.length;
    if (!_bodyDirty &&
        _bodyWidth == maxWidth &&
        _bodyPaintersCount == count &&
        _bodyPaintersColor == color.value) {
      return _bodyPainters;
    }
    for (final painter in _bodyPainters) {
      painter.dispose();
    }
    _bodyPainters = [
      for (final line in textLines.take(count))
        TextPainter(
          text: TextSpan(
            text: line,
            style: TextStyle(
              color: color,
              fontSize: 12.5,
              height: 1.2,
              fontFamily: CanvasTheme.cardFontFamily,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: maxWidth),
    ];
    _bodyWidth = maxWidth;
    _bodyPaintersCount = count;
    _bodyPaintersColor = color.value;
    _bodyDirty = false;
    return _bodyPainters;
  }

  TextPainter? get titlePainter => _titlePainter;

  void invalidateTextCache() {
    _titleDirty = true;
    _bodyDirty = true;
    _textLines = null;
    _branchLabels = null;
    _countersLabel = null;
    for (final painter in _chipPainters) {
      painter.dispose();
    }
    _chipPainters = const [];
    _chipsCount = -1;
    _countersPainter?.dispose();
    _countersPainter = null;
    _countersWidth = -1;
  }

  void dispose() {
    _titlePainter?.dispose();
    for (final painter in _bodyPainters) {
      painter.dispose();
    }
    for (final painter in _chipPainters) {
      painter.dispose();
    }
    _countersPainter?.dispose();
  }
}

// ================================================================
// === НОВЫЕ МОДЕЛИ: ГРУППЫ И КОММЕНТАРИИ ===
// ================================================================

class CanvasGroup {
  final String id;
  final String? chapterId; // <--- ДОБАВЛЕНО
  final String label;
  final Rect rect;
  final Color color;

  CanvasGroup({
    required this.id,
    this.chapterId,
    required this.label,
    required this.rect,
    required this.color,
  });

  CanvasGroup copyWith({
    String? label,
    Rect? rect,
    Color? color,
    String? chapterId,
  }) {
    return CanvasGroup(
      id: id,
      chapterId: chapterId ?? this.chapterId,
      label: label ?? this.label,
      rect: rect ?? this.rect,
      color: color ?? this.color,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'chapterId': chapterId,
    'label': label,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'color': color.value,
  };

  factory CanvasGroup.fromJson(Map<String, dynamic> json) {
    return CanvasGroup(
      id: json['id'],
      chapterId: json['chapterId'],
      label: json['label'] ?? 'Group',
      rect: Rect.fromLTWH(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
        (json['w'] as num).toDouble(),
        (json['h'] as num).toDouble(),
      ),
      color: Color(json['color'] ?? 0xFF2196F3),
    );
  }
}

class CanvasComment {
  final String id;
  final String? chapterId; // <--- ДОБАВЛЕНО
  final String text;
  final Offset position;
  final Size size;

  CanvasComment({
    required this.id,
    this.chapterId,
    required this.text,
    required this.position,
    this.size = const Size(200, 150),
  });

  Rect get rect => position & size;

  CanvasComment copyWith({
    String? text,
    Offset? position,
    Size? size,
    String? chapterId,
  }) {
    return CanvasComment(
      id: id,
      chapterId: chapterId ?? this.chapterId,
      text: text ?? this.text,
      position: position ?? this.position,
      size: size ?? this.size,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'chapterId': chapterId,
    'text': text,
    'x': position.dx,
    'y': position.dy,
    'w': size.width,
    'h': size.height,
  };

  factory CanvasComment.fromJson(Map<String, dynamic> json) {
    return CanvasComment(
      id: json['id'],
      chapterId: json['chapterId'],
      text: json['text'] ?? '',
      position: Offset(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
      ),
      size: Size(
        (json['w'] as num?)?.toDouble() ?? 200.0,
        (json['h'] as num?)?.toDouble() ?? 150.0,
      ),
    );
  }
}

class Connection {
  final String id;
  final Node fromNode;
  final Node toNode;
  final Color color;
  final bool isVirtual;
  final ConnectionKind kind;

  Connection({
    required this.id,
    required this.fromNode,
    required this.toNode,
    this.color = Colors.cyan,
    this.isVirtual = false,
    this.kind = ConnectionKind.content,
  });
}

enum ConnectionKind { content, timer, script }

class ConnectionGeometry {
  final Offset start;
  final Offset end;
  final Offset cp1;
  final Offset cp2;
  final Rect bounds;
  final double lane;
  const ConnectionGeometry({
    required this.start,
    required this.end,
    required this.cp1,
    required this.cp2,
    required this.bounds,
    required this.lane,
  });
}

// ================================================================
// === SPATIAL HASH ===
// ================================================================
class SpatialHash {
  final double cellSize;
  final Map<String, Set<Node>> _grid = {};
  SpatialHash({this.cellSize = 200});
  String _getKey(int x, int y) => '$x,$y';
  void clear() => _grid.clear();

  void insert(Node node) {
    final rect = node.rect;
    final minX = (rect.left / cellSize).floor();
    final minY = (rect.top / cellSize).floor();
    final maxX = (rect.right / cellSize).floor();
    final maxY = (rect.bottom / cellSize).floor();
    for (int x = minX; x <= maxX; x++) {
      for (int y = minY; y <= maxY; y++) {
        final key = _getKey(x, y);
        _grid.putIfAbsent(key, () => {}).add(node);
      }
    }
  }

  Node? queryPoint(Offset point) {
    final x = (point.dx / cellSize).floor();
    final y = (point.dy / cellSize).floor();
    final cells = _grid[_getKey(x, y)];
    if (cells != null) {
      for (final node in cells.toList().reversed) {
        if (node.rect.contains(point)) return node;
      }
    }
    return null;
  }

  void rebuild(List<Node> nodes) {
    clear();
    for (final node in nodes) {
      insert(node);
    }
  }

  Set<Node> query(Rect rect) {
    final result = <Node>{};
    final minX = (rect.left / cellSize).floor();
    final minY = (rect.top / cellSize).floor();
    final maxX = (rect.right / cellSize).floor();
    final maxY = (rect.bottom / cellSize).floor();
    for (int x = minX; x <= maxX; x++) {
      for (int y = minY; y <= maxY; y++) {
        final cells = _grid[_getKey(x, y)];
        if (cells != null) {
          result.addAll(cells);
        }
      }
    }
    return result;
  }
}

class Indicator {
  final IconData icon;
  final Color color;
  Indicator(this.icon, this.color);
}

/// Сколько содержимого влезает в тело карточки.
///
/// Вынесено из художника, чтобы правило проверялось без растеризации:
/// реплики главнее сводки, но подписи веток не отнимают у текста больше,
/// чем до трёх строк.
class NodeBodyLayout {
  final int lines;
  final int chips;
  final bool counters;

  const NodeBodyLayout({
    required this.lines,
    required this.chips,
    required this.counters,
  });

  static NodeBodyLayout fit({
    required double height,
    required int lineCount,
    required int branchCount,
    required bool hasCounters,
  }) {
    final usable = height -
        NodeRenderer.headerHeight -
        NodeRenderer._bodyPadTop -
        NodeRenderer._bodyPadBottom;
    final wanted = lineCount < NodeRenderer.maxBodyLines
        ? lineCount
        : NodeRenderer.maxBodyLines;
    final chipsLimit = wanted == 0 ? 4 : NodeRenderer.maxBranchChips;
    final chipsCap = branchCount < chipsLimit ? branchCount : chipsLimit;

    double chipsHeight(int n) => n == 0
        ? 0
        : n * NodeRenderer._chipHeight +
            (n - 1) * NodeRenderer._chipGap +
            NodeRenderer._chipsTopGap;

    int fitLines(int n, bool withCounters) {
      final free = usable -
          chipsHeight(n) -
          (withCounters
              ? NodeRenderer._countersHeight + NodeRenderer._countersGap
              : 0);
      final fit = (free / NodeRenderer._bodyLineHeight).floor();
      if (fit <= 0) return 0;
      return fit < wanted ? fit : wanted;
    }

    if (wanted == 0) {
      var chips = chipsCap;
      while (chips > 0 && chipsHeight(chips) > usable) {
        chips--;
      }
      final counters = hasCounters &&
          chipsHeight(chips) +
                  NodeRenderer._countersHeight +
                  NodeRenderer._countersGap <=
              usable;
      return NodeBodyLayout(lines: 0, chips: chips, counters: counters);
    }

    var lines = fitLines(0, false);
    var chips = 0;
    // Каждый чип отнимает строку, но не ниже трёх: ветки не должны съесть
    // реплики целиком.
    while (chips < chipsCap) {
      final next = fitLines(chips + 1, false);
      final floor = lines < 3 ? lines : 3;
      if (next < floor) break;
      chips++;
      lines = next;
    }
    // Сводка — последней: показываем, только если она не отнимает реплику.
    final counters = hasCounters && fitLines(chips, true) >= lines;
    return NodeBodyLayout(lines: lines, chips: chips, counters: counters);
  }
}

class NodeRenderer {
  /// Высота шапки ноды — общая для тела ноды и её подписи.
  static const double headerHeight = 44.0;

  // Тело карточки: плотная раскладка «реплики → ветки → сводка».
  //
  // Нода по умолчанию 150×150: шапка 44, тело 106. Раньше в тело попадали
  // две строки первой реплики, а снизу висела пилюля индикаторов — 36 px
  // пустоты на каждой карточке. Теперь индикаторы уехали в шапку, а тело
  // отдано тексту и веткам.
  static const double _bodyPadX = 14.0;
  static const double _bodyPadTop = 8.0;
  static const double _bodyPadBottom = 10.0;
  static const double _bodyLineHeight = 15.5;
  static const double _chipHeight = 17.0;
  static const double _chipGap = 2.0;
  static const double _chipsTopGap = 4.0;
  static const double _countersHeight = 13.0;
  static const double _countersGap = 2.0;
  static const int maxBodyLines = 6;
  static const int maxBranchChips = 2;
  static const int maxHeaderIcons = 3;

  void drawNode(
    Canvas canvas,
    Node node, {
    required bool isSelected,
    required bool isHovered,
    required bool isConnectionStart,
    required bool isConnectionTarget,
    required bool isConnectionMode,
    required List<Connection> allConnections,
    bool isDimmed = false,
    bool hasValidationIssue = false,
    bool showDetails = true,
  }) {
    final rect = node.rect;
    const radius = Radius.circular(18);
    final rrect = RRect.fromRectAndRadius(rect, radius);
    final opacity = isDimmed ? 0.3 : 1.0;

    // Тени убраны: в каноничном M3 глубину на холсте задаёт тон
    // поверхности (surfaceContainer-уровни), а не drop shadow.

    // 1. Тело карточки (surfaceContainerHigh)
    final bodyColor = CanvasTheme.nodeBody.withOpacity(opacity);
    canvas.drawRRect(rrect, Paint()..color = bodyColor);

    // 2. Шапка ноды — это M3 filled-card.
    // Цвет вычисляется из node.color: для нейтральных/тёмных цветов
    // используем surface-роль темы, для остальных — генерируем
    // ГАРМОНИЧНЫЙ tonal-контейнер из самого цвета (ColorScheme.fromSeed).
    // Это даёт РАЗНООБРАЗНЫЕ, но не кислотные цвета, адаптивные к теме.
    final headerColor = _neutralHeader(node).withOpacity(isDimmed ? 0.35 : 1.0);

    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.top, rect.width, headerHeight),
      Paint()..color = headerColor,
    );
    canvas.restore();

    // 4. Граница / состояния
    Color borderColor = CanvasTheme.nodeBorder;
    double borderWidth = 1.0;
    if (isConnectionTarget) {
      borderColor = CanvasTheme.accentTarget;
      borderWidth = 3;
    } else if (isConnectionStart) {
      borderColor = CanvasTheme.accent;
      borderWidth = 3;
    } else if (isSelected) {
      borderColor = CanvasTheme.accent;
      borderWidth = 2.5;
    } else if (isHovered) {
      borderColor = CanvasTheme.nodeBorderHovered;
      borderWidth = 2;
    }
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = borderColor.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth,
    );

    if ((isHovered || isConnectionStart) &&
        isConnectionMode &&
        !isDimmed &&
        showDetails) {
      _drawAnchors(canvas, node);
    }

    // Подпись рисует художник (см. `drawNodeTitle`): она нужна и на большом
    // отдалении, но нормируется бюджетом на кадр.
    if (!showDetails) {
      node.headerRightInset = 0;
      return;
    }
    _drawBodyContent(canvas, node, rect, opacity);
    _drawHeaderIndicators(
      canvas,
      node,
      rect,
      allConnections,
      opacity,
      hasValidationIssue: hasValidationIssue,
    );
  }

  /// Заголовок ноды. Вызывается отдельно от тела ноды: художник решает, сколько
  /// подписей влезает в кадр (`CanvasFrameCost.budgetFor`).
  void drawNodeTitle(Canvas canvas, Node node, {bool isDimmed = false}) {
    final width = node.size.width - 2 * _bodyPadX - node.headerRightInset;
    if (width <= 0) return;
    _drawTitle(
      canvas,
      node,
      node.rect,
      width,
      headerHeight,
      isDimmed ? 0.3 : 1.0,
      _headerTextColor(node),
    );
  }

  static Color _neutralHeader(Node node) {
    final hsl = HSLColor.fromColor(node.color);
    final bool isNeutral = hsl.saturation < 0.15 || hsl.lightness < 0.18;
    return isNeutral
        ? CanvasTheme.containerForRole(NodeColorRole.surface)
        : CanvasTheme.tonalContainerFor(node.color);
  }

  /// Цвет заголовка — канонический M3 «on-container» для роли.
  static Color _headerTextColor(Node node) {
    final hsl = HSLColor.fromColor(node.color);
    final bool isNeutral = hsl.saturation < 0.15 || hsl.lightness < 0.18;
    return isNeutral
        ? CanvasTheme.onContainerForRole(NodeColorRole.surface)
        : CanvasTheme.onTonalContainerFor(node.color);
  }

  void _drawTitle(
    Canvas canvas,
    Node node,
    Rect rect,
    double titleWidth,
    double headerHeight,
    double opacity,
    Color titleColor,
  ) {
    final titlePainter = node.titlePainterFor(
      titleWidth,
      color: titleColor.withOpacity(opacity),
    );
    titlePainter.paint(
      canvas,
      Offset(
        rect.left + _bodyPadX,
        rect.top + (headerHeight - titlePainter.height) / 2,
      ),
    );
  }

  /// Тело карточки: реплики, подписи веток и сводка состава.
  void _drawBodyContent(
    Canvas canvas,
    Node node,
    Rect rect,
    double opacity,
  ) {
    final width = rect.width - 2 * _bodyPadX;
    if (width <= 0) return;
    final branches = node.branchLabels;
    final counters = node.countersLabel;
    final layout = NodeBodyLayout.fit(
      height: rect.height,
      lineCount: node.textLines.length,
      branchCount: branches.length,
      hasCounters: counters.isNotEmpty,
    );
    final top = rect.top + headerHeight + _bodyPadTop;

    final dim = opacity < 1;
    if (dim) {
      canvas.saveLayer(
        rect,
        Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
      );
    }

    if (layout.lines > 0) {
      final painters = node.bodyPainters(
        width,
        layout.lines,
        color: CanvasTheme.nodePreview,
      );
      var y = top;
      for (final painter in painters) {
        painter.paint(canvas, Offset(rect.left + _bodyPadX, y));
        y += _bodyLineHeight;
      }
    }

    var chipTop = top +
        layout.lines * _bodyLineHeight +
        (layout.lines > 0 ? _chipsTopGap : 0);
    Rect? lastChipRect;
    final chipPainters = layout.chips > 0
        ? node.chipPainters(
            width,
            layout.chips,
            color: CanvasTheme.nodePreview,
          )
        : const <TextPainter>[];
    for (var i = 0; i < chipPainters.length; i++) {
      final chip = chipPainters[i];
      final chipWidth = chip.width + 16;
      final chipRect = Rect.fromLTWH(
        rect.left + _bodyPadX,
        chipTop,
        chipWidth,
        _chipHeight,
      );
      final chipRRect = RRect.fromRectAndRadius(
        chipRect,
        const Radius.circular(_chipHeight / 2),
      );
      canvas.drawRRect(
        chipRRect,
        Paint()..color = CanvasTheme.nodeHeader.withOpacity(0.85),
      );
      canvas.drawRRect(
        chipRRect,
        Paint()
          ..color = CanvasTheme.nodeBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      chip.paint(
        canvas,
        Offset(
          chipRect.left + 8,
          chipRect.top + (_chipHeight - chip.height) / 2,
        ),
      );
      lastChipRect = chipRect;
      chipTop += _chipHeight + _chipGap;
    }

    // Скрытые ветки не должны пропадать молча: у нод-меню их бывает 20+.
    // Счётчик — по полному числу веток: из индекса приходят только первые
    // `cardPreviewBranches` подписей, а «+N» должно быть честным.
    final hiddenBranches = node.branchTotal - layout.chips;
    if (hiddenBranches > 0 && lastChipRect != null) {
      final more = TextPainter(
        text: TextSpan(
          text: '+$hiddenBranches',
          style: TextStyle(
            color: CanvasTheme.nodePreview,
            fontSize: 9.5,
            fontFamily: CanvasTheme.cardFontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = lastChipRect.right + 6;
      if (x + more.width <= rect.right - _bodyPadX) {
        more.paint(
          canvas,
          Offset(x, lastChipRect.center.dy - more.height / 2),
        );
      }
      more.dispose();
    }

    if (layout.counters && counters.isNotEmpty) {
      final painter = node.countersPainter(
        width,
        color: CanvasTheme.nodePreview,
      );
      painter.paint(
        canvas,
        Offset(
          rect.left + _bodyPadX,
          rect.bottom - _bodyPadBottom - painter.height,
        ),
      );
    }

    if (dim) canvas.restore();
  }

  List<Indicator> _buildIndicators(
    Node node,
    List<Connection> allConnections, {
    bool hasValidationIssue = false,
  }) {
    final List<Indicator> indicators = [];

    // Иконки-индикаторы используют единую приглушённую M3 tonal-палитру
    // (tone ~70) вместо ярких *Accent-цветов — это убирает «радужную кашу»
    // и держит холст в одном визуальном тоне.
    const indicatorStart = Color(0xFF7FCFA0); // green 70 — старт
    const indicatorStop = Color(0xFFE49592); // red 70 — финал
    const indicatorTimer = Color(0xFFE0C46C); // amber 70 — таймер
    const indicatorScript = Color(0xFF8FB6E0); // blue 70 — скрипт
    const indicatorImage = Color(0xFF7FCFB6); // teal 70 — изображение
    const indicatorAudio = Color(0xFFD79BC0); // pink 70 — аудио

    // Порядок — по важности: при нехватке места отпадают последние.
    if (hasValidationIssue) {
      indicators.add(Indicator(Icons.error_rounded, indicatorStop));
    }
    if (node.isStartNode) {
      indicators.add(
        Indicator(Icons.play_circle_filled_rounded, indicatorStart),
      );
    }
    if (!allConnections.any((c) => c.fromNode.id == node.id) &&
        !node.isStartNode) {
      indicators.add(Indicator(Icons.stop_circle_rounded, indicatorStop));
    }
    if (node.timerDuration != null && node.timerDuration! > 0) {
      indicators.add(Indicator(Icons.timer_rounded, indicatorTimer));
    }
    if (node.scriptCount > 0) {
      indicators.add(Indicator(Icons.code_rounded, indicatorScript));
    }
    if (node.hasImageItem || (node.backgroundAssetId ?? '').trim().isNotEmpty) {
      indicators.add(Indicator(Icons.image_rounded, indicatorImage));
    }
    if (node.hasAudioItem) {
      indicators.add(Indicator(Icons.audiotrack_rounded, indicatorAudio));
    }
    return indicators;
  }

  /// Индикаторы в шапке: раньше это была пилюля внизу, и она отнимала у тела
  /// 36 px из 106.
  void _drawHeaderIndicators(
    Canvas canvas,
    Node node,
    Rect rect,
    List<Connection> allConnections,
    double opacity, {
    bool hasValidationIssue = false,
  }) {
    final indicators = _buildIndicators(
      node,
      allConnections,
      hasValidationIssue: hasValidationIssue,
    );
    if (indicators.isEmpty) {
      node.headerRightInset = 0;
      return;
    }
    final shown = indicators.length <= maxHeaderIcons
        ? indicators
        : indicators.sublist(0, maxHeaderIcons);

    const iconSize = 11.0;
    const iconGap = 3.0;
    final total = shown.length * iconSize + (shown.length - 1) * iconGap;
    node.headerRightInset = total + 8;

    var x = rect.right - _bodyPadX - total;
    final iconY = rect.top + (headerHeight - iconSize) / 2;
    for (final indicator in shown) {
      _iconPainter(
        indicator,
        iconSize,
        indicator.color.withOpacity(opacity),
      ).paint(canvas, Offset(x, iconY));
      x += iconSize + iconGap;
    }
  }

  /// Глифы индикаторов не меняются от кадра к кадру — раскладываем один раз.
  static final Map<String, TextPainter> _iconCache = <String, TextPainter>{};

  static TextPainter _iconPainter(
    Indicator indicator,
    double size,
    Color color,
  ) {
    final key = '${indicator.icon.codePoint}|${size}|${color.value}';
    final cached = _iconCache[key];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(indicator.icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: indicator.icon.fontFamily,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Ключей мало (глиф × цвет), но на всякий случай не растём бесконечно.
    if (_iconCache.length > 256) {
      for (final old in _iconCache.values) {
        old.dispose();
      }
      _iconCache.clear();
    }
    _iconCache[key] = painter;
    return painter;
  }

  void _drawAnchors(Canvas canvas, Node node) {
    final anchors = [
      node.topAnchor,
      node.bottomAnchor,
      node.leftAnchor,
      node.rightAnchor,
    ];
    final anchorPaint = Paint()
      ..color = CanvasTheme.accent
      ..style = PaintingStyle.fill;
    final anchorBorderPaint = Paint()
      ..color = CanvasTheme.anchorBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final anchor in anchors) {
      canvas.drawCircle(anchor, 6, anchorPaint);
      canvas.drawCircle(anchor, 6, anchorBorderPaint);
    }
  }
}
