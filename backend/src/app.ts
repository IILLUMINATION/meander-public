import express, { Request, Response, NextFunction } from 'express';
import { createServer } from 'http';
import cors from 'cors';
import morgan from 'morgan';
import dotenv from 'dotenv';
import passport from 'passport';
import path from 'path';
import fs from 'fs'; 
import helmet from 'helmet';
import compression from 'compression';
import hpp from 'hpp';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import pool from './config/database';

import authRoutes from './routes/auth';
import authYandexRoutes from './routes/auth_yandex';
import authTelegramRoutes from './routes/auth_telegram';
import authAppleRoutes from './routes/auth_apple';
import questRoutes from './routes/quests';
import profileRoutes from './routes/profiles';
import adminRoutes from './routes/admin';
import shareRoutes from './routes/share';
import reportRoutes from './routes/reports';
import notificationRoutes from './routes/notifications';
import appRoutes from './routes/app';
import authorWallRoutes from './routes/author-wall';
import communityRoutes from './routes/community';
import cloudSyncRoutes from './routes/cloud_sync';
import musicRoutes from './routes/music';
import assetRoutes from './routes/assets';
import messageRoutes from './routes/messages';
import forumRoutes from './routes/forums';
import './config/passport';
import { optionalAuthMiddleware, AuthRequest } from './middleware/auth';
import { canSeeUnpublished } from './services/visibility';
import { startAchievementChecker } from './services/achievementChecker';
import { ensureInitialized as initFcm } from './services/fcm';
import { humanErrorMiddleware } from './middleware/error_messages';
import { startCloudSyncCleanupCron } from './services/cloud_sync_cleanup';
import { startAccountDeletionSweep } from './services/account_deletion';
import { startCosmeticExpirySweep } from './services/cosmetics';
import { startRewardSweep } from './services/rewards';
import { initSocket } from './services/socket';
import { clientIp } from './services/client_ip';

dotenv.config();

const app = express();
const server = createServer(app);
const PORT = process.env.PORT || 3000;
const isProduction = process.env.NODE_ENV === 'production';
const allowedOrigins = (process.env.CORS_ORIGINS || '')
  .split(',')
  .map((o) => o.trim())
  .filter(Boolean);

// nginx is the only trusted proxy hop; forwarded headers from direct clients
// must not influence req.ip or rate limits (SEC-07).
app.set('trust proxy', 'loopback');

// --- 1. БЕЗОПАСНОСТЬ ---
app.use(helmet({
    crossOriginResourcePolicy: false,
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            scriptSrc: ["'self'"],
            styleSrc: ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"],
            fontSrc: ["'self'", "https://fonts.gstatic.com"],
            imgSrc: ["'self'", "data:", "https:"],
            connectSrc: ["'self'", "https:"],
        },
    },
}));

app.use(hpp());
app.use(compression());

// CSRF: состояние меняется только по Bearer-токену; cookie-сессий и
// автоматически отправляемых креденшелов у API нет (SEC-20).
app.use(cors({
    origin: (origin, callback) => {
        if (!origin) return callback(null, true);
        if (!isProduction && allowedOrigins.length === 0) return callback(null, true);
        if (allowedOrigins.includes(origin)) return callback(null, true);
        return callback(new Error('Not allowed by CORS'));
    },
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
    allowedHeaders: ['Content-Type', 'Authorization']
}));

// --- 2. ЛИМИТЫ ---

const generalLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 1000, 
    keyGenerator: (req) => ipKeyGenerator(clientIp(req)),
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Too many requests' }
});

const authLimiter = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 100,
    keyGenerator: (req) => ipKeyGenerator(clientIp(req)),
    message: { error: 'Too many login attempts.' }
});

// Публикации: ключ — автор, а не IP. Провайдер отдаёт одним адресом на целый
// дом или район, и тогда пятью публикациями в час распоряжались соседи по
// CGNAT: человек получал 429 без объяснения и писал «квест не публикуется».
const uploadLimiter = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 5,
    message: { error: 'Публиковать можно не чаще 5 раз в час. Попробуй позже.' },
    keyGenerator: (req) => {
        const userId = (req as AuthRequest).user?.id;
        return userId ? `pub_${userId}` : `pub_ip_${ipKeyGenerator(clientIp(req))}`;
    }
});

// Умный лимитер для квестов: авторизованные — мягко, анонимы — жёстко
const publicQuestLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    keyGenerator: (req) => ipKeyGenerator(clientIp(req)),
    max: (req) => {
        const authHeader = req.headers.authorization;
        return authHeader ? 600 : 60; // 600/15мин для авторизованных, 60/15мин для анонимов
    },
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Too many requests. Please slow down.' }
});

// Лимит на скачивание .mnd файлов: защита от парсинга каталога, а не от игроков.
// Счётчик загрузок ведёт POST /quests/:id/download, поэтому здесь можно быть
// щедрым: этот путь теперь обслуживает и клиент, и веб-плеер, а 30 в час на IP
// ловили бы целые дома и офисы за CGNAT (именно на это жаловались в #290).
const downloadLimiter = rateLimit({
    windowMs: 60 * 60 * 1000, // 1 час
    max: (req) => ((req as AuthRequest).user?.id ? 600 : 300),
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Слишком много загрузок. Подожди немного и попробуй снова.' },
    keyGenerator: (req) => {
        // Используем IP + авторизованный user_id для более точного ключа
        const userId = (req as any).user?.id;
        return userId ? `dl_${userId}` : `dl_${ipKeyGenerator(clientIp(req))}`;
    }
});

// === ИЗМЕНЕНИЕ 2: ВРЕМЕННО ЗАКОММЕНТИРУЙ ЭТУ СТРОКУ ===
// Чтобы пользователей пустило прямо сейчас
app.use(generalLimiter);

// --- 3. ПАРСИНГ ---
// SEC-14: обычные JSON-запросы ограничены 1 МБ, формы — 100 КБ. Облачная
// синхронизация принимает квесты до 5 МБ, поэтому большой лимит включается
// только для её префикса, а не для всего приложения.
const jsonDefault = express.json({ limit: '1mb' });
const jsonCloudSync = express.json({ limit: '5mb' });
const urlencodedDefault = express.urlencoded({ extended: true, limit: '100kb' });
const urlencodedCloudSync = express.urlencoded({ extended: true, limit: '5mb' });
const isCloudSyncPath = (p: string) => p === '/cloud-sync' || p.startsWith('/cloud-sync/');
app.use((req, res, next) => {
    (isCloudSyncPath(req.path) ? jsonCloudSync : jsonDefault)(req, res, next);
});
app.use((req, res, next) => {
    (isCloudSyncPath(req.path) ? urlencodedCloudSync : urlencodedDefault)(req, res, next);
});

if (process.env.NODE_ENV !== 'production') {
    app.use(morgan('dev'));
}

// --- 4. СТАТИКА ---
const publicDir = path.join(__dirname, '../public');
const folders = ['uploads', 'quests_files', 'music_files', 'assets_files', '.well-known'];
if (!fs.existsSync(publicDir)) fs.mkdirSync(publicDir);
folders.forEach(folder => {
    const p = path.join(publicDir, folder);
    if (!fs.existsSync(p)) fs.mkdirSync(p);
});

app.use('/uploads', (req, res, next) => {
    if (/\.(html?|js|mjs|svg|xml)$/i.test(req.path)) {
        return res.status(403).json({ error: 'Forbidden file type' });
    }
    next();
}, express.static(path.join(publicDir, 'uploads')));
app.use('/static/quests', express.static(path.join(publicDir, 'quests')));
// Файл квеста лежит по предсказуемому адресу <questId>.mnd, так что для чужой
// загрузки достаточно одного id: отклонённый или ещё не прошедший модерацию
// квест скачивался анонимно. Публикация проверяется здесь, автор и модератор —
// по роли из базы (в JWT она семидневная и после понижения осталась бы прежней).
//
// На проде байты отдаёт nginx по X-Accel-Redirect, а не это приложение: иначе
// location /static/downloads/ с alias минует проверку целиком (проверено 11.10:
// HTTP 200 на отклонённый квест прямо через край). Без префикса в окружении —
// локальная разработка — файл отдаёт sendFile.
const questFilesDir = path.join(publicDir, 'quests_files');
const xaccelPrefix = process.env.QUEST_XACCEL_PREFIX || '';
// Непубликованную копию (её видит только автор и админ) ведём на отдельный
// внутренний location без публичного кэша: иначе «public, max-age=86400»
// осел бы в Cloudflare, и снятый с публикации квест продолжали бы отдавать
// всем, даже когда Node уже отвечает 404.
const xaccelPrivatePrefix = process.env.QUEST_XACCEL_PRIVATE_PREFIX || xaccelPrefix;
app.get('/static/downloads/:fileName', downloadLimiter, optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const fileName = req.params.fileName;
    // Оставляем только <uuid>.mnd: alias внутри nginx иначе ловил бы и
    // ../-пути, и чужие расширения.
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.mnd$/i.test(fileName)) {
        return res.status(404).json({ error: 'Not found' });
    }
    try {
        const r = await pool.query('SELECT status, author_id FROM quests WHERE id = $1', [fileName.slice(0, 36)]);
        if (r.rows.length === 0) return res.status(404).json({ error: 'Not found' });
        const published = r.rows[0].status === 'published';
        if (!published && !(await canSeeUnpublished(req, r.rows[0].author_id))) {
            return res.status(404).json({ error: 'Not found' });
        }
        const fullPath = path.join(questFilesDir, fileName);
        if (!fs.existsSync(fullPath)) return res.status(404).json({ error: 'Not found' });
        res.setHeader('Content-Type', 'application/octet-stream');
        const prefix = published ? xaccelPrefix : xaccelPrivatePrefix;
        if (prefix) {
            // Кэш-заголовки навешивает nginx на внутреннем location: при
            // X-Accel-Redirect они всё равно уходят клиенту, а второй Cache-Control
            // сверху — это два источника правды, которые однажды разойдутся.
            res.setHeader('X-Accel-Redirect', `${prefix}/${fileName}`);
            return res.status(200).end();
        }
        // Локальная разработка без nginx: здесь и кэш, и CORP на нас.
        res.setHeader('Cache-Control', published ? 'public, max-age=86400' : 'no-store');
        res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
        return res.sendFile(fullPath);
    } catch (e) {
        console.error('[downloads] failed to serve quest file:', e);
        return res.status(500).json({ error: 'Failed to serve quest file' });
    }
});
// SEC-LIVE-03: контакт для ответственного раскрытия уязвимостей и правила
// обхода. Явные маршруты выше static, чтобы файл не зависел от public/,
// который исключён из деплоя (там runtime-загрузки).
app.get('/.well-known/security.txt', (_req: Request, res: Response) => {
  res.type('text/plain').send(
    'Contact: https://github.com/IILLUMINATION/meander-public/security/advisories/new\n' +
    'Expires: 2027-11-07T00:00:00.000Z\n' +
    'Preferred-Languages: ru, en\n' +
    'Canonical: https://backend.meander.sbs/.well-known/security.txt\n'
  );
});
app.get('/robots.txt', (_req: Request, res: Response) => {
  res.type('text/plain').send('User-agent: *\nDisallow: /\nAllow: /share/\n');
});
app.use('/.well-known', express.static(path.join(publicDir, '.well-known')));


// --- 5. РОУТЫ ---
app.use(passport.initialize());

// === ИЗМЕНЕНИЕ 3: ДОБАВЬ ЭТОТ РОУТ ДЛЯ ПРОВЕРКИ IP ===
if (!isProduction && process.env.ENABLE_DEBUG_ROUTES === 'true') {
    app.get('/test-ip', (req: Request, res: Response) => {
        res.json({
            ip: clientIp(req),
            ips: [clientIp(req)],
            headers: req.headers['x-forwarded-for']
        });
    });
}

app.get('/', (_req: Request, res: Response) => {
  // LIVE-03: не подтверждаем стек и версию на корне; health-check умеет 204.
  res.status(204).end();
});

app.use('/auth', authLimiter, authRoutes);
app.use('/auth', authLimiter, authYandexRoutes);
app.use('/auth', authLimiter, authTelegramRoutes);
app.use('/auth', authLimiter, authAppleRoutes);

// Публичный доступ к квестам с rate limiting (защита от парсинга)
app.use('/quests', publicQuestLimiter, (req: AuthRequest, res: Response, next: NextFunction) => {
    // Для создания квестов используем отдельный лимит — по автору, поэтому
    // токен сначала разбирается (необязательный: без него ключ — IP).
    if (req.method === 'POST' && req.path === '/') {
        optionalAuthMiddleware(req, res, () => uploadLimiter(req, res, next));
    } else {
        next();
    }
}, questRoutes);

app.use('/profiles', profileRoutes);
app.use('/admin', adminRoutes);
app.use('/share', shareRoutes);
app.use('/reports', reportRoutes);
app.use('/notifications', notificationRoutes);
app.use('/api/app', appRoutes);
app.use('/api/author-walls', authorWallRoutes);
app.use('/api/community', communityRoutes);
app.use('/api/messages', messageRoutes);
app.use('/api/forums', forumRoutes);
app.use('/music', musicRoutes);
app.use('/assets', assetRoutes);

// --- Meander Cloud Sync ---
// Принимает как JSON, так и application/octet-stream (binary .mnd).
// Лимит 200MB позволяет вместить квесты pro-tier (max 100MB) с запасом.
// Парсеры внутри роутера: разбирать тело можно только после токена.
app.use('/cloud-sync', cloudSyncRoutes);

// --- 6. ОШИБКИ ---
app.use((err: any, req: Request, res: Response, next: NextFunction) => {
    if (err instanceof SyntaxError && 'body' in err) return res.status(400).send({ error: 'Bad JSON format' });
    if (err.code === 'LIMIT_FILE_SIZE' || (err.type === 'entity.too.large')) {
        return res.status(413).send({
            error: 'File too large. Limits: regular users 100 MB, verified users 500 MB.'
        });
    }
    if (err.name === 'UnauthorizedError') return res.status(401).send({ error: 'Invalid token' });
    if (err.message === 'Not allowed by CORS') return res.status(403).send({ error: 'CORS blocked' });
    if (err.message === 'Invalid image file type' || err.message === 'Invalid quest file type' || err.message === 'Unexpected upload field') {
        return res.status(400).send({ error: err.message });
    }

    console.error('Unhandled Error:', err);

    // Текст ошибки — по перечислимым шаблонам, наружу details не отдаём
    if (res.headersSent) return next(err);
    humanErrorMiddleware(err, req, res, next);
});

// Инициализируем WebSockets до запуска сервера
initSocket(server);

server.listen(PORT, () => {
  console.log(`✅ Server is running on http://localhost:${PORT}`);
  initFcm(); // Initialize Firebase Admin SDK for push notifications
  startAchievementChecker(10 * 60 * 1000); // every 10 minutes
  startCloudSyncCleanupCron(); // раз в сутки, первый запуск через 5 мин
  startAccountDeletionSweep(); // раз в час: удаления, у которых истёк grace-срок
  startCosmeticExpirySweep(10 * 60 * 1000); // снимает оформление, срок на которое истёк
  startRewardSweep(15 * 60 * 1000); // выдаёт оформление за стрик, игровые дни, отзывы и скачивания
});
