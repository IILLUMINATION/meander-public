import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/shared/script_contracts.dart';

// ============================================================================
//  ScriptParser — ЕДИНСТВЕННАЯ точка входа загрузки скриптов.
//
//  Задачи парсера:
//   1. Нормализовать легаси-форматы (title-события, milliseconds,
//      variable/comparison-условия, русские алиасы типов) к канону,
//      который понимает VisualScriptBlock.fromJson.
//   2. Делегировать разбор в block_models — там один диспетчер на все
//     типы (включая while/for_each). Второй свитч с собственными
//     правилами здесь больше не живёт: рассинхрон двух парсеров уже
//     однажды молча уничтожил блоки (while выпадал, автосейв записывал
//     пустоту поверх файла).
//
//  Неизвестные типы и ошибки парсинга НЕ выбрасываются и не заменяются
//  заглушками — они превращаются в UnknownBlock, который сериализуется
//  обратно в исходный JSON без потерь.
// ============================================================================

class ScriptParser {
  static List<VisualScriptBlock> parseBlocks(List<dynamic> blocksJson) {
    return blocksJson
        .whereType<Map>()
        .map(
          (blockJson) =>
              VisualScriptBlock.fromJson(_normalize(Map<String, dynamic>.from(
            blockJson,
          ))),
        )
        .toList();
  }

  /// Приводит легаси/алиасы к каноническому виду. Возвращает НОВУЮ карту,
  /// исходный JSON не мутирует (важно для UnknownBlock → raw round-trip).
  static Map<String, dynamic> _normalize(Map<String, dynamic> json) {
    final out = Map<String, dynamic>.of(json);

    // ── Алиасы типов ──────────────────────────────────────────────────
    const typeAliases = <String, String>{
      'задержка': BlockTypes.wait,
      'условие': BlockTypes.condition,
      'create_variable': BlockTypes.assignVariable,
      'set_variable': BlockTypes.assignVariable,
      'создать_переменную': BlockTypes.assignVariable,
      'изменить_переменную': BlockTypes.assignVariable,
      'while_loop': BlockTypes.whileLoop,
      'пока': BlockTypes.whileLoop,
      'видимость': BlockTypes.setVisible,
      'верхняя_панель': BlockTypes.setTopPanel,
    };
    final rawType = out['type']?.toString();
    if (rawType != null && typeAliases.containsKey(rawType)) {
      out['type'] = typeAliases[rawType];
    }

    // ── Легаси-события: тип зашит в title ─────────────────────────────
    final type = out['type'];
    if ((type == null && out.containsKey('title')) ||
        (type == 'event' && out['eventType'] == null)) {
      out['type'] = BlockTypes.event;
      final title = out['title'];
      if (out['eventType'] == null) {
        if (title == 'При запуске квеста') {
          out['eventType'] = EventType.onQuestStart.name;
        } else if (title == 'При запуске ноды') {
          out['eventType'] = EventType.onNodeEnter.name;
        } else if (title == 'При нажатии') {
          out['eventType'] = EventType.onPress.name;
        } else if (title == 'При изменении данных') {
          out['eventType'] = EventType.onDataChange.name;
        } else if (title == 'Функция') {
          out['eventType'] = EventType.function.name;
        } else {
          out['eventType'] = EventType.onContentAppear.name;
        }
      }
    }

    // ── Легаси-задержка: milliseconds вместо expression ───────────────
    if (out['type'] == BlockTypes.wait &&
        !out.containsKey('expression') &&
        out.containsKey('milliseconds')) {
      out['expression'] = out['milliseconds'].toString();
    }

    // ── Легаси-условие: variable/comparison/value вместо expression ───
    if (out['type'] == BlockTypes.condition && !out.containsKey('expression')) {
      final variable = (out['variable'] ?? out['переменная'] ?? '').toString();
      final comparison =
          (out['comparison'] ?? out['сравнение'] ?? '==').toString();
      final value = (out['value'] ?? out['значение'] ?? '0').toString();

      final isNumeric = num.tryParse(value) != null;
      final isVariable = value.startsWith('{') && value.endsWith('}');
      final needsQuotes = !isNumeric &&
          !isVariable &&
          !value.startsWith("'") &&
          !value.startsWith('"');
      final valueStr = needsQuotes ? "'$value'" : value;

      out['expression'] = '{$variable} $comparison $valueStr';
    }
    // Русские алиасы веток условия: переносим и УДАЛЯЕМ оригиналы
    // (паритет с ядром — golden-фикстуры сравнивают байт-в-байт).
    if (out['type'] == BlockTypes.condition) {
      final legacyThen = out.remove('если_да');
      if (legacyThen != null && !out.containsKey('then_blocks')) {
        out['then_blocks'] = legacyThen;
      }
      final legacyElse = out.remove('если_нет');
      if (legacyElse != null && !out.containsKey('else_blocks')) {
        out['else_blocks'] = legacyElse;
      }
    }

    return out;
  }

  /// Офлайн-нормализация одного блока (fallback, когда FFI недоступен).
  /// Паритет с ядром проверяется golden-фикстурами.
  static Map<String, dynamic> normalizeBlockJson(Map<String, dynamic> json) =>
      _normalize(json);

  /// Рекурсивная нормализация списка блоков (blocks/children/then/else).
  static List<dynamic> normalizeScriptBlocks(List<dynamic> blocks) => blocks
      .whereType<Map>()
      .map((raw) {
        final block = _normalize(Map<String, dynamic>.from(raw));
        for (final key in const [
          'blocks',
          'children',
          'then_blocks',
          'else_blocks',
        ]) {
          final value = block[key];
          if (value is List) block[key] = normalizeScriptBlocks(value);
        }
        return block;
      })
      .toList();

  static Map<String, dynamic> serializeBlocks(List<VisualScriptBlock> blocks) {
    return {'blocks': blocks.map((block) => block.toJson()).toList()};
  }
}
