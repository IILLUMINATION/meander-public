import { Router, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import pool from '../config/database';
import { v4 as uuidv4 } from 'uuid';
import { OAuth2Client } from 'google-auth-library';
import dotenv from 'dotenv';
import { awardAchievement } from '../services/achievements';
import {
    exchangeGoogleCode,
    GoogleExchangeError,
    isLoopbackRedirect,
    isPkceVerifier,
} from '../services/google_exchange';
import authMiddleware, { AuthRequest } from '../middleware/auth';

dotenv.config();
const router = Router();
const jwtSecret = process.env.JWT_SECRET;

// OAuth client IDs accepted by the backend for the native app targets.
const GOOGLE_CLIENT_IDS = [
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_IOS_CLIENT_ID,
    process.env.GOOGLE_WINDOWS_CLIENT_ID,
    process.env.GOOGLE_DESKTOP_CLIENT_ID,
].filter((id): id is string => Boolean(id));

// Создаем клиента Google Auth (используя ID из .env как основной)
const client = new OAuth2Client(process.env.GOOGLE_CLIENT_ID);

// POST /auth/google/token
router.post('/google/token', async (req: Request, res: Response) => {
    const { idToken } = req.body;

    if (!idToken) {
        return res.status(400).json({ error: 'idToken is required' });
    }

    try {
        if (!jwtSecret) {
            return res.status(500).json({ error: 'Server auth is not configured' });
        }

        if (GOOGLE_CLIENT_IDS.length === 0) {
            return res.status(500).json({ error: 'Google auth is not configured' });
        }

        // 1. Проверяем токен, полученный от Flutter.
        // В audience передаем массив, чтобы сервер принимал токены со всех клиентов.
        const ticket = await client.verifyIdToken({
            idToken: idToken,
            audience: GOOGLE_CLIENT_IDS,
        });
        
        const payload = ticket.getPayload();

        if (!payload) {
            return res.status(401).json({ error: 'Invalid Google token' });
        }

        const { sub: google_id, email, name: full_name, picture: avatar_url } = payload;

        // 2. Ищем пользователя в нашей базе по google_id
        let userResult = await pool.query('SELECT * FROM profiles WHERE google_id = $1', [google_id]);

        let user;

        if (userResult.rows.length === 0) {
            // 3а. Если пользователя нет, создаем нового
            const newUserResult = await pool.query(
                'INSERT INTO profiles (id, google_id, full_name, email, avatar_url) VALUES ($1, $2, $3, $4, $5) RETURNING *',
                [uuidv4(), google_id, full_name, email, avatar_url]
            );
            user = newUserResult.rows[0];
            await awardAchievement(user.id, 'hello_world');
            console.log('New user created via Google Sign-In:', user.full_name);
        } else {
            // 3б. Если пользователь есть, берем его данные
            user = userResult.rows[0];
            console.log('User signed in via Google Sign-In:', user.full_name);
        }
        
        // 4. Создаем НАШ собственный JWT токен для API
        const appToken = jwt.sign(
            { id: user.id, role: user.role }, 
            jwtSecret, 
            { expiresIn: '7d' }
        );

        // 5. Отправляем токен и данные пользователя клиенту
        res.json({ token: appToken, user: user });

    } catch (error) {
        console.error('Error verifying Google token:', error);
        // Возвращаем понятную ошибку, а не просто 500, чтобы видеть в логах Flutter
        res.status(500).json({ error: 'Server error during token verification' });
    }
});

// POST /auth/google/exchange
// Desktop-вход: приложение присылает authorization code и PKCE verifier, а
// секрет клиента добавляет сервер. Сборке больше не нужен
// GOOGLE_DESKTOP_CLIENT_SECRET — и macOS/Linux/Windows собираются с чистого
// клона без локальных ключей.
router.post('/google/exchange', async (req: Request, res: Response) => {
    const { code, clientId, codeVerifier, redirectUri } = req.body ?? {};

    const desktopClientId = process.env.GOOGLE_DESKTOP_CLIENT_ID;
    const desktopClientSecret = process.env.GOOGLE_DESKTOP_CLIENT_SECRET;
    if (!desktopClientId || !desktopClientSecret) {
        return res.status(503).json({ error: 'Google desktop exchange is not configured' });
    }
    if (typeof code !== 'string' || code.length === 0 || code.length > 4096) {
        return res.status(400).json({ error: 'code is required' });
    }
    if (!isPkceVerifier(codeVerifier)) {
        return res.status(400).json({ error: 'codeVerifier is invalid' });
    }
    if (!isLoopbackRedirect(redirectUri)) {
        return res.status(400).json({ error: 'redirectUri must point to loopback' });
    }
    // Секрет привязан к конкретному client id. Google отклонил бы чужой id и
    // сам, но явная проверка даёт внятную причину вместо «invalid_client».
    if (clientId !== undefined && clientId !== desktopClientId) {
        return res.status(400).json({ error: 'clientId does not match this server' });
    }

    try {
        const idToken = await exchangeGoogleCode(
            { code, codeVerifier, redirectUri },
            { clientId: desktopClientId, clientSecret: desktopClientSecret },
        );
        res.json({ idToken });
    } catch (error) {
        if (error instanceof GoogleExchangeError) {
            console.error('Google desktop exchange failed:', error.message);
            return res.status(401).json({ error: 'Google token exchange failed' });
        }
        console.error('Google desktop exchange error:', error);
        res.status(502).json({ error: 'Google token exchange unavailable' });
    }
});

// ============================================================================
//  Удаление аккаунта по запросу владельца
// ============================================================================
//
// Требование App Store 5.1.1(v): приложение, которое умеет создавать аккаунт,
// обязано позволять удалить его прямо из приложения. Физически строку profiles
// вычищает фоновый sweep (services/account_deletion.ts) — здесь только заявка
// и отмена. Всё, что ссылается на profiles, в схеме обвешано ON DELETE CASCADE
// или SET NULL, поэтому удалении строки = удаление аккаунта атомарно.
//
// Столько дней человек вправе передумать: строка за это время остаётся на
// месте, отмена — просто NULL.
const DELETION_GRACE_DAYS = 3;
const MAX_DELETION_REASON_LENGTH = 500;

const remainingDays = (purgeAt: string | Date): number =>
    Math.max(0, Math.ceil((new Date(purgeAt).getTime() - Date.now()) / 86_400_000));

// GET /auth/account — текущее состояние удаления (для экрана настроек).
router.get('/account', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'No user' });

    try {
        const found = await pool.query(
            'SELECT deletion_purge_at, deletion_reason FROM profiles WHERE id = $1',
            [userId],
        );
        if (found.rowCount === 0) {
            return res.status(404).json({ error: 'Профиль не найден' });
        }
        const purgeAt = found.rows[0].deletion_purge_at as Date | null;
        res.json({
            deletion_scheduled_at: purgeAt,
            days_left: purgeAt ? remainingDays(purgeAt) : null,
            reason: found.rows[0].deletion_reason ?? null,
        });
    } catch (error) {
        console.error('Error reading account deletion state:', error);
        res.status(500).json({ error: 'Сервер занят, попробуйте чуть позже' });
    }
});

// DELETE /auth/account — запланировать удаление аккаунта.
router.delete('/account', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'No user' });

    const acknowledged = req.body?.acknowledged;
    const reason = req.body?.reason;
    if (acknowledged !== true) {
        return res.status(400).json({
            error: 'Нужно подтверждение удаления (acknowledged = true)',
        });
    }
    if (
        reason !== undefined &&
        (typeof reason !== 'string' || reason.length > MAX_DELETION_REASON_LENGTH)
    ) {
        return res.status(400).json({ error: 'Причина слишком длинная' });
    }

    const client = await pool.connect();
    try {
        // Администраторов из приложения удалять нельзя: вместе с профилем
        // каскадом уходят их посты, темы и модераторские отметки.
        const role = await client.query('SELECT role FROM profiles WHERE id = $1', [userId]);
        if (role.rowCount === 0) {
            return res.status(404).json({ error: 'Профиль не найден' });
        }
        if (role.rows[0].role === 'admin') {
            return res.status(403).json({
                error: 'Учётную запись администратора удаляет владелец сервиса',
            });
        }

        await client.query('BEGIN');
        const scheduled = await client.query(
            `UPDATE profiles
                SET deletion_purge_at = now() + ($2::int * interval '1 day'),
                    deletion_reason   = $3
              WHERE id = $1
                AND deletion_purge_at IS NULL
              RETURNING deletion_purge_at`,
            [userId, DELETION_GRACE_DAYS, reason ?? null],
        );
        if (scheduled.rowCount === 0) {
            await client.query('ROLLBACK');
            const open = await pool.query(
                'SELECT deletion_purge_at FROM profiles WHERE id = $1',
                [userId],
            );
            return res.status(409).json({
                error: 'Удаление уже запланировано',
                deletion_scheduled_at: open.rows[0]?.deletion_purge_at ?? null,
            });
        }

        await client.query(
            `INSERT INTO account_deletion_audit
                (user_id, purge_at, acknowledged, reason)
             VALUES ($1, $2::timestamptz, true, $3)`,
            [userId, scheduled.rows[0].deletion_purge_at, reason ?? null],
        );
        await client.query('COMMIT');

        console.log(
            `Account deletion scheduled for ${userId} (${DELETION_GRACE_DAYS} days)`,
        );
        res.json({
            deletion_scheduled_at: scheduled.rows[0].deletion_purge_at,
            days_left: DELETION_GRACE_DAYS,
        });
    } catch (error) {
        await client.query('ROLLBACK').catch(() => {});
        console.error('Error scheduling account deletion:', error);
        res.status(500).json({ error: 'Сервер занят, попробуйте чуть позже' });
    } finally {
        client.release();
    }
});

// POST /auth/account/restore — отменить удаление, пока срок не истёк.
router.post('/account/restore', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'No user' });

    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const cancelled = await client.query(
            `UPDATE profiles
                SET deletion_purge_at = NULL,
                    deletion_reason   = NULL
              WHERE id = $1
                AND deletion_purge_at IS NOT NULL
              RETURNING id`,
            [userId],
        );
        if (cancelled.rowCount === 0) {
            await client.query('ROLLBACK');
            return res.status(404).json({ error: 'Удаление не запланировано' });
        }
        await client.query(
            `UPDATE account_deletion_audit
                SET resolved_at = now(),
                    outcome     = 'cancelled'
              WHERE user_id = $1
                AND resolved_at IS NULL`,
            [userId],
        );
        await client.query('COMMIT');
        res.json({ restored: true });
    } catch (error) {
        await client.query('ROLLBACK').catch(() => {});
        console.error('Error cancelling account deletion:', error);
        res.status(500).json({ error: 'Сервер занят, попробуйте чуть позже' });
    } finally {
        client.release();
    }
});

export default router;
