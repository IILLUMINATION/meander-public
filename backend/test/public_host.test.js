// Регрессия на «картинки в сообществе не грузятся» (2026-11): ссылки на
// загруженные файлы склеивались в каждом роуте своей строкой
// `${process.env.BASE_URL || 'http://localhost:3000'}`, и при смене домена
// часть ссылок осталась на мёртвом `backend.meander.sbs`. Теперь адрес
// собирается в одном месте (config/public_host), а тесты держат три
// свойства: хост берётся из BASE_URL, хвостовой слэш не даёт `//uploads`,
// снятый домен распознаётся.

const test = require('node:test');
const assert = require('node:assert');

const {
    RETIRED_PUBLIC_HOSTS,
    publicBaseUrl,
    publicUrl
} = require('../dist/config/public_host');

test('publicBaseUrl берёт адрес из BASE_URL и срезает хвостовые слэши', () => {
    assert.strictEqual(
        publicBaseUrl({ BASE_URL: 'https://meander.illuminat.dev' }),
        'https://meander.illuminat.dev'
    );
    // Слэш в конце давал `https://host//uploads/x.jpg` — nginx отдавал 404
    // на двойной слэш в статике.
    assert.strictEqual(
        publicBaseUrl({ BASE_URL: 'https://meander.illuminat.dev///' }),
        'https://meander.illuminat.dev'
    );
});

test('publicUrl не рождает двойной слэш ни с путём, ни без него', () => {
    const env = { BASE_URL: 'https://meander.illuminat.dev/' };
    assert.strictEqual(
        publicUrl('/uploads/a.jpg', env),
        'https://meander.illuminat.dev/uploads/a.jpg'
    );
    assert.strictEqual(
        publicUrl('uploads/a.jpg', env),
        'https://meander.illuminat.dev/uploads/a.jpg'
    );
});

test('пустой BASE_URL даёт локальный адрес, а не ссылку на пустоту', () => {
    assert.strictEqual(publicBaseUrl({}), 'http://localhost:3000');
    assert.strictEqual(publicUrl('/uploads/a.jpg', {}), 'http://localhost:3000/uploads/a.jpg');
});

test('снятые домены перечислены — по ним и ругается лог', () => {
    // Эти хосты больше не отвечают: ссылка на них выглядит как «картинка
    // не загрузилась», поэтому список должен содержать все три исторических.
    for (const host of ['meander.sbs', 'backend.meander.sbs', 'meander.elitrycraft.workers.dev']) {
        assert.ok(RETIRED_PUBLIC_HOSTS.includes(host), `нет ${host}`);
    }
});

test('адрес на снятом домене не роняет сервер, но возвращается как есть', () => {
    const original = console.error;
    const logged = [];
    console.error = (...args) => logged.push(args.join(' '));
    try {
        assert.strictEqual(
            publicBaseUrl({ BASE_URL: 'https://backend.meander.sbs' }),
            'https://backend.meander.sbs'
        );
    } finally {
        console.error = original;
    }
    assert.strictEqual(logged.length, 1);
    assert.match(logged[0], /backend\.meander\.sbs/);
});