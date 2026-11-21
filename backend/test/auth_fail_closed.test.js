// Регрессия на fail-open в auth: если статус аккаунта не удалось прочитать,
// HTTP-запрос должен получить 503, а не пройти без проверки блокировки.
// Socket.IO должен проверять тот же статус и token_version, а не только подпись.
const test = require('node:test');
const assert = require('node:assert/strict');
const { v4: uuidv4 } = require('uuid');
const jwt = require('jsonwebtoken');

process.env.JWT_SECRET = 'test-secret';
const pool = require('../dist/config/database.js').default;
const authMiddleware = require('../dist/middleware/auth.js').default;
const {
    getAccountState,
    invalidateAccountState,
} = require('../dist/middleware/auth.js');
const { verifySocketToken } = require('../dist/services/socket.js');

const originalQuery = pool.query;

function mockResponse() {
    return {
        statusCode: null,
        body: null,
        status(code) {
            this.statusCode = code;
            return this;
        },
        json(body) {
            this.body = body;
            return this;
        },
    };
}

function tokenFor(id, tv = 0) {
    return jwt.sign({ id, role: 'user', tv }, process.env.JWT_SECRET, { expiresIn: '1h' });
}

function withDbError() {
    pool.query = async () => {
        throw Object.assign(new Error('db down'), { code: 'ECONNREFUSED' });
    };
}

test.after(async () => {
    pool.query = originalQuery;
    await pool.end().catch(() => {});
});

test('getAccountState не превращает недоступность БД в разрешение', async () => {
    const id = uuidv4();
    invalidateAccountState(id);
    withDbError();
    await assert.rejects(() => getAccountState(id), /db down/);
});

test('authMiddleware отдаёт 503, если статус аккаунта не прочитан', async () => {
    const id = uuidv4();
    invalidateAccountState(id);
    withDbError();

    let nextCalled = false;
    const req = { headers: { authorization: `Bearer ${tokenFor(id)}` } };
    const res = mockResponse();
    await authMiddleware(req, res, () => { nextCalled = true; });

    assert.equal(nextCalled, false);
    assert.equal(res.statusCode, 503);
    assert.equal(res.body.code, 'ACCOUNT_STATE_UNAVAILABLE');
});

test('socket handshake не пускает заблокированный аккаунт', async () => {
    const id = uuidv4();
    invalidateAccountState(id);
    pool.query = async () => ({ rows: [{ is_blocked: true, token_version: 0 }] });

    await assert.rejects(() => verifySocketToken(tokenFor(id)), /blocked/);
});

test('socket handshake не пускает отозванный token_version', async () => {
    const id = uuidv4();
    invalidateAccountState(id);
    pool.query = async () => ({ rows: [{ is_blocked: false, token_version: 2 }] });

    await assert.rejects(() => verifySocketToken(tokenFor(id, 1)), /revoked/);
});

test('socket handshake пускает живой токен и возвращает id', async () => {
    const id = uuidv4();
    invalidateAccountState(id);
    pool.query = async () => ({ rows: [{ is_blocked: false, token_version: 1 }] });

    const decoded = await verifySocketToken(tokenFor(id, 1));
    assert.equal(decoded.id, id);
});
