// Вложения чата: что принимаем, что отбрасываем.
//
// Ссылку из тела сообщения рисует клиент, поэтому «наши» адреса проверяются
// на сервере: иначе в ленту можно вставить javascript: или чужой трекер.

const test = require('node:test');
const assert = require('node:assert');

const {
  CHAT_ALBUM_MAX,
  isOurUploadUrl,
  isChatImageName,
  normalizeAttachments,
} = require('../dist/services/chat_media');
const { publicUrl } = require('../dist/config/public_host');

const ours = publicUrl('/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jpg');

test('ссылка на наш загруженный файл принимается', () => {
  assert.equal(isOurUploadUrl(ours), true);
});

test('чужие и опасные ссылки отбрасываются', () => {
  assert.equal(isOurUploadUrl('https://evil.example/x.jpg'), false);
  assert.equal(isOurUploadUrl('javascript:alert(1)'), false);
  assert.equal(isOurUploadUrl(`${publicUrl('/uploads/')}../secret`), false);
  assert.equal(isOurUploadUrl(`${ours}?x=1`), false);
  assert.equal(isOurUploadUrl(`${publicUrl('/uploads/')}not-a-uuid.jpg`), false);
});

test('альбом ограничен пятью кадрами', () => {
  const one = {
    url: ours,
    width: 100,
    height: 100,
    size: 1000,
    mime: 'image/jpeg',
  };
  const many = Array.from({ length: CHAT_ALBUM_MAX + 3 }, () => one);
  assert.equal(normalizeAttachments(many).length, CHAT_ALBUM_MAX);
});

test('нечисловые размеры становятся нулём, а не NaN в jsonb', () => {
  const [attachment] = normalizeAttachments([
    { url: ours, width: 'широко', height: -5, size: null, mime: 42 },
  ]);
  assert.equal(attachment.width, 0);
  assert.equal(attachment.height, 0);
  assert.equal(attachment.size, 0);
  assert.equal(attachment.mime, '');
});

test('не-массив и мусор внутри не роняют отправку', () => {
  assert.deepStrictEqual(normalizeAttachments(null), []);
  assert.deepStrictEqual(normalizeAttachments('url'), []);
  assert.deepStrictEqual(normalizeAttachments([null, 42, { url: 1 }]), []);
});

test('расширения картинок распознаются по имени', () => {
  assert.equal(isChatImageName('photo.JPG'), true);
  assert.equal(isChatImageName('photo.heic'), true);
  assert.equal(isChatImageName('photo.svg'), false);
  assert.equal(isChatImageName('archive.zip'), false);
  assert.equal(isChatImageName(''), false);
});