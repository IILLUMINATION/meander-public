import { Router, Response } from 'express';
import rateLimit from 'express-rate-limit';
import { validate as uuidValidate } from 'uuid';
import pool from '../config/database';
import authMiddleware, { AuthRequest } from '../middleware/auth';
import { getIO } from '../services/socket';
import { clientIp } from '../services/client_ip';
import { createNotification } from '../services/notifications';
import {
    DM_RULES,
    SYSTEM_USER_ID,
    checkDmPermission,
    getDmPrivacy,
    getDmUsageToday,
    getTenure,
    hasPeerReply,
    isStaff,
    secondsUntilNextMessage,
} from '../services/gating';

const router = Router();

// Отправка сообщения — действие человека, а не приложения: полсотни в час хватает
// на живой разговор и не дают развернуться рассылке.
const keyByUser = (req: AuthRequest): string => req.user?.id || clientIp(req) || 'anon';
const limitSend = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 120,
    keyGenerator: keyByUser,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Слишком много отправлений. Попробуй позже.' },
});

// Чужой профиль мы отдаём вместе с оформлением: список диалогов показывает
// людей, и «голый» ник там выглядел бы регрессом рядом с уже украшенным
// профилем.
const PEER_FIELDS = `p.id, p.full_name, p.avatar_url, p.cosmetics, p.role, p.last_seen_at`;

/**
 * Валидатор `uuid` требует ненулевые версии/варианты в самом id, а адрес
 * сервисного аккаунта — нулевой блок: под его проверку он не попадает, и чат
 * команды отвечал «Некорректный идентификатор». Для переписки это настоящий
 * собеседник, поэтому сравниваем его напрямую.
 */
const isUserId = (value: string): boolean =>
    value === SYSTEM_USER_ID || uuidValidate(value);

/**
 * Диалог с человеком (или с командой) создаётся по месту и один раз: порядок
 * id в паре нормализуем, иначе у двух аккаунтов заводится по два окна.
 */
const ensureThread = async (me: string, peer: string): Promise<string> => {
    const [userA, userB] = me < peer ? [me, peer] : [peer, me];
    const created = await pool.query(
        `INSERT INTO dm_threads (user_a, user_b)
         VALUES ($1, $2)
         ON CONFLICT (user_a, user_b) DO UPDATE SET user_a = EXCLUDED.user_a
         RETURNING id`,
        [userA, userB]
    );
    const threadId = created.rows[0].id;
    await pool.query(
        `INSERT INTO dm_thread_state (thread_id, user_id)
         VALUES ($1, $2), ($1, $3)
         ON CONFLICT (thread_id, user_id) DO NOTHING`,
        [threadId, userA, userB]
    );
    return threadId;
};

const mapMessage = (row: any) => ({
    id: row.id,
    thread_id: row.thread_id,
    sender_id: row.sender_id,
    body: row.body,
    kind: row.kind,
    created_at: row.created_at,
});

// =======================================================================
//  ЛЕНТА ДИАЛОГОВ
// =======================================================================
router.get('/threads', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    try {
        const result = await pool.query(
            `SELECT t.id AS thread_id,
                    t.last_message_at,
                    peer.id AS peer_id, peer.full_name AS peer_name, peer.avatar_url AS peer_avatar_url,
                    peer.cosmetics AS peer_cosmetics, peer.role AS peer_role, peer.last_seen_at AS peer_last_seen_at,
                    last.body AS last_body, last.sender_id AS last_sender_id, last.kind AS last_kind,
                    (st.muted_at IS NOT NULL) AS muted,
                    (SELECT COUNT(*)::int FROM dm_messages c
                      WHERE c.thread_id = t.id AND c.deleted_at IS NULL AND c.sender_id <> $1
                        AND c.created_at > COALESCE(st.last_read_at, 'epoch'::timestamptz)) AS unread
               FROM dm_threads t
               JOIN LATERAL (SELECT ${PEER_FIELDS} FROM profiles p
                              WHERE p.id = (CASE WHEN t.user_a = $1 THEN t.user_b ELSE t.user_a END)) peer ON TRUE
               LEFT JOIN dm_thread_state st ON st.thread_id = t.id AND st.user_id = $1
               LEFT JOIN LATERAL (SELECT body, sender_id, kind FROM dm_messages m
                                   WHERE m.thread_id = t.id AND m.deleted_at IS NULL
                                   ORDER BY m.created_at DESC LIMIT 1) last ON TRUE
              WHERE (t.user_a = $1 OR t.user_b = $1)
                AND st.hidden_at IS NULL
              ORDER BY t.last_message_at DESC NULLS LAST, t.created_at DESC
              LIMIT 200`,
            [me]
        );
        res.json({ threads: result.rows, system_user_id: SYSTEM_USER_ID });
    } catch (err) {
        console.error('dm threads:', err);
        res.status(500).json({ error: 'Не удалось загрузить переписки' });
    }
});

// =======================================================================
//  ДИАЛОГ ПО ID ЧЕЛОВЕКА
// =======================================================================
// Лента диалогов знает thread_id, а кнопка «Написать» в профиле — только id
// человека. Без этого окна переписки приходилось бы открывать через список,
// которого у нового диалога ещё нет.
router.get('/threads/peer/:peerId', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const peerId = req.params.peerId;
    if (!isUserId(peerId)) return res.status(400).json({ error: 'Некорректный идентификатор' });

    try {
        const result = await pool.query(
            `SELECT t.id AS thread_id,
                    p.id AS peer_id, p.full_name AS peer_name, p.avatar_url AS peer_avatar_url,
                    p.cosmetics AS peer_cosmetics, p.role AS peer_role, p.last_seen_at AS peer_last_seen_at,
                    (st.muted_at IS NOT NULL) AS muted
               FROM profiles p
               LEFT JOIN dm_threads t
                 ON (t.user_a = $1 AND t.user_b = p.id) OR (t.user_b = $1 AND t.user_a = p.id)
               LEFT JOIN dm_thread_state st ON st.thread_id = t.id AND st.user_id = $1
              WHERE p.id = $2`,
            [me, peerId]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'Человек не найден' });
        res.json(result.rows[0]);
    } catch (err) {
        console.error('dm thread by peer:', err);
        res.status(500).json({ error: 'Не удалось открыть переписку' });
    }
});

// =======================================================================
//  ИСТОРИЯ ОДНОГО ДИАЛОГА
// =======================================================================
router.get('/threads/:id', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });

    try {
        const member = await pool.query(
            `SELECT 1 FROM dm_threads WHERE id = $1 AND (user_a = $2 OR user_b = $2)`,
            [id, me]
        );
        if (member.rows.length === 0) return res.status(404).json({ error: 'Диалог не найден' });

        const before = req.query.before as string | undefined;
        const limit = Math.min(parseInt(req.query.limit as string, 10) || 50, 100);

        const messages = await pool.query(
            `SELECT id, thread_id, sender_id, body, kind, created_at
               FROM dm_messages
              WHERE thread_id = $1 AND deleted_at IS NULL
                AND ($2::timestamptz IS NULL OR created_at < $2::timestamptz)
              ORDER BY created_at DESC
              LIMIT $3`,
            [id, before || null, limit]
        );

        await pool.query(
            `INSERT INTO dm_thread_state (thread_id, user_id, last_read_at)
             VALUES ($1, $2, NOW())
             ON CONFLICT (thread_id, user_id) DO UPDATE SET last_read_at = NOW(), hidden_at = NULL`,
            [id, me]
        );

        res.json({
            thread_id: id,
            has_more: messages.rows.length === limit,
            messages: messages.rows.map(mapMessage).reverse(),
        });
    } catch (err) {
        console.error('dm thread:', err);
        res.status(500).json({ error: 'Не удалось загрузить переписку' });
    }
});

// =======================================================================
//  ОТПРАВКА
// =======================================================================
router.post('/threads/:peerId', authMiddleware, limitSend, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const peerId = req.params.peerId;
    if (!isUserId(peerId)) return res.status(400).json({ error: 'Некорректный получатель' });
    if (peerId === me) return res.status(400).json({ error: 'Себе писать нельзя' });

    const body = typeof req.body?.body === 'string' ? req.body.body.trim() : '';
    if (!body) return res.status(400).json({ error: 'Пустое сообщение' });
    if (body.length > DM_RULES.maxBodyChars) {
        return res.status(400).json({ error: `Сообщение длиннее ${DM_RULES.maxBodyChars} символов` });
    }

    try {
        // Диалог создаётся только после разрешения: иначе отказ оставил бы в БД
        // пустой тред на каждую попытку спам-бота.
        const found = await pool.query(
            `SELECT id FROM dm_threads
              WHERE (user_a = $1 AND user_b = $2) OR (user_a = $2 AND user_b = $1)`,
            [me, peerId]
        );
        const isNewThread = found.rows.length === 0;
        // Пороги «кто вообще может начать» снимаются, только если получатель
        // уже писал в этот диалог: молчание — не согласие на переписку.
        const peerReplied = !isNewThread && await hasPeerReply(found.rows[0].id, me);

        const gate = await checkDmPermission(me, peerId, peerReplied);
        if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

        const tenure = await getTenure(me);
        if (!tenure) return res.status(401).json({ error: 'Профиль не найден' });

        if (!isStaff(tenure)) {
            const usage = await getDmUsageToday(me);
            if (isNewThread && usage.threads >= DM_RULES.maxNewThreadsPerDay) {
                return res.status(429).json({
                    error: `За сутки можно начать ${DM_RULES.maxNewThreadsPerDay} новых переписок.`,
                });
            }
            if (usage.messages >= DM_RULES.maxMessagesPerDay) {
                return res.status(429).json({
                    error: `Дневной лимит сообщений (${DM_RULES.maxMessagesPerDay}) исчерпан.`,
                });
            }
            if (!isNewThread && !peerReplied) {
                const wait = await secondsUntilNextMessage(found.rows[0].id, me, tenure);
                if (wait > 0) {
                    return res.status(429).json({
                        error: `Следующее сообщение можно через ${wait} с.`,
                    });
                }
            }
        }

        const threadId = isNewThread ? await ensureThread(me, peerId) : found.rows[0].id;

        const inserted = await pool.query(
            `INSERT INTO dm_messages (thread_id, sender_id, body)
             VALUES ($1, $2, $3)
             RETURNING id, thread_id, sender_id, body, kind, created_at`,
            [threadId, me, body]
        );
        await pool.query(
            `UPDATE dm_threads SET last_message_at = NOW() WHERE id = $1`,
            [threadId]
        );
        await pool.query(
            `INSERT INTO dm_thread_state (thread_id, user_id, last_read_at)
             VALUES ($1, $2, NOW())
             ON CONFLICT (thread_id, user_id) DO UPDATE SET last_read_at = NOW(), hidden_at = NULL`,
            [threadId, me]
        );

        const message = inserted.rows[0];
        try {
            getIO().to([`user_${me}`, `user_${peerId}`]).emit('dm_message', {
                thread_id: threadId,
                message: mapMessage(message),
                is_new_thread: isNewThread,
            });
        } catch (e) {
            // Сообщение сохранено: отсутствие realtime не должно превращаться в 500.
            console.error('dm socket emit:', e);
        }

        // Пуш — то, по чему человек вообще узнает, что ему написали, когда
        // приложение закрыто. Не дожидаемся: доставка сообщения уже случилась.
        notifyPeerOfMessage(threadId, me, peerId, body).catch(e => console.error('dm push:', e));

        res.status(201).json({ thread_id: threadId, message: mapMessage(message) });
    } catch (err) {
        console.error('dm send:', err);
        res.status(500).json({ error: 'Не удалось отправить сообщение' });
    }
});

/**
 * Уведомление получателю. Заглушённый тред пуша не даёт: человек явно попросил
 * его не будить, при этом переписка никуда не девается и в ленте видна.
 */
const notifyPeerOfMessage = async (
    threadId: string,
    senderId: string,
    recipientId: string,
    body: string
): Promise<void> => {
    const state = await pool.query(
        `SELECT muted_at FROM dm_thread_state WHERE thread_id = $1 AND user_id = $2`,
        [threadId, recipientId]
    );
    if (state.rows[0]?.muted_at) return;

    await createNotification({
        userId: recipientId,
        actorId: senderId,
        type: 'dm_message',
        payload: { thread_id: threadId, preview: body.slice(0, 160) },
    });
};

// =======================================================================
//  ПРОЧИТАНО / СКРЫТО
// =======================================================================
router.post('/threads/:id/read', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });
    try {
        const updated = await pool.query(
            `INSERT INTO dm_thread_state (thread_id, user_id, last_read_at)
             SELECT $1, $2, NOW() FROM dm_threads WHERE id = $1 AND (user_a = $2 OR user_b = $2)
             ON CONFLICT (thread_id, user_id) DO UPDATE SET last_read_at = NOW()
             RETURNING thread_id`,
            [id, me]
        );
        if (updated.rows.length === 0) return res.status(404).json({ error: 'Диалог не найден' });
        res.json({ success: true });
    } catch (err) {
        console.error('dm read:', err);
        res.status(500).json({ error: 'Не удалось отметить прочитанное' });
    }
});

// «Заглушить» — переписка остаётся в ленте и продолжает приходить, но
// перестает будить пушем. Нужно ровно для одного случая: новостей команды
// слишком много, а убрать диалог совсем — значит потерять и системные уведомления.
router.post('/threads/:id/mute', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });
    const muted = req.body?.muted !== false;
    try {
        const updated = await pool.query(
            `INSERT INTO dm_thread_state (thread_id, user_id, muted_at)
             SELECT $1, $2, $3::timestamptz
               FROM dm_threads WHERE id = $1 AND (user_a = $2 OR user_b = $2)
             ON CONFLICT (thread_id, user_id) DO UPDATE SET muted_at = EXCLUDED.muted_at
             RETURNING thread_id`,
            [id, me, muted ? new Date() : null]
        );
        if (updated.rows.length === 0) return res.status(404).json({ error: 'Диалог не найден' });
        res.json({ success: true, muted });
    } catch (err) {
        console.error('dm mute:', err);
        res.status(500).json({ error: 'Не удалось изменить настройку' });
    }
});

// Диалог убирается из ленты только у того, кто нажал: у собеседника он остаётся.
router.delete('/threads/:id', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });
    try {
        const updated = await pool.query(
            `INSERT INTO dm_thread_state (thread_id, user_id, hidden_at)
             SELECT $1, $2, NOW() FROM dm_threads WHERE id = $1 AND (user_a = $2 OR user_b = $2)
             ON CONFLICT (thread_id, user_id) DO UPDATE SET hidden_at = NOW()
             RETURNING thread_id`,
            [id, me]
        );
        if (updated.rows.length === 0) return res.status(404).json({ error: 'Диалог не найден' });
        res.json({ success: true });
    } catch (err) {
        console.error('dm hide:', err);
        res.status(500).json({ error: 'Не удалось скрыть переписку' });
    }
});

// =======================================================================
//  ПРИВАТНОСТЬ: КТО МОЖЕТ ПИСАТЬ
// =======================================================================
router.get('/privacy', authMiddleware, async (req: AuthRequest, res: Response) => {
    try {
        const privacy = await getDmPrivacy(req.user!.id);
        res.json({
            mode: privacy.mode,
            min_playtime_hours: privacy.minPlaytimeHours,
            min_account_age_days: privacy.minAccountAgeDays,
        });
    } catch (err) {
        console.error('dm privacy get:', err);
        res.status(500).json({ error: 'Не удалось загрузить настройки' });
    }
});

const MODES = ['everyone', 'standing', 'following', 'nobody'];

router.put('/privacy', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const mode = req.body?.mode;
    if (!MODES.includes(mode)) return res.status(400).json({ error: 'Неизвестный режим' });

    const hours = Number(req.body?.min_playtime_hours);
    const days = Number(req.body?.min_account_age_days);
    const clean = (v: number, max: number) =>
        Number.isFinite(v) && v > 0 ? Math.min(Math.floor(v), max) : 0;
    if (hours > 1000 || days > 3650) {
        return res.status(400).json({ error: 'Слишком большой порог' });
    }

    try {
        await pool.query(
            `UPDATE profiles SET dm_privacy = $2 WHERE id = $1`,
            [me, JSON.stringify({
                mode,
                min_playtime_hours: clean(hours, 1000),
                min_account_age_days: clean(days, 3650),
            })]
        );
        res.json({ success: true });
    } catch (err) {
        console.error('dm privacy put:', err);
        res.status(500).json({ error: 'Не удалось сохранить настройки' });
    }
});

// =======================================================================
//  БЛОКИРОВКИ
// =======================================================================
router.get('/blocks', authMiddleware, async (req: AuthRequest, res: Response) => {
    try {
        const result = await pool.query(
            `SELECT ${PEER_FIELDS}, b.created_at AS blocked_at
               FROM user_blocks b
               JOIN profiles p ON p.id = b.blocked_id
              WHERE b.user_id = $1
              ORDER BY b.created_at DESC`,
            [req.user!.id]
        );
        res.json({ blocked: result.rows });
    } catch (err) {
        console.error('blocks list:', err);
        res.status(500).json({ error: 'Не удалось загрузить список' });
    }
});

router.post('/blocks/:userId', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const target = req.params.userId;
    if (!isUserId(target)) return res.status(400).json({ error: 'Некорректный идентификатор' });
    if (target === me) return res.status(400).json({ error: 'Себя заблокировать нельзя' });
    if (target === SYSTEM_USER_ID) {
        return res.status(400).json({ error: 'Аккаунт команды заблокировать нельзя' });
    }
    try {
        await pool.query(
            `INSERT INTO user_blocks (user_id, blocked_id) VALUES ($1, $2)
             ON CONFLICT DO NOTHING`,
            [me, target]
        );
        res.json({ success: true });
    } catch (err) {
        console.error('block:', err);
        res.status(500).json({ error: 'Не удалось заблокировать' });
    }
});

router.delete('/blocks/:userId', authMiddleware, async (req: AuthRequest, res: Response) => {
    const target = req.params.userId;
    if (!isUserId(target)) return res.status(400).json({ error: 'Некорректный идентификатор' });
    try {
        await pool.query(
            `DELETE FROM user_blocks WHERE user_id = $1 AND blocked_id = $2`,
            [req.user!.id, target]
        );
        res.json({ success: true });
    } catch (err) {
        console.error('unblock:', err);
        res.status(500).json({ error: 'Не удалось разблокировать' });
    }
});

// =======================================================================
//  СИСТЕМНЫЙ ЧАТ
// =======================================================================
// Тот же диалог, что и человеческий, — просто вторым участником числится
// аккаунт команды. Отдельных эндпоинтов для «чата с новостями» нет намеренно.
router.get('/system', authMiddleware, async (req: AuthRequest, res: Response) => {
    try {
        const threadId = await ensureThread(req.user!.id, SYSTEM_USER_ID);
        res.json({ thread_id: threadId });
    } catch (err) {
        console.error('system thread:', err);
        res.status(500).json({ error: 'Не удалось открыть системный чат' });
    }
});

const limitBroadcast = rateLimit({
    windowMs: 24 * 60 * 60 * 1000,
    max: 10,
    keyGenerator: keyByUser,
    standardHeaders: true,
    legacyHeaders: false,
});

// Рассылка новости: сначала наборно создаём системные треды всем, потом одним
// запросом пишем сообщение. Цикл по пользователям на 4 тыс. аккаунтов — это
// 4 тыс. запросов, а не два.
router.post('/system/broadcast', authMiddleware, limitBroadcast, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const body = typeof req.body?.body === 'string' ? req.body.body.trim() : '';
    if (!body) return res.status(400).json({ error: 'Пустое сообщение' });
    if (body.length > DM_RULES.maxBodyChars) {
        return res.status(400).json({ error: `Новость длиннее ${DM_RULES.maxBodyChars} символов` });
    }

    try {
        const tenure = await getTenure(me);
        if (!tenure || !isStaff(tenure)) {
            return res.status(403).json({ error: 'Новость команды может публиковать только админ' });
        }

        const userCount = await pool.query(`SELECT COUNT(*)::int AS n FROM profiles WHERE id <> $1::uuid`, [me]);
        const limit = Math.min(userCount.rows[0].n + 10, 50000);
        await pool.query(
            `INSERT INTO dm_threads (user_a, user_b)
             SELECT $1::uuid, id FROM profiles WHERE id <> $1::uuid
             ORDER BY id LIMIT $2
             ON CONFLICT (user_a, user_b) DO NOTHING`,
            [SYSTEM_USER_ID, limit]
        );

        const inserted = await pool.query(
            `WITH peers AS (
                SELECT t.id AS thread_id, t.user_b AS user_id
                  FROM dm_threads t
                 WHERE t.user_a = $1::uuid AND t.user_b <> $2::uuid
             ), written AS (
                INSERT INTO dm_messages (thread_id, sender_id, body, kind)
                SELECT thread_id, $1::uuid, $3, 'news' FROM peers
                RETURNING 1
             )
             UPDATE dm_threads t SET last_message_at = NOW()
               FROM peers WHERE t.id = peers.thread_id
             RETURNING (SELECT COUNT(*) FROM written) AS delivered`,
            [SYSTEM_USER_ID, me, body]
        );
        await pool.query(
            `INSERT INTO notifications (user_id, actor_id, type, payload)
             SELECT t.user_b, $1::uuid, 'system_news', $3::jsonb FROM dm_threads t WHERE t.user_a = $1::uuid`,
            [SYSTEM_USER_ID, me, JSON.stringify({ title: 'Новости Meander', body })]
        );

        // Push рассылки на несколько тысяч аккаунтов здесь нет намеренно: новость
        // лежит в системном чате и в колокольчике. Онлайн-получателям отправляем
        // одним вызовом — socket.io сам разберёт, кто реально подключён.
        try {
            const recipients = await pool.query(
                `SELECT user_b FROM dm_threads WHERE user_a = $1`,
                [SYSTEM_USER_ID]
            );
            getIO().to(recipients.rows.map((r: any) => `user_${r.user_b}`)).emit('new_notification', {
                title: 'Новости Meander',
                body,
                data: { type: 'system_news' },
            });
        } catch (e) {
            console.error('broadcast socket emit:', e);
        }

        res.json({ success: true, delivered: Number(inserted.rows[0]?.delivered) || 0 });
    } catch (err) {
        console.error('broadcast:', err);
        res.status(500).json({ error: 'Не удалось опубликовать новость' });
    }
});

export default router;
