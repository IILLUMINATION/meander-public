import 'package:canvas_app/core/utils/quest_genres.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeGenreId', () {
    test('канонический id проходит без изменений', () {
      for (final id in kQuestGenreIds) {
        expect(normalizeGenreId(id), id, reason: id);
      }
    });

    test('старые английские названия сводятся к каноническим id', () {
      expect(normalizeGenreId('Fantasy'), 'fantasy');
      expect(normalizeGenreId('Sci-Fi'), 'sci_fi');
      expect(normalizeGenreId('science fiction'), 'sci_fi');
      expect(normalizeGenreId('Historical'), 'historical');
      expect(normalizeGenreId('History'), 'historical');
    });

    test('регистр, пробелы и дефисы не создают новых жанров', () {
      expect(normalizeGenreId('  Dark Fantasy '), 'dark_fantasy');
      expect(normalizeGenreId('Slice-of-Life'), 'slice_of_life');
      expect(normalizeGenreId('TIME_TRAVEL'), 'time_travel');
    });

    test('неизвестный жанр отбрасывается, а не превращается в мусорный id', () {
      expect(normalizeGenreId('Романтика'), '');
      expect(normalizeGenreId('not-a-genre'), '');
      expect(normalizeGenreId(null), '');
      expect(normalizeGenreId('   '), '');
    });
  });

  group('normalizeGenreIds', () {
    test('убирает повторы и неизвестные, сохраняет порядок', () {
      final result = normalizeGenreIds([
        'Fantasy',
        'noir',
        'fantasy',
        'Романтика',
        'detective',
      ]);
      expect(result, ['fantasy', 'noir', 'detective']);
    });

    test('обрезает список до максимума', () {
      final result = normalizeGenreIds(
        ['fantasy', 'noir', 'detective', 'horror'],
      );
      expect(result, hasLength(3));
      expect(result, ['fantasy', 'noir', 'detective']);
    });

    test('теневой лимит меньше трёх соблюдается', () {
      final result = normalizeGenreIds(['fantasy', 'noir'], max: 1);
      expect(result, ['fantasy']);
    });
  });

  test('каталог жанров не содержит повторов', () {
    expect(kQuestGenreIds.toSet(), hasLength(kQuestGenreIds.length));
  });
}
