/// Английский словарь модуля `b6_shell`: ошибки входа.
///
/// Ключ — русская строка ровно как в коде (регистр и знаки включно);
/// перевод обязан сохранять плейсхолдеры `{...}`.
final Map<String, String> enB6Shell = {
  'Apple не вернул identity token': 'Apple did not return an identity token',
  'Браузер заблокировал всплывающее окно. Разрешите всплывающие окна.': 'The browser blocked the pop-up window. Allow pop-ups.',
  'Google Sign-In code 10: проверь package + SHA-1/SHA-256 в OAuth Android client.': 'Google Sign-In code 10: check the package + SHA-1/SHA-256 in the OAuth Android client.',
  'Google Play Services недоступны — входим через браузер.': 'Google Play Services are unavailable — signing in through the browser.',
  'Google Sign-In не ответил (MIUI может блокировать окно входа)': 'Google Sign-In did not respond (MIUI may be blocking the sign-in window)',
  'Google не выдал idToken.': 'Google did not issue an idToken.',
  'Неверный токен Apple': 'Invalid Apple token',
  'Неверный токен Telegram': 'Invalid Telegram token',
  'Неверный токен Яндекса': 'Invalid Yandex token',
  'Нет связи с Telegram. Проверьте интернет.': 'Cannot reach Telegram. Check your internet connection.',
  'Нет связи с сервером. Проверьте интернет и попробуйте снова.': 'Cannot reach the server. Check your internet connection and try again.',
  'Ошибка Telegram-входа: {p0}': 'Telegram sign-in error: {p0}',
  'Ошибка Яндекс-входа: {p0}': 'Yandex sign-in error: {p0}',
  'Ошибка входа: {p0}': 'Sign-in error: {p0}',
  'Ошибка обмена токена.': 'Token exchange failed.',
  'Ошибка сервера Telegram ({p0})': 'Telegram server error ({p0})',
  'Ошибка сервера: {p0}': 'Server error: {p0}',
  'Сервер временно недоступен. Попробуйте позже.': 'The server is temporarily unavailable. Try again later.',
  'Сервис Google входа недоступен на этом устройстве. Обновите Google Play Services и попробуйте ещё раз.': 'Google Sign-In service is unavailable on this device. Update Google Play Services and try again.',
  'Сервис Google входа недоступен, а браузерный вход не настроен в этой сборке.': 'Google Sign-In service is unavailable and browser sign-in is not configured in this build.',
  'Telegram-вход не настроен': 'Telegram sign-in is not configured',
  'Вход в браузере не завершён — окно было закрыто.': 'Browser sign-in was not completed — the window was closed.',
  'Вход выполнен!': 'Signed in!',
  'Вход не завершён': 'Sign-in not completed',
  'Вход отменён': 'Sign-in cancelled',
  'Яндекс-вход не поддержан на этом устройстве. Попробуйте Google.': 'Yandex sign-in is not supported on this device. Try Google.',
};
