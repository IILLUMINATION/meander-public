/// Dart-обёртка над статическим валидатором квеста (FFI `validation.rs`).
///
/// Анализирует каталог `quests/<questId>/` в `questRoot` (каталог документов
/// приложения) и возвращает отчёт: диагностики (битые ссылки, дубли id,
/// недостижимые ноды, мёртвые переменные, конфликты видимости onAppear-условий
/// в одном контейнере, мёртвый код после перехода, тупики, мёртвые скрипты,
/// циклы без задержки и расхождение строк таблиц с колонками) и статистику.
/// Диагностики скриптов несут `scriptPath` — по нему редактор открывает
/// источник проблемы.
library;

import 'dart:convert';

import 'package:mnd_core/src/gen/api/validation.dart' as gen;

/// Важность диагностики.
enum QuestSeverity {
  warning,
  error;

  static QuestSeverity fromRaw(String raw) =>
      raw == 'error' ? QuestSeverity.error : QuestSeverity.warning;
}

/// Одна диагностика валидации.
class QuestDiagnostic {
  final QuestSeverity severity;
  final String kind;
  final String message;
  final String? nodeId;
  final String? itemId;
  final String? scriptPath;
  final String? fixHint;  // новая подсказка действия

  const QuestDiagnostic({
    required this.severity,
    required this.kind,
    required this.message,
    this.nodeId,
    this.itemId,
    this.scriptPath,
    this.fixHint,  // новая подсказка действия
  });

  factory QuestDiagnostic.fromJson(Map<String, dynamic> json) => QuestDiagnostic(
        severity: QuestSeverity.fromRaw(json['severity'] as String? ?? 'warning'),
        kind: json['kind'] as String? ?? 'unknown',
        message: json['message'] as String? ?? '',
        nodeId: json['node_id'] as String?,
        itemId: json['item_id'] as String?,
        scriptPath: json['script_path'] as String?,
        fixHint: json['fix_hint'] as String?,  // новая подсказка
      );
}

/// Сводная статистика анализа.
class QuestValidationStats {
  final String questId;
  final int nodes;
  final int templates;
  final int scripts;
  final int items;
  final int warnings;
  final int errors;

  const QuestValidationStats({
    required this.questId,
    required this.nodes,
    required this.templates,
    required this.scripts,
    required this.items,
    required this.warnings,
    required this.errors,
  });

  factory QuestValidationStats.fromJson(Map<String, dynamic> json) =>
      QuestValidationStats(
        questId: json['quest_id'] as String? ?? '',
        nodes: (json['nodes'] as num?)?.toInt() ?? 0,
        templates: (json['templates'] as num?)?.toInt() ?? 0,
        scripts: (json['scripts'] as num?)?.toInt() ?? 0,
        items: (json['items'] as num?)?.toInt() ?? 0,
        warnings: (json['warnings'] as num?)?.toInt() ?? 0,
        errors: (json['errors'] as num?)?.toInt() ?? 0,
      );
}

/// Отчёт валидации квеста.
class QuestValidationReport {
  final QuestValidationStats stats;
  final List<QuestDiagnostic> diagnostics;

  const QuestValidationReport({
    required this.stats,
    required this.diagnostics,
  });

  bool get hasErrors => stats.errors > 0;

  factory QuestValidationReport.fromJson(Map<String, dynamic> json) {
    final rawStats = json['stats'] as Map<String, dynamic>? ?? const {};
    final rawDiags = json['diagnostics'] as List<dynamic>? ?? const [];
    return QuestValidationReport(
      stats: QuestValidationStats.fromJson(rawStats),
      diagnostics: rawDiags
          .whereType<Map<String, dynamic>>()
          .map(QuestDiagnostic.fromJson)
          .toList(),
    );
  }
}

/// Запустить статический анализ квеста.
Future<QuestValidationReport> validateQuest({
  required String questId,
  required String questRoot,
}) async {
  final json = await gen.runQuestValidation(
    questId: questId,
    questRoot: questRoot,
  );
  return QuestValidationReport.fromJson(jsonDecode(json) as Map<String, dynamic>);
}