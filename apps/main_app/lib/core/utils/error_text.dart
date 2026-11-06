/// Текст ошибки для человека.
///
/// `Object.toString()` у `Exception` печатает префикс `Exception: ` (см.
/// `dart:core/exceptions.dart`), поэтому `'Ошибка: $e'` показывало авторам
/// «Ошибка: Exception: Лимит 5/час». А `HttpException` — многострочный дамп,
/// который в снэкбаре не читается вовсе.
///
/// Правила те же, что у `_friendlyError` в стеновых провайдерах: известные
/// код-префиксы `api_service` превращаются в понятную фразу, от трейса
/// остаётся первая строка, длина ограничена.
library;

import 'package:canvas_app/core/services/mirror_registry.dart';

import 'package:canvas_app/core/l10n/l10n.dart';

/// Префикс класса: `Exception: `, `FormatException: `, `HttpException: `.
final _classPrefix = RegExp(r'^(?:[\w$]*(?:Exception|Error)): ');

/// Код отказа в начале строки, OPTION-регулярка: `403 Только автор`.
final _httpCode = RegExp(r'^(40[134])(?:\s+(.*))?$');

String friendlyError(Object error) {
  final raw = error.toString();
  if (raw.contains(MirrorRegistry.allMirrorsDownMarker)) {
    // Все зеркала недоступны. Формулировка без запрещённых в РФ терминов:
    // предлагаем «ускоритель интернета», объясняем причину (РКН) и снимаем
    // blame с разработчика — блокировка на стороне провайдера, не баг.
    return tr(
      'Сервер недоступен: возможно, ваш интернет-провайдер ограничивает доступ. Включите «ускоритель интернета» (сервис для улучшения соединения) или задайте своё зеркало в настройках. Разработчик не виноват',
    );
  }
  if (raw.contains('SERVER_MAINTENANCE')) return tr('Сервер на обслуживании');
  if (raw.contains('SocketException') || raw.contains('ClientException')) {
    return tr('Нет соединения с сервером');
  }
  // Дамп с трейсом: человеку нужна первая строка.
  var message = raw.split('\n').first.trim();
  // `Exception(HttpException: …)` даёт двойной префикс — снимаем, пока есть.
  while (message.contains(_classPrefix)) {
    message = message.replaceFirst(_classPrefix, '');
  }
  // Код в начале строки — тем `api_service` различает отказ по правилу,
  // просроченную сессию и прочую служебнину.
  final code = _httpCode.firstMatch(message);
  if (code != null) return _httpCodeText(code.group(1)!, code.group(2) ?? '');
  final result = _collapseKnownPhrases(message);
  return result.length > 140 ? '${result.substring(0, 140)}...' : result;
}

String _httpCodeText(String code, String rest) {
  final message = rest.trim();
  if (code == '403') {
    // Текст бэкенда уже человеческий («Только автор может…»), оставляем его.
    return message.isEmpty ? tr('Доступ запрещён') : message;
  }
  if (code == '404') return message.isEmpty ? tr('Не найдено') : message;
  return tr('Сессия истекла — войдите заново');
}

/// Служебные формулировки `dart:io` и `http`, которые автору ничего не говорят.
String _collapseKnownPhrases(String message) {
  // `Failed to delete: 404 …` из `api_service`: глагол человеку не важен,
  // важны код и текст бэкенда за ним.
  final failure = RegExp(r'^Failed to\D*(\d{3})\s*(.*)$').firstMatch(message);
  if (failure != null) {
    final detail = failure.group(2)!.trim();
    if (detail.isNotEmpty) {
      return trf(
        'Сервер ответил: {p0} {p1}',
        {'p0': failure.group(1), 'p1': detail},
      );
    }
    return failure.group(1) == '404'
        ? tr('Сервер не поддерживает это действие (404)')
        : trf('Сервер ответил ошибкой {p0}', {'p0': failure.group(1)});
  }
  if (message.startsWith('Failed to ')) {
    final tail = message.substring('Failed to '.length).trim();
    return tail.isEmpty
        ? tr('Сервер ответил ошибкой')
        : trf('Сервер ответил: {p0}', {'p0': tail});
  }
  if (message.startsWith('Unauthorized:')) {
    return tr('Сессия истекла — войдите заново');
  }
  return message;
}

/// Обрыв соединения — не ошибка человека и не поломка квеста.
///
/// Отличается от прочих ошибок тем, что приложение при нём работоспособно:
/// библиотека, создание квестов и уже скачанные истории живут офлайн.
/// Поэтому экраны ошибки на этот случай дают не только «Попробовать снова»,
/// но и явный выход в локальную часть.
///
/// Проверка по строке, а не по типу: `api_service` мапит `SocketException` и
/// `ClientException` в `Exception('SERVER_MAINTENANCE')`, а таймаут запроса и
/// DNS-ошибки `dart:io` проходят как есть — то есть в `error` лежит и то, и
/// другое в зависимости от того, где именно оборвалось.
bool isConnectionFailure(Object error) {
  final raw = error.toString();
  return _connectionMarkers.any(raw.contains);
}

const _connectionMarkers = [
  'SERVER_MAINTENANCE',
  'SocketException',
  'ClientException',
  'TimeoutException',
  'Failed host lookup',
  'Failed to connect',
  'Connection refused',
  'Connection timed out',
  'Network is unreachable',
  'No route to host',
  'ENETUNREACH',
  'EHOSTUNREACH',
  'ENOTFOUND',
];

/// Ошибка обращения к собственному хранилищу приложения.
///
/// От сети не отличается ничем в глазах человека: те же «ничего не произошло»
/// и та же мысль, что Meander сломан. Поэтому экраны на такой отказ дают не
/// `errno` и путь, а свою фразу — что проверять (место, разрешения).
///
/// Признак по строке, а не по типу: в этих путях `FileSystemException`
/// приходит из `dart:io`, `MissingPluginException` — из `path_provider` на
/// незнакомой платформе, а `PlatformException` — с Android-канала.
bool looksLikeStorageFailure(Object error) =>
    _storageFailureMarkers.any(error.toString().contains);

const _storageFailureMarkers = [
  'FileSystemException',
  'OSError',
  'MissingPluginException',
  'PlatformException',
  'Permission denied',
  'No space left',
  'Read-only file system',
  'Not a directory',
];
