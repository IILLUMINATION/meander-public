// Cloud Sync хранит .mnd на диске рядом с метаданными в БД.
//
// Что закрываем регрессией:
//   - разные questId не схлопываются в один файл (было: `scene/one` → `scene_one`);
//   - путь из БД не может выйти за CLOUD_SYNC_ROOT;
//   - лимит размера рвёт поток и не оставляет staging;
//   - параллельные загрузки не делят одно временное имя;
//   - новая версия пишется в отдельный blob, старая остаётся до явного удаления.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Readable } = require('node:stream');

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'mnd-cloud-sync-'));
process.env.CLOUD_SYNC_ROOT = ROOT;

const storage = require('../dist/services/cloud_sync_storage.js');
const {
    QUEST_ID_PATTERN,
    PayloadTooLargeError,
    blobFileName,
    deleteBlob,
    legacyStoragePath,
    promoteBlob,
    readBlob,
    receiveQuestStream,
    resolveStoragePath,
} = storage;

const USER = '11111111-2222-3333-4444-555555555555';

function stream(chunks) {
    return Readable.from(chunks);
}

test('questId: слэш и точка не превращаются в подчёркивание', () => {
    assert.equal(QUEST_ID_PATTERN.test('scene_one'), true);
    assert.equal(QUEST_ID_PATTERN.test('scene/one'), false);
    assert.equal(QUEST_ID_PATTERN.test('../evil'), false);
    assert.equal(QUEST_ID_PATTERN.test('a'.repeat(129)), false);
});

test('имена blob разных questId различаются', () => {
    const a = blobFileName('scene_one', 'a'.repeat(64));
    const b = blobFileName('scene-one', 'a'.repeat(64));
    assert.notEqual(a, b);
    assert.match(a, /^scene_one\.[0-9a-f]{16}\.mnd$/);
});

test('resolveStoragePath не выпускает за root', () => {
    const ok = resolveStoragePath(`${USER}/q.mnd`);
    assert.ok(ok.startsWith(ROOT + path.sep));
    assert.throws(() => resolveStoragePath('../escape.mnd'));
    assert.throws(() => resolveStoragePath(`/etc/passwd`));
    assert.throws(() => resolveStoragePath(''));
});

test('превышение лимита — PayloadTooLargeError и без staging', async () => {
    await assert.rejects(
        receiveQuestStream(USER, stream([Buffer.alloc(64), Buffer.alloc(64)]), 100),
        (err) => err instanceof PayloadTooLargeError,
    );
    const dir = path.join(ROOT, USER);
    const leftovers = fs.existsSync(dir)
        ? fs.readdirSync(dir).filter((n) => n.startsWith('.staging-'))
        : [];
    assert.deepEqual(leftovers, []);
});

test('пустое тело не создаёт файл', async () => {
    await assert.rejects(receiveQuestStream(USER, stream([]), 100), /empty body/);
});

test('параллельные загрузки одного questId не делят staging', async () => {
    const one = Buffer.from('version one');
    const two = Buffer.from('version two');
    const [a, b] = await Promise.all([
        receiveQuestStream(USER, stream([one]), 1024),
        receiveQuestStream(USER, stream([two]), 1024),
    ]);
    assert.notEqual(a.stagingPath, b.stagingPath);
    assert.notEqual(a.fingerprint, b.fingerprint);

    const pa = await promoteBlob(a.stagingPath, USER, 'parallel', a.fingerprint);
    const pb = await promoteBlob(b.stagingPath, USER, 'parallel', b.fingerprint);
    assert.notEqual(pa.storagePath, pb.storagePath);
    // Обе версии существуют: ссылка в БД может указывать на любую, старую
    // удаляет только явный delete.
    const readA = await readBlob(pa.storagePath);
    const readB = await readBlob(pb.storagePath);
    assert.equal(readA.size, one.length);
    assert.equal(readB.size, two.length);
    await deleteBlob(pa.storagePath);
    await deleteBlob(pb.storagePath);
});

test('тот же содержимый blob переиспользуется, staging не остаётся', async () => {
    const body = Buffer.from('same bytes');
    const first = await receiveQuestStream(USER, stream([body]), 1024);
    const p1 = await promoteBlob(first.stagingPath, USER, 'same', first.fingerprint);
    assert.equal(p1.created, true);

    const second = await receiveQuestStream(USER, stream([body]), 1024);
    const p2 = await promoteBlob(second.stagingPath, USER, 'same', second.fingerprint);
    assert.equal(p2.created, false);
    assert.equal(p1.storagePath, p2.storagePath);
    assert.equal(fs.existsSync(second.stagingPath), false);
    await deleteBlob(p1.storagePath);
});

test('legacy путь указывает на старую раскладку <userId>/<questId>.mnd', () => {
    assert.equal(
        resolveStoragePath(legacyStoragePath(USER, 'oldq')),
        path.join(ROOT, USER, 'oldq.mnd'),
    );
    assert.throws(() => legacyStoragePath(USER, 'bad/id'));
});

test('deleteAllUserFiles сносит каталог пользователя', async () => {
    const received = await receiveQuestStream(USER, stream([Buffer.from('x')]), 1024);
    const promoted = await promoteBlob(received.stagingPath, USER, 'bulk', received.fingerprint);
    assert.equal(fs.existsSync(promoted.absPath), true);
    await storage.deleteAllUserFiles(USER);
    assert.equal(fs.existsSync(path.join(ROOT, USER)), false);
});
