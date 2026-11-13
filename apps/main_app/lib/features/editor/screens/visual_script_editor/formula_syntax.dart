/// Проверка синтаксиса формулы/шаблона перед сохранением.
///
/// Ловит то, что движок молча превращает в `null`: незакрытые `{`, `[`, `(`
/// и кавычки. Пример живой ошибки: `{{Оружие["Картинка"][Оружие]}` —
/// значение не вычисляется, а автор видит пустую картинку и не понимает,
/// почему: внешняя `{{` закрыта одной `}`.
///
/// Проверка чисто структурная (баланс скобок вне строковых литералов), без
/// разбора грамматики: ложных срабатываний на валидных формулах быть не
/// должно, поэтому спорные конструкции (условные выражения, `in`) не
/// разбираются вовсе.
library;

import 'package:canvas_app/core/l10n/l10n.dart';

/// Возвращает описание проблемы или `null`, если скобки и кавычки сходятся.
String? formulaSyntaxError(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  final open = <String>[];
  var quote = '';
  var escaped = false;

  for (var i = 0; i < text.length; i++) {
    final c = text[i];

    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == quote) {
        quote = '';
      }
      continue;
    }

    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }

    if (c == '{' || c == '[' || c == '(') {
      open.add(c);
      continue;
    }

    if (c == '}' || c == ']' || c == ')') {
      if (open.isEmpty) {
        return trf('Лишняя «{p0}» без открывающей', {'p0': c});
      }
      final last = open.removeLast();
      if (!_pairs(last, c)) {
        return trf(
          'Скобка «{p0}» закрывает «{p1}» — порядок нарушен',
          {'p0': c, 'p1': last},
        );
      }
    }
  }

  if (quote.isNotEmpty) {
    return trf('Не закрыта кавычка {p0}', {'p0': quote});
  }
  if (open.isEmpty) return null;
  final last = open.last;
  final closing = switch (last) {
    '{' => '}',
    '[' => ']',
    _ => ')',
  };
  return trf('Не закрыта «{p0}» — нужна «{p1}»', {'p0': last, 'p1': closing});
}

bool _pairs(String open, String close) => switch (open) {
  '{' => close == '}',
  '[' => close == ']',
  '(' => close == ')',
  _ => false,
};