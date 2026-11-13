import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Состояние палитры редактора формул между открытиями: какие разделы
/// функций были раскрыты и что автор вставляет чаще всего.
///
/// Палитра «Функции» — длинный список из сотен строк, и каждый раз искать
/// в нём `table_cell` заново бессмысленно. Раскрытые разделы и частые
/// вставки храним в `SharedPreferences`: это пользовательская настройка
/// инструмента, а не данные квеста, и она не должна попадать в экспорт.
///
/// Разделы адресуются индексом в списке групп, а не заголовком: заголовки
/// локализуются и меняются при смене языка.
class ExpressionPadState {
  /// Индексы раскрытых групп. `null` — пользователь ещё ничего не выбирал,
  /// открываем раздел по умолчанию (первый).
  final Set<int>? openGroups;

  /// Вставленные элементы по убыванию частоты.
  final List<String> frequent;

  const ExpressionPadState({this.openGroups, this.frequent = const []});
}

class ExpressionPadStore {
  static const String _key = 'expression_editor.pad_state';
  static const int _maxFrequent = 8;
  static const int _maxCounters = 60;

  /// Наибольшая длина текста, который имеет смысл запоминать как «частый»:
  /// формулы и куски текста из буфера в список частых не идут.
  static const int maxTrackedLength = 24;

  static final RegExp _digit = RegExp(r'^[0-9]$');

  static Future<ExpressionPadState> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const ExpressionPadState();
      final data = jsonDecode(raw);
      if (data is! Map) return const ExpressionPadState();
      final open = data['open'];
      final counts = data['counts'];
      final frequent = <String>[];
      if (counts is Map) {
        final entries = <MapEntry<String, int>>[];
        counts.forEach((key, value) {
          final count = value is int ? value : int.tryParse('$value') ?? 0;
          if (key is String && count > 0) {
            entries.add(MapEntry(key, count));
          }
        });
        entries.sort((a, b) => b.value.compareTo(a.value));
        frequent.addAll(entries.take(_maxFrequent).map((e) => e.key));
      }
      Set<int>? openGroups;
      if (open is List) {
        openGroups = <int>{};
        for (final value in open) {
          final index = value is int ? value : int.tryParse('$value');
          if (index != null && index >= 0) openGroups.add(index);
        }
      }
      return ExpressionPadState(
        openGroups: openGroups,
        frequent: frequent,
      );
    } catch (_) {
      // Битые настройки не должны ломать редактор — просто начинаем с нуля.
      return const ExpressionPadState();
    }
  }

  /// Сохраняет набор раскрытых групп, при необходимости обновляя и счётчики.
  static Future<void> saveOpenGroups(Set<int> open) async {
    await _update((data) => data['open'] = open.toList()..sort());
  }

  /// Учитывает вставку: короткие фрагменты (`[`, `{HP}`, `round(x)`) —
  /// кандидаты в «частые», длинный текст и многострочные вставки — нет.
  static Future<void> recordInsert(String text, {Set<int>? openGroups}) async {
    final value = text.trim();
    // Одиночная цифра — не «частый элемент», а просто набор числа.
    final singleDigit = value.length == 1 && _digit.hasMatch(value);
    if (value.isEmpty ||
        singleDigit ||
        value.length > maxTrackedLength ||
        value.contains('\n')) {
      if (openGroups != null) await saveOpenGroups(openGroups);
      return;
    }
    await _update((data) {
      final counts = <String, int>{};
      final raw = data['counts'];
      if (raw is Map) {
        raw.forEach((key, count) {
          if (key is String) {
            counts[key] = count is int ? count : int.tryParse('$count') ?? 0;
          }
        });
      }
      counts[value] = (counts[value] ?? 0) + 1;
      if (counts.length > _maxCounters) {
        final sorted = counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        data['counts'] = Map<String, int>.fromEntries(
          sorted.take(_maxCounters),
        );
      } else {
        data['counts'] = counts;
      }
      final open = openGroups;
      if (open != null) data['open'] = open.toList()..sort();
    });
  }

  static Future<void> _update(void Function(Map<String, dynamic> data) change) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      final data = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      change(data);
      await prefs.setString(_key, jsonEncode(data));
    } catch (_) {
      // Настройка палитры: сбой записи не должен ронять редактор.
    }
  }
}