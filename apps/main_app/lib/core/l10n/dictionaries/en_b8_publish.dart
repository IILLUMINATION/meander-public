/// Публикация, выкачка пакетов, сетевые ответы и синхронизация.
///
/// Ключ — русская строка ровно как в коде (регистр и знаки включно).
final Map<String, String> enB8Publish = {
  // core/importers/qst_importer.dart
  'Неизвестная ошибка парсинга': 'Unknown parsing error',
  // core/services/async_import_service.dart
  'Неизвестная ошибка импорта URQ': 'Unknown URQ import error',
  // core/services/post_media_service.dart
  'Сервер не принял фото (код {p0})':
      'The server did not accept the photo (code {p0})',
  // core/services/publish_upload.dart
  'Пакет квеста больше разрешённого размера.':
      'The quest package is larger than the allowed size.',
  'Пакет квеста весит {p0} МБ, а лимит {p1} — {p2} МБ. Загрузку не начинаем: сервер отклонил бы её в конце. {p3}':
      'The quest package weighs {p0} MB while the {p1} limit is {p2} MB. We are not starting the upload: the server would reject it at the very end. {p3}',
  'Публикация отклонена по правилам магазина: {p0}.\nРабота осталась у тебя в черновиках — правки можно внести и опубликовать снова.':
      'The publication was rejected by the store rules: {p0}.\nThe work stayed in your drafts — you can fix it and publish again.',
  'С лимитом верифицированного автора (500 МБ) такой пакет опубликуется — запроси верификацию в профиле.':
      'With the verified-author limit (500 MB) this package would publish — request verification in your profile.',
  'Сервер не смог обработать публикацию. Это не твоя ошибка: попробуй позже, если повторяется — напиши в поддержку.':
      'The server could not process the publication. This is not your fault: try again later, and if it keeps happening write to support.',
  'Сервер не смог разобрать пакет. Обычно это обрыв при сборке .mnd: пересобери квест (сохрани и выйди из редактора) и опубликуй заново.':
      'The server could not read the package. Usually that means the .mnd build was cut off: rebuild the quest (save and leave the editor) and publish again.',
  'Сервер принял {p0} МБ при лимите {p1} МБ. Больше всего места занимают картинки, звук и видео — начни с них.':
      'The server took {p0} MB against a {p1} MB limit. Images, audio and video take up the most space — start there.',
  'Сессия истекла. Перезайди в аккаунт и опубликуй заново.':
      'Session expired. Sign back into your account and publish again.',
  'Такой файл уже лежит в магазине у другого автора. Измени содержание и опубликуй заново.':
      'Another author already has this file in the store. Change the content and publish again.',
  'У этого квеста уже есть публикация другого автора: он создан как копия из маркета и сохранил её идентификатор. Публиковать нужно под новым идентификатором — тогда твоя работа встанет отдельно и не заденет чужую.':
      'This quest already has another author\'s publication: it was made as a copy from the market and kept that identifier. Publish under a new identifier — then your work stands on its own and does not touch anyone else\'s.',
  'Убери лишнее из ресурсов квеста — картинки, звук и видео занимают больше всего места.':
      'Trim the quest resources — images, audio and video take up the most space.',
  'Файл квеста не дошёл до сервера — похоже, связь оборвалась во время загрузки. Публикацию не записали, попробуй ещё раз.':
      'The quest file never reached the server — the connection looks like it dropped during upload. The publication was not saved, try again.',
  'верифицированного автора': 'for a verified author',
  'обычного автора': 'for a regular author',
  'см. описание правил': 'see the rules description',
  // core/services/quest_cleaner_service.dart
  'Удаленная нода': 'Deleted node',
  // features/analytics/screens/author_analytics_screen.dart
  'без изменений': 'no change',
  // features/analytics/widgets/analytics_charts.dart
  '{p0} за день': '{p0} per day',
  // features/library/services/my_library_service.dart
  'Сервер не даёт файл: перечитайте страницу и войдите заново':
      'The server will not hand over the file: reload the page and sign in again',
  'Сервер не отдал ссылку на файл':
      'The server did not return a link to the file',
  'Сервер не отдал файл (код {p0})':
      'The server did not return the file (code {p0})',
  'Файл не скачался': 'The file did not download',
  'Файла больше нет на сервере': 'The file is no longer on the server',
  // features/messages/providers/dm_provider.dart
  'Сервер не ответил вовремя': 'The server did not answer in time',
  'Уже сохраняю': 'Already saving',
  // features/quests/providers/cloud_sync_provider.dart
  'Изменений нет': 'No changes',
  // features/quests/providers/quest_sync_provider.dart
  'Изменений нет, синхронизация не требуется': 'No changes, nothing to sync',
  'Не синхронизировано': 'Not synced',
  'Синхронизация завершена': 'Sync complete',
  // features/quests/screens/quest_publish_screen.dart
  'В скриптах найден подозрительный или вредоносный код.':
      'Suspicious or malicious code was found in the scripts.',
  'Ваш квест теперь доступен в магазине.':
      'Your quest is now available in the store.',
  'Внутри игры найдена запрещённая картинка.':
      'A forbidden image was found inside the game.',
  'Вы публикуете слишком часто. Подождите пару часов.':
      'You are publishing too often. Wait a couple of hours.',
  'Загрузка встала: {p0} секунд по соединению не прошло ни одного байта. Публикацию не записали, квест остался у тебя — попробуй опубликовать заново.':
      'The upload stalled: not a single byte moved over the connection for {p0} seconds. The publication was not saved and the quest stayed with you — try publishing again.',
  'Загрузка пакета: {p0}%': 'Uploading package: {p0}%',
  'Обложка не прошла проверку (возможно, NSFW или насилие).':
      'The cover did not pass the check (possibly NSFW or violence).',
  'Один из скриншотов содержит недопустимый контент.':
      'One of the screenshots contains disallowed content.',
  'Отправка файлов на сервер...': 'Sending files to the server...',
  'Отправлено на проверку': 'Sent for review',
  'Ошибка авторизации. Перезайдите в аккаунт.':
      'Authorization error. Sign into your account again.',
  'Ошибка публикации: {p0}': 'Publication error: {p0}',
  'Пакет больше лимита': 'Package over the limit',
  'Пакет ушёл на сервер, но ответ не пришёл за {p0} с. Публикация могла и не записаться: проверь «Мои квесты» и, если её там нет, опубликуй заново.':
      'The package went to the server but no answer arrived within {p0} s. The publication may not have been saved: check "My quests" and, if it is not there, publish again.',
  'Подготовка...': 'Preparing...',
  'Размер квеста превышает лимит сервера. Сейчас лимит для обычных аккаунтов: 100 МБ, для верифицированных: 500 МБ.':
      'The quest size exceeds the server limit. Right now the limit is 100 MB for regular accounts and 500 MB for verified ones.',
  'Сборка пакета квеста...': 'Building the quest package...',
  'Сервер отклонил загрузку: файл слишком большой (HTTP 413). Проверь лимиты на backend/nginx.':
      'The server rejected the upload: the file is too large (HTTP 413). Check the limits on backend/nginx.',
  'Сервер проверяет и сохраняет пакет...':
      'The server is checking and storing the package...',
  'Соединение сброшено сервером во время загрузки. Обычно это лимит размера на прокси (nginx) или таймаут upload.':
      'The server dropped the connection during upload. Usually this is a size limit on the proxy (nginx) or an upload timeout.',
  'Текст или описание квеста нарушают правила сообщества.':
      'The quest text or description breaks the community rules.',
  'Успешно опубликовано': 'Published successfully',
  'Этот квест уже был опубликован (дубликат).':
      'This quest has already been published (duplicate).',
  // features/shell/widgets/admin_cosmetics_panel.dart
  'Сервер не ответил: {p0}': 'The server did not answer: {p0}',
  'бессрочно': 'forever',
  'до {p0}': 'until {p0}',
  // features/wall/providers/wall_paginated_provider.dart
  'Ошибка сервера': 'Server error',
  'Страница не найдена': 'Page not found',
};
