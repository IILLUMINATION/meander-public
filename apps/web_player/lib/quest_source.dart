/// Источник ассетов квеста для веб-плеера.
///
/// Два режима, один контракт:
///
///  * [QuestBundle] — весь `.mnd` уже в памяти (загрузка архива целиком);
///  * [HttpQuestAssets] — потоковая выдача: маленький boot-бандл плюс
///    ресурсы по требованию, когда бэкенд отдаёт манифест.
///
/// `assetBytes` намеренно **синхронный**: кадр сцены строится за один проход,
/// `Image.memory` и раскладка не умеют ждать. Поэтому потоковый источник
/// отвечает тем, что уже пришло, а недостающее догружает в фоне и зовёт
/// [notifyListeners] — плеер перерисовывает кадр, и картинка появляется. Виджетам
/// не нужно знать, локальный это источник или сетевой.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'quest_bundle.dart';

/// Ассеты квеста, которые видит плеер.
///
/// Наследник [ChangeNotifier]: локальная реализация ничего не уведомляет, а
/// потоковая сообщает о каждой прилетевшей записи.
abstract class QuestAssets extends ChangeNotifier {
  String get questId;

  /// Содержимое `config.json` (заголовок, фон, правила показа).
  Map<String, dynamic> get config;

  /// Сырой `nodes.json` — движок сам вытаскивает поле `nodes`.
  Map<String, dynamic> get nodesJson;

  List<dynamic> get templates;

  /// `scripts/<uuid>.json` → JSON-строка (то, что читает движок с диска).
  Map<String, String> get embeddedScripts;

  /// Записи, доступные прямо сейчас: у локального источника — весь архив,
  /// у потокового — то, что пришло в boot или уже догрузилось.
  Map<String, Uint8List> get assets;

  /// Пути шрифтов квеста (`res/fonts/…`) для `FontLoader`.
  List<String> get fontPaths;

  bool get hasScripts;

  /// Байты ресурса по «источнику» автора. `null` — этого ресурса сейчас нет;
  /// потоковый источник такую запись уже поставил в очередь на загрузку.
  Uint8List? assetBytes(String? source);

  /// Прогрев пачки источников (следующая нода, превью): догружает их до
  /// первого запроса. У локального источника — ничего не делает.
  Future<void> prefetch(Iterable<String?> sources) async {}
}

/// Открыть квест по URL: потоково, если бэкенд это умеет, иначе архивом.
///
/// [base] — префикс потоковых путей; по умолчанию берётся из `?base=`
/// страницы либо выводится из [url] отбрасыванием `.mnd`. Параметр страницы
/// `?stream=0` выключает потоковый режим целиком.
Future<QuestAssets> openQuestAssets(
  String url, {
  String? base,
  http.Client? client,
}) async {
  final page = Uri.base.queryParameters;
  if (base == null && page['stream'] == '0') {
    return loadQuestBundle(url, client: client);
  }
  final root = base == null ? _streamBase(url) : _trimSlashes(base);
  if (root == null) return loadQuestBundle(url, client: client);

  final owned = client == null;
  final session = client ?? http.Client();
  try {
    final manifest = await _loadManifest(session, root);
    final boot = await session.get(Uri.parse('$root/boot'));
    if (boot.statusCode != 200) {
      throw QuestLoadException('Boot-бандл не пришёл: HTTP ${boot.statusCode}');
    }
    return HttpQuestAssets._(
      root: root,
      client: session,
      manifest: manifest,
      boot: decodeMnd(boot.bodyBytes, '$root/boot'),
    );
  } catch (e) {
    debugPrint(
      '[web-player] потоковая выдача недоступна ($e) — качаю архив целиком',
    );
    // Свой клиент закрываем, чужой (тестовый) отдаём дальше: иначе откат
    // ушёл бы в реальную сеть вместо подставленного клиента.
    if (owned) session.close();
    return loadQuestBundle(url, client: owned ? null : session);
  }
}

const int _manifestVersion = 1;

class _Manifest {
  const _Manifest({required this.questId, required this.entries});

  final String questId;

  /// Пути записей архива: единственный список того, что вообще существует.
  final Set<String> entries;
}

Future<_Manifest> _loadManifest(http.Client client, String root) async {
  final response = await client.get(Uri.parse('$root/manifest'));
  if (response.statusCode != 200) {
    throw QuestLoadException('Манифест не пришёл: HTTP ${response.statusCode}');
  }
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  if (decoded is! Map<String, dynamic>) {
    throw const QuestLoadException('Манифест не JSON-объект');
  }
  final version = decoded['version'];
  if (version is! int || version != _manifestVersion) {
    throw QuestLoadException('Непонятная версия манифеста: $version');
  }
  return _Manifest(
    questId: decoded['questId']?.toString() ?? '',
    entries: {
      for (final entry in (decoded['entries'] as List? ?? const []))
        if (entry is Map && entry['path'] is String) entry['path'] as String,
    },
  );
}

/// Сетевой источник: boot-бандл плюс ресурсы по требованию.
///
/// Внутри boot — тот же архив квеста, только текстовый, поэтому JSON-часть
/// (ноды, шаблоны, скрипты, шрифты) разбирается общим [decodeMnd]. Медиа
/// подтягивается записью и живёт в LRU-кэше.
class HttpQuestAssets extends QuestAssets {
  HttpQuestAssets._({
    required String root,
    required http.Client client,
    required _Manifest manifest,
    required QuestBundle boot,
  }) : _root = root,
       _client = client,
       _boot = boot,
       _known = manifest.entries;

  /// Сколько записей тянем одновременно: браузер всё равно держит ~6
  /// соединений на хост, а больший параллелизм только отнимает полосу
  /// у boot и у следующих нод.
  static const int _parallelism = 6;

  /// Потолок кэша медиа в памяти. Крупные видео не вытесняют из кэша весь
  /// остальной квест: запись больше лимита просто не кэшируется.
  static const int _cacheLimitBytes = 64 << 20;

  final String _root;
  final http.Client _client;
  final QuestBundle _boot;
  final Set<String> _known;

  /// Путь → байты, порядок вставки используется как очередь вытеснения.
  final Map<String, Uint8List> _cache = {};
  int _cacheBytes = 0;
  Map<String, Uint8List>? _assetsView;

  final List<String> _pending = [];
  final Map<String, Completer<void>> _inFlight = {};
  int _active = 0;

  @override
  String get questId => _boot.questId;

  @override
  Map<String, dynamic> get config => _boot.config;

  @override
  Map<String, dynamic> get nodesJson => _boot.nodesJson;

  @override
  List<dynamic> get templates => _boot.templates;

  @override
  Map<String, String> get embeddedScripts => _boot.embeddedScripts;

  @override
  bool get hasScripts => _boot.hasScripts;

  /// Всё, что уже в памяти: boot (тексты, шрифты) плюс догруженные записи.
  /// Map живая, но перестраивается только при изменении содержимого.
  @override
  Map<String, Uint8List> get assets => _assetsView ??= {..._boot.assets, ..._cache};

  @override
  List<String> get fontPaths => _boot.fontPaths;

  @override
  Uint8List? assetBytes(String? source) {
    final candidates = _boot.assetPathCandidates(source);
    for (final path in candidates) {
      final bytes = _local(path);
      if (bytes != null) return bytes;
    }
    // Ничего из кандидатов ещё нет: просим первый, который вообще есть в
    // архиве (манифест — единственный источник правды о содержимом).
    for (final path in candidates) {
      if (_known.contains(path)) {
        _schedule(path);
        break;
      }
    }
    return null;
  }

  @override
  Future<void> prefetch(Iterable<String?> sources) async {
    final waits = <Future<void>>[];
    for (final source in sources) {
      for (final path in _boot.assetPathCandidates(source)) {
        if (_local(path) != null) break;
        if (!_known.contains(path)) continue;
        _schedule(path);
        final done = _inFlight[path];
        if (done != null) waits.add(done.future);
        break;
      }
    }
    await Future.wait(waits);
  }

  Uint8List? _local(String path) {
    final bytes = _cache.remove(path);
    if (bytes != null) {
      // Попадание поднимает запись в очереди вытеснения (LRU).
      _cache[path] = bytes;
      return bytes;
    }
    return _boot.assets[path];
  }

  void _schedule(String path) {
    if (_cache.containsKey(path) || _inFlight.containsKey(path)) return;
    _inFlight[path] = Completer<void>();
    _pending.add(path);
    _pump();
  }

  void _pump() {
    while (_active < _parallelism && _pending.isNotEmpty) {
      final path = _pending.removeAt(0);
      _active++;
      unawaited(
        _load(path).whenComplete(() {
          _active--;
          _inFlight.remove(path)?.complete();
          _pump();
        }),
      );
    }
  }

  Future<void> _load(String path) async {
    final uri = _entryUri(_root, path);
    try {
      final response = await _client.get(uri);
      if (response.statusCode != 200) {
        debugPrint(
          '[web-player] запись не пришла: HTTP ${response.statusCode} ($uri)',
        );
        return;
      }
      _put(path, response.bodyBytes);
    } catch (e) {
      debugPrint('[web-player] запись не загрузилась ($uri): $e');
    }
  }

  void _put(String path, Uint8List bytes) {
    if (bytes.length > _cacheLimitBytes) return;
    _cache.remove(path);
    _cache[path] = bytes;
    _cacheBytes += bytes.length;
    while (_cacheBytes > _cacheLimitBytes && _cache.length > 1) {
      final oldest = _cache.keys.first;
      _cacheBytes -= _cache.remove(oldest)!.length;
    }
    _assetsView = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

/// Путь записи внутри архива — сегментами, чтобы пробелы и не-ASCII имена
/// ресурсов уехали в сеть корректно закодированными.
Uri _entryUri(String root, String path) {
  final base = Uri.parse(root);
  return base.replace(
    pathSegments: [
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      'entry',
      ...path.split('/'),
    ],
    query: null,
    fragment: null,
  );
}

/// Префикс потоковых путей из URL квеста: `…/quest-src/<id>.mnd` → `…/quest-src/<id>`.
String? _streamBase(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null || parsed.host.isEmpty) return null;
  var path = parsed.path;
  if (path.endsWith('.mnd')) {
    path = path.substring(0, path.length - 4);
  } else if (path.endsWith('/file')) {
    path = path.substring(0, path.length - '/file'.length);
  } else {
    return null;
  }
  return _trimSlashes(parsed.replace(path: path, query: null, fragment: null).toString());
}

String _trimSlashes(String value) {
  var out = value.trim();
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}
