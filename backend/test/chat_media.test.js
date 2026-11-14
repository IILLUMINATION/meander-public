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
// ---------------------------------------------------------------------------
//  Сжатие: сервер не верит клиенту и приводит кадр к своим правилам.
// ---------------------------------------------------------------------------
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const sharp = require('sharp');

const { compressChatImage, CHAT_IMAGE_MAX_SIDE } = require('../dist/services/chat_media');

test('большой кадр ужимается до 1600 px и теряет EXIF', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'meander-chat-'));
  const source = path.join(dir, 'huge.jpg');
  await sharp({
    create: {
      width: 3200,
      height: 2000,
      channels: 3,
      background: { r: 30, g: 90, b: 160 },
    },
  })
    .jpeg({ quality: 92 })
    .withMetadata({ exif: { IFD0: { Copyright: 'hidden-location' } } })
    .toFile(source);

  const attachment = await compressChatImage(source);
  assert.equal(attachment.width, CHAT_IMAGE_MAX_SIDE);
  assert.ok(attachment.height <= CHAT_IMAGE_MAX_SIDE);
  assert.ok(attachment.url.startsWith(publicUrl('/uploads/')));

  // Файл на диске тоже без метаданных: иначе они уезжают в публичный урл.
  const stored = path.join(process.cwd(), 'public/uploads', path.basename(attachment.url));
  const meta = await sharp(stored).metadata();
  assert.equal(meta.exif, undefined);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.rmSync(stored, { force: true });
});

test('кадр с прозрачностью остаётся прозрачным (webp, а не jpeg)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'meander-chat-'));
  const source = path.join(dir, 'alpha.png');
  await sharp({
    create: {
      width: 400,
      height: 400,
      channels: 4,
      background: { r: 255, g: 0, b: 0, alpha: 0.5 },
    },
  })
    .png()
    .toFile(source);

  const attachment = await compressChatImage(source);
  assert.ok(attachment.url.endsWith('.webp'));
  assert.equal(attachment.mime, 'image/webp');
  const stored = path.join(process.cwd(), 'public/uploads', path.basename(attachment.url));
  const meta = await sharp(stored).metadata();
  assert.equal(meta.hasAlpha, true);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.rmSync(stored, { force: true });
});

test('не картинка не превращается в файл в общем доступе', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'meander-chat-'));
  const source = path.join(dir, 'note.jpg');
  fs.writeFileSync(source, 'это не картинка');
  await assert.rejects(() => compressChatImage(source));
  fs.rmSync(dir, { recursive: true, force: true });
});
