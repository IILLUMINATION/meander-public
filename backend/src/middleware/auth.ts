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

// In-memory кэш статуса блокировки с коротким TTL (SEC-01). Без кэша каждый
// запрос бил бы в БД; с ним — один SELECT на пользователя раз в TTL, а блок
// вступает в силу максимум через TTL после того, как его поставили.
const BLOCK_CACHE_TTL_MS = 30 * 1000;
const _blockStatusCache = new Map<string, { blocked: boolean; fetchedAt: number }>();

async function isBlocked(userId?: string): Promise<boolean> {
  if (!userId) return false;
  const cached = _blockStatusCache.get(userId);
  if (cached && Date.now() - cached.fetchedAt < BLOCK_CACHE_TTL_MS) {
    return cached.blocked;
  }
  try {
    const result = await pool.query(
      'SELECT is_blocked FROM profiles WHERE id = $1',
      [userId],
    );
    // Строки нет (пользователь удалён) — считаем незаблокированным: дальше по
    // коду запрос просто не найдёт владельца.
    const blocked = result.rows[0]?.is_blocked === true;
    _blockStatusCache.set(userId, { blocked, fetchedAt: Date.now() });
    return blocked;
  } catch (e) {
    // Best-effort, как touchLastSeen: если БД недоступна, большинство запросов
    // всё равно упадёт дальше; здесь не превращаем это в блокировку всех.
    console.error('[auth] block status check failed', e);
    return false;
  }
}

const authMiddleware = async (req: AuthRequest, res: Response, next: NextFunction) => {
  const token = getBearerToken(req.headers['authorization']);
  const secret = process.env.JWT_SECRET;

  if (!secret) {
    return res.status(500).json({ error: 'Server auth is not configured' });
  }
  if (!token) {
    return res.status(401).json({ error: 'No token provided' });
  }

  let user: jwt.JwtPayload | string;
  try {
    // Синхронная форма verify: возвращает payload или бросает на невалидном/
    // протухшем токене.
    user = jwt.verify(token, secret, { algorithms: ['HS256'] });
  } catch (err) {
    // 401, а не 403: токен протух (живёт 7 дней) — это конец сессии, а не
    // отказ по правилу. Клиент по 401 сбрасывает аккаунт и уводит на вход;
    // по 403 он считает ответ «запретил модерирующий код» и остаётся в
    // зомби-сессии, где падает каждый запрос.
    return res.status(401).json({ error: 'Token is not valid', code: 'TOKEN_INVALID' });
  }

  // Наши токены всегда объекты ({ id, role }); строка — это подписанная строка
  // старого формата, которой у нас не бывает.
  if (typeof user === 'string') {
    return res.status(401).json({ error: 'Token is not valid', code: 'TOKEN_INVALID' });
  }

  // SEC-01: заблокированным закрываем все защищённые endpoint'ы сразу в
  // middleware, а не в отдельных route'ах. 403 здесь — отказ по правилу, и
  // клиент его корректно не путает с мёртвым токеном.
  if (await isBlocked(user.id)) {
    return res.status(403).json({ error: 'Your account is blocked', code: 'ACCOUNT_BLOCKED' });
  }

  req.user = user;
  touchLastSeen(user.id);
  next();
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
