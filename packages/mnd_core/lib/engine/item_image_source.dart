/// Переопределения источника картинки, которые назначает скрипт.
///
/// Блок `set_image` пишет в служебную переменную движка
/// `_internal_item_sources` — вида `{itemId: "res/images/cat.png"}`. Держим
/// ключ и чтение здесь, чтобы клиент не выдумывал имя переменной сам, а
/// модель айтема не мутировалась: значение живёт в состоянии игры, поэтому
/// попадает в сейв и восстанавливается из него.
library;

const String kItemSourceVar = '_internal_item_sources';

/// Источник картинки, назначенный айтему [itemId] скриптом (или null).
///
/// В инстансе шаблона айтем носит производный `tpl_*` id, а скрипт мастера
/// адресует его по id мастера. Движок при исполнении раскладывает
/// переопределение на все инстансы (и на сам мастер), так что здесь всё
/// сводится к поиску по id раскрытого айтема.
String? itemSourceOverride(Map<String, dynamic> variables, String itemId) {
  final overrides = variables[kItemSourceVar];
  if (overrides is! Map) return null;
  final value = overrides[itemId]?.toString().trim();
  return (value == null || value.isEmpty) ? null : value;
}
