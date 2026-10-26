// Серверный обмен кода Google (#368).
//
// Смысл эндпоинта — убрать client_secret из сборки. Значит, тест держит три
// вещи: секрет уходит в Google (а не теряется), redirect пускается только на
// loopback и без id_token ответ не считается успехом.

const assert = require('node:assert/strict');
const { test } = require('node:test');
const {
    exchangeGoogleCode,
    GoogleExchangeError,
    isLoopbackRedirect,
    isPkceVerifier,
} = require('../dist/services/google_exchange');

const verifier = 'a'.repeat(64);

test('loopback-редиректы desktop-входа проходят', () => {
    assert.equal(isLoopbackRedirect('http://localhost:51234'), true);
    assert.equal(isLoopbackRedirect('http://127.0.0.1:51234/'), true);
    assert.equal(isLoopbackRedirect('http://[::1]:51234/callback'), true);
});

test('чужие редиректы не проходят', () => {
    // Негативный контроль: без этой проверки эндпоинт обменивал бы коды для
    // любого приложения, подставившего свой redirect_uri.
    assert.equal(isLoopbackRedirect('https://evil.example/callback'), false);
    assert.equal(isLoopbackRedirect('http://localhost.evil.example:80'), false);
    assert.equal(isLoopbackRedirect('http://user:pass@localhost:80'), false);
    assert.equal(isLoopbackRedirect('file:///etc/passwd'), false);
    assert.equal(isLoopbackRedirect('not a url'), false);
    assert.equal(isLoopbackRedirect(''), false);
    assert.equal(isLoopbackRedirect(null), false);
});

test('PKCE verifier: длина и алфавит по RFC 7636', () => {
    assert.equal(isPkceVerifier('a'.repeat(43)), true);
    assert.equal(isPkceVerifier('a'.repeat(128)), true);
    assert.equal(isPkceVerifier('a'.repeat(42)), false);
    assert.equal(isPkceVerifier('a'.repeat(129)), false);
    assert.equal(isPkceVerifier('a'.repeat(63) + '!'), false);
    assert.equal(isPkceVerifier(undefined), false);
});

test('обмен отправляет секрет и возвращает id_token', async () => {
    let seenUrl;
    let seenBody;
    const fakeFetch = async (url, init) => {
        seenUrl = url;
        seenBody = new URLSearchParams(init.body);
        return new Response(JSON.stringify({ id_token: 'header.payload.signature' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
        });
    };

    const idToken = await exchangeGoogleCode(
        {
            code: 'the-code',
            codeVerifier: verifier,
            redirectUri: 'http://localhost:51234',
        },
        { clientId: 'desktop-client', clientSecret: 'server-only-secret' },
        fakeFetch,
    );

    assert.equal(idToken, 'header.payload.signature');
    assert.equal(seenUrl, 'https://oauth2.googleapis.com/token');
    assert.equal(seenBody.get('grant_type'), 'authorization_code');
    assert.equal(seenBody.get('code'), 'the-code');
    assert.equal(seenBody.get('client_id'), 'desktop-client');
    // Ради этого поля эндпоинт и существует: оно не должно попасть в клиент,
    // но обязано уйти в Google.
    assert.equal(seenBody.get('client_secret'), 'server-only-secret');
    assert.equal(seenBody.get('code_verifier'), verifier);
    assert.equal(seenBody.get('redirect_uri'), 'http://localhost:51234');
});

test('ошибка Google и ответ без id_token — исключение', async () => {
    const failing = async () =>
        new Response(JSON.stringify({ error: 'invalid_grant' }), { status: 400 });
    await assert.rejects(
        exchangeGoogleCode(
            { code: 'c', codeVerifier: verifier, redirectUri: 'http://localhost:1' },
            { clientId: 'id', clientSecret: 'secret' },
            failing,
        ),
        GoogleExchangeError,
    );

    const noToken = async () => new Response('{}', { status: 200 });
    await assert.rejects(
        exchangeGoogleCode(
            { code: 'c', codeVerifier: verifier, redirectUri: 'http://localhost:1' },
            { clientId: 'id', clientSecret: 'secret' },
            noToken,
        ),
        GoogleExchangeError,
    );
});
