// Ответы команды в поддержке должны добираться до ленты чатов: у обращения
// нет серверной отметки прочтения для автора, поэтому счётчик считает клиент
// по локальной отметке времени.

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/support/providers/support_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends ApiService {
  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'support/chat') {
      return {
        'language': 'ru',
        'messages': [
          {
            'id': 'm-bot',
            'role': 'bot',
            'body': 'Привет!',
            'created_at': '2026-11-14T09:00:00.000Z',
          },
          {
            'id': 'm-staff',
            'role': 'staff',
            'body': 'Проверили, всё готово.',
            'created_at': '2026-11-14T10:00:00.000Z',
          },
        ],
        'active_ticket': null,
      };
    }
    return <String, dynamic>{};
  }
}

Future<ProviderContainer> _container() async {
  final container = ProviderContainer(
    overrides: [apiServiceProvider.overrideWithValue(_FakeApi())],
  );
  addTearDown(container.dispose);
  container.read(supportChatProvider);
  for (var i = 0; i < 40; i++) {
    if (!container.read(supportChatProvider).isLoading) break;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ответ команды до отметки прочтения считается непрочитанным', () async {
    SharedPreferences.setMockInitialValues({
      'user_id': 'u-1',
      'support_read_at_u-1': '2026-11-14T09:30:00.000Z',
    });

    final container = await _container();
    expect(container.read(supportChatProvider).unread, 1);
  });

  test('отметка прочтения сохраняется и переживает новый провайдер', () async {
    SharedPreferences.setMockInitialValues({
      'user_id': 'u-1',
      'support_read_at_u-1': '2026-11-14T09:30:00.000Z',
    });

    final first = await _container();
    expect(first.read(supportChatProvider).unread, 1);
    await first.read(supportChatProvider.notifier).markRead();
    expect(first.read(supportChatProvider).unread, 0);
    final saved = (await SharedPreferences.getInstance())
        .getString('support_read_at_u-1');
    expect(saved, isNotNull);

    first.dispose();
    final second = await _container();
    expect(second.read(supportChatProvider).unread, 0);
  });
}
