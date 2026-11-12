// Негативный контроль: без проверки подписи Telegram-токена тесты
// «неверная подпись — 401» и «alg=none — 401» падают сами по себе.
//
// Что проверяем: сканер текста квеста обязан отличать «прочитано и чисто» от
// «нечего читать», а решение о публикации — непубликованный текст не
// авто- approve.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');

const { analyzeQuestZip, publishDecision } = require('../dist/services/quest_scan');

// === минимальный ZIP (stored, без сжатия) ===
// yazl/archiver в зависимостях нет, а фикстуры нужны такие, чтобы битый или
// отсутствующий nodes.json был именно таким, каким его принесёт игрок.
function crc32(buf) {
    return zlib.crc32(buf) >>> 0;
}

function buildZip(entries) {
    const chunks = [];
    const central = [];
    let offset = 0;

    for (const entry of entries) {
        const nameBuf = Buffer.from(entry.name, 'utf8');
        const data = Buffer.isBuffer(entry.data) ? entry.data : Buffer.from(entry.data, 'utf8');
        const crc = crc32(data);

        const local = Buffer.alloc(30);
        local.writeUInt32LE(0x04034b50, 0);
        local.writeUInt16LE(20, 4);
        local.writeUInt16LE(0, 6);
        local.writeUInt16LE(0, 8); // stored
        local.writeUInt16LE(0, 10);
        local.writeUInt16LE(0, 12);
        local.writeUInt32LE(crc, 14);
        local.writeUInt32LE(data.length, 18);
        local.writeUInt32LE(data.length, 22);
        local.writeUInt16LE(nameBuf.length, 26);
        local.writeUInt16LE(0, 28);
        chunks.push(local, nameBuf, data);

        const dir = Buffer.alloc(46);
        dir.writeUInt32LE(0x02014b50, 0);
        dir.writeUInt16LE(20, 4);
        dir.writeUInt16LE(20, 6);
        dir.writeUInt16LE(0, 8);
        dir.writeUInt16LE(0, 10);
        dir.writeUInt16LE(0, 12);
        dir.writeUInt16LE(0, 14);
        dir.writeUInt32LE(crc, 16);
        dir.writeUInt32LE(data.length, 20);
        dir.writeUInt32LE(data.length, 24);
        dir.writeUInt16LE(nameBuf.length, 28);
        dir.writeUInt16LE(0, 30);
        dir.writeUInt16LE(0, 32);
        dir.writeUInt16LE(0, 36);
        dir.writeUInt16LE(0, 38);
        dir.writeUInt32LE(0, 42);
        dir.writeUInt32LE(offset, 42);
        central.push(Buffer.concat([dir, nameBuf]));

        offset += local.length + nameBuf.length + data.length;
    }

    const centralBuf = Buffer.concat(central);
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0);
    end.writeUInt16LE(entries.length, 8);
    end.writeUInt16LE(entries.length, 10);
    end.writeUInt32LE(centralBuf.length, 12);
    end.writeUInt32LE(offset, 16);

    return Buffer.concat([...chunks, centralBuf, end]);
}

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'quest-scan-test-'));

function writeQuest(entries) {
    const file = path.join(tempDir, `quest-${Math.random().toString(36).slice(2)}.zip`);
    fs.writeFileSync(file, buildZip(entries));
    return file;
}

const GOOD_NODES = JSON.stringify({
    nodes: [
        { title: 'Лес', content: { items: [{ type: 'text', text: 'Тропа уходит между сосен.' }] } },
        { title: 'Избушка', content: { items: [{ type: 'text', text: 'На столе записка.' }] } },
    ],
});

test('Хороший nodes.json: текст прочитан, флаг сбоя не выставлен', async () => {
    const r = await analyzeQuestZip(writeQuest([{ name: 'nodes.json', data: GOOD_NODES }]), tempDir);
    assert.strictEqual(r.textScanFailed, false);
    assert.strictEqual(r.nodeCount, 2);
    assert.match(r.fullText, /Тропа уходит между сосен/);
});

test('Архив без nodes.json считается непрочитанным (было: «чисто»)', async () => {
    const r = await analyzeQuestZip(writeQuest([{ name: 'data.txt', data: 'что-то внутри' }]), tempDir);
    assert.strictEqual(r.textScanFailed, true);
    assert.strictEqual(r.fullText, '');
});

test('Битый nodes.json считается непрочитанным', async () => {
    const r = await analyzeQuestZip(writeQuest([{ name: 'nodes.json', data: '{"nodes": [' }]), tempDir);
    assert.strictEqual(r.textScanFailed, true);
});

test('nodes.json без массива nodes считается непрочитанным', async () => {
    const r = await analyzeQuestZip(writeQuest([{ name: 'nodes.json', data: '{"nodes": {}}' }]), tempDir);
    assert.strictEqual(r.textScanFailed, true);
});

test('Непрочитанный текст не получает Auto-approved', () => {
    assert.deepStrictEqual(publishDecision(null, false), {
        status: 'published',
        moderatorComment: 'Auto-approved',
    });
    assert.deepStrictEqual(publishDecision(null, true), {
        status: 'in_review',
        moderatorComment: 'Flag: текст игры не прочитан модерацией',
    });
});

test('Флаг правил важнее: спорный текст уходит in_review с причиной', () => {
    assert.deepStrictEqual(publishDecision({ approved: false, reason: 'мат в названии' }, false), {
        status: 'in_review',
        moderatorComment: 'Flag: мат в названии',
    });
    // И при сломанном скане причина модерации остаётся первой.
    assert.strictEqual(publishDecision({ approved: false, reason: 'спас' }, true).moderatorComment, 'Flag: спас');
    assert.strictEqual(publishDecision({ approved: true, reason: '' }, true).status, 'in_review');
});

// Убирать фикстуры надо после прогонов: top-level rmSync отработал бы раньше
// асинхронных тестов и оставил бы им пустую директорию.
process.on('exit', () => fs.rmSync(tempDir, { recursive: true, force: true }));
test('Слишком много узлов — скан помечен как неудачный, а не «чисто»', async () => {
    const nodes = { nodes: Array.from({ length: 5001 }, (_, i) => ({ title: `N${i}`, content: { items: [] } })) };
    const r = await analyzeQuestZip(writeQuest([{ name: 'nodes.json', data: JSON.stringify(nodes) }]), tempDir);
    assert.strictEqual(r.textScanFailed, true);
    assert.strictEqual(r.nodeCount, 5001);
});

test('Слишком много элементов контента — скан помечен как неудачный', async () => {
    // 400 узлов по 200 элементов = 80 000 > 50 000.
    const nodes = {
        nodes: Array.from({ length: 400 }, () => ({
            title: 'n',
            content: { items: Array.from({ length: 200 }, () => ({ type: 'text', text: 'x' })) },
        })),
    };
    const r = await analyzeQuestZip(writeQuest([{ name: 'nodes.json', data: JSON.stringify(nodes) }]), tempDir);
    assert.strictEqual(r.textScanFailed, true);
});
