import { Router, Response } from 'express';
import pool from '../config/database';
import { publicUrl } from '../config/public_host';
import authMiddleware, { AuthRequest, optionalAuthMiddleware } from '../middleware/auth';
import multer from 'multer';
import fs from 'fs';
import fsPromises from 'fs/promises';
import path from 'path';
import os from 'os';
import { v4 as uuidv4, validate as uuidValidate } from 'uuid';
import crypto from 'crypto';
import { pipeline } from 'stream/promises';

import { uploadImage } from '../services/image_host';
import { canSeeUnpublished, isStaff } from '../services/visibility';
import { moderateReview } from '../services/moderation';
import { awardAchievement } from '../services/achievements';

function stripHtml(str: string): string {
  if (typeof str !== 'string') return '';
  return str.replace(/<[^>]*>/g, '').trim();
}
function sanitizeText(str: string, maxLength: number = 5000): string {
  return stripHtml(str).substring(0, maxLength);
}
function deleteTempFile(p: string) {
  fsPromises.unlink(p).catch(() => {});
}

const router = Router();

const TEMP_DIR = path.join(os.tmpdir(), 'meander_uploads');
const PROJECT_ROOT = path.resolve(__dirname, '../../');
const PUBLIC_DIR = path.join(PROJECT_ROOT, 'public');
const MUSIC_STORAGE_DIR = path.join(PUBLIC_DIR, 'music_files');

if (!fs.existsSync(TEMP_DIR)) fs.mkdirSync(TEMP_DIR, { recursive: true });
if (!fs.existsSync(MUSIC_STORAGE_DIR)) fs.mkdirSync(MUSIC_STORAGE_DIR, { recursive: true });

const getPublicMusicUrl = (id: string) => publicUrl(`/music/${id}/file`);

const allowedAudioExtensions = ['.mp3', '.wav', '.ogg', '.m4a', '.flac', '.aac'];
const allowedAudioMimeTypes = [
  'audio/mpeg', 'audio/mp3', 'audio/wav', 'audio/x-wav', 'audio/wave',
  'audio/ogg', 'audio/vorbis', 'audio/mp4', 'audio/x-m4a', 'audio/flac', 'audio/x-flac', 'audio/aac', 'audio/x-aac',
  'application/octet-stream', '', 'binary/octet-stream'
];
const allowedImageExtensions = ['.jpg', '.jpeg', '.png', '.webp'];
const allowedImageMimeTypes = ['image/jpeg', 'image/png', 'image/webp', 'application/octet-stream', ''];

const storage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, TEMP_DIR),
  filename: (_req, file, cb) => cb(null, `music_${Date.now()}_${Math.random().toString(36).slice(2)}${path.extname(file.originalname)}`)
});

const upload = multer({
  storage,
  limits: { fileSize: 100 * 1024 * 1024 }, // 100 MB
  fileFilter: (_req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    const mime = (file.mimetype || '').toLowerCase();
    if (file.fieldname === 'musicFile') {
      const okExt = allowedAudioExtensions.includes(ext);
      const okMime = allowedAudioMimeTypes.includes(mime) || mime.startsWith('audio/');
      if (!okExt) return cb(new Error('Invalid music file type'));
      // permissive mime check for audio
      return cb(null, true);
    }
    if (file.fieldname === 'cover') {
      const okExt = allowedImageExtensions.includes(ext);
      const okMime = allowedImageMimeTypes.includes(mime);
      if (!okExt || !okMime) return cb(new Error('Invalid image file type'));
      return cb(null, true);
    }
    return cb(new Error('Unexpected upload field'));
  }
});

function calcFileHash(filePath: string): string {
  const buf = fs.readFileSync(filePath);
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// POST /music - upload track (spam protection: block check + 5/hour limit + hash dedup)
router.post('/', authMiddleware, upload.fields([{ name: 'musicFile', maxCount: 1 }, { name: 'cover', maxCount: 1 }]), async (req: AuthRequest, res: Response) => {
  const files = req.files as { [k: string]: Express.Multer.File[] } | undefined;
  const musicFile = files?.['musicFile']?.[0];
  const coverFile = files?.['cover']?.[0];
  try {
    const userId = (req as any).user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });
    if (!musicFile) return res.status(400).json({ error: 'musicFile is required' });

    // spam protection: blocked users & rate limit 5/hour
    try {
      const blk = await pool.query('SELECT is_blocked FROM profiles WHERE id=$1', [userId]);
      if (blk.rows[0]?.is_blocked) {
        deleteTempFile(musicFile.path); if (coverFile) deleteTempFile(coverFile.path);
        return res.status(403).json({ error: 'You are blocked' });
      }
      const recent = await pool.query("SELECT COUNT(*) FROM music_tracks WHERE author_id=$1 AND created_at > NOW() - INTERVAL '1 hour'", [userId]);
      if (parseInt(recent.rows[0].count) >= 5) {
        deleteTempFile(musicFile.path); if (coverFile) deleteTempFile(coverFile.path);
        return res.status(429).json({ error: 'Too many uploads. Max 5 per hour.' });
      }
    } catch (e) { console.warn('[music] spam check failed', e); }

    const title = sanitizeText((req.body.title as string) || '', 200);
    const performer = sanitizeText((req.body.performer as string) || '', 200);
    const genre = sanitizeText((req.body.genre as string) || '', 100);
    const license = sanitizeText((req.body.license as string) || 'CC-BY', 500);
    const description = sanitizeText((req.body.description as string) || '', 2000);
    let genres: string[] = [];
    if (req.body.genres) {
      try { const g = typeof req.body.genres === 'string' ? JSON.parse(req.body.genres) : req.body.genres; if (Array.isArray(g)) genres = g.map((x: any) => sanitizeText(String(x), 100)).filter(Boolean); } catch {}
    }
    if (!genres.length && genre) genres = [genre];
    if (!title) { deleteTempFile(musicFile.path); if (coverFile) deleteTempFile(coverFile.path); return res.status(400).json({ error: 'title is required' }); }
    if (!performer) { deleteTempFile(musicFile.path); if (coverFile) deleteTempFile(coverFile.path); return res.status(400).json({ error: 'performer is required' }); }
    if (!license) { deleteTempFile(musicFile.path); if (coverFile) deleteTempFile(coverFile.path); return res.status(400).json({ error: 'license is required' }); }

    const id = uuidv4();
    const ext = path.extname(musicFile.originalname).toLowerCase() || '.mp3';
    const destName = `${id}${ext}`;
    const destPath = path.join(MUSIC_STORAGE_DIR, destName);
    // copy temp -> storage
    await pipeline(fs.createReadStream(musicFile.path), fs.createWriteStream(destPath));
    deleteTempFile(musicFile.path);

    const fileHash = calcFileHash(destPath);
    const stat = await fsPromises.stat(destPath);
    const fileSize = stat.size;

    // hash dedup (global)
    try {
      const dup = await pool.query('SELECT id FROM music_tracks WHERE file_hash=$1 LIMIT 1', [fileHash]);
      if (dup.rows.length) {
        await fsPromises.unlink(destPath).catch(() => {});
        deleteTempFile(musicFile.path); if (coverFile) deleteTempFile(coverFile.path);
        return res.status(409).json({ error: 'Duplicate file (already uploaded)' });
      }
    } catch (e) { console.warn('[music] dup check failed', e); }

    let coverUrl: string | null = null;
    if (coverFile) {
      try {
        coverUrl = await uploadImage(coverFile.path);
      } catch (e) { console.warn('[music] cover upload failed', e); }
      deleteTempFile(coverFile.path);
    }

    const fileUrl = getPublicMusicUrl(id);
    const now = new Date();
    const inserted = await pool.query(
      `INSERT INTO music_tracks (id, title, performer, description, genre, genres, file_url, cover_url, license, file_hash, file_size_bytes, status, author_id, created_at, updated_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,'in_review',$12,$13,$13) RETURNING *`,
      [id, title, performer, description || null, genre || (genres[0] || null), genres, fileUrl, coverUrl, license, fileHash, fileSize, userId, now]
    );
    const row = inserted.rows[0];
    // join author name
    const authorRes = await pool.query(`SELECT full_name, is_verified, cosmetics->>'name_style' AS name_style, cosmetics AS cosmetics FROM profiles WHERE id=$1`, [userId]);
    const author = authorRes.rows[0];
    const out = { ...row, author_name: author?.full_name || null, author_is_verified: !!author?.is_verified, author_name_style: author?.name_style || null, author_cosmetics: author?.cosmetics || null, download_url: fileUrl };
    return res.status(201).json(out);
  } catch (e: any) {
    console.error('[music] POST /', e);
    if (musicFile) deleteTempFile(musicFile.path);
    if (coverFile) deleteTempFile(coverFile.path);
    return res.status(500).json({ error: e.message || 'Internal error' });
  }
});

// GET /music - list (only published for public, author sees own? primitive: only published)
router.get('/', optionalAuthMiddleware, async (req, res: Response) => {
  try {
    const search = (req.query.search as string) || '';
    const genre = (req.query.genre as string) || '';
    const limit = Math.min(Math.max(parseInt(req.query.limit as string) || 50, 1), 200);
    const offset = Math.max(parseInt(req.query.offset as string) || 0, 0);

    const where: string[] = [`status='published'`];
    const params: any[] = [];
    let idx = 1;
    if (search) {
      where.push(`(title ILIKE $${idx} OR performer ILIKE $${idx})`);
      params.push(`%${search}%`);
      idx++;
    }
    if (genre) {
      where.push(`(genre = $${idx} OR $${idx} = ANY(genres))`);
      params.push(genre);
      idx++;
    }
    const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';
    const q = `SELECT m.*, p.full_name AS author_name, p.is_verified AS author_is_verified, p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM music_tracks m LEFT JOIN profiles p ON m.author_id=p.id ${whereSql} ORDER BY m.created_at DESC LIMIT $${idx} OFFSET $${idx+1}`;
    params.push(limit, offset);
    const r = await pool.query(q, params);
    const rows = r.rows.map((row: any) => ({ ...row, download_url: getPublicMusicUrl(row.id), file_url: getPublicMusicUrl(row.id) }));
    return res.json(rows);
  } catch (e: any) {
    console.error('[music] GET /', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

// GET /music/:id - details
router.get('/:id', optionalAuthMiddleware, async (req, res: Response) => {
  try {
    const id = req.params.id;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid id' });
    const r = await pool.query(`SELECT m.*, p.full_name AS author_name, p.is_verified AS author_is_verified, p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM music_tracks m LEFT JOIN profiles p ON m.author_id=p.id WHERE m.id=$1`, [id]);
    if (!r.rows.length) return res.status(404).json({ error: 'Not found' });
    const row = r.rows[0];
    const userId = (req as any).user?.id;
    // only published visible to others
    if (row.status !== 'published' && row.author_id !== userId) {
      // check admin
      if (userId) {
        const pr = await pool.query(`SELECT role FROM profiles WHERE id=$1`, [userId]);
        if (pr.rows[0]?.role !== 'admin') return res.status(403).json({ error: 'Not published' });
      } else {
        return res.status(403).json({ error: 'Not published' });
      }
    }
    const out = { ...row, download_url: getPublicMusicUrl(row.id), file_url: getPublicMusicUrl(row.id) };
    return res.json(out);
  } catch (e: any) {
    console.error('[music] GET /:id', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

// GET /music/:id/file - stream file
router.get('/:id/file', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
  try {
    const id = req.params.id;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid id' });
    // Раньше файл отдавался по id без проверки статуса: трек, снятый с
    // публикации, оставался скачиваемым по прямой ссылке.
    const r = await pool.query(`SELECT status, author_id FROM music_tracks WHERE id=$1`, [id]);
    if (!r.rows.length) return res.status(404).json({ error: 'Not found' });
    if (r.rows[0].status !== 'published' && !(await canSeeUnpublished(req, r.rows[0].author_id))) {
      return res.status(403).json({ error: 'Not published' });
    }
    // find file on disk: music_files/<id>.*
    const files = await fsPromises.readdir(MUSIC_STORAGE_DIR).catch(() => [] as string[]);
    const match = files.find(f => f.startsWith(id + '.'));
    if (!match) return res.status(404).json({ error: 'File not found on storage' });
    const full = path.join(MUSIC_STORAGE_DIR, match);
    const contentTypes: Record<string, string> = {
      '.mp3': 'audio/mpeg',
      '.wav': 'audio/wav',
      '.ogg': 'audio/ogg',
      '.m4a': 'audio/mp4',
      '.flac': 'audio/flac',
      '.aac': 'audio/aac',
    };
    const ext = path.extname(match).toLowerCase();
    const contentType = contentTypes[ext] || 'application/octet-stream';
    res.setHeader('Content-Type', contentType);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    // SEC-18: аудио играем инлайн, неизвестное — только вложением.
    res.setHeader('Content-Disposition', `${contentType.startsWith('audio/') ? 'inline' : 'attachment'}; filename="${match}"`);
    return res.sendFile(full);
  } catch (e: any) {
    console.error('[music] GET /:id/file', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

// DELETE /music/:id
router.delete('/:id', authMiddleware, async (req: AuthRequest, res: Response) => {
  try {
    const id = req.params.id;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid id' });
    const userId = (req as any).user?.id;
    const r = await pool.query(`SELECT author_id FROM music_tracks WHERE id=$1`, [id]);
    if (!r.rows.length) return res.status(404).json({ error: 'Not found' });
    const authorId = r.rows[0].author_id;
    const pr = await pool.query(`SELECT role FROM profiles WHERE id=$1`, [userId]);
    const isAdmin = pr.rows[0]?.role === 'admin';
    if (authorId !== userId && !isAdmin) return res.status(403).json({ error: 'Forbidden' });
    await pool.query(`DELETE FROM music_tracks WHERE id=$1`, [id]);
    // delete file
    const files = await fsPromises.readdir(MUSIC_STORAGE_DIR).catch(() => [] as string[]);
    const match = files.find(f => f.startsWith(id + '.'));
    if (match) await fsPromises.unlink(path.join(MUSIC_STORAGE_DIR, match)).catch(() => {});
    return res.json({ ok: true });
  } catch (e: any) {
    console.error('[music] DELETE', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

// POST /music/:id/admin/action - moderation (admin only)
router.post('/:id/admin/action', authMiddleware, async (req: AuthRequest, res: Response) => {
  try {
    const id = req.params.id;
    if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid id' });
    const userId = (req as any).user?.id;
    const pr = await pool.query(`SELECT role FROM profiles WHERE id=$1`, [userId]);
    if (pr.rows[0]?.role !== 'admin') return res.status(403).json({ error: 'Admin only' });
    const { action, value } = req.body;
    if (action === 'set_status') {
      const allowed = ['published', 'in_review', 'rejected'];
      if (!allowed.includes(value)) return res.status(400).json({ error: 'Invalid status' });
      await pool.query(`UPDATE music_tracks SET status=$1, updated_at=NOW() WHERE id=$2`, [value, id]);
      const r = await pool.query(`SELECT m.*, p.full_name AS author_name, p.is_verified AS author_is_verified, p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM music_tracks m LEFT JOIN profiles p ON m.author_id=p.id WHERE m.id=$1`, [id]);
      return res.json(r.rows[0]);
    }
    return res.status(400).json({ error: 'Unknown action' });
  } catch (e: any) {
    console.error('[music] admin/action', e);
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
    const existing = await pool.query('SELECT is_like FROM music_votes WHERE music_id=$1 AND user_id=$2', [id, userId]);
    const prev = existing.rows[0]?.is_like;
    if (action === 'remove') {
      await pool.query('DELETE FROM music_votes WHERE music_id=$1 AND user_id=$2', [id, userId]);
    } else {
      await pool.query(`INSERT INTO music_votes (music_id, user_id, is_like) VALUES ($1,$2,$3) ON CONFLICT (music_id, user_id) DO UPDATE SET is_like=$3, created_at=NOW()`, [id, userId, !!is_like]);
      if (is_like && !prev) { try { const c = await pool.query('SELECT COUNT(*) FROM music_votes WHERE user_id=$1 AND is_like=TRUE', [userId]); if (parseInt(c.rows[0].count) >= 20) await awardAchievement(userId, 'generous'); } catch {} }
    }
    const likes = await pool.query('SELECT COUNT(*) FROM music_votes WHERE music_id=$1 AND is_like=TRUE', [id]);
    const dislikes = await pool.query('SELECT COUNT(*) FROM music_votes WHERE music_id=$1 AND is_like=FALSE', [id]);
    try { await pool.query('UPDATE music_tracks SET like_count=$1, dislike_count=$2 WHERE id=$3', [likes.rows[0].count, dislikes.rows[0].count, id]); } catch {}
    res.json({ success: true, likes: parseInt(likes.rows[0].count), dislikes: parseInt(dislikes.rows[0].count) });
  } catch (e: any) { console.error('[music] vote', e); res.status(500).json({ error: 'Vote error' }); }
});

router.get('/:id/my-vote', authMiddleware, async (req: AuthRequest, res: Response) => {
  if (!uuidValidate(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  try { const r = await pool.query('SELECT is_like FROM music_votes WHERE music_id=$1 AND user_id=$2', [req.params.id, req.user?.id]); if (!r.rows.length) return res.json({}); res.json(r.rows[0]); } catch (e) { res.status(500).json({ error: 'Failed' }); }
});

router.get('/:id/reviews', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
  if (!uuidValidate(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  try { const r = await pool.query(`SELECT r.*, p.full_name AS author_name, p.avatar_url AS author_avatar_url, p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM music_reviews r JOIN profiles p ON r.author_id=p.id WHERE r.music_id=$1 AND r.status='approved' ORDER BY r.created_at DESC`, [req.params.id]); res.json(r.rows); } catch (e) { res.status(500).json({ error: 'Failed to load reviews' }); }
});

router.get('/:id/my-review', authMiddleware, async (req: AuthRequest, res: Response) => {
  if (!uuidValidate(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  try { const r = await pool.query(`SELECT r.text_content AS text_content, r.status FROM music_reviews r WHERE r.music_id=$1 AND r.author_id=$2`, [req.params.id, req.user?.id]); if (!r.rows.length) return res.json({}); const row = r.rows[0]; res.json({ rating: 0, text: row.text_content, text_content: row.text_content, status: row.status }); } catch (e) { res.status(500).json({ error: 'Failed' }); }
});

router.post('/:id/review', authMiddleware, async (req: AuthRequest, res: Response) => {
  const { id } = req.params; const { text_content } = req.body;
  if (!uuidValidate(id)) return res.status(400).json({ error: 'Invalid ID format' });
  try {
    const blk = await pool.query('SELECT is_blocked FROM profiles WHERE id=$1', [req.user?.id]);
    if (blk.rows[0]?.is_blocked) return res.status(403).json({ error: 'Blocked' });
    if (text_content && text_content.trim().length > 2) {
      try {
        const check = await pool.query('SELECT author_id FROM music_tracks WHERE id=$1', [id]);
        const allowAds = req.user?.id === check.rows[0]?.author_id || await isStaff(req);
        const mod = await moderateReview(text_content, allowAds);
        if (!mod.approved) return res.status(400).json({ error: `Review not allowed: ${mod.reason}` });
      } catch (e) { console.error('Review moderation failed', e); }
    }
    const ex = await pool.query('SELECT id FROM music_reviews WHERE music_id=$1 AND author_id=$2', [id, req.user?.id]);
    let reviewId: string | null = null;
    if (ex.rows.length) {
      const upd = await pool.query(`UPDATE music_reviews SET text_content=$1, status='approved', created_at=NOW() WHERE id=$2 RETURNING id`, [text_content, ex.rows[0].id]);
      reviewId = upd.rows[0]?.id ?? ex.rows[0].id;
    } else {
      const ins = await pool.query(`INSERT INTO music_reviews (id, music_id, author_id, text_content, status) VALUES (gen_random_uuid(), $1,$2,$3,'approved') RETURNING id`, [id, req.user?.id, text_content]);
      reviewId = ins.rows[0]?.id; await awardAchievement(req.user?.id, 'critic_bronze');
    }
    res.json({ success: true, status: 'approved', id: reviewId });
  } catch (e: any) { console.error('[music] review', e); res.status(500).json({ error: 'Server error' }); }
});

export default router;
