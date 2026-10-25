import { Router, Request, Response, NextFunction } from 'express';
import pool from '../config/database';
import authMiddleware, { optionalAuthMiddleware, AuthRequest } from '../middleware/auth';
import { moderateWallPost } from '../services/moderation';
import { getKarmaAndLimits } from '../services/gating';
import { createNotification, createBulkNotifications } from '../services/notifications';
import { validate as uuidValidate, v4 as uuidv4 } from 'uuid';
import multer from 'multer';
import os from 'os';
import path from 'path';
import fs from 'fs';
import { uploadImage, UnsupportedImageError, acceptsImagePartMime } from '../services/image_host';
import { getIO } from '../services/socket';

// Фото публикации — те же картинки, что и аватар, и тот же временный каталог,
// что у квестов/музыки/ассетов. Раньше multer писал в `temp_uploads/` в cwd без
// лимита размера и без fileFilter, а файл никто не удалял: один пост мог
// принести гигабайт мусора на диске, и диск кончался.
const TEMP_DIR = path.join(os.tmpdir(), 'meander_uploads');
const POST_IMAGE_MAX_BYTES = 10 * 1024 * 1024;
const POST_IMAGE_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.webp', '.gif']);

fs.mkdirSync(TEMP_DIR, { recursive: true });

const upload = multer({
    storage: multer.diskStorage({
        destination: (req, file, cb) => cb(null, TEMP_DIR),
        filename: (req, file, cb) => {
            const ext = path.extname(file.originalname || '').toLowerCase();
            cb(null, `mnd-post-${uuidv4()}${POST_IMAGE_EXTENSIONS.has(ext) ? ext : '.jpg'}`);
        },
    }),
    fileFilter: (req, file, cb) => {
        const ext = path.extname(file.originalname || '').toLowerCase();
        if (!POST_IMAGE_EXTENSIONS.has(ext) || !acceptsImagePartMime(file.mimetype)) {
            return cb(new Error('Можно прикрепить jpg, png, webp или gif'));
        }
        cb(null, true);
    },
    limits: { fileSize: POST_IMAGE_MAX_BYTES, files: 1 },
});
const router = Router();

// ============================================================
// HELPERS
// ============================================================

// Пороги активности («сколько можно постить и комментить») переехали в
// services/gating.ts: форумы считают их по той же формуле, и два разных
// списка чисел неизбежно разошлись бы.

// ============================================================
// MEDIA UPLOAD
// ============================================================

// Ошибку лимита multer выбрасывает до обработчика, поэтому переводим её в
// понятный ответ: иначе клиент видел «Сервер не принял фото (413)».
const uploadPostImage = (req: Request, res: Response, next: NextFunction) => {
  upload.single('file')(req, res, (err: any) => {
    if (!err) return next();
    if (err.code === 'LIMIT_FILE_SIZE') {
      return res.status(413).json({ error: `Фото не больше ${POST_IMAGE_MAX_BYTES / 1024 / 1024} МБ` });
    }
    return res.status(400).json({ error: err.message || 'Не удалось загрузить фото' });
  });
};

router.post('/upload-media', authMiddleware, uploadPostImage, async (req: Request, res: Response) => {
  const file = req.file;
  if (!file) return res.status(400).json({ error: 'Файл не дошёл до сервера' });

  try {
    // Upload to local image host and get URL
    const url = await uploadImage(file.path);
    res.json({ url });
  } catch (err) {
    console.error('Media upload error:', err);
    // Файл не картинка по содержимому — это отказ по правилу, а не авария:
    // человек должен получить причину и понять, что выбрать другой файл.
    if (err instanceof UnsupportedImageError) {
      return res.status(415).json({ error: 'Это не похоже на картинку — поддерживаются jpg, png, webp и gif' });
    }
    res.status(500).json({ error: 'Не удалось сохранить фото' });
  } finally {
    // uploadImage копирует файл в public/uploads, временная копия остаётся
    // одна на каждое фото — без unlink каталог рос до конца диска.
    fs.unlink(file.path, () => {});
  }
});

// ============================================================
// POSTS
// ============================================================

// POST /api/author-walls/posts/:postId/view
router.post('/posts/:postId/view', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { postId } = req.params;
    const userId = (req as AuthRequest).user!.id;

    if (!uuidValidate(postId)) return res.status(400).json({ error: 'Invalid post ID' });

    // Try to insert a unique view record
    const result = await pool.query(
      `INSERT INTO author_post_views (post_id, user_id) 
       VALUES ($1, $2) 
       ON CONFLICT (post_id, user_id) DO NOTHING 
       RETURNING *`,
      [postId, userId]
    );

    // If inserted (first time viewing), increment the counter
    if (result.rows.length > 0) {
      await pool.query('UPDATE author_posts SET views_count = views_count + 1 WHERE id = $1', [postId]);
      res.json({ success: true, new_view: true });
    } else {
      res.json({ success: true, new_view: false });
    }
  } catch (err) {
    console.error('View post error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/author-walls/:authorId/posts — лента постов
router.get('/:authorId/posts', optionalAuthMiddleware, async (req: Request, res: Response) => {
  try {
    const { authorId } = req.params;
    if (!uuidValidate(authorId)) return res.status(400).json({ error: 'Invalid author ID format' });
    const limit = parseInt(req.query.limit as string, 10) || 20;
    const offset = parseInt(req.query.offset as string, 10) || 0;
    const viewerId = (req as AuthRequest).user?.id || (req.query.viewer_id as string) || null;

    // Guideline 1.2: стена заблокированного автора для блокирующего пуста.
    if ((req as AuthRequest).user?.id) {
      const blocked = await pool.query(
        'SELECT 1 FROM user_blocks WHERE user_id = $1 AND blocked_id = $2',
        [(req as AuthRequest).user!.id, authorId]
      );
      if (blocked.rows.length > 0) return res.json([]);
    }

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
           WHERE apl.post_id = ap.id AND apl.user_id = $3
         ) as is_liked_by_viewer
       FROM author_posts ap
       JOIN profiles p ON p.id = ap.author_id
       WHERE ap.author_id = $1 AND ap.is_active = true
       ORDER BY ap.created_at DESC
       LIMIT $2 OFFSET $4`,
      [authorId, limit, viewerId, offset]
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
    console.error('Author wall posts error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/author-walls/:authorId/posts — создать пост (только автор)
router.post('/:authorId/posts', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { authorId } = req.params;
    if (!uuidValidate(authorId)) return res.status(400).json({ error: 'Invalid author ID format' });

    const userId = (req as AuthRequest).user!.id;

    if (authorId !== userId) {
      return res.status(403).json({ error: 'Only the author can post on their wall' });
    }

    const { content, media_urls } = req.body;
    if (!content || content.trim().length === 0) {
      return res.status(400).json({ error: 'Content is required' });
    }

    const limits = await getKarmaAndLimits(userId);

    if (limits.postCooldownMin > 0) {
      const cooldownCheck = await pool.query(
        `SELECT id FROM author_posts 
         WHERE author_id = $1 AND created_at > NOW() - ($2 || ' minutes')::INTERVAL 
         LIMIT 1`,
        [authorId, String(limits.postCooldownMin)]
      );

      if (cooldownCheck.rows.length > 0) {
        return res.status(429).json({ 
          error: `Пожалуйста, подождите ${limits.postCooldownMin} минут перед публикацией следующего поста.` 
        });
      }
    }

    const tags = Array.from(new Set((content.match(/#[a-zA-Zа-яА-ЯёЁ0-9_]+/g) || []).map((t: string) => t.toLowerCase().substring(1))));
    let mediaUrls = Array.isArray(media_urls) ? media_urls : [];
    
    // Также извлекаем картинки из маркдауна для ИИ-модерации
    const markdownImages = Array.from(content.matchAll(/!\[.*?\]\((https?:\/\/.*?)\)/g)).map((m: any) => m[1]);
    const allMediaForModeration = Array.from(new Set([...mediaUrls, ...markdownImages]));

    const result = await pool.query(
      `INSERT INTO author_posts (author_id, content, media_urls, tags) 
       VALUES ($1, $2, $3, $4) 
       RETURNING *`,
      [authorId, content.trim(), JSON.stringify(mediaUrls), tags]
    );

    const post = result.rows[0];
    res.status(201).json(post);

    // Модерация поста по правилам — в фоне, пост опубликован сразу
    moderateWallPost(content, allMediaForModeration).then(async (modResult) => {
      if (modResult.needsReview) {
        try {
          await pool.query(
            `INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status) 
             VALUES ($1, 'wall_post', $2, 'AUTO_FLAGGED_FOR_REVIEW', $3, 'pending')`,
            [authorId, post.id, `Пост на стене помечен правилами на ручную проверку: ${modResult.reason}`]
          );
        } catch (e) { console.error('Failed to create report:', e); }
      }

      if (!modResult.approved) {
        await pool.query('UPDATE author_posts SET is_active = false WHERE id = $1', [post.id]);
      } else {
        // Устанавливаем interest_score
        await pool.query('UPDATE author_posts SET interest_score = $1 WHERE id = $2', [modResult.interest_score, post.id]);

        // Уведомляем подписчиков, если пост прошел модерацию
        try {
          // Получаем полные данные поста для отправки в сокет
          const updatedPostRes = await pool.query(`
            SELECT 
                p.id, p.content, p.created_at, p.likes_count,
                p.views_count, p.media_urls, p.tags, p.interest_score,
                (SELECT COUNT(*) FROM author_post_comments WHERE post_id = p.id AND is_active = true) as comments_count,
                pr.full_name as author_name, pr.avatar_url as author_avatar_url, p.author_id,
                pr.cosmetics->>'name_style' as author_name_style, pr.cosmetics AS author_cosmetics,
                pr.is_verified as author_is_verified,
                EXISTS(SELECT 1 FROM user_followers WHERE follower_id = $1 AND user_id = p.author_id) as is_following,
                false as is_liked
            FROM author_posts p
            JOIN profiles pr ON p.author_id = pr.id
            WHERE p.id = $2
          `, [authorId, post.id]);

          if (updatedPostRes.rows.length > 0) {
            getIO().emit('new_wall_post', updatedPostRes.rows[0]);
          }
        } catch (e) {
          console.error("Failed to broadcast new post via socket:", e);
        }

        try {
          const followersResult = await pool.query(
            'SELECT follower_id FROM user_followers WHERE user_id = $1',
            [authorId]
          );
          if (followersResult.rows.length > 0) {
            const followerIds = followersResult.rows.map(r => r.follower_id);
            await createBulkNotifications({
              userIds: followerIds,
              actorId: authorId,
              type: 'wall_post_new',
              payload: { postId: post.id },
            });
          }
        } catch (e) {
          console.error("Failed to notify followers about new post:", e);
        }
      }
    }).catch(e => {
      console.error("Background wall post moderation failed:", e);
    });
  } catch (err) {
    console.error('Create author post error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// PUT /api/author-walls/posts/:postId — редактировать пост
router.put('/posts/:postId', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { postId } = req.params;
    const userId = (req as AuthRequest).user!.id;
    const { content, media_urls } = req.body;

    if (!content || content.trim().length === 0) {
      return res.status(400).json({ error: 'Content is required' });
    }

    const post = await pool.query('SELECT author_id FROM author_posts WHERE id = $1', [postId]);
    if (post.rows.length === 0) {
      return res.status(404).json({ error: 'Post not found' });
    }

    if (post.rows[0].author_id !== userId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const tags = Array.from(new Set((content.match(/#[a-zA-Zа-яА-ЯёЁ0-9_]+/g) || []).map((t: string) => t.toLowerCase().substring(1))));
    const mediaUrls = Array.isArray(media_urls) ? media_urls : [];

    const markdownImages = Array.from(content.matchAll(/!\[.*?\]\((https?:\/\/.*?)\)/g)).map((m: any) => m[1]);
    const allMediaForModeration = Array.from(new Set([...mediaUrls, ...markdownImages]));

    const result = await pool.query(
      `UPDATE author_posts 
       SET content = $1, media_urls = $2, tags = $3
       WHERE id = $4
       RETURNING *`,
      [content.trim(), JSON.stringify(mediaUrls), tags, postId]
    );

    const updatedPost = result.rows[0];
    res.json(updatedPost);

    // Модерация edited-поста по правилам в фоне
    moderateWallPost(content, allMediaForModeration).then(async (modResult) => {
      if (modResult.needsReview) {
        try {
          await pool.query(
            `INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status) 
             VALUES ($1, 'wall_post', $2, 'AUTO_FLAGGED_FOR_REVIEW', $3, 'pending')`,
            [userId, postId, `Отредактированный пост помечен правилами на ручную проверку: ${modResult.reason}`]
          );
        } catch (e) { console.error('Failed to create report:', e); }
      }

      if (!modResult.approved) {
        await pool.query('UPDATE author_posts SET is_active = false WHERE id = $1', [postId]);
      } else {
        await pool.query('UPDATE author_posts SET interest_score = $1 WHERE id = $2', [modResult.interest_score, postId]);
      }
    }).catch(console.error);
  } catch (err) {
    console.error('Edit author post error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// DELETE /api/author-walls/posts/:postId — удалить пост
router.delete('/posts/:postId', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { postId } = req.params;
    const userId = (req as AuthRequest).user!.id;

    const post = await pool.query('SELECT author_id FROM author_posts WHERE id = $1', [postId]);
    if (post.rows.length === 0) {
      return res.status(404).json({ error: 'Post not found' });
    }

    if (post.rows[0].author_id !== userId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    await pool.query('UPDATE author_posts SET is_active = false WHERE id = $1', [postId]);
    res.json({ success: true });
  } catch (err) {
    console.error('Delete author post error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/author-walls/posts/:postId/like — лайк/анлайк
router.post('/posts/:postId/like', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { postId } = req.params;
    const userId = (req as AuthRequest).user!.id;

    const existing = await pool.query(
      'SELECT 1 FROM author_post_likes WHERE post_id = $1 AND user_id = $2',
      [postId, userId]
    );

    if (existing.rows.length > 0) {
      try {
        await pool.query(
          'DELETE FROM author_post_likes WHERE post_id = $1 AND user_id = $2',
          [postId, userId]
        );
        const updateRes = await pool.query(
          'UPDATE author_posts SET likes_count = GREATEST(likes_count - 1, 0) WHERE id = $1 ' +
          'RETURNING likes_count, (SELECT COUNT(*) FROM author_post_comments WHERE post_id = $1 AND is_active = true) as comments_count',
          [postId]
        );
        if (updateRes.rows.length > 0) {
          getIO().emit('post_stats_updated', {
            postId,
            likes_count: updateRes.rows[0].likes_count,
            comments_count: parseInt(updateRes.rows[0].comments_count, 10)
          });
        }
      } catch (e) {
        console.error('Unlike author post error:', e);
      }
      res.json({ liked: false });
    } else {
      try {
        await pool.query(
          'INSERT INTO author_post_likes (post_id, user_id) VALUES ($1, $2)',
          [postId, userId]
        );
        const updateRes = await pool.query(
          'UPDATE author_posts SET likes_count = likes_count + 1 WHERE id = $1 ' +
          'RETURNING likes_count, (SELECT COUNT(*) FROM author_post_comments WHERE post_id = $1 AND is_active = true) as comments_count',
          [postId]
        );
        if (updateRes.rows.length > 0) {
          getIO().emit('post_stats_updated', {
            postId,
            likes_count: updateRes.rows[0].likes_count,
            comments_count: parseInt(updateRes.rows[0].comments_count, 10)
          });
        }
        
        // Notify author
        try {
          const postAuthorResult = await pool.query('SELECT author_id FROM author_posts WHERE id = $1', [postId]);
          const postAuthorId = postAuthorResult.rows[0]?.author_id;
          if (postAuthorId && postAuthorId !== userId) {
            await createNotification({
              userId: postAuthorId,
              actorId: userId,
              type: 'wall_post_like',
              payload: { postId },
            });
          }
        } catch (e) {
          console.error("Failed to notify author about post like:", e);
        }
      } catch (e) {
        console.error('Like author post error:', e);
      }
      res.json({ liked: true });
    }
  } catch (err) {
    console.error('Like author post error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============================================================
// COMMENTS
// ============================================================

// GET /api/author-walls/posts/:postId
router.get('/posts/:postId', async (req: Request, res: Response) => {
  try {
    const { postId } = req.params;
    const viewerId = req.query.viewer_id as string | undefined;

    const result = await pool.query(
      `SELECT 
          p.id, p.author_id, p.content, p.title, p.forum_id, p.created_at, p.updated_at,
          p.likes_count, p.is_active, p.interest_score, p.views_count,
          p.media_urls, p.tags,
          (SELECT COUNT(*) FROM author_post_comments WHERE post_id = p.id AND is_active = true) as comments_count,
          pr.full_name as author_name, pr.avatar_url as author_avatar_url, p.author_id,
          pr.cosmetics->>'name_style' as author_name_style, pr.cosmetics AS author_cosmetics,
          pr.is_verified as author_is_verified,
          $2::uuid IS NOT NULL AND EXISTS(SELECT 1 FROM user_followers WHERE follower_id = $2 AND user_id = p.author_id) as is_following,
          $2::uuid IS NOT NULL AND EXISTS(SELECT 1 FROM author_post_likes WHERE post_id = p.id AND user_id = $2) as is_liked
       FROM author_posts p
       JOIN profiles pr ON pr.id = p.author_id
       WHERE p.id = $1 AND p.is_active = true`,
      [postId, viewerId || null]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Post not found' });
    }

    const row = result.rows[0];
    res.json({
      ...row,
      comments_count: parseInt(row.comments_count, 10),
      likes_count: parseInt(row.likes_count, 10),
      views_count: parseInt(row.views_count || '0', 10),
      media_urls: row.media_urls || [],
      tags: row.tags || []
    });
  } catch (err) {
    console.error('Get post error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/author-walls/posts/:postId/comments
router.get('/posts/:postId/comments', async (req: Request, res: Response) => {
  try {
    const { postId } = req.params;
    const viewerId = req.query.viewer_id as string | undefined;

    let result;
    try {
        result = await pool.query(
          `SELECT 
             apc.*, 
             p.full_name as user_name,
             p.avatar_url as user_avatar_url,
             p.cosmetics->>'name_style' as user_name_style, p.cosmetics AS user_cosmetics,
             EXISTS (
               SELECT 1 FROM author_post_comment_likes apcl 
               WHERE apcl.comment_id = apc.id AND apcl.user_id = $2
             ) as is_liked_by_viewer
           FROM author_post_comments apc
           JOIN profiles p ON p.id = apc.user_id
           WHERE apc.post_id = $1 AND apc.is_active = true
           ORDER BY apc.created_at ASC`,
          [postId, viewerId || null]
        );
    } catch (e: any) {
        if (e.code === '42703') {
            result = await pool.query(
              `SELECT 
                 apc.id, apc.post_id, apc.user_id, apc.content, apc.created_at, apc.likes_count,
                 null as parent_id,
                 p.full_name as user_name,
                 p.avatar_url as user_avatar_url,
                 p.cosmetics->>'name_style' as user_name_style, p.cosmetics AS user_cosmetics,
                 EXISTS (
                   SELECT 1 FROM author_post_comment_likes apcl 
                   WHERE apcl.comment_id = apc.id AND apcl.user_id = $2
                 ) as is_liked_by_viewer
               FROM author_post_comments apc
               JOIN profiles p ON p.id = apc.user_id
               WHERE apc.post_id = $1 AND apc.is_active = true
               ORDER BY apc.created_at ASC`,
              [postId, viewerId || null]
            );
        } else {
            throw e;
        }
    }

    res.json(result.rows);
  } catch (err) {
    console.error('Get post comments error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/author-walls/posts/:postId/comments
router.post('/posts/:postId/comments', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { postId } = req.params;
    const userId = (req as AuthRequest).user!.id;
    const { content, parentId } = req.body;

    if (!content || content.trim().length === 0) {
      return res.status(400).json({ error: 'Content is required' });
    }

    const limits = await getKarmaAndLimits(userId);

    if (limits.commentCooldownSec > 0) {
      const cooldownCheck = await pool.query(
        `SELECT id FROM author_post_comments 
         WHERE user_id = $1 AND created_at > NOW() - ($2 || ' seconds')::INTERVAL 
         LIMIT 1`,
        [userId, String(limits.commentCooldownSec)]
      );

      if (cooldownCheck.rows.length > 0) {
        return res.status(429).json({ 
          error: `Вы комментируете слишком часто. Подождите ${limits.commentCooldownSec} сек.` 
        });
      }
    }

    let result;
    try {
        result = await pool.query(
          `INSERT INTO author_post_comments (post_id, user_id, content, parent_id) 
           VALUES ($1, $2, $3, $4) 
           RETURNING *`,
          [postId, userId, content.trim(), parentId || null]
        );
    } catch (dbError: any) {
        if (dbError.code === '42703') { // column "parent_id" does not exist
            result = await pool.query(
              `INSERT INTO author_post_comments (post_id, user_id, content) 
               VALUES ($1, $2, $3) 
               RETURNING *`,
              [postId, userId, content.trim()]
            );
        } else {
            throw dbError;
        }
    }

    const comment = result.rows[0];

    // Notify author of the post or parent comment
    try {
      if (parentId) {
        const parentCommentResult = await pool.query('SELECT user_id FROM author_post_comments WHERE id = $1', [parentId]);
        const parentCommentAuthorId = parentCommentResult.rows[0]?.user_id;
        if (parentCommentAuthorId && parentCommentAuthorId !== userId) {
          await createNotification({
            userId: parentCommentAuthorId,
            actorId: userId,
            type: 'wall_post_comment_reply',
            payload: { postId, commentId: comment.id, parentId },
          });
        }
      } else {
        const postAuthorResult = await pool.query('SELECT author_id FROM author_posts WHERE id = $1', [postId]);
        const postAuthorId = postAuthorResult.rows[0]?.author_id;
        if (postAuthorId && postAuthorId !== userId) {
          await createNotification({
            userId: postAuthorId,
            actorId: userId,
            type: 'wall_post_comment',
            payload: { postId, commentId: comment.id },
          });
        }
      }
    } catch (e) {
      console.error("Failed to notify author about comment:", e);
    }

    res.status(201).json(comment);

    try {
      getIO().to(`post_${postId}`).emit('new_comment', comment);
      
      const countRes = await pool.query(
        'SELECT COUNT(*) as cnt FROM author_post_comments WHERE post_id = $1 AND is_active = true',
        [postId]
      );
      const likesRes = await pool.query(
        'SELECT likes_count FROM author_posts WHERE id = $1', [postId]
      );
      if (likesRes.rows.length > 0) {
        getIO().emit('post_stats_updated', {
          postId,
          likes_count: parseInt(likesRes.rows[0].likes_count, 10),
          comments_count: parseInt(countRes.rows[0].cnt, 10)
        });
      }
    } catch (e) {
      console.error('Socket emit error:', e);
    }

  } catch (err) {
    console.error('Create comment error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// PUT /api/author-walls/comments/:commentId — редактировать комментарий
router.put('/comments/:commentId', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { commentId } = req.params;
    const userId = (req as AuthRequest).user!.id;
    const { content } = req.body;

    if (!content || content.trim().length === 0) {
      return res.status(400).json({ error: 'Content is required' });
    }

    const comment = await pool.query('SELECT user_id FROM author_post_comments WHERE id = $1', [commentId]);
    if (comment.rows.length === 0) {
      return res.status(404).json({ error: 'Comment not found' });
    }

    if (comment.rows[0].user_id !== userId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const result = await pool.query(
      `UPDATE author_post_comments 
       SET content = $1
       WHERE id = $2
       RETURNING *`,
      [content.trim(), commentId]
    );

    res.json(result.rows[0]);

  } catch (err) {
    console.error('Edit comment error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// DELETE /api/author-walls/comments/:commentId — удалить комментарий
router.delete('/comments/:commentId', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { commentId } = req.params;
    const userId = (req as AuthRequest).user!.id;

    const comment = await pool.query('SELECT user_id, post_id FROM author_post_comments WHERE id = $1', [commentId]);
    if (comment.rows.length === 0) {
      return res.status(404).json({ error: 'Comment not found' });
    }

    if (comment.rows[0].user_id !== userId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const postId = comment.rows[0].post_id;

    await pool.query('UPDATE author_post_comments SET is_active = false WHERE id = $1', [commentId]);
    const countRes = await pool.query(
      'SELECT COUNT(*) as cnt FROM author_post_comments WHERE post_id = $1 AND is_active = true',
      [postId]
    );
    const likesRes = await pool.query(
      'SELECT likes_count FROM author_posts WHERE id = $1', [postId]
    );
    if (likesRes.rows.length > 0) {
      try {
        getIO().emit('post_stats_updated', {
          postId,
          likes_count: parseInt(likesRes.rows[0].likes_count, 10),
          comments_count: parseInt(countRes.rows[0].cnt, 10)
        });
      } catch (e) { console.error('Socket emit error:', e); }
    }

    res.json({ success: true });
  } catch (err) {
    console.error('Delete comment error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/author-walls/comments/:commentId/like
router.post('/comments/:commentId/like', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { commentId } = req.params;
    const userId = (req as AuthRequest).user!.id;

    const existing = await pool.query(
      'SELECT 1 FROM author_post_comment_likes WHERE comment_id = $1 AND user_id = $2',
      [commentId, userId]
    );

    if (existing.rows.length > 0) {
      try {
        await pool.query(
          'DELETE FROM author_post_comment_likes WHERE comment_id = $1 AND user_id = $2',
          [commentId, userId]
        );
        await pool.query('UPDATE author_post_comments SET likes_count = GREATEST(likes_count - 1, 0) WHERE id = $1', [commentId]);
      } catch (e) {
        console.error('Unlike comment error:', e);
      }
      res.json({ liked: false });
    } else {
      try {
        await pool.query(
          'INSERT INTO author_post_comment_likes (comment_id, user_id) VALUES ($1, $2)',
          [commentId, userId]
        );
        await pool.query('UPDATE author_post_comments SET likes_count = likes_count + 1 WHERE id = $1', [commentId]);
      } catch (e) {
        console.error('Like comment error:', e);
      }
      res.json({ liked: true });
    }
  } catch (err) {
    console.error('Like comment error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============================================================
// REPORTS
// ============================================================

// POST /api/author-walls/posts/:postId/report
router.post('/posts/:postId/report', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { postId } = req.params;
    const userId = (req as AuthRequest).user!.id;
    const { reason } = req.body;

    if (!reason || reason.trim().length === 0) {
      return res.status(400).json({ error: 'Reason is required' });
    }

    await pool.query(
      `INSERT INTO author_post_reports (post_id, reporter_id, reason) 
       VALUES ($1, $2, $3) 
       ON CONFLICT (post_id, reporter_id) DO NOTHING`,
      [postId, userId, reason.trim()]
    );

    res.json({ success: true });
  } catch (err) {
    console.error('Report post error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/author-walls/comments/:commentId/report
router.post('/comments/:commentId/report', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { commentId } = req.params;
    const userId = (req as AuthRequest).user!.id;
    const { reason } = req.body;

    if (!reason || reason.trim().length === 0) {
      return res.status(400).json({ error: 'Reason is required' });
    }

    await pool.query(
      `INSERT INTO author_post_comment_reports (comment_id, reporter_id, reason) 
       VALUES ($1, $2, $3) 
       ON CONFLICT (comment_id, reporter_id) DO NOTHING`,
      [commentId, userId, reason.trim()]
    );

    res.json({ success: true });
  } catch (err) {
    console.error('Report comment error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============================================================
// REVIEW REPLIES
// ============================================================

// POST /api/quests/:questId/reviews/:reviewId/reply
router.post('/quests/:questId/reviews/:reviewId/reply', authMiddleware, async (req: Request, res: Response) => {
  try {
    const { questId, reviewId } = req.params;
    const userId = (req as AuthRequest).user!.id;
    const { text } = req.body;

    if (!text || text.trim().length === 0) {
      return res.status(400).json({ error: 'Text is required' });
    }

    // Check that user is the quest author
    const quest = await pool.query('SELECT author_id, title FROM quests WHERE id = $1', [questId]);
    if (quest.rows.length === 0) {
      return res.status(404).json({ error: 'Quest not found' });
    }
    if (quest.rows[0].author_id !== userId) {
      return res.status(403).json({ error: 'Only the quest author can reply to reviews' });
    }

    const result = await pool.query(
      `UPDATE reviews 
       SET author_reply = $1, author_reply_at = NOW() 
       WHERE id = $2 AND quest_id = $3 
       RETURNING id, author_id`,
      [text.trim(), reviewId, questId]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Review not found' });
    }

    // Notify the user who left the review
    const reviewAuthorId = result.rows[0].author_id;
    if (reviewAuthorId !== userId) {
      await createNotification({
        userId: reviewAuthorId,
        actorId: userId,
        type: 'review_reply',
        questId: questId,
        reviewId: reviewId,
        payload: { title: quest.rows[0].title }
      });
    }

    res.json({ success: true });
  } catch (err) {
    console.error('Review reply error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;
