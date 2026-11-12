import fsPromises from 'fs/promises';
import path from 'path';
import yauzl from 'yauzl';
import { v4 as uuidv4 } from 'uuid';

/**
 * Разбор и модерационное решение по файлу квеста.
 *
 * Отдельно от маршрута публикации: здесь перечислимо-проверяемые правила
 * (что считать прочитанным текстом, чем заканчивается проверка), и их нужно
 * видеть и тестировать без базы, multer и всего HTTP-стека.
 */

const streamToBuffer = (stream: any, sizeLimit: number): Promise<Buffer> => {
    return new Promise((resolve, reject) => {
        const chunks: Buffer[] = [];
        let totalLen = 0;
        stream.on('data', (chunk: Buffer) => {
            totalLen += chunk.length;
            if (totalLen > sizeLimit) {
                stream.destroy();
                reject(new Error('File inside zip is too large (Zip Bomb protection)'));
                return;
            }
            chunks.push(chunk);
        });
        stream.on('end', () => resolve(Buffer.concat(chunks)));
        stream.on('error', (err: any) => reject(err));
    });
};

function calcPlaytime(nodes: any[]): number {
    const WORDS_PER_MINUTE = 250; 
    const SECONDS_PER_IMAGE = 3;
    const SECONDS_DECISION = 2;
    const BRANCHING_FACTOR = 0.15; 

    let totalSecondsAllNodes = 0;
    
    for (const node of nodes) {
        totalSecondsAllNodes += SECONDS_DECISION;
        const items = node.content?.items || [];
        for (const item of items) {
            if (item.type === 'text') {
                const words = (item.text || '').split(/\s+/).length;
                totalSecondsAllNodes += (words / WORDS_PER_MINUTE) * 60;
            } else if (item.type === 'image') {
                totalSecondsAllNodes += SECONDS_PER_IMAGE;
            } else if (item.type === 'timer') {
                totalSecondsAllNodes += parseInt(item.text || '0');
            }
        }
    }
    
    const estimatedMinutes = Math.round((totalSecondsAllNodes * BRANCHING_FACTOR) / 60);
    return Math.max(1, estimatedMinutes);
}

export interface ZipAnalysis {
    fullText: string;
    images: string[];
    nodeCount: number;
    estimatedPlaytime: number;
    /**
     * Текст игры не удалось прочитать (слишком большой, битый JSON, нет nodes
     * или в архиве вообще нет nodes.json). Раньше это молча проходило как
     * «проверено и чисто»: достаточно было nodes.json больше 10 МБ, чтобы весь
     * контент ушёл в магазин без проверки.
     */
    textScanFailed: boolean;
}

// Сколько текста игры успевает собрать сканер. moderation.ts проверяет ровно
// столько же: оставалось бы 20 000 — и всё, что дальше двадцатитысячного
// символа, правила уже не смотрели бы.
const BODY_SCAN_CHAR_BUDGET = 200_000;

// Безопасные лимиты для извлечения файлов из ZIP
const MAX_IMAGE_SIZE = 10 * 1024 * 1024;   // 10 MB на одно изображение
const MAX_TOTAL_EXTRACTED = 100 * 1024 * 1024; // 100 MB общий лимит на всё извлечённое
const MAX_ENTRIES = 20000;                 // макс. количество файлов в ZIP (защита от zip bomb)
// Узлы и элементы контента тоже ограничены: один nodes.json до 10 МБ может
// содержать сотни тысяч узлов, и обход строил строки/массивы пропорционально
// их числу даже при обрезанном тексте. Такой квест помечается как «не
// просканирован», а не проходит молча.
const MAX_SCAN_NODES = 5000;
const MAX_SCAN_ITEMS = 50_000;

/**
 * Проверяет магические байты буфера — является ли он допустимым изображением.
 * Блокирует SVG/HTML/XML.
 */
function isSafeImageBuffer(buf: Buffer, ext: string): boolean {
    // Проверка на SVG/HTML/XML сигнатуры
    const blockedPrefixes: { name: string; bytes: Buffer }[] = [
        { name: 'SVG', bytes: Buffer.from([0x3c, 0x73, 0x76, 0x67]) },
        { name: 'XML', bytes: Buffer.from([0x3c, 0x3f, 0x78, 0x6d]) },
        { name: 'HTML', bytes: Buffer.from([0x3c, 0x21, 0x44, 0x4f]) },
        { name: 'HTML', bytes: Buffer.from([0x3c, 0x68, 0x74, 0x6d]) },
    ];
    for (const sig of blockedPrefixes) {
        if (buf.length >= sig.bytes.length && buf.subarray(0, sig.bytes.length).equals(sig.bytes)) {
            console.warn(`Zip image blocked: appears to be ${sig.name}`);
            return false;
        }
    }

    // Проверка магических байт для заявленного расширения
    const magic: Record<string, Buffer> = {
        '.jpg':  Buffer.from([0xff, 0xd8, 0xff]),
        '.jpeg': Buffer.from([0xff, 0xd8, 0xff]),
        '.png':  Buffer.from([0x89, 0x50, 0x4e, 0x47]),
        '.gif':  Buffer.from([0x47, 0x49, 0x46]),
        '.webp': Buffer.from([0x52, 0x49, 0x46, 0x46]),
    };
    const expected = magic[ext.toLowerCase()];
    if (!expected) return false;
    if (buf.length < expected.length) return false;
    return buf.subarray(0, expected.length).equals(expected);
}

export async function analyzeQuestZip(filePath: string, tempDir: string): Promise<ZipAnalysis> {
    return new Promise((resolve, reject) => {
        const result: ZipAnalysis = {
            fullText: "",
            images: [],
            nodeCount: 0,
            estimatedPlaytime: 5,
            textScanFailed: false
        };

        let totalExtracted = 0;
        let entryCount = 0;
        let streamErrorOccurred = false;
        let sawNodesJson = false;

        yauzl.open(filePath, { lazyEntries: true }, (err, zipfile) => {
            if (err) return reject(err);

            zipfile.on("close", () => {
                // Если была ошибка в стриме — реджектим
                if (streamErrorOccurred) return;
                // Архив без nodes.json — это не «чисто», это «нечего читать»:
                // такой квест выкладывали, чтобы весь его контент прошёл мимо
                // правил. Отсутствующий файл считаем тем же сбоем скана, что и
                // битый.
                if (!sawNodesJson) result.textScanFailed = true;
                resolve(result);
            });
            zipfile.readEntry();

            zipfile.on("entry", (entry) => {
                // Пропускаем директории и служебные файлы macOS —
                // в лимит записей идут только реальные файлы
                if (/\/$/.test(entry.fileName) || entry.fileName.startsWith('__MACOSX')) {
                    zipfile.readEntry();
                    return;
                }

                // Защита от слишком большого количества записей (zip bomb)
                entryCount++;
                if (entryCount > MAX_ENTRIES) {
                    streamErrorOccurred = true;
                    zipfile.close();
                    return reject(new Error(`Zip contains too many entries (>${MAX_ENTRIES})`));
                }

                if (entry.fileName.endsWith('nodes.json')) {
                    sawNodesJson = true;
                    zipfile.openReadStream(entry, async (err, readStream) => {
                        if (err) { streamErrorOccurred = true; return reject(err); }
                        try {
                            const buf = await streamToBuffer(readStream, 10 * 1024 * 1024);
                            const jsonStr = buf.toString('utf8');
                            const data = JSON.parse(jsonStr);

                            if (!Array.isArray(data.nodes)) {
                                // Формальный JSON без nodes — проверять нечего.
                                result.textScanFailed = true;
                            }
                            if (Array.isArray(data.nodes)) {
                                result.nodeCount = data.nodes.length;
                                if (result.nodeCount > MAX_SCAN_NODES) {
                                    result.textScanFailed = true;
                                } else {
                                    result.estimatedPlaytime = calcPlaytime(data.nodes);
                                    let itemsSeen = 0;
                                    for (const node of data.nodes) {
                                        if (itemsSeen > MAX_SCAN_ITEMS) {
                                            result.textScanFailed = true;
                                            break;
                                        }
                                        if (result.fullText.length < BODY_SCAN_CHAR_BUDGET) {
                                            result.fullText += `[${node.title || ''}]\n`;
                                            if (node.content && Array.isArray(node.content.items)) {
                                                itemsSeen += node.content.items.length;
                                                for (const item of node.content.items) {
                                                    if (item.text) result.fullText += item.text + "\n";
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } catch (e) {
                            console.error("Error parsing nodes.json inside zip", e);
                            result.textScanFailed = true;
                        }
                        zipfile.readEntry();
                    });
                } 
                else if (result.images.length < 3 && entry.fileName.match(/\.(jpg|png|jpeg|gif|webp)$/i)) {
                    // Проверяем сжатый размер как эвристику (защита от бомбы: 10MB в сжатом виде → не извлекаем)
                    if (entry.compressedSize > MAX_IMAGE_SIZE) {
                        console.warn(`Skipping oversized zip entry: ${entry.fileName} (compressed: ${entry.compressedSize})`);
                        zipfile.readEntry();
                        return;
                    }

                    zipfile.openReadStream(entry, async (err, readStream) => {
                        if (err) { streamErrorOccurred = true; return reject(err); }
                        try {
                            // Извлекаем с лимитом размера (защита от zip bomb)
                            const buf = await streamToBuffer(readStream, MAX_IMAGE_SIZE);
                            
                            // Проверяем, что лимит превышен не был
                            if (buf.length >= MAX_IMAGE_SIZE) {
                                console.warn(`Image too large in zip: ${entry.fileName}`);
                                zipfile.readEntry();
                                return;
                            }

                            // Проверяем общий лимит извлечённого
                            totalExtracted += buf.length;
                            if (totalExtracted > MAX_TOTAL_EXTRACTED) {
                                console.warn('Total extracted size exceeded, skipping remaining images');
                                zipfile.readEntry();
                                return;
                            }

                            // Определяем расширение для проверки магических байт
                            const extMatch = entry.fileName.match(/\.(jpg|jpeg|png|gif|webp)$/i);
                            const ext = extMatch ? extMatch[0] : '.jpg';

                            // Проверяем магические байты
                            if (!isSafeImageBuffer(buf, ext)) {
                                console.warn(`Rejected unsafe image in zip: ${entry.fileName}`);
                                zipfile.readEntry();
                                return;
                            }

                            const imagePath = path.join(tempDir, `internal_${uuidv4()}${ext}`);
                            await fsPromises.writeFile(imagePath, buf);
                            result.images.push(imagePath);
                        } catch (e) {
                            console.error("Error extracting image", e);
                        }
                        zipfile.readEntry();
                     });
                } 
                else {
                    zipfile.readEntry();
                }
            });

            zipfile.on("end", () => { });
            zipfile.on("error", (err) => { streamErrorOccurred = true; reject(err); });
        });
    });
}

/**
 * Итог moderation-блока публикации.
 *
 * Непрочитанный текст — это не «чисто»: правила не смотрели содержимое
 * (битый, гигантский или отсутствующий nodes.json), и раньше такой квест
 * уходил в магазин с отметкой Auto-approved. Спорное отдаём людям.
 */
export function publishDecision(
    moderation: { approved: boolean; reason: string } | null,
    textScanFailed: boolean
): { status: 'published' | 'in_review'; moderatorComment: string } {
    if (moderation && !moderation.approved) {
        return { status: 'in_review', moderatorComment: `Flag: ${moderation.reason}` };
    }
    if (textScanFailed) {
        return { status: 'in_review', moderatorComment: 'Flag: текст игры не прочитан модерацией' };
    }
    return { status: 'published', moderatorComment: 'Auto-approved' };
}

