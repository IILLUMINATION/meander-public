import { PoolClient } from 'pg';
import pool from '../config/database';
import { sendPushToUser, buildPushFromNotification } from './fcm';
import { mirrorToSystemChat } from './system_chat';
import { getIO } from './socket';

export type NotificationType =
  | 'quest_like'
  | 'quest_review'
  | 'quest_updated'
  | 'quest_published'
  | 'quest_approved'
  | 'quest_rejected'
  | 'user_follow'
  | 'wall_post_new'
  | 'wall_post_like'
  | 'wall_post_comment'
  | 'wall_post_comment_reply'
  | 'review_reply'
  | 'system_news'
  | 'dm_message'
  | 'forum_ban'
  | 'forum_topic_removed'
  | 'support_message'
  | 'support_reply'
  | 'channel_post';

interface CreateNotificationInput {
  userId: string;
  actorId?: string | null;
  type: NotificationType;
  questId?: string | null;
  reviewId?: string | null;
  payload?: Record<string, any> | null;
}

interface CreateBulkNotificationsInput {
  userIds: string[];
  actorId?: string | null;
  type: NotificationType;
  questId?: string | null;
  reviewId?: string | null;
  payload?: Record<string, any> | null;
}

const normalizeUserIds = (userIds: string[], actorId?: string | null) => {
  const set = new Set<string>();
  for (const id of userIds) {
    if (!id) continue;
    if (actorId && id === actorId) continue;
    set.add(id);
  }
  return Array.from(set.values());
};

export const createNotification = async (
  input: CreateNotificationInput,
  client?: PoolClient,
) => {
  const { userId, actorId, type, questId, reviewId, payload } = input;
  if (!userId) return false;
  if (actorId && userId === actorId) return false;

  const db = client ?? pool;

  // Check author notification settings if this is an author-generated event
  if (actorId && ['quest_published', 'quest_updated', 'wall_post_new'].includes(type)) {
    const profileRes = await db.query(
      'SELECT author_notifs_mode, author_notifs_exceptions FROM profiles WHERE id = $1',
      [userId]
    );
    if (profileRes.rows.length > 0) {
      const { author_notifs_mode: mode, author_notifs_exceptions: exceptions } = profileRes.rows[0];
      const hasException = (exceptions || []).includes(actorId);
      if (mode === 'all' && hasException) return false; // muted
      if (mode === 'none' && !hasException) return false; // not whitelisted
    }
  }

  await db.query(
    `INSERT INTO notifications
        (user_id, actor_id, type, quest_id, review_id, payload)
      VALUES ($1, $2, $3, $4, $5, $6)`,
    [userId, actorId ?? null, type, questId ?? null, reviewId ?? null, payload ?? null],
  );

  // Send push notification automatically (fire-and-forget)
  sendPushForNotification(userId, actorId, type, payload, questId, reviewId).catch((err) => {
    console.error('Push notification background error:', err);
  });

  // Тихие часы и дебаунг — про шум в браузере; в чате событие должно остаться,
  // иначе «что происходило с аккаунтом» потеряет половину истории.
  mirrorToSystemChat([userId], actorId ?? null, type, payload ?? null).catch((err) => {
    console.error('System chat mirror error:', err);
  });

  return true;
};

/** Minimum interval between push notifications of the same type for the same user */
const PUSH_DEBOUNCE_MINUTES = 5;

/** Quiet hours: no push between 22:00 and 08:00 local user time */
const QUIET_START_HOUR = 22;
const QUIET_END_HOUR = 8;

const isQuietHours = async (userId: string): Promise<boolean> => {
  try {
    const res = await pool.query(
      'SELECT quiet_hours_enabled, timezone_offset FROM profiles WHERE id = $1',
      [userId],
    );
    if (res.rows.length === 0) return false;
    const { quiet_hours_enabled, timezone_offset } = res.rows[0];
    if (!quiet_hours_enabled) return false;
    if (timezone_offset == null) return false;

    const now = new Date();
    const userHour = new Date(now.getTime() + timezone_offset * 60 * 1000).getUTCHours();
    return userHour >= QUIET_START_HOUR || userHour < QUIET_END_HOUR;
  } catch {
    return false;
  }
};

/**
 * Resolve actor name and send push notification.
 * Fire-and-forget — never throws.
 * Debounces: no push if same (user, actor, type) was sent within PUSH_DEBOUNCE_MINUTES.
 */
const sendPushForNotification = async (
  userId: string,
  actorId?: string | null,
  type?: string,
  payload?: Record<string, any> | null,
  questId?: string | null,
  reviewId?: string | null,
) => {
  try {
    // Debounce check — skip push if same event happened recently
    const recent = await pool.query(
      `SELECT 1 FROM notifications
       WHERE user_id = $1 AND actor_id = $2 AND type = $3
         AND created_at > NOW() - ($4 || ' minutes')::INTERVAL
       LIMIT 2`,
      [userId, actorId ?? null, type ?? null, PUSH_DEBOUNCE_MINUTES.toString()],
    );
    // recent.rows.length > 1 because we just inserted this notification above,
    // so >1 means a duplicate before this one
    if (recent.rows.length > 1) {
      console.log(`⏳ [FCM] Debounced push for ${userId} (${type})`);
      return;
    }

    const quiet = await isQuietHours(userId);
    if (quiet) {
      console.log(`🔇 [FCM] Quiet hours — push skipped for ${userId}`);
      return;
    }

    let actorName: string | null = null;
    if (actorId) {
      const actor = await pool.query(
        'SELECT full_name FROM profiles WHERE id = $1',
        [actorId],
      );
      actorName = actor.rows[0]?.full_name ?? null;
    }

    const push = buildPushFromNotification(type ?? '', payload, actorName);
    if (!push) return; // This notification type doesn't trigger a push

    // Construct data payload for frontend deep linking
    const dataPayload: Record<string, string> = {
      type: type ?? '',
    };
    if (actorId) dataPayload.actorId = actorId;
    if (payload?.questId || questId) dataPayload.questId = payload?.questId ?? questId;
    if (payload?.postId) dataPayload.postId = payload.postId;
    // Бан и снятый топик адресуются слагом сообщества: без него тап по плашке
    // некуда вести — другого адреса у форума нет.
    if (payload?.forum_slug) dataPayload.forumSlug = String(payload.forum_slug);
    if (payload?.reviewId || reviewId) dataPayload.reviewId = payload?.reviewId ?? reviewId;
    // Поддержка и каналы ведут не по id сущности, а по своему адресу: у
    // обращения и поста в канале разные экраны.
    if (payload?.channel_id) dataPayload.channelId = String(payload.channel_id);
    if (payload?.ticket_id) dataPayload.ticketId = String(payload.ticket_id);
    if (payload?.link) dataPayload.link = String(payload.link);

    try {
      getIO().to(`user_${userId}`).emit('new_notification', {
        title: push.title,
        body: push.body,
        data: dataPayload
      });
    } catch (e) {
      console.error('Socket notification emit error:', e);
    }

    await sendPushToUser(userId, push.title, push.body, dataPayload);
  } catch (e) {
    // Silently ignore — push is best-effort
    console.error('Push error:', e);
  }
};

export const createBulkNotifications = async (
  input: CreateBulkNotificationsInput,
  client?: PoolClient,
) => {
  const { userIds, actorId, type, questId, reviewId, payload } = input;
  let recipients = normalizeUserIds(userIds, actorId ?? null);
  if (recipients.length === 0) return 0;

  const db = client ?? pool;

  // Check author notification settings if this is an author-generated event
  if (actorId && ['quest_published', 'quest_updated', 'wall_post_new'].includes(type)) {
    const profilesRes = await db.query(
      'SELECT id, author_notifs_mode, author_notifs_exceptions FROM profiles WHERE id = ANY($1)',
      [recipients]
    );
    
    recipients = recipients.filter(userId => {
      const profile = profilesRes.rows.find(p => p.id === userId);
      if (!profile) return true;
      const mode = profile.author_notifs_mode || 'all';
      const exceptions = profile.author_notifs_exceptions || [];
      const hasException = exceptions.includes(actorId);
      if (mode === 'all' && hasException) return false;
      if (mode === 'none' && !hasException) return false;
      return true;
    });
  }

  if (recipients.length === 0) return 0;

  const result = await db.query(
    `INSERT INTO notifications (user_id, actor_id, type, quest_id, review_id, payload)
     SELECT unnest($1::uuid[]), $2, $3, $4, $5, $6`,
    [recipients, actorId ?? null, type, questId ?? null, reviewId ?? null, payload ?? null],
  );

  for (const recipientId of recipients) {
    sendPushForNotification(recipientId, actorId, type, payload, questId, reviewId).catch((err) => {
      console.error('Push notification background error:', err);
    });
  }

  mirrorToSystemChat(recipients, actorId ?? null, type, payload ?? null).catch((err) => {
    console.error('System chat mirror error:', err);
  });

  return result.rowCount ?? 0;
};
