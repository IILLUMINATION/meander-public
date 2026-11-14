// Вложения чата на клиенте: что рисуется и что уходит на сервер.
//
// Здесь проверяется не вёрстка, а то, что видно по данным: фото без подписи
// превращается в «Фото» в ленте, лишние кадры отбрасываются, а размеры из
// ответа сервера попадают в модель (по ним резервируется место в пузыре).

import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _attachment({
  String url = 'https://meander.illuminat.dev/uploads/a.jpg',
  Object? width = 1600,
  Object? height = 1067,
  Object? size = 5977,
}) => {'url': url, 'width': width, 'height': height, 'size': size};

void main() {
  group('DmAttachment', () {
    test('размеры и пропорции берутся из ответа сервера', () {
      final list = DmAttachment.listFrom([_attachment()]);
      expect(list, hasLength(1));
      expect(list.first.width, 1600);
      expect(list.first.height, 1067);
      expect(list.first.aspectRatio, closeTo(1.4995, 0.001));
    });

    test('битые размеры не роняют кадр и не дают NaN', () {
      final list = DmAttachment.listFrom([
        _attachment(width: 'широко', height: null, size: '5'),
      ]);
      expect(list.single.width, 0);
      expect(list.single.height, 0);
      expect(list.single.size, 5);
      expect(list.single.aspectRatio, isNull);
    });

    test('мусор вместо массива и пустые адреса отбрасываются', () {
      expect(DmAttachment.listFrom(null), isEmpty);
      expect(DmAttachment.listFrom('url'), isEmpty);
      expect(
        DmAttachment.listFrom([null, 42, {'url': ''}, _attachment()]),
        hasLength(1),
      );
    });
  });

  group('лента чатов', () {
    DmThread threadWith(Map<String, dynamic> extra) => DmThread.fromJson({
      'thread_id': 't1',
      'peer_id': 'p1',
      'peer_name': 'Аня',
      'peer_role': 'user',
      ...extra,
    });

    test('реплика из одних фото подписана «Фото», а не «Нет сообщений»', () {
      final one = threadWith({'last_attachments': [_attachment()]});
      expect(one.preview, 'Фото');

      final three = threadWith({
        'last_attachments': [_attachment(), _attachment(), _attachment()],
      });
      expect(three.preview, '3 фото');
    });

    test('текст важнее счётчика фото, если он есть', () {
      final thread = threadWith({
        'last_body': 'смотри',
        'last_attachments': [_attachment()],
      });
      expect(thread.preview, 'смотри');
    });
  });

  group('сообщение', () {
    test('вложения приходят вместе с репликой', () {
      final message = DmMessage.fromJson({
        'id': 'm1',
        'thread_id': 't1',
        'sender_id': 'p1',
        'body': '',
        'created_at': '2026-11-14T10:00:00.000Z',
        'attachments': [_attachment(), _attachment()],
      });
      expect(message.attachments, hasLength(2));
      expect(message.body, isEmpty);
    });

    test('старое сообщение без колонки attachments читается как одно фото-ноль', () {
      final message = DmMessage.fromJson({
        'id': 'm2',
        'thread_id': 't1',
        'sender_id': 'p1',
        'body': 'привет',
        'created_at': '2026-11-14T10:00:00.000Z',
      });
      expect(message.attachments, isEmpty);
      expect(message.body, 'привет');
    });
  });

  group('сток markdown-превью', () {
    test('звёздочки и решётки не попадают в строку уведомления', () {
      expect(
        AppMarkdownInline.plain('**Важно:** #обновление прошло'),
        'Важно: обновление прошло',
      );
    });

    test('ссылка разметки оставляет текст, а голый адрес — адрес', () {
      expect(
        AppMarkdownInline.plain('Смотри [пост](https://meander.illuminat.dev/x)'),
        'Смотри пост',
      );
      expect(
        AppMarkdownInline.plain('Подробнее: https://meander.illuminat.dev/x'),
        'Подробнее: https://meander.illuminat.dev/x',
      );
    });

    test('переносы строк схлопываются в пробел', () {
      expect(AppMarkdownInline.plain('раз\n\nдва'), 'раз два');
    });
  });
}