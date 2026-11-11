import 'package:canvas_app/features/wall/widgets/post_card.dart';
import 'package:canvas_app/models/wall_post_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// На десктопе системный share для текста — это `mailto:`-ссылка, то есть
/// кнопка «Поделиться» в ленте либо звала почтовый клиент, либо молча падала.
/// Ожидание то же, что у квеста и профиля: ссылка в буфер, и публичный хост,
/// а не локальный адрес из debug-сборки.
void main() {
  const platform = SystemChannels.platform;

  WallPost post() => WallPost(
    id: '11111111-1111-1111-1111-111111111111',
    authorId: '22222222-2222-2222-2222-222222222222',
    authorName: 'Лена',
    content: 'Прошёл замок без ключа.',
    likesCount: 0,
    commentsCount: 0,
    viewsCount: 0,
    isLikedByViewer: false,
    createdAt: DateTime(2026, 10, 3, 12),
  );

  /// Возвращает текст, который оказался в буфере обмена, или null.
  Future<String?> tapShare(WidgetTester tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(platform, (
      call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        platform,
        null,
      ),
    );

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    // Меню до конца анимации игнорирует тапы. Время нарочно не переводить за
    // 2.5 с — иначе сработает таймер просмотра и потянет настоящий запрос.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Поделиться'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return copied;
  }

  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(children: [PostCard(post: post())]),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('«Поделиться» на десктопе кладёт ссылку в буфер', (tester) async {
    await pumpCard(tester);

    final copied = await tapShare(tester);

    expect(
      copied,
      'https://meander.illuminat.dev/share/post/'
      '11111111-1111-1111-1111-111111111111',
    );
    expect(find.text('Ссылка скопирована в буфер обмена'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Снять дерево: у карточки остался бы неотменённый таймер просмотра.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ссылка на пост не строится на локальном адресе сборки', (
    tester,
  ) async {
    await pumpCard(tester);
    final copied = await tapShare(tester);
    await tester.pumpWidget(const SizedBox());

    // `AppConfig.apiUrl` в debug-сборке — это сервер в локальной сети, и
    // такая ссылка не открылась бы у того, кому её прислали.
    expect(copied, isNotNull);
    expect(copied, isNot(contains('192.168')));
    expect(copied, startsWith('https://'));
  });

  /// Стена профиля живёт на узком телефоне: длинное имя автора и большие
  /// счётчики не должны вытягивать строку за край.
  testWidgets('узкий телефон: шапка поста влезает целиком', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                PostCard(
                  post: WallPost(
                    id: '11111111-1111-1111-1111-111111111111',
                    authorId: '22222222-2222-2222-2222-222222222222',
                    authorName:
                        'Максимилиан Александрович Вольф-Штенбоген-младший',
                    content: 'Очень длинный текст поста, который идёт в две строки и дальше.',
                    likesCount: 128733,
                    commentsCount: 94421,
                    viewsCount: 999999,
                    isLikedByViewer: false,
                    createdAt: DateTime(2026, 10, 3, 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Снять дерево: у карточки остался бы неотменённый таймер просмотра.
    await tester.pumpWidget(const SizedBox());
  });
}
