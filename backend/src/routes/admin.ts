import { Router, Response } from 'express';
import pool from '../config/database';
import authMiddleware, { AuthRequest } from '../middleware/auth';
import adminAuth from '../middleware/adminAuth';
import fsPromises from 'fs/promises';
import path from 'path';
import { validate as uuidValidate, v4 as uuidv4 } from 'uuid';
import { COSMETICS, grantCosmetics } from '../services/cosmetics';
import { createNotification } from '../services/notifications';
import { recomputeTier } from '../services/cloud_sync_tier';
import { getActivityOverview } from '../services/activity';

const router = Router();

const PROJECT_ROOT = path.resolve(__dirname, '../../');

const deleteFileIfExists = async (filePath: string) => {
    try {
        await fsPromises.unlink(filePath);
    } catch (e: any) {
        if (e?.code !== 'ENOENT') {
            console.error(`Failed to delete file ${filePath}:`, e);
        }
    }
};

router.use(authMiddleware);
router.use(adminAuth);

router.get('/stats', async (req: AuthRequest, res: Response) => {
    try {
        const users = await pool.query('SELECT COUNT(*) FROM profiles');
        const quests = await pool.query('SELECT COUNT(*) FROM quests');
        const pending = await pool.query("SELECT COUNT(*) FROM quests WHERE status = 'in_review'");
        const pendingMusic = await pool.query("SELECT COUNT(*) FROM music_tracks WHERE status = 'in_review'");
        const pendingAssets = await pool.query("SELECT COUNT(*) FROM market_assets WHERE status = 'in_review'");

        res.json({
            users: parseInt(users.rows[0].count),
            quests: parseInt(quests.rows[0].count),
            pending_quests: parseInt(pending.rows[0].count),
            pending_music: parseInt(pendingMusic.rows[0].count),
            pending_assets: parseInt(pendingAssets.rows[0].count),
        });
    } catch (e) {
        res.status(500).json(e);
    }
});

// GET /admin/activity?days=30 — сводка активности: заходы, действия, топ юзеров.
router.get('/activity', async (req: AuthRequest, res: Response) => {
    try {
        const overview = await getActivityOverview(req.query.days);
        res.json(overview);
    } catch (e) {
        console.error('admin activity:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

router.get('/moderation-queue', async (req: AuthRequest, res: Response) => {
    try {
        const result = await pool.query(`
            SELECT q.*, p.full_name as author_name
            FROM quests q
            JOIN profiles p ON q.author_id = p.id
            WHERE q.status = 'in_review'
            ORDER BY q.updated_at ASC
        `);
        res.json(result.rows);
    } catch (e) {
        res.status(500).json(e);
    }
});

router.get('/music-moderation-queue', async (req: AuthRequest, res: Response) => {
    try {
        const result = await pool.query(`
            SELECT m.*, p.full_name as author_name, p.is_verified as author_is_verified
            FROM music_tracks m
            LEFT JOIN profiles p ON m.author_id = p.id
            WHERE m.status = 'in_review'
            ORDER BY m.created_at ASC
        `);
        res.json(result.rows);
    } catch (e) {
        res.status(500).json(e);
    }
});

router.post('/music/:id/review', async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid ID format' });
    const { status } = req.body;
    if (!['published', 'rejected'].includes(status)) return res.status(400).json({ error: 'Invalid status' });
    try {
        if (status === 'rejected') {
            const r = await pool.query('SELECT file_url FROM music_tracks WHERE id=$1', [id]);
            if (!r.rows.length) return res.status(404).json({ error: 'Track not found' });
            await pool.query('DELETE FROM music_tracks WHERE id=$1', [id]);
            // delete file
            const files = await fsPromises.readdir(path.join(PROJECT_ROOT, 'public', 'music_files')).catch(() => [] as string[]);
            const m = files.find((f: string) => f.startsWith(id + '.'));
            if (m) await deleteFileIfExists(path.join(PROJECT_ROOT, 'public', 'music_files', m));
        } else {
            const upd = await pool.query('UPDATE music_tracks SET status=$1, updated_at=NOW() WHERE id=$2', [status, id]);
            if (upd.rowCount === 0) return res.status(404).json({ error: 'Track not found' });
        }
        res.json({ success: true });
    } catch (e) {
        res.status(500).json(e);
    }
});

router.get('/assets-moderation-queue', async (req: AuthRequest, res: Response) => {
    try {
        const result = await pool.query(`
            SELECT m.*, p.full_name as author_name, p.is_verified as author_is_verified
            FROM market_assets m
            LEFT JOIN profiles p ON m.author_id = p.id
            WHERE m.status = 'in_review'
            ORDER BY m.created_at ASC
        `);
        res.json(result.rows);
    } catch (e) {
        res.status(500).json(e);
    }
});

router.post('/assets/:id/review', async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid ID format' });
    const { status } = req.body;
    if (!['published', 'rejected'].includes(status)) return res.status(400).json({ error: 'Invalid status' });
    try {
        if (status === 'rejected') {
            const r = await pool.query('SELECT file_url FROM market_assets WHERE id=$1', [id]);
            if (!r.rows.length) return res.status(404).json({ error: 'Asset not found' });
            await pool.query('DELETE FROM market_assets WHERE id=$1', [id]);
            const files = await fsPromises.readdir(path.join(PROJECT_ROOT, 'public', 'assets_files')).catch(() => [] as string[]);
            const m = files.find((f: string) => f.startsWith(id + '.'));
            if (m) await deleteFileIfExists(path.join(PROJECT_ROOT, 'public', 'assets_files', m));
        } else {
            const upd = await pool.query('UPDATE market_assets SET status=$1, updated_at=NOW() WHERE id=$2', [status, id]);
            if (upd.rowCount === 0) return res.status(404).json({ error: 'Asset not found' });
        }
        res.json({ success: true });
    } catch (e) {
        res.status(500).json(e);
    }
});

router.post('/quest/:id/review', async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid ID format' });

    const { status, comment } = req.body;

    if (!['published', 'rejected'].includes(status)) {
        return res.status(400).json({ error: 'Invalid status' });
    }

    try {
        // Отклонение — мягкое: работа остаётся и в базе, и на диске. Статус со
        // ссылкой на причину доходит до «Моих публикаций», откуда правку можно
        // переотправить. Раньше здесь был DELETE вместе с файлом квеста.
        const updateResult = await pool.query(
            'UPDATE quests SET status = $1, moderator_comment = $2, updated_at = NOW() WHERE id = $3 RETURNING author_id, title',
            [status, comment ?? null, id]
        );

        if (updateResult.rowCount === 0) {
            return res.status(404).json({ error: 'Quest not found' });
        }

        const { author_id: authorId, title } = updateResult.rows[0];

        // Уведомления об исходе модерации клиент и пуш-шаблоны умели показывать
        // раньше, чем появился хоть один, кто их рассылает.
        if (authorId) {
            createNotification({
                userId: authorId,
                actorId: null,
                type: status === 'published' ? 'quest_approved' : 'quest_rejected',
                questId: id,
                payload: { title },
            }).catch((e) => console.error('[moderation] author notification failed:', e));

            // Tier автора считается по опубликованным квестам.
            (async () => {
                try {
                    await recomputeTier(authorId);
                } catch (e) {
                    console.error('[cloud-sync] tier recompute on moderation failed:', e);
                }
            })();
        }

        res.json({ success: true });
    } catch (e) {
        res.status(500).json(e);
    }
});

router.get('/blocked-users', async (req: AuthRequest, res: Response) => {
    try {
        const result = await pool.query(`
            SELECT id, full_name, email, created_at, is_blocked
            FROM profiles
            WHERE is_blocked = TRUE
            ORDER BY created_at DESC
        `);
        res.json(result.rows);
    } catch (e) {
        console.error('Error fetching blocked users:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

router.post('/users/:id/unblock', async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid ID format' });

    try {
        const result = await pool.query('UPDATE profiles SET is_blocked = FALSE WHERE id = $1 RETURNING *', [id]);

        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'User not found' });
        }

        res.json({ success: true, user: result.rows[0] });
    } catch (e) {
        console.error('Error unblocking user:', e);
        res.status(500).json({ error: 'Server error' });
    }
});


// =======================================================================
//  Оформление профиля: выдача, отзыв, промокоды на косметику
//
//  Сценарий реальный: победа в конкурсе -> выдаём предмет конкретным
//  аккаунтам (grant) либо поднимаем код, который победители активируют сами
//  (codes). Права бессрочные, если не указан `days`.
// =======================================================================

const MAX_GRANT_USERS = 500;
const MAX_GRANT_ITEMS = 100;

// GET /admin/cosmetics/catalog — что вообще можно выдать (по каталогу сборки)
router.get('/cosmetics/catalog', async (_req: AuthRequest, res: Response) => {
    res.json({ items: Array.from(COSMETICS.values()) });
});

// GET /admin/cosmetics/grants — все выдачи (для списка в админке)
router.get('/cosmetics/grants', async (req: AuthRequest, res: Response) => {
    const userId = typeof req.query.user_id === 'string' ? req.query.user_id : null;
    if (userId && !uuidValidate(userId)) {
        return res.status(400).json({ error: 'Invalid user_id' });
    }
    try {
        const result = await pool.query(
            `SELECT uc.user_id, p.full_name, uc.cosmetic_id, uc.slot, uc.tier,
                    uc.source, uc.reason, uc.granted_at, uc.expires_at
               FROM user_cosmetics uc
               JOIN profiles p ON p.id = uc.user_id
              WHERE ($1::uuid IS NULL OR uc.user_id = $1)
              ORDER BY uc.granted_at DESC
              LIMIT 500`,
            [userId],
        );
        res.json({ grants: result.rows });
    } catch (e) {
        console.error('admin cosmetics grants:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// POST /admin/cosmetics/grant  { user_ids|user_id, cosmetic_ids, days?, reason? }
router.post('/cosmetics/grant', async (req: AuthRequest, res: Response) => {
    const body = req.body || {};
    const userIds: string[] = Array.isArray(body.user_ids)
        ? body.user_ids.map(String)
        : (body.user_id ? [String(body.user_id)] : []);
    const cosmeticIds: string[] = Array.isArray(body.cosmetic_ids)
        ? body.cosmetic_ids.map(String)
        : [];

    if (userIds.length === 0 || userIds.length > MAX_GRANT_USERS) {
        return res.status(400).json({ error: `Нужен список user_ids (1..${MAX_GRANT_USERS})` });
    }
    if (cosmeticIds.length === 0 || cosmeticIds.length > MAX_GRANT_ITEMS) {
        return res.status(400).json({ error: `Нужен список cosmetic_ids (1..${MAX_GRANT_ITEMS})` });
    }
    const unknown = cosmeticIds.filter((id) => !COSMETICS.has(id));
    if (unknown.length > 0) {
        return res.status(400).json({ error: `Неизвестные id оформления: ${unknown.join(', ')}` });
    }
    const days = body.days === undefined || body.days === null ? null : Number(body.days);
    if (days !== null && (!Number.isFinite(days) || days <= 0 || days > 3650)) {
        return res.status(400).json({ error: 'days должен быть числом 1..3650 или null' });
    }

    try {
        const grantedPerUser: Record<string, string[]> = {};
        for (const userId of userIds) {
            if (!uuidValidate(userId)) {
                return res.status(400).json({ error: `Неверный id пользователя: ${userId}` });
            }
            const result = await grantCosmetics(userId, cosmeticIds, {
                days,
                source: 'admin_grant',
                reason: typeof body.reason === 'string' ? body.reason.slice(0, 300) : undefined,
                grantedBy: req.user?.id ?? null,
            });
            grantedPerUser[userId] = result.granted;
        }
        res.json({ success: true, granted: grantedPerUser });
    } catch (e) {
        console.error('admin cosmetics grant:', e);
        res.status(500).json({ error: 'Server error granting cosmetics' });
    }
});

// GET /admin/cosmetics/users?q= — найти получателя по имени, чтобы не
// светить в админке лишние поля профиля (email, телефон и т. п.).
router.get('/cosmetics/users', async (req: AuthRequest, res: Response) => {
    const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
    if (q.length < 2) {
        return res.status(400).json({ error: 'Нужно не меньше 2 символов' });
    }
    try {
        const result = await pool.query(
            `SELECT id, full_name, avatar_url
               FROM profiles
              WHERE full_name ILIKE $1
                 OR id::text = $2
              ORDER BY full_name
              LIMIT 25`,
            [`%${q}%`, q],
        );
        res.json({ users: result.rows });
    } catch (e) {
        console.error('admin cosmetics users:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// POST /admin/cosmetics/revoke  { user_id, cosmetic_ids }
router.post('/cosmetics/revoke', async (req: AuthRequest, res: Response) => {
    const body = req.body || {};
    const userId = String(body.user_id || '');
    const cosmeticIds: string[] = Array.isArray(body.cosmetic_ids) ? body.cosmetic_ids.map(String) : [];
    if (!uuidValidate(userId) || cosmeticIds.length === 0) {
        return res.status(400).json({ error: 'Нужны user_id и cosmetic_ids' });
    }

    try {
        const result = await pool.query(
            'DELETE FROM user_cosmetics WHERE user_id = $1 AND cosmetic_id = ANY($2::text[]) RETURNING cosmetic_id',
            [userId, cosmeticIds],
        );
        // Снимаем только отозванные предметы: остальное человек надел честно,
        // и терять его оформление из-за одного отзыва незачем.
        await pool.query(
            `UPDATE profiles
                SET cosmetics = (
                        SELECT jsonb_object_agg(key, value)
                          FROM jsonb_each_text(cosmetics) AS e
                         WHERE NOT (e.value = ANY($2::text[]))
                    )
              WHERE id = $1`,
            [userId, cosmeticIds],
        );
        res.json({ success: true, revoked: result.rows.map((r) => r.cosmetic_id) });
    } catch (e) {
        console.error('admin cosmetics revoke:', e);
        res.status(500).json({ error: 'Server error revoking cosmetics' });
    }
});

// GET /admin/cosmetics/codes — коды с оформлением
router.get('/cosmetics/codes', async (_req: AuthRequest, res: Response) => {
    try {
        const result = await pool.query(
            `SELECT code, cosmetic_ids, days_duration, max_uses, current_uses, is_active, created_at
               FROM promo_codes
              WHERE cardinality(cosmetic_ids) > 0
              ORDER BY created_at DESC
              LIMIT 200`,
        );
        res.json({ codes: result.rows });
    } catch (e) {
        console.error('admin cosmetics codes:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// POST /admin/cosmetics/codes  { cosmetic_ids, code?, title?, max_uses?, days? }
router.post('/cosmetics/codes', async (req: AuthRequest, res: Response) => {
    const body = req.body || {};
    const cosmeticIds: string[] = Array.isArray(body.cosmetic_ids) ? body.cosmetic_ids.map(String) : [];
    if (cosmeticIds.length === 0 || cosmeticIds.length > MAX_GRANT_ITEMS) {
        return res.status(400).json({ error: `Нужен список cosmetic_ids (1..${MAX_GRANT_ITEMS})` });
    }
    const unknown = cosmeticIds.filter((id) => !COSMETICS.has(id));
    if (unknown.length > 0) {
        return res.status(400).json({ error: `Неизвестные id оформления: ${unknown.join(', ')}` });
    }

    const rawCode = typeof body.code === 'string' ? body.code.trim().toUpperCase() : '';
    const code = rawCode.length > 0 && rawCode.length <= 40
        ? rawCode
        : `MND-${uuidv4().slice(0, 8).toUpperCase()}`;
    const maxUses = Number.isFinite(Number(body.max_uses)) ? Math.max(1, Number(body.max_uses)) : 100;
    const days = Number.isFinite(Number(body.days)) ? Math.max(0, Number(body.days)) : 0;

    try {
        await pool.query(
            `INSERT INTO promo_codes (code, days_duration, max_uses, cosmetic_ids)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (code) DO UPDATE
               SET cosmetic_ids = EXCLUDED.cosmetic_ids,
                   days_duration = EXCLUDED.days_duration,
                   max_uses = EXCLUDED.max_uses,
                   is_active = TRUE`,
            [code, days, maxUses, cosmeticIds],
        );
        res.json({ success: true, code, cosmetic_ids: cosmeticIds, max_uses: maxUses, days_duration: days });
    } catch (e) {
        console.error('admin cosmetics code create:', e);
        res.status(500).json({ error: 'Server error creating code' });
    }
});

export default router;
