const test = require('node:test');
const assert = require('node:assert');

const {
  canCommentInChannel,
  canManageChannel,
  canReadChannel,
} = require('../dist/services/channel_rules');

test('писать в канал может только владелец и админ канала', () => {
  assert.equal(canManageChannel('owner'), true);
  assert.equal(canManageChannel('admin'), true);
  // Подписчик и прохожий — нет: иначе канал перестаёт быть каналом.
  assert.equal(canManageChannel('subscriber'), false);
  assert.equal(canManageChannel(null), false);
  assert.equal(canManageChannel(undefined), false);
});

test('закрытый канал виден только участникам', () => {
  assert.equal(canReadChannel(true, null), true);
  assert.equal(canReadChannel(true, undefined), true);
  assert.equal(canReadChannel(false, null), false);
  assert.equal(canReadChannel(false, 'subscriber'), true);
  // Даже владелец закрытого канала читает его только через членство,
  // а оно у него есть по определению.
  assert.equal(canReadChannel(false, 'owner'), true);
});

test('комментировать может участник, но не прохожий', () => {
  assert.equal(canCommentInChannel('subscriber'), true);
  assert.equal(canCommentInChannel('admin'), true);
  assert.equal(canCommentInChannel(null), false);
  assert.equal(canCommentInChannel(undefined), false);
});