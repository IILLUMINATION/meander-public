// Регрессия на молчаливые отказы публикации: слово в тексте игры или форма
// текста не должны сниматься автоматически — автор получал 400 и «квест не
// публикуется». Спорное тело уходит в ручную проверку (in_review).
//
// Негативный контроль: тесты падают, если `hard` у PORN/SPAM_SHAPE в scope
// «body» снова станет true.
const test = require('node:test');
const assert = require('node:assert/strict');
const { scanText, verdict } = require('../dist/services/content_rules.js');
const { moderateQuestContent } = require('../dist/services/moderation.js');

const find = (hits, code) => hits.find(h => h.code === code);

test('PORN в тексте игры не жёсткий отказ, а ручная проверка', () => {
    const v = verdict(scanText('Герой шутит про порно в баре', 'body'));
    assert.equal(v.isHardReject, false);
    assert.equal(v.needsReview, true);
});

test('PORN в названии и описании остаётся жёстким отказом', () => {
    for (const scope of ['title', 'description']) {
        const hit = find(scanText('порно', scope), 'PORN');
        assert.ok(hit, `${scope}: срабатывание пропало`);
        assert.equal(hit.hard, true);
    }
});

test('Спам-форма в тексте игры не жёсткий отказ', () => {
    // Набор согласных и повтор слова остаются спам-признаком.
    for (const text of ['бвгджзйклмн', 'повторение повторение']) {
        const v = verdict(scanText(text, 'body'));
        assert.equal(v.isHardReject, false, `${text}: тело снято автоматически`);
        assert.equal(v.needsReview, true);
    }
});

test('Повтор одного символа спамом не считается', () => {
    // Разделители и цензура — обычная вёрстка квеста. Правило «один символ
    // повторяется много раз» ложно снимало публикации, поэтому удалено.
    for (const text of ['███████', '───────', '!!!!!!!!!!!', 'аааааааа']) {
        for (const scope of ['title', 'description', 'body']) {
            const hit = find(scanText(text, scope), 'SPAM_SHAPE');
            assert.equal(hit, undefined, `${text} в ${scope}: SPAM_SHAPE всё ещё срабатывает`);
        }
    }
});

test('Спам-форма в витрине остаётся жёстким отказом', () => {
    for (const scope of ['title', 'description']) {
        const hit = find(scanText('бвгджзйклмн', scope), 'SPAM_SHAPE');
        assert.ok(hit, `${scope}: срабатывание пропало`);
        assert.equal(hit.hard, true);
    }
});

test('Запрещёнка не мягчает ни в каком scope', () => {
    const cases = [
        ['CSAM', 'как соблазнить ребенка и секс с ним'],
        ['HATE', 'хайль гитлер'],
        ['SELF_HARM', 'повесись'],
    ];
    for (const [code, text] of cases) {
        for (const scope of ['title', 'description', 'body']) {
            const hit = find(scanText(text, scope), code);
            assert.ok(hit, `${code} в ${scope}: перестало срабатывать`);
            assert.equal(hit.hard, true, `${code} в ${scope}: стало мягким`);
        }
    }
});

test('Публикация квеста со словом «порно» в игре уходит в in_review, а не в 400', async () => {
    const title = 'Ночная смена в баре';
    const description = 'Квест про бариста, который не спал три ночи подряд.';
    const body = 'В баре кто-то оставил журнал «порно» на стойке, и все делают вид, что не замечают.';

    const r = await moderateQuestContent(title, description, body);
    assert.equal(r.isHardReject, false, `жёсткий отказ: ${r.reason}`);
    assert.equal(r.approved, false);
    assert.equal(r.needsReview, true);
});

test('Пустой квест по-прежнему снимается: правило объёма на месте', async () => {
    const r = await moderateQuestContent('Тест', '', '');
    assert.equal(r.isHardReject, true);
    assert.match(r.reason, /мало контента/i);
});
