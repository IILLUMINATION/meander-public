/// Английский словарь модуля `b2_settings`.
///
/// Ключ — русская строка ровно как в коде (регистр и знаки включно);
/// перевод обязан сохранять плейсхолдеры `{...}`.
final Map<String, String> enB2Settings = {
  'А': 'A',
  'Аккаунт будет удалён {p0}. Если передумаете — вернитесь в приложение, войдите и отмените удаление здесь же.':
      'Your account will be deleted {p0}. If you change your mind — return to the app, sign in and cancel the deletion right here.',
  'Аккаунт будет удалён в ближайшие дни. Если передумаете — войдите и отмените удаление в этих же настройках.':
      'Your account will be deleted in the coming days. If you change your mind — sign in and cancel the deletion in these same settings.',
  'Аккаунт помечен на удаление': 'Account marked for deletion',
  'Аккаунт, профиль, сохранения, переписки, публикации и статистика будут удалены безвозвратно.\n\nКвесты других авторов, которые вы купили или скачали, останутся на устройстве.':
      'Account, profile, saves, chats, publications and statistics will be deleted permanently.\n\nQuests by other authors that you bought or downloaded will remain on the device.',
  'Будет удалён {p0} — до этой даты всё можно вернуть.':
      'Will be deleted {p0} — everything can be restored up to this date.',
  'Всё, что не трогать, считает Material. Нажатие — точный цвет, «Авто» — вернуть расчёт.':
      'Anything you don\'t touch is computed by Material. Tap for an exact color, "Auto" to restore the calculation.',
  'Вторичный текст — по нему лучше всего видно, что вы выбрали для onSurfaceVariant.':
      'Secondary text — it shows best what you chose for onSurfaceVariant.',
  'Если заколоть primary вручную, светлые контейнеры пересчитаются в его же оттенок — тема остаётся цельной. Выключите, чтобы контейнеры остались как их построил Material.':
      'If you pin primary manually, light containers are recomputed in the same hue — the theme stays cohesive. Turn off to keep containers as Material built them.',
  'Итог: {p0}  ·  H{p1} C{p2} T{p3}': 'Result: {p0}  ·  H{p1} C{p2} T{p3}',
  'Как из одного цвета расходятся все тона. «Точная» оставляет ваш цвет как есть, «Графит» игнорирует оттенок вовсе.':
      'How all tones diverge from a single color. "Exact" keeps your color as is, "Graphite" ignores the hue entirely.',
  'Карточка слоя': 'Layer card',
  'Контейнер акцента': 'Accent container',
  'Контейнеры — из моего акцента': 'Containers — from my accent',
  'Контент 18+ включен': '18+ content enabled',
  'Контент 18+ может содержать нецензурную лексику, жестокость и материалы для взрослых.\n\nПодтвердите, что вам исполнилось 18 лет.':
      '18+ content may contain profanity, violence and adult material.\n\nConfirm that you are at least 18 years old.',
  'Контент 18+ скрыт': '18+ content hidden',
  'Контраст {p0}:1 · {p1}': 'Contrast {p0}:1 · {p1}',
  'Мейандр': 'Meander',
  'Новый документ сразу в новой вкладке':
      'New documents open right away in a new tab',
  'Обучение по созданию квеста будет показано снова при следующем нажатии на «Создать квест».':
      'The quest creation tutorial will be shown again the next time you tap "Create quest".',
  'Панель вкладок для открытых документов': 'Tab bar for open documents',
  'Слои поверхности 0 → 4': 'Surface layers 0 → 4',
  'Совет: не обязательно писать JSON руками — «Настроить» у любой темы даёт те же поля визуально (вариант, ручки HCT, пины ролей), а кнопка «JSON темы» вверху показывает, что получилось. Меню → «Экспорт активной» — то же в буфер.':
      'Tip: you don\'t have to write JSON by hand — "Customize" on any theme gives the same fields visually (variant, HCT sliders, role pins), and the "Theme JSON" button at the top shows what you got. Menu → "Export active" — the same to the clipboard.',
  'Сохранить как свою': 'Save as your own',
  'Тема — это JSON-объект (или массив объектов). Минимум — id, name и seed: из него Material 3 построит всю палитру. Дальше можно выбрать вариант палитры, поправить seed по HCT (оттенок/насыщенность/светлота) и заколоть любые отдельные роли в light/dark — что не заколото, дорассчитает алгоритм.':
      'A theme is a JSON object (or an array of objects). The minimum is id, name and seed: Material 3 builds the whole palette from it. Then you can choose a palette variant, adjust the seed by HCT (hue/chroma/lightness) and pin any individual roles in light/dark — anything not pinned the algorithm will compute.',
  'Тон этого же цвета': 'Tone of the same color',
  'Тост / инверсная поверхность': 'Toast / inverse surface',
  'Формат JSON темы': 'Theme JSON format',
  'выбран': 'selected',
  'необязательно': 'optional',
  'обычный': 'regular',
  'обязательно': 'required',
  'светлая': 'light',
  'тёмная': 'dark',
  'Первый запуск': 'First launch',
  'Экран, который видит новый пользователь': 'The screen a new user sees',
  'Подключение': 'Connection',
  'Зеркала и серверы': 'Mirrors and servers',
  'Meander — open-source': 'Meander is open-source',
  'Исходный код открыт: github.com/IILLUMINATION/meander-public — бэкенд, конструктор квестов, плеер':
      'The source code is open: github.com/IILLUMINATION/meander-public — backend, quest builder, player',
  'Meander — open-source: можно указать свои серверы с квестами или зеркала. Можно добавить несколько и переключаться':
      'Meander is open-source: you can point it at your own quest servers or mirrors. Add several and switch between them.',
  'Тест пинга': 'Ping test',
  'Автовыбор': 'Auto-select',
  'Активное зеркало': 'Active mirror',
  'Ваш сервер': 'Your server',
  'Встроенное зеркало': 'Built-in mirror',
  'Нет ответа': 'No response',
  'Поле пустое — зеркало не добавлено': 'The field is empty — no mirror added',
  'Сервер не отвечает': 'Server not responding',
  'Зеркало добавлено': 'Mirror added',
  'Подключение установлено': 'Connection established',
  'Все зеркала недоступны': 'All mirrors are unreachable',
  'Некорректный адрес сервера': 'Invalid server address',
  'Сервер недоступен: возможно, ваш интернет-провайдер ограничивает доступ. Включите «ускоритель интернета» (сервис для улучшения соединения) или задайте своё зеркало в настройках. Разработчик не виноват':
      'Cannot reach the server: your internet provider may be restricting access. Turn on an internet accelerator (a service that improves connectivity) or set a custom mirror in Settings. The developer is not at fault.',
};
