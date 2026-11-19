/// Английский словарь модуля `settings`.
///
/// Ключ — русская строка ровно как в коде (регистр и знаки включно);
/// перевод обязан сохранять плейсхолдеры `{...}`.
final Map<String, String> enSettings = {
  '#RRGGBB или #AARRGGBB': '#RRGGBB or #AARRGGBB',
  'JSON темы': 'Theme JSON',
  'JSON темы или массив тем…': 'Theme JSON or an array of themes…',
  'JSON темы скопирован в буфер': 'Theme JSON copied to clipboard',
  'Push-уведомления': 'Push notifications',
  '{p0} (моя)': '{p0} (mine)',
  'Авто': 'Auto',
  'Авто-открывать вкладку': 'Auto-open tab',
  'Администрирование': 'Administration',
  'Академия': 'Academy',
  'Активация промокода': 'Promo code activation',
  'Библиотека ресурсов с корня': 'Resource library from root',
  'Открывать на корневой папке, а не там, где библиотеку закрыли':
      'Open at the root folder instead of where you last left it',
  'Вариант палитры': 'Palette variant',
  'Вариант палитры M3: fidelity (цвет остаётся моим), vibrant (по умолчанию, усиленный), tonalSpot, expressive, content, neutral, monochrome (графит), rainbow, fruitSalad.':
      'M3 palette variant: fidelity (color stays mine), vibrant (default, boosted), tonalSpot, expressive, content, neutral, monochrome (graphite), rainbow, fruitSalad.',
  'Введите промокод': 'Enter the promo code',
  'Ввести код': 'Enter code',
  'Вернуть seed': 'Reset seed',
  'Версия формата. Всегда 1.': 'Format version. Always 1.',
  'Видеогайды, разборы квестов, ссылки сообщества':
      'Video guides, quest breakdowns, community links',
  'Внимание': 'Warning',
  'Вы уверены, что хотите выйти?': 'Are you sure you want to sign out?',
  'Выйти из аккаунта': 'Sign out',
  'Выйти из аккаунта?': 'Sign out of the account?',
  'Градиент для шапки профиля. Обычно 2 цвета: ["#0088FF", "#00CCAA"]. Если не задан — берётся градиент из палитры темы.':
      'Gradient for the profile header. Usually 2 colors: ["#0088FF", "#00CCAA"]. If not set, the gradient is taken from the theme palette.',
  'Диалог обновления': 'Update dialog',
  'Из буфера': 'From clipboard',
  'Импорт темы': 'Theme import',
  'Импортировано: {p0}': 'Imported: {p0}',
  'Импортировать тему': 'Import theme',
  'Имя автора темы (для соавторских работ).':
      'Theme author name (for co-authored work).',
  'Имя обновлено': 'Name updated',
  'Информация': 'Information',
  'История версий, команда': 'Version history, team',
  'Как создать свою тему — формат JSON':
      'How to make your own theme — JSON format',
  'Контент 18+': '18+ content',
  'Кто может писать, стаж, блокировки': 'Who can write, account age, blocks',
  'Минимальный пример': 'Minimal example',
  'Модерация, отчёты, блокировки': 'Moderation, reports, blocks',
  'Настроить «{p0}»': 'Configure "{p0}"',
  'Настройка темы · {p0}': 'Theme settings · {p0}',
  'Не беспокоить ночью': 'Do not disturb at night',
  'Не удалось изменить: {p0}': 'Failed to change: {p0}',
  'Не удалось отменить: {p0}': 'Failed to cancel: {p0}',
  'Не удалось удалить аккаунт: {p0}': 'Failed to delete the account: {p0}',
  'Несколько тем сразу (массив)': 'Several themes at once (array)',
  'Нечитаемые пары: {p0}': 'Illegible pairs: {p0}',
  'Обучение сброшено': 'Tutorial reset',
  'Ок': 'OK',
  'Описание обновлено': 'Description updated',
  'Опорный цвет': 'Seed color',
  'Отменить удаление': 'Cancel deletion',
  'Отображаемое название темы.': 'Theme display name.',
  'Оттенок': 'Hue',
  'По умолчанию true: если заколоть primary, то primaryContainer пересчитается в тот же оттенок (тон 80 в светлой, 30 в тёмной). false — контейнеры остаются как их построил Material.':
      'True by default: if you pin primary, primaryContainer is recomputed into the same hue (tone 80 in light, 30 in dark). false — containers stay as Material built them.',
  'Подсказки в разделах': 'Hints in sections',
  'Подсказки вернутся при следующем входе в разделы':
      'Hints will come back the next time you enter the sections',
  'Показать объяснения плашек заново': 'Show the badge explanations again',
  'Показать тестовое окно с ченджлогом':
      'Show a test window with the changelog',
  'Полная тема: вариант + ручки HCT + пины ролей':
      'Full theme: variant + HCT handles + role pins',
  'Поля': 'Fields',
  'Понимаю, что это необратимо': 'I understand this is irreversible',
  'Разработка': 'Development',
  'Редактировать био': 'Edit bio',
  'Редактировать имя': 'Edit name',
  'Режим': 'Mode',
  'Ручки опорного цвета. Тон (0..100) — светлота: у чёрного он 0, поэтому «чёрный seed» физически не может быть акцентом, пока тон не поднят. Chroma — насыщенность, hue — оттенок 0..360.':
      'Seed color handles. Tone (0..100) is lightness: black has tone 0, so a "black seed" physically can\'t be an accent until the tone is raised. Chroma is saturation, hue is 0..360.',
  'Ручные цвета конкретных ролей: primary, secondary, tertiary, error, surface, background, *Container, surfaceContainer0..4, outline, inverseSurface, scrim, shadow и все on*. Незаколотые on* подбираются сами под контраст не ниже 4.5:1.':
      'Hand-picked colors for specific roles: primary, secondary, tertiary, error, surface, background, *Container, surfaceContainer0..4, outline, inverseSurface, scrim, shadow and all on*. Unpinned on* colors are chosen automatically for a contrast of at least 4.5:1.',
  'Сбросить обучение?': 'Reset the tutorial?',
  'Сбросить правки': 'Reset edits',
  'Светлая': 'Light',
  'Светлота (тон)': 'Lightness (tone)',
  'Семя-цвет в формате "#RRGGBB" или "#AARRGGBB". Из него Material 3 построит всю палитру.':
      'Seed color in "#RRGGBB" or "#AARRGGBB" format. Material 3 builds the whole palette from it.',
  'Системная': 'System',
  'Скопировано': 'Copied',
  'Тема «{p0}» применена': 'Theme "{p0}" applied',
  'Тема оформления': 'Appearance theme',
  'Тёмная': 'Dark',
  'У этого цвета оттенка нет — это графит. Из него M3 не может взять «краску», поэтому либо вариант «Графит», либо поднимите насыщенность и светлоту ниже.':
      'This color has no hue — it is graphite. M3 can\'t take "paint" from it, so either use the Monochrome variant or raise the saturation and lightness below.',
  'Удаление запланировано': 'Deletion scheduled',
  'Удаление отменено, аккаунт снова обычный.':
      'Deletion cancelled, the account is normal again.',
  'Удалить аккаунт': 'Delete account',
  'Удалить аккаунт?': 'Delete the account?',
  'Уникальный идентификатор темы. Латиница, цифры, _.':
      'Unique theme identifier. Latin letters, digits, _.',
  'Управление расширениями': 'Extension management',
  'Файл .json': '.json file',
  'Формат JSON': 'JSON format',
  'Цвет, фон, пресеты': 'Color, background, presets',
  'Цвета ролей': 'Role colors',
  'Экспорт активной': 'Export the active one',
  'Это цвет-источник: палитра строится из него, а ручки ниже правят его же.':
      'This is the source color: the palette is built from it, and the handles below edit it too.',
  'тон {p0}': 'tone {p0}',
  'Язык интерфейса': 'Interface language',
  'Язык интерфейса: {name}': 'Interface language: {name}',
  'Текущий язык': 'Current language',
};
