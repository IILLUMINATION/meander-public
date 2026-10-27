// Жанры квестов: в базу попадают только канонические id, а старые подписи
// (`Fantasy`, `Sci-Fi`) переводятся при публикации. Негативный контроль:
// уберите перевод алиасов в normalizeGenreId — тесты на легаси упадут.
const test = require('node:test');
const assert = require('node:assert/strict');
const {
    QUEST_GENRE_IDS,
    MAX_QUEST_GENRES,
    normalizeGenreId,
    normalizeQuestGenres,
} = require('../dist/data/quest_genres.js');

test('справочник жанров не пустой и без повторов', () => {
    assert.ok(QUEST_GENRE_IDS.length >= 40);
    assert.equal(new Set(QUEST_GENRE_IDS).size, QUEST_GENRE_IDS.length);
    for (const id of QUEST_GENRE_IDS) {
        assert.match(id, /^[a-z][a-z0-9_]*$/, `${id} — не стабильный id`);
    }
});

test('канонические id проходят без изменений', () => {
    for (const id of ['fantasy', 'sci_fi', 'escape_room', 'slice_of_life']) {
        assert.equal(normalizeGenreId(id), id);
    }
});

test('старые английские названия переводятся в id', () => {
    const map = {
        Fantasy: 'fantasy',
        'Sci-Fi': 'sci_fi',
        SciFi: 'sci_fi',
        Horror: 'horror',
        Adventure: 'adventure',
        Mystery: 'mystery',
        Romance: 'romance',
        Comedy: 'comedy',
        Thriller: 'thriller',
        Historical: 'historical',
        Drama: 'drama',
    };
    for (const [legacy, expected] of Object.entries(map)) {
        assert.equal(normalizeGenreId(legacy), expected, legacy);
    }
});

test('регистр, пробелы и дефисы не мешают', () => {
    assert.equal(normalizeGenreId('  DARK FANTASY '), 'dark_fantasy');
    assert.equal(normalizeGenreId('post-apocalypse'), 'post_apocalypse');
    assert.equal(normalizeGenreId('SCI_FI'), 'sci_fi');
});

test('неизвестный жанр отбрасывается, а не ломает публикацию', () => {
    assert.equal(normalizeGenreId('фэнтези'), null);
    assert.equal(normalizeGenreId(''), null);
    assert.equal(normalizeGenreId(null), null);
    assert.equal(normalizeGenreId(42), null);
    assert.deepEqual(normalizeQuestGenres(['fantasy', 'nonsense', 'horror']), [
        'fantasy',
        'horror',
    ]);
});

test('повторы убираются, порядок и лимит сохраняются', () => {
    assert.deepEqual(
        normalizeQuestGenres(['Horror', 'horror', 'Fantasy', 'Drama', 'Comedy']),
        ['horror', 'fantasy', 'drama'],
    );
    assert.equal(normalizeQuestGenres(['Fantasy', 'Drama', 'Comedy']).length, MAX_QUEST_GENRES);
});

test('«All» остаётся служебным значением фильтра, а не жанром', () => {
    // Маршрут GET /quests при пустом результате нормализации оставляет
    // исходную строку; «All» затем пропускает marketListQuery.
    assert.equal(normalizeGenreId('All'), null);
    assert.equal(normalizeGenreId('all'), null);
});

test('строковое поле genres (старый FormData) тоже понимается', () => {
    assert.deepEqual(normalizeQuestGenres('Sci-Fi'), ['sci_fi']);
    assert.deepEqual(normalizeQuestGenres(['Sci-Fi']), ['sci_fi']);
});
