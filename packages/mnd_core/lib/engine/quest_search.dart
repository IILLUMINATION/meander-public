/// Поиск по всему квесту (FFI `mnd_core::quest_search`).
///
/// Обход файлов делает Rust: один вызов на запрос вместо асинхронного чтения
/// каждой ноды из Dart. Модель повторяет JSON-отчёт `SearchReport`: попадания
/// сгруппированы клиентом по [kind], `totals` считают все совпадения (в выдачу
/// попадает не больше `limitPerKind` на вид), `elapsedMs` — стоимость поиска.
library;

import 'dart:convert';

import 'package:mnd_core/src/gen/api/quest_search.dart' as gen;

/// Вид результата.
enum QuestSearchKind {
  node('node'),
  script('script'),
  lua('lua'),
  table('table'),
  variable('variable'),
  resource('resource');

  const QuestSearchKind(this.raw);

  /// Ключ вида в JSON — данные, их не переименовываем без клиента.
  final String raw;

  static QuestSearchKind? fromRaw(String raw) {
    for (final kind in values) {
      if (kind.raw == raw) return kind;
    }
    return null;
  }
}

/// Одно попадание поиска.
class QuestSearchHit {
  const QuestSearchHit({
    required this.kind,
    required this.id,
    required this.title,
    this.context = '',
    this.snippet = '',
  });

  final QuestSearchKind kind;

  /// Чем открывается результат: id ноды, имя файла, имя таблицы/переменной.
  final String id;
  final String title;

  /// Где нашлось: «название ноды», папка скрипта, «таблица».
  final String context;

  /// Кусок текста со совпадением; пустой, если совпало название.
  final String snippet;

  factory QuestSearchHit.fromJson(Map<String, dynamic> json) {
    final kind =
        QuestSearchKind.fromRaw(json['kind'] as String? ?? '') ??
        QuestSearchKind.node;
    return QuestSearchHit(
      kind: kind,
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      context: json['context'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
    );
  }
}

/// Отчёт поиска.
class QuestSearchReport {
  const QuestSearchReport({
    required this.query,
    required this.hits,
    required this.totals,
    required this.total,
    required this.matches,
    required this.elapsedMs,
    required this.limitPerKind,
  });

  final String query;
  final List<QuestSearchHit> hits;

  /// Все совпадения по видам — включая не попавшие в выдачу.
  final Map<QuestSearchKind, int> totals;

  /// Сколько попаданий в выдаче.
  final int total;

  /// Сколько всего совпадений нашлось.
  final int matches;

  /// Время поиска в миллисекундах (считает Rust).
  final int elapsedMs;
  final int limitPerKind;

  factory QuestSearchReport.fromJson(Map<String, dynamic> json) {
    final rawTotals = json['totals'] as Map<String, dynamic>? ?? const {};
    final totals = <QuestSearchKind, int>{};
    for (final entry in rawTotals.entries) {
      final kind = QuestSearchKind.fromRaw(entry.key);
      if (kind != null) totals[kind] = (entry.value as num).toInt();
    }
    final hits = (json['hits'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(QuestSearchHit.fromJson)
        .toList(growable: false);
    return QuestSearchReport(
      query: json['query'] as String? ?? '',
      hits: hits,
      totals: totals,
      total: (json['total'] as num?)?.toInt() ?? hits.length,
      matches: (json['matches'] as num?)?.toInt() ?? hits.length,
      elapsedMs: (json['elapsed_ms'] as num?)?.toInt() ?? 0,
      limitPerKind: (json['limit_per_kind'] as num?)?.toInt() ?? 12,
    );
  }
}

/// Найти [query] по нодам, скриптам, таблицам, переменным и ресурсам квеста.
Future<QuestSearchReport> searchQuest({
  required String questId,
  required String questRoot,
  required String query,
  int? limitPerKind,
}) async {
  final json = await gen.searchQuest(
    questId: questId,
    questRoot: questRoot,
    query: query,
    limitPerKind: limitPerKind,
  );
  return QuestSearchReport.fromJson(jsonDecode(json) as Map<String, dynamic>);
}
