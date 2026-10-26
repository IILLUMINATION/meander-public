// Обмен authorization code → id_token для desktop-входа.
//
// Секрет desktop-клиента — единственное, что раньше требовалось от сборки
// (--dart-define). Теперь он живёт только на сервере: приложение присылает код
// и PKCE-verifier, сервер добавляет секрет и получает id_token. Клиентский
// бинарник остаётся без секретов.
//
// Redirect обязан быть loopback: desktop-вход поднимает локальный HTTP-сервер
// на 127.0.0.1. Если пускать произвольный redirect_uri, эндпоинт стал бы
// открытым обменником кодов для чужих приложений.

const GOOGLE_TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token';
const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

export interface GoogleExchangeInput {
    code: string;
    codeVerifier: string;
    redirectUri: string;
}

export interface GoogleExchangeConfig {
    clientId: string;
    clientSecret: string;
}

export class GoogleExchangeError extends Error {}

/** Только http(s) на loopback: auth-сервер приложения слушает 127.0.0.1. */
export function isLoopbackRedirect(raw: unknown): boolean {
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > 2048) {
        return false;
    }
    let url: URL;
    try {
        url = new URL(raw);
    } catch {
        return false;
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
    if (url.username || url.password) return false;
    return LOOPBACK_HOSTS.has(url.hostname);
}

/** PKCE: 43–128 символов из unreserved-набора (RFC 7636). */
export function isPkceVerifier(raw: unknown): raw is string {
    return (
        typeof raw === 'string' &&
        /^[A-Za-z0-9._~-]{43,128}$/.test(raw)
    );
}

export async function exchangeGoogleCode(
    input: GoogleExchangeInput,
    config: GoogleExchangeConfig,
    fetchImpl: typeof globalThis.fetch = globalThis.fetch,
): Promise<string> {
    const body = new URLSearchParams({
        grant_type: 'authorization_code',
        code: input.code,
        client_id: config.clientId,
        client_secret: config.clientSecret,
        code_verifier: input.codeVerifier,
        redirect_uri: input.redirectUri,
    });

    const response = await fetchImpl(GOOGLE_TOKEN_ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body.toString(),
    });

    const text = await response.text();
    if (!response.ok) {
        throw new GoogleExchangeError(
            `Google token endpoint answered ${response.status}: ${text.slice(0, 500)}`,
        );
    }

    let data: unknown;
    try {
        data = JSON.parse(text);
    } catch {
        throw new GoogleExchangeError('Google token endpoint returned invalid JSON');
    }

    const idToken = (data as { id_token?: unknown })?.id_token;
    if (typeof idToken !== 'string' || idToken.length === 0) {
        throw new GoogleExchangeError('Google token endpoint returned no id_token');
    }
    return idToken;
}
