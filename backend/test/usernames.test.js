const test = require('node:test');
const assert = require('node:assert');

const {
  USERNAME_MAX,
  USERNAME_MIN,
  normalizeUsername,
  parseUsername,
  usernameFormatError,
} = require('../dist/services/usernames');

test('юзернейм приводится к нижнему регистру и без @', () => {
  assert.equal(normalizeUsername('  @Mnd_Dev '), 'mnd_dev');
  assert.equal(normalizeUsername('@'), null);
  assert.equal(normalizeUsername(''), null);
  assert.equal(normalizeUsername(null), null);
});

test('формат: латиница, цифры, подчёркивание, от 3 до 32', () => {
  assert.equal(usernameFormatError('mnd_dev'), null);
  assert.equal(usernameFormatError('a_1'), null);
  assert.equal(usernameFormatError('a'.repeat(USERNAME_MAX)), null);

  assert.ok(usernameFormatError('ab'));
  assert.ok(usernameFormatError('a'.repeat(USERNAME_MAX + 1)));
  assert.ok(usernameFormatError('русский'));
  assert.ok(usernameFormatError('me-and-er'));
  assert.ok(usernameFormatError('1meander'));
});

test('служебные адреса не отдаются', () => {
  assert.ok(usernameFormatError('api'));
  assert.ok(usernameFormatError('support'));
  assert.ok(usernameFormatError('meander'));
  assert.ok(usernameFormatError('u'));
  // Похожее, но не служебное — можно.
  assert.equal(usernameFormatError('meander_dev'), null);
});

test('parseUsername отвечает либо адресом, либо ошибкой', () => {
  assert.deepEqual(parseUsername('@Mnd_Dev'), { username: 'mnd_dev' });
  assert.deepEqual(parseUsername('  '), { username: undefined });
  assert.equal(typeof parseUsername('ab').error, 'string');
  assert.equal(parseUsername('ab').username, undefined);
});
