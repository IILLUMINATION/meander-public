import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import pool from '../config/database';
import { resetCleanupStageOnActivity } from '../services/cloud_sync_cleanup';
import { touchDailyActivity } from '../services/activity';

export interface AuthRequest extends Request {
  user?: any;
  files?: any;
}

// In-memory throttle: для каждого юзера обновляем last_seen_at не чаще раза в 2 минуты,
// чтобы не нагружать БД на каждом запросе.
const _lastSeenTouchedAt = new Map<string, number>();
const LAST_SEEN_THROTTLE_MS = 2 * 60 * 1000; // 2 минуты

function touchLastSeen(userId?: string) {
  if (!userId) return;
  const now = Date.now();
  const last = _lastSeenTouchedAt.get(userId) ?? 0;
  if (now - last < LAST_SEEN_THROTTLE_MS) return;
  _lastSeenTouchedAt.set(userId, now);
  // Аддитивный фоновый апдейт — не блокирует ответ
  pool
    .query(`UPDATE profiles SET last_seen_at = now() WHERE id = $1`, [userId])
    .catch(() => {
      // best-effort, поле может ещё не существовать на старых базах
    });
  // Сбрасываем cleanup_stage при возврате юзера (best-effort)
  resetCleanupStageOnActivity(userId).catch(() => {});
  // Заход в приложение для дашборда активности (best-effort, свой троттлинг)
  touchDailyActivity(userId);
}

const getBearerToken = (authHeader?: string): string | null => {
  if (!authHeader) return null;
  const [scheme, token] = authHeader.split(' ');
  if (scheme !== 'Bearer' || !token) return null;
  return token;
};

const authMiddleware = (req: AuthRequest, res: Response, next: NextFunction) => {
  const token = getBearerToken(req.headers['authorization']);
  const secret = process.env.JWT_SECRET;

  if (!secret) {
    return res.status(500).json({ error: 'Server auth is not configured' });
  }
  if (!token) {
    return res.status(401).json({ error: 'No token provided' });
  }

  jwt.verify(token, secret, { algorithms: ['HS256'] }, (err: any, user: any) => {
    if (err) {
      // 401, а не 403: токен протух (живёт 7 дней) — это конец сессии, а не
      // отказ по правилу. Клиент по 401 сбрасывает аккаунт и уводит на вход;
      // по 403 он считает ответ «запретил модерирующий код» и остаётся в
      // зомби-сессии, где падает каждый запрос.
      return res.status(401).json({ error: 'Token is not valid', code: 'TOKEN_INVALID' });
    }
    req.user = user;
    touchLastSeen(user?.id);
    next();
  });
};

export const optionalAuthMiddleware = (
  req: AuthRequest,
  res: Response,
  next: NextFunction,
) => {
  const token = getBearerToken(req.headers['authorization']);
  const secret = process.env.JWT_SECRET;

  if (!secret || !token) {
    next();
    return;
  }

  jwt.verify(token, secret, { algorithms: ['HS256'] }, (err: any, user: any) => {
    if (!err) {
      req.user = user;
      touchLastSeen(user?.id);
    }
    next();
  });
};

export default authMiddleware;
