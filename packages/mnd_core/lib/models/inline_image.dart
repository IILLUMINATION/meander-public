const Set<String> inlineImageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'bmp',
  'avif',
  'heic',
  'heif',
};

const int inlineImagePathMaxLength = 1024;

// Граница длины не даёт каждому `[img=` заново сканировать весь хвост.
final RegExp inlineImageTag = RegExp(r'\[img=([^\]\r\n]{1,1024})\]');

final RegExp _backtickRun = RegExp(r'`+');

class InlineCodeSpan {
  final int start;
  final String delimiter;
  final int end;

  const InlineCodeSpan({
    required this.start,
    required this.delimiter,
    required this.end,
  });
}

List<InlineCodeSpan> inlineCodeSpans(String text) {
  final runs = <_BacktickRun>[];
  var i = 0;
  while (i < text.length) {
    if (text[i] != '`') {
      i++;
      continue;
    }
    final start = i;
    while (i < text.length && text[i] == '`') {
      i++;
    }
    runs.add(
      _BacktickRun(
        start: start,
        end: i,
        length: i - start,
        escaped: _isEscaped(text, start),
      ),
    );
  }

  final nextSameLength = List<int?>.filled(runs.length, null);
  final lastByLength = <int, int>{};
  for (var i = runs.length - 1; i >= 0; i--) {
    nextSameLength[i] = lastByLength[runs[i].length];
    lastByLength[runs[i].length] = i;
  }

  final spans = <InlineCodeSpan>[];
  for (var i = 0; i < runs.length;) {
    final opener = runs[i];
    final closerIndex = nextSameLength[i];
    if (opener.escaped || closerIndex == null) {
      i++;
      continue;
    }
    final closer = runs[closerIndex];
    spans.add(
      InlineCodeSpan(
        start: opener.start,
        delimiter: text.substring(opener.start, opener.end),
        end: closer.end,
      ),
    );
    i = closerIndex + 1;
  }
  return spans;
}

InlineCodeSpan? inlineCodeSpanAt(String text, int at) =>
    _InlineCodeCursor(inlineCodeSpans(text)).spanAt(at);

Iterable<RegExpMatch> inlineImageMatchesOutsideCode(String text) sync* {
  final code = _InlineCodeCursor(inlineCodeSpans(text));
  for (final match in inlineImageTag.allMatches(text)) {
    if (normalizeInlineImagePath(match.group(1)) != null &&
        !_isEscaped(text, match.start) &&
        !code.contains(match.start)) {
      yield match;
    }
  }
}

class _InlineCodeCursor {
  _InlineCodeCursor(this.spans);

  final List<InlineCodeSpan> spans;
  int _index = 0;

  bool contains(int offset) {
    while (_index < spans.length && spans[_index].end <= offset) {
      _index++;
    }
    if (_index >= spans.length) return false;
    final span = spans[_index];
    return span.start <= offset && offset < span.end;
  }

  InlineCodeSpan? spanAt(int offset) {
    while (_index < spans.length && spans[_index].end <= offset) {
      _index++;
    }
    if (_index >= spans.length) return null;
    final span = spans[_index];
    return span.start == offset ? span : null;
  }
}

String? normalizeInlineImagePath(String? source) {
  final path = (source ?? '').trim().replaceAll(r'\', '/');
  if (path.isEmpty ||
      path.length > inlineImagePathMaxLength ||
      path.startsWith('/') ||
      path.contains(':')) {
    return null;
  }
  if (path.contains('?') || path.contains('#')) return null;
  if (path.codeUnits.any((unit) => unit < 0x20)) return null;

  final segments = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    // Win32 отбрасывает хвостовые точки и пробелы, превращая `.. ` в `..`.
    if (segment == '..' || segment.endsWith(' ') || segment.endsWith('.')) {
      return null;
    }
    segments.add(segment);
  }
  if (segments.isEmpty) return null;

  final fileName = segments.last;
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return null;
  final extension = fileName.substring(dot + 1).toLowerCase();
  if (!inlineImageExtensions.contains(extension)) return null;

  if (segments.length > 1 &&
      (segments.first != 'res' || segments[1] != 'images')) {
    return null;
  }
  return segments.join('/');
}

Iterable<String> extractInlineImagePaths(String text) sync* {
  for (final match in inlineImageMatchesOutsideCode(text)) {
    final path = normalizeInlineImagePath(match.group(1));
    if (path != null) yield path;
  }
}

String stripInlineImageTags(String text) {
  final out = StringBuffer();
  final code = _InlineCodeCursor(inlineCodeSpans(text));
  var i = 0;
  while (i < text.length) {
    final span = code.spanAt(i);
    if (span != null) {
      out.write(text.substring(i, span.end));
      i = span.end;
      continue;
    }
    if (text[i] == '`') {
      final run = _backtickRun.matchAsPrefix(text, i)!.group(0)!;
      out.write(run);
      i += run.length;
      continue;
    }
    final image = inlineImageTag.matchAsPrefix(text, i);
    if (image != null) {
      final valid =
          normalizeInlineImagePath(image.group(1)) != null &&
          !_isEscaped(text, i) &&
          !code.contains(i);
      out.write(valid ? '' : image.group(0)!);
      i = image.end;
      continue;
    }
    out.write(text[i]);
    i++;
  }
  return out.toString();
}

bool _isEscaped(String text, int offset) {
  var backslashes = 0;
  for (var i = offset - 1; i >= 0 && text[i] == '\\'; i--) {
    backslashes++;
  }
  return backslashes.isOdd;
}

class _BacktickRun {
  const _BacktickRun({
    required this.start,
    required this.end,
    required this.length,
    required this.escaped,
  });

  final int start;
  final int end;
  final int length;
  final bool escaped;
}
