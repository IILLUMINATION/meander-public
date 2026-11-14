import { getApps, initializeApp, cert } from 'firebase-admin/app';
import { getMessaging, Message } from 'firebase-admin/messaging';
import pool from '../config/database';
import path from 'path';

// Initialize Firebase Admin SDK once
const serviceAccountPath = path.join(
  __dirname,
  '../../meander-39f48-firebase-adminsdk-fbsvc-aa87191011.json',
);

let warned = false;

/// false — ключа нет/не читается, пушей не будет. Повторный вызов дешёв и
/// не отравлен прошлой неудачей.
export const ensureInitialized = (): boolean => {
  if (getApps().length > 0) return true;
  try {
    initializeApp({
      credential: cert(serviceAccountPath),
    });
    console.log('✅ [FCM] Firebase Admin SDK initialized');
    return true;
  } catch (e: any) {
    // Раньше здесь при неудаче ставили `initialized = true`: процесс больше
    // не пробовал ничего, и прод жил без пушей до рестарта, роняя на каждое
    // сообщение «The default Firebase app does not exist». Если не запоминать
    // провал, файл достаточно подложить на место — следующий пуш уйдёт уже
    // без перезапуска.
    if (!warned) {
      warned = true;
      console.error(
        `⚠️ [FCM] Firebase не инициализирован: нет или не читается ключ ${serviceAccountPath}.`,
        'Пушей не будет. Причина:',
        e?.message ?? e,
      );
    }
    return false;
  }
};

/**
 * Send a push notification to a single user.
 * Looks up fcm_token from profiles table.
 * Returns true if sent, false if skipped (no token or error).
 */
export const sendPushToUser = async (
  userId: string,
  title: string,
  body: string,
  data?: Record<string, string>,
): Promise<boolean> => {
  try {
    if (!ensureInitialized()) {
      // Без ключа getMessaging() тонет в «default Firebase app does not
      // exist», и лог забывается мусором вместо одной внятной строки выше.
      return false;
    }

    // Get user's FCM token
    const result = await pool.query(
      'SELECT fcm_token FROM profiles WHERE id = $1',
      [userId],
    );

    if (result.rows.length === 0) {
      console.log(`📵 [FCM] User not found: ${userId}`);
      return false;
    }

    const fcmToken = result.rows[0].fcm_token;
    if (!fcmToken) {
      console.log(`📵 [FCM] No token for user: ${userId}`);
      return false;
    }

    // Send via Firebase
    const message: Message = {
      token: fcmToken,
      notification: {
        title,
        body,
      },
      data: data ?? {},
      android: {
        priority: 'high',
        notification: {
          channelId: 'meander_notifications',
          sound: 'default',
        },
      },
    };

    await getMessaging().send(message);
    console.log(`📨 [FCM] Sent push to user ${userId}: ${title}`);
    return true;
  } catch (error: any) {
    // If token is invalid, log and continue
    if (error.code === 'messaging/invalid-registration-token' ||
        error.code === 'messaging/registration-token-not-registered') {
      console.log(`📵 [FCM] Invalid token for user ${userId}, clearing...`);
      // Clear invalid token so we don't keep failing
      await pool.query(
        'UPDATE profiles SET fcm_token = NULL WHERE id = $1',
        [userId],
      );
      return false;
    }
    console.error('❌ [FCM] Push send error:', error.message ?? error);
    return false;
  }
};

/**
 * Build notification title/body from in-app notification type.
 * Returns { title, body } or null if this type shouldn't trigger a push.
 */
export const buildPushFromNotification = (
  type: string,
  payload?: Record<string, any> | null,
  actorName?: string | null,
): { title: string; body: string } | null => {
  switch (type) {
    case 'quest_like':
      return {
        title: 'Новый лайк ❤️',
        body: actorName
          ? `${actorName} оценил(а) ваш квест`
          : 'Кому-то понравился ваш квест',
      };

    case 'quest_review':
      return {
        title: 'Новый отзыв 📝',
        body: actorName
          ? `${actorName} оставил(а) отзыв на ваш квест`
          : 'Новый отзыв на ваш квест',
      };

    case 'quest_published':
      return {
        title: '📚 Новый квест',
        body: actorName
          ? (payload?.title
              ? `${actorName} опубликовал(а) квест «${payload.title}»`
              : `${actorName} опубликовал(а) новый квест`)
          : (payload?.title
              ? `Вышел новый квест «${payload.title}»`
              : 'Вышел новый квест от автора, на которого вы подписаны'),
      };

    case 'quest_updated':
      return {
        title: '🔄 Обновление квеста',
        body: actorName
          ? (payload?.title
              ? `${actorName} обновил(а) квест «${payload.title}»`
              : `${actorName} обновил(а) квест`)
          : (payload?.title
              ? `Обновился квест «${payload.title}»`
              : 'Обновился квест'),
      };

    case 'quest_approved':
      return {
        title: '🎉 Квест опубликован!',
        body: payload?.title
          ? `Ваш квест "${payload.title}" прошёл модерацию!`
          : 'Ваш квест прошёл модерацию',
      };

    case 'quest_rejected':
      return {
        title: 'Квест отклонён',
        body: payload?.title
          ? `Модератор отклонил квест "${payload.title}" — причина в «Мои публикации»`
          : 'Модератор отклонил ваш квест, причина в «Мои публикации»',
      };

    case 'user_follow':
      return {
        title: 'Новый подписчик 👋',
        body: actorName
          ? `${actorName} подписался(ась) на вас`
          : 'У вас новый подписчик',
      };

    case 'wall_post_new':
      return {
        title: 'Новый пост 📰',
        body: actorName
          ? `${actorName} опубликовал(а) новый пост`
          : 'Новый пост от автора',
      };

    case 'wall_post_like':
      return {
        title: 'Новый лайк на пост ❤️',
        body: actorName
          ? `${actorName} оценил(а) ваш пост`
          : 'Кому-то понравился ваш пост',
      };

    case 'wall_post_comment':
      return {
        title: 'Новый комментарий 💬',
        body: actorName
          ? `${actorName} прокомментировал(а) ваш пост`
          : 'У вашего поста новый комментарий',
      };

    case 'review_reply':
      return {
        title: 'Ответ разработчика 💬',
        body: actorName
          ? `${actorName} ответил(а) на ваш отзыв`
          : 'Автор ответил на ваш отзыв',
      };

    case 'dm_message': {
      const preview = String(payload?.preview || '').slice(0, 90);
      return {
        title: 'Новое сообщение',
        body: preview ? `${actorName ? actorName + ': ' : ''}${preview}` : `${actorName || 'Кто-то'}: личное сообщение`,
      };
    }

    case 'forum_ban':
      return {
        title: 'Ограничение в сообществе',
        body: payload?.forum
          ? `В сообществе «${payload.forum}» вам закрыли публикации`
          : 'В одном из сообществ вам закрыли публикации',
      };

    case 'forum_topic_removed':
      return {
        title: 'Топик удалён',
        body: payload?.forum
          ? `Модератор сообщества «${payload.forum}» удалил ваш топик`
          : 'Модератор сообщества удалил ваш топик',
      };

    case 'support_message': {
      const preview = String(payload?.preview || '').slice(0, 90);
      return {
        title: 'Поддержка Meander',
        body: preview || 'Команда ответила в обращении',
      };
    }

    case 'support_reply': {
      const preview = String(payload?.preview || '').slice(0, 90);
      return {
        title: 'Ответ поддержки',
        body: preview || 'Вам ответили по обращению',
      };
    }

    case 'channel_post': {
      const channel = String(payload?.channel_title || '');
      const preview = String(payload?.preview || '').slice(0, 90);
      return {
        title: channel ? `${channel}` : 'Новый пост в канале',
        body: preview || 'В канале, на который вы подписаны, новый пост',
      };
    }

    default:
      // Don't send push for other types
      return null;
  }
};