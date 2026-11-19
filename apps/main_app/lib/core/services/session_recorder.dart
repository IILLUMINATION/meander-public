import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostics_export.dart';

/// Запись сессии тестировщика: что человек нажимал и как на это ответило
/// приложение.
///
/// Зачем. Отчёты «скрипт не сохраняется» и «попал в цикл экранов» приходили
/// без воспроизводимых данных: по видео нельзя понять, какой экран, какая
/// вкладка и какое сохранение сработали. Здесь пишется машинночитаемый
/// журнал (JSONL, строка на событие) плюс человекочитаемая сводка `.md`.
///
/// Формат строки: `{"t": <мс от старта>, "at": "<ISO>", "type": "...", …}`.
///
/// Журнал лежит в `<документы приложения>/session_logs/session-*.jsonl`.
/// Запись идёт сразу в файл (буфер IOSink сбрасывается по таймеру), поэтому
/// падение приложения не съедает уже записанное.
class SessionRecorder {
  SessionRecorder._();

  static final SessionRecorder instance = SessionRecorder._();

  /// Сколько событий держим в памяти для сводки. В файл пишутся все.
  @visibleForTesting
  static int maxRetainedEvents = 5000;

  /// Предел размера файла: длинная сессия не должна съесть диск. По
  /// достижении журнал закрывается, в него дописывается маркер.
  static const int maxFileBytes = 16 * 1024 * 1024;

  /// Подмена каталога в тестах (`path_provider` в юнит-тестах недоступен).
  @visibleForTesting
  static Directory? directoryOverride;

  final List<Map<String, Object?>> _events = [];

  IOSink? _sink;
  DateTime? _startedAt;
  String? _filePath;
  String? _questId;
  int _bytesWritten = 0;
  Timer? _flushTimer;
  bool _running = false;
  bool _writeFailed = false;
  List<String> _knownRoutes = const [];

  /// Поколение сессии: экспорт и UI-бейдж читают его, чтобы не показывать
  /// данные прошлой записи.
  int _sessionGeneration = 0;

  bool get isRecording => _sink != null;

  /// Идёт сессия (в том числе без файла — так её поднимают тесты виджетов).
  /// `record()` сам решает, писать ли строку на диск.
  bool get isActive => _running;
  DateTime? get startedAt => _startedAt;
  String? get currentFilePath => _filePath;
  int get eventCount => _events.length;
  int get generation => _sessionGeneration;

  /// События текущей (или последней) сессии — только чтение.
  List<Map<String, Object?>> get events => List.unmodifiable(_events);

  /// Название текущего маршрута — для сводки и поиска «где мы были».
  void noteRoute(String name) {
    final known = List<String>.of(_knownRoutes);
    known.add(name);
    if (known.length > 8) known.removeAt(0);
    _knownRoutes = known;
  }

  Future<void> start({String? questId, String? note}) async {
    if (isRecording) return;
    final dir = directoryOverride ?? await getApplicationDocumentsDirectory();
    final logsDir = Directory('${dir.path}/session_logs');
    if (!logsDir.existsSync()) {
      await logsDir.create(recursive: true);
    }
    final started = DateTime.now();
    final stamp = _stamp(started);
    final file = File('${logsDir.path}/session-$stamp.jsonl');
    final sink = file.openWrite(mode: FileMode.write);

    _sessionGeneration++;
    _events.clear();
    _knownRoutes = const [];
    _startedAt = started;
    _filePath = file.path;
    _questId = questId;
    _sink = sink;
    _running = true;
    _bytesWritten = 0;
    _writeFailed = false;
    // Сброс буфера раз в 2 секунды: при жёстком kill ядра Dart хвост
    // IOSink теряется, а записи последних секунд для отчёта важнее всего.
    _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_flush());
    });

    record('session.start', {
      'questId': questId,
      'note': ?note,
      'platform': Platform.operatingSystem,
      'isDebug': kDebugMode,
      'appVersion': _appVersionHint(),
    });
  }

  Future<void> stop([String? reason]) async {
    if (!isRecording) return;
    record('session.stop', {'reason': ?reason});
    _flushTimer?.cancel();
    _flushTimer = null;
    final sink = _sink;
    _sink = null;
    _running = false;
    try {
      await sink?.flush();
    } catch (_) {}
    try {
      await sink?.close();
    } catch (_) {}
  }

  /// Записать событие. Дешёвая операция: строка собирается сразу, файл
  /// пишется буферизованно. Исключения наружу не выходят — диагностика не
  /// имеет права ломать интерфейс.
  void record(String type, [Map<String, Object?> data = const {}]) {
    final started = _startedAt;
    if (!_running || started == null) return;
    final event = <String, Object?>{
      't': DateTime.now().difference(started).inMilliseconds,
      'at': DateTime.now().toIso8601String(),
      'type': type,
      ...data,
    };
    _events.add(event);
    if (_events.length > maxRetainedEvents) {
      _events.removeRange(0, _events.length - maxRetainedEvents);
    }
    _write(_encode(event));
  }

  /// Только для тестов виджетов: сессия без файла. Реальная запись идёт
  /// через [start] и требует настоящего I/O, которое в fake-async
  /// `testWidgets` не выполняется.
  @visibleForTesting
  void seedForTest({DateTime? startedAt}) {
    _events.clear();
    _startedAt = startedAt ?? DateTime.now();
    _running = true;
  }

  /// Ошибка приложения: пишем текст, стек и текущее место.
  void recordError(Object error, StackTrace? stack, {String? context}) {
    record('error', {
      'error': error.toString(),
      'context': ?context,
      if (stack != null)
        'stack': stack.toString().split('\n').take(20).join('\n'),
      'routes': _knownRoutes,
    });
  }

  void _write(String line) {
    final sink = _sink;
    if (sink == null) return;
    try {
      sink.writeln(line);
      _bytesWritten += line.length + 1;
      if (_bytesWritten > maxFileBytes && !_writeFailed) {
        // Маркер пишем напрямую: `record` уже не пройдёт сквозь флаг.
        sink.writeln(
          jsonEncode({
            't': DateTime.now()
                .difference(_startedAt ?? DateTime.now())
                .inMilliseconds,
            'type': 'session.fileLimit',
            'bytes': _bytesWritten,
          }),
        );
        _writeFailed = true;
      }
    } catch (e) {
      _writeFailed = true;
      debugPrint('SessionRecorder: запись не удалась: $e');
    }
  }

  Future<void> _flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  /// Сводка для человека: экраны, нажатия, сохранения, ошибки, состояние
  /// вкладок. Именно её удобно приложить к отчёту, не открывая JSONL.
  String buildDigest() {
    final started = _startedAt;
    final buffer = StringBuffer();
    buffer.writeln('# Запись сессии тестировщика');
    buffer.writeln();
    if (started != null) {
      buffer.writeln('- Начало: ${started.toIso8601String()}');
      final last = _events.isEmpty ? null : _events.last['t'] as int?;
      if (last != null) {
        buffer.writeln('- Длительность: ${_duration(last)}');
      }
    }
    buffer.writeln('- Событий в сводке: ${_events.length}');
    if (_questId != null) buffer.writeln('- Квест: $_questId');
    buffer.writeln();

    void section(String title, String type, {int limit = 200}) {
      final items = _events.where((e) => e['type'] == type).toList();
      if (items.isEmpty) return;
      buffer.writeln('## $title (${items.length})');
      for (final event
          in items.length > limit
              ? items.sublist(items.length - limit)
              : items) {
        buffer.writeln('- ${_describe(event)}');
      }
      buffer.writeln();
    }

    section('Экраны', 'route');
    section('Редактор', 'editor');
    section('Скрипты', 'script');
    section('Игра', 'game');
    section('Состояние', 'state', limit: 40);
    section('Прочее', 'lifecycle');
    section('Ошибки', 'error', limit: 50);
    section('Нажатия', 'tap', limit: 300);

    return buffer.toString();
  }

  String _describe(Map<String, Object?> event) {
    final t = event['t'];
    final stamp = t is int ? _duration(t) : '';
    final rest = {
      for (final entry in event.entries)
        if (entry.key != 't' && entry.key != 'at' && entry.key != 'type')
          entry.key: entry.value,
    };
    return '[$stamp] $rest';
  }

  /// Отдать журнал и сводку наружу: на мобильных — через «поделиться», на
  /// десктопе — «сохранить как». Сначала останавливаем запись, чтобы файл
  /// был дописан, затем экспортируем JSONL и `.md`.
  Future<String?> exportAndShare() async {
    await stop('export');
    final path = _filePath;
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    final jsonl = await file.readAsString();
    final digest = buildDigest();
    final base = path
        .split(Platform.pathSeparator)
        .last
        .replaceAll('.jsonl', '');
    final saved = await DiagnosticsExport.saveOrShareText(
      fileName: '$base.jsonl',
      content: jsonl,
      shareSubject: 'Запись сессии Meander',
    );
    await DiagnosticsExport.saveOrShareText(
      fileName: '$base.md',
      content: digest,
      shareSubject: 'Сводка сессии Meander',
    );
    return saved;
  }

  /// Список прошлых сессий (свежие сверху) — для экрана диагностики.
  Future<List<File>> listSessions() async {
    final dir = directoryOverride ?? await getApplicationDocumentsDirectory();
    final logsDir = Directory('${dir.path}/session_logs');
    if (!logsDir.existsSync()) return const [];
    final files =
        logsDir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.jsonl'))
            .toList()
          ..sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
          );
    return files;
  }

  static String _duration(int millis) {
    final d = Duration(milliseconds: millis);
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$m:$s.$ms';
  }

  static String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }

  static String _appVersionHint() {
    const version = String.fromEnvironment('MND_VERSION');
    return version.isEmpty ? 'dev' : version;
  }

  static String _encode(Map<String, Object?> event) {
    try {
      return jsonEncode(event);
    } catch (_) {
      return jsonEncode({
        't': event['t'],
        'type': event['type'],
        'error': 'not-encodable',
      });
    }
  }

  @visibleForTesting
  void resetForTest() {
    _sink = null;
    _running = false;
    _events.clear();
    _startedAt = null;
    _filePath = null;
    _questId = null;
    _writeFailed = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    _knownRoutes = const [];
  }
}

/// Наблюдатель навигации: каждый push/pop/replace попадает в журнал.
class SessionRecorderNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log('push', route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log('pop', route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _log('replace', newRoute);
  }

  void _log(String action, Route<dynamic>? route) {
    final recorder = SessionRecorder.instance;
    if (!recorder.isActive) return;
    final name = route?.settings.name ?? route?.runtimeType.toString() ?? '?';
    recorder.noteRoute(name);
    recorder.record('route', {'action': action, 'route': name});
  }
}

/// Слушает касания всего приложения и записывает, по каким подписям
/// пришёлся тап.
///
/// Живёт в `MaterialApp.builder`, поэтому видит все экраны. Подписи берём из
/// дерева рендера в точке касания (`Text`, semantics-метка, tooltip) — так в
/// журнале появляется «нажал на кнопку "Сохранить"», а не голые координаты.
class SessionTapRecorder extends StatelessWidget {
  const SessionTapRecorder({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: (event) {
        final recorder = SessionRecorder.instance;
        if (!recorder.isActive) return;
        recorder.record('tap', {
          'x': event.position.dx.round(),
          'y': event.position.dy.round(),
          'kind': event.kind.name,
          'labels': _labelsAt(event.position, event.viewId),
        });
      },
      child: child,
    );
  }

  /// Подписи под точкой: от самого глубокого элемента наружу, первые
  /// несколько. Пустые и дубликаты отбрасываем.
  static List<String> _labelsAt(ui.Offset position, int viewId) {
    try {
      final result = HitTestResult();
      RendererBinding.instance.hitTestInView(result, position, viewId);
      final labels = <String>[];
      for (final entry in result.path) {
        final target = entry.target;
        if (target is RenderParagraph) {
          _addLabel(labels, target.text.toPlainText());
        } else if (target is RenderSemanticsAnnotations) {
          _addLabel(labels, target.properties.label);
          final tooltip = target.properties.tooltip;
          if (tooltip != null) _addLabel(labels, tooltip);
        }
        if (labels.length >= 4) break;
      }
      return labels;
    } catch (_) {
      return const [];
    }
  }

  static void _addLabel(List<String> labels, String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return;
    if (labels.contains(text)) return;
    labels.add(text.length > 80 ? '${text.substring(0, 80)}…' : text);
  }
}
