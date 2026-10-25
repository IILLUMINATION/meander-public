import { Router, Response } from 'express';
import pool from '../config/database';
import authMiddleware, { AuthRequest, optionalAuthMiddleware } from '../middleware/auth';
import adminAuth from '../middleware/adminAuth';
import { canSeeUnpublished, isAdmin, isStaff } from '../services/visibility';
import { marketListQuery } from '../services/market_query';
import multer from 'multer';
import fs from 'fs';
import fsPromises from 'fs/promises';
import path from 'path';
import os from 'os';
import { v4 as uuidv4, validate as uuidValidate } from 'uuid';
import crypto from 'crypto';
import { pipeline } from 'stream/promises';
import { moderateQuestContent, moderateReview } from '../services/moderation';
import { analyzeQuestZip, publishDecision } from '../services/quest_scan';
import { normalizeQuestLanguage } from '../services/quest_language';
import {
    VERIFIED_USER_MAX_FILE_SIZE_BYTES,
    archiveUnreadable,
    buildPublishSizeGate,
    contentRejected,
    duplicateFile,
    fileTooLarge,
    missingQuestFile,
    ownershipConflict,
    sizeLimitFor,
    toHttpResponse
} from '../services/publish_errors';
import {
    clampDays,
    getAuthorAnalytics,
    getQuestAnalytics,
} from '../services/quest_analytics';

/**
 * Удаляет HTML-теги и обрезает пробелы. Защита от stored XSS.
 */
function stripHtml(str: string): string {
    if (typeof str !== 'string') return '';
    return str.replace(/<[^>]*>/g, '').trim();
}

/**
 * Санитизирует пользовательский текст: удаляет HTML и обрезает до maxLength.
 */
function sanitizeText(str: string, maxLength: number = 5000): string {
    return stripHtml(str).substring(0, maxLength);
}
import { uploadImage } from '../services/image_host'; // ИСПОЛЬЗУЕМ ЛОКАЛЬНЫЙ ЗАГРУЗЧИК
import { awardAchievement } from '../services/achievements';
import { createBulkNotifications, createNotification } from '../services/notifications';
import { recomputeTier } from '../services/cloud_sync_tier';

const router = Router();

const TEMP_DIR = path.join(os.tmpdir(), 'meander_uploads');
const PROJECT_ROOT = path.resolve(__dirname, '../../');
const PUBLIC_DIR = path.join(PROJECT_ROOT, 'public');
const QUESTS_STORAGE_DIR = path.join(PUBLIC_DIR, 'quests_files');

if (!fs.existsSync(TEMP_DIR)) fs.mkdirSync(TEMP_DIR, { recursive: true });
if (!fs.existsSync(QUESTS_STORAGE_DIR)) fs.mkdirSync(QUESTS_STORAGE_DIR, { recursive: true });

const getPublicDownloadUrl = (questId: string) => {
    const baseUrl = process.env.BASE_URL || 'http://localhost:3000';
    return `${baseUrl}/quests/${questId}/file`;
};

const withPublicDownloadUrl = (row: any) => {
    if (!row || !row.id) return row;
    return { ...row, download_url: getPublicDownloadUrl(row.id) };
};

const allowedImageExtensions = new Set(['.jpg', '.jpeg', '.png', '.webp']);
const allowedImageMimeTypes = new Set([
    'image/jpeg',
    'image/jpg',
    'image/pjpeg',
    'image/png',
    'image/webp',
]);
const permissiveUploadMimeTypes = new Set([
    '',
    'application/octet-stream',
    'binary/octet-stream',
]);
const allowedQuestExtensions = new Set(['.mnd', '.zip']);
const allowedQuestMimeTypes = new Set([
    'application/octet-stream',
    'application/zip',
    'application/x-zip-compressed',
]);
/**
 * Отсев по размеру ДО разбора multipart-тела (порядок фильтров задаётся ниже,
 * в `router.post`). Логика — в publish_errors.buildPublishSizeGate, чтобы
 * проверялась тестом без БД.
 */
const publishSizeGate = buildPublishSizeGate(async (userId) => {
    const profile = await pool.query('SELECT is_verified FROM profiles WHERE id = $1', [userId]);
    return profile.rows[0]?.is_verified === true;
});

const upload = multer({
    storage: multer.diskStorage({
        destination: (req, file, cb) => { cb(null, TEMP_DIR); },
        filename: (req, file, cb) => {
            const uniqueName = `${uuidv4()}${path.extname(file.originalname)}`;
            cb(null, uniqueName);
        }
    }),
    fileFilter: (req, file, cb) => {
        const ext = path.extname(file.originalname || '').toLowerCase();
        const mime = (file.mimetype || '').toLowerCase();

        if (file.fieldname === 'questFile') {
            const extOk = allowedQuestExtensions.has(ext);
            const mimeOk = allowedQuestMimeTypes.has(mime);
            if (extOk && mimeOk) return cb(null, true);
            return cb(new Error('Invalid quest file type'));
        }

        if (file.fieldname === 'cover' || file.fieldname === 'screenshots') {
            const extOk = allowedImageExtensions.has(ext);
            const mimeOk = allowedImageMimeTypes.has(mime);
            const genericMime = permissiveUploadMimeTypes.has(mime);
            if (extOk && (mimeOk || genericMime)) return cb(null, true);
            return cb(new Error('Invalid image file type'));
        }

        return cb(new Error('Unexpected upload field'));
    },
    // Технический потолок для multipart (должен быть >= verified лимита).
    limits: { fileSize: VERIFIED_USER_MAX_FILE_SIZE_BYTES }
});

const deleteTempFile = async (filePath: string) => {
    try {
        await fsPromises.access(filePath);
        await fsPromises.unlink(filePath);
    } catch (e) { }
};

// === УДАЛЕНИЕ ЗАГОЛОВКА MND_ZIP_ ===
async function sanitizeQuestFile(filePath: string): Promise<void> {
    const tempPath = filePath + ".tmp";
    let fd: fsPromises.FileHandle | null = null;

    try {
        fd = await fsPromises.open(filePath, 'r');
        const headerBuf = Buffer.alloc(8);
        const { bytesRead } = await fd.read(headerBuf, 0, 8, 0);
        await fd.close();
        fd = null; 

        if (bytesRead === 8 && headerBuf.toString() === 'MND_ZIP_') {
            console.log(`🛠️ Detected MND_ZIP_ header in ${path.basename(filePath)}. Stripping...`);
            
            const readStream = fs.createReadStream(filePath, { start: 8 });
            const writeStream = fs.createWriteStream(tempPath);

            await pipeline(readStream, writeStream);
            
            await fsPromises.unlink(filePath);
            await fsPromises.rename(tempPath, filePath);
            console.log(`✅ File sanitized: converted to standard ZIP.`);
        }
    } catch (e) {
        if (fd) await fd.close();
        if (fs.existsSync(tempPath)) await fsPromises.unlink(tempPath);
        throw e;
    }
}

// ============================================================================
// POST: ПУБЛИКАЦИЯ
// ============================================================================
router.post('/', authMiddleware, publishSizeGate, upload.fields([
    { name: 'cover', maxCount: 1 },
    { name: 'questFile', maxCount: 1 },
    { name: 'screenshots', maxCount: 10 }
]), async (req: AuthRequest, res: Response) => {
    
    const files = req.files as { [fieldname: string]: Express.Multer.File[] };
    const cleanupPaths: string[] = [];
    if (files) Object.values(files).flat().forEach(f => cleanupPaths.push(f.path));

    let client = null;

    try {
        const userId = req.user?.id;
        
        // Проверяем, не заблокирован ли пользователь
        const userCheck = await pool.query('SELECT is_blocked FROM profiles WHERE id = $1', [userId]);
        if (userCheck.rows.length === 0) {
            return res.status(404).json({ error: "User not found" });
        }
        if (userCheck.rows[0].is_blocked === true) {
            return res.status(403).json({ error: "Your account is blocked. You cannot publish quests." });
        }
        let { id, title, description, version, genres, category, is_demo, demo } = req.body;
        
        // XSS-защита: удаляем HTML-теги из пользовательского текста
        title = sanitizeText(title, 200);
        description = sanitizeText(description, 5000);
        version = sanitizeText(version, 50);
        
        const isDemo =
            is_demo === true ||
            is_demo === 'true' ||
            demo === true ||
            demo === 'true';

        const isNsfw = req.body.is_nsfw === true || req.body.is_nsfw === 'true';

        // Язык квеста: метка из настроек автора, по ней маркет поднимает
        // «свои» квесты первыми. Невалидная форма — то же самое, что «не
        // указано», публикацию из-за неё отбивать не за что.
        const questLanguage = normalizeQuestLanguage(req.body.language);

        // 1. Обработка жанров (Multi-select)
        let selectedGenres: string[] = [];
        
        // Проверяем новое поле genres
        if (genres) {
            try {
                // Если пришел JSON-строка (например, из FormData)
                selectedGenres = JSON.parse(genres);
            } catch (e) {
                // Если пришел массив или просто строка
                if (Array.isArray(genres)) selectedGenres = genres;
                else selectedGenres = [genres.toString()];
            }
        }
        
        // Обратная совместимость: если genres пуст, но есть category (старое приложение)
        if (selectedGenres.length === 0 && category) {
            selectedGenres = [category];
        }

        // Дефолт, если ничего нет
        if (selectedGenres.length === 0) {
            selectedGenres = ["Adventure"];
        }

        // Основная категория для обратной совместимости (первый элемент массива)
        const mainCategory = selectedGenres[0];

        const questId = (id && uuidValidate(id)) ? id : uuidv4();
        console.log(`Processing Upload for QuestID: ${questId}`);

        // Чужой id в req.body — это ещё не право на обновление: файл лежит по
        // адресу static/downloads/<questId>.mnd, и копирование ниже затёрло бы
        // чужой квест до всяких проверок (проверка в транзакции была позже,
        // откатывалась она только базу — файл на диске оставался).
        const ownership = await pool.query('SELECT author_id FROM quests WHERE id = $1', [questId]);
        if (ownership.rows.length > 0
            && ownership.rows[0].author_id !== userId
            && !(await isAdmin(req))) {
            throw ownershipConflict();
        }

        if (!files || !files['questFile']) throw missingQuestFile();
        const questFile = files['questFile'][0];

        // ПРОВЕРКА ЛИМИТА РАЗМЕРА ФАЙЛА
        // Верифицированные авторы могут загружать до 500 МБ, остальные — до 100 МБ
        const userProfile = await pool.query('SELECT is_verified FROM profiles WHERE id = $1', [userId]);
        const isVerified = userProfile.rows[0]?.is_verified === true;
        const sizeLimit = sizeLimitFor(isVerified);

        if (questFile.size > sizeLimit) {
            throw fileTooLarge(questFile.size, sizeLimit);
        }

        // 2. Очистка файла (MND_ZIP header)
        await sanitizeQuestFile(questFile.path);

        // 3. Хэширование
        const hashSum = crypto.createHash('sha256');
        const fileStream = fs.createReadStream(questFile.path);
        await pipeline(fileStream, hashSum);
        const hash = hashSum.digest('hex');

        // Проверка дубликатов (исключая самого автора)
        const dupCheck = await pool.query('SELECT id FROM quests WHERE file_hash = $1 AND author_id != $2', [hash, userId]);
        if (dupCheck.rows.length > 0) throw duplicateFile();

        // 4. Анализ
        let analysisData;
        try {
            analysisData = await analyzeQuestZip(questFile.path, TEMP_DIR);
        } catch (e) {
            // Битый или слишком хитрый архив — это проблема пакета, а не
            // сервера: человек должен видеть «не читаю архив», а не 500.
            throw archiveUnreadable((e as Error).message);
        }
        cleanupPaths.push(...analysisData.images);

        // 5. Модерация по перечислимым правилам (жанр теперь берём от пользователя).
        // Идёт ДО копирования: отклонённая публикация раньше успевала затереть
        // файл уже живущего в магазине квеста — игроки качали отклонённую
        // сборку, пока запись в базе описывала старую версию.
        let moderation: { approved: boolean; reason: string } | null = null;
        if (analysisData.fullText || description || title) {
            const r = await moderateQuestContent(title, description, analysisData.fullText);

            if (r.isHardReject) {
                throw contentRejected(r.reason);
            }
            moderation = { approved: r.approved, reason: r.reason };
        }

        const { status, moderatorComment } = publishDecision(moderation, analysisData.textScanFailed);

        // 6. Копирование файла — пока в staging, на постоянное место только после COMMIT.
        const permFileName = `${questId}.mnd`;
        const permFilePath = path.join(QUESTS_STORAGE_DIR, permFileName);
        const stagingPath = `${permFilePath}.staging`;
        await fsPromises.copyFile(questFile.path, stagingPath);
        cleanupPaths.push(stagingPath);

        const baseUrl = process.env.BASE_URL || 'http://localhost:3000';
        const downloadUrl = `${baseUrl}/static/downloads/${permFileName}`;

        // 7. Обложка (ЛОКАЛЬНОЕ СОХРАНЕНИЕ)
        let previewImageUrl = null;
        if (files['cover']) {
            try {
                // Используем наш локальный загрузчик вместо ImgBB
                previewImageUrl = await uploadImage(files['cover'][0].path);
            } catch (e) { console.error("Cover upload failed:", e); }
        }

        // 8. Скриншоты (ЛОКАЛЬНОЕ СОХРАНЕНИЕ)
        const screenshotUrls: string[] = [];
        if (files['screenshots']) {
            // Используем наш локальный загрузчик
            const uploadPromises = files['screenshots'].map(file => uploadImage(file.path));
            const results = await Promise.allSettled(uploadPromises);
            results.forEach((result) => {
                if (result.status === 'fulfilled') screenshotUrls.push(result.value);
            });
        }

        // 9. БД (С ЗАЩИТОЙ)
        client = await pool.connect();
        await client.query('BEGIN');

        // --- ВАЖНАЯ ЗАЩИТА: ПРОВЕРЯЕМ АВТОРА ---
        const existingQuest = await client.query('SELECT author_id FROM quests WHERE id = $1', [questId]);
        const isNewQuest = existingQuest.rows.length === 0;
        if (existingQuest.rows.length > 0) {
            // Если квест существует, проверяем, что его обновляет автор или админ
            if (existingQuest.rows[0].author_id !== userId && !(await isAdmin(req))) {
                throw ownershipConflict();
            }
        }
        // ----------------------------------------

        const upsertQuery = `
            INSERT INTO quests (
                id, title, description, author_id, download_url, preview_image_url, 
                version, node_count, estimated_playtime, quest_size_bytes, 
                status, updated_at, moderator_comment, category, genres, file_hash, is_demo, is_nsfw
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, NOW(), $12, $13, $14, $15, $16, $17)
            ON CONFLICT (id) DO UPDATE SET 
                title=EXCLUDED.title, 
                description=EXCLUDED.description, 
                download_url=EXCLUDED.download_url, 
                preview_image_url=COALESCE(EXCLUDED.preview_image_url, quests.preview_image_url), 
                version=EXCLUDED.version, 
                node_count=EXCLUDED.node_count, 
                estimated_playtime=EXCLUDED.estimated_playtime, 
                quest_size_bytes=EXCLUDED.quest_size_bytes, 
                updated_at=NOW(), 
                status=$11, 
                moderator_comment=$12, 
                category=$13, 
                genres=$14,
                file_hash=$15,
                is_demo=EXCLUDED.is_demo,
                is_nsfw=EXCLUDED.is_nsfw
            RETURNING *;
        `;

        const resDb = await client.query(upsertQuery, [
            questId, title, description, userId, downloadUrl, previewImageUrl,
            version, analysisData.nodeCount, analysisData.estimatedPlaytime, questFile.size,
            status, moderatorComment, mainCategory, selectedGenres, hash, isDemo, isNsfw
        ]);

        // Язык — отдельным UPDATE, не колонкой upsert'а: поле шлёт только
        // новый клиент. «Поля нет» = старый клиент, метку бережём; «поле
        // пустое» = автор снял язык, пишем null.
        if ('language' in req.body) {
            await client.query(
                'UPDATE quests SET language = $1 WHERE id = $2',
                [questLanguage, questId]
            );
        }

        await client.query('DELETE FROM quest_screenshots WHERE quest_id = $1', [questId]);
        for (let i = 0; i < screenshotUrls.length; i++) {
            await client.query(
                'INSERT INTO quest_screenshots (quest_id, image_url, sort_order) VALUES ($1, $2, $3)',
                [questId, screenshotUrls[i], i]
            );
        }

        await client.query('UPDATE profiles SET last_published_at = NOW() WHERE id = $1', [userId]);
        
        // Выдача ачивки (проверяем, первый ли это опубликованный квест)
        const questCountRes = await client.query("SELECT COUNT(*) FROM quests WHERE author_id = $1 AND status = 'published'", [userId]);
        if (parseInt(questCountRes.rows[0].count) === 1) {
            await awardAchievement(userId, 'publisher_debut');
        }

        if (status === 'published') {
            const followersRes = await client.query(
                'SELECT follower_id FROM user_followers WHERE user_id = $1',
                [userId]
            );
            const followerIds = followersRes.rows.map(r => r.follower_id);

            if (isNewQuest) {
                await createBulkNotifications({
                    userIds: followerIds,
                    actorId: userId,
                    type: 'quest_published',
                    questId,
                    payload: { title, version, is_demo: isDemo }
                }, client);
            } else {
                // Анти-спам: уведомления об обновлении квеста рассылаем
                // не чаще, чем раз в QUEST_UPDATE_NOTIFY_COOLDOWN_HOURS часов на квест.
                const QUEST_UPDATE_NOTIFY_COOLDOWN_HOURS = 12;
                const recentUpdateRes = await client.query(
                    `SELECT 1 FROM notifications
                     WHERE quest_id = $1
                       AND type = 'quest_updated'
                       AND created_at > NOW() - ($2 || ' hours')::interval
                     LIMIT 1`,
                    [questId, QUEST_UPDATE_NOTIFY_COOLDOWN_HOURS]
                );

                if (recentUpdateRes.rows.length === 0) {
                    const downloadsRes = await client.query(
                        'SELECT user_id FROM quest_downloads WHERE quest_id = $1',
                        [questId]
                    );
                    const downloadIds = downloadsRes.rows.map(r => r.user_id);
                    const recipients = Array.from(new Set([...followerIds, ...downloadIds]));

                    await createBulkNotifications({
                        userIds: recipients,
                        actorId: userId,
                        type: 'quest_updated',
                        questId,
                        payload: { title, version, is_demo: isDemo }
                    }, client);
                } else {
                    console.log(`⏳ [Notify] Skipped quest_updated for quest ${questId} (cooldown ${QUEST_UPDATE_NOTIFY_COOLDOWN_HOURS}h)`);
                }
            }
        }

        await client.query('COMMIT');

        // Файл занимает постоянное место только у закоммиченной публикации.
        await fsPromises.rename(stagingPath, permFilePath);

        const publishedQuest = resDb.rows[0];
        if (status === 'published') {
            // Пересчёт Meander Cloud tier (best-effort, не блокируем ответ)
            (async () => {
                try {
                    await recomputeTier(userId);
                } catch (e) {
                    console.error('[cloud-sync] tier recompute failed:', e);
                }
            })();
        }

        res.status(201).json({ ...publishedQuest, message: 'Published successfully' });

    } catch (err) {
        if (client) await client.query('ROLLBACK');
        console.error("Publish error:", err);
        const out = toHttpResponse(err);
        res.status(out.status).json(out.body);
    } finally {
        if (client) client.release();
        cleanupPaths.forEach(f => deleteTempFile(f));
    }
});

// ... (остальные роуты без изменений)

router.post('/:id/vote', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" }); 

    const userId = req.user?.id;
    const { action, is_like } = req.body;
    if (!userId) return res.status(401).json({ error: "Unauthorized" });
    try {
        const existingVoteRes = await pool.query(
            'SELECT is_like FROM quest_votes WHERE quest_id = $1 AND user_id = $2',
            [id, userId]
        );
        const previousIsLike = existingVoteRes.rows[0]?.is_like === true;

        if (action === 'remove') await pool.query('DELETE FROM quest_votes WHERE quest_id = $1 AND user_id = $2', [id, userId]);
        else {
             await pool.query(`INSERT INTO quest_votes (quest_id, user_id, is_like) VALUES ($1, $2, $3) ON CONFLICT (quest_id, user_id) DO UPDATE SET is_like = $3, created_at = NOW()`, [id, userId, is_like]);
             if (is_like) {
                 const likesCountRes = await pool.query("SELECT COUNT(*) FROM quest_votes WHERE user_id = $1 AND is_like = TRUE", [userId]);
                 if (parseInt(likesCountRes.rows[0].count) >= 20) {
                     await awardAchievement(userId, 'generous');
                 }
             }
        }
        if (action !== 'remove' && is_like === true && !previousIsLike) {
            const questRes = await pool.query('SELECT author_id, title FROM quests WHERE id = $1', [id]);
            const authorId = questRes.rows[0]?.author_id;
            if (authorId && authorId !== userId) {
                await createNotification({
                    userId: authorId,
                    actorId: userId,
                    type: 'quest_like',
                    questId: id,
                    payload: { title: questRes.rows[0]?.title }
                });
            }
        }
        const likesRes = await pool.query("SELECT COUNT(*) FROM quest_votes WHERE quest_id = $1 AND is_like = TRUE", [id]);
        const dislikesRes = await pool.query("SELECT COUNT(*) FROM quest_votes WHERE quest_id = $1 AND is_like = FALSE", [id]);
        await pool.query("UPDATE quests SET like_count = $1, dislike_count = $2 WHERE id = $3", [likesRes.rows[0].count, dislikesRes.rows[0].count, id]);
        res.json({ success: true, likes: parseInt(likesRes.rows[0].count), dislikes: parseInt(dislikesRes.rows[0].count) });
    } catch (err) { res.status(500).json({ error: 'Vote error' }); }
});

// POST /quests/:id/view — «человек открыл страницу квеста».
//
// Счётчик, а не лог событий: одна строка на (квест, человек, сутки), из неё
// и дневной график, и «разные посетители». Свои просмотры автору не считаем —
// им нечего измерять, он свою страницу и так открывает. Порог в 30 секунд
// отсекает дёрганье «назад → открыть» по тапу.
router.post('/:id/view', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" });

    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: "Unauthorized" });
    try {
        await pool.query(
            `INSERT INTO quest_views (quest_id, user_id, day, views, last_view_at)
             SELECT $1, $2, $3::date, 1, NOW()
               FROM quests q
              WHERE q.id = $1 AND q.author_id <> $2
             ON CONFLICT (quest_id, user_id, day) DO UPDATE
                SET views = quest_views.views +
                        (CASE WHEN NOW() - quest_views.last_view_at >= INTERVAL '30 seconds'
                              THEN 1 ELSE 0 END),
                    last_view_at = NOW()`,
            [id, userId, new Date().toISOString().split('T')[0]]
        );
        res.json({ success: true });
    } catch (err) {
        console.error('quest view:', err);
        res.status(500).json({ error: "Server error" });
    }
});

router.post('/:id/download', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" }); 

    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: "Unauthorized" });
    try {
        const check = await pool.query('SELECT 1 FROM quest_downloads WHERE user_id = $1 AND quest_id = $2', [userId, id]);
        if (check.rows.length === 0) {
            await pool.query('INSERT INTO quest_downloads (user_id, quest_id) VALUES ($1, $2)', [userId, id]);
            await pool.query('UPDATE quests SET downloads_count = downloads_count + 1 WHERE id = $1', [id]);
            
            await awardAchievement(userId, 'first_step'); 
            
            const dlCountRes = await pool.query('SELECT COUNT(*) FROM quest_downloads WHERE user_id = $1', [userId]);
            const dlCount = parseInt(dlCountRes.rows[0].count);
            if (dlCount >= 10) await awardAchievement(userId, 'bookworm');
            if (dlCount >= 50) await awardAchievement(userId, 'library_keeper');
        }
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: "Server error" }); }
});

router.delete('/:id', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" }); 

    const userId = req.user?.id;
    try {
        const q = await pool.query('SELECT author_id FROM quests WHERE id = $1', [id]);
        if (q.rows.length === 0) return res.status(404).json({ error: "Quest not found" });

        if (q.rows[0].author_id !== userId && !(await isAdmin(req))) {
            return res.status(403).json({ error: "Forbidden" });
        }

        const filePath = path.join(QUESTS_STORAGE_DIR, `${id}.mnd`);
        deleteTempFile(filePath);

        await pool.query('DELETE FROM quests WHERE id = $1', [id]);
        res.json({ message: "Quest deleted" });
    } catch (err) { res.status(500).json({ error: "Delete failed" }); }
});

// Public file download endpoint to avoid auth/proxy issues on /static/downloads
router.get('/:id/file', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" });

    const filePath = path.join(QUESTS_STORAGE_DIR, `${id}.mnd`);
    try {
        // Файл тянут и по прямой ссылке, минуя детали квеста, поэтому статус
        // проверяется здесь: мягкое отклонение оставляет .mnd на диске, и без
        // этого gates чужой отклонённый квест качался по id анонимно
        // (проверено на проде: HTTP 200 на rejected-квест).
        const meta = await pool.query('SELECT status, author_id FROM quests WHERE id = $1', [id]);
        if (meta.rows.length === 0) {
            return res.status(404).json({ error: "Quest file not found" });
        }
        const isPrivileged = await canSeeUnpublished(req, meta.rows[0].author_id);
        if (meta.rows[0].status !== 'published' && !isPrivileged) {
            return res.status(404).json({ error: "Quest file not found" });
        }

        if (!fs.existsSync(filePath)) {
            return res.status(404).json({ error: "Quest file not found" });
        }
        res.setHeader('Content-Type', 'application/octet-stream');
        return res.sendFile(filePath);
    } catch (e) {
        return res.status(500).json({ error: "Failed to serve quest file" });
    }
});

router.get('/', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    let showNsfw = false;
    if (req.user?.id) {
        try {
            const pRes = await pool.query('SELECT show_nsfw FROM profiles WHERE id = $1', [req.user.id]);
            if (pRes.rows.length > 0) showNsfw = pRes.rows[0].show_nsfw;
        } catch (_) {}
    }

    const { search, category } = req.query;
    const { text: q, params: p } = marketListQuery({
        search: typeof search === 'string' ? search : undefined,
        category: typeof category === 'string' ? category : undefined,
        showNsfw,
        viewerId: req.user?.id ?? null,
    });

    try {
        const r = await pool.query(q, p);
        res.json(r.rows.map(withPublicDownloadUrl));
    } catch (e) { 
        console.error("GET /quests Search failed:", e);
        res.status(500).json({ error: "Search failed" }); 
    }
});

router.get('/liked-genres', authMiddleware, async (req: AuthRequest, res: Response) => {
    try {
        const userId = req.user?.id;
        if (!userId) return res.json([]);

        const result = await pool.query(`
            SELECT DISTINCT unnest(q.genres) as genre 
            FROM quest_votes qv
            JOIN quests q ON q.id = qv.quest_id
            WHERE qv.user_id = $1 AND qv.is_like = TRUE
        `, [userId]);

        const genres = result.rows.map(r => r.genre).filter(Boolean);
        res.json(genres);
    } catch (e) {
        console.error("GET /quests/liked-genres failed:", e);
        res.status(500).json({ error: "Failed to load liked genres" });
    }
});

router.get('/featured', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    try {
        let showNsfw = false;
        if (req.user?.id) {
            try {
                const pRes = await pool.query('SELECT show_nsfw FROM profiles WHERE id = $1', [req.user.id]);
                if (pRes.rows.length > 0) showNsfw = pRes.rows[0].show_nsfw;
            } catch (_) {}
        }

        const rawLimit = Number(req.query.limit);
        const rawOffset = Number(req.query.offset);
        const limit = Number.isFinite(rawLimit)
            ? Math.min(Math.max(Math.trunc(rawLimit), 1), 200)
            : null;
        const offset = Number.isFinite(rawOffset)
            ? Math.max(Math.trunc(rawOffset), 0)
            : 0;

        let q = "SELECT mq.*, p.cosmetics ->> 'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM market_quests mq LEFT JOIN profiles p ON p.id = mq.author_id WHERE mq.status = 'published' AND mq.is_featured = TRUE";
        const params: any[] = [];
        if (!showNsfw) {
            q += " AND mq.is_nsfw = FALSE";
        }
        q += ` AND NOT EXISTS (SELECT 1 FROM user_blocks ub WHERE ub.user_id = $${params.length + 1} AND ub.blocked_id = mq.author_id)`;
        params.push(req.user?.id ?? null);
        q += " ORDER BY mq.created_at DESC";
        if (limit !== null) {
            params.push(limit);
            q += ` LIMIT $${params.length}`;
        }
        if (offset > 0) {
            params.push(offset);
            q += ` OFFSET $${params.length}`;
        }

        const r = await pool.query(q, params);
        res.json(r.rows.map(withPublicDownloadUrl));
    } catch (e) { 
        console.error("GET /quests/featured failed:", e);
        res.status(500).json({ error: 'Failed to load featured quests' }); 
    }
});

router.get('/activity/recent', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    let showNsfw = false;
    if (req.user?.id) {
        try {
            const pRes = await pool.query('SELECT show_nsfw FROM profiles WHERE id = $1', [req.user.id]);
            if (pRes.rows.length > 0) showNsfw = pRes.rows[0].show_nsfw;
        } catch (_) {}
    }

    const rawLimit = Number(req.query.limit);
    const limit = Number.isFinite(rawLimit)
        ? Math.min(Math.max(Math.trunc(rawLimit), 1), 50)
        : 20;

    try {
        console.log(`[RecentActivity] request user=${req.user?.id ?? 'unknown'} limit=${limit}`);
        const result = await pool.query(
            `
            WITH recent_activity AS (
                -- Публикации квестов
                SELECT
                    concat('publish:', q.id, ':', extract(epoch FROM q.created_at)::bigint) AS id,
                    'quest_published'::text AS event_type,
                    q.created_at,
                    q.author_id AS actor_id,
                    actor.full_name AS actor_name,
                    actor.avatar_url AS actor_avatar_url,
                    actor.is_verified AS actor_is_verified,
                    actor.cosmetics ->> 'name_style' AS actor_name_style, actor.cosmetics AS actor_cosmetics,
                    actor.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
                    q.id AS quest_id,
                    q.title AS quest_title,
                    q.author_id AS target_user_id,
                    actor.full_name AS target_user_name
                FROM quests q
                JOIN profiles actor ON actor.id = q.author_id
                WHERE q.status = 'published'
                  AND (q.is_nsfw = FALSE OR $1 = TRUE)

                UNION ALL

                -- Лайки
                SELECT
                    concat('like:', qv.quest_id, ':', qv.user_id, ':', extract(epoch FROM qv.created_at)::bigint) AS id,
                    'quest_like'::text AS event_type,
                    qv.created_at,
                    qv.user_id AS actor_id,
                    actor.full_name AS actor_name,
                    actor.avatar_url AS actor_avatar_url,
                    actor.is_verified AS actor_is_verified,
                    actor.cosmetics ->> 'name_style' AS actor_name_style, actor.cosmetics AS actor_cosmetics,
                    actor.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
                    q.id AS quest_id,
                    q.title AS quest_title,
                    q.author_id AS target_user_id,
                    target.full_name AS target_user_name
                FROM quest_votes qv
                JOIN quests q ON q.id = qv.quest_id
                JOIN profiles actor ON actor.id = qv.user_id
                JOIN profiles target ON target.id = q.author_id
                WHERE qv.is_like = TRUE
                  AND q.status = 'published'
                  AND (q.is_nsfw = FALSE OR $1 = TRUE)

                UNION ALL

                -- Отзывы
                SELECT
                    concat('review:', r.id) AS id,
                    'quest_review'::text AS event_type,
                    r.created_at,
                    r.author_id AS actor_id,
                    actor.full_name AS actor_name,
                    actor.avatar_url AS actor_avatar_url,
                    actor.is_verified AS actor_is_verified,
                    actor.cosmetics ->> 'name_style' AS actor_name_style, actor.cosmetics AS actor_cosmetics,
                    actor.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
                    q.id AS quest_id,
                    q.title AS quest_title,
                    q.author_id AS target_user_id,
                    target.full_name AS target_user_name
                FROM reviews r
                JOIN quests q ON q.id = r.quest_id
                JOIN profiles actor ON actor.id = r.author_id
                JOIN profiles target ON target.id = q.author_id
                WHERE r.status = 'approved'
                  AND q.status = 'published'
                  AND (q.is_nsfw = FALSE OR $1 = TRUE)

                UNION ALL

                -- Подписки на авторов
                SELECT
                    concat('follow:', uf.user_id, ':', uf.follower_id, ':', extract(epoch FROM uf.created_at)::bigint) AS id,
                    'user_follow'::text AS event_type,
                    uf.created_at,
                    uf.follower_id AS actor_id,
                    actor.full_name AS actor_name,
                    actor.avatar_url AS actor_avatar_url,
                    actor.is_verified AS actor_is_verified,
                    actor.cosmetics ->> 'name_style' AS actor_name_style, actor.cosmetics AS actor_cosmetics,
                    actor.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
                    q.id AS quest_id,
                    q.title AS quest_title,
                    uf.user_id AS target_user_id,
                    target.full_name AS target_user_name
                FROM user_followers uf
                JOIN profiles actor ON actor.id = uf.follower_id
                JOIN profiles target ON target.id = uf.user_id
                LEFT JOIN LATERAL (
                    SELECT id, title
                    FROM quests
                    WHERE author_id = uf.follower_id AND status = 'published'
                    ORDER BY created_at DESC
                    LIMIT 1
                ) q ON TRUE
            )
            SELECT * FROM recent_activity ra
            WHERE NOT EXISTS (
                SELECT 1 FROM user_blocks ub
                WHERE ub.user_id = $3::uuid
                  AND (ub.blocked_id = ra.actor_id OR ub.blocked_id = ra.target_user_id)
            )
            ORDER BY created_at DESC
            LIMIT $2
            `,
            [showNsfw, limit, req.user?.id ?? null]
        );

        console.log(`[RecentActivity] rows=${result.rows.length}`);
        if (result.rows.length > 0) {
            const sample = result.rows[0];
            console.log(
                `[RecentActivity] sample type=${sample.event_type} quest=${sample.quest_id} actor=${sample.actor_id} at=${sample.created_at}`
            );
        } else {
            const diag = await pool.query(
                `
                SELECT
                    (SELECT COUNT(*)::int FROM quests WHERE status = 'published') AS published_quests,
                    (SELECT COUNT(*)::int FROM quest_votes qv JOIN quests q ON q.id = qv.quest_id WHERE qv.is_like = TRUE AND q.status = 'published') AS published_likes,
                    (SELECT COUNT(*)::int FROM reviews r JOIN quests q ON q.id = r.quest_id WHERE r.status = 'approved' AND q.status = 'published') AS approved_reviews,
                    (SELECT COUNT(*)::int FROM user_followers) AS follow_events,
                    (SELECT COUNT(*)::int FROM quest_downloads qd JOIN quests q ON q.id = qd.quest_id WHERE q.status = 'published') AS download_events
                `
            );
            console.log(`[RecentActivity] empty diagnostics`, diag.rows[0]);
        }

        res.json(result.rows);
    } catch (e) {
        console.error('[RecentActivity] failed:', e);
        res.status(500).json({ error: 'Failed to load recent activity' });
    }
});

router.post('/:id/admin/action', authMiddleware, adminAuth, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" });

    const action = (req.body?.action || '').toString();
    const value = req.body?.value;

    try {
        if (action === 'set_demo') {
            const result = await pool.query(
                'UPDATE quests SET is_demo = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
                [value === true, id]
            );
            if (result.rows.length === 0) return res.status(404).json({ error: 'Quest not found' });
            return res.json(result.rows[0]);
        }

        if (action === 'set_nsfw') {
            const result = await pool.query(
                'UPDATE quests SET is_nsfw = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
                [value === true, id]
            );
            if (result.rows.length === 0) return res.status(404).json({ error: 'Quest not found' });
            return res.json(result.rows[0]);
        }

        if (action === 'set_featured') {
            const result = await pool.query(
                'UPDATE quests SET is_featured = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
                [value === true, id]
            );
            if (result.rows.length === 0) return res.status(404).json({ error: 'Quest not found' });
            return res.json(result.rows[0]);
        }

        if (action === 'set_status') {
            const nextStatus = (value || '').toString();
            if (!['published', 'in_review', 'rejected'].includes(nextStatus)) {
                return res.status(400).json({ error: 'Invalid status' });
            }
            const result = await pool.query(
                'UPDATE quests SET status = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
                [nextStatus, id]
            );
            if (result.rows.length === 0) return res.status(404).json({ error: 'Quest not found' });

            // Пересчёт Meander Cloud tier автора (best-effort)
            const authorId = result.rows[0].author_id;
            if (authorId) {
                // Смена статуса из админ-шиты карточки раньше была безмолвной:
                // автор узнавал об «Отклонено» только зайдя в «Мои публикации».
                // Очередь модерации (admin/quest/:id/review) уже уведомляет —
                // здесь тот же набор типов.
                if (nextStatus === 'published' || nextStatus === 'rejected') {
                    createNotification({
                        userId: authorId,
                        actorId: req.user?.id ?? null,
                        type: nextStatus === 'published' ? 'quest_approved' : 'quest_rejected',
                        questId: id,
                        payload: { title: result.rows[0].title },
                    }).catch((e) => console.error('[moderation] author notification failed:', e));
                }

                (async () => {
                    try {
                        await recomputeTier(authorId);
                    } catch (e) {
                        console.error('[cloud-sync] tier recompute on status change failed:', e);
                    }
                })();
            }
            return res.json(result.rows[0]);
        }

        return res.status(400).json({ error: 'Unknown admin action' });
    } catch (e) {
        console.error('[QuestAdminAction] failed:', e);
        return res.status(500).json({ error: 'Server error' });
    }
});

// GET /quests/analytics/author?days=30 — сводка по всем квестам автора.
//
// Регистрируется до `/:id/analytics`: путь из двух сегментов, и путать их
// незачем. Цифры те же, что и в карточке квеста, — считается общими
// функциями, а не вторым слоем правил.
router.get('/analytics/author', authMiddleware, async (req: AuthRequest, res: Response) => {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });
    try {
        res.json(await getAuthorAnalytics(userId, clampDays(req.query.days)));
    } catch (e) {
        console.error('[AuthorAnalytics] failed:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// GET /quests/:id/analytics?days=30 — подробная статистика квеста.
//
// Видна только автору и админу: цифры чужого квеста — не «открытая аналитика»,
// а разведка конкурента. Ответ один и целиком: дневной ряд, два окна (текущее
// и предыдущее той же длины), итога за всё время и распределение оценок.
router.get('/:id/analytics', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid ID format' });
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });
    try {
        const ownerRes = await pool.query('SELECT author_id FROM quests WHERE id = $1', [id]);
        if (ownerRes.rows.length === 0) return res.status(404).json({ error: 'Quest not found' });
        if (ownerRes.rows[0].author_id !== userId && !(await isAdmin(req))) {
            return res.status(403).json({ error: 'Статистику видит только автор квеста' });
        }
        const analytics = await getQuestAnalytics(id, clampDays(req.query.days));
        res.json(analytics);
    } catch (e) {
        console.error('[QuestAnalytics] failed:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

router.get('/:id', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    if (!uuidValidate(req.params.id)) return res.status(400).json({ error: "Invalid ID format" });

    const userId = req.user?.id;

    try {
        // Заблокированный автор недоступен и по прямой ссылке — иначе обход
        // ленты возвращал бы тот же квест через сохранённый id.
        if (userId) {
            const blocked = await pool.query(
                `SELECT 1 FROM user_blocks ub
                   JOIN quests q ON q.author_id = ub.blocked_id
                  WHERE ub.user_id = $1 AND q.id = $2`,
                [userId, req.params.id],
            );
            if (blocked.rows.length > 0) {
                return res.status(404).json({ error: "Quest not found or access denied" });
            }
        }

        const r = await pool.query(
            "SELECT mq.*, p.cosmetics ->> 'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM market_quests mq LEFT JOIN profiles p ON p.id = mq.author_id WHERE mq.id = $1",
            [req.params.id],
        );

        if (r.rows.length === 0) {
            const raw = await pool.query("SELECT * FROM quests WHERE id = $1", [req.params.id]);
            if (raw.rows.length > 0) {
                if (await canSeeUnpublished(req, raw.rows[0].author_id)) {
                    return res.json(withPublicDownloadUrl(raw.rows[0]));
                }
            }
            return res.status(404).json({ error: "Quest not found or access denied" });
        }

        // `market_quests` не фильтрует по статусу (проверено на проде через
        // pg_get_viewdef), поэтому unpublished-квест приходил к любому, кто знает
        // id: с download_url, картинками и moderator_comment. Право на такую
        // работу — только у автора и администратора (роль берём из базы, не из
        // токена: пониженный админ не должен сохранять доступ).
        const quest = r.rows[0];
        const isPrivileged = await canSeeUnpublished(req, quest.author_id);
        if (quest.status !== 'published' && !isPrivileged) {
            return res.status(404).json({ error: "Quest not found or access denied" });
        }

        res.json(withPublicDownloadUrl(quest));
    } catch (e) { res.status(500).json({ error: 'Failed to load quest details' }); }
});

router.get('/:id/reviews', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    if (!uuidValidate(req.params.id)) return res.status(400).json({ error: "Invalid ID format" }); 
    try { const r = await pool.query(`SELECT r.*, p.full_name as author_name, p.avatar_url as author_avatar_url, p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics, rt.rating as rating FROM reviews r JOIN profiles p ON r.author_id = p.id LEFT JOIN ratings rt ON (r.quest_id = rt.quest_id AND r.author_id = rt.user_id) WHERE r.quest_id = $1 AND r.status = 'approved' ORDER BY r.created_at DESC`, [req.params.id]); res.json(r.rows); } catch (e) { res.status(500).json({ error: 'Failed to load reviews' }); }
});

router.get('/:id/screenshots', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    if (!uuidValidate(req.params.id)) return res.status(400).json({ error: "Invalid ID format" }); 
    try { const r = await pool.query("SELECT * FROM quest_screenshots WHERE quest_id = $1 ORDER BY sort_order", [req.params.id]); res.json(r.rows); } catch (e) { res.status(500).json({ error: 'Failed to load screenshots' }); }
});

router.get('/:id/my-vote', authMiddleware, async (req: AuthRequest, res: Response) => {
    if (!uuidValidate(req.params.id)) return res.status(400).json({ error: "Invalid ID format" }); 
    try { const r = await pool.query("SELECT is_like FROM quest_votes WHERE quest_id = $1 AND user_id = $2", [req.params.id, req.user?.id]); if (r.rows.length === 0) return res.json({}); res.json(r.rows[0]); } catch (e) { res.status(500).json({ error: 'Failed to load vote' }); }
});

router.get('/:id/my-review', authMiddleware, async (req: AuthRequest, res: Response) => {
    if (!uuidValidate(req.params.id)) return res.status(400).json({ error: "Invalid ID format" }); 
    try { const rate = await pool.query("SELECT rating FROM ratings WHERE quest_id = $1 AND user_id = $2", [req.params.id, req.user?.id]); const rev = await pool.query("SELECT text_content FROM reviews WHERE quest_id = $1 AND author_id = $2", [req.params.id, req.user?.id]); res.json({ rating: rate.rows[0]?.rating, text_content: rev.rows[0]?.text_content }); } catch (e) { res.status(500).json({ error: 'Failed to load review data' }); }
});

router.post('/:id/rate', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params; const { rating } = req.body;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" }); 

    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: "Unauthorized" });

    // Значение шло прямо в INSERT: сработал бы CHECK (rating 1..5) или FK на
    // quests, обработчик вернул 500, а клиент на любую 500 показывает
    // «Сервер на обслуживании» — человек вместо «квеста уже нет» видел
    // техработы.
    const value = Number(rating);
    if (!Number.isInteger(value) || value < 1 || value > 5) {
        return res.status(400).json({ error: "Rating must be an integer from 1 to 5" });
    }

    try {
        const quest = await pool.query('SELECT id FROM quests WHERE id = $1', [id]);
        if (quest.rows.length === 0) return res.status(404).json({ error: "Quest not found" });

        await pool.query(`INSERT INTO ratings (quest_id, user_id, rating) VALUES ($1, $2, $3) ON CONFLICT (quest_id, user_id) DO UPDATE SET rating = $3, created_at = NOW()`, [id, userId, value]);
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: 'Server error' }); }
});

router.post('/:id/review', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { id } = req.params; const { text_content } = req.body;
    if (!uuidValidate(id)) return res.status(400).json({ error: "Invalid ID format" }); 
    
    try {
        // Проверяем, не заблокирован ли пользователь
        const userCheck = await pool.query('SELECT is_blocked FROM profiles WHERE id = $1', [req.user?.id]);
        if (userCheck.rows.length === 0) {
            return res.status(404).json({ error: "User not found" });
        }
        if (userCheck.rows[0].is_blocked === true) {
            return res.status(403).json({ error: "Your account is blocked. You cannot post reviews." });
        }

        // Модерация отзыва по правилам
        if (text_content && text_content.trim().length > 2) {
            const questCheck = await pool.query('SELECT author_id FROM quests WHERE id = $1', [id]);
            const questAuthorId = questCheck.rows[0]?.author_id;

            const allowAds = req.user?.id === questAuthorId || await isStaff(req);

            const reviewMod = await moderateReview(text_content, allowAds);
            if (!reviewMod.approved) {
                return res.status(400).json({ error: `Review not allowed: ${reviewMod.reason}` });
            }
        }
        
        const ex = await pool.query("SELECT id FROM reviews WHERE quest_id = $1 AND author_id = $2", [id, req.user?.id]);
        let reviewId: string | null = null;
        let isNewReview = false;

        if (ex.rows.length > 0) {
            const updated = await pool.query(
                "UPDATE reviews SET text_content = $1, status = 'approved', created_at = NOW() WHERE id = $2 RETURNING id",
                [text_content, ex.rows[0].id]
            );
            reviewId = updated.rows[0]?.id ?? ex.rows[0].id;
        } else {
            const inserted = await pool.query(
                `INSERT INTO reviews (id, quest_id, author_id, text_content, status) VALUES (gen_random_uuid(), $1, $2, $3, 'approved') RETURNING id`,
                [id, req.user?.id, text_content]
            );
            reviewId = inserted.rows[0]?.id ?? null;
            isNewReview = true;
            await awardAchievement(req.user?.id, 'critic_bronze');
        }

        if (isNewReview) {
            const questRes = await pool.query('SELECT author_id, title FROM quests WHERE id = $1', [id]);
            const authorId = questRes.rows[0]?.author_id;
            if (authorId && authorId !== req.user?.id) {
                await createNotification({
                    userId: authorId,
                    actorId: req.user?.id,
                    type: 'quest_review',
                    questId: id,
                    reviewId,
                    payload: { title: questRes.rows[0]?.title }
                });
            }
        }
        res.json({ success: true, status: 'approved' });
    } catch (err) { res.status(500).json({ error: 'Server error' }); }
});

export default router;
