/// Разбор текста для анимации появления («печатная машинка»).
///
/// Плеер рисует префикс текста и скармливает его markdown-генератору. Если
/// резать по сырым символам, на кадр становился виден сам синтаксис: `**пол` —
/// звёздочки как текст, `[color=#FF0000]крас` — открытый тег без закрывающего.
/// Поэтому текст режется на атомарные единицы:
///  * markdown- и инлайн-теги (`**`, `` ` ``, `[color=…]`, ссылки, маркеры
///    строк) — единицы с нулевой «видимой» длиной: они не появляются наполовину;
///  * остальной текст — по графемным кластерам, чтобы эмодзи из нескольких
///    кодовых точек не распадалось на «тофу».
///
/// Разрезанную конструкцию префикс автозакрывает: `**ж` уходит генератору как
/// `**ж**`, то есть уже набранное видно сразу жирным. Одиночные звёздочки, у
/// которых пары нет, считаются текстом — иначе анимация на минуту делала бы
/// курсив из «2*3». Полностью набранный текст возвращается строкой буквально
/// как пришёл: последний кадр обязан совпасть с тем, что автор видел бы без
/// анимации.
library;

import 'package:flutter/widgets.dart' show Characters;

/// План проявления конкретного текста. Строится один раз и кешируется:
/// анимация пересчитывает только отсечку, а не разбор на каждый кадр.
class TextRevealPlan {
  TextRevealPlan._(this.source, this._cumVisible, this._srcEnd, this._closure);

  static final Map<String, TextRevealPlan> _cache = {};
  static const int _cacheMax = 16;

  static TextRevealPlan of(String source) => _cache[source] ?? _build(source);

  final String source;

  /// Сколько всего видимых символов — знаменатель прогресса.
  int get totalVisible => _cumVisible.last;

  /// Для границы k: накопленные видимые символы, конец куска в исходнике и
  /// «хвост», которым надо закрыть открытые к этому месту конструкции.
  final List<int> _cumVisible;
  final List<int> _srcEnd;
  final List<String> _closure;

  /// Видимых символов, соответствующих доле [t] (0..1).
  int visibleAt(double t) => (t * totalVisible).round().clamp(0, totalVisible);

  /// Что отдать markdown-генератору, когда набрано [visible] символов.
  String prefixFor(int visible) {
    if (visible >= totalVisible) return source;
    if (visible <= 0) return '';
    // Левая граница, где счётчик дошёл до [visible]: следующий за последним
    // набранным символом синтаксис (маркер нового пункта, закрывающие `**`)
    // в префикс НЕ берётся — иначе пустой `- ` показал бы лишнюю галочку.
    var lo = 0;
    var hi = _cumVisible.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_cumVisible[mid] < visible) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final cut = _srcEnd[lo];
    final tail = _closure[lo];
    if (tail.isEmpty) return source.substring(0, cut);
    return '${source.substring(0, cut)}$tail';
  }

  static const List<String> _emphasisTokens = [
    '**',
    '__',
    '~~',
    '``',
    '`',
    '*',
    '_',
  ];

  static TextRevealPlan _build(String source) {
    // Границы кластеров: индекс старта -> индекс конца. Позволяет резать по
    // граемам, не поднимая Characters-итератор на каждый символ.
    final clusterEndAt = <int, int>{};
    var scan = 0;
    for (final cluster in Characters(source).toList()) {
      clusterEndAt[scan] = scan + cluster.length;
      scan += cluster.length;
    }

    final cum = <int>[0];
    final ends = <int>[0];
    final closures = <String>[''];
    final open = <String>[];
    var i = 0;
    var atLineStart = true;
    var inFence = false;

    void add(String text, int visible) {
      i += text.length;
      cum.add(cum.last + visible);
      ends.add(i);
      closures.add(open.reversed.join());
    }

    void addLiteral() {
      final end = clusterEndAt[i] ?? (i + 1);
      add(source.substring(i, end), 1);
    }

    while (i < source.length) {
      if (source[i] == '\n') {
        // Сам перевод строки ничего не «печатает», но после него снова
        // действуют маркеры строк — в том числе внутри блока кода, где им
        // надо закрыть fence.
        add('\n', 0);
        atLineStart = true;
        continue;
      }

      if (atLineStart) {
        if (inFence) {
          final closing = _match(source, i, _closingFenceExp);
          if (closing != null) {
            if (open.isNotEmpty) open.removeLast();
            add(closing, 0);
            inFence = false;
            atLineStart = false;
            continue;
          }
        } else {
          final marker = _blockMarkerAt(source, i);
          if (marker != null) {
            final fenceRun = _fenceRunOf(marker);
            if (fenceRun != null) {
              // Блок кода тоже закрывается «снаружи», иначе префикс с
              // открытой выборкой уедет в бесконечный абзац кода.
              inFence = true;
              open.add(fenceRun);
            }
            add(marker, 0);
            atLineStart = false;
            continue;
          }
          final indent = _match(source, i, _indentExp);
          if (indent != null) {
            // Отступ строки без маркера невидим, но отдаётся целиком —
            // иначе следующий символ снова приняли бы за маркер.
            add(indent, 0);
            continue;
          }
        }
      }

      if (!inFence) {
        final token = _inlineTokenAt(source, i);
        if (token != null && _isBalancedAt(source, i, token, open)) {
          final closer = _closerOf(token);
          if (open.isNotEmpty && open.last == closer && _isCloserOf(token)) {
            open.removeLast();
          } else if (closer != null) {
            open.add(closer);
          }
          add(token, 0);
          atLineStart = false;
          continue;
        }
        final link = _linkAt(source, i);
        if (link != null) {
          if (link.label.isEmpty) {
            // Картинка или пустая ссылка: показывать по частям нечего.
            add(link.opener, 0);
          } else {
            // Ссылку раскладываем: label печатается по буквам, а адрес
            // `](url)` подмешивается закрытием, поэтому его никогда не видно.
            open.add(link.tail);
            add(link.opener, 0);
            for (final cluster in Characters(link.label).toList()) {
              add(cluster, 1);
            }
            open.removeLast();
            add(link.tail, 0);
          }
          atLineStart = false;
          continue;
        }
      }

      addLiteral();
      atLineStart = false;
    }

    if (_cache.length >= _cacheMax) _cache.remove(_cache.keys.first);
    final plan = TextRevealPlan._(
      source,
      List.unmodifiable(cum),
      List.unmodifiable(ends),
      List.unmodifiable(closures),
    );
    _cache[source] = plan;
    return plan;
  }

  /// Парная ли конструкция и закрыта ли она позже в тексте. `[/color]` без
  /// открывающего тега и одиночная `*` — это просто символы.
  static bool _isBalancedAt(
    String source,
    int at,
    String token,
    List<String> open,
  ) {
    if (token == '[/color]' || token == '[/font]') {
      return open.isNotEmpty && open.last == token;
    }
    if (token.startsWith('[color=') || token.startsWith('[font=')) {
      return source.indexOf(_closerOf(token)!, at + token.length) >= 0;
    }
    final closer = _closerOf(token);
    if (closer == null) return false;
    if (open.isNotEmpty && open.last == closer && _isCloserOf(token)) {
      return true;
    }
    return source.indexOf(token, at + token.length) >= 0;
  }

  /// Токен может быть и открытием, и закрытием; «закрытием» считаем тот, что
  /// закрывает последний открытый.
  static bool _isCloserOf(String token) =>
      _emphasisTokens.contains(token) ||
      token == '[/color]' ||
      token == '[/font]';

  static String? _match(String source, int at, RegExp re) =>
      re.matchAsPrefix(source, at)?.group(0);
}

final RegExp _indentExp = RegExp(r'[ \t]+');
final RegExp _closingFenceExp = RegExp(r'[ \t]*(?:```+|~~~+)[^\n]*');

/// Что из маркера строки является зачинателем блока кода: ` ``` ` или `~~~`.
/// Возвращается ровно тот бегущий символ, которым блок и закрывается.
String? _fenceRunOf(String marker) {
  final trimmed = marker.trimLeft();
  if (trimmed.startsWith('```')) {
    return RegExp(r'^`+').firstMatch(trimmed)?.group(0);
  }
  if (trimmed.startsWith('~~~')) {
    return RegExp(r'^~+').firstMatch(trimmed)?.group(0);
  }
  return null;
}

/// Маркер начала строки: заголовок, список, цитата, блок кода. Это служебный
/// текст, его не печатают по буквам. Якорь `^` тут не нужен: шаблоны вызываются
/// только через `matchAsPrefix`, а он и так привязан к позиции — зато `^`
/// ломает совпадение на всех строках, кроме первой.
final List<RegExp> _blockMarkerExps = [
  RegExp(r'[ \t]*(?:```+|~~~+)[^\n]*'),
  RegExp(r'[ \t]{0,3}#{1,6}[ \t]+'),
  RegExp(r'[ \t]*\d+\.[ \t]+'),
  RegExp(r'[ \t]*[-*+•][ \t]+'),
  RegExp(r'[ \t]*>[ \t]?'),
];

String? _blockMarkerAt(String source, int at) {
  for (final re in _blockMarkerExps) {
    final m = re.matchAsPrefix(source, at);
    if (m != null) return m.group(0);
  }
  return null;
}

/// Инлайн-конструкция, которую нельзя показывать наполовину: теги цвета и
/// шрифта, акценты, встроенный код.
final List<RegExp> _inlineTagExps = [
  RegExp(r'\[color=#[0-9A-Fa-f]{6,8}\]'),
  RegExp(r'\[outline=#[0-9A-Fa-f]{6,8}(?::[0-9.]+)?\]'),
  RegExp(r'\[font=[^\]\n]+\]'),
];

String? _inlineTokenAt(String source, int at) {
  for (final re in _inlineTagExps) {
    final m = re.matchAsPrefix(source, at);
    if (m != null) return m.group(0);
  }
  for (final token in const ['[/color]', '[/outline]', '[/font]']) {
    if (source.startsWith(token, at)) return token;
  }
  for (final token in TextRevealPlan._emphasisTokens) {
    if (source.startsWith(token, at)) return token;
  }
  return null;
}

/// Что закроет конструкцию, если обрезали внутри неё.
String? _closerOf(String token) {
  if (token.startsWith('[color=')) return '[/color]';
  if (token.startsWith('[outline=')) return '[/outline]';
  if (token.startsWith('[font=')) return '[/font]';
  if (token == '[/color]' || token == '[/outline]' || token == '[/font]') {
    return token;
  }
  if (TextRevealPlan._emphasisTokens.contains(token)) return token;
  return null;
}

class _LinkParts {
  const _LinkParts({
    required this.opener,
    required this.label,
    required this.tail,
  });

  /// `[` у ссылки и всё `![alt](url)` целиком у картинки.
  final String opener;
  final String label;

  /// `](url)` — то, чем надо закрыть префикс, обрезанный внутри label.
  final String tail;
}

/// Ссылка или картинка. Адрес не должен появляться на экране, поэтому
/// конструкция возвращается разобранной, а не куском исходника.
_LinkParts? _linkAt(String source, int at) {
  final isImage =
      source[at] == '!' && at + 1 < source.length && source[at + 1] == '[';
  if (!isImage && source[at] != '[') return null;
  final bracket = isImage ? at + 1 : at;
  final close = source.indexOf(']', bracket);
  if (close < 0 || close + 1 >= source.length || source[close + 1] != '(') {
    return null;
  }
  final end = source.indexOf(')', close + 2);
  if (end < 0) return null;
  if (isImage) {
    return _LinkParts(
      opener: source.substring(at, end + 1),
      label: '',
      tail: '',
    );
  }
  return _LinkParts(
    opener: source.substring(at, bracket + 1),
    label: source.substring(bracket + 1, close),
    tail: source.substring(close, end + 1),
  );
}
