import { Router, Response } from 'express';
import pool from '../config/database';
import authMiddleware, { AuthRequest } from '../middleware/auth';
import adminAuth from '../middleware/adminAuth';
import { validate as uuidValidate } from 'uuid';
import fs from 'fs';
import path from 'path';

const router = Router();

const PROJECT_ROOT = path.resolve(__dirname, '../../');
const QUESTS_STORAGE_DIR = path.join(PROJECT_ROOT, 'public', 'quests_files');
const ASSETS_STORAGE_DIR = path.join(PROJECT_ROOT, 'public', 'assets_files');
const MUSIC_STORAGE_DIR = path.join(PROJECT_ROOT, 'public', 'music_files');

// Файл лежит на диске как `<id>.<ext>` — см. assets.ts / music.ts.
function deleteStoredMedia(dir: string, id: string) {
    if (!fs.existsSync(dir)) return;
    const match = fs.readdirSync(dir).find((f) => f.startsWith(id + '.'));
    if (!match) return;
    try {
        fs.unlinkSync(path.join(dir, match));
        console.log(`🗑️ Deleted ${match}`);
    } catch (e) {
        console.error(`Failed to delete ${match}:`, e);
    }
}

// POST /reports - Создание жалобы
router.post('/', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;

    if (!userId) {
        return res.status(401).json({ error: "Unauthorized" });
    }

    const { reported_type, reported_id, reason, description } = req.body;

    if (!reported_type || !reported_id || !reason) {
        return res.status(400).json({ error: "Missing required fields" });
    }

    if (!['quest', 'review', 'user', 'wall_post', 'wall_comment', 'asset', 'music', 'message'].includes(reported_type)) {
        return res.status(400).json({ error: "Invalid reported_type" });
    }

    if (!uuidValidate(reported_id)) {
        return res.status(400).json({ error: "Invalid reported_id format" });
    }

    // Проверяем, что пользователь не жалуется на себя
    if (reported_type === 'user' && reported_id === userId) {
        return res.status(400).json({ error: "Cannot report yourself" });
    }

    // Проверяем, что объект существует
    try {
        if (reported_type === 'quest') {
            const questCheck = await pool.query('SELECT id FROM quests WHERE id = $1', [reported_id]);
            if (questCheck.rows.length === 0) {
                return res.status(404).json({ error: "Quest not found" });
            }
        } else if (reported_type === 'review') {
            const reviewCheck = await pool.query('SELECT id FROM reviews WHERE id = $1', [reported_id]);
            if (reviewCheck.rows.length === 0) {
                return res.status(404).json({ error: "Review not found" });
            }
        } else if (reported_type === 'user') {
            const userCheck = await pool.query('SELECT id FROM profiles WHERE id = $1', [reported_id]);
            if (userCheck.rows.length === 0) {
                return res.status(404).json({ error: "User not found" });
            }
        } else if (reported_type === 'wall_post') {
            const postCheck = await pool.query('SELECT id FROM author_posts WHERE id = $1', [reported_id]);
            if (postCheck.rows.length === 0) {
                return res.status(404).json({ error: "Post not found" });
            }
        } else if (reported_type === 'wall_comment') {
            const commentCheck = await pool.query('SELECT id FROM author_post_comments WHERE id = $1', [reported_id]);
            if (commentCheck.rows.length === 0) {
                return res.status(404).json({ error: "Comment not found" });
            }
        } else if (reported_type === 'asset') {
            const assetCheck = await pool.query('SELECT id FROM market_assets WHERE id = $1', [reported_id]);
            if (assetCheck.rows.length === 0) {
                return res.status(404).json({ error: "Asset not found" });
            }
        } else if (reported_type === 'music') {
            const trackCheck = await pool.query('SELECT id FROM music_tracks WHERE id = $1', [reported_id]);
            if (trackCheck.rows.length === 0) {
                return res.status(404).json({ error: "Track not found" });
            }
        } else if (reported_type === 'message') {
            // Жаловаться можно только на сообщение из своего диалога и только
            // на чужое: иначе через reports можно было бы дёргать чужие ЛС.
            const messageCheck = await pool.query(
                `SELECT m.id, m.sender_id
                   FROM dm_messages m
                   JOIN dm_threads t ON t.id = m.thread_id
                  WHERE m.id = $1
                    AND m.deleted_at IS NULL
                    AND (t.user_a = $2 OR t.user_b = $2)`,
                [reported_id, userId]
            );
            if (messageCheck.rows.length === 0) {
                return res.status(404).json({ error: "Message not found" });
            }
            if (messageCheck.rows[0].sender_id === userId) {
                return res.status(400).json({ error: "Cannot report your own message" });
            }
        }
    } catch (err) {
        console.error("Error checking reported object:", err);
        return res.status(500).json({ error: "Server error" });
    }

    try {
        // Проверка на повторную жалобу тоже ходит в БД: вне try её ошибка
        // уходила как необработанный rejection, и запрос висел без ответа.
        const existingReport = await pool.query(
            'SELECT id FROM reports WHERE reporter_id = $1 AND reported_type = $2 AND reported_id = $3 AND status = $4',
            [userId, reported_type, reported_id, 'pending']
        );

        if (existingReport.rows.length > 0) {
            return res.status(400).json({ error: "You have already reported this item" });
        }

        const result = await pool.query(
            `INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status)
             VALUES ($1, $2, $3, $4, $5, 'pending')
             RETURNING *`,
            [userId, reported_type, reported_id, reason, description || null]
        );

        res.status(201).json({ success: true, report: result.rows[0] });
    } catch (err) {
        console.error('[reports] failed to create report:', err);
        // (err as Error).message наружу отдавать нельзя: там попадается
        // текст с именем таблицы и колонки.
        res.status(500).json({ error: "Server error creating report" });
    }
});

// GET /reports/admin - Получение списка жалоб (только для админов)
router.get('/admin', authMiddleware, adminAuth, async (req: AuthRequest, res: Response) => {
    try {
        const { status = 'pending' } = req.query;

        let query = `
            SELECT 
                r.*,
                reporter.full_name as reporter_name,
                reporter.avatar_url as reporter_avatar,
                CASE 
                    WHEN r.reported_type = 'quest' THEN q.title
                    WHEN r.reported_type = 'review' THEN rev.text_content
                    WHEN r.reported_type = 'user' THEN reported_user.full_name
                    WHEN r.reported_type = 'wall_post' THEN ap.content
                    WHEN r.reported_type = 'wall_comment' THEN apc.content
                    WHEN r.reported_type = 'asset' THEN ma.title
                    WHEN r.reported_type = 'music' THEN mt.title
                    WHEN r.reported_type = 'message' THEN dm.body
                END as reported_item_title,
                CASE 
                    WHEN r.reported_type = 'quest' THEN q.author_id
                    WHEN r.reported_type = 'review' THEN rev.author_id
                    WHEN r.reported_type = 'user' THEN r.reported_id
                    WHEN r.reported_type = 'wall_post' THEN ap.author_id
                    WHEN r.reported_type = 'wall_comment' THEN apc.user_id
                    WHEN r.reported_type = 'asset' THEN ma.author_id
                    WHEN r.reported_type = 'music' THEN mt.author_id
                    WHEN r.reported_type = 'message' THEN dm.sender_id
                END as reported_user_id,
                CASE 
                    WHEN r.reported_type = 'quest' THEN q_author.full_name
                    WHEN r.reported_type = 'review' THEN rev_author.full_name
                    WHEN r.reported_type = 'user' THEN reported_user.full_name
                    WHEN r.reported_type = 'wall_post' THEN ap_author.full_name
                    WHEN r.reported_type = 'wall_comment' THEN apc_author.full_name
                    WHEN r.reported_type = 'asset' THEN ma_author.full_name
                    WHEN r.reported_type = 'music' THEN mt_author.full_name
                    WHEN r.reported_type = 'message' THEN dm_sender.full_name
                END as reported_user_name
            FROM reports r
            LEFT JOIN profiles reporter ON r.reporter_id = reporter.id
            LEFT JOIN quests q ON r.reported_type = 'quest' AND r.reported_id = q.id
            LEFT JOIN profiles q_author ON q.author_id = q_author.id
            LEFT JOIN reviews rev ON r.reported_type = 'review' AND r.reported_id = rev.id
            LEFT JOIN profiles rev_author ON rev.author_id = rev_author.id
            LEFT JOIN profiles reported_user ON r.reported_type = 'user' AND r.reported_id = reported_user.id
            LEFT JOIN author_posts ap ON r.reported_type = 'wall_post' AND r.reported_id = ap.id
            LEFT JOIN profiles ap_author ON ap.author_id = ap_author.id
            LEFT JOIN author_post_comments apc ON r.reported_type = 'wall_comment' AND r.reported_id = apc.id
            LEFT JOIN profiles apc_author ON apc.user_id = apc_author.id
            LEFT JOIN market_assets ma ON r.reported_type = 'asset' AND r.reported_id = ma.id
            LEFT JOIN profiles ma_author ON ma.author_id = ma_author.id
            LEFT JOIN music_tracks mt ON r.reported_type = 'music' AND r.reported_id = mt.id
            LEFT JOIN profiles mt_author ON mt.author_id = mt_author.id
            LEFT JOIN dm_messages dm ON r.reported_type = 'message' AND r.reported_id = dm.id
            LEFT JOIN profiles dm_sender ON dm.sender_id = dm_sender.id
            WHERE r.status = $1
            ORDER BY r.created_at DESC
        `;

        const result = await pool.query(query, [status]);
        res.json(result.rows);
    } catch (err) {
        console.error('[reports] failed to fetch reports:', err);
        res.status(500).json({ error: "Server error fetching reports" });
    }
});

// POST /reports/admin/:id/resolve - Обработка жалобы (только для админов)
router.post('/admin/:id/resolve', authMiddleware, adminAuth, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" });

    const { action, block_user } = req.body;
    const adminId = req.user?.id;

    if (!['delete', 'dismiss'].includes(action)) {
        return res.status(400).json({ error: "Invalid action. Must be 'delete' or 'dismiss'" });
    }

    try {
        // Получаем информацию о жалобе
        const reportResult = await pool.query(
            'SELECT * FROM reports WHERE id = $1 AND status = $2',
            [id, 'pending']
        );

        if (reportResult.rows.length === 0) {
            return res.status(404).json({ error: "Report not found or already resolved" });
        }

        const report = reportResult.rows[0];

        // Если action = 'delete', удаляем объект
        if (action === 'delete') {
            let userIdToBlock: string | null = null;

            // Сначала получаем author_id ДО удаления
            if (report.reported_type === 'quest') {
                const questResult = await pool.query('SELECT author_id FROM quests WHERE id = $1', [report.reported_id]);
                if (questResult.rows.length > 0) {
                    userIdToBlock = questResult.rows[0].author_id;
                }
                // Удаляем файл квеста
                const filePath = path.join(QUESTS_STORAGE_DIR, `${report.reported_id}.mnd`);
                if (fs.existsSync(filePath)) {
                    try {
                        fs.unlinkSync(filePath);
                        console.log(`🗑️ Deleted quest file: ${filePath}`);
                    } catch (e) {
                        console.error(`Failed to delete quest file ${filePath}:`, e);
                    }
                }
                // Удаляем квест из БД (каскадно удалятся отзывы, рейтинги и т.д.)
                await pool.query('DELETE FROM quests WHERE id = $1', [report.reported_id]);
            } else if (report.reported_type === 'review') {
                const reviewResult = await pool.query('SELECT author_id FROM reviews WHERE id = $1', [report.reported_id]);
                if (reviewResult.rows.length > 0) {
                    userIdToBlock = reviewResult.rows[0].author_id;
                }
                await pool.query('DELETE FROM reviews WHERE id = $1', [report.reported_id]);
            } else if (report.reported_type === 'user') {
                userIdToBlock = report.reported_id;
            } else if (report.reported_type === 'wall_post') {
                const postResult = await pool.query('SELECT author_id FROM author_posts WHERE id = $1', [report.reported_id]);
                if (postResult.rows.length > 0) {
                    userIdToBlock = postResult.rows[0].author_id;
                }
                await pool.query('DELETE FROM author_posts WHERE id = $1', [report.reported_id]);
            } else if (report.reported_type === 'wall_comment') {
                const commentResult = await pool.query('SELECT user_id, post_id FROM author_post_comments WHERE id = $1', [report.reported_id]);
                if (commentResult.rows.length > 0) {
                    userIdToBlock = commentResult.rows[0].user_id;
                    await pool.query('DELETE FROM author_post_comments WHERE id = $1', [report.reported_id]);
                } else {
                    await pool.query('DELETE FROM author_post_comments WHERE id = $1', [report.reported_id]);
                }
            } else if (report.reported_type === 'asset') {
                const assetResult = await pool.query('SELECT author_id FROM market_assets WHERE id = $1', [report.reported_id]);
                if (assetResult.rows.length > 0) {
                    userIdToBlock = assetResult.rows[0].author_id;
                }
                // Голоса и отзывы на ресурсе снимутся каскадом (asset_votes / asset_reviews).
                await pool.query('DELETE FROM market_assets WHERE id = $1', [report.reported_id]);
                deleteStoredMedia(ASSETS_STORAGE_DIR, report.reported_id);
            } else if (report.reported_type === 'music') {
                const trackResult = await pool.query('SELECT author_id FROM music_tracks WHERE id = $1', [report.reported_id]);
                if (trackResult.rows.length > 0) {
                    userIdToBlock = trackResult.rows[0].author_id;
                }
                await pool.query('DELETE FROM music_tracks WHERE id = $1', [report.reported_id]);
                deleteStoredMedia(MUSIC_STORAGE_DIR, report.reported_id);
            } else if (report.reported_type === 'message') {
                // Мягкое удаление: тело сообщения не оставляем даже в БД,
                // история чата уже фильтрует deleted_at.
                const messageResult = await pool.query(
                    'SELECT sender_id FROM dm_messages WHERE id = $1',
                    [report.reported_id]
                );
                if (messageResult.rows.length > 0) {
                    userIdToBlock = messageResult.rows[0].sender_id;
                }
                await pool.query(
                    "UPDATE dm_messages SET body = '', deleted_at = NOW() WHERE id = $1",
                    [report.reported_id]
                );
            }

            // Если нужно заблокировать пользователя
            if (block_user && userIdToBlock) {
                await pool.query('UPDATE profiles SET is_blocked = TRUE, token_version = token_version + 1 WHERE id = $1', [userIdToBlock]);
                console.log(`🚫 Blocked user: ${userIdToBlock}`);
            }
        }

        // Обновляем статус жалобы
        await pool.query(
            'UPDATE reports SET status = $1, resolved_by = $2, resolved_at = NOW() WHERE id = $3',
            [action === 'delete' ? 'resolved' : 'dismissed', adminId, id]
        );

        res.json({ success: true, message: `Report ${action === 'delete' ? 'resolved' : 'dismissed'}` });
    } catch (err) {
        console.error("Error resolving report:", err);
        res.status(500).json({ error: "Server error resolving report" });
    }
});

export default router;
