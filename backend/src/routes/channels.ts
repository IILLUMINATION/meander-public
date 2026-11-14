import { Router, Response } from 'express';
import rateLimit from 'express-rate-limit';
import { validate as uuidValidate } from 'uuid';

import pool from '../config/database';
import authMiddleware, { optionalAuthMiddleware, AuthRequest } from '../middleware/auth';
import { createBulkNotifications, createNotification } from '../services/notifications';
import { getIO } from '../services/socket';
import { clientIp } from '../services/client_ip';
import { normalizeAttachments } from '../services/chat_media';
import { getTenure } from '../services/gating';

const router = Router();

const limitWrite = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 60,
  keyGenerator: (req: AuthRequest) => req.user?.id || clientIp(req) || 'anon',
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Слишком много действий. Попробуй позже.' },
});

const CHANNEL_TITLE_MAX = 80;
const CHANNEL_DESCRIPTION_MAX = 500;
const POST_BODY_MAX = 8000;
const COMMENT_BODY_MAX = 1000;
const MAX_CHANNELS_PER_USER = 10;

const text = (value: unknown): string => (typeof value === 'string' ? value : '');

/** Роль вошедшего в канале: owner/admin может писать, subscriber — читать. */
const roleInChannel = async (channelId: string, userId?: string): Promise<string | null> => {
  if (!userId) return null;
  const result = await pool.query(
    `SELECT role FROM channel_subscribers WHERE channel_id = $1 AND user_id = $2`,
    [channelId, userId],
  );
  return result.rows[0]?.role ?? null;
};

const mapPost = (row: Record<string, unknown>) => ({
  id: text(row.id),
  channel_id: text(row.channel_id),
  author_id: text(row.author_id) || null,
  body: text(row.body),
  attachments: Array.isArray(row.attachments) ? row.attachments : [],
  views_count: Number(row.views_count) || 0,
  comments_count: Number(row.comments_count) || 0,
  created_at: text(row.created_at),
  edited_at: text(row.edited_at) || null,
});

/** Ссылка на канал для сообщений и уведомлений. */
const channelLink = (channelId: string): string => `/channels/${channelId}`;

// =======================================================================
//  СПИСОК И ПОИСК
// =======================================================================
router.get('/', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user?.id;
  const query = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  const mine = req.query.mine === 'true';
  const limit = Math.min(parseInt(String(req.query.limit ?? '30'), 10) || 30, 50);

  try {
    const result = await pool.query(
      `SELECT c.id, c.title, c.slug, c.description, c.avatar_url, c.is_public,
              c.subscribers_count, c.posts_count, c.created_at, c.last_post_at,
              s.role AS my_role, s.muted AS my_muted
         FROM channels c
         LEFT JOIN channel_subscribers s ON s.channel_id = c.id AND s.user_id = $1
        WHERE (c.is_public OR s.user_id IS NOT NULL)
          AND ($2 = '' OR c.title ILIKE '%' || $2 || '%' OR c.description ILIKE '%' || $2 || '%')
          AND ($3 = FALSE OR s.user_id IS NOT NULL)
        ORDER BY (s.user_id IS NOT NULL) DESC, c.subscribers_count DESC, c.created_at DESC
        LIMIT $4`,
      [me ?? null, query, mine, limit],
    );
    res.json({ channels: result.rows });
  } catch (error) {
    console.error('channels list:', error);
    res.status(500).json({ error: 'Не удалось загрузить каналы' });
  }
});

router.post('/', authMiddleware, limitWrite, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const title = text(req.body?.title).trim();
  const description = text(req.body?.description).trim();
  const avatarUrl = text(req.body?.avatar_url).trim();
  const isPublic = req.body?.is_public !== false;

  if (title.length < 2 || title.length > CHANNEL_TITLE_MAX) {
    return res.status(400).json({ error: `Название от 2 до ${CHANNEL_TITLE_MAX} символов` });
  }
  if (description.length > CHANNEL_DESCRIPTION_MAX) {
    return res.status(400).json({ error: `Описание до ${CHANNEL_DESCRIPTION_MAX} символов` });
  }

  try {
    const tenure = await getTenure(me);
    if (!tenure) return res.status(401).json({ error: 'Профиль не найден' });
    if (tenure.isBlocked) return res.status(403).json({ error: 'Профиль заблокирован' });

    const owned = await pool.query(
      `SELECT COUNT(*)::int AS n FROM channels WHERE owner_id = $1`,
      [me],
    );
    const isStaff = tenure.role === 'admin' || tenure.role === 'moderator';
    if (!isStaff && (owned.rows[0]?.n ?? 0) >= MAX_CHANNELS_PER_USER) {
      return res.status(429).json({ error: `Не больше ${MAX_CHANNELS_PER_USER} каналов на аккаунт` });
    }

    const created = await pool.query(
      `INSERT INTO channels (owner_id, title, description, avatar_url, is_public)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id, title, description, avatar_url, is_public, subscribers_count, posts_count, created_at`,
      [me, title, description, avatarUrl || null, isPublic],
    );
    const channel = created.rows[0];
    await pool.query(
      `INSERT INTO channel_subscribers (channel_id, user_id, role)
       VALUES ($1, $2, 'owner')
       ON CONFLICT (channel_id, user_id) DO UPDATE SET role = 'owner'`,
      [channel.id, me],
    );
    await pool.query(
      `UPDATE channels SET subscribers_count = 1 WHERE id = $1`,
      [channel.id],
    );
    res.status(201).json({ channel: { ...channel, subscribers_count: 1, my_role: 'owner' } });
  } catch (error) {
    console.error('channel create:', error);
    res.status(500).json({ error: 'Не удалось создать канал' });
  }
});

router.get('/:id', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });
  try {
    const result = await pool.query(
      `SELECT c.id, c.title, c.slug, c.description, c.avatar_url, c.is_public,
              c.comments_enabled, c.subscribers_count, c.posts_count,
              c.created_at, c.last_post_at, c.owner_id,
              s.role AS my_role, s.muted AS my_muted
         FROM channels c
         LEFT JOIN channel_subscribers s ON s.channel_id = c.id AND s.user_id = $2
        WHERE c.id = $1`,
      [id, req.user?.id ?? null],
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Канал не найден' });
    const channel = result.rows[0];
    if (!channel.is_public && !channel.my_role) {
      return res.status(404).json({ error: 'Канал не найден' });
    }
    res.json({ channel });
  } catch (error) {
    console.error('channel get:', error);
    res.status(500).json({ error: 'Не удалось открыть канал' });
  }
});

router.patch('/:id', authMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });

  try {
    const role = await roleInChannel(id, me);
    if (role !== 'owner' && role !== 'admin') {
      return res.status(403).json({ error: 'Менять канал может только владелец' });
    }
    const title = req.body?.title === undefined ? null : text(req.body.title).trim();
    if (title !== null && (title.length < 2 || title.length > CHANNEL_TITLE_MAX)) {
      return res.status(400).json({ error: `Название от 2 до ${CHANNEL_TITLE_MAX} символов` });
    }
    const description =
      req.body?.description === undefined ? null : text(req.body.description).trim();
    if (description !== null && description.length > CHANNEL_DESCRIPTION_MAX) {
      return res.status(400).json({ error: `Описание до ${CHANNEL_DESCRIPTION_MAX} символов` });
    }
    const avatarUrl = req.body?.avatar_url === undefined ? null : text(req.body.avatar_url).trim();
    const isPublic = typeof req.body?.is_public === 'boolean' ? req.body.is_public : null;
    const commentsEnabled =
      typeof req.body?.comments_enabled === 'boolean' ? req.body.comments_enabled : null;

    const updated = await pool.query(
      `UPDATE channels
          SET title = COALESCE($2, title),
              description = COALESCE($3, description),
              avatar_url = COALESCE($4, avatar_url),
              is_public = COALESCE($5, is_public),
              comments_enabled = COALESCE($6, comments_enabled),
              updated_at = NOW()
        WHERE id = $1
        RETURNING id, title, description, avatar_url, is_public, comments_enabled,
                  subscribers_count, posts_count`,
      [id, title, description, avatarUrl, isPublic, commentsEnabled],
    );
    res.json({ channel: updated.rows[0] });
  } catch (error) {
    console.error('channel patch:', error);
    res.status(500).json({ error: 'Не удалось сохранить канал' });
  }
});

router.delete('/:id', authMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });
  try {
    const deleted = await pool.query(
      `DELETE FROM channels WHERE id = $1 AND owner_id = $2 RETURNING id`,
      [id, me],
    );
    if (deleted.rows.length === 0) {
      return res.status(403).json({ error: 'Удалить канал может только владелец' });
    }
    res.json({ success: true });
  } catch (error) {
    console.error('channel delete:', error);
    res.status(500).json({ error: 'Не удалось удалить канал' });
  }
});

// =======================================================================
//  ПОДПИСКА
// =======================================================================
router.post('/:id/subscribe', authMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });
  try {
    const channel = await pool.query(
      `SELECT id, is_public FROM channels WHERE id = $1`,
      [id],
    );
    if (channel.rows.length === 0) return res.status(404).json({ error: 'Канал не найден' });
    if (!channel.rows[0].is_public) {
      return res.status(403).json({ error: 'Это закрытый канал' });
    }
    const inserted = await pool.query(
      `INSERT INTO channel_subscribers (channel_id, user_id)
       VALUES ($1, $2)
       ON CONFLICT (channel_id, user_id) DO NOTHING
       RETURNING channel_id`,
      [id, me],
    );
    if (inserted.rows.length > 0) {
      await pool.query(
        `UPDATE channels SET subscribers_count = subscribers_count + 1 WHERE id = $1`,
        [id],
      );
    }
    res.json({ subscribed: true });
  } catch (error) {
    console.error('channel subscribe:', error);
    res.status(500).json({ error: 'Не удалось подписаться' });
  }
});

router.delete('/:id/subscribe', authMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });
  try {
    const deleted = await pool.query(
      `DELETE FROM channel_subscribers
        WHERE channel_id = $1 AND user_id = $2 AND role = 'subscriber'
        RETURNING channel_id`,
      [id, me],
    );
    if (deleted.rows.length > 0) {
      await pool.query(
        `UPDATE channels SET subscribers_count = GREATEST(subscribers_count - 1, 0) WHERE id = $1`,
        [id],
      );
    }
    res.json({ subscribed: false });
  } catch (error) {
    console.error('channel unsubscribe:', error);
    res.status(500).json({ error: 'Не удалось отписаться' });
  }
});

// =======================================================================
//  ПОСТЫ
// =======================================================================
router.get('/:id/posts', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });
  const before = typeof req.query.before === 'string' ? req.query.before : null;
  const limit = Math.min(parseInt(String(req.query.limit ?? '20'), 10) || 20, 50);

  try {
    const channel = await pool.query(
      `SELECT id, is_public FROM channels WHERE id = $1`,
      [id],
    );
    if (channel.rows.length === 0) return res.status(404).json({ error: 'Канал не найден' });
    const role = await roleInChannel(id, req.user?.id);
    if (!channel.rows[0].is_public && !role) {
      return res.status(404).json({ error: 'Канал не найден' });
    }

    const posts = await pool.query(
      `SELECT id, channel_id, author_id, body, attachments, views_count,
              comments_count, created_at, edited_at
         FROM channel_posts
        WHERE channel_id = $1 AND deleted_at IS NULL
          AND ($2::timestamptz IS NULL OR created_at < $2::timestamptz)
        ORDER BY created_at DESC
        LIMIT $3`,
      [id, before, limit],
    );
    res.json({
      has_more: posts.rows.length === limit,
      posts: posts.rows.map(mapPost),
    });
  } catch (error) {
    console.error('channel posts:', error);
    res.status(500).json({ error: 'Не удалось загрузить посты' });
  }
});

/**
 * Публикация поста. Права проверяются по подписке с ролью: писать может
 * владелец и назначенные админы, подписчик — только читать. Событие уходит
 * подписчикам пачкой: у канала сотни людей, и по одному запросу в базу на
 * каждого рассылка превращалась бы в минуты ожидания.
 */
router.post('/:id/posts', authMiddleware, limitWrite, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });

  const body = text(req.body?.body).trim();
  const attachments = normalizeAttachments(req.body?.attachments);
  if (!body && attachments.length === 0) {
    return res.status(400).json({ error: 'Пустой пост' });
  }
  if (body.length > POST_BODY_MAX) {
    return res.status(400).json({ error: `Пост длиннее ${POST_BODY_MAX} символов` });
  }

  try {
    const role = await roleInChannel(id, me);
    if (role !== 'owner' && role !== 'admin') {
      return res.status(403).json({ error: 'Писать в канал может только владелец' });
    }
    const channel = await pool.query(
      `SELECT id, title FROM channels WHERE id = $1`,
      [id],
    );
    if (channel.rows.length === 0) return res.status(404).json({ error: 'Канал не найден' });

    const inserted = await pool.query(
      `INSERT INTO channel_posts (channel_id, author_id, body, attachments)
       VALUES ($1, $2, $3, $4::jsonb)
       RETURNING id, channel_id, author_id, body, attachments, views_count,
                 comments_count, created_at, edited_at`,
      [id, me, body, JSON.stringify(attachments)],
    );
    const post = mapPost(inserted.rows[0]);
    await pool.query(
      `UPDATE channels
          SET posts_count = posts_count + 1, last_post_at = NOW(), updated_at = NOW()
        WHERE id = $1`,
      [id],
    );

    const subscribers = await pool.query(
      `SELECT user_id FROM channel_subscribers
        WHERE channel_id = $1 AND user_id <> $2`,
      [id, me],
    );
    const recipientIds = subscribers.rows.map((row: { user_id: string }) => row.user_id);
    const preview = (body || '📷 Фото').slice(0, 140);
    const title = channel.rows[0].title;

    // Уведомления пачкой; ошибка базы на одном человеке не отменяет рассылку.
    if (recipientIds.length > 0) {
      await createBulkNotifications({
        userIds: recipientIds,
        actorId: me,
        type: 'channel_post',
        payload: {
          channel_id: id,
          channel_title: title,
          post_id: post.id,
          preview,
          link: `/channels/${id}/posts/${post.id}`,
        },
      }).catch((error) => console.error('channel notify:', error));

      try {
        getIO()
          .to(recipientIds.map((userId) => `user_${userId}`))
          .emit('channel_post', {
            channel_id: id,
            channel_title: title,
            post,
          });
      } catch (error) {
        console.error('channel socket:', error);
      }
    }

    res.status(201).json({ post, notified: recipientIds.length, link: channelLink(id) });
  } catch (error) {
    console.error('channel post:', error);
    res.status(500).json({ error: 'Не удалось опубликовать пост' });
  }
});

router.delete('/:id/posts/:postId', authMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { id, postId } = req.params;
  if (!uuidValidate(id) || !uuidValidate(postId)) {
    return res.status(400).json({ error: 'Некорректный идентификатор' });
  }
  try {
    const role = await roleInChannel(id, me);
    if (role !== 'owner' && role !== 'admin') {
      return res.status(403).json({ error: 'Удалять посты может только владелец' });
    }
    const deleted = await pool.query(
      `UPDATE channel_posts SET deleted_at = NOW()
        WHERE id = $1 AND channel_id = $2 AND deleted_at IS NULL
        RETURNING id`,
      [postId, id],
    );
    if (deleted.rows.length === 0) return res.status(404).json({ error: 'Пост не найден' });
    await pool.query(
      `UPDATE channels SET posts_count = GREATEST(posts_count - 1, 0) WHERE id = $1`,
      [id],
    );
    res.json({ success: true });
  } catch (error) {
    console.error('channel post delete:', error);
    res.status(500).json({ error: 'Не удалось удалить пост' });
  }
});

/** Просмотр: считаем один раз на человека, иначе счётчик крутится на F5. */
router.post('/posts/:postId/view', authMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { postId } = req.params;
  if (!uuidValidate(postId)) return res.status(400).json({ error: 'Некорректный идентификатор' });
  try {
    const inserted = await pool.query(
      `INSERT INTO channel_post_views (post_id, user_id)
       VALUES ($1, $2)
       ON CONFLICT (post_id, user_id) DO NOTHING
       RETURNING post_id`,
      [postId, me],
    );
    if (inserted.rows.length > 0) {
      await pool.query(
        `UPDATE channel_posts SET views_count = views_count + 1 WHERE id = $1`,
        [postId],
      );
    }
    res.json({ success: true, counted: inserted.rows.length > 0 });
  } catch (error) {
    console.error('channel post view:', error);
    res.status(500).json({ error: 'Не удалось учесть просмотр' });
  }
});

// =======================================================================
//  КОММЕНТАРИИ
// =======================================================================
router.get('/posts/:postId/comments', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
  const { postId } = req.params;
  if (!uuidValidate(postId)) return res.status(400).json({ error: 'Некорректный идентификатор' });
  try {
    const result = await pool.query(
      `SELECT cm.id, cm.post_id, cm.author_id, cm.body, cm.created_at,
              p.full_name AS author_name, p.avatar_url AS author_avatar_url
         FROM channel_comments cm
         LEFT JOIN profiles p ON p.id = cm.author_id
        WHERE cm.post_id = $1 AND cm.deleted_at IS NULL
        ORDER BY cm.created_at ASC
        LIMIT 200`,
      [postId],
    );
    res.json({ comments: result.rows });
  } catch (error) {
    console.error('channel comments:', error);
    res.status(500).json({ error: 'Не удалось загрузить комментарии' });
  }
});

router.post('/posts/:postId/comments', authMiddleware, limitWrite, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { postId } = req.params;
  if (!uuidValidate(postId)) return res.status(400).json({ error: 'Некорректный идентификатор' });
  const body = text(req.body?.body).trim();
  if (!body) return res.status(400).json({ error: 'Пустой комментарий' });
  if (body.length > COMMENT_BODY_MAX) {
    return res.status(400).json({ error: `Комментарий до ${COMMENT_BODY_MAX} символов` });
  }

  try {
    const post = await pool.query(
      `SELECT p.id, p.channel_id, c.comments_enabled, c.owner_id
         FROM channel_posts p JOIN channels c ON c.id = p.channel_id
        WHERE p.id = $1 AND p.deleted_at IS NULL`,
      [postId],
    );
    if (post.rows.length === 0) return res.status(404).json({ error: 'Пост не найден' });
    const row = post.rows[0];
    if (!row.comments_enabled) {
      return res.status(403).json({ error: 'Комментарии в канале выключены' });
    }

    const inserted = await pool.query(
      `INSERT INTO channel_comments (post_id, author_id, body)
       VALUES ($1, $2, $3)
       RETURNING id, post_id, author_id, body, created_at`,
      [postId, me, body],
    );
    await pool.query(
      `UPDATE channel_posts SET comments_count = comments_count + 1 WHERE id = $1`,
      [postId],
    );

    // Владельцу канала — уведомление, кроме его собственного комментария.
    if (row.owner_id && row.owner_id !== me) {
      await createNotification({
        userId: row.owner_id,
        actorId: me,
        type: 'channel_post',
        payload: {
          channel_id: row.channel_id,
          post_id: postId,
          preview: body.slice(0, 140),
          link: `/channels/${row.channel_id}/posts/${postId}`,
        },
      }).catch(() => false);
    }

    res.status(201).json({ comment: inserted.rows[0] });
  } catch (error) {
    console.error('channel comment create:', error);
    res.status(500).json({ error: 'Не удалось отправить комментарий' });
  }
});

export default router;