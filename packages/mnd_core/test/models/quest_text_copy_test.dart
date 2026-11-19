// Разрешение на копирование текста — настройка автора в config.json.
//
// Игроку по умолчанию нельзя выделять текст нод: старые квесты не должны
// менять поведение после обновления. Флаг обязан переживать разбор и
// сохранение настроек, иначе редактор включит его, а плеер не увидит.

import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/quest_descriptor.dart';

void main() {
  group('Quest.allowTextCopy', () {
    test('по умолчанию выключено и явно пишется в json', () {
      final quest = Quest.fromJson({'id': 'q1', 'title': 'Квест'});

      expect(quest.allowTextCopy, isFalse);
      expect(quest.toJson()['allowTextCopy'], isFalse);
      expect(Quest.fromJson(quest.toJson()).allowTextCopy, isFalse);
    });

    test('включённый флаг переживает round-trip', () {
      final quest = Quest.fromJson({
        'id': 'q1',
        'title': 'Квест',
        'allowTextCopy': true,
      });

      expect(quest.allowTextCopy, isTrue);
      expect(Quest.fromJson(quest.toJson()).allowTextCopy, isTrue);
    });

    test('copyWith меняет флаг, не теряя остальные поля', () {
      final quest = Quest.fromJson({'id': 'q1', 'title': 'Квест'});

      final enabled = quest.copyWith(allowTextCopy: true);
      expect(enabled.allowTextCopy, isTrue);
      expect(enabled.title, 'Квест');
      expect(enabled.copyWith(title: 'Новое').allowTextCopy, isTrue);
    });
  });
}
