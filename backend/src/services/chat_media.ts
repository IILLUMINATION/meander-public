import fs from 'fs';
import path from 'path';
import sharp from 'sharp';
import { v4 as uuidv4 } from 'uuid';

import { publicUrl } from '../config/public_host';
import { UnsupportedImageError, uploadImage } from './image_host';

/**
 * Фото в чатах и каналах.
 *
 * Сжатие — на сервере, а не на клиенте: клиент может прислать что угодно
 * (12 Мп с телефона — это ~48 МБ в памяти и секунды декода на слабом
 * устройстве), и доверять ему в вопросе «я уже ужал» нельзя. Здесь же
 * снимаются метаданные (EXIF с геолокацией), переворачивается кадр по
 * ориентации и отбрасывается всё, что не нужно ленте.
 *
 * Выход: JPEG (или WebP, если у картинки есть прозрачность), не больше
 * 1600 px по длинной стороне — этого хватает на 2× экран телефона.
 */

export const CHAT_IMAGE_MAX_BYTES = 5 * 1024 * 1024;
export const CHAT_ALBUM_MAX = 5;
export const CHAT_IMAGE_MAX_SIDE = 1600;
export const CHAT_IMAGE_QUALITY = 82;

export interface ChatAttachment {
  url: string;
  width: number;
  height: number;
  size: number;
  mime: string;
}

/** Разрешённые форматы: всё, что декодирует sharp, но SVG/PDF не пускаем. */
export const CHAT_IMAGE_EXTENSIONS: Record<string, true> = {
  '.jpg': true,
  '.jpeg': true,
  '.png': true,
  '.webp': true,
  '.gif': true,
  '.heic': true,
  '.heif': true,
};

export const isChatImageName = (originalName: string): boolean =>
  CHAT_IMAGE_EXTENSIONS[path.extname(originalName || '').toLowerCase()] === true;

/**
 * Пересжать принятый файл и положить его в публичный каталог.
 * Возвращает готовые метаданные; временный файл удаляет вызывающий.
 */
export async function compressChatImage(
  tempPath: string,
): Promise<ChatAttachment> {
  // `rotate()` без аргумента применяет EXIF-ориентацию и выкидывает метку:
  // иначе вертикальное фото с телефона приезжает боком.
  const pipeline = sharp(tempPath, { failOn: 'error' }).rotate();
  const meta = await pipeline.metadata();
  if (!meta.format || !['jpeg', 'png', 'webp', 'gif', 'heif', 'avif'].includes(meta.format)) {
    throw new UnsupportedImageError(`Unsupported image format: ${meta.format}`);
  }

  const hasAlpha = Boolean(meta.hasAlpha);
  const resized = pipeline.resize({
    width: CHAT_IMAGE_MAX_SIDE,
    height: CHAT_IMAGE_MAX_SIDE,
    fit: 'inside',
    withoutEnlargement: true,
  });

  const encoded = hasAlpha
    ? await resized.webp({ quality: CHAT_IMAGE_QUALITY }).toBuffer({ resolveWithObject: true })
    : await resized.jpeg({ quality: CHAT_IMAGE_QUALITY, mozjpeg: true }).toBuffer({ resolveWithObject: true });

  const ext = hasAlpha ? '.webp' : '.jpg';
  const fileName = `${uuidv4()}${ext}`;
  const targetDir = path.join(process.cwd(), 'public/uploads');
  fs.mkdirSync(targetDir, { recursive: true });
  const targetPath = path.join(targetDir, fileName);
  fs.writeFileSync(targetPath, encoded.data);

  return {
    url: publicUrl(`/uploads/${fileName}`),
    width: encoded.info.width,
    height: encoded.info.height,
    size: encoded.data.length,
    mime: hasAlpha ? 'image/webp' : 'image/jpeg',
  };
}

/**
 * Фолбэк без sharp: только настоящие картинки и только уже маленькие.
 * Нужен, если нативный бинарник в образе отсутствует — чат должен работать,
 * пусть и без пересжатия, а не отвечать 500 на любое фото.
 */
export async function storeChatImageAsIs(
  tempPath: string,
): Promise<ChatAttachment> {
  const size = fs.statSync(tempPath).size;
  if (size > CHAT_IMAGE_MAX_BYTES) {
    throw new UnsupportedImageError('Фото больше 5 МБ, а сжать его не удалось');
  }
  const url = await uploadImage(tempPath);
  return { url, width: 0, height: 0, size, mime: 'image/*' };
}

/** Имя файла нашего загрузчика: `<uuid>.jpg|webp`. */
const UPLOAD_FILE_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp|gif)$/i;

/**
 * Проверка ссылки из тела сообщения: принимаем только наши файлы.
 * Иначе в ленту можно вставить `javascript:` или чужой трекер, и он
 * откроется у собеседника.
 */
export const isOurUploadUrl = (value: string): boolean => {
  const prefix = publicUrl('/uploads/');
  if (!value.startsWith(prefix)) return false;
  const rest = value.slice(prefix.length);
  if (rest.includes('/') || rest.includes('?') || rest.includes('#')) {
    return false;
  }
  return UPLOAD_FILE_RE.test(rest);
};

/**
 * Приводит присланный клиентом список вложений к безопасному виду:
 * только наши ссылки, максимум 5 штук, целые числа в размерах.
 */
export function normalizeAttachments(raw: unknown): ChatAttachment[] {
  if (!Array.isArray(raw)) return [];
  const result: ChatAttachment[] = [];
  for (const item of raw.slice(0, CHAT_ALBUM_MAX)) {
    if (!item || typeof item !== 'object' || !('url' in item)) continue;
    const url = typeof item.url === 'string' ? item.url.trim() : '';
    if (!isOurUploadUrl(url)) continue;
    const number = (key: 'width' | 'height' | 'size'): number => {
      if (!(key in item)) return 0;
      const value = Number(item[key]);
      return Number.isFinite(value) && value > 0 ? Math.round(value) : 0;
    };
    const mime = 'mime' in item && typeof item.mime === 'string' ? item.mime.slice(0, 32) : '';
    result.push({
      url,
      width: number('width'),
      height: number('height'),
      size: number('size'),
      mime,
    });
  }
  return result;
}