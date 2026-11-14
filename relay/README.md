# Слепой ретранслятор TLS

Зеркало-прокси (`https://…`, nginx/uvicorn/CF worker) обязано расшифровать TLS,
чтобы маршрутизировать запросы, — значит, оно видит `Authorization`, переписку и
всё тело запросов. Ретранслятор здесь другой: он перекладывает **байты** между
клиентом и одним фиксированным адресом (`127.0.0.1:443` на том же сервере).
Сертификат основного домена клиент проверяет сам, ретранслятор ключей не знает и
протокола не понимает — как MTProxy у Telegram.

## Что он даёт

- Клиент ходит на `https://meander.illuminat.dev/...` как обычно (TLS, SNI и
  проверка сертификата — настоящие), но TCP-соединение идёт на адрес
  ретранслятора. Для сетей, где домен недоступен, это замена зеркалу-прокси.
- Токены, idToken и переписка через него не проходят в открытом виде: он видит
  только объём и тайминги.
- Открытым прокси он не является: пункт назначения задан окружением, `CONNECT`
  не поддерживается, других адресов нет.

## Ограничения

- Не помогает, если провайдер блокирует IP ретранслятора.
- Не кэширует и не ускоряет: это один лишний TCP-хоп.
- Cloudflare Workers такой ретранслятор не заменяет (там нет произвольного TCP).

## Установка (systemd)

```bash
install -d /opt/meander-tunnel
install -m 0644 relay/server.js /opt/meander-tunnel/server.js
install -m 0644 relay/meander-tunnel.service /etc/systemd/system/meander-tunnel.service
systemctl daemon-reload
systemctl enable --now meander-tunnel
systemctl status meander-tunnel --no-pager
```

Порт — `8443/tcp` (меняется в юните). Если включён файрвол:

```bash
ufw allow 8443/tcp
```

Проверка, что цепочка живая и сертификат отдаёт основной домен:

```bash
openssl s_client -connect <relay-ip>:8443 \
  -servername meander.illuminat.dev -verify_return_error </dev/null 2>&1 | head -5
curl --resolve meander.illuminat.dev:8443:<relay-ip> \
  https://meander.illuminat.dev:8443/quests | head -c 80
```

## Настройки

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `RELAY_LISTEN_HOST` | `0.0.0.0` | адрес прослушивания |
| `RELAY_LISTEN_PORT` | `8443` | порт |
| `RELAY_TARGET_HOST` | `127.0.0.1` | куда перекладывать байты |
| `RELAY_TARGET_PORT` | `443` | порт назначения |
| `RELAY_MAX_CONN` | `1024` | предел одновременных соединений |
| `RELAY_IDLE_MS` | `180000` | простой до разрыва |
| `RELAY_VERBOSE` | `0` | писать в журнал каждое подключение |

## Подключение в приложении

Список ретрансляторов задаётся на сборке:

```bash
flutter build apk --release --dart-define=MEANDER_RELAYS=194.31.223.9:8443
```

Значение — через запятую, формат `host:port`. Если ни один не отвечает,
приложение работает напрямую, как раньше.
