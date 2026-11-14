// Список языков квеста (#331, доработка).
//
// Квест может поддерживать несколько языков, поэтому авторы шлют `languages`
// списком. Негативные контроли ниже падают, если:
//  - начать пропускать невалидные метки (в колонку попадёт что угодно);
//  - потерять порядок автора (первый тег — основной, по нему старый клиент и
//    `quests.language` считают квест «своим»);
//  - перестать схлопывать дубликаты (клиент шлёт и `language`, и `languages`).

const test = require('node:test');
const assert = require('node:assert');

const {
    normalizeQuestLanguage,
    normalizeQuestLanguages,
    MAX_QUEST_LANGUAGES,
} = require('../dist/services/quest_language');

test('принимает список из FormData JSON-строкой', () => {
    assert.deepStrictEqual(normalizeQuestLanguages('["ru","en"]'), ['ru', 'en']);
    assert.deepStrictEqual(
        normalizeQuestLanguages('["ru","zh-CN","pt-BR"]'),
        ['ru', 'zh-CN', 'pt-BR'],
    );
});

test('принимает настоящий массив из JSON-тела запроса', () => {
    assert.deepStrictEqual(normalizeQuestLanguages(['en', 'ru']), ['en', 'ru']);
});

test('принимает строку через запятую (ручные запросы)', () => {
    assert.deepStrictEqual(normalizeQuestLanguages('ru,en, ja'), ['ru', 'en', 'ja']);
});

test('порядок автора сохраняется — первый тег основной', () => {
    assert.strictEqual(normalizeQuestLanguages('["ja","ru"]')[0], 'ja');
});

test('дубликаты схлопываются', () => {
    assert.deepStrictEqual(
        normalizeQuestLanguages('["ru","ru","RU","en"]'),
        ['ru', 'en'],
    );
});

test('невалидные метки выбрасываются молча', () => {
    assert.deepStrictEqual(
        normalizeQuestLanguages('["ru","<script>","",null,"en"]'),
        ['ru', 'en'],
    );
    assert.deepStrictEqual(normalizeQuestLanguages('ру,ru'), ['ru']);
});

test('пустое значение — пустой список, а не исключение', () => {
    for (const value of [undefined, null, '', '   ', '[]', 'null', 42, {}]) {
        assert.deepStrictEqual(normalizeQuestLanguages(value), [], String(value));
    }
});

test('битый JSON не роняет разбор и не превращается в тег', () => {
    assert.deepStrictEqual(normalizeQuestLanguages('["ru",'), []);
});

test('количество языков ограничено', () => {
    const many = JSON.stringify(
        Array.from({ length: 20 }, (_, i) => `l${String.fromCharCode(97 + i)}`),
    );
    assert.strictEqual(normalizeQuestLanguages(many).length, MAX_QUEST_LANGUAGES);
});

test('одиночный язык остаётся валидным значением колонки', () => {
    assert.strictEqual(normalizeQuestLanguage('ru'), 'ru');
    assert.strictEqual(normalizeQuestLanguages('["ru"]').length, 1);
});