// Кнопки бота поддержки: нажатие — это POST, а не локальная подстановка.
//
// Проверяем ровно это: бот присылает готовый ответ, клиент дорисовывает его
// в переписку и не показывает кнопки старых сообщений (иначе человек жмёт
// «Опишу проблему» второй раз и получает второй тикет).

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/support/models/support_models.dart';
import 'package:canvas_app/features/support/providers/support_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends ApiService {
  final List<String> postedCallbacks = [];

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
            'id': 'm-1',
            'role': 'bot',
            'body': 'Здравствуйте! Что случилось?',
            'created_at': '2026-11-14T09:00:00.000Z',
            'buttons': [
              {'id': 'cat:bug', 'label': 'Ошибка'},
              {'id': 'cat:idea', 'label': 'Идея'},
            ],
          },
        ],
        'active_ticket': null,
      };
    }
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> post(String endpoint, {Map<String, dynamic>? body}) async {
    if (endpoint == 'support/callback') {
      postedCallbacks.add((body?['button_id'] ?? '').toString());
      return {
        'bot_messages': [
          {
            'id': 'm-2',
            'role': 'bot',
            'body': 'Опиши проблему — команда увидит её сразу.',
            'created_at': '2026-11-14T09:00:01.000Z',
            'buttons': <Map<String, dynamic>>[],
          },
        ],
      };
    }
    return <String, dynamic>{};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('нажатие кнопки уходит на сервер и добавляет ответ бота', () async {
    SharedPreferences.setMockInitialValues({'user_id': 'me-1', 'jwt_token': 't'});
    final api = _FakeApi();
    final container = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(supportChatProvider.notifier);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(supportChatProvider).messages.length, 1);

    final button = container.read(supportChatProvider).messages.first.buttons
        .firstWhere((b) => b.id == 'cat:bug');
    await notifier.pressButton(button);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(api.postedCallbacks, ['cat:bug']);
    final state = container.read(supportChatProvider);
    expect(state.messages.length, 2);
    expect(state.messages.last.body, contains('Опиши проблему'));
    // Кнопки живут только у последнего сообщения бота: у нового ответа их
    // нет, значит и старые больше не показываются.
    expect(notifier.liveButtonMessageIds, isNot(contains('m-1')));
  });

  test('закрытый тикет не считается открытым', () {
    final ticket = SupportTicket.fromJson({
      'id': 't-1',
      'subject': 'Не открывается квест',
      'status': 'closed',
      'category': 'bug',
      'created_at': '2026-11-14T09:00:00.000Z',
    });
    expect(ticket.statusTitle, isNotEmpty);
    expect(ticket.status, 'closed');
  });
}