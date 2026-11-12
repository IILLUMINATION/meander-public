import { Router, Request, Response, NextFunction } from 'express';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import pool from '../config/database';
import { publicUrl } from '../config/public_host';
import authMiddleware, { AuthRequest, optionalAuthMiddleware } from '../middleware/auth';
import multer from 'multer';
import fs from 'fs';
import fsPromises from 'fs/promises';
import path from 'path';
import os from 'os';
import { v4 as uuidv4, validate as uuidValidate } from 'uuid';
import { pipeline } from 'stream/promises';
import { uploadImage } from '../services/image_host';
import { canSeeUnpublished, isStaff } from '../services/visibility';
import { moderateReview } from '../services/moderation';
import { awardAchievement } from '../services/achievements';
import { createNotification } from '../services/notifications';
import { checkUploadAllowed, hashFile } from '../services/upload_guard';
import { clientIp } from '../services/client_ip';

function sanitizeText(str: string, maxLength = 5000): string {
  if (typeof str !== 'string') return '';
  return str.replace(/<[^>]*>/g, '').trim().substring(0, maxLength);
}
function deleteTempFile(p: string) { fsPromises.unlink(p).catch(() => {}); }

const router = Router();
const TEMP_DIR = path.join(os.tmpdir(), 'meander_uploads');
const PUBLIC_DIR = path.join(path.resolve(__dirname, '../../'), 'public');
const ASSETS_DIR = path.join(PUBLIC_DIR, 'assets_files');
if (!fs.existsSync(TEMP_DIR)) fs.mkdirSync(TEMP_DIR, { recursive: true });
if (!fs.existsSync(ASSETS_DIR)) fs.mkdirSync(ASSETS_DIR, { recursive: true });

const getPublicAssetUrl = (id: string) => publicUrl(`/assets/${id}/file`);

const ALLOWED_KINDS = ['button_preset', 'background', 'image', 'sfx', 'font', 'music'] as const;

const kindExtensions: Record<string, string[]> = {
  // Пресет кнопок: ZIP (presets.json + текстуры) — старые JSON тоже принимаем.
  button_preset: ['.json', '.zip'],
  background: ['.jpg', '.jpeg', '.png', '.webp'],
  image: ['.jpg', '.jpeg', '.png', '.webp'],
  sfx: ['.mp3', '.wav', '.ogg', '.m4a', '.flac', '.aac'],
  font: ['.ttf', '.otf', '.woff', '.woff2'],
  music: ['.mp3', '.wav', '.ogg', '.m4a', '.flac', '.aac'],
};

const storage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, TEMP_DIR),
  filename: (_req, file, cb) => cb(null, `asset_${Date.now()}_${Math.random().toString(36).slice(2)}${path.extname(file.originalname)}`)
});

const upload = multer({
  storage,
  limits: { fileSize: 100 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    if (file.fieldname === 'cover') {
      const ok = ['.jpg', '.jpeg', '.png', '.webp'].includes(ext);
      return ok ? cb(null, true) : cb(new Error('Invalid cover type'));
    }
    if (file.fieldname === 'assetFile') {
      // allow any, check kind later
      return cb(null, true);
    }
    return cb(new Error('Unexpected field'));
  }
});

// Лимит попыток — до multer: отказ не должен принимать 100 МБ файл.
const uploadAttempts = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 20,
  keyGenerator: (req: Request) =>
    (req as AuthRequest).user?.id || ipKeyGenerator(clientIp(req)),
  standardHeaders: true,
});

async function guardUpload(req: AuthRequest, res: Response, next: NextFunction) {
  try {
    const denial = await checkUploadAllowed(req.user?.id as string, 'market_assets');
    if (denial) return res.status(denial.status).json({ error: denial.error });
    next();
  } catch (e) {
    console.error('[assets] upload guard failed', e);
    res.status(503).json({ error: 'Upload temporarily unavailable' });
  }
}

// POST /assets - upload
router.post('/', authMiddleware, uploadAttempts, guardUpload, upload.fields([{ name: 'assetFile', maxCount: 1 }, { name: 'cover', maxCount: 1 }]), async (req: AuthRequest, res: Response) => {
  const files = req.files as { [k: string]: Express.Multer.File[] } | undefined;
  const assetFile = files?.['assetFile']?.[0];
  const coverFile = files?.['cover']?.[0];
  // Постоянный файл удаляем, если строка БД так и не появилась: иначе при
  // сбое после копирования оставался orphan, который не убирает обычный DELETE.
  let destPath: string | null = null;
  let persisted = false;
  try {
    const userId = (req as any).user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });
    if (!assetFile) return res.status(400).json({ error: 'assetFile required' });
    const kind = sanitizeText((req.body.kind as string) || '', 50);
    if (!ALLOWED_KINDS.includes(kind as any)) { deleteTempFile(assetFile.path); if (coverFile) deleteTempFile(coverFile.path); return res.status(400).json({ error: 'Invalid kind. Allowed: ' + ALLOWED_KINDS.join(', ') }); }
    const title = sanitizeText((req.body.title as string) || '', 200);
    const genre = sanitizeText((req.body.genre as string) || '', 100);
    const license = sanitizeText((req.body.license as string) || 'CC-BY', 500);
    const description = sanitizeText((req.body.description as string) || '', 2000);
    if (!title) { deleteTempFile(assetFile.path); if (coverFile) deleteTempFile(coverFile.path); return res.status(400).json({ error: 'title required' }); }


    const ext = path.extname(assetFile.originalname).toLowerCase();
    const allowed = kindExtensions[kind] || [];
    if (allowed.length && !allowed.includes(ext)) {
      deleteTempFile(assetFile.path); if (coverFile) deleteTempFile(coverFile.path);
      return res.status(400).json({ error: `Invalid extension for kind ${kind}. Allowed: ${allowed.join(', ')}` });
    }

    const id = uuidv4();
    const destName = `${id}${ext}`;
    destPath = path.join(ASSETS_DIR, destName);
    await pipeline(fs.createReadStream(assetFile.path), fs.createWriteStream(destPath));
    deleteTempFile(assetFile.path);
    const hash = await hashFile(destPath);
    const stat = await fsPromises.stat(destPath);

    // dedup
    try {
      const dup = await pool.query('SELECT id FROM market_assets WHERE file_hash=$1 LIMIT 1', [hash]);
      if (dup.rows.length) { await fsPromises.unlink(destPath).catch(()=>{}); if (coverFile) deleteTempFile(coverFile.path); return res.status(409).json({ error: 'Duplicate file' }); }
    } catch {}

    let coverUrl: string | null = null;
    if (coverFile) { try { coverUrl = await uploadImage(coverFile.path); } catch (e) { console.warn('[assets] cover failed', e); } deleteTempFile(coverFile.path); }

    const fileUrl = getPublicAssetUrl(id);
    const genres = genre ? [genre] : [];
    const now = new Date();
    const ins = await pool.query(
      `INSERT INTO market_assets (id, kind, title, description, genre, genres, file_url, cover_url, license, file_hash, file_size_bytes, status, author_id, created_at, updated_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,'in_review',$12,$13,$13) RETURNING *`,
      [id, kind, title, description || null, genre || null, genres, fileUrl, coverUrl, license, hash, stat.size, userId, now]
    );
    persisted = true;
    const row = ins.rows[0];
    const author = (await pool.query('SELECT full_name, is_verified FROM profiles WHERE id=$1', [userId])).rows[0];
    const out = { ...row, author_name: author?.full_name || null, author_is_verified: !!author?.is_verified, download_url: fileUrl };
    return res.status(201).json(out);
  } catch (e: any) {
    console.error('[assets] POST', e);
    if (assetFile) deleteTempFile(assetFile.path);
    const cf = (req.files as any)?.['cover']?.[0]; if (cf) deleteTempFile(cf.path);
    if (!persisted && destPath) fsPromises.unlink(destPath).catch(() => {});
    return res.status(500).json({ error: e.message || 'Internal error' });
  }
});

// GET /assets - list published
router.get('/', optionalAuthMiddleware, async (req, res: Response) => {
  try {
    const search = (req.query.search as string) || '';
    const kind = (req.query.kind as string) || '';
    const genre = (req.query.genre as string) || '';
    const authorId = (req.query.author_id as string) || (req.query.authorId as string) || '';
    const limit = Math.min(Math.max(parseInt(req.query.limit as string) || 50, 1), 200);
    const offset = Math.max(parseInt(req.query.offset as string) || 0, 0);
    const where: string[] = [`status='published'`];
    const params: any[] = [];
    let idx = 1;
    if (search) { where.push(`(title ILIKE $${idx} OR description ILIKE $${idx})`); params.push(`%${search}%`); idx++; }
    if (kind && ALLOWED_KINDS.includes(kind as any)) { where.push(`kind=$${idx}`); params.push(kind); idx++; }
    if (genre) { where.push(`(genre=$${idx} OR $${idx}=ANY(genres))`); params.push(genre); idx++; }
    if (authorId && uuidValidate(authorId)) { where.push(`m.author_id=$${idx}`); params.push(authorId); idx++; }
    const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';
    const q = `SELECT m.*, p.full_name AS author_name, p.is_verified AS author_is_verified, p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM market_assets m LEFT JOIN profiles p ON m.author_id=p.id ${whereSql} ORDER BY m.created_at DESC LIMIT $${idx} OFFSET $${idx+1}`;
    params.push(limit, offset);
    const r = await pool.query(q, params);
    const rows = r.rows.map((row: any) => ({ ...row, download_url: getPublicAssetUrl(row.id), file_url: getPublicAssetUrl(row.id) }));
    return res.json(rows);
  } catch (e: any) {
    console.error('[assets] GET', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

router.get('/:id', optionalAuthMiddleware, async (req, res: Response) => {
  try {
    const id = req.params.id;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid id' });
    const r = await pool.query(`SELECT m.*, p.full_name AS author_name, p.is_verified AS author_is_verified, p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM market_assets m LEFT JOIN profiles p ON m.author_id=p.id WHERE m.id=$1`, [id]);
    if (!r.rows.length) return res.status(404).json({ error: 'Not found' });
    const row = r.rows[0];
    const userId = (req as any).user?.id;
    if (row.status !== 'published' && row.author_id !== userId) {
      if (userId) { const pr = await pool.query(`SELECT role FROM profiles WHERE id=$1`, [userId]); if (pr.rows[0]?.role !== 'admin') return res.status(403).json({ error: 'Not published' }); } else return res.status(403).json({ error: 'Not published' });
    }
    const out = { ...row, download_url: getPublicAssetUrl(row.id), file_url: getPublicAssetUrl(row.id) };
    return res.json(out);
  } catch (e: any) {
    console.error('[assets] GET :id', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

router.get('/:id/file', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
  try {
    const id = req.params.id;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid id' });
    // Статус проверяется и здесь: карточка ассета его прячет, а прямая ссылка
    // на файл раньше об этом не знала.
    const r = await pool.query(`SELECT status, author_id FROM market_assets WHERE id=$1`, [id]);
    if (!r.rows.length) return res.status(404).json({ error: 'Not found' });
    if (r.rows[0].status !== 'published' && !(await canSeeUnpublished(req, r.rows[0].author_id))) {
      return res.status(403).json({ error: 'Not published' });
    }
    const files = await fsPromises.readdir(ASSETS_DIR).catch(() => [] as string[]);
    const match = files.find(f => f.startsWith(id + '.'));
    if (!match) return res.status(404).json({ error: 'File not found' });
    const full = path.join(ASSETS_DIR, match);
    const contentTypes: Record<string, string> = {
      '.mp3': 'audio/mpeg',
      '.wav': 'audio/wav',
      '.ogg': 'audio/ogg',
      '.m4a': 'audio/mp4',
      '.flac': 'audio/flac',
      '.aac': 'audio/aac',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.webp': 'image/webp',
      '.ttf': 'font/ttf',
      '.otf': 'font/otf',
      '.woff': 'font/woff',
      '.woff2': 'font/woff2',
    };
    const ext = path.extname(match).toLowerCase();
    const contentType = contentTypes[ext] || 'application/octet-stream';
    // SEC-18: инлайн — только для медиа и шрифтов; неизвестный тип отдаём
    // вложением, чтобы браузер не пытался его отрисовать.
    const inline = /^(image|audio|video|font)\//.test(contentType);
    res.setHeader('Content-Type', contentType);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Disposition', `${inline ? 'inline' : 'attachment'}; filename="${match}"`);
    return res.sendFile(full);
  } catch (e: any) {
    console.error('[assets] file', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

router.delete('/:id', authMiddleware, async (req: AuthRequest, res: Response) => {
  try {
    const id = req.params.id;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid id' });
    const userId = (req as any).user?.id;
    const r = await pool.query(`SELECT author_id FROM market_assets WHERE id=$1`, [id]);
    if (!r.rows.length) return res.status(404).json({ error: 'Not found' });
    const pr = await pool.query(`SELECT role FROM profiles WHERE id=$1`, [userId]);
    const isAdmin = pr.rows[0]?.role === 'admin';
    if (r.rows[0].author_id !== userId && !isAdmin) return res.status(403).json({ error: 'Forbidden' });
    await pool.query(`DELETE FROM market_assets WHERE id=$1`, [id]);
    const files = await fsPromises.readdir(ASSETS_DIR).catch(() => [] as string[]);
    const m = files.find((f: string) => f.startsWith(id + '.'));
    if (m) await fsPromises.unlink(path.join(ASSETS_DIR, m)).catch(()=>{});
    return res.json({ ok: true });
  } catch (e: any) {
    console.error('[assets] DELETE', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

router.post('/:id/admin/action', authMiddleware, async (req: AuthRequest, res: Response) => {
  try {
    const id = req.params.id;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid id' });
    const userId = (req as any).user?.id;
    const pr = await pool.query(`SELECT role FROM profiles WHERE id=$1`, [userId]);
    if (pr.rows[0]?.role !== 'admin') return res.status(403).json({ error: 'Admin only' });
    const { action, value } = req.body;
    if (action === 'set_status') {
      const allowed = ['published','in_review','rejected'];
      if (!allowed.includes(value)) return res.status(400).json({ error: 'Invalid status' });
      await pool.query(`UPDATE market_assets SET status=$1, updated_at=NOW() WHERE id=$2`, [value, id]);
      const r = await pool.query(`SELECT m.*, p.full_name AS author_name, p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM market_assets m LEFT JOIN profiles p ON m.author_id=p.id WHERE m.id=$1`, [id]);
      return res.json(r.rows[0]);
    }
    return res.status(400).json({ error: 'Unknown action' });
  } catch (e: any) {
    console.error('[assets] admin', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

// --- Votes ---
router.post('/:id/vote', authMiddleware, async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid ID format' });
  const userId = req.user?.id;
  const { action, is_like } = req.body;
  if (!userId) return res.status(401).json({ error: 'Unauthorized' });
  try {
    const existing = await pool.query('SELECT is_like FROM asset_votes WHERE asset_id=$1 AND user_id=$2', [id, userId]);
    const prev = existing.rows[0]?.is_like;
    if (action === 'remove') {
      await pool.query('DELETE FROM asset_votes WHERE asset_id=$1 AND user_id=$2', [id, userId]);
    } else {
      await pool.query(`INSERT INTO asset_votes (asset_id, user_id, is_like) VALUES ($1,$2,$3) ON CONFLICT (asset_id, user_id) DO UPDATE SET is_like=$3, created_at=NOW()`, [id, userId, !!is_like]);
      if (is_like && !prev) {
        try { const c = await pool.query('SELECT COUNT(*) FROM asset_votes WHERE user_id=$1 AND is_like=TRUE', [userId]); if (parseInt(c.rows[0].count) >= 20) await awardAchievement(userId, 'generous'); } catch {}
      }
    }
    const likes = await pool.query('SELECT COUNT(*) FROM asset_votes WHERE asset_id=$1 AND is_like=TRUE', [id]);
    const dislikes = await pool.query('SELECT COUNT(*) FROM asset_votes WHERE asset_id=$1 AND is_like=FALSE', [id]);
    try { await pool.query('UPDATE market_assets SET like_count=$1, dislike_count=$2 WHERE id=$3', [likes.rows[0].count, dislikes.rows[0].count, id]); } catch {}
    res.json({ success: true, likes: parseInt(likes.rows[0].count), dislikes: parseInt(dislikes.rows[0].count) });
  } catch (e: any) { console.error('[assets] vote', e); res.status(500).json({ error: 'Vote error' }); }
});

router.get('/:id/my-vote', authMiddleware, async (req: AuthRequest, res: Response) => {
  if (!uuidValidate(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  try { const r = await pool.query('SELECT is_like FROM asset_votes WHERE asset_id=$1 AND user_id=$2', [req.params.id, req.user?.id]); if (!r.rows.length) return res.json({}); res.json(r.rows[0]); } catch (e) { res.status(500).json({ error: 'Failed' }); }
});

router.get('/:id/reviews', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
  if (!uuidValidate(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  try { const r = await pool.query(`SELECT r.*, p.full_name AS author_name, p.avatar_url AS author_avatar_url, p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM asset_reviews r JOIN profiles p ON r.author_id=p.id WHERE r.asset_id=$1 AND r.status='approved' ORDER BY r.created_at DESC`, [req.params.id]); res.json(r.rows); } catch (e) { res.status(500).json({ error: 'Failed to load reviews' }); }
});

router.get('/:id/my-review', authMiddleware, async (req: AuthRequest, res: Response) => {
  if (!uuidValidate(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  try { const r = await pool.query(`SELECT r.text_content AS text_content, r.status FROM asset_reviews r WHERE r.asset_id=$1 AND r.author_id=$2`, [req.params.id, req.user?.id]); if (!r.rows.length) return res.json({}); const row = r.rows[0]; res.json({ rating: 0, text: row.text_content, text_content: row.text_content, status: row.status }); } catch (e) { res.status(500).json({ error: 'Failed' }); }
});

router.post('/:id/review', authMiddleware, async (req: AuthRequest, res: Response) => {
  const { id } = req.params; const { text_content } = req.body;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid ID format' });
  try {
    const blk = await pool.query('SELECT is_blocked FROM profiles WHERE id=$1', [req.user?.id]);
    if (blk.rows[0]?.is_blocked) return res.status(403).json({ error: 'Blocked' });
    if (text_content && text_content.trim().length > 2) {
      try {
        const assetCheck = await pool.query('SELECT author_id FROM market_assets WHERE id=$1', [id]);
        const allowAds = req.user?.id === assetCheck.rows[0]?.author_id || await isStaff(req);
        const mod = await moderateReview(text_content, allowAds);
        if (!mod.approved) return res.status(400).json({ error: `Review not allowed: ${mod.reason}` });
      } catch (e) { console.error('Review moderation failed', e); }
    }
    const ex = await pool.query('SELECT id FROM asset_reviews WHERE asset_id=$1 AND author_id=$2', [id, req.user?.id]);
    let reviewId: string | null = null;
    if (ex.rows.length) {
      const upd = await pool.query(`UPDATE asset_reviews SET text_content=$1, status='approved', created_at=NOW() WHERE id=$2 RETURNING id`, [text_content, ex.rows[0].id]);
      reviewId = upd.rows[0]?.id ?? ex.rows[0].id;
    } else {
      const ins = await pool.query(`INSERT INTO asset_reviews (id, asset_id, author_id, text_content, status) VALUES (gen_random_uuid(), $1,$2,$3,'approved') RETURNING id`, [id, req.user?.id, text_content]);
      reviewId = ins.rows[0]?.id; await awardAchievement(req.user?.id, 'critic_bronze');
    }
    res.json({ success: true, status: 'approved', id: reviewId });
  } catch (e: any) { console.error('[assets] review', e); res.status(500).json({ error: 'Server error' }); }
});

export default router;
