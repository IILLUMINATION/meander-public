// Журнал обращений: пачки, нормализация полей, фильтр статики.
//
// Цель журнала — разбор атак, поэтому важно, что в колонки попадают только
// валидные значения (IP из доверенного заголовка, UUID пользователя, короткий
// device id), а запись не превращается в один INSERT на каждый запрос.

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  createVisitAudit,
  buildInsert,
  rowParams,
  normalizeDeviceId,
  normalizeUserId,
  LIMITS,
} = require('../dist/services/visit_audit.js');
const { visitEntryFor, shouldAudit } = require('../dist/middleware/visit_audit.js');

const entry = (overrides = {}) => ({
  ip: '203.0.113.7',
  userId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
  deviceId: 'dev-1',
  platform: 'android',
  appVersion: '2.8.19',
  method: 'GET',
  path: '/quests?limit=3',
  status: 200,
  userAgent: 'Meander/2.8.19',
  durationMs: 12.4,
  ...overrides,
});

test('insert собирается на всю пачку, параметры идут подряд', () => {
  const sql = buildInsert(2);
  assert.match(sql, /VALUES \(\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10\), \(\$11/);
  assert.equal(rowParams(entry()).length, 10);
});

test('пишет пачкой, а не по одному запросу на обращение', async () => {
  const calls = [];
  const audit = createVisitAudit(
    async (sql, params) => {
      calls.push({ sql, params });
    },
    { batchLimit: 3, flushMs: 60_000 },
  );

  audit.record(entry());
  audit.record(entry());
  assert.equal(calls.length, 0, 'до пачки база не трогается');
  audit.record(entry());
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(calls.length, 1);
  assert.equal(calls[0].params.length, 30, 'три строки по десять параметров');
  audit.dispose();
});

test('flush отправляет остаток и очищает очередь', async () => {
  const calls = [];
  const audit = createVisitAudit(
    async (sql, params) => {
      calls.push(params.length);
    },
    { flushMs: 60_000 },
  );

  audit.record(entry());
  assert.equal(audit.pending(), 1);
  await audit.flush();

  assert.equal(audit.pending(), 0);
  assert.deepEqual(calls, [10]);
  audit.dispose();
});

test('ошибка базы не ломает вызывающий код', async () => {
  const audit = createVisitAudit(
    async () => {
      throw new Error('db down');
    },
    { flushMs: 60_000 },
  );
  audit.record(entry());
  await assert.doesNotReject(() => audit.flush());
  assert.equal(audit.pending(), 0, 'строка не застревает в очереди навсегда');
  audit.dispose();
});

test('длинные поля обрезаются, мусор в user_id отбрасывается', () => {
  const params = rowParams(
    entry({
      userId: 'not-a-uuid',
      deviceId: 'x'.repeat(200),
      userAgent: 'u'.repeat(2000),
      path: '/' + 'a'.repeat(2000),
      method: 'M'.repeat(100),
    }),
  );
  const [ip, userId, deviceId, , , method, path, , userAgent] = params;
  assert.equal(ip, '203.0.113.7');
  assert.equal(userId, null);
  assert.equal(deviceId, null, 'слишком длинный id тоже мусор');
  assert.equal(method.length, LIMITS.method);
  assert.equal(path.length, LIMITS.path);
  assert.equal(userAgent.length, LIMITS.userAgent);
});

test('device id чистится от пробелов и управляющих символов', () => {
  assert.equal(normalizeDeviceId('  abc-123  '), 'abc-123');
  assert.equal(normalizeDeviceId('abc 123'), null);
  assert.equal(normalizeDeviceId('abc\n123'), null);
  assert.equal(normalizeDeviceId(''), null);
  assert.equal(normalizeDeviceId(42), null);
});

test('user id принимается только UUID и приводится к нижнему регистру', () => {
  assert.equal(
    normalizeUserId('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'),
    'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
  );
  assert.equal(normalizeUserId('anon'), null);
});

test('статика и загрузки не пишутся, API пишется', () => {
  assert.equal(shouldAudit('/uploads/avatar.png'), false);
  assert.equal(shouldAudit('/static/quests/q.mnd'), false);
  assert.equal(shouldAudit('/.well-known/apple-app-site-association'), false);
  assert.equal(shouldAudit('/quests'), true);
  assert.equal(shouldAudit('/profiles/abc'), true);
});

test('запись берёт IP из доверенного заголовка и пользователя из запроса', () => {
  const req = {
    method: 'POST',
    path: '/reports',
    originalUrl: '/reports?x=1',
    url: '/reports?x=1',
    headers: {
      'x-real-ip': '198.51.100.9',
      'x-device-id': 'dev-42',
      'x-client-platform': 'ios',
      'x-client-version': '2.8.19',
      'user-agent': 'Meander/2.8.19 (iPhone)',
    },
    socket: { remoteAddress: '127.0.0.1' },
    ip: '127.0.0.1',
    user: { id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' },
  };

  const result = visitEntryFor(req, 201, 33.3);

  assert.equal(result.ip, '198.51.100.9');
  assert.equal(result.userId, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
  assert.equal(result.deviceId, 'dev-42');
  assert.equal(result.platform, 'ios');
  assert.equal(result.path, '/reports?x=1');
  assert.equal(result.status, 201);
});

test('анонимный запрос пишется без пользователя и устройства', () => {
  const req = {
    method: 'GET',
    path: '/quests',
    originalUrl: '/quests',
    url: '/quests',
    headers: { 'x-real-ip': '198.51.100.9' },
    socket: { remoteAddress: '127.0.0.1' },
    ip: '127.0.0.1',
  };

  const result = visitEntryFor(req, 200, 1);

  assert.equal(result.userId, null);
  assert.equal(result.deviceId, null);
});

test('запрос за картинкой в журнал не попадает', () => {
  const req = {
    method: 'GET',
    path: '/uploads/a.png',
    originalUrl: '/uploads/a.png',
    url: '/uploads/a.png',
    headers: {},
    socket: { remoteAddress: '127.0.0.1' },
  };

  assert.equal(visitEntryFor(req, 200, 1), null);
});
test('чистка удаляет пачками, пока база отдаёт по 5000 строк', async () => {
  const { purgeOldVisits } = require('../dist/services/visit_audit.js');
  const calls = [];
  const sizes = [5000, 5000, 1200];
  const executor = async (sql, params) => {
    calls.push(params[0]);
    return { rowCount: sizes[calls.length - 1] };
  };

  const removed = await purgeOldVisits(180, executor);

  assert.equal(removed, 11200);
  assert.equal(calls.length, 3, 'останавливается на неполной пачке');
  assert.deepEqual(calls, ['180', '180', '180']);
});
