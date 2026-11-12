import express, { Router, Response } from 'express';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import { validate as uuidValidate } from 'uuid';

import pool from '../config/database';
import type { PoolClient } from 'pg';
import authMiddleware, { AuthRequest } from '../middleware/auth';
import {
    TIERS,
    TierName,
    recomputeTier,
    grantTier,
    buildUpgradeHints,
} from '../services/cloud_sync_tier';
import {
    QUEST_ID_PATTERN,
    PayloadTooLargeError,
    blobFileName,
    deleteBlob,
    legacyStoragePath,
    promoteBlob,
    readBlob,
    receiveQuestStream,
} from '../services/cloud_sync_storage';
import { runCloudSyncCleanup } from '../services/cloud_sync_cleanup';
import { clientIp } from '../services/client_ip';

const router = Router();

// ============================================================================
//  Rate limits (per authenticated user)
// ============================================================================

// Если юзер не аутентифицирован, фолбэк на IP с корректной IPv6 обработкой.
const userKey = (req: AuthRequest, res: Response): string =>
    req.user?.id || ipKeyGenerator(clientIp(req));

const limitQuotaGet = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 300,
    keyGenerator: userKey,
    standardHeaders: true,
});
const limitList = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 200,
    keyGenerator: userKey,
});
const limitCheck = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 600,
    keyGenerator: userKey,
    standardHeaders: true,
});
const limitUpload = rateLimit({
    windowMs: 60 * 60 * 1000,
    // Массовая первая синхронизация может содержать сотни квестов; 30/час было
    // слишком мало и приводило к 429 "Too many requests".
    max: 300,
    keyGenerator: userKey,
    standardHeaders: true,
});
const limitDownload = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 300,
    keyGenerator: userKey,
    standardHeaders: true,
});

// ============================================================================
//  Quota helpers
// ============================================================================

interface QuotaRow {
    tier: TierName;
    used_bytes: number;
    used_quests: number;
    max_bytes: number;
    max_quests: number;
    max_quest_bytes: number;
    max_refs: number;
    granted_reason: string | null;
    expires_at: Date | null;
}

async function ensureQuotaRow(userId: string): Promise<QuotaRow> {
    const r = await pool.query(
        `SELECT tier, used_bytes, used_quests,
                max_bytes, max_quests, max_quest_bytes, max_refs,
                granted_reason, expires_at
           FROM cloud_sync_quotas WHERE user_id = $1`,
        [userId],
    );
    if ((r.rowCount ?? 0) > 0) {
        return r.rows[0] as QuotaRow;
    }
    // Первый запрос — создаём запись и считаем tier
    await recomputeTier(userId);
    const r2 = await pool.query(
        `SELECT tier, used_bytes, used_quests,
                max_bytes, max_quests, max_quest_bytes, max_refs,
                granted_reason, expires_at
           FROM cloud_sync_quotas WHERE user_id = $1`,
        [userId],
    );
    return r2.rows[0] as QuotaRow;
}

async function loadCounts(userId: string): Promise<{ user: number; ref: number }> {
    const r = await pool.query(
        `SELECT
            COALESCE(SUM(CASE WHEN source = 'user'       THEN 1 ELSE 0 END), 0)::int AS user_cnt,
            COALESCE(SUM(CASE WHEN source = 'market_ref' THEN 1 ELSE 0 END), 0)::int AS ref_cnt
         FROM cloud_sync_quests
         WHERE user_id = $1 AND deleted_at IS NULL`,
        [userId],
    );
    return {
        user: Number(r.rows[0]?.user_cnt) || 0,
        ref: Number(r.rows[0]?.ref_cnt) || 0,
    };
}

/** Ошибка квоты: превращается в 4xx без «внутренней» 500. */
class QuotaError extends Error {
    readonly status: number;
    readonly code: string;
    constructor(code: string, status = 413) {
        super(code);
        this.name = 'QuotaError';
        this.code = code;
        this.status = status;
    }
}

/**
 * Транзакция с блокировкой строки квоты пользователя.
 *
 * Раньше проверка остатка и запись шли без транзакции: два параллельных PUT
 * читали один `used_bytes` и оба решали, что места хватает. `FOR UPDATE` на
 * `cloud_sync_quotas` сериализует загрузки одного пользователя.
 */
async function withQuotaLock<T>(
    userId: string,
    fn: (client: PoolClient, quota: QuotaRow) => Promise<T>,
): Promise<T> {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const q = await client.query(
            `SELECT tier, used_bytes, used_quests,
                    max_bytes, max_quests, max_quest_bytes, max_refs,
                    granted_reason, expires_at
               FROM cloud_sync_quotas WHERE user_id = $1 FOR UPDATE`,
            [userId],
        );
        if ((q.rowCount ?? 0) === 0) {
            throw new Error('quota row missing');
        }
        const result = await fn(client, q.rows[0] as QuotaRow);
        await client.query('COMMIT');
        return result;
    } catch (e) {
        await client.query('ROLLBACK').catch(() => {});
        throw e;
    } finally {
        client.release();
    }
}

/** Счётчики слотов внутри транзакции (для проверки квоты). */
async function loadCountsTx(client: PoolClient, userId: string): Promise<{ user: number; ref: number }> {
    const r = await client.query(
        `SELECT
            COALESCE(SUM(CASE WHEN source = 'user'       THEN 1 ELSE 0 END), 0)::int AS user_cnt,
            COALESCE(SUM(CASE WHEN source = 'market_ref' THEN 1 ELSE 0 END), 0)::int AS ref_cnt
         FROM cloud_sync_quests
         WHERE user_id = $1 AND deleted_at IS NULL`,
        [userId],
    );
    return {
        user: Number(r.rows[0]?.user_cnt) || 0,
        ref: Number(r.rows[0]?.ref_cnt) || 0,
    };
}

async function audit(
    userId: string,
    questId: string | null,
    action: string,
    bytes: number | null,
    detail?: any,
): Promise<void> {
    try {
        await pool.query(
            `INSERT INTO cloud_sync_audit (user_id, quest_id, action, bytes, detail)
             VALUES ($1, $2, $3, $4, $5::jsonb)`,
            [userId, questId, action, bytes, detail ? JSON.stringify(detail) : null],
        );
    } catch (_) {
        // best-effort
    }
}

// ============================================================================
//  Public routes (require auth)
// ============================================================================

router.use(authMiddleware);

// Парсеры тела — только после проверки токена. Пока они висели на mount'е в
// app.ts, любой аноним мог прислать application/octet-stream до 200 МБ, и Node
// буферизовал это целиком: один curl без токена укладывал 200 МБ в память процесса.
//
// Бинарный `.mnd` больше не проходит через express.raw: PUT-обработчик сам
// стримит тело в staging-файл с жёстким лимитом (см. receiveQuestStream), так
// что даже авторизованный пользователь без квоты не заставляет процесс держать
// тело в RAM. JSON (market_ref) остаётся буферизованным — он маленький.
router.use(express.json({ limit: '5mb' }));

// ----------------------------------------------------------------------------
//  GET /cloud-sync/quota
// ----------------------------------------------------------------------------
router.get('/quota', limitQuotaGet, async (req: AuthRequest, res: Response) => {
    try {
        const userId = req.user?.id!;
        // Lazy recompute (дешёвый — выполняется в фоне один раз)
        await ensureQuotaRow(userId);
        const tier = await recomputeTier(userId);
        const q = await ensureQuotaRow(userId);
        const counts = await loadCounts(userId);
        const hints = await buildUpgradeHints(userId, tier);
        res.json({
            tier: q.tier,
            usedBytes: Number(q.used_bytes) || 0,
            usedQuests: counts.user,
            usedRefs: counts.ref,
            maxBytes: Number(q.max_bytes) || 0,
            maxQuests: q.max_quests,
            maxQuestBytes: Number(q.max_quest_bytes) || 0,
            maxRefs: q.max_refs,
            grantedReason: q.granted_reason,
            expiresAt: q.expires_at,
            upgradeHints: hints,
        });
    } catch (e: any) {
        console.error('[cloud-sync] quota:', e);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ----------------------------------------------------------------------------
//  GET /cloud-sync/quests
// ----------------------------------------------------------------------------
router.get('/quests', limitList, async (req: AuthRequest, res: Response) => {
    try {
        const userId = req.user?.id!;
        const r = await pool.query(
            `SELECT q.quest_id, q.title, q.source, q.size_bytes, q.fingerprint,
                    q.market_quest_id, q.market_version, q.updated_at,
                    mq.status AS market_status,
                    mq.version AS market_current_version
               FROM cloud_sync_quests q
          LEFT JOIN quests mq ON mq.id = q.market_quest_id
              WHERE q.user_id = $1 AND q.deleted_at IS NULL
              ORDER BY q.updated_at DESC`,
            [userId],
        );
        const list = r.rows.map((row: any) => {
            const isRef = row.source === 'market_ref';
            const marketAvailable = isRef && row.market_status === 'published';
            return {
                questId: row.quest_id,
                title: row.title,
                source: row.source,
                size: Number(row.size_bytes) || 0,
                fingerprint: row.fingerprint,
                updatedAt: row.updated_at,
                marketQuestId: row.market_quest_id || undefined,
                marketVersion: row.market_version || undefined,
                marketCurrentVersion: row.market_current_version || undefined,
                marketAvailable: isRef ? marketAvailable : undefined,
                downloadPath: isRef
                    ? `/cloud-sync/quests/${row.quest_id}`
                    : `/cloud-sync/quests/${row.quest_id}`,
            };
        });
        res.json(list);
    } catch (e: any) {
        console.error('[cloud-sync] list:', e);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ----------------------------------------------------------------------------
//  POST /cloud-sync/quests/:questId/check
//
//  body: { fingerprint, size, marketRef?: { marketQuestId, version } }
//  возвращает: { exists, sameFingerprint, wouldExceedQuota, supportsMarketRef,
//                recommendation: 'skip' | 'market_ref' | 'upload',
//                remoteFingerprint, remoteUpdatedAt }
// ----------------------------------------------------------------------------
router.post('/quests/:questId/check', limitCheck, async (req: AuthRequest, res: Response) => {
    try {
        const userId = req.user?.id!;
        const { questId } = req.params;
        const { fingerprint, size, marketRef } = req.body || {};

        if (typeof fingerprint !== 'string' || fingerprint.length < 8) {
            return res.status(400).json({ error: 'fingerprint required' });
        }
        const requestedSize = Number(size) || 0;

        const q = await ensureQuotaRow(userId);
        const counts = await loadCounts(userId);

        const existing = await pool.query(
            `SELECT source, size_bytes, fingerprint, market_quest_id, market_version, updated_at
               FROM cloud_sync_quests
              WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL`,
            [userId, questId],
        );
        const row = (existing.rowCount ?? 0) > 0 ? existing.rows[0] : null;

        // Проверка валидности market_ref
        let supportsMarketRef = false;
        if (marketRef && marketRef.marketQuestId && uuidValidate(marketRef.marketQuestId)) {
            const mq = await pool.query(
                `SELECT id, status FROM quests WHERE id = $1`,
                [marketRef.marketQuestId],
            );
            supportsMarketRef =
                (mq.rowCount ?? 0) > 0 && mq.rows[0].status === 'published';
        }

        // Если идентичный fingerprint уже на сервере — ничего не делаем
        if (row && row.fingerprint === fingerprint) {
            return res.json({
                exists: true,
                sameFingerprint: true,
                wouldExceedQuota: false,
                supportsMarketRef,
                recommendation: 'skip',
                remoteFingerprint: row.fingerprint,
                remoteUpdatedAt: row.updated_at,
            });
        }

        // Если у пользователя есть валидный market_ref в запросе — рекомендуем ссылку.
        // Квота для refs полностью независимая от user-слотов, чтобы маркет-ссылки
        // не съедали лимит на свои квесты.
        if (supportsMarketRef) {
            const wouldNeedRefSlot = !row || row.source !== 'market_ref';
            const refOverflow =
                wouldNeedRefSlot && counts.ref >= q.max_refs && q.tier !== 'admin';

            return res.json({
                exists: !!row,
                sameFingerprint: false,
                wouldExceedQuota: refOverflow,
                supportsMarketRef: true,
                recommendation: refOverflow ? 'none' : 'market_ref',
                reason: refOverflow ? 'ref_quota_exceeded' : undefined,
                remoteFingerprint: row?.fingerprint,
                remoteUpdatedAt: row?.updated_at,
            });
        }

        // Обычный путь — upload
        if (q.tier === 'none' || q.max_bytes === 0) {
            return res.json({
                exists: !!row,
                sameFingerprint: false,
                wouldExceedQuota: true,
                supportsMarketRef: false,
                recommendation: 'none',
                reason: 'no_quota',
                remoteFingerprint: row?.fingerprint,
                remoteUpdatedAt: row?.updated_at,
            });
        }

        if (requestedSize > Number(q.max_quest_bytes)) {
            return res.json({
                exists: !!row,
                sameFingerprint: false,
                wouldExceedQuota: true,
                supportsMarketRef: false,
                recommendation: 'none',
                reason: 'file_too_large',
                remoteFingerprint: row?.fingerprint,
                remoteUpdatedAt: row?.updated_at,
            });
        }

        // Лимит на user-слоты считается ТОЛЬКО по user-квестам,
        // market_ref имеют отдельный max_refs.
        const oldSize = row?.source === 'user' ? Number(row?.size_bytes) || 0 : 0;
        const projectedBytes =
            (Number(q.used_bytes) || 0) - oldSize + requestedSize;
        const bytesOverflow = projectedBytes > Number(q.max_bytes);
        const slotsOverflow =
            !row && counts.user >= q.max_quests && q.tier !== 'admin';
        const wouldExceedQuota = bytesOverflow || slotsOverflow;

        return res.json({
            exists: !!row,
            sameFingerprint: false,
            wouldExceedQuota,
            supportsMarketRef: false,
            recommendation: wouldExceedQuota ? 'none' : 'upload',
            reason: bytesOverflow
                ? 'bytes_quota_exceeded'
                : (slotsOverflow ? 'quest_quota_exceeded' : undefined),
            remoteFingerprint: row?.fingerprint,
            remoteUpdatedAt: row?.updated_at,
        });
    } catch (e: any) {
        console.error('[cloud-sync] check:', e);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ----------------------------------------------------------------------------
//  PUT /cloud-sync/quests/:questId
//
//  Два режима:
//    application/octet-stream  → upload (источник 'user')
//        headers: x-title, x-fingerprint (опц.)
//    application/json          → market_ref
//        body: { title, marketQuestId, marketVersion? }
// ----------------------------------------------------------------------------
router.put(
    '/quests/:questId',
    limitUpload,
    async (req: AuthRequest, res: Response) => {
        const userId = req.user?.id!;
        const { questId } = req.params;
        // Строгий allowlist вместо «заменим спецсимволы подчёркиванием»:
        // `scene/one` и `scene_one` раньше становились одним файлом и
        // перетирали друг друга.
        if (!QUEST_ID_PATTERN.test(questId)) {
            return res.status(400).json({ error: 'invalid quest id' });
        }

        const contentType = String(req.headers['content-type'] || '');

        // ----- Режим B: market_ref (маленький JSON) -----
        if (contentType.includes('application/json')) {
            try {
                const { title, marketQuestId, marketVersion } = req.body || {};
                if (typeof title !== 'string' || title.trim().length === 0) {
                    return res.status(400).json({ error: 'title required' });
                }
                if (!marketQuestId || !uuidValidate(marketQuestId)) {
                    return res.status(400).json({ error: 'marketQuestId must be uuid' });
                }

                const mq = await pool.query(
                    `SELECT id, status FROM quests WHERE id = $1`,
                    [marketQuestId],
                );
                if ((mq.rowCount ?? 0) === 0 || mq.rows[0].status !== 'published') {
                    return res.status(404).json({ error: 'market quest not available' });
                }

                const q = await ensureQuotaRow(userId);
                if (q.tier === 'none') {
                    return res.status(403).json({ error: 'no_quota' });
                }

                // Файл прежней user-версии удаляем только после COMMIT: при
                // сбое SQL запись всё ещё описывает её, и удалять blob нельзя.
                let obsoleteStoragePath: string | null = null;
                await withQuotaLock(userId, async (client, quota) => {
                    const existing = await client.query(
                        `SELECT source, storage_path FROM cloud_sync_quests
                          WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL
                          FOR UPDATE`,
                        [userId, questId],
                    );
                    const exists = (existing.rowCount ?? 0) > 0;
                    const counts = await loadCountsTx(client, userId);
                    if (
                        (!exists || existing.rows[0].source !== 'market_ref') &&
                        counts.ref >= quota.max_refs &&
                        quota.tier !== 'admin'
                    ) {
                        throw new QuotaError('ref_quota_exceeded', 403);
                    }
                    if (exists && existing.rows[0].source === 'user') {
                        obsoleteStoragePath = existing.rows[0].storage_path || null;
                    }
                    await client.query(
                        `INSERT INTO cloud_sync_quests (
                            user_id, quest_id, title, source, size_bytes, fingerprint,
                            storage_path, market_quest_id, market_version,
                            created_at, updated_at
                         ) VALUES ($1,$2,$3,'market_ref',0,NULL,'',$4,$5, now(), now())
                         ON CONFLICT (user_id, quest_id) DO UPDATE SET
                            title           = EXCLUDED.title,
                            source          = 'market_ref',
                            size_bytes      = 0,
                            fingerprint     = NULL,
                            storage_path    = '',
                            market_quest_id = EXCLUDED.market_quest_id,
                            market_version  = EXCLUDED.market_version,
                            deleted_at      = NULL,
                            updated_at      = now()`,
                        [
                            userId,
                            questId,
                            title.trim().slice(0, 200),
                            marketQuestId,
                            typeof marketVersion === 'string' ? marketVersion : null,
                        ],
                    );
                });

                if (obsoleteStoragePath) {
                    await deleteBlob(obsoleteStoragePath).catch(() => {});
                }
                await audit(userId, questId, 'ref_create', 0, {
                    marketQuestId,
                    marketVersion,
                });
                return res.json({
                    questId,
                    source: 'market_ref',
                    size: 0,
                    marketQuestId,
                    marketVersion: marketVersion || null,
                });
            } catch (e) {
                if (e instanceof QuotaError) {
                    return res.status(e.status).json({ error: e.code });
                }
                console.error('[cloud-sync] PUT ref error:', e);
                return res.status(500).json({ error: 'Internal server error' });
            }
        }

        // ----- Режим A: upload .mnd, потоком в staging -----
        const q = await ensureQuotaRow(userId);
        if (q.tier === 'none' || Number(q.max_bytes) === 0) {
            // Отказ ДО чтения тела: раньше 200 МБ уже лежали в памяти.
            req.resume();
            return res.status(403).json({ error: 'no_quota' });
        }
        const maxQuestBytes = Number(q.max_quest_bytes) || 0;
        const declared = Number(req.headers['content-length'] || 0);
        if (declared > 0 && declared > maxQuestBytes) {
            req.resume();
            return res.status(413).json({ error: 'file_too_large' });
        }

        // Медленное тело не должно держать соединение бесконечно.
        req.setTimeout(120_000, () => req.destroy());

        const rawTitle = String(req.headers['x-title'] || 'Без названия');
        const titleEncoding = String(req.headers['x-title-encoding'] || '');
        let title = rawTitle;
        if (titleEncoding === 'percent') {
            try {
                title = decodeURIComponent(rawTitle);
            } catch {
                // Битая percent-последовательность — оставляем как пришло.
                title = rawTitle;
            }
        }
        title = title.slice(0, 200);

        let promoted: Awaited<ReturnType<typeof promoteBlob>> | null = null;
        try {
            const received = await receiveQuestStream(userId, req, maxQuestBytes);
            const promo = await promoteBlob(
                received.stagingPath,
                userId,
                questId,
                received.fingerprint,
            );
            promoted = promo;
            const size = received.size;

            let obsoleteStoragePath: string | null = null;
            await withQuotaLock(userId, async (client, quota) => {
                if (quota.tier === 'none' || Number(quota.max_bytes) === 0) {
                    throw new QuotaError('no_quota', 403);
                }
                if (size > Number(quota.max_quest_bytes)) {
                    throw new QuotaError('file_too_large', 413);
                }
                const existing = await client.query(
                    `SELECT source, size_bytes, storage_path FROM cloud_sync_quests
                      WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL
                      FOR UPDATE`,
                    [userId, questId],
                );
                const exists = (existing.rowCount ?? 0) > 0;
                const previous = exists ? existing.rows[0] : null;
                const oldSize =
                    previous?.source === 'user' ? Number(previous.size_bytes) || 0 : 0;
                const projected = (Number(quota.used_bytes) || 0) - oldSize + size;
                if (projected > Number(quota.max_bytes) && quota.tier !== 'admin') {
                    throw new QuotaError('bytes_quota_exceeded', 413);
                }
                const counts = await loadCountsTx(client, userId);
                const hasUserSlot = previous?.source === 'user';
                if (!hasUserSlot && counts.user >= quota.max_quests && quota.tier !== 'admin') {
                    throw new QuotaError('quest_quota_exceeded', 403);
                }
                obsoleteStoragePath = previous?.storage_path || null;

                await client.query(
                    `INSERT INTO cloud_sync_quests (
                        user_id, quest_id, title, source, size_bytes, fingerprint,
                        storage_path, market_quest_id, market_version,
                        created_at, updated_at
                     ) VALUES ($1,$2,$3,'user',$4,$5,$6,NULL,NULL, now(), now())
                     ON CONFLICT (user_id, quest_id) DO UPDATE SET
                        title           = EXCLUDED.title,
                        source          = 'user',
                        size_bytes      = EXCLUDED.size_bytes,
                        fingerprint     = EXCLUDED.fingerprint,
                        storage_path    = EXCLUDED.storage_path,
                        market_quest_id = NULL,
                        market_version  = NULL,
                        deleted_at      = NULL,
                        updated_at      = now()`,
                    [userId, questId, title, size, received.fingerprint, promo.storagePath],
                );
            });

            if (obsoleteStoragePath && obsoleteStoragePath !== promo.storagePath) {
                await deleteBlob(obsoleteStoragePath).catch(() => {});
            }
            await audit(userId, questId, 'upload', size, {
                fingerprint: received.fingerprint,
            });
            return res.json({
                questId,
                source: 'user',
                size,
                fingerprint: received.fingerprint,
            });
        } catch (e) {
            // COMMIT не прошёл (или квота): новый blob никому не принадлежит.
            // Удаляем только то, что создали мы и на что не ссылается строка.
            if (promoted?.created) {
                const refs = await pool
                    .query(
                        `SELECT 1 FROM cloud_sync_quests
                          WHERE storage_path = $1 AND deleted_at IS NULL LIMIT 1`,
                        [promoted.storagePath],
                    )
                    .catch(() => null);
                if (refs && (refs.rowCount ?? 0) === 0) {
                    await deleteBlob(promoted.storagePath).catch(() => {});
                }
            }
            if (e instanceof PayloadTooLargeError) {
                return res.status(413).json({ error: 'file_too_large' });
            }
            if (e instanceof QuotaError) {
                return res.status(e.status).json({ error: e.code });
            }
            if (e instanceof Error && e.message === 'empty body') {
                return res.status(400).json({
                    error: 'binary .mnd body required (application/octet-stream)',
                });
            }
            console.error('[cloud-sync] PUT error:', e);
            return res.status(500).json({ error: 'Internal server error' });
        }
    },
);

// ----------------------------------------------------------------------------
//  GET /cloud-sync/quests/:questId  — стрим .mnd или редирект на маркет
// ----------------------------------------------------------------------------
router.get(
    '/quests/:questId',
    limitDownload,
    async (req: AuthRequest, res: Response) => {
        try {
            const userId = req.user?.id!;
            const { questId } = req.params;

            const r = await pool.query(
                `SELECT q.source, q.size_bytes, q.fingerprint, q.storage_path,
                        q.market_quest_id,
                        mq.download_url, mq.status AS market_status
                   FROM cloud_sync_quests q
              LEFT JOIN quests mq ON mq.id = q.market_quest_id
                  WHERE q.user_id = $1 AND q.quest_id = $2 AND q.deleted_at IS NULL`,
                [userId, questId],
            );
            if ((r.rowCount ?? 0) === 0) {
                return res.status(404).json({ error: 'not found' });
            }
            const row = r.rows[0];

            if (row.source === 'market_ref') {
                if (!row.download_url || row.market_status !== 'published') {
                    return res
                        .status(410)
                        .json({ error: 'market_quest_unavailable' });
                }
                await audit(userId, questId, 'download', null, { via: 'market_ref' });
                return res.redirect(302, row.download_url);
            }

            const storagePath =
                row.storage_path || legacyStoragePath(userId, questId);
            const { stream, size } = await readBlob(storagePath);
            res.setHeader('Content-Type', 'application/octet-stream');
            res.setHeader('Content-Length', String(size));
            res.setHeader('x-fingerprint', row.fingerprint || '');
            await audit(userId, questId, 'download', size, { via: 'user' });
            stream.pipe(res);
        } catch (e: any) {
            console.error('[cloud-sync] GET error:', e);
            res.status(500).json({ error: 'Internal server error' });
        }
    },
);

// ----------------------------------------------------------------------------
//  DELETE /cloud-sync/quests/:questId  — мягкое удаление + физическое
// ----------------------------------------------------------------------------
router.delete('/quests/:questId', async (req: AuthRequest, res: Response) => {
    try {
        const userId = req.user?.id!;
        const { questId } = req.params;

        const r = await pool.query(
            `SELECT source, size_bytes, storage_path FROM cloud_sync_quests
              WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL`,
            [userId, questId],
        );
        if ((r.rowCount ?? 0) === 0) {
            return res.status(404).json({ error: 'not found' });
        }
        const row = r.rows[0];

        await pool.query(
            `UPDATE cloud_sync_quests SET deleted_at = now(), updated_at = now()
              WHERE user_id = $1 AND quest_id = $2`,
            [userId, questId],
        );
        if (row.source === 'user') {
            try {
                await deleteBlob(row.storage_path || legacyStoragePath(userId, questId));
            } catch (_) {
                // best-effort
            }
        }
        await audit(userId, questId, 'delete', Number(row.size_bytes) || 0, {
            source: row.source,
        });
        // Полностью удалим запись (history-free для простоты)
        await pool.query(
            `DELETE FROM cloud_sync_quests WHERE user_id = $1 AND quest_id = $2`,
            [userId, questId],
        );
        res.json({ ok: true });
    } catch (e: any) {
        console.error('[cloud-sync] delete:', e);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
//  Admin endpoints
// ============================================================================

async function isAdmin(userId: string): Promise<boolean> {
    const r = await pool.query(`SELECT role FROM profiles WHERE id = $1`, [userId]);
    return (r.rowCount ?? 0) > 0 && r.rows[0].role === 'admin';
}

router.post('/admin/grant', async (req: AuthRequest, res: Response) => {
    try {
        if (!(await isAdmin(req.user?.id!))) {
            return res.status(403).json({ error: 'forbidden' });
        }
        const { userId, tier, reason, expiresAt } = req.body || {};
        if (!uuidValidate(userId)) return res.status(400).json({ error: 'userId uuid' });
        if (!tier || !(tier in TIERS)) return res.status(400).json({ error: 'invalid tier' });
        await grantTier(
            userId,
            tier as TierName,
            String(reason || 'manual'),
            req.user?.id!,
            expiresAt ? new Date(expiresAt) : null,
        );
        res.json({ ok: true });
    } catch (e: any) {
        console.error('[cloud-sync] grant:', e);
        res.status(500).json({ error: 'Internal server error' });
    }
});

router.post('/admin/recompute', async (req: AuthRequest, res: Response) => {
    try {
        if (!(await isAdmin(req.user?.id!))) {
            return res.status(403).json({ error: 'forbidden' });
        }
        const { userId } = req.body || {};
        if (!uuidValidate(userId)) return res.status(400).json({ error: 'userId uuid' });
        const tier = await recomputeTier(userId);
        res.json({ ok: true, tier });
    } catch (e: any) {
        console.error('[cloud-sync] recompute:', e);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// Ручной запуск cleanup-задачи (помимо суточного cron).
router.post('/admin/cleanup', async (req: AuthRequest, res: Response) => {
    try {
        if (!(await isAdmin(req.user?.id!))) {
            return res.status(403).json({ error: 'forbidden' });
        }
        const report = await runCloudSyncCleanup();
        res.json({ ok: true, ...report });
    } catch (e: any) {
        console.error('[cloud-sync] cleanup:', e);
        res.status(500).json({ error: 'Internal server error' });
    }
});

export default router;
