/// Точка входа веб-плеера: адрес квеста → `.mnd` → экран игры.
///
/// Квест берётся по ссылке: `?url=` (что угодно, что отдаёт байты архива, —
/// в том числе локальная раздача для отладки) или `?quest=<id>` (публичная
/// загрузка маркета). Плюс `?node=<id>` — войти не в стартовую ноду.
///
/// Экспорт квеста — это та же оболочка плюс `quest.mnd` рядом с `index.html`
/// (`scripts/build_quest_web.sh`). Такой архив подхватывается сам, без ссылки
/// в адресной строке: автор открывает папку и сразу играет. Без встроенного
/// архива показываем поле ввода — дев-сборка и «принеси свой .mnd».
library;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'play_screen.dart';
import 'player.dart';
import 'quest_source.dart';

/// Куда кладёт архивы раздача того же origins, что и плеер. Браузер пускает
/// запрос только на свои домены: страница живёт под COEP, а чужой хост без
/// CORS-заголовков просто не отдал бы байты. На проде этот путь отдаёт каталог
/// маркета. С 11.10 он ведёт не прямой alias на диск, а в Node
/// (`/quest-src/ → GET /static/downloads/`), иначе отклонённую сборку можно было
/// скачать в обход проверки публикации; байты по-прежнему отдаёт nginx.
const String _questSrcPath = '/quest-src/';

/// Архив, положенный рядом с оболочкой экспортёром (`scripts/build_quest_web.sh`).
const String _bakedQuestPath = 'quest.mnd';

void main() {
  runApp(const MeanderWebPlayerApp());
}

class MeanderWebPlayerApp extends StatelessWidget {
  const MeanderWebPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meander',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C853),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0D10),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const QuestLauncher(),
    );
  }
}

/// Разбирает ссылку из адресной строки и запускает игру.
class QuestLauncher extends StatefulWidget {
  const QuestLauncher({super.key});

  @override
  State<QuestLauncher> createState() => _QuestLauncherState();
}

class _QuestLauncherState extends State<QuestLauncher> {
  late final TextEditingController _field;
  String? _inputError;

  @override
  void initState() {
    super.initState();
    final params = Uri.base.queryParameters;
    final link = params['url'] ?? _marketLink(params['quest']);
    _field = TextEditingController(text: link ?? params['quest'] ?? '');
    if (link != null) {
      // Deep-link: играть сразу, без лишних кликов.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openQuest(
          url: link,
          startNodeId: params['node'],
        ),
      );
    } else {
      // Экспорт «оболочка + quest.mnd»: ссылки в адресе нет, архив лежит
      // рядом со страницей.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openBakedQuest(startNodeId: params['node']),
      );
    }
  }

  /// Открыть архив, положенный рядом с оболочкой, если он есть.
  ///
  /// HEAD, чтобы не качать мегабайты дважды; если хостинг не разрешает HEAD —
  /// пробуем GET. Отсутствие файла (404) — это обычная дев-сборка, остаётся
  /// экран со ссылкой.
  Future<void> _openBakedQuest({String? startNodeId}) async {
    final url = _resolveLink(_bakedQuestPath);
    bool exists = false;
    try {
      final head = await http.head(Uri.parse(url));
      // Браузерный fetch не отдаёт Content-Length у HEAD (len=0), поэтому
      // существование — это сам 200: 404 приходит как 404.
      exists = head.statusCode == 200;
      if (head.statusCode == 405 || head.statusCode == 501) {
        final get = await http.get(Uri.parse(url));
        exists = get.statusCode == 200 && get.bodyBytes.isNotEmpty;
      }
    } catch (_) {
      exists = false;
    }
    if (!mounted || !exists) return;
    _openQuest(url: url, startNodeId: startNodeId);
  }

  /// Относительная ссылка считается от страницы: `?url=/quests/x.mnd` или
  /// `?url=x.mnd` должны работать без полного URL с хостом.
  static String _resolveLink(String raw) {
    final value = raw.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) return value;
    return Uri.base.resolve(value).toString();
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  static String? _marketLink(String? questId) {
    final id = questId?.trim();
    if (id == null || id.isEmpty) return null;
    return '$_questSrcPath$id.mnd';
  }

  /// Без схемы это id квеста из маркета.
  String _normalize(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return value;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    return _marketLink(value) ?? value;
  }

  void _openQuest({String? url, String? startNodeId, String? questId}) {
    final raw = (url ?? _marketLink(questId) ?? '').trim();
    if (raw.isEmpty) {
      setState(() => _inputError = 'Нужна ссылка на архив квеста');
      return;
    }
    final link = _resolveLink(raw);
    setState(() => _inputError = null);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            QuestRoute(url: link, startNodeId: startNodeId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Meander',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Квест в браузере: движок считает сцены прямо здесь, архив '
                  'никуда не отправляется.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _field,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Ссылка на .mnd или id квеста',
                    hintText: 'https://…/quest.mnd',
                    errorText: _inputError,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (value) =>
                      _openQuest(url: _normalize(value)),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => _openQuest(url: _normalize(_field.text)),
                  child: const Text('Играть'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Маршрут, владеющий игроком: грузит архив, запускает движок и освобождает
/// его при выходе из игры.
class QuestRoute extends StatefulWidget {
  const QuestRoute({super.key, required this.url, this.startNodeId});

  final String url;
  final String? startNodeId;

  @override
  State<QuestRoute> createState() => _QuestRouteState();
}

class _QuestRouteState extends State<QuestRoute> {
  QuestPlayer? _player;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bundle = await openQuestAssets(widget.url);
      if (!mounted) return;
      final player = QuestPlayer(bundle);
      setState(() {
        _player = player;
        _loading = false;
      });
      await player.start(startNodeId: widget.startNodeId);
    } catch (e) {
      debugPrint('[web-player] bundle load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Загрузка квеста…',
                style: TextStyle(color: Theme.of(context).primaryTextTheme.bodyMedium?.color),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_off, size: 40, color: Colors.redAccent),
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Назад'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _load,
                      child: const Text('Повторить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    return PlayScreen(player: _player!);
  }
}
