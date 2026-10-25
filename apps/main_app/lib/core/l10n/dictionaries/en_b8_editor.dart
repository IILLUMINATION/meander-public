/// Редактор: канвас, ноды, стек, визуальные скрипты, проверки квеста.
///
/// Ключ — русская строка ровно как в коде (регистр и знаки включно).
final Map<String, String> enB8Editor = {
  // features/editor/logic/item_editor_helper.dart
  'Задержка (сек)': 'Delay (sec)',
  // features/editor/screens/button_module_preview_screen.dart
  'Превью компоновки': 'Layout preview',
  // features/editor/screens/button_style_presets_screen.dart
  'Импортировано: {p0}, пропущено: {p1}': 'Imported: {p0}, skipped: {p1}',
  'Черновик': 'Draft',
  'Экспорт готов': 'Export is ready',
  'Экспорт готов, пропущено текстур: {p0}':
      'Export is ready, textures skipped: {p0}',
  // features/editor/screens/canvas_screen.dart
  'Нода «{p0}» вставлена': 'Node "{p0}" inserted',
  'Нода «{p0}» вставлена (ресурсов: {p1}, пропущено: {p2})':
      'Node "{p0}" inserted (resources: {p1}, skipped: {p2})',
  'Обычные': 'Regular',
  // features/editor/screens/node_content/button_editor_screen.dart
  'Выберите целевую ноду для перехода': 'Choose the node to go to',
  // features/editor/screens/node_content/container_editor_screen.dart
  '4 px по горизонтали': '4 px horizontally',
  '8 px снизу': '8 px at the bottom',
  'Текст: Авто (по квесту)': 'Text: auto (per quest)',
  'Текст: Масштабирование': 'Text: scaling',
  'Текст: Перенос': 'Text: wrapping',
  // features/editor/screens/node_content/content_item_card.dart
  'Мастер шаблона: {p0}': 'Template author: {p0}',
  'Отправитель': 'Sender',
  'Связан с шаблоном': 'Linked to a template',
  'Связан с шаблоном: {p0}': 'Linked to a template: {p0}',
  'Шаблон удалён или недоступен': 'The template is deleted or unavailable',
  // features/editor/screens/node_content/modal_editor_screen.dart
  'Выполнение скрипта': 'Script running',
  'Закрыть окно': 'Close the window',
  'Нет действия': 'No action',
  // features/editor/screens/node_content/stack_canvas/stack_canvas_item.dart
  'Колонка': 'Column',
  // features/editor/screens/node_content/stack_canvas/stack_canvas_screen.dart
  ' · ещё {p0}': ' · {p0} more',
  '{p0} элементов · {p1}×{p2}': '{p0} items · {p1}x{p2}',
  'Вписать': 'Fit',
  'Заполнить': 'Fill',
  'Мозаика': 'Tile',
  'Растянуть': 'Stretch',
  'блокировка': 'locked',
  'за краем холста': 'off-canvas',
  'замок снят': 'unlocked',
  'координаты': 'coordinates',
  'нулевой размер': 'zero size',
  'обводка убрана': 'outline removed',
  'размер': 'size',
  'толщина обводки': 'outline thickness',
  'цвет обводки': 'outline color',
  // features/editor/screens/node_content/video_editor_screen.dart
  'URL видео (mp4/webm)': 'Video URL (mp4/webm)',
  'YouTube ссылка': 'YouTube link',
  // features/editor/screens/node_selection_screen.dart
  'В этом квесте пока нет других нод': 'This quest has no other nodes yet',
  'В этом квесте пока нет нод': 'This quest has no nodes yet',
  'Попробуйте изменить запрос': 'Try a different search',
  // features/editor/screens/tags_screen.dart
  '{p0} (из шаблона)': '{p0} (from a template)',
  'Глава «{p0}» вставлена (нод: {p1}, связей: {p2})':
      'Chapter "{p0}" inserted (nodes: {p1}, links: {p2})',
  'Глава «{p0}» вставлена (нод: {p1}, связей: {p2}, ресурсов: {p3}, пропущено: {p4})':
      'Chapter "{p0}" inserted (nodes: {p1}, links: {p2}, resources: {p3}, skipped: {p4})',
  // features/editor/screens/visual_script_editor/action_picker_screen.dart
  'Заметки': 'Notes',
  'Сеть': 'Network',
  // features/editor/screens/visual_script_editor/content_item_picker_model.dart
  '{p0} без источника': '{p0} without a source',
  // features/editor/screens/visual_script_editor/script_block_shell.dart
  ' со всем содержимым': ' with all its contents',
  'Удалить блок': 'Delete the block',
  'Удалить блок?': 'Delete the block?',
  'блок': 'block',
  'вырезан': 'cut',
  'вырезано': 'cut',
  'кроссфейд': 'crossfade',
  'продублирован': 'duplicated',
  'продублировано': 'duplicated',
  'скопирован': 'copied',
  'скопировано': 'copied',
  'событие': 'event',
  'условие': 'condition',
  'цикл': 'loop',
  // features/editor/screens/visual_script_editor/table_path_picker.dart
  'да/нет': 'yes/no',
  'словарь ({p0})': 'dictionary ({p0})',
  'список ({p0})': 'list ({p0})',
  'число': 'number',
  // features/editor/screens/visual_script_editor/variable_selection_screen.dart
  'ID предыдущей ноды': 'Previous node ID',
  'ID текущей ноды': 'Current node ID',
  '{p0} из {p1} используются': '{p0} of {p1} are used',
  'Анализ идет в фоне': 'Analysis runs in the background',
  'Время загрузки сейва (HH:MM:SS)': 'Save load time (HH:MM:SS)',
  'Год': 'Year',
  'Дата загрузки сейва (YYYY-MM-DD)': 'Save load date (YYYY-MM-DD)',
  'Дата и время загрузки сейва (ISO)': 'Save load date and time (ISO)',
  'День': 'Day',
  'День недели': 'Day of week',
  'Месяц': 'Month',
  'Минута': 'Minute',
  'Проверка запускается вручную': 'The check starts manually',
  'Час': 'Hour',
  'переменную': 'variable',
  'таблицу': 'table',
  'хранилище скриптов пусто': 'the script storage is empty',
  // features/editor/screens/visual_script_editor/widgets/event_block_widget.dart
  'Вызывается по имени': 'Called by name',
  'Один раз при запуске игры, до первой ноды. Скрипт с таким блоком в папке scripts/ движок находит сам.':
      'Once when the game starts, before the first node. The engine finds a script with this block in the scripts/ folder by itself.',
  'По нажатию': 'On press',
  'При входе в ноду': 'On entering the node',
  'При запуске квеста': 'When the quest starts',
  'При изменении данных': 'When the data changes',
  'При появлении контента': 'When the content appears',
  'Срабатывает при заходе на ноду': 'Fires when you enter a node',
  'Срабатывает при нажатии': 'Fires on a press',
  'Срабатывает при показе элемента': 'Fires when the item is shown',
  'Срабатывает, когда меняется один из указанных путей: переменная, ключ таблицы или ячейка. * — следить за всем.':
      'Fires when one of the listed paths changes: a variable, a table key or a cell. * — watch everything.',
  // features/editor/screens/visual_script_editor/widgets/table_operation_block_widget.dart
  'всё хранилище': 'the whole storage',
  'не указан': 'not set',
  // features/editor/screens/visual_script_editor/widgets/while_block_widget.dart
  ' шаг {p0}': ' step {p0}',
  '{p0} раз': '{p0} times',
  // features/editor/services/trigger_service.dart
  'Нажатие': 'Press',
  // features/editor/widgets/content_add_menu.dart
  'Строка': 'String',
  'Элемент ({p0})': 'Item ({p0})',
  // features/editor/widgets/quest_validation_panel.dart
  'Битая ссылка на ноду': 'Broken link to a node',
  'Битая ссылка на ресурс': 'Broken link to a resource',
  'Битая ссылка на скрипт': 'Broken link to a script',
  'Дубликат id айтема': 'Duplicate item id',
  'Дубликат id ноды': 'Duplicate node id',
  'Дубликат id шаблона': 'Duplicate template id',
  'Конфликт видимости': 'Visibility conflict',
  'Мёртвая переменная': 'Dead variable',
  'Не удалось выполнить проверку: {p0}': 'The check could not run: {p0}',
  'Недостижимая нода': 'Unreachable node',
  'Некорректное выражение': 'Invalid expression',
  'Переменная без инициализации': 'Variable without initialization',
  'Пустой скрипт': 'Empty script',
  // features/editor/widgets/template_picker_sheet.dart
  'Выбор шаблона': 'Choose a template',
  // features/editor/widgets/trigger_slot_buttons.dart
  'Стек перехватывает нажатие: у него самого есть действие, поэтому onPress этого объекта не сработает. Уберите действие у стека — тогда нажатию начнут доставаться дети.':
      'The stack intercepts the press: it has an action of its own, so onPress on this object will not fire. Remove the stack action — presses will then reach the children.',
  // features/editor/workspace/editor_document.dart
  'Изменено': 'Modified',
  // features/editor/workspace/editor_tabs_bar.dart
  'Закрепить вкладку': 'Pin the tab',
  'Открепить вкладку': 'Unpin the tab',
};
