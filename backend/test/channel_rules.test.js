const test = require('node:test');
const assert = require('node:assert');

const {
  canBroadcastNews,
  canCommentInChannel,
  canManageChannel,
  canPublishInChannel,
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

test('в официальном канале публикует только владелец', () => {
  const owner = '11111111-1111-4111-8111-111111111111';
  const admin = '22222222-2222-4222-8222-222222222222';

  assert.equal(canPublishInChannel(true, owner, owner, 'owner'), true);
  // Админ канала в обычном канале пишет, но официальный — только владелец.
  assert.equal(canPublishInChannel(true, owner, admin, 'admin'), false);
  assert.equal(canPublishInChannel(true, owner, admin, 'owner'), false);
  assert.equal(canPublishInChannel(false, owner, admin, 'admin'), true);
  assert.equal(canPublishInChannel(false, owner, admin, 'subscriber'), false);
});

test('рассылку новостей запускает только владелец официального канала', () => {
  const owner = '11111111-1111-4111-8111-111111111111';
  const admin = '22222222-2222-4222-8222-222222222222';

  assert.equal(canBroadcastNews(owner, owner), true);
  assert.equal(canBroadcastNews(owner, admin), false);
  assert.equal(canBroadcastNews(null, admin), false);
  assert.equal(canBroadcastNews(owner, null), false);
});
