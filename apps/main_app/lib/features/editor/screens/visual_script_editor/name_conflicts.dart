/// Имя из [taken], конфликтующее с [candidate] без учёта регистра и
/// окружающих пробелов, либо `null`, если имя свободно.
///
/// Переменные и таблицы живут в одном пространстве имён формул: переменная
/// `Оружие` рядом с таблицей `Оружие` делает `table_cell(Оружие, …)`
/// нерабочим (первый аргумент резолвится в переменную), а переименование
/// такой пары задевает оба объявления сразу. Поэтому при создании и
/// переименовании проверяем оба списка одной функцией.
///
/// [ignore] — имя, которое разрешено совпасть (переименование в себя или
/// смена регистра уже существующего объявления).
String? conflictingName(
  String candidate,
  Iterable<String> taken, {
  String? ignore,
}) {
  final needle = candidate.trim().toLowerCase();
  if (needle.isEmpty) return null;
  final ignored = ignore?.trim().toLowerCase();
  for (final name in taken) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) continue;
    if (ignored != null && normalized == ignored) continue;
    if (normalized == needle) return name;
  }
  return null;
}