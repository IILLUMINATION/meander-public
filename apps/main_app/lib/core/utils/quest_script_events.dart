/// Примитивы событий визуального скрипта, зеркало Rust-ядра
/// (`executor::get_block_event_type` / `executor::declares_event`).
///
/// Реестра «глобальные скрипты» в конфиге больше нет: движок сам находит
/// скрипты запуска квеста по объявленному событию, поэтому все инструменты —
/// чистильщик и веб-плеер — должны спрашивать об этом сам файл скрипта.
library;

/// Тип события event-блока: `eventType`, а для старых файлов — русский title.
/// `null`, если блок не событие нужного вида.
String? blockEventType(Map block) {
  final type = block['eventType']?.toString().trim() ?? '';
  if (type.isNotEmpty) return type;
  switch (block['title']?.toString().trim() ?? '') {
    case 'При запуске квеста':
      return 'onQuestStart';
    case 'При запуске ноды':
      return 'onNodeEnter';
    case 'При нажатии':
      return 'onPress';
    case 'При изменении данных':
      return 'onDataChange';
    case 'Функция':
      return 'function';
  }
  return null;
}

/// Объявляет ли скрипт событие «При запуске квеста» явным event-блоком.
///
/// Плоский скрипт без обёртки не считается: при автораскопке `scripts/`
/// он иначе запустился бы на старте каждого квеста.
bool declaresQuestStartEvent(dynamic blocks) {
  if (blocks is! List) return false;
  for (final block in blocks.whereType<Map>()) {
    if (block['type']?.toString() != 'event') continue;
    if (blockEventType(block) == 'onQuestStart') return true;
  }
  return false;
}
