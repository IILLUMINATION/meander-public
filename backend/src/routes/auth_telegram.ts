import { Router, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import pool from '../config/database';
import { v4 as uuidv4 } from 'uuid';
import dotenv from 'dotenv';
import crypto from 'crypto';
import { awardAchievement } from '../services/achievements';
import { verifyTelegramIdToken } from '../services/telegram_jwt';

dotenv.config();

const router = Router();
const jwtSecret = process.env.JWT_SECRET;
const botToken = process.env.TELEGRAM_BOT_TOKEN || process.env.TELOXIDE_TOKEN;

// POST /auth/telegram/token  { telegramIdToken: string }  or { idToken, token }
router.post('/telegram/token', async (req: Request, res: Response) => {
  const { telegramIdToken, idToken, token, telegramData } = req.body as any;
  const rawToken: string | undefined = telegramIdToken || idToken || token;

  // Fallback: legacy Telegram Widget hash auth (if client sends telegramData + hash)
  if (!rawToken && telegramData) {
    // telegramData = { id, first_name, username, auth_date, hash }
    return handleTelegramWidgetAuth(req, res);
  }

  if (!rawToken) {
    return res.status(400).json({ error: 'telegramIdToken is required' });
  }
  if (!jwtSecret) {
    return res.status(500).json({ error: 'Server auth is not configured' });
  }
  // Без ключа бота подпись проверить нечем, а принимать неподписанный токен
  // нельзя — значит вход через Telegram недоступен, а не открыт.
  if (!botToken) {
    return res.status(503).json({ error: 'Telegram sign-in is not configured' });
  }

  try {
    const payload = verifyTelegramIdToken(rawToken, botToken);

    // Telegram JWT payload fields vary: sub/id, preferred_username/username, name, picture
    const telegramId: string | null = String(
      payload.sub || payload.id || payload.user_id || payload.telegram_id || '',
    ) || null;
    const username: string | null = payload.preferred_username || payload.username || payload.login || null;
    const fullName: string | null =
      payload.name || [payload.given_name, payload.family_name].filter(Boolean).join(' ') || username || (telegramId ? `tg_${telegramId}` : null);
    const avatarUrl: string | null = payload.picture || payload.photo_url || null;

    if (!telegramId) {
      return res.status(401).json({ error: 'Invalid Telegram token payload' });
    }

    let userResult = await pool.query('SELECT * FROM profiles WHERE telegram_id = $1', [telegramId]);
    let user;

    if (userResult.rows.length === 0) {
      // No link by email (per request) — ensure email UNIQUE not violated (telegram users have NULL email)
      const newUserResult = await pool.query(
        'INSERT INTO profiles (id, telegram_id, telegram_username, full_name, avatar_url) VALUES ($1, $2, $3, $4, $5) RETURNING *',
        [uuidv4(), telegramId, username, fullName, avatarUrl],
      );
      user = newUserResult.rows[0];
      await awardAchievement(user.id, 'hello_world');
      console.log('New user via Telegram:', telegramId, username);
    } else {
      user = userResult.rows[0];
      try {
        await pool.query('UPDATE profiles SET telegram_username = COALESCE($2, telegram_username), full_name = COALESCE($3, full_name), avatar_url = CASE WHEN avatar_custom THEN avatar_url ELSE COALESCE($4, avatar_url) END WHERE id = $1', [
          user.id,
          username,
          fullName,
          avatarUrl,
        ]);
        user.telegram_username = username || user.telegram_username;
        user.full_name = fullName || user.full_name;
        // Картинка из Telegram не отменяет свой аватар.
        if (!user.avatar_custom) user.avatar_url = avatarUrl || user.avatar_url;
      } catch (_) {}
      console.log('User sign-in via Telegram:', telegramId, username);
    }

    const appToken = jwt.sign({ id: user.id, role: user.role, tv: user.token_version ?? 0 }, jwtSecret, { expiresIn: '7d' });
    res.json({ token: appToken, user });
  } catch (error: any) {
    if (error.status === 401) return res.status(401).json({ error: error.message || 'Invalid Telegram token' });
    console.error('Error verifying Telegram token:', error);
    res.status(500).json({ error: 'Server error during Telegram verification' });
  }
});

// Optional: handle legacy Widget hash flow if needed
async function handleTelegramWidgetAuth(req: Request, res: Response) {
  const data = (req.body as any).telegramData;
  if (!data?.id || !data?.hash) return res.status(400).json({ error: 'telegramData invalid' });
  if (!botToken) return res.status(500).json({ error: 'TELEGRAM_BOT_TOKEN not configured' });
  const checkString = Object.keys(data)
    .filter((k) => k !== 'hash')
    .sort()
    .map((k) => `${k}=${data[k]}`)
    .join('\n');
  const secret = crypto.createHash('sha256').update(botToken).digest();
  const hmac = crypto.createHmac('sha256', secret).update(checkString).digest('hex');
  const expected = Buffer.from(hmac, 'hex');
  const provided = Buffer.from(String(data.hash || ''), 'hex');
  if (expected.length !== provided.length || !crypto.timingSafeEqual(expected, provided)) {
    return res.status(401).json({ error: 'Invalid Telegram hash' });
  }
  // SEC-10: auth_date обязателен; произвольно старый или будущий payload —
  // это повтор украденного виджета, а не вход.
  const authDate = Number(data.auth_date);
  if (!Number.isFinite(authDate) || Math.abs(Date.now() / 1000 - authDate) > 86400) {
    return res.status(401).json({ error: 'Telegram auth expired' });
  }
  const telegramId = String(data.id);
  const username = data.username || null;
  const fullName = [data.first_name, data.last_name].filter(Boolean).join(' ') || username || `tg_${telegramId}`;
  const avatarUrl = data.photo_url || null;
  let userResult = await pool.query('SELECT * FROM profiles WHERE telegram_id = $1', [telegramId]);
  let user;
  if (userResult.rows.length === 0) {
    const r = await pool.query('INSERT INTO profiles (id, telegram_id, telegram_username, full_name, avatar_url) VALUES ($1,$2,$3,$4,$5) RETURNING *', [
      uuidv4(),
      telegramId,
      username,
      fullName,
      avatarUrl,
    ]);
    user = r.rows[0];
    await awardAchievement(user.id, 'hello_world');
  } else {
    user = userResult.rows[0];
  }
  const token = jwt.sign({ id: user.id, role: user.role, tv: user.token_version ?? 0 }, jwtSecret as string, { expiresIn: '7d' });
  return res.json({ token, user });
}

export default router;
