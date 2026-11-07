import { Router, Response, Request, NextFunction } from 'express';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import multer from 'multer';
import fs from 'fs';
import os from 'os';
import path from 'path';
import pool from '../config/database';
import authMiddleware, { AuthRequest, optionalAuthMiddleware } from '../middleware/auth';
import { createNotification } from '../services/notifications';
import { validate as uuidValidate, v4 as uuidv4 } from 'uuid';
import { decryptToken, encryptToken } from '../services/sync_settings_crypto';
import { awardAchievement } from '../services/achievements';
import { isStaff } from '../services/visibility';
import { clientIp } from '../services/client_ip';
import { grantDueRewards, rewardProgress } from '../services/rewards';
import { uploadImage, UnsupportedImageError, acceptsImagePartMime } from '../services/image_host';
import {
    COSMETICS,
    equippedFor,
    findMissingGrants,
    legacyBannerStyle,
    listGrants,
    validateEquipped,
} from '../services/cosmetics';

const router = Router();

// Пул маленький (max 10) и ждёт освобождения соединения всего 2 с, то есть
// connect() отказывает именно в момент нагрузки. Снаружи try это
// необработанный промис: Express 4 не отвечает ничего, клиент висит до своего
// таймаута. Отказ пула превращаем в честный 503.
const acquireClient = async (res: Response, tag: string) => {
    try {
        return await pool.connect();
    } catch (err) {
        console.error(`${tag}: pool acquire failed:`, err);
        res.status(503).json({ error: 'Сервер занят, попробуйте чуть позже' });
        return null;
    }
};

// =======================================================================
//  Профиль: банеры и соцсети — валидация
// =======================================================================

/// Список допустимых id пресетов баннеров (соответствует Dart: banner_presets.dart).
const ALLOWED_BANNER_IDS = new Set([
    'beige', 'forest', 'royal_purple', 'sunset', 'ocean', 'rose',
    'cyber', 'mono', 'aurora',
]);

/// Разрешённые платформы соцсетей.
const ALLOWED_SOCIAL_PLATFORMS = new Set([
    'telegram', 'youtube', 'vk', 'instagram', 'twitter', 'x',
    'github', 'boosty', 'discord', 'website', 'tiktok',
]);

const MAX_SOCIAL_LINKS = 8;
const MAX_URL_LENGTH = 500;

interface BannerStyle {
    type: 'preset';
    id: string;
}

interface SocialLink {
    platform: string;
    url: string;
}

/**
 * Нормализует и валидирует banner_style.
 * Возвращает корректный объект или `null`, если входные данные пустые/некорректные.
 * Бросает `Error`, если структура неправильная.
 */
function validateBannerStyle(value: any): BannerStyle | null {
    if (value === null || value === undefined) return null;
    if (typeof value !== 'object') {
        throw new Error('banner_style must be an object');
    }
    const type = value.type;
    if (type !== 'preset') {
        throw new Error('banner_style.type must be "preset"');
    }
    const id = value.id;
    if (typeof id !== 'string' || !ALLOWED_BANNER_IDS.has(id)) {
        throw new Error(`banner_style.id "${id}" is not allowed`);
    }
    return { type: 'preset', id };
}

/**
 * Нормализует и валидирует social_links.
 */
function validateSocialLinks(value: any): SocialLink[] {
    if (value === null || value === undefined) return [];
    if (!Array.isArray(value)) {
        throw new Error('social_links must be an array');
    }
    if (value.length > MAX_SOCIAL_LINKS) {
        throw new Error(`social_links exceeds maximum (${MAX_SOCIAL_LINKS})`);
    }
    const result: SocialLink[] = [];
    for (const item of value) {
        if (!item || typeof item !== 'object') continue;
        const platform = String(item.platform || '').toLowerCase().trim();
        const url = String(item.url || '').trim();
        if (!ALLOWED_SOCIAL_PLATFORMS.has(platform)) {
            throw new Error(`social_links: unknown platform "${platform}"`);
        }
        if (url.length === 0 || url.length > MAX_URL_LENGTH) {
            throw new Error(`social_links: invalid url for "${platform}"`);
        }
        // Простейшая защита: разрешаем только http(s) ссылки.
        if (!/^https?:\/\//i.test(url)) {
            throw new Error(`social_links: url must start with http:// or https://`);
        }
        result.push({ platform, url });
    }
    return result;
}

// GET /profiles/sync-settings
router.get('/sync-settings', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });

    try {
        const q = await pool.query(
            `SELECT github_enabled, github_owner, github_repo, github_branch, github_root_path,
                    github_token_ciphertext, github_token_iv, github_token_tag
             FROM profile_sync_settings
             WHERE user_id = $1`,
            [userId]
        );

        if (q.rows.length === 0) {
            return res.json({
                github: {
                    enabled: false,
                    token: '',
                    owner: '',
                    repo: '',
                    branch: 'main',
                    rootPath: 'meander-sync'
                }
            });
        }

        const row = q.rows[0];
        const token = decryptToken(
            row.github_token_ciphertext,
            row.github_token_iv,
            row.github_token_tag
        );

        return res.json({
            github: {
                enabled: row.github_enabled === true,
                token,
                owner: row.github_owner || '',
                repo: row.github_repo || '',
                branch: row.github_branch || 'main',
                rootPath: row.github_root_path || 'meander-sync'
            }
        });
    } catch (err) {
        console.error('sync-settings GET error:', err);
        return res.status(500).json({ error: 'Server error getting sync settings' });
    }
});

// POST /profiles/sync-settings
router.post('/sync-settings', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });

    const github = req.body?.github ?? {};
    const enabled = github.enabled === true;
    const owner = (github.owner ?? '').toString().trim();
    const repo = (github.repo ?? '').toString().trim();
    const branchRaw = (github.branch ?? 'main').toString().trim();
    const branch = branchRaw.length > 0 ? branchRaw : 'main';
    const rootPathRaw = (github.rootPath ?? 'meander-sync').toString().trim();
    const rootPath = rootPathRaw.length > 0 ? rootPathRaw : 'meander-sync';
    const tokenRaw = (github.token ?? '').toString();

    if (owner.length > 100 || repo.length > 150 || branch.length > 100 || rootPath.length > 200) {
        return res.status(400).json({ error: 'Sync settings fields are too long' });
    }

    if (enabled && (!owner || !repo || !branch)) {
        return res.status(400).json({ error: 'Owner/repo/branch are required when sync is enabled' });
    }

    try {
        const encrypted = tokenRaw.trim().length > 0 ? encryptToken(tokenRaw) : {
            ciphertext: '',
            iv: '',
            tag: ''
        };

        const upsert = `
            INSERT INTO profile_sync_settings (
                user_id, github_enabled, github_owner, github_repo, github_branch, github_root_path,
                github_token_ciphertext, github_token_iv, github_token_tag, updated_at
            ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,NOW())
            ON CONFLICT (user_id) DO UPDATE SET
                github_enabled = EXCLUDED.github_enabled,
                github_owner = EXCLUDED.github_owner,
                github_repo = EXCLUDED.github_repo,
                github_branch = EXCLUDED.github_branch,
                github_root_path = EXCLUDED.github_root_path,
                github_token_ciphertext = EXCLUDED.github_token_ciphertext,
                github_token_iv = EXCLUDED.github_token_iv,
                github_token_tag = EXCLUDED.github_token_tag,
                updated_at = NOW()
            RETURNING user_id, github_enabled, github_owner, github_repo, github_branch, github_root_path
        `;

        const result = await pool.query(upsert, [
            userId,
            enabled,
            owner || null,
            repo || null,
            branch,
            rootPath,
            encrypted.ciphertext || null,
            encrypted.iv || null,
            encrypted.tag || null
        ]);

        return res.json({
            success: true,
            github: {
                enabled: result.rows[0].github_enabled === true,
                owner: result.rows[0].github_owner || '',
                repo: result.rows[0].github_repo || '',
                branch: result.rows[0].github_branch || 'main',
                rootPath: result.rows[0].github_root_path || 'meander-sync'
            }
        });
    } catch (err) {
        console.error('sync-settings POST error:', err);
        return res.status(500).json({ error: 'Server error saving sync settings' });
    }
});

// GET /profiles/author-notifs-settings
router.get('/author-notifs-settings', authMiddleware, async (req: AuthRequest, res: Response) => {
    try {
        const userId = req.user!.id;
        const result = await pool.query(
            `SELECT author_notifs_mode, author_notifs_exceptions 
             FROM profiles 
             WHERE id = $1`,
            [userId]
        );
        
        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Profile not found' });
        }
        
        return res.json({
            mode: result.rows[0].author_notifs_mode || 'all',
            exceptions: result.rows[0].author_notifs_exceptions || []
        });
    } catch (err) {
        console.error('author-notifs-settings GET error:', err);
        return res.status(500).json({ error: 'Server error getting author notifs settings' });
    }
});

// POST /profiles/author-notifs-settings
router.post('/author-notifs-settings', authMiddleware, async (req: AuthRequest, res: Response) => {
    try {
        const userId = req.user!.id;
        const { mode, exceptions } = req.body;

        if (mode !== 'all' && mode !== 'none') {
            return res.status(400).json({ error: 'Invalid mode' });
        }

        if (!Array.isArray(exceptions)) {
            return res.status(400).json({ error: 'Exceptions must be an array' });
        }

        // Optional: validate UUIDs in exceptions array
        const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        const validExceptions = exceptions.filter(id => typeof id === 'string' && uuidRegex.test(id));

        await pool.query(
            `UPDATE profiles 
             SET author_notifs_mode = $1, author_notifs_exceptions = $2
             WHERE id = $3`,
            [mode, validExceptions, userId]
        );

        return res.json({ success: true, mode, exceptions: validExceptions });
    } catch (err) {
        console.error('author-notifs-settings POST error:', err);
        return res.status(500).json({ error: 'Server error saving author notifs settings' });
    }
});

// =======================================================================
//  Оформление профиля: что надето и чем владею
// =======================================================================

// GET /profiles/cosmetics/mine
// Права живут на бэке, поэтому клиент не «разблокирует» предметы сам:
// без строки в user_cosmetics он увидит их в витрине закрытыми.
router.get('/cosmetics/mine', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: "Unauthorized" });

    try {
        const [equipped, granted] = await Promise.all([
            equippedFor(userId),
            listGrants(userId),
        ]);
        res.json({ equipped, granted });
    } catch (err) {
        console.error('cosmetics/mine error:', err);
        res.status(500).json({ error: 'Server error loading cosmetics' });
    }
});

// GET /profiles/:id (Обновленный SQL запрос)
router.get('/:id', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" });

    try {
        // ДОБАВЛЕНЫ ПОЛЯ: streak_count, last_activity_date, banner_style, social_links
        const profileQuery = `
            SELECT 
                p.id, p.full_name, p.avatar_url, p.created_at, p.bio, 
                p.is_verified, p.role, p.ad_free_until,
                p.streak_count, p.last_activity_date, p.last_seen_at,
                p.banner_style, p.social_links, p.show_nsfw, p.cosmetics,
                p.quiet_hours_enabled, p.timezone_offset,
                p.total_playtime_seconds,
                (SELECT COUNT(*)::int FROM user_followers WHERE user_id = p.id) as followers_count,
                (SELECT COUNT(*)::int FROM user_followers WHERE follower_id = p.id) as following_count,
                (SELECT COALESCE(SUM(like_count), 0)::int FROM quests WHERE author_id = p.id) as total_likes,
                (SELECT COALESCE(SUM(downloads_count), 0)::int FROM quests WHERE author_id = p.id) as total_downloads,
                (SELECT COALESCE(SUM(playtime_seconds), 0)::int FROM user_quest_playtime WHERE user_id = p.id) as total_quests_playtime_seconds
            FROM profiles p
            WHERE p.id = $1;
        `;
        const profile = await pool.query(profileQuery, [id]);

        if (profile.rows.length === 0) {
            return res.status(404).json({ error: 'Profile not found' });
        }
        const row = profile.rows[0];
        // Своя карточка и стафф видят полный профиль; остальным отдаём только
        // публичные поля — без роли, приватности, последней активности и playtime.
        if (req.user?.id === id || (await isStaff(req))) {
            return res.json(row);
        }
        const publicProfile: any = { ...row };
        for (const field of [
            'role',
            'last_seen_at',
            'timezone_offset',
            'quiet_hours_enabled',
            'show_nsfw',
            'ad_free_until',
            'total_playtime_seconds',
            'total_quests_playtime_seconds',
        ]) {
            delete publicProfile[field];
        }
        return res.json(publicProfile);
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Server error getting profile' });
    }
});

// POST /profiles/update-streak (НОВЫЙ РОУТ)
router.post('/update-streak', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: "Unauthorized" });

    const client = await acquireClient(res, 'streak update');
    if (!client) return;

    try {
        await client.query('BEGIN');

        // Блокируем строку для обновления (FOR UPDATE), чтобы избежать гонки запросов
        const userRes = await client.query(
            "SELECT streak_count, last_activity_date FROM profiles WHERE id = $1 FOR UPDATE", 
            [userId]
        );

        if (userRes.rows.length === 0) {
            await client.query('ROLLBACK');
            return res.status(404).json({ error: "User not found" });
        }

        const { streak_count, last_activity_date } = userRes.rows[0];
        
        const now = new Date();
        const todayStr = now.toISOString().split('T')[0]; // "YYYY-MM-DD"
        
        let newStreak = streak_count || 0;
        let streakUpdated = false;

        if (!last_activity_date) {
            // Первый заход вообще
            newStreak = 1;
            streakUpdated = true;
        } else {
            // Конвертируем дату из БД в строку YYYY-MM-DD
            const lastDate = new Date(last_activity_date);
            const lastDateStr = lastDate.toISOString().split('T')[0];

            if (lastDateStr === todayStr) {
                // Уже заходил сегодня
                streakUpdated = false;
            } else {
                // Проверяем, был ли заход вчера
                const yesterday = new Date(now);
                yesterday.setDate(now.getDate() - 1);
                const yesterdayStr = yesterday.toISOString().split('T')[0];

                if (lastDateStr === yesterdayStr) {
                    // Заходил вчера -> серия продолжается
                    newStreak += 1;
                    streakUpdated = true;
                } else {
                    // Пропустил день -> сброс серии
                    newStreak = 1;
                    streakUpdated = true;
                }
            }
        }

        if (streakUpdated) {
            await client.query(
                "UPDATE profiles SET streak_count = $1, last_activity_date = $2 WHERE id = $3",
                [newStreak, todayStr, userId]
            );
        }

        await client.query('COMMIT');

        res.json({ 
            success: true, 
            streak_updated: streakUpdated, 
            current_streak: newStreak 
        });

    } catch (err) {
        await client.query('ROLLBACK');
        console.error("Streak update error:", err);
        res.status(500).json({ error: "Server error" });
    } finally {
        client.release();
    }
});

// POST /profiles/me (Обновление профиля)
router.post('/me', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    const { full_name, bio, banner_style, social_links, cosmetics } = req.body;

    if (!userId) return res.status(401).json({ error: "Unauthorized" });

    try {
        const updates: string[] = [];
        const values: any[] = [];
        let paramIndex = 1;

        if (full_name !== undefined) {
            updates.push(`full_name = $${paramIndex}`);
            values.push(full_name);
            paramIndex++;
        }

        if (bio !== undefined) {
            updates.push(`bio = $${paramIndex}`);
            values.push(bio);
            paramIndex++;
        }

        if (banner_style !== undefined) {
            try {
                const cleaned = validateBannerStyle(banner_style);
                updates.push(`banner_style = $${paramIndex}`);
                values.push(cleaned ? JSON.stringify(cleaned) : null);
                paramIndex++;
            } catch (e: any) {
                return res.status(400).json({ error: e.message });
            }
        }

        if (social_links !== undefined) {
            try {
                const cleaned = validateSocialLinks(social_links);
                updates.push(`social_links = $${paramIndex}::jsonb`);
                values.push(JSON.stringify(cleaned));
                paramIndex++;
            } catch (e: any) {
                return res.status(400).json({ error: e.message });
            }
        }

        if (cosmetics !== undefined) {
            try {
                const equipped = validateEquipped(cosmetics);
                const worn = Object.values(equipped).filter(Boolean) as string[];
                const missing = await findMissingGrants(userId, worn);
                if (missing.length > 0) {
                    return res.status(403).json({
                        error: `Нет права на оформление: ${missing.join(', ')}`,
                    });
                }
                updates.push(`cosmetics = $${paramIndex}::jsonb`);
                values.push(JSON.stringify(equipped));
                paramIndex++;

                // Старые версии приложения понимают только banner_style,
                // поэтому статичный пресет дублируем в прежнюю колонку.
                const legacy = legacyBannerStyle(equipped);
                if (legacy) {
                    updates.push(`banner_style = $${paramIndex}::jsonb`);
                    values.push(JSON.stringify(legacy));
                    paramIndex++;
                }
            } catch (e: any) {
                return res.status(400).json({ error: e.message });
            }
        }

        if (req.body.show_nsfw !== undefined) {
            updates.push(`show_nsfw = $${paramIndex}`);
            values.push(Boolean(req.body.show_nsfw));
            paramIndex++;
        }

        if (req.body.quiet_hours_enabled !== undefined) {
            updates.push(`quiet_hours_enabled = $${paramIndex}`);
            values.push(Boolean(req.body.quiet_hours_enabled));
            paramIndex++;
        }

        if (req.body.timezone_offset !== undefined) {
            updates.push(`timezone_offset = $${paramIndex}`);
            values.push(Number(req.body.timezone_offset));
            paramIndex++;
        }

        if (updates.length === 0) {
            return res.status(400).json({ error: "No fields to update" });
        }

        values.push(userId);
        const query = `UPDATE profiles SET ${updates.join(', ')} WHERE id = $${paramIndex} RETURNING *`;

        const result = await pool.query(query, values);
        res.json(result.rows[0]);

    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Server error updating profile' });
    }
});

// =======================================================================
//  Аватар: свой файл с автоматическим отсевом
// =======================================================================

const AVATAR_MAX_BYTES = 2 * 1024 * 1024;
const AVATAR_MIN_ACCOUNT_AGE_DAYS = 7;
const AVATAR_CHANGES_PER_DAY = 3;

/**
 * Пороги «положения в сообществе» — единственная защита аватара: содержимое
 * картинки сервер не смотрит. Любой пункт считается достаточным: смысл не в
 * том, чтобы измерить человека одним числом, а в том, чтобы свежий
 * аккаунт-пустышка (то, чем пользуются спамеры) аватар так быстро не получил.
 */
const AVATAR_STANDING_FOLLOWERS = 5;
const AVATAR_STANDING_PUBLISHED = 1;
const AVATAR_STANDING_REVIEWS = 3;
const AVATAR_STREAK_DAYS = 5;
const AVATAR_STANDING_SECONDS = 3 * 3600;
const AVATAR_STANDING_HINT =
    'Аватар доступен, когда в сообществе есть история: 5 подписчиков, '
    + 'опубликованный квест, 3 отзыва, стрик 5 дней или 3 часа в играх.';
const AVATAR_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.webp']);

const avatarUpload = multer({
    storage: multer.diskStorage({
        destination: (req, file, cb) => cb(null, os.tmpdir()),
        filename: (req, file, cb) => {
            const ext = path.extname(file.originalname || '').toLowerCase();
            cb(null, `mnd-avatar-${uuidv4()}${AVATAR_EXTENSIONS.has(ext) ? ext : '.jpg'}`);
        },
    }),
    fileFilter: (req, file, cb) => {
        const ext = path.extname(file.originalname || '').toLowerCase();
        // Тип части клиент обязан объявить, но полагаться на него нельзя:
        // настоящее решение принимает checkMagicBytes в image_host.ts.
        if (!AVATAR_EXTENSIONS.has(ext) || !acceptsImagePartMime(file.mimetype)) {
            return cb(new Error('Можно загрузить jpg, png или webp'));
        }
        cb(null, true);
    },
    limits: { fileSize: AVATAR_MAX_BYTES, files: 1 },
});

const logAvatarChange = async (
    userId: string,
    avatarUrl: string | null,
    verdict: string,
    reason: string | null
): Promise<void> => {
    try {
        await pool.query(
            `INSERT INTO avatar_changes (user_id, avatar_url, verdict, reason)
             VALUES ($1, $2, $3, $4)`,
            [userId, avatarUrl, verdict, reason]
        );
    } catch (e) {
        // Журнал не должен ломать ответ пользователю.
        console.error('avatar_changes log failed:', e);
    }
};

/**
 * Есть ли у аккаунта история в сообществе: подписчики, опубликованный квест,
 * оставленные отзывы, стрик или несколько часов игры.
 */
const hasAvatarStanding = async (userId: string): Promise<boolean> => {
    const standing = await pool.query(
        `SELECT
            (SELECT COUNT(*)::int FROM user_followers WHERE user_id = p.id) AS followers,
            (SELECT COUNT(*)::int FROM quests WHERE author_id = p.id AND status = 'published') AS published,
            (SELECT COUNT(*)::int FROM reviews WHERE author_id = p.id) AS reviews,
            p.streak_count,
            p.total_playtime_seconds
           FROM profiles p WHERE p.id = $1`,
        [userId]
    );
    const r = standing.rows[0];
    if (!r) return false;
    return r.followers >= AVATAR_STANDING_FOLLOWERS
        || r.published >= AVATAR_STANDING_PUBLISHED
        || r.reviews >= AVATAR_STANDING_REVIEWS
        || (r.streak_count || 0) >= AVATAR_STREAK_DAYS
        || (r.total_playtime_seconds || 0) >= AVATAR_STANDING_SECONDS;
};

// Ошибки multer (размер, тип) долетают до глобального хэндлера и превращаются
// в безликое 500 — переводим их в понятный отказ до входа в роут.
const uploadAvatarFile = (req: Request, res: Response, next: NextFunction) => {
    avatarUpload.single('file')(req, res, (err: any) => {
        if (err) {
            const msg = err.code === 'LIMIT_FILE_SIZE'
                ? 'Картинка больше 2 МБ — выберите меньшую'
                : (err.message || 'Не удалось прочитать файл');
            return res.status(400).json({ error: msg });
        }
        next();
    });
};

// POST /profiles/me/avatar (multipart, поле «file»)
//
// Отсека три: возраст аккаунта, привязанный внешний вход, частота смены, плюс
// история в сообществе. Содержимое картинки сервер не проверяет — смотрит
// сообщество: аватар сразу виден всем, на него работает жалоба.
router.post('/me/avatar', authMiddleware, uploadAvatarFile, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    const file = req.file;
    const tempPath = file?.path;

    if (!userId) {
        if (tempPath) fs.unlink(tempPath, () => {});
        return res.status(401).json({ error: 'Unauthorized' });
    }

    try {
        if (!file) return res.status(400).json({ error: 'Прикрепите файл картинки' });

        const me = await pool.query(
            `SELECT created_at, role, is_blocked, is_verified,
                    google_id, yandex_id, telegram_id, apple_id
               FROM profiles WHERE id = $1`,
            [userId]
        );
        if (me.rows.length === 0) return res.status(404).json({ error: 'Профиль не найден' });
        const p = me.rows[0];
        const isStaff = p.role === 'admin' || p.role === 'moderator';

        if (p.is_blocked) {
            return res.status(403).json({ error: 'Профиль заблокирован — аватар недоступен' });
        }

        if (!isStaff) {
            const ageDays = (Date.now() - new Date(p.created_at).getTime()) / 86_400_000;
            if (ageDays < AVATAR_MIN_ACCOUNT_AGE_DAYS) {
                return res.status(403).json({
                    error: `Свой аватар можно ставить через ${AVATAR_MIN_ACCOUNT_AGE_DAYS} дней после регистрации`,
                });
            }
            const linked = [p.google_id, p.yandex_id, p.telegram_id, p.apple_id].some(Boolean);
            if (!linked && !p.is_verified) {
                return res.status(403).json({
                    error: 'Аватар доступен аккаунтам со входом через Google, Яндекс, Telegram или Apple',
                });
            }
            const recent = await pool.query(
                `SELECT count(*)::int AS n FROM avatar_changes
                  WHERE user_id = $1 AND verdict = 'approved'
                    AND created_at > NOW() - INTERVAL '24 hours'`,
                [userId]
            );
            if (recent.rows[0].n >= AVATAR_CHANGES_PER_DAY) {
                return res.status(429).json({
                    error: `Менять аватар можно не чаще ${AVATAR_CHANGES_PER_DAY} раз в сутки`,
                });
            }
            // Содержимое картинки никто не смотрит, поэтому право на аватар
            // даёт история в сообществе: новичок с нулём активности — самый
            // дешёвый канал для спама. Дальше аватар виден всем и на него можно
            // пожаловаться.
            if (!(await hasAvatarStanding(userId))) {
                return res.status(403).json({ error: AVATAR_STANDING_HINT });
            }
        }

        const url = await uploadImage(file.path);
        await pool.query(
            `UPDATE profiles SET avatar_url = $2, avatar_custom = TRUE WHERE id = $1`,
            [userId, url]
        );
        await logAvatarChange(userId, url, 'approved', 'Проверка ИИ отключена');

        await awardAchievement(userId, 'profile_pic');

        res.json({ success: true, avatar_url: url });
    } catch (e) {
        console.error('avatar upload:', e);
        if (e instanceof UnsupportedImageError) {
            return res.status(415).json({ error: 'Это не похоже на картинку — поддерживаются jpg, png и webp' });
        }
        res.status(500).json({ error: 'Не удалось загрузить аватар' });
    } finally {
        if (tempPath) fs.unlink(tempPath, () => {});
    }
});

// GET /profiles/me/rewards — награды за активность и прогресс к ним.
//
// Экран сам провоцирует выдачу: человек открыл список наград, значит его
// стоит и поздравить с тем, что уже открылось. Держим это в одном запросе,
// чтобы не плодить «сначала проверь, потом забери».
router.get('/me/rewards', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });

    try {
        // Последовательно, не в Promise.all: прогресс читается уже после
        // выдачи, иначе только что закрытая награда показали бы как «не твоя»
        // рядом со снекбаром «награда ваша».
        const grantedNow = await grantDueRewards(userId);
        const progress = await rewardProgress(userId);
        res.json({
            granted_now: grantedNow,
            rules: progress.map((p) => ({
                id: p.rule.id,
                metric: p.rule.metric,
                threshold: p.rule.threshold,
                title: p.rule.title,
                hint: p.rule.hint,
                cosmetics: p.rule.cosmetics,
                current: p.current,
                done: p.done,
                granted_at: p.grantedAt,
            })),
        });
    } catch (e) {
        console.error('rewards list:', e);
        res.status(500).json({ error: 'Server error getting rewards' });
    }
});

// SEC-15: перебор промокодов. Ключ — пользователь, для анонимов — IP.
const redeemLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 10,
    keyGenerator: (req) => {
        const userId = (req as AuthRequest).user?.id;
        return userId ? `redeem_${userId}` : `redeem_ip_${ipKeyGenerator(clientIp(req))}`;
    },
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Слишком много попыток. Попробуйте позже.' },
});

// POST /profiles/redeem (Промокоды)
router.post('/redeem', authMiddleware, redeemLimiter, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    const { code } = req.body;

    if (!userId) return res.status(401).json({ error: "Unauthorized" });
    if (!code) return res.status(400).json({ error: "Code is required" });

    const client = await acquireClient(res, 'promo redeem');
    if (!client) return;

    try {
        await client.query('BEGIN');

        // 1. Ищем код. FOR UPDATE: без блокировки два параллельных активатора
        // читали один и тот же current_uses и оба проходили проверку лимита,
        // то есть последний слот выдавался дважды.
        const codeRes = await client.query(
            "SELECT * FROM promo_codes WHERE code = $1 AND is_active = TRUE FOR UPDATE", 
            [code]
        );

        if (codeRes.rows.length === 0) {
            await client.query('ROLLBACK');
            return res.status(400).json({ error: "Неверный или недоступный код" });
        }

        const promo = codeRes.rows[0];

        // 2. Проверяем лимит использований
        if (promo.current_uses >= promo.max_uses) {
            await client.query('ROLLBACK');
            return res.status(400).json({ error: "Неверный или недоступный код" });
        }

        // 3. Проверяем, активировал ли уже этот юзер
        const usageCheck = await client.query(
            "SELECT 1 FROM promo_code_usages WHERE user_id = $1 AND code = $2",
            [userId, code]
        );

        if (usageCheck.rows.length > 0) {
            await client.query('ROLLBACK');
            return res.status(400).json({ error: "Неверный или недоступный код" });
        }

        // 4. Обновляем счетчик использований
        await client.query(
            "UPDATE promo_codes SET current_uses = current_uses + 1 WHERE code = $1",
            [code]
        );

        // 5. Записываем факт использования
        await client.query(
            "INSERT INTO promo_code_usages (user_id, code) VALUES ($1, $2)",
            [userId, code]
        );

        // 6. Обновляем дату окончания премиума у пользователя
        const updatedProfile = await client.query(
            `UPDATE profiles 
             SET ad_free_until = (
                CASE 
                    WHEN ad_free_until > NOW() THEN ad_free_until + ($1 || ' days')::INTERVAL
                    ELSE NOW() + ($1 || ' days')::INTERVAL
                END
             ) 
             WHERE id = $2
             RETURNING *`,
            [promo.days_duration, userId]
        );

        // 6.5. Промокод может выдавать и оформление профиля.
        const cosmeticIds: string[] = Array.isArray(promo.cosmetic_ids) ? promo.cosmetic_ids : [];
        const grantedCosmetics: string[] = [];
        for (const id of cosmeticIds) {
            const def = COSMETICS.get(id);
            // Id из каталога более ранней сборки: не роняем активацию кода.
            if (!def) continue;
            await client.query(
                `INSERT INTO user_cosmetics (user_id, cosmetic_id, slot, tier, source, reason, expires_at)
                 VALUES ($1, $2, $3, $4, 'promo', $5, NULL)
                 ON CONFLICT (user_id, cosmetic_id) DO UPDATE
                   SET source = 'promo',
                       reason = EXCLUDED.reason,
                       expires_at = NULL`,
                [userId, id, def.slot, def.tier, promo.code]
            );
            grantedCosmetics.push(id);
        }

        await client.query('COMMIT');

        const parts: string[] = [];
        if (promo.days_duration > 0) {
            parts.push(`Премиум активирован на ${promo.days_duration} дней`);
        }
        if (grantedCosmetics.length > 0) {
            parts.push(`Выдано оформление: ${grantedCosmetics.join(', ')}`);
        }
        res.json({
            success: true,
            message: parts.join('. ') || 'Код активирован',
            cosmetics: grantedCosmetics,
            user: updatedProfile.rows[0]
        });

    } catch (err) {
        await client.query('ROLLBACK');
        console.error(err);
        res.status(500).json({ error: 'Server error redeeming code' });
    } finally {
        client.release();
    }
});

// POST /profiles/:id/follow
router.post('/:id/follow', authMiddleware, async (req: AuthRequest, res: Response) => {
    const targetUserId = req.params.id; 
    if (!uuidValidate(targetUserId)) return res.status(400).json({ error: "Invalid ID format" }); 

    const currentUserId = req.user?.id; 

    if (!currentUserId) return res.status(401).json({ error: "Unauthorized" });
    if (targetUserId === currentUserId) return res.status(400).json({ error: "Cannot follow yourself" });

    try {
        const check = await pool.query(
            'SELECT 1 FROM user_followers WHERE user_id = $1 AND follower_id = $2',
            [targetUserId, currentUserId]
        );

        let isFollowing = false;

        if (check.rows.length > 0) {
            await pool.query(
                'DELETE FROM user_followers WHERE user_id = $1 AND follower_id = $2',
                [targetUserId, currentUserId]
            );
            isFollowing = false;
        } else {
            await pool.query(
                'INSERT INTO user_followers (user_id, follower_id) VALUES ($1, $2)',
                [targetUserId, currentUserId]
            );
            isFollowing = true;

            await createNotification({
                userId: targetUserId,
                actorId: currentUserId,
                type: 'user_follow',
                payload: null
            });

            const followCountRes = await pool.query(
                'SELECT COUNT(*) FROM user_followers WHERE follower_id = $1',
                [currentUserId]
            );
            if (parseInt(followCountRes.rows[0].count) >= 5) {
                await awardAchievement(currentUserId, 'social_butterfly');
            }
        }

        res.json({ success: true, isFollowing });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Server error toggling follow' });
    }
});

// GET /profiles/:id/quests
router.get('/:id/quests', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" }); 

    const currentUserId = req.user?.id;

    try {
        let query = `
            SELECT 
                q.*,
                p.full_name AS author_name,
                p.is_verified AS author_is_verified,
                p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics,
                (SELECT AVG(r.rating) FROM ratings r WHERE r.quest_id = q.id) AS average_rating
            FROM quests q
            LEFT JOIN profiles p ON q.author_id = p.id
            WHERE q.author_id = $1
        `;
        const params = [id];

        if (currentUserId !== id) {
            // Если смотрим чужой профиль - только опубликованные
            query += " AND q.status = 'published'";
        }
        
        query += " ORDER BY q.created_at DESC";
        
        const quests = await pool.query(query, params);
        res.json(quests.rows);
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Server error getting user quests' });
    }
});

// GET /profiles/:id/reviews
router.get('/:id/reviews', async (req, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" }); 

    try {
        const reviews = await pool.query(
            `SELECT 
                r.*, 
                q.title as quest_title, 
                p.full_name as author_name, 
                p.avatar_url as author_avatar_url,
                p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics
             FROM reviews r
             JOIN quests q ON r.quest_id = q.id
             JOIN profiles p ON r.author_id = p.id
             WHERE r.author_id = $1 AND r.status = 'approved'
             ORDER BY r.created_at DESC`, 
             [id]
        );
        res.json(reviews.rows);
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Server error getting user reviews' });
    }
});

// GET /profiles/:id/is-following
router.get('/:id/is-following', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { id: profileUserId } = req.params;
    if (!uuidValidate(profileUserId)) return res.status(400).json({ error: "Invalid ID format" }); 

    const currentUserId = req.user?.id;
    try {
        const result = await pool.query(
            'SELECT 1 FROM user_followers WHERE user_id = $1 AND follower_id = $2',
            [profileUserId, currentUserId]
        );
        res.json({ isFollowing: result.rows.length > 0 });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Server error checking follow status' });
    }
});

// Библиотека «во что и сколько играл» — один и тот же набор запросов для
// своего профиля (rows для `/me/…`) и для чужого (`/:id/…`): смотреть, чем
// живёт другой человек, — ровно та же задача.
const PLAY_HISTORY_WINDOW_DAYS = 91;

async function buildPlayHistory(userId: string) {
    const items = await pool.query(
        `SELECT uqp.quest_id,
                uqp.playtime_seconds AS seconds,
                uqp.last_played_at,
                q.title,
                q.preview_image_url,
                q.status,
                q.author_id,
                p.full_name AS author_name,
                p.cosmetics ->> 'name_style' AS author_name_style, p.cosmetics AS author_cosmetics,
                COALESCE(d.days, 0)::int AS days
           FROM user_quest_playtime uqp
           JOIN quests q ON q.id = uqp.quest_id
           LEFT JOIN profiles p ON p.id = q.author_id
           LEFT JOIN (
                SELECT quest_id, count(*) AS days
                  FROM playtime_daily
                 WHERE user_id = $1
                 GROUP BY quest_id
           ) d ON d.quest_id = uqp.quest_id
          WHERE uqp.user_id = $1
          ORDER BY uqp.last_played_at DESC
          LIMIT 500`,
        [userId],
    );

    const totals = await pool.query(
        `SELECT COALESCE(sum(playtime_seconds), 0)::bigint AS total_seconds,
                count(*)::int AS quests_played
           FROM user_quest_playtime WHERE user_id = $1`,
        [userId],
    );
    const days = await pool.query(
        `SELECT count(DISTINCT day)::int AS active_days
           FROM playtime_daily WHERE user_id = $1`,
        [userId],
    );
    // Дневная активность для полоски «как в GitHub»: пустые дни дописывает
    // клиенту, здесь только то, в что реально играли.
    const activity = await pool.query(
        `SELECT day::text AS day, sum(seconds)::bigint AS seconds
           FROM playtime_daily
          WHERE user_id = $1
            AND day >= CURRENT_DATE - ($2::int - 1)
          GROUP BY day
          ORDER BY day`,
        [userId, PLAY_HISTORY_WINDOW_DAYS],
    );

    return {
        items: items.rows,
        activity: activity.rows.map((r: any) => ({
            day: r.day,
            seconds: Number(r.seconds),
        })),
        summary: {
            total_seconds: Number(totals.rows[0].total_seconds),
            quests_played: totals.rows[0].quests_played,
            active_days: days.rows[0].active_days,
            window_days: PLAY_HISTORY_WINDOW_DAYS,
        },
    };
}

// GET /profiles/me/playhistory — «во что и сколько играл», как в Steam.
//
// Строки `user_quest_playtime` писались с самого начала, но наружу не
// отдавались ни одним эндпоинтом: юзер видел наигранное только на том
// устройстве, где копил `SharedPreferences`.
router.get('/me/playhistory', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });

    try {
        res.json(await buildPlayHistory(userId));
    } catch (e) {
        console.error('playhistory:', e);
        res.status(500).json({ error: 'Server error getting play history' });
    }
});

// GET /profiles/:id/playhistory — библиотека другого человека.
//
// Публично намеренно: сами квесты и время в них — открытые данные, и «во что
// играет автор» — ровно та же информация, что список его публикаций.
router.get('/:id/playhistory', async (req, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" });

    try {
        res.json(await buildPlayHistory(id));
    } catch (e) {
        console.error('playhistory by id:', e);
        res.status(500).json({ error: 'Server error getting play history' });
    }
});

// GET /profiles/:id/achievements
router.get('/:id/achievements', async (req, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" }); 

    try {
        const achievements = await pool.query(
            `SELECT ua.achieved_at, a.* 
             FROM user_achievements ua
             JOIN achievements a ON ua.achievement_id = a.id
             WHERE ua.user_id = $1`,
            [id]
        );
        res.json(achievements.rows);
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Server error getting user achievements' });
    }
});

// POST /profiles/fcm-token — save FCM device token for push notifications
router.post('/fcm-token', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });

    const { token } = req.body;
    const finalToken = (token && typeof token === 'string' && token.trim().length > 0) ? token.trim() : null;

    try {
        await pool.query(
            'UPDATE profiles SET fcm_token = $1 WHERE id = $2',
            [finalToken, userId],
        );
        res.json({ success: true });
    } catch (err) {
        console.error('FCM token save error:', err);
        res.status(500).json({ error: 'Server error' });
    }
});

// POST /profiles/playtime-sync (НОВЫЙ РОУТ)
router.post('/playtime-sync', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    const { total_app_time, quest_times } = req.body; // quest_times: { [questId: string]: number }

    if (!userId) return res.status(401).json({ error: "Unauthorized" });

    const client = await acquireClient(res, 'playtime sync');
    if (!client) return;
    try {
        await client.query('BEGIN');

        // Security: Prevent unreasonable jumps (e.g. over 60 minutes + 10 min buffer per sync interval)
        // This stops bad actors from sending million-second payloads
        const MAX_ALLOWABLE_SYNC_SECONDS = 70 * 60; 

        // Дельтам клиента верить на слово нельзя: при потолке в 70 минут и синке
        // раз в пять минут аккаунт накручивает ~840 «наигранных» часов в сутки.
        // Настоящий потолок — сколько времени реально прошло с прошлого синка
        // по часам сервера; запас прикрывает рассинхрон часов и пересечение секунд.
        const SYNC_GRACE_SECONDS = 120;
        const marked = await client.query(
            `SELECT playtime_last_sync_at FROM profiles WHERE id = $1 FOR UPDATE`,
            [userId],
        );
        const lastSyncAt = marked.rows[0]?.playtime_last_sync_at;
        const budget = lastSyncAt
            ? Math.min(
                  MAX_ALLOWABLE_SYNC_SECONDS,
                  Math.floor((Date.now() - new Date(lastSyncAt).getTime()) / 1000) +
                      SYNC_GRACE_SECONDS,
              )
            : MAX_ALLOWABLE_SYNC_SECONDS;

        // Update total app time
        if (total_app_time && total_app_time > 0 && typeof total_app_time === 'number') {
            const safeAppTime = Math.min(total_app_time, budget);
            await client.query(
                `UPDATE profiles SET total_playtime_seconds = COALESCE(total_playtime_seconds, 0) + $1 WHERE id = $2`,
                [safeAppTime, userId]
            );
        }

        // Сколько секунд удалось принять; суммарно квесты не должны перевалить
        // за то же время, что прошло на сервере.
        let questBudget = budget;
        const todayStr = new Date().toISOString().split('T')[0];

        // Update individual quest times
        if (quest_times && typeof quest_times === 'object') {
            const questIds = Object.keys(quest_times).filter(id => uuidValidate(id));
            if (questIds.length > 0) {
                const existingQuestsResult = await client.query(
                    `SELECT id FROM quests WHERE id = ANY($1::uuid[])`,
                    [questIds]
                );
                const existingQuestIds = new Set(existingQuestsResult.rows.map(r => r.id));

                for (const questId of questIds) {
                    if (existingQuestIds.has(questId)) {
                        const playtime = quest_times[questId];
                        if (typeof playtime === 'number' && playtime > 0) {
                            const safeQuestTime = Math.min(playtime, questBudget);
                            if (safeQuestTime <= 0) continue;
                            questBudget -= safeQuestTime;
                            await client.query(
                                `INSERT INTO user_quest_playtime (user_id, quest_id, playtime_seconds, last_played_at)
                                 VALUES ($1, $2, $3, NOW())
                                 ON CONFLICT (user_id, quest_id) 
                                 DO UPDATE SET 
                                    playtime_seconds = user_quest_playtime.playtime_seconds + EXCLUDED.playtime_seconds,
                                    last_played_at = NOW()`,
                                [userId, questId, safeQuestTime]
                            );
                            // Тот же факт, но разложенный по суткам: из
                            // накопленной суммы не видно ни игрового дня, ни
                            // дневного графика для автора.
                            await client.query(
                                `INSERT INTO playtime_daily (user_id, quest_id, day, seconds)
                                 VALUES ($1, $2, $3::date, $4)
                                 ON CONFLICT (user_id, quest_id, day)
                                 DO UPDATE SET seconds = playtime_daily.seconds + EXCLUDED.seconds`,
                                [userId, questId, todayStr, safeQuestTime]
                            );
                        }
                    }
                }
            }
        }

        await client.query(
            `UPDATE profiles SET playtime_last_sync_at = NOW() WHERE id = $1`,
            [userId]
        );

        await client.query('COMMIT');
        res.json({ success: true });
    } catch (e) {
        await client.query('ROLLBACK');
        console.error('Error syncing playtime:', e);
        res.status(500).json({ error: 'Server error syncing playtime' });
    } finally {
        client.release();
    }
});

export default router;
