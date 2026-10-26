// Негативный контроль: «ищет автора» падает, если вернуть в предикате только
// mq.title; «один параметр на оба условия» — если начать толкать шаблон два
// раза; «плейсхолдер жанра не съезжает» — если сдвинуть нумерацию. Тесты
// «пороги видимости» падают, если выбросить фильтр статуса или adult-настройку.
//
// Почему тест на тексте SQL, а не на живом запросе: локальной базы в проекте
// нет, а прод крутит старый код. Сам предикат проверён read-only выборкой с
// прода: до фикса слово «NN» давало 0 совпадений по названию и 8 по автору.

const test = require('node:test');
const assert = require('node:assert');

const { marketListQuery } = require('../dist/services/market_query');

test('поиск ищет и по названию, и по автору', () => {
    const { text, params } = marketListQuery({ search: 'Иллюминат' });
    assert.ok(text.includes('mq.title ILIKE $1'), text);
    assert.ok(text.includes('mq.author_name ILIKE $1'), text);
    assert.ok(text.includes('OR'), 'условия должны быть через OR, иначе автор ищется вместо названия');
    assert.deepStrictEqual(params, ['%Иллюминат%']);
});

test('один параметр на оба условия: предикат в скобках', () => {
    const { text } = marketListQuery({ search: 'x', category: 'Horror' });
    assert.ok(text.includes(' AND (mq.title ILIKE $1 OR mq.author_name ILIKE $1) AND '), text);
});

test('без поиска предиката нет', () => {
    const { text, params } = marketListQuery({});
    assert.ok(!text.includes('ILIKE'), text);
    assert.deepStrictEqual(params, []);
});

test('видны только опубликованные, adult — только по настройке зрителя', () => {
    const { text } = marketListQuery({ search: 'x' });
    assert.ok(text.includes("mq.status = 'published'"), text);
    assert.ok(text.includes('mq.is_nsfw = FALSE'), text);
    assert.ok(!marketListQuery({ showNsfw: true }).text.includes('is_nsfw'));
});

test('жанр получает следующий свободный номер, когда поиск занял $1', () => {
    const { text, params } = marketListQuery({ search: 'дождь', category: 'Horror' });
    assert.ok(text.includes('$2 = ANY(mq.genres)'), text);
    assert.deepStrictEqual(params, ['%дождь%', 'Horror']);
});

test('категория All не добавляет условия', () => {
    const { text, params } = marketListQuery({ search: 'x', category: 'All' });
    assert.ok(!text.includes('ANY(mq.genres)'), text);
    assert.deepStrictEqual(params, ['%x%']);
});

test('каталог отдаёт суммарные просмотры по квесту', () => {
    const { text } = marketListQuery({});
    assert.ok(
        text.includes('SUM(v.views)') && text.includes('AS views_count'),
        text,
    );
    // Негативный контроль: без привязки к `mq.id` подзапрос посчитал бы
    // просмотры всего каталога и на каждой карточке показал одно число.
    assert.ok(text.includes('v.quest_id = mq.id'), text);
});

// Guideline 1.2. Негативный контроль: без блока `viewerId` тест падает на
// NOT EXISTS, с перепутанными колонками — на `blocked_id = mq.author_id`,
// со забытым параметром — на последнем элементе params.
test('квесты заблокированного автора скрыты от вошедшего зрителя', () => {
    const viewerId = '11111111-1111-1111-1111-111111111111';
    const { text, params } = marketListQuery({ viewerId });
    assert.ok(text.includes('NOT EXISTS'), text);
    assert.ok(text.includes('ub.blocked_id = mq.author_id'), text);
    assert.deepStrictEqual(params, [viewerId]);
    assert.ok(text.includes('ub.user_id = $1'), text);
});

test('блокировка идёт отдельным плейсхолдером после поиска и жанра', () => {
    const { text, params } = marketListQuery({
        search: 'дождь',
        category: 'Horror',
        viewerId: 'v',
    });
    assert.deepStrictEqual(params, ['%дождь%', 'Horror', 'v']);
    assert.ok(text.includes('ub.user_id = $3'), text);
});

test('гость не платит за фильтр блокировок сдвигом плейсхолдеров', () => {
    const { text, params } = marketListQuery({ search: 'x' });
    assert.ok(!text.includes('user_blocks'), text);
    assert.deepStrictEqual(params, ['%x%']);
});
