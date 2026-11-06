import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/utils/quest_paths.dart';

// Регрессия path traversal через `id` в config.json: импорт подставлял
// `id:"../"` в `quests/<id>/...` без проверки, `Directory.delete(recursive)`
// стирал всё вне `quests/` (на desktop — реальные Документы).
void main() {
  group('QuestPaths.isSafeQuestId', () {
    test('допускает UUID и безопасные имена', () {
      expect(
        QuestPaths.isSafeQuestId('496e8377-b092-43d2-b2a9-f594c1b3a607'),
        isTrue,
      );
      expect(QuestPaths.isSafeQuestId('my_quest-1'), isTrue);
      expect(QuestPaths.isSafeQuestId('A'), isTrue);
      expect(QuestPaths.isSafeQuestId('x' * 128), isTrue);
    });

    test('отвергает path traversal и разделители путей', () {
      expect(QuestPaths.isSafeQuestId('../'), isFalse);
      expect(QuestPaths.isSafeQuestId('..'), isFalse);
      expect(QuestPaths.isSafeQuestId('../../etc/passwd'), isFalse);
      expect(QuestPaths.isSafeQuestId('a/b'), isFalse);
      expect(QuestPaths.isSafeQuestId('a\\b'), isFalse);
      expect(QuestPaths.isSafeQuestId('a.b'), isFalse);
      expect(QuestPaths.isSafeQuestId('/etc'), isFalse);
      expect(QuestPaths.isSafeQuestId('C:'), isFalse);
      expect(QuestPaths.isSafeQuestId('.'), isFalse);
    });

    test('отвергает пустое, пробелы, юникод и переполнение длины', () {
      expect(QuestPaths.isSafeQuestId(''), isFalse);
      expect(QuestPaths.isSafeQuestId('a b'), isFalse);
      expect(QuestPaths.isSafeQuestId('кириллица'), isFalse);
      expect(QuestPaths.isSafeQuestId('x' * 129), isFalse);
    });
  });
}