import { Router, Request, Response } from 'express';
import pool from '../config/database';
import authMiddleware, { optionalAuthMiddleware } from '../middleware/auth';
import { validate as uuidValidate } from 'uuid';

const router = Router();

// =======================================================================
//  COMMUNITY: ONLINE & RECENT USERS
// =======================================================================
// last_seen_at обновляется только авторизованными запросами (middleware/auth.ts,
// не чаще раза в 2 минуты), поэтому «в сети» по нему — это 15-минутное окно:
// на проде в нём один человек вместо живой ленты. Список отдаёт активных за
// неделю, а зелёную метку «онлайн» клиент рисует сам по last_seen_at.
const ACTIVE_WINDOW_DAYS = 7;
const ONLINE_LIMIT_MAX = 50;

router.get('/online', async (req: Request, res: Response) => {
    try {
        const requested = parseInt(req.query.limit as string, 10) || 20;
        const limit = Math.min(Math.max(requested, 1), ONLINE_LIMIT_MAX);

        const result = await pool.query(
            `SELECT id, full_name, avatar_url, last_seen_at,
                    cosmetics ->> 'name_style' AS name_style, cosmetics AS cosmetics
             FROM profiles
             WHERE is_blocked = FALSE
               AND last_seen_at > NOW() - ($2 || ' days')::INTERVAL
             ORDER BY last_seen_at DESC NULLS LAST
             LIMIT $1`,
            [limit, ACTIVE_WINDOW_DAYS.toString()]
        );

        res.json(result.rows);
    } catch (err) {
        console.error('Error fetching online users:', err);
        res.status(500).json({ error: 'Server error' });
    }
});

// =======================================================================
//  COMMUNITY: TOP AUTHORS
// =======================================================================
// query param 'type' = 'followers' | 'likes' | 'quests'
router.get('/top', async (req: Request, res: Response) => {
    try {
        const limit = parseInt(req.query.limit as string, 10) || 10;
        const type = (req.query.type as string) || 'followers';

        let orderBy = '';
        let joinTables = '';
        let selectFields = '';

        if (type === 'followers') {
            orderBy = 'ORDER BY metric_count DESC NULLS LAST';
            selectFields = `(SELECT COUNT(*)::int FROM user_followers WHERE user_id = p.id) as metric_count`;
        } else if (type === 'likes') {
            orderBy = 'ORDER BY metric_count DESC NULLS LAST';
            selectFields = `(SELECT COALESCE(SUM(like_count), 0)::int FROM quests WHERE author_id = p.id) as metric_count`;
        } else if (type === 'quests') {
            orderBy = 'ORDER BY metric_count DESC NULLS LAST';
            selectFields = `(SELECT COUNT(*)::int FROM quests WHERE author_id = p.id) as metric_count`;
        } else {
            return res.status(400).json({ error: 'Invalid type parameter' });
        }

        const query = `
            SELECT p.id, p.full_name, p.avatar_url, p.streak_count, p.is_verified, p.role, p.cosmetics->>'name_style' AS name_style, p.cosmetics AS cosmetics,
                   ${selectFields}
            FROM profiles p
            WHERE true
            ${orderBy}
            LIMIT $1
        `;

        const result = await pool.query(query, [limit]);
        res.json(result.rows);
    } catch (err) {
        console.error('Error fetching top users:', err);
        res.status(500).json({ error: 'Server error' });
    }
});

// =======================================================================
//  COMMUNITY: GLOBAL FEED
// =======================================================================
// query param 'filter' = 'all' | 'following'
router.get('/feed', optionalAuthMiddleware, async (req: Request, res: Response) => {
    try {
        const limit = parseInt(req.query.limit as string, 10) || 20;
        const offset = parseInt(req.query.offset as string, 10) || 0;
        const filter = (req.query.filter as string) || 'all';
        const viewerId = (req as any).user?.id || null;

        // Топики форумов в общую ленту не поднимаем: у поста ровно одно место,
        // иначе один и тот же текст человек видит и в сообществе квеста, и в ленте.
        let whereClause = 'ap.is_active = true AND ap.forum_id IS NULL';
        const queryParams: any[] = [limit, offset];
        const viewerIndex = 3;
        queryParams.push(viewerId);

        // 1. Following Filter
        if (filter === 'following') {
            if (!viewerId) return res.status(401).json({ error: 'Unauthorized to view following feed' });
            
            whereClause += ` AND ap.author_id IN (
                SELECT user_id FROM user_followers WHERE follower_id = $${viewerIndex}
            )`;
        }

        // Guideline 1.2: посты заблокированных авторов не показываются тому,
        // кто их заблокировал. Для гостя $3 = NULL — условие ничего не режет.
        whereClause += ` AND NOT EXISTS (
            SELECT 1 FROM user_blocks ub
            WHERE ub.user_id = $${viewerIndex} AND ub.blocked_id = ap.author_id
        )`;

        const result = await pool.query(
            `SELECT 
               ap.id, ap.author_id, ap.content, ap.title, ap.created_at, ap.updated_at,
               ap.likes_count, ap.is_active, ap.interest_score, ap.views_count,
               ap.media_urls, ap.tags,
               (SELECT COUNT(*) FROM author_post_comments WHERE post_id = ap.id AND is_active = true) as comments_count,
               p.full_name as author_name,
               p.avatar_url as author_avatar_url,
               p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics,
               p.is_verified as author_is_verified,
               EXISTS (
                 SELECT 1 FROM author_post_likes apl 
                 WHERE apl.post_id = ap.id AND apl.user_id = $${viewerIndex}
               ) as is_liked_by_viewer
             FROM author_posts ap
             JOIN profiles p ON p.id = ap.author_id
             WHERE ${whereClause}
             ORDER BY (COALESCE(ap.interest_score, 50) + ap.likes_count * 15) / POWER(EXTRACT(EPOCH FROM (NOW() - ap.created_at))/3600 + 2, 1.5) DESC, ap.created_at DESC
             LIMIT $1 OFFSET $2::bigint`,
            queryParams
        );

        const posts = result.rows.map((row) => ({
            ...row,
            comments_count: parseInt(row.comments_count, 10),
            likes_count: parseInt(row.likes_count, 10),
            views_count: parseInt(row.views_count || '0', 10),
            media_urls: row.media_urls || [],
            tags: row.tags || []
        }));

        res.json(posts);
    } catch (err) {
        console.error('Error fetching global feed:', err);
        res.status(500).json({ error: 'Server error' });
    }
});

// =======================================================================
//  COMMUNITY: SINGLE POST BY ID
// =======================================================================
router.get('/post/:id', optionalAuthMiddleware, async (req: Request, res: Response) => {
    try {
        const { id } = req.params;
        if (!uuidValidate(id)) {
            return res.status(400).json({ error: 'Invalid post ID format' });
        }

        const viewerId = (req as any).user?.id || null;

        const result = await pool.query(
            `SELECT 
               ap.id, ap.author_id, ap.content, ap.created_at, ap.updated_at,
               ap.likes_count, ap.is_active, ap.interest_score, ap.views_count,
               ap.media_urls, ap.tags,
               (SELECT COUNT(*) FROM author_post_comments WHERE post_id = ap.id AND is_active = true) as comments_count,
               p.full_name as author_name,
               p.avatar_url as author_avatar_url,
               p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics,
               p.is_verified as author_is_verified,
               EXISTS (
                 SELECT 1 FROM author_post_likes apl 
                 WHERE apl.post_id = ap.id AND apl.user_id = $2
               ) as is_liked_by_viewer
             FROM author_posts ap
             JOIN profiles p ON p.id = ap.author_id
             WHERE ap.id = $1 AND ap.is_active = true
               AND NOT EXISTS (
                 SELECT 1 FROM user_blocks ub
                 WHERE ub.user_id = $2::uuid AND ub.blocked_id = ap.author_id
               )`,
            [id, viewerId]
        );

        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Post not found' });
        }

        const row = result.rows[0];
        const post = {
            ...row,
            comments_count: parseInt(row.comments_count, 10),
            likes_count: parseInt(row.likes_count, 10),
            views_count: parseInt(row.views_count || '0', 10),
            media_urls: row.media_urls || [],
            tags: row.tags || []
        };

        res.json(post);
    } catch (err) {
        console.error('Error fetching single post:', err);
        res.status(500).json({ error: 'Server error' });
    }
});

export default router;
