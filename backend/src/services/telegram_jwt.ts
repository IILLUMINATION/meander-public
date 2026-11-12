import crypto from 'crypto';

/**
 * Проверка id_token от Telegram Login Widget.
 *
 * Исторически несовпадение подписи только логировалось, и сервер принимал любой
 * JWT, у которого не истёк exp: подписав свой токен с чужим telegram_id, можно
 * было войти под любым аккаунтом или создать новый. Ключ подписи известен только
 * владельцу бота, поэтому проверка обязательна.
 */
export class TelegramTokenError extends Error {
    status = 401;
    constructor(message: string) {
        super(message);
        this.name = 'TelegramTokenError';
    }
}

/** Поля, которые реально читает вход через Telegram. */
export interface TelegramIdTokenPayload {
    sub?: string;
    id?: string;
    user_id?: string;
    telegram_id?: string;
    preferred_username?: string;
    username?: string;
    login?: string;
    name?: string;
    given_name?: string;
    family_name?: string;
    picture?: string;
    photo_url?: string;
    exp: number;
    iat?: number;
    auth_date?: number;
    [key: string]: unknown;
}

/**
 * Telegram выдаёт id_token с TTL около часа. Всё, что «живёт» заметно дольше
 * суток, — подделка или подписанный не тем ключом токен; сутки оставляем как
 * запас на часы и на кэш клиента.
 */
const MAX_TOKEN_TTL_SECONDS = 24 * 60 * 60;

function asObject(value: unknown): Record<string, unknown> | null {
    return value !== null && typeof value === 'object' && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : null;
}

function base64UrlDecode(str: string): string {
    let s = str.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    return Buffer.from(s, 'base64').toString('utf-8');
}

const signaturesMatch = (expected: string, actual: string): boolean => {
    const a = Buffer.from(expected);
    const b = Buffer.from(actual);
    // Разная длина — сразу мимо: timingSafeEqual на неровных буферах кидает.
    return a.length === b.length && crypto.timingSafeEqual(a, b);
};

export function verifyTelegramIdToken(
    idToken: string,
    botToken: string,
): TelegramIdTokenPayload {
    if (!botToken) throw new TelegramTokenError('Telegram sign-in is not configured');

    const parts = String(idToken || '').split('.');
    if (parts.length !== 3) throw new TelegramTokenError('Invalid JWT format');

    let header: Record<string, unknown> | null;
    let payload: Record<string, unknown> | null;
    try {
        header = asObject(JSON.parse(base64UrlDecode(parts[0])));
        payload = asObject(JSON.parse(base64UrlDecode(parts[1])));
    } catch {
        throw new TelegramTokenError('Invalid JWT encoding');
    }
    if (!header || !payload) throw new TelegramTokenError('Invalid JWT payload');

    // Только HS256: alg=none и RS256 проверить нечем, а принять их — значит
    // вернуть ту же дыру.
    if (header?.alg !== 'HS256') throw new TelegramTokenError('Unsupported Telegram token algorithm');

    const data = `${parts[0]}.${parts[1]}`;
    // Telegram подписывает id_token ключом SHA256(bot_token); сырой токен
    // оставляем вторым кандидатом — так проверяли старые сборки.
    const derived = crypto.createHash('sha256').update(botToken).digest();
    const expected = crypto.createHmac('sha256', derived).update(data).digest('base64url');
    const expectedRaw = crypto.createHmac('sha256', botToken).update(data).digest('base64url');
    if (!signaturesMatch(expected, parts[2]) && !signaturesMatch(expectedRaw, parts[2])) {
        throw new TelegramTokenError('Invalid Telegram token signature');
    }

    // Раньше проверка была `if (payload.exp && …)`: подписанный токен без exp
    // (или с exp строкой/нечислом) считался вечным. Теперь exp обязателен,
    // числовой и в разумном коридоре — по нему же ограничивается «вечность»
    // украденного токена.
    const exp = payload.exp;
    if (typeof exp !== 'number' || !Number.isFinite(exp)) {
        throw new TelegramTokenError('Telegram token has no valid exp');
    }
    const nowSeconds = Date.now() / 1000;
    if (nowSeconds > exp) {
        throw new TelegramTokenError('Telegram token expired');
    }
    if (exp > nowSeconds + MAX_TOKEN_TTL_SECONDS) {
        throw new TelegramTokenError('Telegram token exp is in the future');
    }
    return payload as TelegramIdTokenPayload;
}

/** Подпись виджета (`telegramData` + `hash`) — тот же ключ, схема другая. */
export function verifyTelegramWidgetHash(data: Record<string, any>, botToken: string): boolean {
    const checkString = Object.keys(data)
        .filter((k) => k !== 'hash')
        .sort()
        .map((k) => `${k}=${data[k]}`)
        .join('\n');
    const secret = crypto.createHash('sha256').update(botToken).digest();
    const expected = crypto.createHmac('sha256', secret).update(checkString).digest('hex');
    return signaturesMatch(expected, String(data.hash));
}
