/**
 * Единственное место, где решается, какой публичный адрес сервер вписывает
 * в ссылки (картинки, файлы квестов, музыка, share-страницы).
 *
 * Раньше каждый роут сам склеивал `${process.env.BASE_URL || 'http://localhost:3000'}`
 * с путём. Дважды это уже стоило поломки: при смене домена часть ссылок
 * осталась на мёртвом `backend.meander.sbs` и картинки в сообществе просто
 * не грузились, а слэш в конце `BASE_URL` давал `//uploads/...`.
 *
 * Правила:
 *  - хвостовые слэши срезаются, чтобы не рождались двойные слэши;
 *  - снятые домены не валят сервер (он продолжает обслуживать запросы), но
 *    кричат в лог: с такими ссылками половина функций выглядит «сломанной»,
 *    а причина — одна строка в `.env`.
 */

/** Домены, которые больше не обслуживают этот бэкенд. */
export const RETIRED_PUBLIC_HOSTS = [
    'meander.sbs',
    'backend.meander.sbs',
    'meander.elitrycraft.workers.dev',
];

const DEFAULT_BASE_URL = 'http://localhost:3000';

/** Публичный базовый адрес без хвостового слэша. */
export const publicBaseUrl = (env: NodeJS.ProcessEnv = process.env): string => {
    const raw = (env.BASE_URL || '').trim();
    if (!raw) return DEFAULT_BASE_URL;
    const withoutSlash = raw.replace(/\/+$/, '');
    try {
        const host = new URL(withoutSlash).hostname.toLowerCase();
        if (RETIRED_PUBLIC_HOSTS.includes(host)) {
            console.error(
                `[config] BASE_URL указывает на снятый домен ${host}: ` +
                'ссылки на картинки и файлы будут битыми. Обновите .env.'
            );
        }
    } catch {
        // Невалидный URL: не наша задача чинить тут, вернём как есть —
        // маршрут всё равно отдаст клиенту то, что настроено.
    }
    return withoutSlash;
};

/** Абсолютная ссылка на публичный файл: `publicUrl('/uploads/x.jpg')`. */
export const publicUrl = (path: string, env?: NodeJS.ProcessEnv): string => {
    const suffix = path.startsWith('/') ? path : `/${path}`;
    return `${publicBaseUrl(env)}${suffix}`;
};