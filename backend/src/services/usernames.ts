import pool from '../config/database';

/**
 * Юзернейм — короткий адрес `@name` для профиля и канала.
 *
 * Одно пространство имён на оба вида: `@meander` — либо человек, либо канал,
 * но не оба сразу. Иначе `@name` в тексте некуда однозначно развернуть.
 */

export const USERNAME_MIN = 3;
export const USERNAME_MAX = 32;

const USERNAME_RE = /^[a-z][a-z0-9_]{2,31}$/;

/**
 * Служебные адреса: заняты маршрутами приложения, ссылками и командами,
 * которые нельзя отдавать человеку.
 */
const RESERVED = new Set([
    'admin', 'api', 'app', 'assets', 'auth', 'bot', 'c', 'channel', 'channels',
    'cloud', 'community', 'help', 'login', 'market', 'me', 'meander', 'moderator',
    'music', 'news', 'profile', 'profiles', 'quest', 'quests', 'root', 'settings',
    'share', 'support', 'system', 'team', 'u', 'user', 'users', 'www',
]);

export interface UsernameCheck {
    username?: string;
    error?: string;
}

/**
 * Приводит ввод к каноническому виду: срезает `@`, пробелы и регистр.
 * `null` — пустая строка, то есть «убрать адрес».
 */
export function normalizeUsername(raw: unknown): string | null {
    if (raw === null || raw === undefined) return null;
    const value = String(raw).trim().replace(/^@+/, '').toLowerCase();
    return value.length === 0 ? null : value;
}

/** Проверка формата; `null` — адрес корректен. */
export function usernameFormatError(username: string): string | null {
    if (username.length < USERNAME_MIN || username.length > USERNAME_MAX) {
        return `Юзернейм от ${USERNAME_MIN} до ${USERNAME_MAX} символов`;
    }
    if (!USERNAME_RE.test(username)) {
        return 'Юзернейм: латинские буквы, цифры и _, начинается с буквы';
    }
    if (RESERVED.has(username)) return 'Этот юзернейм зарезервирован';
    return null;
}

/** Разбор присланного значения: `{username}` или `{error}`. */
export function parseUsername(raw: unknown): UsernameCheck {
    const username = normalizeUsername(raw);
    if (username === null) return { username: undefined };
    const error = usernameFormatError(username);
    return error ? { error } : { username };
}

/**
 * Занят ли адрес другим профилем или каналом. `ignoreProfileId` — чтобы
 * человек мог сохранить свой же адрес без изменения.
 */
export async function usernameTaken(
    username: string,
    ignoreProfileId?: string,
): Promise<boolean> {
    const result = await pool.query(
        `SELECT
            EXISTS (SELECT 1 FROM profiles
                     WHERE lower(username) = $1
                       AND ($2::uuid IS NULL OR id <> $2::uuid)) AS profile,
            EXISTS (SELECT 1 FROM channels WHERE lower(slug) = $1) AS channel`,
        [username, ignoreProfileId ?? null],
    );
    const row = result.rows[0];
    return Boolean(row?.profile || row?.channel);
}
