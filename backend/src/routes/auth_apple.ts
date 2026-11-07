import { Router, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import crypto from 'crypto';
import pool from '../config/database';
import { v4 as uuidv4 } from 'uuid';
import dotenv from 'dotenv';
import { awardAchievement } from '../services/achievements';

dotenv.config();

const router = Router();
const jwtSecret = process.env.JWT_SECRET;

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_JWKS_URL = `${APPLE_ISSUER}/auth/keys`;
const JWKS_TTL_MS = 60 * 60 * 1000;
// Принудительное обновление по неизвестному kid ограничиваем, чтобы поддельный
// заголовок не заставил нас долбить JWKS Apple.
const FORCED_REFRESH_COOLDOWN_MS = 60 * 1000;
const ALLOWED_ALGS = ['RS256', 'ES256'];

interface AppleJwk {
  kid: string;
  alg?: string;
  kty: string;
  [key: string]: unknown;
}

interface ApplePayload extends jwt.JwtPayload {
  email?: string;
  is_private_email?: string | boolean;
  email_verified?: string | boolean;
  nonce?: string;
}

// Аудитория identity token нативного iOS-приложения — bundle id; Service ID
// пригодится, если включим веб-редирект. Оба принимаем.
const APPLE_BUNDLE_ID = process.env.APPLE_BUNDLE_ID || 'com.IILLUMINAT.meadner';
const APPLE_AUDIENCES: [string, ...string[]] = process.env.APPLE_SERVICE_ID
  ? [process.env.APPLE_SERVICE_ID, APPLE_BUNDLE_ID]
  : [APPLE_BUNDLE_ID];

let jwksCache: { keys: AppleJwk[]; fetchedAt: number } = { keys: [], fetchedAt: 0 };
let lastForcedRefreshAt = 0;

async function getAppleKeys(forceRefresh: boolean): Promise<AppleJwk[]> {
  const isFresh = Date.now() - jwksCache.fetchedAt < JWKS_TTL_MS;
  if (!forceRefresh && isFresh && jwksCache.keys.length > 0) return jwksCache.keys;
  if (forceRefresh && jwksCache.keys.length > 0 && Date.now() - lastForcedRefreshAt < FORCED_REFRESH_COOLDOWN_MS) {
    return jwksCache.keys;
  }

  lastForcedRefreshAt = Date.now();
  const res = await fetch(APPLE_JWKS_URL, {
    headers: { accept: 'application/json' },
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) {
    throw Object.assign(new Error(`Apple JWKS failed: ${res.status}`), { status: 502 });
  }
  const data = (await res.json()) as { keys?: AppleJwk[] };
  if (!Array.isArray(data.keys) || data.keys.length === 0) {
    throw Object.assign(new Error('Apple JWKS returned no keys'), { status: 502 });
  }
  jwksCache = { keys: data.keys, fetchedAt: Date.now() };
  return jwksCache.keys;
}

function jwkToPem(jwk: AppleJwk): string {
  return crypto
    .createPublicKey({ key: jwk as unknown as crypto.JsonWebKey, format: 'jwk' })
    .export({ type: 'spki', format: 'pem' }) as string;
}

function fail(status: number, message: string): Error {
  return Object.assign(new Error(message), { status });
}

async function verifyAppleIdentityToken(idToken: string, rawNonce?: string): Promise<ApplePayload> {
  const decoded = jwt.decode(idToken, { complete: true });
  const kid = decoded?.header?.kid;
  const alg = decoded?.header?.alg;
  if (!kid || typeof alg !== 'string' || !ALLOWED_ALGS.includes(alg)) {
    throw fail(401, 'Unexpected Apple token header');
  }

  let jwk = (await getAppleKeys(false)).find((k) => k.kid === kid);
  if (!jwk) {
    jwk = (await getAppleKeys(true)).find((k) => k.kid === kid);
  }
  if (!jwk) {
    throw fail(401, 'Apple signing key not found');
  }

  const payload = jwt.verify(idToken, jwkToPem(jwk), {
    algorithms: [alg as jwt.Algorithm],
    issuer: APPLE_ISSUER,
    audience: APPLE_AUDIENCES,
  }) as ApplePayload;

  // Nonce обязателен: без него пересланный чужой identity token дали бы доступ
  // к чужому аккаунту. Клиент генерит nonce, отправляет нам его в открытом виде,
  // а Apple возвращает его SHA-256 внутри токена.
  if (!rawNonce || !payload.nonce) {
    throw fail(401, 'Missing nonce');
  }
  const digest = crypto.createHash('sha256').update(rawNonce, 'utf8').digest();
  const expected = [digest.toString('base64url'), digest.toString('hex')];
  const provided = String(payload.nonce);
  // Base64url без padding — канонический вид; hex допускаем, потому что часть
  // примеров от Apple хэширует именно так, а разница для нас безопасна:
  // и то, и другое — образ одного и того же nonce.
  const matched = expected.some(
    (value) =>
      value.length === provided.length &&
      crypto.timingSafeEqual(Buffer.from(value), Buffer.from(provided)),
  );
  if (!matched) {
    throw fail(401, 'Nonce mismatch');
  }

  if (!payload.sub) {
    throw fail(401, 'Apple token has no subject');
  }
  return payload;
}

function normalizeName(body: { firstName?: string; lastName?: string; fullName?: string }): string | null {
  // Apple отдаёт имя только при первой авторизации, поэтому его присылает клиент.
  const fromParts = [body.firstName, body.lastName]
    .map((p) => (typeof p === 'string' ? p.trim() : ''))
    .filter(Boolean)
    .join(' ');
  const raw = fromParts || (typeof body.fullName === 'string' ? body.fullName.trim() : '');
  if (!raw) return null;
  return raw.slice(0, 120);
}

const isTruthyFlag = (value: string | boolean | undefined): boolean =>
  value === true || value === 'true' || value === '1';

// POST /auth/apple/token
// { idToken: string, nonce: string, firstName?, lastName?, fullName? }
router.post('/apple/token', async (req: Request, res: Response) => {
  const { idToken, nonce } = req.body as { idToken?: string; nonce?: string };

  if (!idToken) {
    return res.status(400).json({ error: 'idToken is required' });
  }
  if (!jwtSecret) {
    return res.status(500).json({ error: 'Server auth is not configured' });
  }

  try {
    const payload = await verifyAppleIdentityToken(idToken, nonce);

    const appleId = String(payload.sub);
    const email: string | null = payload.email ?? null;
    const emailRelayed = isTruthyFlag(payload.is_private_email);
    const fullName = normalizeName(req.body as Record<string, string>);

    // Без линка по email (по просьбе): ищем только по apple_id.
    let userResult = await pool.query('SELECT * FROM profiles WHERE apple_id = $1', [appleId]);
    let user;

    if (userResult.rows.length === 0) {
      // email UNIQUE может быть занят google/yandex-акком — тогда оставляем
      // нового пользователя без email, линкинга сознательно нет.
      let emailToInsert = email;
      if (emailToInsert) {
        const emailExists = await pool.query('SELECT id FROM profiles WHERE email = $1', [emailToInsert]);
        if (emailExists.rows.length > 0) emailToInsert = null;
      }
      const newUserResult = await pool.query(
        'INSERT INTO profiles (id, apple_id, full_name, email, apple_email_relayed) VALUES ($1, $2, $3, $4, $5) RETURNING *',
        [uuidv4(), appleId, fullName, emailToInsert, emailRelayed],
      );
      user = newUserResult.rows[0];
      await awardAchievement(user.id, 'hello_world');
      console.log('New user created via Sign in with Apple:', user.full_name);
    } else {
      user = userResult.rows[0];
      // Имя и флаг релея приходят только при первой авторизации — обновляем
      // best-effort, существующие данные не затираем.
      try {
        await pool.query(
          'UPDATE profiles SET full_name = COALESCE($2, full_name), apple_email_relayed = COALESCE($3, apple_email_relayed) WHERE id = $1',
          [user.id, fullName, emailRelayed],
        );
        user.full_name = fullName || user.full_name;
      } catch (_) {}
      console.log('User signed in via Sign in with Apple:', user.full_name);
    }

    const appToken = jwt.sign({ id: user.id, role: user.role, tv: user.token_version ?? 0 }, jwtSecret, { expiresIn: '7d' });

    res.json({ token: appToken, user });
  } catch (error: any) {
    if (error.status === 401) {
      return res.status(401).json({ error: 'Invalid Apple token' });
    }
    if (error.status === 502) {
      return res.status(502).json({ error: 'Apple is unreachable, try again' });
    }
    console.error('Error verifying Apple token:', error);
    res.status(500).json({ error: 'Server error during Apple token verification' });
  }
});

export default router;
