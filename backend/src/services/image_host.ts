import fs from 'fs';
import path from 'path';
import { v4 as uuidv4 } from 'uuid';
import dotenv from 'dotenv';

dotenv.config();

// Папка для картинок
const UPLOADS_DIR = path.join(process.cwd(), 'public/uploads');
if (!fs.existsSync(UPLOADS_DIR)) {
    fs.mkdirSync(UPLOADS_DIR, { recursive: true });
}

/**
 * Файл отклонён по содержимому: не картинка либо формат не поддерживается.
 * Отличается от сбоя диска тем, что повторять попытку бесполезно — клиент
 * должен показать человеку причину, а не «не удалось загрузить».
 */
export class UnsupportedImageError extends Error {
    constructor(message: string) {
        super(message);
        this.name = 'UnsupportedImageError';
    }
}

/**
 * Заявленный клиентом Content-Type части multipart — самодекларация, а не
 * проверка. Клиент Meander (`package:http`) ставит `application/octet-stream`
 * для файлов, выбранных в галерее, если тип не заполнить вручную, и требование
 * `image/*` отрезало настоящие фото. Здесь пропускаем картинку и «не знаю, что
 * это»; заведомо чужое (application/pdf, text/html) отсекаем, а настоящее
 * решение принимает checkMagicBytes по сигнатуре файла.
 */
const GENERIC_PART_MIME_TYPES = new Set(['', 'application/octet-stream', 'binary/octet-stream']);

export const acceptsImagePartMime = (mimetype: string | undefined): boolean => {
    const mime = (mimetype || '').toLowerCase();
    return mime.startsWith('image/') || GENERIC_PART_MIME_TYPES.has(mime);
};

/**
 * Проверяет магические байты файла (первые байты) на соответствие
 * заявленному расширению. Защита от подмены типа файла.
 * Также блокирует SVG и другие XML-based форматы как изображения.
 */
const MAGIC_BYTES: Record<string, number[]> = {
    '.jpg':  [0xff, 0xd8, 0xff],
    '.jpeg': [0xff, 0xd8, 0xff],
    '.png':  [0x89, 0x50, 0x4e, 0x47],
    '.gif':  [0x47, 0x49, 0x46],
    '.webp': [0x52, 0x49, 0x46, 0x46],
};

/** XML/SVG сигнатуры, которые блокируются как изображения */
const BLOCKED_SIGNATURES: { name: string; bytes: number[] }[] = [
    { name: 'SVG/XML', bytes: [0x3c, 0x73, 0x76, 0x67] },      // "<svg"
    { name: 'XML declaration', bytes: [0x3c, 0x3f, 0x78, 0x6d] }, // "<?xml"
    { name: 'HTML', bytes: [0x3c, 0x21, 0x44, 0x4f] },           // "<!DO"
    { name: 'HTML tag', bytes: [0x3c, 0x68, 0x74, 0x6d] },       // "<html"
];

const checkMagicBytes = (filePath: string, ext: string): void => {
    // Если расширение неизвестно — пропускаем проверку (наверху будет отвергнуто)
    const expected = MAGIC_BYTES[ext.toLowerCase()];
    if (!expected) {
        throw new UnsupportedImageError(`Unsupported image extension: ${ext}`);
    }

    const fd = fs.openSync(filePath, 'r');
    try {
        const header = Buffer.alloc(Math.max(16, ...expected.map(() => 0)));
        const bytesRead = fs.readSync(fd, header, 0, header.length, 0);

        // Проверяем на запрещённые сигнатуры (SVG, HTML, XML) в первую очередь
        for (const sig of BLOCKED_SIGNATURES) {
            if (bytesRead >= sig.bytes.length) {
                let match = true;
                for (let i = 0; i < sig.bytes.length; i++) {
                    if (header[i] !== sig.bytes[i]) { match = false; break; }
                }
                if (match) {
                    throw new UnsupportedImageError(`File appears to be ${sig.name}, not a valid image`);
                }
            }
        }

        // Проверяем соответствие магических байт расширению
        let magicMatch = true;
        for (let i = 0; i < expected.length; i++) {
            if (header[i] !== expected[i]) { magicMatch = false; break; }
        }
        if (!magicMatch) {
            throw new UnsupportedImageError(`Magic bytes do not match extension ${ext}. Header: ${header.subarray(0, 8).toString('hex')}`);
        }
    } finally {
        fs.closeSync(fd);
    }
};

export const uploadImage = async (filePath: string): Promise<string> => {
    try {
        // 1. Генерируем уникальное имя
        const ext = path.extname(filePath) || '.jpg'; // Фоллбэк расширение
        const newFileName = `${uuidv4()}${ext}`;
        const targetPath = path.join(UPLOADS_DIR, newFileName);

        // 2. ПРОВЕРКА МАГИЧЕСКИХ БАЙТОВ (защита от подмены типа файла + SVG/HTML)
        checkMagicBytes(filePath, ext);

        // 3. Перемещаем файл из временной папки в uploads
        // Используем copyFileSync, чтобы не было конфликтов с удалением временных файлов в контроллере
        fs.copyFileSync(filePath, targetPath);
        
        // 4. Формируем ссылку
        // БАЗОВЫЙ URL ДОЛЖЕН БЫТЬ В .env БЕЗ СЛЕША В КОНЦЕ (например: https://meander.illuminat.dev)
        const baseUrl = process.env.BASE_URL || 'http://localhost:3000';
        
        // Возвращаем прямую ссылку на твой сервер
        return `${baseUrl}/uploads/${newFileName}`;

    } catch (error: any) {
        console.error("Local Upload Error:", error.message);
        // Отказ по содержимому — не поломка диска: вызывающий роут обязан
        // ответить 415 с причиной, а не обещать «не удалось сохранить».
        if (error instanceof UnsupportedImageError) throw error;
        throw new Error("Failed to save image locally");
    }
};
