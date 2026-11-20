import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Service;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:mnd_player/utils/file_storage.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart' as vm_io;

/// Сторож зависаний UI-потока.
///
/// Зависание (в отличие от исключения) не бросает ошибку: UI просто замирает,
/// и единственный способ «поймать» его — наблюдать со стороны. Главный изолят
/// каждую секунду шлёт «heartbeat» с последним известным шагом. Отдельный
/// изолят-сторож, не получив heartbeat дольше [stallTimeout], пишет HANG-строку
/// в crash-лог.
///
/// Дополнительно сторож каждую секунду сам читает RSS процесса и, при
/// аномальном скачке памяти (или при пропуске heartbeat), снимает через
/// VM Service стек висящего изолята (`getStack`) и профиль аллокаций
/// (`getAllocationProfile`) в `/tmp/mnd_stack_dump.json` и
/// `/tmp/mnd_alloc_dump.json`. RPC идут через safepoint-механизм VM, а не
/// через message loop изолята, поэтому работают даже когда UI заблокирован.
///
/// Весь жизненный цикл сторожа логируется в `/tmp/mnd_watchdog.log` — по нему
/// видно, какая версия кода реально исполняется и на каком шаге что-то не так.
class HangWatchdog {
  HangWatchdog._();

  static const Duration beatInterval = Duration(seconds: 1);
  static const Duration stallTimeout = Duration(seconds: 5);
  static const String _bootLog = '/tmp/mnd_watchdog.log';

  /// Допуск между стеновыми и монотонными часами, за которым процесс спал, а
  /// не висел. Сон системы останавливает и те, и другие таймеры разом, а
  /// настоящее зависание UI-потока — только heartbeat.
  @visibleForTesting
  static const int sleepDriftToleranceMs = 2000;

  /// Висящий UI или ночной сон ноутбука?
  ///
  /// При реальном зависании процесс работает: монотонные часы уходят вперёд
  /// вместе со стеновыми. При suspend и то, и другое стоит, и после пробуждения
  /// `wallGapMs` равен всей длительности сна, а `monoGapMs` — почти нулю.
  /// Без этой проверки сторож писал «UI HANG 9 часов» на каждое пробуждение.
  @visibleForTesting
  static bool isRealStall({required int wallGapMs, required int monoGapMs}) =>
      monoGapMs >= wallGapMs - sleepDriftToleranceMs;

  static bool _started = false;
  static SendPort? _heartbeatPort;
  static String _lastStep = 'idle';

  /// Запустить сторож (идемпотентно). Вызывать из главного изолята.
  ///
  /// Только debug: в release сторож не запускается вовсе — его секундные
  /// таймеры, синхронное чтение RSS и записи в файлы даром не нужны в
  /// проде и добавляют постоянную фоновую активность.
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    if (!kDebugMode) return;

    String? logDir;
    try {
      final dir = await FileStorage.getAppDirectory();
      logDir = dir.path;
    } catch (_) {}

    // URI VM Service для дампа стека (только debug). В release сервиса нет.
    String? vmServiceWsUri;
    try {
      final info = await Service.getInfo();
      vmServiceWsUri = info.serverWebSocketUri?.toString();
    } catch (_) {}

    // Handshake: сторож создаёт свой ReceivePort и шлёт sendPort обратно —
    // только так главный изолят может слать heartbeat'ы в сторож.
    final handshake = ReceivePort();
    try {
      await Isolate.spawn(
        _watchdogMain,
        (logDir, handshake.sendPort, kDebugMode, vmServiceWsUri),
        debugName: 'hang-watchdog',
      );
    } catch (e) {
      debugPrint('[HangWatchdog] не удалось запустить сторож: $e');
      _started = false;
      return;
    }
    _heartbeatPort = await handshake.first as SendPort;
    handshake.close();
    Timer.periodic(beatInterval, (_) {
      // Если UI-поток заблокирован — этот таймер не срабатывает, и сторож
      // фиксирует зависание.
      _heartbeatPort?.send([_lastStep, DateTime.now().millisecondsSinceEpoch]);
    });
  }

  /// Отметить текущий шаг — последний известный этап перед рискованной
  /// операцией (движок, декодирование JSON, восстановление сессии).
  static void mark(String step) {
    _lastStep = step;
  }

  /// Последний отмеченный шаг. Нужен аварийному экрану запуска: если
  /// инициализация зависла, по этой строке видно, на чём именно.
  static String get lastStep => _lastStep;

  static void _watchdogMain((String?, SendPort, bool, String?) args) {
    final (logDir, handshake, debugMemory, vmServiceWsUri) = args;
    final receivePort = ReceivePort();
    handshake.send(receivePort.sendPort); // сообщаем main, куда слать beats

    void log(String line) {
      _writeFile(
        _bootLog,
        '${DateTime.now().toIso8601String()} $line\n',
        append: true,
      );
    }

    log(
      'watchdog v2 started; debugMemory=$debugMemory; '
      'wsUri=${vmServiceWsUri == null ? 'NULL' : 'present'}',
    );

    var lastStep = 'idle';
    var lastBeat = DateTime.now();
    // Монотонные часы сторожевого изолята: они стоят вместе с процессом во
    // время сна системы, в отличие от wall-clock штампа heartbeat.
    final mono = Stopwatch()..start();
    var lastBeatMonoMs = mono.elapsedMilliseconds;
    Timer? stallTimer;

    vm.VmService? vmService;
    String? mainIsolateId;
    bool dumpStarted = false;

    Future<void> initVmService() async {
      final ws = vmServiceWsUri;
      if (ws == null) {
        log('VM service: no wsUri (Service.getInfo returned null)');
        return;
      }
      try {
        final svc = await vm_io
            .vmServiceConnectUri(ws)
            .timeout(const Duration(seconds: 10));
        final info = await svc.getVM();
        final isolates = info.isolates ?? const <vm.IsolateRef>[];
        if (isolates.isEmpty) {
          log('VM service: connected but no isolates');
          return;
        }
        vm.IsolateRef? main;
        for (final iso in isolates) {
          if (iso.name == 'main') {
            main = iso;
            break;
          }
        }
        main ??= isolates.firstWhere(
          (i) => !(i.name ?? '').startsWith('vm-service'),
          orElse: () => isolates.first,
        );
        vmService = svc;
        mainIsolateId = main.id;
        log('VM service: connected; main isolate ${main.id} (${main.name})');
      } catch (e) {
        log('VM service: connect FAILED: $e');
      }
    }

    Future<void> dumpStack() async {
      final svc = vmService;
      final id = mainIsolateId;
      if (svc == null || id == null) {
        log('dump: skipped (service not ready)');
        _writeFile(
          '/tmp/mnd_stack_dump.txt',
          'VM service not ready\n',
          append: true,
        );
        return;
      }
      var paused = false;
      try {
        log('dump: pausing $id...');
        await svc.pause(id).timeout(const Duration(seconds: 10));
        paused = true;
        try {
          log('dump: paused; getStack...');
          final stack = await svc
              .getStack(id)
              .timeout(const Duration(seconds: 10));
          _writeFile('/tmp/mnd_stack_dump.json', jsonEncode(stack.toJson()));
          log('dump: stack written (${stack.frames?.length ?? 0} frames)');
        } catch (e) {
          log('dump: getStack FAILED: $e');
          _writeFile(
            '/tmp/mnd_stack_dump.txt',
            'getStack failed: $e\n',
            append: true,
          );
        }
        try {
          log('dump: getAllocationProfile...');
          final alloc = await svc
              .getAllocationProfile(id, gc: true)
              .timeout(const Duration(seconds: 20));
          _writeFile('/tmp/mnd_alloc_dump.json', jsonEncode(alloc.toJson()));
          log('dump: allocation profile written');
        } catch (e) {
          log('dump: getAllocationProfile FAILED: $e');
        }
      } catch (e) {
        log('dump: FAILED: $e');
        _writeFile('/tmp/mnd_stack_dump.txt', 'dump failed: $e\n', append: true);
      } finally {
        if (paused) {
          try {
            await svc.resume(id).timeout(const Duration(seconds: 10));
            log('dump: resumed');
          } catch (e) {
            log('dump: resume FAILED: $e');
          }
        }
      }
    }

    void triggerDump(String reason) {
      if (dumpStarted) return;
      dumpStarted = true;
      log('TRIGGER dump: $reason');
      unawaited(dumpStack());
    }

    void writeHang() {
      final dir = logDir;
      if (dir != null) {
        try {
          final file = File('$dir/crash_log.txt');
          file.writeAsStringSync(
            '${DateTime.now().toIso8601String()} 🔴 UI HANG: no heartbeat since '
            '$lastBeat, last step: $lastStep, rss=${_readRssKb() ?? '?'}kB\n',
            mode: FileMode.append,
          );
        } catch (_) {}
      }
      triggerDump('heartbeat stall');
    }

    // Один таймер на всё время жизни: каждый heartbeat сбрасывает его заново.
    void armStall() {
      stallTimer?.cancel();
      stallTimer = Timer(stallTimeout, () {
        final wallGap = DateTime.now().difference(lastBeat).inMilliseconds;
        final monoGap = mono.elapsedMilliseconds - lastBeatMonoMs;
        if (!isRealStall(wallGapMs: wallGap, monoGapMs: monoGap)) {
          // Стена ушла вперёд, а монотонные — нет: процесс не висел,
          // а спал (suspend, SIGSTOP). Даём отсчёт заново и не дёргаем дамп.
          log('sleep: wall +${wallGap}ms при mono +${monoGap}ms — не зависание');
          lastBeat = DateTime.now();
          lastBeatMonoMs = mono.elapsedMilliseconds;
          armStall();
          return;
        }
        writeHang();
        armStall(); // пере-арм: пока UI висит, пишем каждые stallTimeout
      });
    }

    // Независимый опрос RSS: пишет memory_log и ловит скачок памяти даже когда
    // главный изолят заблокирован и heartbeat уже не приходит.
    var lastRss = _readRssKb() ?? 0;
    void rssPoll() {
      final rss = _readRssKb();
      if (rss == null) return;
      if (debugMemory && logDir != null) {
        try {
          File('$logDir/memory_log.txt').writeAsStringSync(
            '${DateTime.now().toIso8601String()} rss=${rss}kB\n',
            mode: FileMode.append,
          );
        } catch (_) {}
      }
      final delta = rss - lastRss;
      if (delta > 300 * 1024) {
        // +300 МБ за ~1 c — аномальный аллокационный шторм. Снимаем дамп сразу,
        // не дожидаясь 5-секундного таймаута heartbeat.
        triggerDump('rss spike +${delta}kB');
      }
      lastRss = rss;
    }

    receivePort.listen((dynamic message) {
      if (message is! List || message.length < 2) return;
      final step = message[0];
      final at = message[1];
      if (step is String) lastStep = step;
      if (at is int) lastBeat = DateTime.fromMillisecondsSinceEpoch(at);
      lastBeatMonoMs = mono.elapsedMilliseconds;
      armStall();
    });

    armStall();
    Timer.periodic(const Duration(seconds: 1), (_) => rssPoll());
    unawaited(initVmService()); // подключаемся заранее, не в момент зависания
  }

  /// Резидентная память процесса в килобайтах (Linux: /proc/self/status).
  /// null на не-Linux платформах или если файл недоступен.
  static int? _readRssKb() {
    if (!Platform.isLinux) return null;
    try {
      for (final line in File('/proc/self/status').readAsLinesSync()) {
        if (line.startsWith('VmRSS:')) {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 2) return int.tryParse(parts[1]);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Синхронная запись файла (не зависит от event loop — работает даже когда
  /// главный изолят уже заблокирован).
  static void _writeFile(String path, String content, {bool append = false}) {
    try {
      File(path).writeAsStringSync(
        content,
        mode: append ? FileMode.append : FileMode.write,
      );
    } catch (_) {}
  }
}
