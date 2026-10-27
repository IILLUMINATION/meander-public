// Уровни каталога: 1 — лучшие, 2 — прошедшие модерацию, 3 — демо.
//
// Тесты на чистых функциях: SQL-выражение повторной публикации проверяется
// по тексту (локальной базы нет), а ветки — по порядку WHEN. Негативный
// контроль: если убрать `ELSE quests.market_tier`, обычная перепубликация
// начнёт снимать ручной первый уровень, и тест на сохранение упадёт.

const test = require('node:test');
const assert = require('node:assert');

const {
    MARKET_TIER_BEST,
    MARKET_TIER_DEMO,
    MARKET_TIER_MODERATED,
    MARKET_TIER_ON_REPUBLISH_SQL,
    parseMarketTier,
    tierForNewQuest,
} = require('../dist/services/market_tiers');

test('новая публикация: демо — третий уровень, остальное — второй', () => {
    assert.strictEqual(tierForNewQuest(true), MARKET_TIER_DEMO);
    assert.strictEqual(tierForNewQuest(false), MARKET_TIER_MODERATED);
    assert.notStrictEqual(tierForNewQuest(false), MARKET_TIER_BEST);
});

test('уровень принимается только целым от 1 до 3', () => {
    for (const good of [1, 2, 3, '1', '2', '3', ' 2 ']) {
        assert.strictEqual(parseMarketTier(good), Number(good), String(good));
    }
    for (const bad of [0, 4, -1, 1.5, '', ' ', 'best', null, undefined, {}, []]) {
        assert.strictEqual(parseMarketTier(bad), null, JSON.stringify(bad));
    }
});

test('перепубликация не снимает ручной первый уровень', () => {
    // Порядок веток важен: демо падает вниз раньше, чем проверяется сохранение.
    assert.strictEqual(
        MARKET_TIER_ON_REPUBLISH_SQL,
        'CASE WHEN EXCLUDED.is_demo THEN 3 WHEN quests.market_tier = 3 THEN 2 ELSE quests.market_tier END',
    );
    assert.ok(MARKET_TIER_ON_REPUBLISH_SQL.indexOf('EXCLUDED.is_demo') <
        MARKET_TIER_ON_REPUBLISH_SQL.indexOf('quests.market_tier'), 'демо должно проверяться первым');
    assert.ok(MARKET_TIER_ON_REPUBLISH_SQL.includes('ELSE quests.market_tier'), 'иначе кураторский уровень 1 теряется');
});
