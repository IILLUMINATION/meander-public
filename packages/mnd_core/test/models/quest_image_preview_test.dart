// Нажатие на изображение без действия — настройка автора в config.json.
//
// Раньше такое изображение всегда открывало полноэкранный просмотр. Для
// геймплея это лишнее: фото может быть декорацией, на которую нельзя
// нажимать. Флаг обязан переживать разбор и сохранение настроек.

import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/quest_descriptor.dart';

void main() {
  group('Quest.allowImagePreview', () {
    test('по умолчанию включено — старые квесты не меняют поведение', () {
      final quest = Quest.fromJson({'id': 'q1', 'title': 'Квест'});

      expect(quest.allowImagePreview, isTrue);
      expect(quest.toJson()['allowImagePreview'], isTrue);
      expect(Quest.fromJson(quest.toJson()).allowImagePreview, isTrue);
    });

    test('выключенный флаг переживает round-trip', () {
      final quest = Quest.fromJson({
        'id': 'q1',
        'title': 'Квест',
        'allowImagePreview': false,
      });

      expect(quest.allowImagePreview, isFalse);
      expect(Quest.fromJson(quest.toJson()).allowImagePreview, isFalse);
    });

    test('copyWith меняет флаг, не теряя остальные поля', () {
      final quest = Quest.fromJson({'id': 'q1', 'title': 'Квест'});

      final disabled = quest.copyWith(allowImagePreview: false);
      expect(disabled.allowImagePreview, isFalse);
      expect(disabled.title, 'Квест');
      expect(disabled.copyWith(title: 'Новое').allowImagePreview, isFalse);
    });
  });
}
