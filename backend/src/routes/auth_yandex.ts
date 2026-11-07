import { Router, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import pool from '../config/database';
import { v4 as uuidv4 } from 'uuid';
import dotenv from 'dotenv';
import { awardAchievement } from '../services/achievements';

dotenv.config();

const router = Router();
const jwtSecret = process.env.JWT_SECRET;

interface YandexInfo {
  id: string;
  login: string;
  default_email?: string;
  emails?: string[];
  display_name?: string;
  real_name?: string;
  first_name?: string;
  last_name?: string;
  default_avatar_id?: string;
}

async function fetchYandexInfo(oauthToken: string): Promise<YandexInfo> {
  const res = await fetch('https://login.yandex.ru/info?format=json', {
    headers: { Authorization: `OAuth ${oauthToken}` },
    // 5s timeout via AbortController
    signal: AbortSignal.timeout(5000),
  } as any);
  if (res.status === 401) {
    const e: any = new Error('Invalid Yandex token');
    e.status = 401;
    throw e;
  }
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    const e: any = new Error(`Yandex info failed: ${res.status} ${text}`);
    e.status = 502;
    throw e;
  }
  const data = (await res.json()) as any;
  if (!data.id || !data.login) {
    const e: any = new Error('Yandex response missing id/login');
    e.status = 502;
    throw e;
  }
  return data as YandexInfo;
}

// POST /auth/yandex/token  { yandexToken: string }
router.post('/yandex/token', async (req: Request, res: Response) => {
  const { yandexToken, token } = req.body as { yandexToken?: string; token?: string };
  const oauthToken = yandexToken || token;

  if (!oauthToken) {
    return res.status(400).json({ error: 'yandexToken is required' });
  }
  if (!jwtSecret) {
    return res.status(500).json({ error: 'Server auth is not configured' });
  }

  try {
    const info = await fetchYandexInfo(oauthToken);

    const yandexId = String(info.id);
    const yandexLogin = String(info.login);
    const email: string | null = info.default_email || (info.emails && info.emails[0]) || null;
    const fullName: string | null =
      info.display_name || info.real_name || [info.first_name, info.last_name].filter(Boolean).join(' ') || yandexLogin;
    const avatarUrl: string | null = info.default_avatar_id
      ? `https://avatars.yandex.net/get-yapic/${info.default_avatar_id}/islands-200`
      : null;

    // Без линка по email (по просьбе): ищем только по yandex_id
    let userResult = await pool.query('SELECT * FROM profiles WHERE yandex_id = $1', [yandexId]);
    let user;

    if (userResult.rows.length === 0) {
      // Создаём нового пользователя. email может быть null (если скрыт в Яндексе) — тогда UNIQUE не триггерит.
      // Если email уже занят другим google-акком — не линкуем, создаём отдельного я-акка без email или с суффиксом.
      // Проще: если email конфликт — ставим email = null для yandex-пользователя.
      let emailToInsert: string | null = email;
      if (emailToInsert) {
        const emailExists = await pool.query('SELECT id FROM profiles WHERE email = $1', [emailToInsert]);
        if (emailExists.rows.length > 0) {
          // Не линкуем — оставляем yandex-пользователя без email, чтобы не нарушить UNIQUE
          emailToInsert = null;
        }
      }
      const newUserResult = await pool.query(
        'INSERT INTO profiles (id, yandex_id, yandex_login, full_name, email, avatar_url) VALUES ($1, $2, $3, $4, $5, $6) RETURNING *',
        [uuidv4(), yandexId, yandexLogin, fullName, emailToInsert, avatarUrl],
      );
      user = newUserResult.rows[0];
      await awardAchievement(user.id, 'hello_world');
      console.log('New user created via Yandex:', user.full_name, yandexLogin);
    } else {
      user = userResult.rows[0];
      // Обновляем профиль свежим именем/аватаркой при каждом входе (best-effort).
      // Свой аватар (avatar_custom) картинкой из Яндекса не перетираем.
      try {
        await pool.query('UPDATE profiles SET full_name = COALESCE($2, full_name), avatar_url = CASE WHEN avatar_custom THEN avatar_url ELSE COALESCE($3, avatar_url) END, yandex_login = $4 WHERE id = $1', [
          user.id,
          fullName,
          avatarUrl,
          yandexLogin,
        ]);
        user.full_name = fullName || user.full_name;
        if (!user.avatar_custom) user.avatar_url = avatarUrl || user.avatar_url;
        user.yandex_login = yandexLogin;
      } catch (_) {}
      console.log('User signed in via Yandex:', user.full_name, yandexLogin);
    }

    const appToken = jwt.sign({ id: user.id, role: user.role, tv: user.token_version ?? 0 }, jwtSecret, { expiresIn: '7d' });

    res.json({ token: appToken, user });
  } catch (error: any) {
    if (error.status === 401) {
      return res.status(401).json({ error: 'Invalid Yandex token' });
    }
    console.error('Error verifying Yandex token:', error);
    res.status(500).json({ error: 'Server error during Yandex verification' });
  }
});

export default router;
