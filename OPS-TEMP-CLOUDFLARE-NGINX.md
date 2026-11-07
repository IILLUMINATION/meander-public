# ВРЕМЕННЫЙ ОБХОД: nginx отдаёт HTTP (Cloudflare Flexible)

**Статус: активен.** Дата: 2026-11-07, ~22:51 MSK (19:51 UTC).

## Симптом
Мониторинг: `[Backend Meander] [🔴 Down] Maximum number of redirects exceeded`
и `[Meander Main] [🔴 Down] Maximum number of redirects exceeded`.
`https://meander.sbs/` и `https://backend.meander.sbs/quests` отдавали `301` на тот же URL (петля).

## Причина
Cloudflare SSL/TLS в режиме **Flexible**: CF ходит на origin по **HTTP**.
Origin на HTTP отдавал `return 301 https://...`, CF возвращал этот 301 браузеру,
браузер снова шёл по HTTPS — и так 50 раз.

## Что изменено (временно)
- `/etc/nginx/sites-enabled/meander-site`:
  удалён `server { listen 80; ... return 301 https://...; }`,
  в 443-блок добавлен `listen 80;`.
- `/etc/nginx/sites-enabled/meander` (backend): то же самое.
- Бэкапы исходных конфигов:
  - `/root/nginx-backups/meander-site.bak.20261107_195008`
  - `/root/nginx-backups/meander.bak.20261107_195040`

## Проверка (сейчас)
```bash
curl -sI https://meander.sbs/                 # 200
curl -sI https://backend.meander.sbs/quests   # 200
curl -sI http://127.0.0.1/ -H 'Host: meander.sbs'          # 200 (временно)
curl -sI http://127.0.0.1/quests -H 'Host: backend.meander.sbs' # 200 (временно)
```

## КАК ВЕРНУТЬ (сделать, когда Cloudflare будет Full (strict))
1. Cloudflare Dashboard → зона `meander.sbs` → **SSL/TLS → Overview → Full (strict)**.
2. На сервере:
   ```bash
   cp /root/nginx-backups/meander-site.bak.20261107_195008 /etc/nginx/sites-enabled/meander-site
   cp /root/nginx-backups/meander.bak.20261107_195040      /etc/nginx/sites-enabled/meander
   nginx -t && systemctl reload nginx
   ```
3. Проверить:
   ```bash
   curl -sI https://meander.sbs/      # 200
   curl -sI http://meander.sbs/       # 301 → https://meander.sbs/
   curl -sI https://backend.meander.sbs/quests  # 200
   ```
4. Удалить это напоминание (файл на Desktop, в репозитории и на сервере).

## Напоминание
При каждом входе root по SSH в `/root/.bashrc` выводится предупреждение.
Убрать: удалить из `/root/.bashrc` блок, начинающийся с
`# TEMP: Cloudflare nginx workaround reminder`.

## Почему не оставлять навсегда
Пока обход активен, origin отдаёт сайт и API по **прямому HTTP** (если знать IP),
т.е. трафик вне Cloudflare не шифруется и нет CF-защиты. HSTS включён, но это не замена Full (strict).

## Дополнительно сделано 2026-11-07 (можно оставить после откатa обхода)

- **Реальный IP клиента (SEC-07).** `/etc/nginx/snippets/cloudflare-real-ip.conf`
  содержит `set_real_ip_from` для всех сетей Cloudflare (v4/v6),
  `real_ip_header CF-Connecting-IP; real_ip_recursive off;`. Сниппет
  подключён в `http{}` в `/etc/nginx/nginx.conf` (бэкап
  `/root/nginx.conf.bak.*`). Приложение доверяет `X-Real-IP` только от
  loopback (`trust proxy = 'loopback'`), поэтому прямой запрос на origin
  не подделывает IP. Проверка: в `access.log` вместо адреса edge
  появляется адрес клиента (`2.26.48.217`).
- **Автодеплой и переменные окружения.** `meander-autodeploy` теперь делает
  `pm2 startOrReload /var/www/mnd/backend/ecosystem.config.js --update-env`,
  поэтому изменения `CORS_ORIGINS` из `ecosystem.config.js` применяются при
  каждом деплое. `localhost` из production-allowlist удалён (SEC-16).
- **TLS 1.3 (LIVE-02, не закрыто).** Origin-nginx уже слушает
  `ssl_protocols ... TLSv1.3`, но edge Cloudflare отвечает
  `tlsv1 alert protocol version` на `openssl s_client -tls1_3`.
  Включить: Cloudflare Dashboard → SSL/TLS → Edge Certificates →
  TLS 1.3. Это настройка зоны, из репозитория не меняется.
- **Большие ответы (LIVE-01, мониторить).** С этой точки наблюдения
  `GET https://backend.meander.sbs/quests` (279 КБ) и share-страницы
  отдаются целиком; зависание на ~24 КБ не воспроизводится. Если
  повторится — проверять аплинк origin, `proxy_buffering`/MTU и edge
  Cloudflare в проблемном регионе, а не код.
- **`/` и `security.txt` (LIVE-03).** Корень отдаёт `204`, добавлены
  `/.well-known/security.txt` (GitHub Security Advisories) и `robots.txt`.