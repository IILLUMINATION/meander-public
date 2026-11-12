import { createHash } from 'crypto';
import { createReadStream } from 'fs';
import { pipeline } from 'stream/promises';

import pool from '../config/database';

/**
 * Общие проверки для дорогих публикаций (музыка, ассеты маркета).
 *
 * Раньше `is_blocked` и лимит «5 в час» проверялись уже ПОСЛЕ multer: файл до
 * 100 МБ успевал лечь в temp, и только потом запрос получал 403/429. Теперь
 * проверка стоит перед приёмом файла, а лимит попыток считает сам
 * express-rate-limit в роуте.
 */

export type UploadTable = 'music_tracks' | 'market_assets';

export type UploadDenial = { status: number; error: string };

/** Возвращает отказ или `null`, если грузить можно. */
export async function checkUploadAllowed(
    userId: string,
    table: UploadTable,
): Promise<UploadDenial | null> {
    const blk = await pool.query('SELECT is_blocked FROM profiles WHERE id=$1', [userId]);
    if (blk.rows[0]?.is_blocked) {
        return { status: 403, error: 'You are blocked' };
    }
    const recent = await pool.query(
        `SELECT COUNT(*) FROM ${table}
          WHERE author_id=$1 AND created_at > NOW() - INTERVAL '1 hour'`,
        [userId],
    );
    if (parseInt(String(recent.rows[0]?.count ?? '0'), 10) >= 5) {
        return { status: 429, error: 'Too many uploads. Max 5 per hour.' };
    }
    return null;
}

/**
 * SHA-256 файла потоком. Старое `readFileSync` поднимало в память весь файл
 * (до 100 МБ) и блокировало event loop на всё время хеширования.
 */
export async function hashFile(filePath: string): Promise<string> {
    const hash = createHash('sha256');
    await pipeline(createReadStream(filePath), hash);
    return hash.digest('hex');
}