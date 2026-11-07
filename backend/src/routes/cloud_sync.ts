import express, { Router, Response } from 'express';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import { validate as uuidValidate } from 'uuid';

import pool from '../config/database';
import authMiddleware, { AuthRequest } from '../middleware/auth';
import {
    TIERS,
    TierName,
    recomputeTier,
    grantTier,
    buildUpgradeHints,
} from '../services/cloud_sync_tier';
import {
    writeQuestFile,
    readQuestStream,
    deleteQuestFile,
    sha256Hex,
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
router.use(express.raw({ type: 'application/octet-stream', limit: '200mb' }));
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
        res.status(500).json({ error: e?.message || 'quota error' });
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
        res.status(500).json({ error: e?.message || 'list error' });
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
        res.status(500).json({ error: e?.message || 'check error' });
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
        try {
            const userId = req.user?.id!;
            const { questId } = req.params;
            if (questId.length === 0 || questId.length > 128) {
                return res.status(400).json({ error: 'invalid quest id' });
            }

            const q = await ensureQuotaRow(userId);
            const counts = await loadCounts(userId);
            const contentType = (req.headers['content-type'] || '').toString();

            // ----- Режим B: market_ref -----
            if (contentType.includes('application/json')) {
                const { title, marketQuestId, marketVersion } = req.body || {};
                if (typeof title !== 'string' || title.trim().length === 0) {
                    return res.status(400).json({ error: 'title required' });
                }
                if (!marketQuestId || !uuidValidate(marketQuestId)) {
                    return res.status(400).json({ error: 'marketQuestId must be uuid' });
                }
                if (q.tier === 'none') {
                    return res.status(403).json({ error: 'no_quota' });
                }
                const mq = await pool.query(
                    `SELECT id, status FROM quests WHERE id = $1`,
                    [marketQuestId],
                );
                if ((mq.rowCount ?? 0) === 0 || mq.rows[0].status !== 'published') {
                    return res.status(404).json({ error: 'market quest not available' });
                }

                // Если уже была запись — апдейтим, иначе вставляем
                const existing = await pool.query(
                    `SELECT source FROM cloud_sync_quests
                      WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL`,
                    [userId, questId],
                );
                const exists = (existing.rowCount ?? 0) > 0;
                const wasUser = exists && existing.rows[0].source === 'user';
                // market_ref имеет отдельный лимит, user-слоты не трогаем
                if (!exists) {
                    if (counts.ref >= q.max_refs && q.tier !== 'admin') {
                        return res.status(403).json({ error: 'ref_quota_exceeded' });
                    }
                }

                // Если до этого был user-блоб — удалим файл
                if (wasUser) {
                    await deleteQuestFile(userId, questId);
                }

                await pool.query(
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
            }

            // ----- Режим A: upload .mnd -----
            const buf: Buffer = req.body instanceof Buffer ? req.body : null!;
            if (!buf || !Buffer.isBuffer(buf) || buf.byteLength === 0) {
                return res
                    .status(400)
                    .json({ error: 'binary .mnd body required (application/octet-stream)' });
            }
            const size = buf.byteLength;
            // Название квеста приходит в заголовке x-title. HTTP-заголовки не
            // допускают не-ASCII, поэтому клиент percent-кодирует значение и
            // ставит флаг x-title-encoding: percent. Декодируем обратно в UTF-8.
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
            const clientFingerprint = (req.headers['x-fingerprint'] || '').toString();

            if (q.tier === 'none' || q.max_bytes === 0) {
                return res.status(403).json({ error: 'no_quota' });
            }
            if (size > Number(q.max_quest_bytes)) {
                return res.status(413).json({ error: 'file_too_large' });
            }

            const existing = await pool.query(
                `SELECT source, size_bytes FROM cloud_sync_quests
                  WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL`,
                [userId, questId],
            );
            const exists = (existing.rowCount ?? 0) > 0;
            const oldSize =
                exists && existing.rows[0].source === 'user'
                    ? Number(existing.rows[0].size_bytes) || 0
                    : 0;

            // Проверка лимита квот по размеру
            const projected = (Number(q.used_bytes) || 0) - oldSize + size;
            if (projected > Number(q.max_bytes) && q.tier !== 'admin') {
                return res.status(413).json({ error: 'bytes_quota_exceeded' });
            }
            // user-слот считается ТОЛЬКО по user-квестам, market_ref не блокирует
            if (!exists && counts.user >= q.max_quests && q.tier !== 'admin') {
                return res.status(403).json({ error: 'quest_quota_exceeded' });
            }

            const computedFp = sha256Hex(buf);
            if (clientFingerprint && clientFingerprint !== computedFp) {
                // Не критично, просто залогируем
                // console.warn('Fingerprint mismatch', { clientFingerprint, computedFp });
            }

            const written = await writeQuestFile(userId, questId, buf);

            await pool.query(
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
                [userId, questId, title, size, written.fingerprint, written.path],
            );

            await audit(userId, questId, 'upload', size, { fingerprint: written.fingerprint });
            return res.json({
                questId,
                source: 'user',
                size,
                fingerprint: written.fingerprint,
            });
        } catch (e: any) {
            console.error('[cloud-sync] PUT error:', e);
            res.status(500).json({ error: e?.message || 'put error' });
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
                `SELECT q.source, q.size_bytes, q.fingerprint, q.market_quest_id,
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

            const { stream, size } = await readQuestStream(userId, questId);
            res.setHeader('Content-Type', 'application/octet-stream');
            res.setHeader('Content-Length', String(size));
            res.setHeader('x-fingerprint', row.fingerprint || '');
            await audit(userId, questId, 'download', size, { via: 'user' });
            stream.pipe(res);
        } catch (e: any) {
            console.error('[cloud-sync] GET error:', e);
            res.status(500).json({ error: e?.message || 'get error' });
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
            `SELECT source, size_bytes FROM cloud_sync_quests
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
                await deleteQuestFile(userId, questId);
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
        res.status(500).json({ error: e?.message || 'delete error' });
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
        res.status(500).json({ error: e?.message || 'grant error' });
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
        res.status(500).json({ error: e?.message || 'recompute error' });
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
        res.status(500).json({ error: e?.message || 'cleanup error' });
    }
});

export default router;
