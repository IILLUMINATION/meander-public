import 'package:canvas_app/features/forums/models/forum_models.dart';
import 'package:canvas_app/features/forums/widgets/forum_topic_tile.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ForumTopic _topic({int likes = 3, bool liked = false}) => ForumTopic(
  id: 'p1',
  title: 'Как пройти замок',
  body: 'Нужна подсказка про третий код.',
  author: const ForumPerson(id: 'u1', name: 'Лена'),
  likesCount: likes,
  commentsCount: 2,
  isLikedByViewer: liked,
  createdAt: DateTime.now().subtract(const Duration(hours: 5)),
);

Future<void> _pump(WidgetTester tester, Widget tile) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ListView(children: [tile]))),
  );
}

void main() {
  testWidgets('строка умеет лайкать сама себя', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      ForumTopicTile(
        topic: _topic(),
        onOpen: () {},
        onLike: () async {
          calls++;
          return null;
        },
      ),
    );

    expect(find.text('3'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    await tester.pump();
    expect(calls, 1);
    // Иконка на время увеличивается — анимацию надо докрутить до конца.
    await tester.pumpAndSettle();
  });

  testWidgets('лайк с ошибкой возвращает её наружу, а не роняет ленту', (
    tester,
  ) async {
    await _pump(
      tester,
      ForumTopicTile(
        topic: _topic(likes: 1, liked: true),
        onOpen: () {},
        onLike: () async => 'Нет соединения с сервером',
      ),
    );
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.favorite_rounded));
    await tester.pump();
    await tester.pump();
    expect(find.text('Нет соединения с сервером'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('в чужой ленте видно сообщество и тап ведёт в него', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      ForumTopicTile(
        topic: _topic(),
        onOpen: () {},
        communityName: 'Ночные квесты',
        onOpenCommunity: () => opened++,
      ),
    );

    expect(find.text('Ночные квесты'), findsOneWidget);
    await tester.tap(find.text('Ночные квесты'));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('markdown в превью не показывается исходником', (tester) async {
    await _pump(
      tester,
      ForumTopicTile(
        topic: ForumTopic(
          id: 'p2',
          title: 'Проверка',
          body: '![Фото](https://meander.illuminat.dev/uploads/1.jpg)',
          author: const ForumPerson(id: 'u1', name: 'Лена'),
          likesCount: 0,
          commentsCount: 0,
          isLikedByViewer: false,
        ),
        onOpen: () {},
      ),
    );

    // Служебный синтаксис человек видеть не должен, а картинка обязана
    // доехать до строки миниатюрой, даже если её нет в media_urls.
    expect(find.textContaining("!["), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });

  testWidgets('топик без заголовка называется текстом тела', (tester) async {
    await _pump(
      tester,
      ForumTopicTile(
        topic: ForumTopic(
          id: 'p3',
          title: '',
          body: '# Итог\nтам **первая** глава',
          author: const ForumPerson(id: 'u1', name: 'Лена'),
          likesCount: 0,
          commentsCount: 0,
          isLikedByViewer: false,
        ),
        onOpen: () {},
      ),
    );

    expect(find.text('Итог там первая глава'), findsOneWidget);
  });

  testWidgets('без обработчика лайка пилюля не остаётся мёртвой кнопкой', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      ForumTopicTile(topic: _topic(), onOpen: () => opened++),
    );
    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    await tester.pump();
    expect(opened, 1);
  });
}
