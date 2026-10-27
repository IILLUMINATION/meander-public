import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Граница гостевого доступа к странице квеста: смотреть и скачивать можно
/// без аккаунта, а лайки, оценки и отзывы — нет.
///
/// Экран не собирается в виджет-тесте (ad-SDK, riverpod-обвязка), поэтому
/// проверяем тела методов по тексту файла — как в `first_launch_choice_test`.
/// Негативный контроль встроен в смысл проверки: верните `return` перед
/// `startDownload` по пустому токену — первый тест упадёт.
void main() {
  final details = File(
    'lib/features/market/screens/quest_market_details_screen.dart',
  );
  final download = File(
    'lib/features/market/providers/market_download_provider.dart',
  );
  late String source;
  late String provider;

  setUpAll(() {
    expect(details.existsSync(), isTrue, reason: 'запускать из apps/main_app');
    expect(download.existsSync(), isTrue);
    source = details.readAsStringSync();
    provider = download.readAsStringSync();
  });

  String bodyFrom(String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    final end = source.indexOf(endMarker, start);
    expect(start, greaterThan(-1), reason: 'не найден $startMarker');
    expect(end, greaterThan(start), reason: 'не найден $endMarker');
    return source.substring(start, end);
  }

  test('скачивание не требует входа: пустой токен не останавливает загрузку', () {
    final body = bodyFrom(
      'Future<void> _downloadAndImport()',
      'void _showAuthRequiredDialog()',
    );
    expect(
      body,
      isNot(contains('_showAuthRequiredDialog')),
      reason: 'гость должен скачивать без окна про аккаунт',
    );
    expect(
      body,
      contains("prefs.getString('jwt_token') ?? ''"),
      reason: 'без токена загрузка всё равно идёт, просто без статистики',
    );
    expect(body, contains('token: token'));
  });

  test('лайк и отзыв по-прежнему требуют аккаунт', () {
    final vote = bodyFrom(
      'Future<void> _handleVote(',
      'setState(() => _isVoteProcessing = true)',
    );
    expect(vote, contains('_showAuthRequiredDialog()'));

    final review = bodyFrom(
      'void _showReviewDialog()',
      'final userReviewData',
    );
    expect(review, contains('_showAuthRequiredDialog()'));
  });

  test('гостевая загрузка не дёргает счётчик загрузок', () {
    final start = provider.indexOf('Future<void> startDownload(');
    expect(start, greaterThan(-1));
    final body = provider.substring(start);
    expect(
      body,
      contains('if (token.trim().isNotEmpty)'),
      reason: 'без сессии POST /download вернёт 401 и засорит лог',
    );
    expect(body, contains("post('quests/\${quest.id}/download')"));
  });
}
