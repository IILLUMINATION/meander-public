import { Router, Response } from 'express';
import rateLimit from 'express-rate-limit';
import { validate as uuidValidate } from 'uuid';

import pool from '../config/database';
import authMiddleware, { AuthRequest } from '../middleware/auth';
import { getIO } from '../services/socket';
import { clientIp } from '../services/client_ip';
import { createNotification } from '../services/notifications';
import { getTenure } from '../services/gating';
import { normalizeAttachments, type ChatAttachment } from '../services/chat_media';
import {
  detectLanguage,
  greetingReply,
  handleCallback,
  normalizeButtons,
  replyToText,
  ticketCreatedReply,
  ticketSubjectFrom,
  ticketsReply,
  type BotButton,
  type BotState,
  type SupportCategory,
  type SupportLanguage,
} from '../services/support_bot';

const router = Router();

const limitSupportSend = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 120,
  keyGenerator: (req: AuthRequest) => req.user?.id || clientIp(req) || 'anon',
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Слишком много сообщений. Попробуй позже.' },
});

interface SupportMessageRow {
  id: string;
  ticket_id: string | null;
  sender_id: string | null;
  role: 'user' | 'bot' | 'staff' | 'system';
  body: string;
  attachments: ChatAttachment[];
  buttons: BotButton[];
  created_at: string;
}

const text = (value: unknown): string => (typeof value === 'string' ? value : '');
const uuidOrNull = (value: unknown): string | null =>
  typeof value === 'string' && uuidValidate(value) ? value : null;

/**
 * Строка `support_messages` → контракт клиента. pg отдаёт неизвестные типы,
 * поэтому каждое поле проверяется, а не приводится вслепую: jsonb с чужим
 * содержимым не должен ронять ленту.
 */
const mapMessage = (row: Record<string, unknown>): SupportMessageRow => {
  const role = text(row.role);
  const attachments = Array.isArray(row.attachments)
    ? normalizeAttachments(row.attachments)
    : [];
  const buttons = normalizeButtons(row.buttons);
  return {
    id: text(row.id),
    ticket_id: uuidOrNull(row.ticket_id),
    sender_id: uuidOrNull(row.sender_id),
    role: role === 'bot' || role === 'staff' || role === 'system' ? role : 'user',
    body: text(row.body),
    attachments,
    buttons,
    created_at: text(row.created_at) || new Date().toISOString(),
  };
};

/** Профильные данные собеседника для шапки инбокса. */
const STAFF_FIELDS = `p.id, p.full_name, p.avatar_url, p.role`;

const isSupportLang = (value: unknown): value is SupportLanguage =>
  value === 'ru' || value === 'en';

/**
 * Сессия диалога с ботом. Создаётся при первом входе в окно; язык берётся
 * из профиля, если клиент его не присылал, и меняется кнопкой в меню.
 */
const ensureSession = async (
  userId: string,
  languageHint?: string,
): Promise<{ language: SupportLanguage; state: BotState }> => {
  const inserted = await pool.query(
    `INSERT INTO support_sessions (user_id, language)
     VALUES ($1, $2)
     ON CONFLICT (user_id) DO UPDATE SET updated_at = support_sessions.updated_at
     RETURNING language, state`,
    [userId, detectLanguage(languageHint)],
  );
  const row = inserted.rows[0];
  const language = isSupportLang(row.language) ? row.language : 'ru';
  const state = (row.state ?? {}) as BotState;
  return { language, state };
};

const saveSession = async (
  userId: string,
  language: SupportLanguage | undefined,
  state: BotState,
): Promise<void> => {
  await pool.query(
    `UPDATE support_sessions
        SET language = COALESCE($2, language), state = $3::jsonb, updated_at = NOW()
      WHERE user_id = $1`,
    [userId, language ?? null, JSON.stringify(state)],
  );
};

/** Записать реплику бота (или системную) в ленту пользователя. */
const writeBotMessages = async (
  userId: string,
  ticketId: string | null,
  replies: Array<{ body: string; buttons: BotButton[] }>,
): Promise<SupportMessageRow[]> => {
  const written: SupportMessageRow[] = [];
  for (const reply of replies) {
    if (!reply.body && reply.buttons.length === 0) continue;
    const inserted = await pool.query(
      `INSERT INTO support_messages (user_id, ticket_id, role, body, buttons)
       VALUES ($1, $2, 'bot', $3, $4::jsonb)
       RETURNING id, ticket_id, sender_id, role, body, attachments, buttons, created_at`,
      [userId, ticketId, reply.body, JSON.stringify(reply.buttons)],
    );
    written.push(mapMessage(inserted.rows[0]));
  }
  return written;
};

const activeTicket = async (userId: string) => {
  const result = await pool.query(
    `SELECT id, subject, category, status, language, created_at
       FROM support_tickets
      WHERE user_id = $1 AND status <> 'closed'
      ORDER BY created_at DESC
      LIMIT 1`,
    [userId],
  );
  return result.rows[0] ?? null;
};

const userTickets = async (userId: string) => {
  const result = await pool.query(
    `SELECT id, subject, status, created_at
       FROM support_tickets
      WHERE user_id = $1
      ORDER BY created_at DESC
      LIMIT 20`,
    [userId],
  );
  return result.rows;
};

const adminIds = async (): Promise<string[]> => {
  const result = await pool.query(
    `SELECT id FROM profiles WHERE role = 'admin' AND is_blocked = FALSE`,
  );
  return result.rows.map((row: any) => row.id);
};

const emitToUsers = (userIds: string[], event: string, payload: unknown): void => {
  if (userIds.length === 0) return;
  try {
    getIO()
      .to(userIds.map((id) => `user_${id}`))
      .emit(event, payload);
  } catch (error) {
    // Сообщение сохранено: отсутствие realtime — не повод для 500.
    console.error('support socket emit:', error);
  }
};

/**
 * Новое обращение от человека уходит всем админам сразу: личный диалог тут не
 * годится, обращение должно увидеть любой свободный.
 */
const fanOutToAdmins = async (
  ticket: { id: string; user_id: string; subject: string },
  preview: string,
): Promise<void> => {
  const admins = await adminIds();
  await Promise.all(
    admins.map((adminId) =>
      createNotification({
        userId: adminId,
        actorId: ticket.user_id,
        type: 'support_message',
        payload: {
          ticket_id: ticket.id,
          preview: preview.slice(0, 160),
          link: `/support/tickets/${ticket.id}`,
        },
      }).catch(() => false),
    ),
  );
  emitToUsers(admins, 'support_ticket_message', {
    ticket_id: ticket.id,
    preview: preview.slice(0, 160),
  });
};

// =======================================================================
//  ОКНО «ПОДДЕРЖКА» (автор обращения)
// =======================================================================
router.get('/chat', authMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  try {
    const hint = typeof req.headers['x-client-language'] === 'string'
      ? (req.headers['x-client-language'] as string)
      : undefined;
    const session = await ensureSession(me, hint);

    const existing = await pool.query(
      `SELECT COUNT(*)::int AS n FROM support_messages WHERE user_id = $1`,
      [me],
    );
    if ((existing.rows[0]?.n ?? 0) === 0) {
      await writeBotMessages(me, null, [greetingReply(session.language)]);
    }

    const [messages, ticket] = await Promise.all([
      pool.query(
        `SELECT id, ticket_id, sender_id, role, body, attachments, buttons, created_at
           FROM support_messages
          WHERE user_id = $1 AND deleted_at IS NULL
          ORDER BY created_at DESC
          LIMIT 100`,
        [me],
      ),
      activeTicket(me),
    ]);

    res.json({
      language: session.language,
      state: session.state,
      active_ticket: ticket,
      messages: messages.rows.map(mapMessage).reverse(),
    });
  } catch (error) {
    console.error('support chat:', error);
    res.status(500).json({ error: 'Не удалось открыть поддержку' });
  }
});

router.post('/messages', authMiddleware, limitSupportSend, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const body = typeof req.body?.body === 'string' ? req.body.body.trim() : '';
  const attachments = normalizeAttachments(req.body?.attachments);
  if (!body && attachments.length === 0) {
    return res.status(400).json({ error: 'Пустое сообщение' });
  }
  if (body.length > 4000) {
    return res.status(400).json({ error: 'Сообщение длиннее 4000 символов' });
  }

  try {
    const session = await ensureSession(me);
    const ticket = await activeTicket(me);

    // Есть открытое обращение — сообщение уходит в него и всем админам.
    if (ticket) {
      const inserted = await pool.query(
        `INSERT INTO support_messages (user_id, ticket_id, sender_id, role, body, attachments)
         VALUES ($1, $2, $1, 'user', $3, $4::jsonb)
         RETURNING id, ticket_id, sender_id, role, body, attachments, buttons, created_at`,
        [me, ticket.id, body, JSON.stringify(attachments)],
      );
      await pool.query(
        `UPDATE support_tickets
            SET status = 'open', updated_at = NOW(), last_message_at = NOW()
          WHERE id = $1`,
        [ticket.id],
      );
      const message = mapMessage(inserted.rows[0]);
      await fanOutToAdmins(
        { id: ticket.id, user_id: me, subject: ticket.subject },
        body || '📷 Фото',
      );
      return res.status(201).json({ message, ticket });
    }

    // Обращения нет: либо человек описывает проблему после выбора категории,
    // либо просто разговаривает с ботом.
    const state = session.state;
    if (state.awaiting === 'description' && (body || attachments.length > 0)) {
      const created = await pool.query(
        `INSERT INTO support_tickets (user_id, subject, category, language)
         VALUES ($1, $2, $3, $4)
         RETURNING id, subject, category, status, language, created_at`,
        [me, ticketSubjectFrom(body || 'Фото без описания'), state.category ?? 'other', session.language],
      );
      const ticketRow = created.rows[0];
      const inserted = await pool.query(
        `INSERT INTO support_messages (user_id, ticket_id, sender_id, role, body, attachments)
         VALUES ($1, $2, $1, 'user', $3, $4::jsonb)
         RETURNING id, ticket_id, sender_id, role, body, attachments, buttons, created_at`,
        [me, ticketRow.id, body, JSON.stringify(attachments)],
      );
      await saveSession(me, session.language, {});
      const botMessages = await writeBotMessages(me, ticketRow.id, [
        ticketCreatedReply(session.language),
      ]);
      await fanOutToAdmins(
        { id: ticketRow.id, user_id: me, subject: ticketRow.subject },
        body || '📷 Фото',
      );
      return res.status(201).json({
        message: mapMessage(inserted.rows[0]),
        bot_messages: botMessages,
        ticket: ticketRow,
      });
    }

    const clearedState = state.awaiting ? {} : state;
    if (state.awaiting) await saveSession(me, session.language, {});

    const reply = replyToText(body, session.language, clearedState, await userTickets(me));
    const botMessages = await writeBotMessages(me, null, [reply]);
    res.status(201).json({ bot_messages: botMessages });
  } catch (error) {
    console.error('support message:', error);
    res.status(500).json({ error: 'Не удалось отправить сообщение в поддержку' });
  }
});

router.post('/callback', authMiddleware, limitSupportSend, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const buttonId = typeof req.body?.button_id === 'string' ? req.body.button_id : '';
  if (!buttonId) return res.status(400).json({ error: 'Нет кнопки' });

  try {
    const session = await ensureSession(me);
    const result = handleCallback(buttonId, session.language, session.state);
    let replies = result.replies;

    // «Мои обращения» — данные из базы, поэтому собирается здесь, а не в боте.
    if (buttonId === 'my') {
      replies = [ticketsReply(session.language, await userTickets(me))];
    }

    await saveSession(me, result.language ?? session.language, result.state);
    const botMessages = await writeBotMessages(me, null, replies);
    res.json({ bot_messages: botMessages, language: result.language ?? session.language });
  } catch (error) {
    console.error('support callback:', error);
    res.status(500).json({ error: 'Не удалось выполнить действие' });
  }
});

// =======================================================================
//  ИНБОКС КОМАНДЫ
// =======================================================================
const requireStaff = async (req: AuthRequest, res: Response): Promise<boolean> => {
  const tenure = await getTenure(req.user!.id);
  if (!tenure || (tenure.role !== 'admin' && tenure.role !== 'moderator')) {
    res.status(403).json({ error: 'Только для команды' });
    return false;
  }
  return true;
};

router.get('/tickets', authMiddleware, async (req: AuthRequest, res: Response) => {
  if (!(await requireStaff(req, res))) return;
  const status = typeof req.query.status === 'string' ? req.query.status : 'open';
  const limit = Math.min(parseInt(String(req.query.limit ?? '50'), 10) || 50, 100);

  try {
    const result = await pool.query(
      `SELECT t.id, t.subject, t.category, t.status, t.priority, t.language,
              t.created_at, t.last_message_at, t.assigned_admin_id,
              ${STAFF_FIELDS},
              last.body AS last_body, last.role AS last_role,
              (SELECT COUNT(*)::int FROM support_messages m
                WHERE m.ticket_id = t.id AND m.deleted_at IS NULL
                  AND m.role = 'user'
                  AND m.created_at > COALESCE(r.last_read_at, 'epoch'::timestamptz)) AS unread
         FROM support_tickets t
         JOIN profiles p ON p.id = t.user_id
         LEFT JOIN support_staff_reads r ON r.ticket_id = t.id AND r.admin_id = $1
         LEFT JOIN LATERAL (
              SELECT body, role FROM support_messages m
               WHERE m.ticket_id = t.id AND m.deleted_at IS NULL
               ORDER BY m.created_at DESC LIMIT 1
         ) last ON TRUE
        WHERE ($2 = 'all' OR t.status = $2)
        ORDER BY t.priority ASC, t.last_message_at DESC
        LIMIT $3`,
      [req.user!.id, status, limit],
    );
    res.json({ tickets: result.rows });
  } catch (error) {
    console.error('support tickets:', error);
    res.status(500).json({ error: 'Не удалось загрузить обращения' });
  }
});

router.get('/tickets/:id', authMiddleware, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });

  try {
    const staff = await getTenure(me);
    const isStaff = staff?.role === 'admin' || staff?.role === 'moderator';

    const ticket = await pool.query(
      `SELECT t.*, ${STAFF_FIELDS}
         FROM support_tickets t JOIN profiles p ON p.id = t.user_id
        WHERE t.id = $1`,
      [id],
    );
    if (ticket.rows.length === 0) return res.status(404).json({ error: 'Обращение не найдено' });
    const row = ticket.rows[0];
    if (!isStaff && row.user_id !== me) {
      return res.status(404).json({ error: 'Обращение не найдено' });
    }

    const messages = await pool.query(
      `SELECT id, ticket_id, sender_id, role, body, attachments, buttons, created_at
         FROM support_messages
        WHERE ticket_id = $1 AND deleted_at IS NULL
        ORDER BY created_at ASC
        LIMIT 500`,
      [id],
    );

    if (isStaff) {
      await pool.query(
        `INSERT INTO support_staff_reads (ticket_id, admin_id, last_read_at)
         VALUES ($1, $2, NOW())
         ON CONFLICT (ticket_id, admin_id) DO UPDATE SET last_read_at = NOW()`,
        [id, me],
      );
    }

    res.json({ ticket: row, messages: messages.rows.map(mapMessage) });
  } catch (error) {
    console.error('support ticket:', error);
    res.status(500).json({ error: 'Не удалось открыть обращение' });
  }
});

router.post('/tickets/:id/messages', authMiddleware, limitSupportSend, async (req: AuthRequest, res: Response) => {
  const me = req.user!.id;
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });

  const body = typeof req.body?.body === 'string' ? req.body.body.trim() : '';
  const attachments = normalizeAttachments(req.body?.attachments);
  if (!body && attachments.length === 0) {
    return res.status(400).json({ error: 'Пустое сообщение' });
  }

  try {
    const tenure = await getTenure(me);
    const isStaff = tenure?.role === 'admin' || tenure?.role === 'moderator';

    const ticket = await pool.query(
      `SELECT id, user_id, status, language FROM support_tickets WHERE id = $1`,
      [id],
    );
    if (ticket.rows.length === 0) return res.status(404).json({ error: 'Обращение не найдено' });
    const row = ticket.rows[0];
    if (!isStaff && row.user_id !== me) {
      return res.status(404).json({ error: 'Обращение не найдено' });
    }

    const role = isStaff ? 'staff' : 'user';
    const inserted = await pool.query(
      `INSERT INTO support_messages (user_id, ticket_id, sender_id, role, body, attachments)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb)
       RETURNING id, ticket_id, sender_id, role, body, attachments, buttons, created_at`,
      [row.user_id, id, me, role, body, JSON.stringify(attachments)],
    );
    await pool.query(
      `UPDATE support_tickets
          SET status = $2, updated_at = NOW(), last_message_at = NOW()
        WHERE id = $1`,
      [id, isStaff ? 'answered' : 'open'],
    );

    const message = mapMessage(inserted.rows[0]);
    emitToUsers([row.user_id], 'support_message', { ticket_id: id, message });

    if (isStaff) {
      await createNotification({
        userId: row.user_id,
        actorId: me,
        type: 'support_reply',
        payload: {
          ticket_id: id,
          preview: (body || '📷 Фото').slice(0, 160),
          link: '/support',
        },
      }).catch(() => false);
    } else {
      await fanOutToAdmins(
        { id, user_id: row.user_id, subject: id },
        body || '📷 Фото',
      );
    }

    res.status(201).json({ message });
  } catch (error) {
    console.error('support ticket message:', error);
    res.status(500).json({ error: 'Не удалось отправить сообщение' });
  }
});

router.post('/tickets/:id/status', authMiddleware, async (req: AuthRequest, res: Response) => {
  if (!(await requireStaff(req, res))) return;
  const me = req.user!.id;
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Некорректный идентификатор' });

  const status = typeof req.body?.status === 'string' ? req.body.status : '';
  const assignToMe = req.body?.assign === true;
  if (!['open', 'answered', 'closed'].includes(status)) {
    return res.status(400).json({ error: 'Неизвестный статус' });
  }

  try {
    const updated = await pool.query(
      `UPDATE support_tickets
          SET status = $2,
              closed_at = CASE WHEN $2 = 'closed' THEN NOW() ELSE NULL END,
              closed_by = CASE WHEN $2 = 'closed' THEN $3::uuid ELSE NULL END,
              assigned_admin_id = CASE WHEN $4 THEN $3::uuid ELSE assigned_admin_id END,
              updated_at = NOW()
        WHERE id = $1
        RETURNING id, user_id, subject, status, language, closed_at`,
      [id, status, me, assignToMe],
    );
    if (updated.rows.length === 0) return res.status(404).json({ error: 'Обращение не найдено' });
    const row = updated.rows[0];

    if (status === 'closed') {
      const language = isSupportLang(row.language) ? row.language : 'ru';
      const closedMessages = await writeBotMessages(row.user_id, id, [
        {
          body:
            language === 'en'
              ? 'Your ticket is now closed. Write here if the issue comes back.'
              : 'Обращение закрыто. Если проблема вернётся — напиши здесь.',
          buttons: [],
        },
      ]);
      emitToUsers([row.user_id], 'support_message', {
        ticket_id: id,
        message: closedMessages[0] ?? null,
      });
    }

    res.json({ ticket: row });
  } catch (error) {
    console.error('support ticket status:', error);
    res.status(500).json({ error: 'Не удалось изменить статус' });
  }
});

export default router;