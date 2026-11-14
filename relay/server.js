// Слепой ретранслятор TLS для Meander.
//
// Зачем: приложение работает и в сетях, где основной домен недоступен, а
// зеркал-прокси, которые расшифровывают трафик, быть не должно — прокси,
// терминирующий TLS, видит `Authorization`, переписку и всё остальное.
// Здесь ретранслятор — тупой TCP-мост к одному фиксированному адресу:
// клиент проверяет сертификат основного домена сам, ретранслятор видит
// только зашифрованные байты. Как у Telegram: прокси не знает ключей.
//
// Открытым прокси он не является: пункт назначения задаётся только
// переменными окружения, CONNECT-запросов не понимает, других адресов не
// обслуживает.
//
// Запуск:
//   RELAY_TARGET_HOST=127.0.0.1 RELAY_TARGET_PORT=443 node server.js
// Переменные: RELAY_LISTEN_HOST (0.0.0.0), RELAY_LISTEN_PORT (8443),
// RELAY_TARGET_HOST, RELAY_TARGET_PORT, RELAY_MAX_CONN (1024),
// RELAY_IDLE_MS (180000).

'use strict';

const net = require('net');

const LISTEN_HOST = process.env.RELAY_LISTEN_HOST || '0.0.0.0';
const LISTEN_PORT = Number(process.env.RELAY_LISTEN_PORT || 8443);
const TARGET_HOST = process.env.RELAY_TARGET_HOST || '127.0.0.1';
const TARGET_PORT = Number(process.env.RELAY_TARGET_PORT || 443);
const MAX_CONN = Number(process.env.RELAY_MAX_CONN || 1024);
const IDLE_MS = Number(process.env.RELAY_IDLE_MS || 180000);

let active = 0;
let total = 0;
let rejected = 0;

const server = net.createServer({ allowHalfOpen: true }, (client) => {
  if (active >= MAX_CONN) {
    rejected += 1;
    client.destroy();
    return;
  }
  active += 1;
  total += 1;

  const upstream = net.createConnection({ host: TARGET_HOST, port: TARGET_PORT });
  upstream.setNoDelay(true);
  client.setNoDelay(true);

  const kill = () => {
    client.destroy();
    upstream.destroy();
  };

  client.setTimeout(IDLE_MS, kill);
  upstream.setTimeout(IDLE_MS, kill);

  client.on('error', kill);
  upstream.on('error', kill);
  client.on('close', () => upstream.destroy());
  upstream.on('close', () => client.destroy());

  // Никакого разбора содержимого: только байты в обе стороны.
  client.pipe(upstream);
  upstream.pipe(client);

  if (process.env.RELAY_VERBOSE === '1') {
    console.log(
      `[relay] ${client.remoteAddress}:${client.remotePort} → ${TARGET_HOST}:${TARGET_PORT}`,
    );
  }
  const release = () => {
    active -= 1;
  };
  client.once('close', release);
});

server.on('error', (err) => {
  console.error('[relay] listen error:', err.message);
  process.exit(1);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(
    `[relay] ${LISTEN_HOST}:${LISTEN_PORT} → ${TARGET_HOST}:${TARGET_PORT} ` +
      `(max ${MAX_CONN} conn, idle ${IDLE_MS}ms)`,
  );
});

const shutdown = () => {
  console.log(`[relay] shutting down: total=${total} active=${active} rejected=${rejected}`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// Раз в час — строка в журнал, чтобы видеть нагрузку и мусорные подключения.
setInterval(() => {
  console.log(`[relay] total=${total} active=${active} rejected=${rejected}`);
}, 3600000).unref();