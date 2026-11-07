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

// In-memory кэш состояния аккаунта (SEC-01, SEC-02). Без кэша каждый запрос
// бил бы в БД; с ним — один SELECT на пользователя раз в TTL, а блокировка и
// отзыв токена вступают в силу максимум через TTL.
const ACCOUNT_CACHE_TTL_MS = 30 * 1000;
const _accountCache = new Map<string, { blocked: boolean; tokenVersion: number | null; fetchedAt: number }>();

async function getAccountState(userId?: string): Promise<{ blocked: boolean; tokenVersion: number | null }> {
  if (!userId) return { blocked: false, tokenVersion: null };
  const cached = _accountCache.get(userId);
  if (cached && Date.now() - cached.fetchedAt < ACCOUNT_CACHE_TTL_MS) {
    return cached;
  }
  try {
    const result = await pool.query(
      'SELECT is_blocked, token_version FROM profiles WHERE id = $1',
      [userId],
    );
    // Строки нет (пользователь удалён) — считаем незаблокированным: дальше по
    // коду запрос просто не найдёт владельца.
    const state = {
      blocked: result.rows[0]?.is_blocked === true,
      tokenVersion: result.rows[0]?.token_version ?? 0,
    };
    _accountCache.set(userId, { ...state, fetchedAt: Date.now() });
    return state;
  } catch (e: any) {
    // Миграция token_version могла ещё не приехать: не блокируем всех из-за
    // отсутствующей колонки, проверяем хотя бы is_blocked.
    if (e?.code === '42703') {
      try {
        const result = await pool.query('SELECT is_blocked FROM profiles WHERE id = $1', [userId]);
        const state = { blocked: result.rows[0]?.is_blocked === true, tokenVersion: null };
        _accountCache.set(userId, { ...state, fetchedAt: Date.now() });
        return state;
      } catch (e2) {
        console.error('[auth] block status check failed', e2);
        return { blocked: false, tokenVersion: null };
      }
    }
    // Best-effort, как touchLastSeen: если БД недоступна, большинство запросов
    // всё равно упадёт дальше; здесь не превращаем это в блокировку всех.
    console.error('[auth] account state check failed', e);
    return { blocked: false, tokenVersion: null };
  }
}

/** Отозван ли токен: `tv` в JWT должен совпадать с profiles.token_version. */
const isTokenCurrent = (payload: jwt.JwtPayload, state: { tokenVersion: number | null }): boolean =>
  state.tokenVersion === null || Number(payload.tv ?? 0) === state.tokenVersion;

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
  const state = await getAccountState(user.id);
  if (state.blocked) {
    return res.status(403).json({ error: 'Your account is blocked', code: 'ACCOUNT_BLOCKED' });
  }
  // SEC-02: бан/смена роли/восстановление инкрементируют token_version, и все
  // ранее выданные токены перестают проходить проверку.
  if (!isTokenCurrent(user, state)) {
    return res.status(401).json({ error: 'Token is not valid', code: 'TOKEN_REVOKED' });
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

  jwt.verify(token, secret, { algorithms: ['HS256'] }, async (err: any, user: any) => {
    try {
      if (!err && user && typeof user !== 'string') {
        const state = await getAccountState(user.id);
        if (!state.blocked && isTokenCurrent(user as jwt.JwtPayload, state)) {
          req.user = user;
          touchLastSeen(user.id);
        }
      }
    } catch (e) {
      console.error('[auth] optional token check failed', e);
    }
    next();
  });
};

export default authMiddleware;
