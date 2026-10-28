import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';

void main() {
  group('equippedOf', () {
    test('карта cosmetics важнее плоской колонки name_style', () {
      final equipped = equippedOf({
        'author_name_style': 'frost_blue',
        'author_cosmetics': {'name_style': 'royal_gold', 'avatar_frame': 'prism_ring'},
      });
      expect(equipped.nameStyle, 'royal_gold');
      expect(equipped.avatarFrame, 'prism_ring');
    });

    test('без карты берёт стиль из плоской колонки', () {
      for (final key in const [
        'author_name_style',
        'authorNameStyle',
        'user_name_style',
        'actor_name_style',
      ]) {
        final equipped = equippedOf({key: 'toxic_lime'});
        expect(equipped.nameStyle, 'toxic_lime', reason: key);
        expect(equipped.avatarFrame, isNull, reason: key);
      }
    });

    test('мёртвый id в карте не перебивает живую плоскую колонку', () {
      final equipped = equippedOf({
        'author_name_style': 'royal_gold',
        'author_cosmetics': {'name_style': 'item_from_removed_catalog'},
      });
      expect(equipped.nameStyle, 'royal_gold');
    });

    test('чужие ключи и не-строка дают пустой снап', () {
      expect(equippedOf(null).isEmpty, isTrue);
      expect(equippedOf('royal_gold').isEmpty, isTrue);
      expect(equippedOf({'name_style': 'royal_gold'}).isEmpty, isTrue);
    });
  });

  group('слот фона', () {
    test('фон переживает json и не трогает остальные слоты', () {
      final equipped = EquippedCosmetics.fromJson({
        'banner': 'art_night_meadow',
        'background': 'bg_night_meadow',
        'effect': 'snowfall',
      });
      expect(equipped.background, 'bg_night_meadow');
      expect(equipped.banner, 'art_night_meadow');
      expect(equipped.effect, 'snowfall');

      final json = equipped.toJson();
      expect(json['background'], 'bg_night_meadow');
      expect(json['banner'], 'art_night_meadow');
    });

    test('смена фона не сбрасывает обложку', () {
      const before = EquippedCosmetics(
        banner: 'art_golden_field',
        effect: 'hearts',
      );
      final after = before.withSlot(CosmeticSlot.background, 'bg_golden_field');
      expect(after.background, 'bg_golden_field');
      expect(after.banner, 'art_golden_field');
      expect(after.effect, 'hearts');
      expect(
        after.withSlot(CosmeticSlot.background, null).background,
        isNull,
      );
    });

    test('предмет не своего слота и мёртвый id в фон не попадают', () {
      expect(
        EquippedCosmetics.fromJson({'background': 'art_night_meadow'}).background,
        isNull,
        reason: 'обложка не должна читаться как фон',
      );
      expect(
        EquippedCosmetics.fromJson({'background': 'no_such_bg'}).background,
        isNull,
      );
    });

    test('один фон уже не пустая экипировка', () {
      expect(
        const EquippedCosmetics(background: 'bg_open_road').isEmpty,
        isFalse,
      );
    });
  });
}
