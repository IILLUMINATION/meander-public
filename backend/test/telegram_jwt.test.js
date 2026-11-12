// Telegram-вход раньше принимал любой JWT с живым exp: подпись проверялась, но
// при несовпадении писался warning и запрос шёл дальше. Подделав токен с чужим
// telegram_id, можно было получить чужой аккаунт. Регрессия: подпись обязательна.
//
// Негативный контроль: тесты падают, если verifyTelegramIdToken снова начинает
// пропускать неподписанные/чужие токены (например, заглушкой `return payload`).
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { verifyTelegramIdToken } = require('../dist/services/telegram_jwt.js');

const BOT = '123456:TEST-BOT-TOKEN';

// id_token как его выдаёт виджет: HMAC по ключу SHA256(bot_token).
function sign(payload, { key = BOT, alg = 'HS256' } = {}) {
    const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
    const header = b64({ alg, typ: 'JWT' });
    const body = b64(payload);
    const derived = crypto.createHash('sha256').update(key).digest();
    const sig = crypto.createHmac('sha256', derived).update(`${header}.${body}`).digest('base64url');
    return `${header}.${body}.${sig}`;
}

// exp обязателен: токен без exp раньше считался вечным.
const freshPayload = () => ({
    sub: '42',
    auth_date: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 900,
});

test('Подписанный ботом токен проходит', () => {
    const payload = verifyTelegramIdToken(sign(freshPayload()), BOT);
    assert.equal(payload.sub, '42');
});

test('Токен, подписанный сырым bot token, тоже проходит (старая схема)', () => {
    const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
    const header = b64({ alg: 'HS256', typ: 'JWT' });
    const body = b64(freshPayload());
    const sig = crypto.createHmac('sha256', BOT).update(`${header}.${body}`).digest('base64url');
    const payload = verifyTelegramIdToken(`${header}.${body}.${sig}`, BOT);
    assert.equal(payload.sub, '42');
});

test('Неверная подпись — 401 (было: пропускался)', () => {
    const token = sign(freshPayload(), { key: 'other-bot-token' });
    assert.throws(() => verifyTelegramIdToken(token, BOT), (err) => {
        assert.equal(err.status, 401);
        assert.match(err.message, /signature/i);
        return true;
    });
});

test('alg=none без подписи — 401 (было: пропускался)', () => {
    const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
    const forged = `${b64({ alg: 'none', typ: 'JWT' })}.${b64(freshPayload())}.`;
    assert.throws(() => verifyTelegramIdToken(forged, BOT), { status: 401 });
});

test('Подпись под другим алгоритмом (RS256) не принимается', () => {
    assert.throws(() => verifyTelegramIdToken(sign(freshPayload(), { alg: 'RS256' }), BOT), { status: 401 });
});

test('Просроченный exp — 401', () => {
    const expired = sign({ sub: '42', exp: Math.floor(Date.now() / 1000) - 60 });
    assert.throws(() => verifyTelegramIdToken(expired, BOT), { status: 401 });
});

test('Живой exp всё ещё пускают', () => {
    const ok = sign({ sub: '42', exp: Math.floor(Date.now() / 1000) + 3600 });
    assert.equal(verifyTelegramIdToken(ok, BOT).sub, '42');
});

test('Мусор вместо JWT — 401, а не 500', () => {
    for (const junk of ['', 'abc', 'a.b', 'aaa.bbb.ccc']) {
        assert.throws(() => verifyTelegramIdToken(junk, BOT), { status: 401 }, junk);
    }
});

test('Без ключа бота вход закрыт', () => {
    assert.throws(() => verifyTelegramIdToken(sign(freshPayload()), ''), { status: 401 });
});

test('Токен без exp — 401 (было: принимался как вечный)', () => {
    const token = sign({ sub: '42', auth_date: Math.floor(Date.now() / 1000) });
    assert.throws(() => verifyTelegramIdToken(token, BOT), { status: 401 });
});

test('exp не число — 401', () => {
    for (const bad of [String(Math.floor(Date.now() / 1000) + 900), true, null]) {
        assert.throws(() => verifyTelegramIdToken(sign({ sub: '42', exp: bad }), BOT), { status: 401 }, String(bad));
    }
});

test('exp намного в будущем — 401 (украденный токен не «вечный»)', () => {
    const token = sign({ sub: '42', exp: Math.floor(Date.now() / 1000) + 86400 * 365 });
    assert.throws(() => verifyTelegramIdToken(token, BOT), { status: 401 });
});

test('Расхождение часов в пределах skew принимается', () => {
    const token = sign({ sub: '42', exp: Math.floor(Date.now() / 1000) + 120 });
    assert.equal(verifyTelegramIdToken(token, BOT).sub, '42');
});
