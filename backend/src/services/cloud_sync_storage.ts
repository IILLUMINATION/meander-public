import { promises as fs, createReadStream } from 'fs';
import { createWriteStream } from 'fs';
import path from 'path';
import crypto from 'crypto';
import { Transform } from 'stream';
import { pipeline } from 'stream/promises';

/**
 * Meander Cloud — физическое хранилище на локальной ФС.
 *
 * Раскладка: `<root>/<userId>/<questId>.<fingerprint8>.mnd`.
 *
 * Имя blob'а содержит отпечаток содержимого: новая версия квеста — новый
 * файл, старый удаляется только после успешного COMMIT в БД. Раньше файл
 * перезаписывался по `<questId>.mnd` до записи метаданных, и сбой SQL терял
 * предыдущее сохранение.
 *
 * questId не нормализуется: `scene/one` и `scene_one` раньше превращались в
 * один файл и затирали друг друга. Теперь допустим только строгий allowlist,
 * иначе 400.
 *
 * Конфигурируется через env CLOUD_SYNC_ROOT (по умолчанию `<cwd>/storage/cloud_sync`).
 */

function resolveRoot(): string {
    const env = process.env.CLOUD_SYNC_ROOT;
    if (env && env.trim().length > 0) return path.resolve(env);
    return path.resolve(process.cwd(), 'storage', 'cloud_sync');
}

export const CLOUD_SYNC_ROOT = resolveRoot();

/** Допустимый questId: латиница, цифры, `_`, `-`, до 128 символов. */
export const QUEST_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

/** клиент прислал слишком большое тело. */
export class PayloadTooLargeError extends Error {
    readonly limit: number;
    constructor(limit: number) {
        super('payload too large');
        this.name = 'PayloadTooLargeError';
        this.limit = limit;
    }
}

export function assertQuestId(questId: string): void {
    if (!QUEST_ID_PATTERN.test(questId)) {
        throw new Error(`Invalid questId for storage: ${questId}`);
    }
}

async function ensureDir(p: string): Promise<void> {
    await fs.mkdir(p, { recursive: true });
}

function userDir(userId: string): string {
    // Защита от path traversal — допускаем только UUID-like символы
    if (!/^[0-9a-fA-F-]{32,40}$/.test(userId)) {
        throw new Error(`Invalid userId for storage: ${userId}`);
    }
    return path.join(CLOUD_SYNC_ROOT, userId);
}

/** Имя blob'а версии: уникально для (questId, содержимое). */
export function blobFileName(questId: string, fingerprint: string): string {
    assertQuestId(questId);
    const fp = fingerprint.slice(0, 16);
    if (!/^[0-9a-f]{16}$/.test(fp)) {
        throw new Error('fingerprint must be hex sha256');
    }
    return `${questId}.${fp}.mnd`;
}

/** Путь к blob'у по данным строки БД (`storage_path`). */
export function resolveStoragePath(storagePath: string): string {
    if (!storagePath || storagePath.trim().length === 0) {
        throw new Error('storage_path is empty');
    }
    if (path.isAbsolute(storagePath)) {
        throw new Error('storage_path must be relative');
    }
    const abs = path.resolve(CLOUD_SYNC_ROOT, storagePath);
    const rootWithSep = CLOUD_SYNC_ROOT.endsWith(path.sep)
        ? CLOUD_SYNC_ROOT
        : CLOUD_SYNC_ROOT + path.sep;
    if (!abs.startsWith(rootWithSep)) {
        throw new Error('storage_path escapes CLOUD_SYNC_ROOT');
    }
    return abs;
}

/** Старый путь `<userId>/<questId>.mnd` — для записей без storage_path. */
export function legacyStoragePath(userId: string, questId: string): string {
    assertQuestId(questId);
    return path.join(userId, `${questId}.mnd`);
}

/**
 * Принять поток тела в staging-файл с жёстким лимитом байт.
 *
 * Тело никогда не буферизуется целиком: раньше `express.raw({limit:'200mb'})`
 * держал в RAM до 200 МБ на запрос, и отказ по квоте происходил уже после
 * этого. Здесь превышение лимита рвёт поток, а staging удаляется.
 */
export async function receiveQuestStream(
    userId: string,
    source: NodeJS.ReadableStream,
    maxBytes: number,
): Promise<{ stagingPath: string; size: number; fingerprint: string; created: true }> {
    const dir = userDir(userId);
    await ensureDir(dir);
    // Уникальное имя + флаг wx: две параллельные загрузки одного questId
    // раньше писали в один `<file>.tmp-<Date.now()>` и портили друг друга.
    const stagingPath = path.join(dir, `.staging-${crypto.randomUUID()}`);
    const hash = crypto.createHash('sha256');
    let size = 0;

    const counter = new Transform({
        transform(chunk: Buffer, _enc, cb) {
            size += chunk.length;
            if (size > maxBytes) {
                cb(new PayloadTooLargeError(maxBytes));
                return;
            }
            hash.update(chunk);
            cb(null, chunk);
        },
    });

    try {
        await pipeline(
            source,
            counter,
            createWriteStream(stagingPath, { flags: 'wx' }),
        );
    } catch (e) {
        await fs.unlink(stagingPath).catch(() => {});
        throw e;
    }

    if (size === 0) {
        await fs.unlink(stagingPath).catch(() => {});
        throw new Error('empty body');
    }

    return {
        stagingPath,
        size,
        fingerprint: hash.digest('hex'),
        created: true,
    };
}

/**
 * Перенести staging на постоянное место версии.
 *
 * Если такой blob уже есть (тот же questId и то же содержимое) — staging
 * просто удаляется, `created: false`: файл принадлежит другой записи, и
 * откатывающая ветка не должна его удалять.
 */
export async function promoteBlob(
    stagingPath: string,
    userId: string,
    questId: string,
    fingerprint: string,
): Promise<{ storagePath: string; absPath: string; created: boolean }> {
    const absPath = path.join(userDir(userId), blobFileName(questId, fingerprint));
    const storagePath = path.relative(CLOUD_SYNC_ROOT, absPath).split(path.sep).join('/');
    try {
        await fs.access(absPath);
        await fs.unlink(stagingPath).catch(() => {});
        return { storagePath, absPath, created: false };
    } catch {
        // Файла ещё нет — переносим.
    }
    try {
        await fs.rename(stagingPath, absPath);
    } catch (e) {
        // Гонка: параллельная загрузка успела положить тот же blob.
        const code = (e as NodeJS.ErrnoException).code;
        if (code === 'EEXIST' || code === 'ENOTEMPTY') {
            await fs.unlink(stagingPath).catch(() => {});
            return { storagePath, absPath, created: false };
        }
        await fs.unlink(stagingPath).catch(() => {});
        throw e;
    }
    return { storagePath, absPath, created: true };
}

export async function readBlob(
    storagePath: string,
): Promise<{ stream: NodeJS.ReadableStream; size: number }> {
    const abs = resolveStoragePath(storagePath);
    const stat = await fs.stat(abs);
    if (!stat.isFile()) throw new Error(`Not a file: ${abs}`);
    return { stream: createReadStream(abs), size: stat.size };
}

export async function deleteBlob(storagePath: string): Promise<void> {
    if (!storagePath) return;
    const abs = resolveStoragePath(storagePath);
    try {
        await fs.unlink(abs);
    } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e;
    }
}

export function sha256Hex(data: Buffer): string {
    return crypto.createHash('sha256').update(data).digest('hex');
}

/**
 * Удалить все файлы пользователя (например, при DELETE аккаунта).
 * Best-effort: ENOENT игнорируем.
 */
export async function deleteAllUserFiles(userId: string): Promise<void> {
    const dir = userDir(userId);
    try {
        await fs.rm(dir, { recursive: true, force: true });
    } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e;
    }
}