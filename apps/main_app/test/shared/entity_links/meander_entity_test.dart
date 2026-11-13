import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/shared/entity_links/meander_entity.dart';
import 'package:flutter_test/flutter_test.dart';

/// Проверки разборки текста на ссылки: виджет рисует `entity_ref_card.dart`,
/// а здесь решает только одно — где в тексте кончается слово и начинается
/// чья-то страница.
void main() {
  const questId = '3a84a172-c52d-4414-a0af-b2f9393f32ae';
  const userId = '11111111-2222-4333-8444-555555555555';
  const postId = 'aaaaaaaa-bbbb-4ccc-9ddd-eeeeeeeeeeee';

  MeanderEntity? firstEntity(String source) {
    final segments = splitMeanderEntities(source);
    return segments.firstWhere(
      (segment) => segment.isEntity,
      orElse: () => const MeanderSegment.text(''),
    ).entity;
  }

  List<String> texts(String source) => splitMeanderEntities(source)
      .where((segment) => !segment.isEntity)
      .map((segment) => segment.text)
      .toList();

  group('ссылки приложения', () {
    test('share-ссылка квеста с прод-хоста', () {
      expect(
        firstEntity('прошёл https://meander.illuminat.dev/share/quest/$questId'),
        const MeanderEntity(kind: MeanderEntityKind.quest, id: questId),
      );
    });

    test('ссылка профиля без протокола', () {
      expect(
        firstEntity('вот человек: meander.illuminat.dev/share/profile/$userId'),
        const MeanderEntity(kind: MeanderEntityKind.profile, id: userId),
      );
    });

    test('meander:// — своя схема', () {
      expect(
        firstEntity('meander://post/$postId'),
        const MeanderEntity(kind: MeanderEntityKind.post, id: postId),
      );
    });

    test('схема со страницы шаринга несёт ещё и share-сегмент', () {
      expect(
        firstEntity('открой meander://share/quest/$questId'),
        const MeanderEntity(kind: MeanderEntityKind.quest, id: questId),
      );
    });

    test('ссылка текущего бэкенда разработки', () {
      final host = AppConfig.apiUrl.replaceFirst(RegExp(r'^https?://'), '');
      expect(
        firstEntity('$host/share/quest/$questId'),
        const MeanderEntity(kind: MeanderEntityKind.quest, id: questId),
      );
    });

    test('ссылки с зеркал остаются карточками', () {
      for (final mirror in AppConfig.defaultMirrorUrls) {
        final host = mirror.replaceFirst(RegExp(r'^https?://'), '');
        expect(
          firstEntity('квест $mirror/share/quest/$questId'),
          const MeanderEntity(kind: MeanderEntityKind.quest, id: questId),
          reason: 'ссылка с зеркала $host — та же карточка квеста',
        );
      }
    });

    test('регистр id и хоста не важен, id нормализуется', () {
      final upper = questId.toUpperCase();
      expect(
        firstEntity('https://BACKEND.MEANDER.SBS/share/quest/$upper'),
        const MeanderEntity(kind: MeanderEntityKind.quest, id: questId),
      );
    });
  });

  group('markdown-ссылка', () {
    test('подпись остаётся текстом, адрес становится карточкой', () {
      final segments = splitMeanderEntities(
        'советую [вот этот квест](https://meander.illuminat.dev/share/quest/$questId) всем',
      );
      expect(
        segments.map((segment) => segment.isEntity ? '#card' : segment.text),
        ['советую ', 'вот этот квест ', '#card', ' всем'],
      );
    });

    test('из одного вложения — одна карточка', () {
      final segments = splitMeanderEntities(
        '[квест](https://meander.illuminat.dev/share/quest/$questId)',
      );
      expect(
        segments.where((segment) => segment.isEntity).length,
        1,
        reason: 'markdown-ссылка содержит обычный адрес внутри',
      );
    });

    test('несколько ссылок в одном сообщении', () {
      final segments = splitMeanderEntities(
        'квест https://meander.illuminat.dev/share/quest/$questId и '
        'профиль https://meander.illuminat.dev/share/profile/$userId',
      );
      expect(segments.where((segment) => segment.isEntity).map((s) => s.entity), [
        const MeanderEntity(kind: MeanderEntityKind.quest, id: questId),
        const MeanderEntity(kind: MeanderEntityKind.profile, id: userId),
      ]);
    });
  });

  group('голый uuid', () {
    test('узнаётся без адреса, тип отдаётся резолверу', () {
      expect(
        firstEntity('ищи его по id $questId'),
        const MeanderEntity(kind: MeanderEntityKind.unknown, id: questId),
      );
    });

    test('путь ресурса квеста карточкой не становится', () {
      expect(
        firstEntity('картинка assets/$questId.png лежит в архиве'),
        null,
      );
      expect(
        firstEntity('res/sounds/$questId'),
        null,
      );
      expect(
        firstEntity('id:prefix_$questId'),
        null,
        reason: 'uuid внутри слова — не отдельный id',
      );
    });
  });

  test('чужие адреса не трогаем', () {
    expect(
      firstEntity('почитай https://example.com/share/quest/$questId'),
      null,
      reason: 'чужой домен не про наши страницы',
    );
    expect(firstEntity('обычный текст без ссылок'), null);
    expect(firstEntity(''), null);
    expect(hasMeanderEntity('обычный текст без ссылок'), isFalse);
    expect(hasMeanderEntity('https://meander.illuminat.dev/share/quest/$questId'), isTrue);
  });

  test('текст вокруг карточки сохраняется целиком', () {
    const source = 'до https://meander.illuminat.dev/share/quest/$questId после';
    expect(texts(source).join(), isNot(contains(questId)));
    expect(texts(source).join(), 'до  после');
  });
}
